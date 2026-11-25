import XCTest
@testable import NaraLiveChat

/// Parity with Android's ErrorMessagesTest — raw codes/bodies never reach the user.
/// The codes the API really sends (SDK API v1) and the HTTP status both decide.
final class FriendlyErrorTests: XCTestCase {

    func testNetworkMapsToConnectionHint() {
        XCTAssertEqual(
            friendlyError(SdkError.network(nil), isId: true),
            "Koneksi bermasalah. Periksa internet kamu lalu coba lagi."
        )
        XCTAssertEqual(
            friendlyError(SdkError.network(nil), isId: false),
            "Connection problem. Check your internet and try again."
        )
    }

    func testNotFoundMapsToChatUnavailable() {
        XCTAssertEqual(
            friendlyError(SdkError.notFound, isId: true),
            "Chat tidak bisa dimuat. Coba lagi nanti."
        )
        XCTAssertEqual(
            friendlyError(SdkError.notFound, isId: false),
            "Couldn't load the chat. Please try again later."
        )
    }

    func testRouteNotFoundReadsLikeNotFound() {
        // route_not_found is the 404 a baseUrl without the /api prefix gets back.
        XCTAssertEqual(
            friendlyError(SdkError.http(status: 404, code: "route_not_found"), isId: true),
            "Chat tidak bisa dimuat. Coba lagi nanti."
        )
        XCTAssertEqual(
            friendlyError(SdkError.http(status: 404, code: "route_not_found"), isId: false),
            "Couldn't load the chat. Please try again later."
        )
    }

    func test429AsksToWaitByStatusOrByCode() {
        XCTAssertEqual(
            friendlyError(SdkError.http(status: 429, code: "too_many_requests"), isId: true),
            "Terlalu banyak percobaan. Tunggu sebentar ya."
        )
        XCTAssertEqual(
            friendlyError(SdkError.http(status: 429, code: "send_limit"), isId: false),
            "Too many requests. Please wait a moment."
        )
    }

    func testOther401And403ReadAsAnEndedSession() {
        XCTAssertEqual(
            friendlyError(SdkError.http(status: 401, code: "unauthorized"), isId: true),
            "Sesi kamu berakhir. Buka ulang chat."
        )
        XCTAssertEqual(
            friendlyError(SdkError.http(status: 403, code: "forbidden"), isId: false),
            "Your session ended. Please reopen the chat."
        )
    }

    func testPackageNotAllowedAndTokenInvalid() {
        XCTAssertEqual(friendlyError(SdkError.packageNotAllowed, isId: true), "Aplikasi ini belum diizinkan memakai live chat.")
        XCTAssertEqual(friendlyError(SdkError.visitorTokenInvalid, isId: false), "Session expired. Please reopen the chat.")
    }

    func testUnknownErrorsFallBackToGeneric() {
        XCTAssertEqual(friendlyError(SdkError.http(status: 500, code: "internal"), isId: true), "Ada yang salah. Coba lagi nanti.")
        XCTAssertEqual(friendlyError(nil, isId: false), "Something went wrong. Please try again later.")
        XCTAssertEqual(friendlyError(NSError(domain: "x", code: 1), isId: false), "Something went wrong. Please try again later.")
    }

    func testNoRawSyntaxLeaks() {
        let sdkCases: [SdkError] = [
            .network(nil), .notFound, .packageNotAllowed, .visitorTokenInvalid,
            .validation, .prechatRequired(["name"]), .http(status: 404, code: "not_found"),
            .http(status: 404, code: "route_not_found"), .http(status: 429, code: "too_many_requests"),
            .http(status: 401, code: "unauthorized"), .http(status: 403, code: "forbidden"),
            .http(status: 404, code: "http_404"),
        ]
        let cases: [Error?] = sdkCases.map { $0 as Error } + [nil, NSError(domain: "x", code: 1)]
        for e in cases {
            for isId in [true, false] {
                let msg = friendlyError(e, isId: isId)
                XCTAssertTrue(!msg.isEmpty)
                XCTAssertFalse(msg.contains("{") || msg.contains("}"))
                XCTAssertFalse(msg.contains("not_found") || msg.contains("network_error"))
                XCTAssertFalse(msg.contains("[") || msg.contains("]"))
            }
        }
    }

    // MARK: - Offline notice

    /// A config with nothing to it but `offline` — the widget's own notice, or whatever stands in for it.
    private func offlineConfig(_ offline: String) throws -> WidgetConfig {
        let json = #"{"key":"k","name":"N","mode":"offline","online":false,"offline":\#(offline)}"#
        return try JSONDecoder().decode(WidgetConfig.self, from: json.data(using: .utf8)!)
    }

    func testTheOfflineNoticeIsTheWidgetsOwnTitleAndText() throws {
        let config = try offlineConfig(
            #"{"title":"Kami sedang tidak online","text":"Tinggalkan pesan, kami akan menghubungi kamu lewat email."}"#
        )

        let notice = offlineNotice(config, isId: true)

        XCTAssertEqual(notice.title, "Kami sedang tidak online")
        XCTAssertEqual(notice.text, "Tinggalkan pesan, kami akan menghubungi kamu lewat email.")
    }

    func testANoticeTheServerLeftOutOrBlankFallsBackToStandbyLinesInTheUILanguage() throws {
        let blank = try offlineConfig(#"{"title":"  ","text":null}"#)
        XCTAssertEqual(offlineNotice(blank, isId: true).title, "Kami sedang tidak online")
        XCTAssertEqual(offlineNotice(blank, isId: true).text, "Chat sedang tidak tersedia. Coba lagi nanti.")

        let none = try offlineConfig("null")
        XCTAssertEqual(offlineNotice(none, isId: false).title, "We are offline right now")
        XCTAssertEqual(offlineNotice(none, isId: false).text, "Chat isn't available right now. Please try again later.")
    }
}
