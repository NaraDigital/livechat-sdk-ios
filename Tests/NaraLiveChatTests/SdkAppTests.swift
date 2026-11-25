import XCTest
@testable import NaraLiveChat

/// The key has to name the same app across launches, however its address is spelled.
final class SdkAppTests: XCTestCase {

    func testTheAddressLosesItsSchemeCaseAndClosingSlashesAndKeepsPortAndPath() {
        XCTAssertEqual(SdkApp.address("https://api.nara.ai.id/api"), "api.nara.ai.id/api")
        XCTAssertEqual(SdkApp.address("HTTPS://API.Nara.ai.id/api///"), "api.nara.ai.id/api")
        XCTAssertEqual(SdkApp.address("http://api.nara.ai.id/api/"), "api.nara.ai.id/api")
        XCTAssertEqual(SdkApp.address("http://10.0.2.2:3000/api"), "10.0.2.2:3000/api")
        XCTAssertEqual(SdkApp.address("https://api.nara.ai.id"), "api.nara.ai.id")
        XCTAssertEqual(SdkApp.address(""), "")
    }

    func testAnotherKeyHostPortOrPathIsAnotherApp() {
        let app = SdkApp(appKey: "nk_1", baseUrl: "https://api.nara.ai.id/api")
        XCTAssertEqual(app.key, SdkApp(appKey: "nk_1", baseUrl: "http://API.NARA.AI.ID/api/").key)
        // Only the address is normalized; the key is compared as it is.
        XCTAssertNotEqual(app.key, SdkApp(appKey: "NK_1", baseUrl: "https://api.nara.ai.id/api").key)
        XCTAssertNotEqual(app.key, SdkApp(appKey: "nk_2", baseUrl: "https://api.nara.ai.id/api").key)
        XCTAssertNotEqual(app.key, SdkApp(appKey: "nk_1", baseUrl: "https://api.narachat.com/api").key)
        XCTAssertNotEqual(app.key, SdkApp(appKey: "nk_1", baseUrl: "https://api.nara.ai.id:8443/api").key)
        XCTAssertNotEqual(app.key, SdkApp(appKey: "nk_1", baseUrl: "https://api.nara.ai.id/sdk-api").key)
    }
}
