import XCTest
@testable import NaraLiveChat

/// The wire under the socket in these tests: the test decides what comes back.
private final class FakeWire: SocketWire {
    private let lock = NSLock()
    private var frames: [Result<String, Error>] = []
    private var waiting: ((Result<String, Error>) -> Void)?
    private(set) var sent: [String] = []
    private(set) var isCancelled = false
    var closeCode = 0
    /// What the system's task would still hold in `response`.
    var httpStatus: Int?

    /// How many reads the socket has asked for so far.
    var reads: Int {
        lock.lock()
        defer { lock.unlock() }
        return readCount
    }
    private var readCount = 0

    func receive(_ completion: @escaping (Result<String, Error>) -> Void) {
        lock.lock()
        readCount += 1
        if !frames.isEmpty {
            let frame = frames.removeFirst()
            lock.unlock()
            completion(frame)
            return
        }
        waiting = completion
        lock.unlock()
    }

    /// Queues `frame`, or answers the read that is waiting for it.
    func deliver(_ frame: Result<String, Error>) {
        lock.lock()
        let handler = waiting
        waiting = nil
        if handler == nil { frames.append(frame) }
        lock.unlock()
        handler?(frame)
    }

    func send(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        sent.append(text)
    }

    /// Like `URLSessionWebSocketTask.cancel`: the read that is waiting ends with an error.
    func cancel() {
        lock.lock()
        isCancelled = true
        let handler = waiting
        waiting = nil
        lock.unlock()
        handler?(.failure(URLError(.cancelled)))
    }

    /// True while the socket is waiting for a frame.
    var isReading: Bool {
        lock.lock()
        defer { lock.unlock() }
        return waiting != nil
    }
}

/// Stands in for the ping timer: every timer the socket starts is fired by hand here.
private final class PingClock {
    private let lock = NSLock()
    private let onSchedule: XCTestExpectation
    private var tick: (() -> Void)?
    private(set) var intervals: [TimeInterval] = []
    private(set) var stopped = false

    init(onSchedule: XCTestExpectation) {
        self.onSchedule = onSchedule
    }

    /// Hand this to the socket as its `scheduler`.
    var schedule: VisitorSocket.Scheduler {
        { [self] interval, fire in
            lock.lock()
            intervals.append(interval)
            tick = fire
            stopped = false
            lock.unlock()
            onSchedule.fulfill()
            return { [self] in
                lock.lock()
                tick = nil
                stopped = true
                lock.unlock()
            }
        }
    }

    /// Runs the ping as the timer would.
    func fireThePing() {
        lock.lock()
        let tick = self.tick
        lock.unlock()
        tick?()
    }
}

/// Gets what the socket reports.
private final class Recorder: VisitorSocket.Listener {
    private let lock = NSLock()
    private(set) var readyCount = 0
    private(set) var created: [ChatMessage] = []
    private(set) var updated: [ChatMessage] = []
    private(set) var typings: [(typing: Bool, name: String?)] = []
    private(set) var ends: [VisitorSocket.End] = []
    private var next: XCTestExpectation?

    /// Fulfilled — and cleared — by the next callback.
    func arm(_ expectation: XCTestExpectation) {
        lock.lock()
        defer { lock.unlock() }
        next = expectation
    }

    func onSocketReady() { readyCount += 1; note() }
    func onMessageCreated(_ message: ChatMessage) { created.append(message); note() }
    func onMessageUpdated(_ message: ChatMessage) { updated.append(message); note() }
    func onTyping(typing: Bool, name: String?) { typings.append((typing, name)); note() }
    func onSocketEnded(_ end: VisitorSocket.End) { ends.append(end); note() }

    private func note() {
        lock.lock()
        let expectation = next
        next = nil
        lock.unlock()
        expectation?.fulfill()
    }
}

