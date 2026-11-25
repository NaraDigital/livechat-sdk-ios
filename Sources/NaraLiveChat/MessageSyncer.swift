import Foundation

/// Ten rounds of three seconds: the fallback gives up after half a minute.
private enum Polling {
    static let interval: TimeInterval = 3
    static let maxRounds = 10
}

/// What the syncer needs from the session.
@MainActor
protocol MessageSyncSource: AnyObject {
    /// True while the socket is connected — nothing to catch up on then.
    var isRealtimeLive: Bool { get }
    /// The server's latest page, or nil when it could not be read this time.
    func fetchLatestMessages() async -> [ChatMessage]?
    /// Folds a page into the list on screen; true when it brought a reply from the AI or an agent.
    func foldLatest(_ fresh: [ChatMessage]) -> Bool
}

/// Keeps the message list current whenever the socket cannot be relied on: right after it came
/// back (replies may have arrived while it was down), and after the visitor sent something while
/// it is still down.
@MainActor
final class MessageSyncer {

    typealias Sleeper = (TimeInterval) async -> Void

    private let source: MessageSyncSource
    private let pollInterval: TimeInterval
    private let maxPolls: Int
    private let sleep: Sleeper
    private var polling: Task<Void, Never>?

    init(
        source: MessageSyncSource,
        pollInterval: TimeInterval = Polling.interval,
        maxPolls: Int = Polling.maxRounds,
        sleep: @escaping Sleeper = MessageSyncer.taskSleep
    ) {
        self.source = source
        self.pollInterval = pollInterval
        self.maxPolls = maxPolls
        self.sleep = sleep
    }

    /// The socket answered `ready`: polling can stop, and after a drop the list catches up.
    func socketReady(afterDrop: Bool) {
        stop()
        if afterDrop {
            Task { await self.resync() }
        }
    }

    /// Reads the server's latest page once and folds it in.
    func resync() async {
        guard let fresh = await source.fetchLatestMessages() else { return }
        _ = source.foldLatest(fresh)
    }

    /// Reads the latest page every `pollInterval` until a reply shows up, the socket is back, or
    /// `maxPolls` rounds are over. Does nothing while the socket is connected.
    func pollForReply() {
        guard !source.isRealtimeLive else { return }
        polling?.cancel()
        polling = Task {
            var rounds = 0
            while !Task.isCancelled, !self.source.isRealtimeLive, rounds < self.maxPolls {
                rounds += 1
                await self.sleep(pollInterval)
                guard !Task.isCancelled, !self.source.isRealtimeLive else { return }
                if let fresh = await self.source.fetchLatestMessages(), self.source.foldLatest(fresh) {
                    self.polling = nil
                    return
                }
            }
            self.polling = nil
        }
    }

    func stop() {
        polling?.cancel()
        polling = nil
    }

    nonisolated static func taskSleep(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}
