import Foundation
import XCTest
@testable import NaraLiveChat

/// Polls `condition` on the main actor until it holds; fails the test when it never does.
@MainActor
func waitUntil(
    timeout: TimeInterval = 2,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @MainActor () async -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !(await condition()) {
        if Date() > deadline {
            XCTFail("timed out waiting for the condition", file: file, line: line)
            return
        }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}

/// Collects the diagnostic lines the SDK writes while a test runs.
final class RecordedLog {
    private let lock = NSLock()
    private var stored: [String] = []

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    var joined: String { lines.joined(separator: "\n") }

    func take(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        stored.append(line)
    }
}

/// A chat message for tests: a reply from the team unless `from` says otherwise.
func message(
    _ id: String,
    from: String = "agent",
    sentAt: String = "2026-11-23T10:00:00.000Z",
    clientId: String? = nil
) -> ChatMessage {
    ChatMessage(
        id: id, clientId: clientId, from: from, senderName: "Agen", type: "text", body: "hai",
        media: nil, status: "sent", sentAt: sentAt, quoted: nil
    )
}

/// A socket nothing happens to until the test reports something on its behalf.
final class FakeSocket: RealtimeSocket {
    private let listener: VisitorSocket.Listener
    private let lock = NSLock()
    private var connectCount = 0
    private var closed = false

    init(listener: VisitorSocket.Listener) {
        self.listener = listener
    }

    var connects: Int {
        lock.lock()
        defer { lock.unlock() }
        return connectCount
    }

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    func connect() {
        lock.lock()
        defer { lock.unlock() }
        connectCount += 1
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        closed = true
    }

    /// Reports as the socket's own queue would: from whatever thread calls it.
    func report(_ event: RealtimeEvent) {
        switch event {
        case .ready: listener.onSocketReady()
        case .created(let m): listener.onMessageCreated(m)
        case .updated(let m): listener.onMessageUpdated(m)
        case .typing(let typing, let name): listener.onTyping(typing: typing, name: name)
        case .ended(let end): listener.onSocketEnded(end)
        }
    }
}

/// What the connection opened: one fake socket per dial, with the address it was given.
final class Sockets {
    private let lock = NSLock()
    private var opened: [(socket: FakeSocket, url: URL)] = []

    /// Hand this to the connection as its `openSocket`.
    func open(_ url: URL, _ listener: VisitorSocket.Listener) -> RealtimeSocket {
        let socket = FakeSocket(listener: listener)
        lock.lock()
        opened.append((socket, url))
        lock.unlock()
        return socket
    }

    var all: [FakeSocket] {
        lock.lock()
        defer { lock.unlock() }
        return opened.map { $0.socket }
    }

    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return opened.map { $0.url }
    }

    var count: Int { all.count }

    var last: FakeSocket? { all.last }

    /// The `token` query value of every address the connection dialed.
    var tokens: [String] {
        urls.map { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first?.value ?? "" }
    }
}

/// Stands in for waiting. Records each delay and returns at once, or — started with `hold: true` —
/// holds the caller until `release()`.
actor SleepLog {
    private(set) var waits: [TimeInterval] = []
    private var gateClosed: Bool
    private var held: [CheckedContinuation<Void, Never>] = []

    init(hold: Bool = false) {
        gateClosed = hold
    }

    func note(_ seconds: TimeInterval) async {
        waits.append(seconds)
        if gateClosed {
            await withCheckedContinuation { held.append($0) }
        }
    }

    /// Lets every held wait continue; waits from then on return at once.
    func release() {
        gateClosed = false
        let all = held
        held = []
        all.forEach { $0.resume() }
    }
}

/// Gets what the connection tells its owner.
@MainActor
final class Owner: RealtimeListener {
    /// `afterDrop` of every `ready`, in order.
    private(set) var reads: [Bool] = []
    private(set) var created: [ChatMessage] = []
    private(set) var updated: [ChatMessage] = []
    private(set) var typings: [(typing: Bool, name: String?)] = []
    private(set) var expiryAsks = 0

    func onRealtimeReady(afterDrop: Bool) { reads.append(afterDrop) }
    func onRealtimeMessage(_ message: ChatMessage) { created.append(message) }
    func onRealtimeUpdate(_ message: ChatMessage) { updated.append(message) }
    func onRealtimeTyping(typing: Bool, name: String?) { typings.append((typing, name)) }
    func onRealtimeTokenExpired() { expiryAsks += 1 }
}