/// One visitor socket over a wire the test controls.
final class VisitorSocketTests: XCTestCase {
    private let address = "wss://chat.invalid/api/sdk/v1/ws?token=st_x"
    private var socket: VisitorSocket!
    private var wire: FakeWire!
    private var clock: PingClock!
    private var recorder: Recorder!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let wired = expectation(description: "socket wired")
        let wire = FakeWire()
        let clock = PingClock(onSchedule: wired)
        let recorder = Recorder()
        self.wire = wire
        self.clock = clock
        self.recorder = recorder
        socket = VisitorSocket(
            url: try XCTUnwrap(URL(string: address)),
            listener: recorder,
            pingInterval: 25,
            openWire: { _ in wire },
            scheduler: clock.schedule
        )
        socket.connect()
        wait(for: [wired], timeout: 1)
    }

    override func tearDown() {
        socket.close()
        super.tearDown()
    }

    /// Delivers `frame` and waits until the socket has handled it.
    private func deliver(_ frame: String, handledAs description: String) {
        let handled = expectation(description: description)
        recorder.arm(handled)
        wire.deliver(.success(frame))
        wait(for: [handled], timeout: 1)
    }

    /// Delivers a frame the socket answers with nothing, then waits until it reads again.
    private func deliverIgnored(_ frame: String) {
        let before = wire.reads
        wire.deliver(.success(frame))
        // Handled once the socket asked for the next frame and waits for it.
        eventually { self.wire.reads > before && self.wire.isReading }
    }

    /// Polls until `condition` holds.
    private func eventually(
        timeout: TimeInterval = 2, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out waiting for the condition", file: file, line: line)
                return
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    /// Runs the ping timer once and waits until the ping of that tick is on the wire.
    private func fireOnePing(sent count: Int) {
        clock.fireThePing()
        eventually { self.wire.sent.count == count }
    }

    /// Waits for the socket to give its line up.
    private func fireTheLastPing() {
        let ended = expectation(description: "ended")
        recorder.arm(ended)
        clock.fireThePing()
        wait(for: [ended], timeout: 1)
        XCTAssertEqual(recorder.ends.count, 1, "the line is given up once")
    }

    private func sentPayload(at index: Int) throws -> [String: Any] {
        let text = try XCTUnwrap(wire.sent.count > index ? wire.sent[index] : nil)
        let data = try XCTUnwrap(text.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testItPingsEveryTwentyFiveSeconds() {
        XCTAssertEqual(clock.intervals, [25])
        XCTAssertTrue(wire.sent.isEmpty, "nothing is sent before the first ping")

        fireOnePing(sent: 1)
        XCTAssertEqual(wire.sent, [#"{"type":"ping"}"#])

        fireOnePing(sent: 2)
        XCTAssertEqual(recorder.readyCount, 0, "a ping is not a server event")
        XCTAssertTrue(recorder.ends.isEmpty, "two pings in a row are still tolerated")
    }

    func testALineThatAnswersNothingIsCutByTheSocketItself() {
        deliver(#"{"type":"ready"}"#, handledAs: "ready")
        fireOnePing(sent: 1)
        fireOnePing(sent: 2)

        fireTheLastPing()
        XCTAssertEqual(
            recorder.ends,
            [VisitorSocket.End(code: 0, httpStatus: nil, networkCode: nil, wasOpen: true, silent: true)]
        )
        XCTAssertEqual(recorder.ends.first?.handshakeRefused, false, "the socket was up before the line died")
        XCTAssertEqual(wire.sent.count, 2, "no ping goes out with the tick that gives up")
        eventually { self.wire.isCancelled }
        XCTAssertFalse(wire.isReading, "a dead socket reads no further")
        XCTAssertTrue(clock.stopped, "the ping stops with the socket")
    }

    func testAnythingTheServerSendsCountsAsAnAnswer() {
        deliver(#"{"type":"ready"}"#, handledAs: "ready")
        fireOnePing(sent: 1)
        fireOnePing(sent: 2)
        deliverIgnored(#"{"type":"pong"}"#)
        fireOnePing(sent: 3)
        fireOnePing(sent: 4)
        deliver(#"{"type":"typing","data":{"typing":false}}"#, handledAs: "typing")
        fireOnePing(sent: 5)
        fireOnePing(sent: 6)
        XCTAssertTrue(recorder.ends.isEmpty, "every frame from the server starts the count over")

        fireTheLastPing()
        XCTAssertEqual(wire.sent.count, 6)
        XCTAssertEqual(recorder.typings.count, 1)
    }

    func testASocketThatNeverHeardTheServerIsCutTheSameWay() {
        fireOnePing(sent: 1)
        fireOnePing(sent: 2)

        fireTheLastPing()
        XCTAssertEqual(
            recorder.ends,
            [VisitorSocket.End(code: 0, httpStatus: nil, networkCode: nil, wasOpen: false, silent: true)]
        )
        XCTAssertEqual(recorder.ends.first?.handshakeRefused, true)
    }

    /// A scheduler for a test's extra sockets: no timer at all.
    private static let noPings: VisitorSocket.Scheduler = { _, _ in return {} }

    /// Opens one more socket over a wire whose task holds `httpStatus`, ends it with `error`, and
    /// returns what the socket reported.
    private func endOfOneMoreSocket(taskHolding httpStatus: Int?, failure error: Error) throws -> VisitorSocket.End? {
        let fresh = FakeWire()
        fresh.httpStatus = httpStatus
        let one = VisitorSocket(
            url: try XCTUnwrap(URL(string: address)),
            listener: recorder,
            pingInterval: 25,
            openWire: { _ in fresh },
            scheduler: Self.noPings
        )
        one.connect()
        eventually { fresh.isReading }
        let ended = expectation(description: "ended")
        recorder.arm(ended)
        fresh.deliver(.failure(error))
        wait(for: [ended], timeout: 1)
        return recorder.ends.last
    }

    func testTheStatusOfARefusalIsReadFromTheErrorOrFromTheTask() throws {
        let response = try XCTUnwrap(HTTPURLResponse(
            url: try XCTUnwrap(URL(string: address)), statusCode: 404, httpVersion: nil, headerFields: nil
        ))
        let current = NSError(
            domain: NSURLErrorDomain, code: NSURLErrorBadServerResponse,
            userInfo: ["NSErrorFailingURLResponseKey": response]
        )
        let older = NSError(
            domain: NSURLErrorDomain, code: NSURLErrorBadServerResponse,
            userInfo: ["NSURLErrorFailingURLSessionResponseErrorKey": response]
        )

        XCTAssertEqual(try endOfOneMoreSocket(taskHolding: 503, failure: current)?.httpStatus, 404, "the error's status wins")
        XCTAssertEqual(try endOfOneMoreSocket(taskHolding: nil, failure: older)?.httpStatus, 404, "the older spelling too")

        // The error carries none: what the task still holds stands in.
        XCTAssertEqual(
            try endOfOneMoreSocket(taskHolding: 503, failure: URLError(.badServerResponse)),
            VisitorSocket.End(code: 0, httpStatus: 503, networkCode: -1011, wasOpen: false)
        )
    }

    func testAStatusTheTaskHoldsIsNoRefusalOnceTheUpgradeWentThrough() throws {
        // 101 is what the task holds after an upgrade that went through.
        let upgraded = try XCTUnwrap(endOfOneMoreSocket(taskHolding: 101, failure: URLError(.networkConnectionLost)))
        XCTAssertEqual(upgraded, VisitorSocket.End(code: 0, httpStatus: nil, networkCode: -1005, wasOpen: false))

        // After frames came through the line was up, whatever the task holds.
        let fresh = FakeWire()
        fresh.httpStatus = 502
        let up = VisitorSocket(
            url: try XCTUnwrap(URL(string: address)),
            listener: recorder,
            pingInterval: 25,
            openWire: { _ in fresh },
            scheduler: Self.noPings
        )
        up.connect()
        eventually { fresh.isReading }
        fresh.deliver(.success(#"{"type":"ready"}"#))
        eventually { self.recorder.readyCount == 1 }
        let ended = expectation(description: "ended")
        recorder.arm(ended)
        fresh.deliver(.failure(URLError(.networkConnectionLost)))
        wait(for: [ended], timeout: 1)
        XCTAssertEqual(recorder.ends.last, VisitorSocket.End(code: 0, httpStatus: nil, networkCode: -1005, wasOpen: true))
        up.close()
    }

    func testItDecodesTheFramesTheServerSends() {
        deliver(#"{"type":"ready"}"#, handledAs: "ready")
        XCTAssertEqual(recorder.readyCount, 1)

        deliver(
            #"{"type":"message.created","data":{"id":"m_1","clientId":null,"from":"agent","senderName":"Budi","type":"text","body":"Halo","status":"sent","sentAt":"2026-11-23T10:00:00.000Z","media":null,"quoted":null}}"#,
            handledAs: "message.created"
        )
        XCTAssertEqual(recorder.created.map(\.id), ["m_1"])
        XCTAssertEqual(recorder.created.first?.body, "Halo")
        XCTAssertEqual(recorder.created.first?.senderName, "Budi")
        XCTAssertEqual(recorder.created.first?.isTeam, true)

        deliver(
            #"{"type":"message.updated","data":{"id":"m_1","from":"agent","senderName":"Budi","type":"text","body":"Halo","status":"read","sentAt":"2026-11-23T10:00:00.000Z"}}"#,
            handledAs: "message.updated"
        )
        XCTAssertEqual(recorder.updated.map(\.status), ["read"])

        deliver(#"{"type":"agent.typing","data":{"typing":true,"name":"Budi"}}"#, handledAs: "agent.typing")
        XCTAssertEqual(recorder.typings.count, 1)
        XCTAssertEqual(recorder.typings.first?.typing, true)
        XCTAssertEqual(recorder.typings.first?.name, "Budi")
        XCTAssertTrue(recorder.ends.isEmpty, "handling a frame does not end the socket")
    }

    func testAFrameItCannotReadIsSkipped() {
        deliverIgnored("not json")
        deliverIgnored(#"{"type":"something.new","data":{}}"#)
        deliverIgnored(#"{"type":"message.created"}"#)
        deliverIgnored(#"{"type":"message.created","data":{"body":"no id here"}}"#)  // as on Android: only the id is required

        // The socket is still reading what comes after.
        deliver(#"{"type":"ready"}"#, handledAs: "ready")
        XCTAssertEqual(recorder.readyCount, 1)
        XCTAssertTrue(recorder.created.isEmpty)
        XCTAssertTrue(recorder.ends.isEmpty)
    }

    func testTheOldTypingEventIsStillUnderstood() {
        deliver(#"{"type":"typing","data":{"typing":false}}"#, handledAs: "typing")
        XCTAssertEqual(recorder.typings.count, 1)
        XCTAssertEqual(recorder.typings.first?.typing, false)
        XCTAssertNil(recorder.typings.first?.name)
    }

    func testAMessageOfAnUnknownTypeKeepsItsIdAndGetsTheFallbackText() {
        deliver(
            #"{"type":"message.created","data":{"id":"m_9","from":"agent","senderName":"Budi","type":"video","body":"","status":"sent","sentAt":"2026-11-23T10:00:00.000Z","media":{"url":"https://chat.invalid/v.mp4","mime":"video/mp4"}}}"#,
            handledAs: "message.created"
        )
        let m = recorder.created.first
        XCTAssertEqual(m?.id, "m_9")
        XCTAssertEqual(m?.type, "fallback")
        XCTAssertEqual(m?.body, ChatMessage.fallbackBodyId)
        XCTAssertEqual(m?.media?.url, "https://chat.invalid/v.mp4")
        XCTAssertEqual(m?.isTeam, true)
    }

    func testTheServersCloseCodeIsWhatASocketThatNeverOpenedReports() {
        wire.closeCode = 4401
        let ended = expectation(description: "ended")
        recorder.arm(ended)
        wire.deliver(.failure(URLError(.badServerResponse)))
        wait(for: [ended], timeout: 1)

        XCTAssertEqual(
            recorder.ends,
            [VisitorSocket.End(code: 4401, httpStatus: nil, networkCode: -1011, wasOpen: false)]
        )
        XCTAssertEqual(recorder.ends.first?.handshakeRefused, true)
        XCTAssertFalse(wire.isReading, "a dead socket reads no further")
        XCTAssertTrue(clock.stopped, "the ping stops with the socket")
    }

    func testACloseCodeTheSystemPassesAlongInTheErrorIsUsed() {
        // The system usually hands the close code over in the error, before the task knows it.
        let error = NSError(domain: NSURLErrorDomain, code: 57, userInfo: ["_NSURLErrorWSCloseCodeKey": 4401])
        let ended = expectation(description: "ended")
        recorder.arm(ended)
        wire.deliver(.failure(error))
        wait(for: [ended], timeout: 1)

        XCTAssertEqual(recorder.ends, [VisitorSocket.End(code: 4401, httpStatus: nil, networkCode: 57, wasOpen: false)])
    }

    func testARefusedHandshakeReportsTheHttpStatus() throws {
        let response = try XCTUnwrap(HTTPURLResponse(
            url: try XCTUnwrap(URL(string: address)), statusCode: 404, httpVersion: nil, headerFields: nil
        ))
        let refused = NSError(
            domain: NSURLErrorDomain, code: NSURLErrorBadServerResponse,
            userInfo: ["NSErrorFailingURLResponseKey": response]
        )
        let ended = expectation(description: "ended")
        recorder.arm(ended)
        wire.deliver(.failure(refused))
        wait(for: [ended], timeout: 1)

        XCTAssertEqual(recorder.ends, [VisitorSocket.End(code: 0, httpStatus: 404, networkCode: -1011, wasOpen: false)])
        XCTAssertEqual(recorder.ends.first?.handshakeRefused, true)
    }

    func testALineThatFailsAfterFramesCameThroughWasOpen() {
        deliver(#"{"type":"ready"}"#, handledAs: "ready")
        let ended = expectation(description: "ended")
        recorder.arm(ended)
        wire.deliver(.failure(URLError(.networkConnectionLost)))
        wait(for: [ended], timeout: 1)

        XCTAssertEqual(recorder.ends, [VisitorSocket.End(code: 0, httpStatus: nil, networkCode: -1005, wasOpen: true)])
        XCTAssertEqual(recorder.ends.first?.handshakeRefused, false)
    }

    func testClosingStopsThePingAndNothingElseIsReported() {
        socket.close()
        eventually { self.wire.isCancelled }
        XCTAssertTrue(clock.stopped)
        XCTAssertTrue(recorder.ends.isEmpty)

        // A frame that turns up after the close is not handled.
        wire.deliver(.success(#"{"type":"ready"}"#))
        let nothing = expectation(description: "nothing is reported")
        nothing.isInverted = true
        recorder.arm(nothing)
        wait(for: [nothing], timeout: 0.2)
        XCTAssertEqual(recorder.readyCount, 0)
    }

    func testATypingSignalIsSentAsJson() throws {
        socket.sendTyping(true, draft: "halo")
        eventually { !self.wire.sent.isEmpty }
        let first = try sentPayload(at: 0)
        XCTAssertEqual(first["type"] as? String, "typing")
        XCTAssertEqual(first["typing"] as? Bool, true)
        XCTAssertEqual(first["draft"] as? String, "halo")

        // A long draft is cut; no draft is left out.
        socket.sendTyping(false, draft: String(repeating: "a", count: 250))
        socket.sendTyping(false, draft: nil)
        eventually { self.wire.sent.count == 3 }
        let second = try sentPayload(at: 1)
        XCTAssertEqual(second["typing"] as? Bool, false)
        XCTAssertEqual((second["draft"] as? String)?.count, 200)
        let third = try sentPayload(at: 2)
        XCTAssertEqual(third["typing"] as? Bool, false)
        XCTAssertNil(third["draft"])
    }
}
