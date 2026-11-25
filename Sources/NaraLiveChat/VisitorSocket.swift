import Foundation

/// One visitor realtime socket — `GET /sdk/v1/ws?token=<visitorToken>` (protocol: ready, pong,
/// typing, draft, message.created, message.updated). Unknown event types are ignored per the
/// compat rule; unknown message types inside `message.*` degrade to the fallback text via
/// `ChatMessage.withFallback`.
///
/// It pings while it is open, gives the line up when nothing comes back, and reports how it
/// ended; reconnecting is `RealtimeConnection`'s job.
public final class VisitorSocket {

    /// How a socket ended. No error object travels with it: a `URLError` repeats the whole
    /// URL, token included, in its userInfo.
    public struct End: Equatable, Sendable {
        /// Close code the server sent, or 0 when none arrived.
        public let code: Int
        /// HTTP status of a refused upgrade, when one could be read.
        public let httpStatus: Int?
        /// `URLError` code when the line failed without a close frame.
        public let networkCode: Int?
        /// True once a frame had arrived: the socket was up before it ended.
        public let wasOpen: Bool
        /// Nothing came from the server after `unansweredLimit` pings in a row: the socket cut
        /// the line itself, because no error was ever going to report it.
        public let silent: Bool

        /// The server never delivered a frame: the upgrade was refused, or the line failed first.
        public var handshakeRefused: Bool { !wasOpen }

        public init(code: Int, httpStatus: Int?, networkCode: Int?, wasOpen: Bool, silent: Bool = false) {
            self.code = code
            self.httpStatus = httpStatus
            self.networkCode = networkCode
            self.wasOpen = wasOpen
            self.silent = silent
        }
    }

    public protocol Listener: AnyObject {
        func onSocketReady()
        func onMessageCreated(_ message: ChatMessage)
        func onMessageUpdated(_ message: ChatMessage)
        func onTyping(typing: Bool, name: String?)
        /// The socket is over, unless `close()` was called first.
        func onSocketEnded(_ end: End)
    }

    /// The web widget's keep-alive cadence.
    public static let pingInterval: TimeInterval = 25
    /// Pings in a row that nothing from the server came after. The system reports a dead line
    /// only when it notices one itself, which can take minutes or never happen.
    static let unansweredLimit = 2

    private static let ping = #"{"type":"ping"}"#

    /// Starts work that repeats every so many seconds and returns what stops it.
    typealias Scheduler = (TimeInterval, @escaping () -> Void) -> () -> Void

    private let url: URL
    private let listener: Listener
    private let pingInterval: TimeInterval
    private let openWire: (URL) -> SocketWire
    private let scheduler: Scheduler

    /// Touched on `queue` only: frames arrive on the session's queue, the ping on the
    /// timer's, and `close()` from whoever owns the socket.
    private let queue = DispatchQueue(label: "id.nara.livechat.socket", qos: .utility)
    private var wire: SocketWire?
    private var stopPing: (() -> Void)?
    private var closed = false
    private var wasOpen = false
    /// Pings sent in a row with no frame from the server in between.
    private var unanswered = 0

    public convenience init(url: URL, listener: Listener) {
        self.init(
            url: url, listener: listener, pingInterval: VisitorSocket.pingInterval,
            openWire: VisitorSocket.systemWire, scheduler: VisitorSocket.dispatchTimer
        )
    }

    /// `openWire` and `scheduler` are the system's in production; tests hand in their own.
    init(
        url: URL,
        listener: Listener,
        pingInterval: TimeInterval,
        openWire: @escaping (URL) -> SocketWire,
        scheduler: @escaping Scheduler
    ) {
        self.url = url
        self.listener = listener
        self.pingInterval = pingInterval
        self.openWire = openWire
        self.scheduler = scheduler
    }

    public func connect() {
        queue.async {
            guard !self.closed, self.wire == nil else { return }
            let wire = self.openWire(self.url)
            self.wire = wire
            self.stopPing = self.scheduler(self.pingInterval) { [weak self] in
                guard let self = self else { return }
                self.queue.async { self.tick(wire) }
            }
            self.receive(wire)
        }
    }

    /// The timer's work: the ping, and the count of the ones nothing answered.
    private func tick(_ wire: SocketWire) {
        guard !closed, self.wire === wire else { return }
        if unanswered >= Self.unansweredLimit {
            end(nil, wire: wire, silent: true)
            wire.cancel()
            return
        }
        unanswered += 1
        wire.send(Self.ping)
    }

    private func receive(_ wire: SocketWire) {
        wire.receive { result in
            self.queue.async {
                // A socket that was closed or replaced reports nothing and reads no further.
                guard !self.closed, self.wire === wire else { return }
                switch result {
                case .success(let text):
                    self.wasOpen = true
                    self.unanswered = 0
                    self.handle(text)
                    self.receive(wire)
                case .failure(let error):
                    self.end(error, wire: wire)
                }
            }
        }
    }

