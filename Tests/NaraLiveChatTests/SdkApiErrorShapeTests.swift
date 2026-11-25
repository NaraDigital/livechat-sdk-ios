import XCTest
@testable import NaraLiveChat

/// Answers every request with a canned `(status, body)` — no network, but the real
/// `SdkApiURLSession` code path runs end to end.
final class StubURLProtocol: URLProtocol {
    static var response: (status: Int, body: String) = (200, "{}")
    static var contentType = "application/json"
    static var lastPath: String?
    /// The request the last answer was for: method, address and headers.
    static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let canned = Self.response
        Self.lastPath = url.path
        Self.lastRequest = request
        let response = HTTPURLResponse(
            url: url, statusCode: canned.status, httpVersion: nil,
            headerFields: ["Content-Type": Self.contentType]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: canned.body.data(using: .utf8)!)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// The SDK reads the error body the API really sends —
/// `{"error":{"code","message","details"}}` (SDK API v1) — and older flat bodies.
final class SdkApiErrorShapeTests: XCTestCase {

    private func stubApi() -> SdkApiURLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return SdkApiURLSession(
            baseUrl: "https://stub.invalid/api",
            session: URLSession(configuration: config)
        )
    }

    private func stub(_ status: Int, _ body: String) {
        StubURLProtocol.response = (status, body)
    }

    /// Runs `block` and returns the `SdkError` it threw, nil when it threw something else or nothing.
    private func sdkError(_ block: () async throws -> Void) async -> SdkError? {
        do {
            try await block()
            return nil
        } catch let error as SdkError {
            return error
        } catch {
            return nil
        }
    }

