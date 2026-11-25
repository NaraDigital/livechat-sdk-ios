import XCTest
@testable import NaraLiveChat

/// The session as the syncer sees it: says whether the socket is up, hands out pages, folds them.
@MainActor
private final class Source: MessageSyncSource {
    var live = false
    var isRealtimeLive: Bool { live }
    /// The socket comes back once this many pages were folded.
    var liveAfterFolds: Int?
    /// Whether each folded page, in order, brought a reply.
    var replies: [Bool] = []
    private(set) var fetches = 0
    private(set) var foldedIds: [[String]] = []

    func fetchLatestMessages() async -> [ChatMessage]? {
        fetches += 1
        return [message("fresh_\(fetches)")]
    }

    @discardableResult
    func foldLatest(_ fresh: [ChatMessage]) -> Bool {
        foldedIds.append(fresh.map(\.id))
        if foldedIds.count == liveAfterFolds { live = true }
        return foldedIds.count <= replies.count ? replies[foldedIds.count - 1] : false
    }
}

@MainActor
private func makeSyncer(_ source: Source, hold: Bool = false) -> (syncer: MessageSyncer, sleeps: SleepLog) {
    let sleeps = SleepLog(hold: hold)
    let syncer = MessageSyncer(source: source, sleep: { seconds in await sleeps.note(seconds) })
    return (syncer, sleeps)
}

/// The SDK goes looking for a reply over HTTP whenever the socket cannot be relied on, and
/// stops the moment it is no longer needed.
@MainActor
final class MessageSyncerTests: XCTestCase {

    /// Gives a task the time to run out.
    private func settle() async {
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    func testPollingStopsOnceAReplyShowsUp() async {
        let source = Source()
        source.replies = [false, false, true]
        let (syncer, sleeps) = makeSyncer(source)

        syncer.pollForReply()
        await waitUntil { source.fetches == 3 }
        await settle()

        XCTAssertEqual(source.fetches, 3)
        let waits = await sleeps.waits
        XCTAssertEqual(waits, [3, 3, 3], "one read every three seconds")
    }

    func testPollingStopsOnceTheSocketIsBack() async {
        let source = Source()
        source.liveAfterFolds = 2
        let (syncer, sleeps) = makeSyncer(source)

        syncer.pollForReply()
        await waitUntil { source.fetches == 2 }
        await settle()

        XCTAssertEqual(source.fetches, 2)
        let waits = await sleeps.waits
        XCTAssertEqual(waits, [3, 3])
    }

    func testPollingGivesUpAfterHalfAMinute() async {
        let source = Source()
        let (syncer, sleeps) = makeSyncer(source)

        syncer.pollForReply()
        await waitUntil { source.fetches == 10 }
        await settle()

        XCTAssertEqual(source.fetches, 10)
        let waits = await sleeps.waits
        XCTAssertEqual(waits, Array(repeating: 3, count: 10))
        XCTAssertEqual(waits.reduce(0, +), 30)
    }

    func testNothingIsFetchedWhileTheSocketIsConnected() async {
        let source = Source()
        source.live = true
        let (syncer, sleeps) = makeSyncer(source)

        syncer.pollForReply()
        await settle()

        XCTAssertEqual(source.fetches, 0)
        let waits = await sleeps.waits
        XCTAssertTrue(waits.isEmpty)
    }

    func testTheListCatchesUpOnlyAfterADrop() async {
        let source = Source()
        let (syncer, _) = makeSyncer(source)
        source.live = true

        syncer.socketReady(afterDrop: false)
        await settle()
        XCTAssertEqual(source.fetches, 0, "the first ready follows a list that was just loaded")

        syncer.socketReady(afterDrop: true)
        await waitUntil { source.fetches == 1 }
        await settle()
        XCTAssertEqual(source.fetches, 1)
        XCTAssertEqual(source.foldedIds, [["fresh_1"]])
    }

    func testStoppingCancelsThePollThatWasWaiting() async {
        let source = Source()
        let (syncer, sleeps) = makeSyncer(source, hold: true)
        syncer.pollForReply()
        await waitUntil { await sleeps.waits.count == 1 }

        syncer.stop()
        await sleeps.release()
        await settle()

        XCTAssertEqual(source.fetches, 0)
    }

    func testASendWhileAPollRunsStartsAFreshPoll() async {
        let source = Source()
        source.replies = [true]
        let (syncer, sleeps) = makeSyncer(source, hold: true)
        syncer.pollForReply()
        await waitUntil { await sleeps.waits.count == 1 }

        syncer.pollForReply()
        await waitUntil { await sleeps.waits.count == 2 }
        await sleeps.release()
        await settle()

        XCTAssertEqual(source.fetches, 1, "the first poll was cancelled, the second read once")
        XCTAssertEqual(source.foldedIds, [["fresh_1"]])
    }

    func testAReadyEndsThePollThatWasWaiting() async {
        let source = Source()
        let (syncer, sleeps) = makeSyncer(source, hold: true)
        syncer.pollForReply()
        await waitUntil { await sleeps.waits.count == 1 }

        source.live = true
        syncer.socketReady(afterDrop: true)
        await sleeps.release()
        await settle()

        XCTAssertEqual(source.fetches, 1, "only the catch-up page was read")
        XCTAssertEqual(source.foldedIds, [["fresh_1"]])
    }
}
