import Combine
import Foundation
import os

/// Where the realtime link stands.
enum RealtimeState: Equatable {
    /// Opening the socket for the first time since `open`.
    case connecting
    case connected
    /// The link is down: the next attempt is scheduled or under way.
    case reconnecting
    /// Closed by the owner, or given up on: 4404, a chat that has no realtime socket.
    case stopped
}

/// What one physical socket reported.
enum RealtimeEvent {
    case ready
    case created(ChatMessage)
    case updated(ChatMessage)
    case typing(Bool, String?)
    case ended(VisitorSocket.End)
}

/// The reconnect policy in one place.
enum RealtimePolicy {
    /// The server's close codes: an unusable token, and a chat that has no realtime socket.
    static let tokenExpired = 4401
    static let chatUnavailable = 4404

    static let minBackoff: TimeInterval = 1
    static let maxBackoff: TimeInterval = 30
    /// Keeps many devices from retrying in step.
    static let maxJitter: TimeInterval = 0.5

    /// Seconds before attempt `retry`, counting from 0: 1, 2, 4 … 30.
    static func backoffDelay(retry: Int, jitter: TimeInterval = 0) -> TimeInterval {
        let doublings = Double(min(max(retry, 0), 20))
        return min(maxBackoff, minBackoff * pow(2.0, doublings)) + jitter
    }
}

/// The slice of a socket the connection drives; tests hand in their own.
protocol RealtimeSocket: AnyObject {
    func connect()
    func close()
}

extension VisitorSocket: RealtimeSocket {}

/// Gets the realtime events on the main actor.
@MainActor
protocol RealtimeListener: AnyObject {
    /// The server answered `ready`; `afterDrop` is false only the very first time.
    func onRealtimeReady(afterDrop: Bool)
    func onRealtimeMessage(_ message: ChatMessage)
    func onRealtimeUpdate(_ message: ChatMessage)
    func onRealtimeTyping(typing: Bool, name: String?)
    /// Close code 4401: this token no longer opens a socket. Renew the session, then `open` the
    /// link with the new token. Asked again at backoff speed while that does not happen.
    func onRealtimeTokenExpired()
}

/// The visitor's realtime link to `GET /sdk/v1/ws`, kept open for as long as the messenger is:
/// after a drop it reconnects with backoff, and it tells its owner when the list on screen has to
/// catch up. Same behaviour as the web widget's `client.connect`.
@MainActor
final class RealtimeConnection {

    typealias State = RealtimeState
    typealias Sleeper = (TimeInterval) async -> Void

    /// Every change of `state`, for whoever shows the "reconnecting" hint.
    let states = PassthroughSubject<State, Never>()

    private(set) var state: State = .stopped {
        didSet { if oldValue != state { states.send(state) } }
    }

    /// Bumped whenever the socket or the pending retry is replaced; an older one's callbacks no
    /// longer count.
    private(set) var generation = 0

    private let listener: RealtimeListener
    private let wsUrl: String
    private let openSocket: (URL, VisitorSocket.Listener) -> RealtimeSocket
    private let sleep: Sleeper
    /// Wait before attempt N, counting from 0.
    private let backoff: (Int) -> TimeInterval
    private let log: (String) -> Void

    /// Path of the socket — the only thing the log says about its address.
    private let path: String

    private var token: String?
    private var socket: RealtimeSocket?
    /// Consecutive attempts that did not reach `ready`.
    private var retry = 0
    private var everReady = false
    private var retryTask: Task<Void, Never>?

    init(
        listener: RealtimeListener,
        wsUrl: String,
        openSocket: @escaping (URL, VisitorSocket.Listener) -> RealtimeSocket,
        sleep: @escaping Sleeper = RealtimeConnection.taskSleep,
        backoff: @escaping (Int) -> TimeInterval = RealtimeConnection.defaultBackoff,
        log: @escaping (String) -> Void = RealtimeConnection.defaultLog
    ) {
        self.listener = listener
        self.wsUrl = wsUrl
        self.openSocket = openSocket
        self.sleep = sleep
        self.backoff = backoff
        self.log = log
        path = SdkApiURLSession.socketPath(wsUrl: wsUrl)
    }

    /// Opens the link with `token`. A link that is already open is kept, unless `reopen` is set.
    func open(token: String, reopen: Bool = false) {
        let sameToken = self.token == token
        self.token = token
        if !reopen && sameToken && socket != nil { return }
        replaceSocket()
        retry = 0
        dial()
    }

