import XCTest
@testable import NaraLiveChat

/// Collects the diagnostic lines the SDK writes while a test runs.
private final class LogSpy {
    var lines: [String] = []
    func take(_ line: String) { lines.append(line) }
}

/// A successful status whose body is not the JSON the endpoint promised (a web page, an
/// empty or cut-off body, a missing field) leaves the SDK as `bad_response` — never a bare
/// `DecodingError` — and the body never reaches a log line.
final class SdkBadResponseTests: XCTestCase {

    private static let html = "<html><head><title>Attention Required!</title></head><body>WAF-BLOCKED-PAGE-MARKER</body></html>"

    private let spy = LogSpy()

    override func setUp() {
        super.setUp()
        StubURLProtocol.response = (200, Self.html)
        StubURLProtocol.contentType = "text/html"
    }

    override func tearDown() {
        StubURLProtocol.response = (200, "{}")
        StubURLProtocol.contentType = "application/json"
        super.tearDown()
    }

    private func api() -> SdkApiURLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return SdkApiURLSession(
            baseUrl: "https://stub.invalid/api",
            session: URLSession(configuration: config),
            log: spy.take
        )
    }

    /// The error `block` threw, whatever its type — a bare `DecodingError` would show up here.
    private func thrown(_ block: () async throws -> Void) async -> Error? {
        do {
            try await block()
            return nil
        } catch {
            return error
        }
    }

    /// Asserts the call failed as `bad_response` with the status it was answered with, and wrote
    /// exactly one diagnostic line.
    private func assertBad(
        status: Int, file: StaticString = #filePath, line: UInt = #line,
        _ call: () async throws -> Void
    ) async {
        let before = spy.lines.count
        let error = await thrown(call)
        guard let error else {
            XCTFail("the call succeeded on an unreadable body", file: file, line: line)
            return
        }
        XCTAssertEqual(
            error as? SdkError, SdkError.badResponse(status: status),
            "got \(error)", file: file, line: line
        )
        XCTAssertEqual(spy.lines.count - before, 1, "one diagnostic line per unreadable answer", file: file, line: line)
    }

    func testHtmlWithStatus200OnTheSessionPathIsBadResponse() async throws {
        let error = await thrown {
            _ = try await self.api().createSession(
                appKey: "nk_x", bundleId: "com.example.app", token: nil, login: nil, setUser: nil, page: nil
            )
        }
        XCTAssertEqual(error as? SdkError, SdkError.badResponse(status: 200))
        XCTAssertEqual(friendlyError(error, isId: true), "Ada yang salah. Coba lagi nanti.")

        let entry = try XCTUnwrap(spy.lines.first)
        XCTAssertTrue(entry.contains("POST /api/sdk/v1/session"))
        XCTAssertTrue(entry.contains("HTTP 200"))
        XCTAssertTrue(entry.contains("text/html"))
        XCTAssertTrue(entry.contains("\(Self.html.utf8.count) bytes"))
        XCTAssertFalse(entry.contains("WAF-BLOCKED-PAGE-MARKER"), "the body reached the log")
    }

    func testEmptyBodyIsBadResponse() async throws {
        StubURLProtocol.response = (200, "")
        await assertBad(status: 200) {
            _ = try await self.api().createSession(
                appKey: "nk_x", bundleId: "com.example.app", token: nil, login: nil, setUser: nil, page: nil
            )
        }
        XCTAssertTrue(try XCTUnwrap(spy.lines.first).contains("0 bytes"))
    }

    func testTruncatedJsonIsBadResponse() async {
        StubURLProtocol.contentType = "application/json"
        StubURLProtocol.response = (200, #"{"token":"st_abc","expiresAt":"2030-01-01T00:00:00Z""#)
        await assertBad(status: 200) {
            _ = try await self.api().createSession(
                appKey: "nk_x", bundleId: "com.example.app", token: nil, login: nil, setUser: nil, page: nil
            )
        }
    }

    func testMissingRequiredFieldIsBadResponse() async {
        StubURLProtocol.contentType = "application/json"
        StubURLProtocol.response = (200, "{}")
        await assertBad(status: 200) {
            _ = try await self.api().createSession(
                appKey: "nk_x", bundleId: "com.example.app", token: nil, login: nil, setUser: nil, page: nil
            )
        }
    }

    func testEveryJsonEndpointIsCovered() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("k297-upload.bin")
        try Data([0x00, 0x01, 0x02]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        StubURLProtocol.response = (201, Self.html)
        await assertBad(status: 201) { _ = try await self.api().sendMessage(token: "tok", text: "hai", clientId: "c1") }
        await assertBad(status: 201) {
            _ = try await self.api().upload(
                token: "tok", fileURL: file, fileName: "a.bin", mime: "application/octet-stream", caption: nil, clientId: "c2"
            )
        }

        StubURLProtocol.response = (200, Self.html)
        await assertBad(status: 200) { _ = try await self.api().messages(token: "tok", before: "m_1", limit: 20) }
        await assertBad(status: 200) { _ = try await self.api().unread(token: "tok") }
        await assertBad(status: 200) { _ = try await self.api().helpOverview(appKey: "nk_x") }
        await assertBad(status: 200) { _ = try await self.api().helpSearch(appKey: "nk_x", query: "jam") }
        await assertBad(status: 200) { _ = try await self.api().helpArticle(appKey: "nk_x", slug: "cara-chat") }
        await assertBad(status: 200) { _ = try await self.api().registerDeviceToken(token: "tok", platform: "ios", deviceToken: "apns-1") }
        await assertBad(status: 200) {
            _ = try await self.api().initSdk(appKey: "nk_x", platform: "ios", bundleId: "com.example.app", sdkVersion: "1.0.0")
        }

        // Method and path only: a query string may carry a key or a token.
        let joined = spy.lines.joined(separator: "\n")
        XCTAssertTrue(joined.contains("GET /api/sdk/v1/messages"))
        XCTAssertFalse(joined.contains("?"))
        XCTAssertFalse(joined.contains("nk_x"))
        XCTAssertFalse(joined.contains("before=m_1"))
    }

    func test204WithoutABodyStillSucceeds() async {
        StubURLProtocol.response = (204, "")
        let api = api()
        let calls: [() async throws -> Void] = [
            { try await api.markRead(token: "tok", upToMessageId: "m_1") },
            { try await api.deleteDeviceToken(token: "tok", deviceToken: "apns-1") },
        ]
        for call in calls {
            do {
                try await call()
            } catch {
                XCTFail("an empty 204 is a success, got \(error)")
            }
        }
        XCTAssertTrue(spy.lines.isEmpty)
    }

    func testBadResponseReadsAsTheGenericMessage() {
        let e = SdkError.badResponse(status: 200)
        XCTAssertEqual(e.apiCode, "bad_response")
        XCTAssertEqual(e.httpStatus, 200)
        XCTAssertEqual(friendlyError(e, isId: true), "Ada yang salah. Coba lagi nanti.")
        XCTAssertEqual(friendlyError(e, isId: false), "Something went wrong. Please try again later.")
    }

    func testInitDiagnosticsKeepTheStatusAndTheHint() {
        let e = SdkInitError.from(
            SdkError.badResponse(status: 200),
            url: "https://api.nara.ai.id/api/sdk/v1/init", appKey: "nk_x"
        )
        XCTAssertEqual(e.summary, "HTTP 200 · bad_response")
        XCTAssertTrue(e.hint?.contains("bukan JSON") == true)
    }
}
