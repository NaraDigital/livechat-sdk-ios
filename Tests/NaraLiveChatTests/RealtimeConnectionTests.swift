import XCTest
@testable import NaraLiveChat

/// One connection over fake sockets. Its waits are held until `release`, so a test can look at
/// the state between one attempt and the next.
@MainActor
private final class Harness {
    let owner: Owner
    let sockets: Sockets
    let sleeps: SleepLog
    let log: RecordedLog
    let link: RealtimeConnection

    init(jitter: TimeInterval = 0, wsUrl: String = "wss://chat.invalid/api/sdk/v1/ws") {
        let owner = Owner()
        let sockets = Sockets()
        let sleeps = SleepLog(hold: true)
        let log = RecordedLog()
        self.owner = owner
        self.sockets = sockets
        self.sleeps = sleeps
        self.log = log
        link = RealtimeConnection(
            listener: owner,
            wsUrl: wsUrl,
            openSocket: { sockets.open($0, $1) },
            sleep: { seconds in await sleeps.note(seconds) },
            backoff: { retry in RealtimePolicy.backoffDelay(retry: retry, jitter: jitter) },
            log: log.take
        )
    }

    /// Lets the held wait continue.
    func release() async {
        await sleeps.release()
    }
}

/// Keeps the realtime link up on its own: every drop is retried with backoff, a dead token is
/// handed to the owner, and the log says why — never with the token.
@MainActor
final class RealtimeConnectionTests: XCTestCase {

    /// A refused upgrade: no close frame, the HTTP status in its place.
    private let refused = VisitorSocket.End(code: 0, httpStatus: 404, networkCode: nil, wasOpen: false)
    private let dropped = VisitorSocket.End(code: 1006, httpStatus: nil, networkCode: nil, wasOpen: true)
    private let expired = VisitorSocket.End(code: 4401, httpStatus: nil, networkCode: nil, wasOpen: true)
    private let unavailable = VisitorSocket.End(code: 4404, httpStatus: nil, networkCode: nil, wasOpen: true)