    func close() {
        token = nil
        replaceSocket()
        state = .stopped
    }

    /// Forgets the open socket and the pending retry; what is opened next carries a new generation.
    private func replaceSocket() {
        generation += 1
        retryTask?.cancel()
        retryTask = nil
        socket?.close()
        socket = nil
    }

    private func dial() {
        guard let token else { return }
        state = retry > 0 ? .reconnecting : .connecting
        generation += 1
        guard let url = SdkApiURLSession.socketUrl(wsUrl: wsUrl, token: token) else {
            // A baseUrl the socket address cannot be built from: the chat still works over HTTP.
            log("socket not opened: invalid_url")
            state = .stopped
            return
        }
        let opened = openSocket(url, DialListener(owner: self, origin: generation))
        socket = opened
        opened.connect()
    }

    private func ready() {
        retry = 0
        state = .connected
        let afterDrop = everReady
        everReady = true
        listener.onRealtimeReady(afterDrop: afterDrop)
    }

    private func ended(_ end: VisitorSocket.End) {
        socket = nil
        if end.code == RealtimePolicy.chatUnavailable {
            log("socket \(why(end)) at \(path) — this chat has no realtime socket")
            state = .stopped
            return
        }
        // A dead token is never retried on its own: the owner renews the session and opens the
        // link with the new one, which cancels the pending retry. Should that renewal fail, the
        // retry asks again — at backoff speed, never several times a second.
        let expired = end.code == RealtimePolicy.tokenExpired
        if expired { listener.onRealtimeTokenExpired() }
        let wait = backoff(retry)
        retry += 1
        let asked = expired ? "waiting for a new session, " : ""
        log("socket \(why(end)) at \(path) — \(asked)reconnect #\(retry) in \(String(format: "%.1f", wait))s")
        state = .reconnecting
        let origin = generation
        retryTask = Task {
            await self.sleep(wait)
            guard self.generation == origin, !Task.isCancelled else { return }
            if expired { self.listener.onRealtimeTokenExpired() }
            self.dial()
        }
    }

    /// What the log calls it: the close code or the network code, never the error itself.
    private func why(_ end: VisitorSocket.End) -> String {
        if end.code != 0 { return "closed \(end.code)" }
        let detail: String
        if end.silent {
            detail = " (no pong to \(VisitorSocket.unansweredLimit) pings)"
        } else if let status = end.httpStatus {
            detail = " (HTTP \(status))"
        } else if let code = end.networkCode {
            detail = " (URLError \(code))"
        } else {
            detail = ""
        }
        return (end.handshakeRefused ? "handshake refused" : "connection lost") + detail
    }

    /// What one physical socket reported, if it is still the current one.
    fileprivate func deliver(_ event: RealtimeEvent, from origin: Int) {
        guard generation == origin else { return }
        switch event {
        case .ready:
            ready()
        case .created(let message):
            listener.onRealtimeMessage(message)
        case .updated(let message):
            listener.onRealtimeUpdate(message)
        case .typing(let typing, let name):
            listener.onRealtimeTyping(typing: typing, name: name)
        case .ended(let end):
            ended(end)
        }
    }

    nonisolated static func taskSleep(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    nonisolated static func defaultBackoff(retry: Int) -> TimeInterval {
        RealtimePolicy.backoffDelay(retry: retry, jitter: Double.random(in: 0...RealtimePolicy.maxJitter))
    }

    nonisolated static func defaultLog(_ line: String) {
        os_log(.error, log: SdkApiURLSession.osLog, "%{public}@", line)
    }
}

/// What one physical socket reported, moved from the socket's queue onto the main actor.
private final class DialListener: VisitorSocket.Listener {
    private weak var owner: RealtimeConnection?
    private let origin: Int

    init(owner: RealtimeConnection, origin: Int) {
        self.owner = owner
        self.origin = origin
    }

    func onSocketReady() { pass(.ready) }
    func onMessageCreated(_ message: ChatMessage) { pass(.created(message)) }
    func onMessageUpdated(_ message: ChatMessage) { pass(.updated(message)) }
    func onTyping(typing: Bool, name: String?) { pass(.typing(typing, name)) }
    func onSocketEnded(_ end: VisitorSocket.End) { pass(.ended(end)) }

    private func pass(_ event: RealtimeEvent) {
        let owner = self.owner
        let origin = self.origin
        Task { @MainActor in owner?.deliver(event, from: origin) }
    }
}