    /// Reads the error for its codes only: its description repeats the URL, token included.
    /// `error` is nil when the socket gave the line up itself.
    private func end(_ error: Error?, wire: SocketWire?, silent: Bool = false) {
        stopPing?()
        stopPing = nil
        self.wire = nil
        let info = error.map { ($0 as NSError).userInfo } ?? [:]
        // The response in the error goes under its older spelling on some systems.
        let carried = info["NSErrorFailingURLResponseKey"] ?? info["NSURLErrorFailingURLSessionResponseErrorKey"]
        let status = (carried as? HTTPURLResponse)?.statusCode ?? refusedStatus(of: wire)
        var code = wire?.closeCode ?? 0
        if code == 0 {
            code = (info["_NSURLErrorWSCloseCodeKey"] as? NSNumber)?.intValue ?? 0
        }
        let networkCode = (error as? URLError)?.errorCode
        listener.onSocketEnded(
            End(code: code, httpStatus: status, networkCode: networkCode, wasOpen: wasOpen, silent: silent)
        )
    }

    /// The status of a refused upgrade as the task itself still holds it: the error carries one
    /// on some systems only. 101 is an upgrade that went through, not a refusal.
    private func refusedStatus(of wire: SocketWire?) -> Int? {
        guard !wasOpen, let status = wire?.httpStatus, status != 101 else { return nil }
        return status
    }

    private struct Event: Decodable {
        let type: String?
        let data: EventData?
        struct EventData: Decodable {
            let typing: Bool?
            let name: String?
        }
    }

    /// A frame the SDK cannot read is skipped — it must not take the whole socket down.
    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let event = try? JSONDecoder().decode(Event.self, from: data),
              let type = event.type else { return }

        switch type {
        case "ready":
            listener.onSocketReady()
        case "pong":
            break
        case "message.created":
            if let m = decodeMessage(text) { listener.onMessageCreated(m) }
        case "message.updated":
            if let m = decodeMessage(text) { listener.onMessageUpdated(m) }
        case "agent.typing", "typing":
            listener.onTyping(typing: event.data?.typing ?? false, name: event.data?.name)
        default:
            break // unknown event types must be ignored (forward compat)
        }
    }

    private func decodeMessage(_ text: String) -> ChatMessage? {
        guard let data = text.data(using: .utf8) else { return nil }
        struct Wrapper: Decodable { let data: ChatMessage? }
        return (try? JSONDecoder().decode(Wrapper.self, from: data))?.data.map { ChatMessage.withFallback($0, locale: "id") }
    }

    public func sendTyping(_ typing: Bool, draft: String?) {
        var payload: [String: Any] = ["type": "typing", "typing": typing]
        if let draft { payload["draft"] = String(draft.prefix(200)) }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        queue.async { self.wire?.send(text) }
    }

    public func close() {
        queue.async {
            self.closed = true
            self.stopPing?()
            self.stopPing = nil
            self.wire?.cancel()
            self.wire = nil
        }
    }

    private static func systemWire(_ url: URL) -> SocketWire {
        URLSessionSocketWire(URLSession.shared.webSocketTask(with: url))
    }

    private static let pingQueue = DispatchQueue(label: "id.nara.livechat.ping", qos: .utility)

    /// A repeating timer on a private queue: it needs no run loop and keeps no thread alive.
    static func dispatchTimer(_ interval: TimeInterval, _ fire: @escaping () -> Void) -> () -> Void {
        let timer = DispatchSource.makeTimerSource(queue: pingQueue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler(handler: fire)
        timer.resume()
        return { timer.cancel() }
    }
}

/// The slice of `URLSessionWebSocketTask` the socket works with; tests hand in their own.
protocol SocketWire: AnyObject {
    /// Delivers one frame or the end of the line; called again after each frame.
    func receive(_ completion: @escaping (Result<String, Error>) -> Void)
    func send(_ text: String)
    /// Close code the server sent, or 0.
    var closeCode: Int { get }
    /// HTTP status the task last received: 101 once the upgrade went through.
    var httpStatus: Int? { get }
    func cancel()
}

final class URLSessionSocketWire: SocketWire {
    private let task: URLSessionWebSocketTask

    init(_ task: URLSessionWebSocketTask) {
        self.task = task
        task.resume()
    }

    func receive(_ completion: @escaping (Result<String, Error>) -> Void) {
        task.receive { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let message):
                switch message {
                case .string(let text):
                    completion(.success(text))
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        completion(.success(text))
                    } else {
                        self.receive(completion) // not text: skip the frame and keep reading
                    }
                @unknown default:
                    self.receive(completion)
                }
            }
        }
    }

    func send(_ text: String) {
        task.send(.string(text)) { _ in }
    }

    var closeCode: Int { task.closeCode.rawValue }
    var httpStatus: Int? { (task.response as? HTTPURLResponse)?.statusCode }

    func cancel() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}