    /// Gives a callback the time to travel from the socket to the main actor.
    private func settle() async {
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    func testARefusedHandshakeIsRetriedWithGrowingWaits() async {
        let h = Harness()
        h.link.open(token: "st_old")
        XCTAssertEqual(h.sockets.count, 1)
        XCTAssertEqual(h.link.state, .connecting)

        h.sockets.last?.report(.ended(refused))
        await waitUntil { h.link.state == .reconnecting }
        XCTAssertEqual(h.log.lines.last, "socket handshake refused (HTTP 404) at /api/sdk/v1/ws — reconnect #1 in 1.0s")

        await h.release()
        await waitUntil { h.sockets.count == 2 }
        XCTAssertEqual(h.link.state, .reconnecting, "a retry is a reconnect, not a first dial")

        h.sockets.last?.report(.ended(dropped))
        await waitUntil { h.log.lines.count == 2 }
        XCTAssertEqual(h.log.lines.last, "socket closed 1006 at /api/sdk/v1/ws — reconnect #2 in 2.0s")

        await h.release()
        await waitUntil { h.sockets.count == 3 }
        let waits = await h.sleeps.waits
        XCTAssertEqual(waits, [1, 2])
        XCTAssertFalse(h.log.joined.contains("st_old"), "the token reached the log")
    }

    func testAReadyAfterADropAsksForACatchUpAndStartsTheRetryCountOver() async {
        let h = Harness()
        h.link.open(token: "st_1")
        h.sockets.last?.report(.ready)
        await waitUntil { h.owner.reads.count == 1 }
        XCTAssertEqual(h.owner.reads, [false], "the very first ready is not a recovery")
        XCTAssertEqual(h.link.state, .connected)

        h.sockets.last?.report(.ended(dropped))
        await waitUntil { h.log.lines.count == 1 }
        XCTAssertEqual(h.link.state, .reconnecting)
        await h.release()
        await waitUntil { h.sockets.count == 2 }

        h.sockets.last?.report(.ready)
        await waitUntil { h.owner.reads.count == 2 }
        XCTAssertEqual(h.owner.reads, [false, true], "a ready that follows a drop is a recovery")
        XCTAssertEqual(h.link.state, .connected)

        h.sockets.last?.report(.ended(dropped))
        await waitUntil { h.log.lines.count == 2 }
        XCTAssertEqual(
            h.log.lines.last, "socket closed 1006 at /api/sdk/v1/ws — reconnect #1 in 1.0s",
            "the count starts over after a ready"
        )
    }

    func testAnExpiredTokenIsHandedToTheOwnerAndNotDialedAgainMeanwhile() async {
        let h = Harness()
        h.link.open(token: "st_old")
        h.sockets.last?.report(.ended(expired))
        await waitUntil { h.log.lines.count == 1 }
        XCTAssertEqual(h.owner.expiryAsks, 1)
        XCTAssertEqual(h.sockets.count, 1, "the dead token is not dialed again while the owner renews")
        XCTAssertEqual(
            h.log.lines.last,
            "socket closed 4401 at /api/sdk/v1/ws — waiting for a new session, reconnect #1 in 1.0s"
        )
        XCTAssertEqual(h.link.state, .reconnecting)

        // The owner renewed the session and opens the link with the new token.
        h.link.open(token: "st_new", reopen: true)
        XCTAssertEqual(h.sockets.count, 2)
        XCTAssertEqual(h.sockets.tokens, ["st_old", "st_new"])
        // The 4401 socket already ended on its own (wire and ping gone), as on Android: it is
        // dropped, never dialed again, and nothing it still reports counts.
        XCTAssertEqual(h.sockets.all[0].connects, 1, "the dead token's socket is not dialed again")
        XCTAssertEqual(h.link.state, .connecting, "a new token is a first dial again")

        // The retry that was pending no longer counts.
        await h.release()
        await settle()
        XCTAssertEqual(h.owner.expiryAsks, 1)
        XCTAssertEqual(h.sockets.count, 2)
        XCTAssertFalse(h.log.joined.contains("st_"))
    }

    func testAnExpiredTokenIsAskedAgainAtBackoffSpeedUntilTheSessionIsRenewed() async {
        let h = Harness()
        h.link.open(token: "st_old")
        h.sockets.last?.report(.ended(expired))
        await waitUntil { h.log.lines.count == 1 }
        XCTAssertEqual(h.owner.expiryAsks, 1)

        // The renewal has not come through: the retry asks again, once per backoff.
        await h.release()
        await waitUntil { h.owner.expiryAsks == 2 }
        await waitUntil { h.sockets.count == 2 }
        XCTAssertEqual(h.link.state, .reconnecting)

        h.link.close()
        XCTAssertEqual(h.link.state, .stopped)
        XCTAssertTrue(h.sockets.all[1].isClosed)

        // What the replaced socket reports from here on changes nothing.
        h.sockets.all[1].report(.ended(expired))
        await settle()
        XCTAssertEqual(h.owner.expiryAsks, 2)
        XCTAssertEqual(h.sockets.count, 2)
    }

    func testAChatWithoutARealtimeSocketIsGivenUpOn() async {
        let h = Harness()
        h.link.open(token: "st_1")
        h.sockets.last?.report(.ended(unavailable))
        await waitUntil { h.link.state == .stopped }
        XCTAssertEqual(h.log.lines, ["socket closed 4404 at /api/sdk/v1/ws — this chat has no realtime socket"])
        let waits = await h.sleeps.waits
        XCTAssertTrue(waits.isEmpty)
        XCTAssertEqual(h.sockets.count, 1)
    }

    func testClosingCancelsThePendingRetry() async {
        let h = Harness()
        h.link.open(token: "st_1")
        h.sockets.last?.report(.ended(dropped))
        await waitUntil { h.log.lines.count == 1 }

        h.link.close()
        XCTAssertEqual(h.link.state, .stopped)
        await h.release()
        await settle()
        XCTAssertEqual(h.sockets.count, 1)
        XCTAssertEqual(h.owner.expiryAsks, 0)
    }

    func testReopeningReplacesTheSocketAndTheOldOneNoLongerCounts() async {
        let h = Harness()
        h.link.open(token: "st_1")
        let first = h.sockets.last
        h.link.open(token: "st_1", reopen: true)
        XCTAssertEqual(h.sockets.count, 2)
        XCTAssertTrue(first?.isClosed == true)

        first?.report(.ready)
        first?.report(.ended(dropped))
        await settle()
        XCTAssertEqual(h.link.state, .connecting)
        XCTAssertTrue(h.owner.reads.isEmpty)
        XCTAssertEqual(h.log.lines.count, 0, "a replaced socket's end is not a drop")
        let waits = await h.sleeps.waits
        XCTAssertTrue(waits.isEmpty, "a replaced socket's end schedules no retry")

        h.sockets.last?.report(.ready)
        await waitUntil { h.owner.reads.count == 1 }
        XCTAssertEqual(h.link.state, .connected)
    }

    func testOpeningAgainKeepsASocketThatIsStillOpen() async {
        let h = Harness()
        h.link.open(token: "st_1")
        h.link.open(token: "st_1")
        XCTAssertEqual(h.sockets.count, 1)

        // Another token replaces it.
        h.link.open(token: "st_2")
        XCTAssertEqual(h.sockets.count, 2)
        XCTAssertEqual(h.sockets.tokens.last, "st_2")
        XCTAssertTrue(h.sockets.all[0].isClosed)

        // So does an open whose socket is gone, even with the same token.
        h.sockets.last?.report(.ended(dropped))
        await waitUntil { h.log.lines.count == 1 }
        h.link.open(token: "st_2")
        XCTAssertEqual(h.sockets.count, 3)
        XCTAssertEqual(h.link.state, .connecting, "an explicit open is a first dial, not a retry")
    }

    func testFramesAreForwardedToTheOwner() async {
        let h = Harness()
        h.link.open(token: "st_1")
        let socket = h.sockets.last
        socket?.report(.created(message("m_1")))
        socket?.report(.updated(message("m_1")))
        socket?.report(.typing(true, "Budi"))
        await waitUntil { h.owner.typings.count == 1 }
        XCTAssertEqual(h.owner.created.map { $0.id }, ["m_1"])
        XCTAssertEqual(h.owner.updated.map { $0.id }, ["m_1"])
        XCTAssertEqual(h.owner.typings.first?.typing, true)
        XCTAssertEqual(h.owner.typings.first?.name, "Budi")
    }

    func testAFailedLineIsLoggedWithItsNetworkCode() async {
        let h = Harness()
        h.link.open(token: "st_1")
        let lost = VisitorSocket.End(code: 0, httpStatus: nil, networkCode: -1005, wasOpen: true)
        h.sockets.last?.report(.ended(lost))
        await waitUntil { h.log.lines.count == 1 }
        XCTAssertEqual(h.log.lines.last, "socket connection lost (URLError -1005) at /api/sdk/v1/ws — reconnect #1 in 1.0s")

        // A refused upgrade the system reported no status for.
        await h.release()
        await waitUntil { h.sockets.count == 2 }
        let unreported = VisitorSocket.End(code: 0, httpStatus: nil, networkCode: -1011, wasOpen: false)
        h.sockets.last?.report(.ended(unreported))
        await waitUntil { h.log.lines.count == 2 }
        XCTAssertEqual(h.log.lines.last, "socket handshake refused (URLError -1011) at /api/sdk/v1/ws — reconnect #2 in 2.0s")
    }

    func testALineThatWentSilentIsReconnectedAndCaughtUpLikeADrop() async {
        let h = Harness()
        h.link.open(token: "st_1")
        h.sockets.last?.report(.ready)
        let silent = VisitorSocket.End(code: 0, httpStatus: nil, networkCode: nil, wasOpen: true, silent: true)
        h.sockets.last?.report(.ended(silent))
        await waitUntil { h.log.lines.count == 1 }
        XCTAssertEqual(h.link.state, .reconnecting)
        XCTAssertEqual(h.log.lines.last, "socket connection lost (no pong to 2 pings) at /api/sdk/v1/ws — reconnect #1 in 1.0s")

        await h.release()
        await waitUntil { h.sockets.count == 2 }
        h.sockets.last?.report(.ready)
        await waitUntil { h.owner.reads.count == 2 }
        XCTAssertEqual(h.owner.reads, [false, true], "what arrived while the line was dead is fetched")
        XCTAssertEqual(h.link.state, .connected)
    }

    func testAnAddressThatIsNotAWebSocketUrlIsNotDialed() {
        let h = Harness(wsUrl: "chat.invalid/api/sdk/v1/ws")
        h.link.open(token: "st_1")
        XCTAssertEqual(h.sockets.count, 0)
        XCTAssertEqual(h.link.state, .stopped)
        XCTAssertEqual(h.log.lines, ["socket not opened: invalid_url"])
    }

    func testBackoffGrowsFromOneSecondToThirty() {
        XCTAssertEqual(RealtimePolicy.backoffDelay(retry: 0), 1)
        XCTAssertEqual(RealtimePolicy.backoffDelay(retry: 1), 2)
        XCTAssertEqual(RealtimePolicy.backoffDelay(retry: 4), 16)
        XCTAssertEqual(RealtimePolicy.backoffDelay(retry: 5), 30)
        XCTAssertEqual(RealtimePolicy.backoffDelay(retry: 40), 30)
        XCTAssertEqual(RealtimePolicy.backoffDelay(retry: -3), 1)
        XCTAssertEqual(RealtimePolicy.backoffDelay(retry: 9, jitter: 0.5), 30.5)
        XCTAssertEqual(RealtimePolicy.backoffDelay(retry: 2, jitter: 0.25), 4.25)
    }

    func testTheSocketAddressIsTheApiHostWithTheTokenAsItsOnlyQueryValue() {
        let api = SdkApiURLSession(baseUrl: "https://api.nara.ai.id/api")
        XCTAssertEqual(api.wsUrl, "wss://api.nara.ai.id/api/sdk/v1/ws")
        XCTAssertEqual(SdkApiURLSession(baseUrl: "https://api.nara.ai.id/api/").wsUrl, api.wsUrl)
        XCTAssertEqual(SdkApiURLSession(baseUrl: "http://10.0.2.2:3000/api").wsUrl, "ws://10.0.2.2:3000/api/sdk/v1/ws")
        XCTAssertEqual(SdkApiURLSession(baseUrl: NaraChat.defaultBaseUrl).wsUrl, api.wsUrl)
        XCTAssertEqual(SdkApiURLSession(baseUrl: "https://api.narachat.com/api").wsUrl, "wss://api.narachat.com/api/sdk/v1/ws")

        let url = SdkApiURLSession.socketUrl(wsUrl: api.wsUrl, token: "st_abc123")
        XCTAssertEqual(url?.absoluteString, "wss://api.nara.ai.id/api/sdk/v1/ws?token=st_abc123")
        XCTAssertEqual(SdkApiURLSession.socketPath(wsUrl: api.wsUrl), "/api/sdk/v1/ws")
        XCTAssertEqual(SdkApiURLSession.socketPath(wsUrl: "wss://api.narachat.com/api/sdk/v1/ws"), "/api/sdk/v1/ws")

        XCTAssertNil(SdkApiURLSession.socketUrl(wsUrl: "https://api.nara.ai.id/api/sdk/v1/ws", token: "st_1"))
        XCTAssertNil(SdkApiURLSession.socketUrl(wsUrl: "api.nara.ai.id/api/sdk/v1/ws", token: "st_1"))
        XCTAssertEqual(SdkApiURLSession.socketPath(wsUrl: "not a url"), "/sdk/v1/ws")
    }
}
