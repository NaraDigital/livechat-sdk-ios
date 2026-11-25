import XCTest
@testable import NaraLiveChat

/// K-330 on iOS — what `init` answers for a widget that takes no chat, end to end through
/// `NaraChat.configure` and the real `SdkApiURLSession` (requests answered by `StubURLProtocol`):
/// - a plan that ended or a quota that ran out: 200 with the offline config
///   (`apps/api/src/modules/webchat/offline-form.ts`, `offlineConfig`);
/// - an owner locked out, or a plan without the mobile SDK: 404 `SDK key not found`
///   (`apps/api/src/modules/sdk/sdk.service.ts`, `authenticateApp`).
/// Same outcome as the Android SDK: an offline notice in place of the chat, or `initError` with
/// a hint for the developer and a friendly line for the user, never a crash.
@MainActor
final class OfflineInitTests: XCTestCase {

    /// The exact shape `offlineConfig` sends, extra keys (`poweredBy`, `fields`, …) included.
    static let offlineBody = """
    {"key":"wk_live_1","name":"Toko Nara",
     "style":{"colors":{"primary":"#0B5FFF"},"header":{"title":"Toko Nara","subtitle":null},"logoUrl":null,
              "sdk":{"theme":"accent","accent":"#ffc400","mode":"light","locale":"id"}},
     "mode":"offline",
     "settings":{"showPoweredBy":true,"locale":"id","privacyText":"Data kamu aman."},
     "poweredBy":{"label":"Nara","url":"https://nara.ai.id"},
     "help":null,"aiAgent":null,"online":false,
     "offline":{"title":"Kami sedang offline","text":"Tinggalkan pesan, kami balas lewat email.",
                "fields":{"name":{"required":true,"max":120},"email":{"required":true,"max":254},
                          "message":{"required":true,"max":2000}}}}
    """

    /// `NotFoundError('SDK key')` as the API's error handler writes it.
    static let lockedBody = #"{"error":{"code":"not_found","message":"SDK key not found"}}"#

    override func setUp() {
        super.setUp()
        // `configure` builds its API on `URLSession.shared`; this puts the stub in front of it.
        URLProtocol.registerClass(StubURLProtocol.self)
    }

    override func tearDown() async throws {
        // Leave the shared SDK on the default host for the tests after these, with the stub still
        // in front so the reset's own `init` never reaches the network.
        StubURLProtocol.response = (200, "{}")
        StubURLProtocol.lastRequest = nil
        NaraChat.shared.configure(appKey: "nk_reset", baseUrl: NaraChat.defaultBaseUrl)
        try await until("the reset init answered") {
            StubURLProtocol.lastRequest?.url?.host == "api.nara.ai.id" && NaraChat.shared.initError == nil
        }
        URLProtocol.unregisterClass(StubURLProtocol.self)
        try await super.tearDown()
    }

    private func until(_ what: String, _ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for: \(what)")
    }

    // MARK: - 200 with the offline config

    func testTheOfflineConfigDecodesWithItsNotice() throws {
        let config = try JSONDecoder().decode(WidgetConfig.self, from: Data(Self.offlineBody.utf8))
        XCTAssertTrue(config.isOfflineMode)
        XCTAssertFalse(config.online)
        XCTAssertNil(config.aiAgent)
        XCTAssertNil(config.help)
        XCTAssertNil(config.sdk)
        XCTAssertEqual(config.name, "Toko Nara")
        XCTAssertEqual(config.settings?.locale, "id")
        XCTAssertEqual(config.style?.sdk?.locale, "id")

        let notice = offlineNotice(config, isId: true)
        XCTAssertEqual(notice.title, "Kami sedang offline")
        XCTAssertEqual(notice.text, "Tinggalkan pesan, kami balas lewat email.")
    }

    func testAnOfflineConfigWithABlankNoticeFallsBackToTheSdkText() throws {
        let body = #"{"key":"k","name":"N","mode":"offline","online":false,"help":null,"aiAgent":null,"offline":{"title":"  ","text":null}}"#
        let config = try JSONDecoder().decode(WidgetConfig.self, from: Data(body.utf8))
        XCTAssertEqual(offlineNotice(config, isId: true).title, "Kami sedang tidak online")
        XCTAssertEqual(offlineNotice(config, isId: false).text, "Chat isn't available right now. Please try again later.")
    }

    func testConfigureWithAnOfflineWidgetPutsTheMessengerOffline() async throws {
        StubURLProtocol.response = (200, Self.offlineBody)
        let nara = NaraChat.shared
        nara.configure(appKey: "nk_offline_test", baseUrl: "https://stub.invalid/api")
        try await until("the offline config on hand") { nara.configValue?.isOfflineMode == true }

        XCTAssertEqual(StubURLProtocol.lastPath, "/api/sdk/v1/init")
        XCTAssertNil(nara.initError, "an offline widget is an answer, not an error")
        XCTAssertEqual(nara.configValue?.online, false)
        XCTAssertFalse(nara.updateRequired, "the notice is what RootView shows, not the update screen")
    }

    // MARK: - 404 SDK key (owner locked out)

    func testALockedOwnersInitIsReadAsNotFound() async {
        StubURLProtocol.response = (404, Self.lockedBody)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let api = SdkApiURLSession(baseUrl: "https://stub.invalid/api", session: URLSession(configuration: config))
        do {
            _ = try await api.initSdk(appKey: "nk_locked", platform: "ios", bundleId: "com.example.app", sdkVersion: NaraChat.VERSION)
            XCTFail("a 404 is not a config")
        } catch {
            XCTAssertEqual(error as? SdkError, .notFound)
        }
    }

    func testConfigureWithALockedOwnerIsATidyInitErrorNotACrash() async throws {
        StubURLProtocol.response = (404, Self.lockedBody)
        let nara = NaraChat.shared
        nara.configure(appKey: "nk_locked_test_1234", baseUrl: "https://stub.invalid/api")
        try await until("initError") { nara.initError != nil }

        let failure = try XCTUnwrap(nara.initError)
        XCTAssertEqual(failure.status, 404)
        XCTAssertEqual(failure.code, "not_found")
        XCTAssertEqual(failure.url, "https://stub.invalid/api/sdk/v1/init")
        XCTAssertTrue(failure.hint?.contains("cek appKey") == true, "the developer is told where to look")
        XCTAssertEqual(failure.appKeyHint, "…1234", "the appKey never shows in full")

        // What the user reads, in the messenger, when the chat cannot load.
        XCTAssertEqual(friendlyError(SdkError.notFound, isId: true), "Chat tidak bisa dimuat. Coba lagi nanti.")
        XCTAssertEqual(friendlyError(SdkError.notFound, isId: false), "Couldn't load the chat. Please try again later.")
        XCTAssertNotEqual(friendlyError(SdkError.notFound, isId: true), friendlyError(nil, isId: true),
                          "not the generic \"Ada yang salah\"")
    }
}