    func test428CarriesTheRequiredPrechatFields() async {
        stub(428, #"{"error":{"code":"prechat_required","message":"Prechat required","details":{"required":["name","email"]}}}"#)
        let e = await sdkError { _ = try await self.stubApi().sendMessage(token: "tok", text: "hai", clientId: "c1") }
        XCTAssertEqual(e, .prechatRequired(["name", "email"]))
    }

    func test404RouteNotFoundKeepsItsCode() async {
        // What a baseUrl without the /api prefix gets back.
        stub(404, #"{"error":{"code":"route_not_found","message":"Route not found"}}"#)
        let e = await sdkError {
            _ = try await self.stubApi().initSdk(appKey: "nk_x", platform: "ios", bundleId: "com.example.app", sdkVersion: "1.0.0")
        }
        XCTAssertEqual(e, .http(status: 404, code: "route_not_found"))
        XCTAssertEqual(StubURLProtocol.lastPath, "/api/sdk/v1/init")
    }

    func test403PackageNotAllowedBecomesTheFriendlyMessage() async {
        stub(403, #"{"error":{"code":"sdk_package_not_allowed","message":"Package not allowed","details":{"package":"com.example.app"}}}"#)
        let e = await sdkError {
            _ = try await self.stubApi().initSdk(appKey: "nk_x", platform: "ios", bundleId: "com.example.app", sdkVersion: "1.0.0")
        }
        XCTAssertEqual(e, .packageNotAllowed)
        XCTAssertEqual(friendlyError(e, isId: false), "This app isn't allowed to use live chat yet.")
    }

    func test401VisitorTokenInvalidIsRecognisedSoTheSessionCanRecover() async {
        stub(401, #"{"error":{"code":"visitor_token_invalid","message":"Visitor token invalid"}}"#)
        let e = await sdkError { _ = try await self.stubApi().messages(token: "stale", before: nil, limit: 20) }
        XCTAssertEqual(e, .visitorTokenInvalid)
    }

    func test429KeepsCodeAndStatus() async {
        stub(429, #"{"error":{"code":"too_many_requests","message":"Too many requests","details":{"retryAfterSeconds":30}}}"#)
        let e = await sdkError { _ = try await self.stubApi().sendMessage(token: "tok", text: "hai", clientId: "c1") }
        XCTAssertEqual(e, .http(status: 429, code: "too_many_requests"))
        XCTAssertEqual(friendlyError(e, isId: true), "Terlalu banyak percobaan. Tunggu sebentar ya.")
    }

    func testLegacyFlatBodiesStillParse() {
        let flat = #"{"code":"not_found","message":"Widget not found"}"#.data(using: .utf8)!
        XCTAssertEqual(SdkError.from(status: 404, body: flat), .notFound)
        let bare = #"{"error":"prechat_required","details":{"required":["email"]}}"#.data(using: .utf8)!
        XCTAssertEqual(SdkError.from(status: 428, body: bare), .prechatRequired(["email"]))
    }

    func testNonJsonBodyFallsBackToTheHttpStatus() {
        // A web page answering instead of the API (wrong baseUrl) must not become a JSON-looking code.
        let html = Data("<html><body>404 Not Found</body></html>".utf8)
        XCTAssertEqual(SdkError.from(status: 404, body: html), .http(status: 404, code: "http_404"))
    }

    /// The device token goes as a query value, authorized by the session that bound it.
    func testDeviceTokenIsUnboundByDeleteWithTheTokenOfTheSessionThatBoundIt() async throws {
        stub(204, "")
        try await stubApi().deleteDeviceToken(token: "tok-old", deviceToken: "fcm token/1")
        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(url.path, "/api/sdk/v1/device-token")
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query, [URLQueryItem(name: "token", value: "fcm token/1")])
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok-old")
    }

    func testDefaultBaseUrlIsTheApiHostWithTheApiPrefix() {
        XCTAssertEqual(NaraChat.defaultBaseUrl, "https://api.nara.ai.id/api")
        XCTAssertEqual(NaraChat.shared.baseUrl, NaraChat.defaultBaseUrl)
        // The SDK calls <baseUrl>/sdk/v1, so the default lands on https://api.nara.ai.id/api/sdk/v1/….
        XCTAssertEqual(SdkApiURLSession(baseUrl: NaraChat.defaultBaseUrl).baseUrl, "https://api.nara.ai.id/api")
    }
}

/// Developer diagnostics for a failed init — useful, and never carrying the full appKey.
final class SdkInitErrorTests: XCTestCase {

    private let url = "https://api.nara.ai.id/api/sdk/v1/init"
    private let appKey = "nk_secret_key_abcd1234"

    func test404NotFoundPointsAtAppKeyAndBaseUrl() {
        let e = SdkInitError.from(SdkError.http(status: 404, code: "not_found"), url: url, appKey: appKey)
        XCTAssertEqual(e.status, 404)
        XCTAssertEqual(e.url, url)
        XCTAssertEqual(e.summary, "HTTP 404 · not_found")
        XCTAssertEqual(e.hint, "cek appKey & baseUrl (contoh https://api.nara.ai.id/api)")
        XCTAssertEqual(
            e.logLine,
            "init failed — POST \(url) → HTTP 404 · not_found · appKey …1234 · " +
                "cek appKey & baseUrl (contoh https://api.nara.ai.id/api)"
        )
    }

    func test404RouteNotFoundExplainsTheMissingApiPrefix() {
        let e = SdkInitError.from(SdkError.http(status: 404, code: "route_not_found"), url: url, appKey: appKey)
        XCTAssertEqual(e.code, "route_not_found")
        XCTAssertTrue(e.hint?.hasPrefix("cek appKey & baseUrl (contoh https://api.nara.ai.id/api)") == true)
        XCTAssertTrue(e.hint?.contains("diakhiri /api") == true)
    }

    func testNamedCodesCarryTheirStatusAndHint() {
        let allow = SdkInitError.from(SdkError.packageNotAllowed, url: url, appKey: appKey)
        XCTAssertEqual(allow.summary, "HTTP 403 · sdk_package_not_allowed")
        XCTAssertTrue(allow.hint?.contains("bundle id") == true)

        let net = SdkInitError.from(SdkError.network(nil), url: url, appKey: appKey)
        XCTAssertEqual(net.status, 0)
        XCTAssertEqual(net.summary, "network_error")
        XCTAssertTrue(net.hint?.contains("koneksi internet") == true)

        XCTAssertNil(SdkInitError.from(SdkError.http(status: 500, code: "internal_error"), url: url, appKey: appKey).hint)
    }

    func testNonSdkFailuresAreClassified() throws {
        struct NotJson: Error {}
        let other = SdkInitError.from(NotJson(), url: url, appKey: appKey)
        XCTAssertEqual(other.status, 0)
        XCTAssertEqual(other.code, "NotJson")
        XCTAssertNil(other.hint)

        // A web page answering with 200 instead of the API's JSON config fails decoding.
        var caught: Error?
        do {
            _ = try JSONDecoder().decode(WidgetConfig.self, from: Data("<html><body>Not found</body></html>".utf8))
        } catch {
            caught = error
        }
        let html = SdkInitError.from(try XCTUnwrap(caught), url: url, appKey: appKey)
        XCTAssertEqual(html.code, "DecodingError")
        XCTAssertTrue(html.hint?.contains("bukan JSON") == true)
    }

    func testAppKeyNeverAppearsInFullOnlyItsLastFourCharacters() {
        for secret in [appKey, "nk_a", "nk_ab", "abcdefgh"] {
            let line = SdkInitError.from(SdkError.notFound, url: url, appKey: secret).logLine
            XCTAssertFalse(line.contains(secret), "full appKey leaked: \(line)")
        }
        XCTAssertEqual(SdkInitError.mask(appKey), "…1234")
        XCTAssertEqual(SdkInitError.mask("nk_ab"), "…k_ab")
        XCTAssertEqual(SdkInitError.mask("nk_a"), "…") // 4 characters or fewer: nothing is shown
        XCTAssertEqual(SdkInitError.mask(""), "…")
        XCTAssertEqual(SdkInitError.mask(nil), "…")
    }
}
