import XCTest

/// End-to-end smoke test against a real NaraChat API: init → open the messenger → send a
/// message → a reply from the AI or an agent comes in while the chat is open.
///
/// Needs a widget whose allowed packages include `id.nara.livechat.sample`, with the prechat
/// form off and an AI agent (or someone answering). Without `NARA_APP_KEY` the test is skipped:
///
///     TEST_RUNNER_NARA_APP_KEY=nk_xxx TEST_RUNNER_NARA_BASE_URL=https://api.nara.ai.id/api \
///     xcodebuild test -project NaraSampleApp.xcodeproj -scheme SampleApp \
///       -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SampleAppUITests
final class SmokeUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testInitOpenSendAndAReplyArrives() throws {
        let env = ProcessInfo.processInfo.environment
        guard let appKey = env["NARA_APP_KEY"], appKey.hasPrefix("nk_"), appKey.count > 3 else {
            throw XCTSkip("Set TEST_RUNNER_NARA_APP_KEY to run the smoke test against a real widget.")
        }
        let app = XCUIApplication()
        app.launchEnvironment["NARA_APP_KEY"] = appKey
        app.launchEnvironment["NARA_BASE_URL"] = env["NARA_BASE_URL"] ?? "https://api.nara.ai.id/api"
        app.launch()

        // Init + open the messenger.
        app.buttons["sample.anonymousChat"].tap()
        let thread = app.buttons["nara.messages.thread"]
        XCTAssertTrue(thread.waitForExistence(timeout: 30), "the messenger opens once init answers")
        thread.tap()

        // Send a message.
        let input = app.textFields["nara.chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 30), "the chat opens with its composer")
        input.tap()
        input.typeText("Halo, ini smoke test iOS SDK \(Int(Date().timeIntervalSince1970))")
        app.buttons["nara.chat.send"].tap()

        let bubbles = app.descendants(matching: .any)
        XCTAssertTrue(
            bubbles.matching(identifier: "nara.chat.message.visitor").firstMatch.waitForExistence(timeout: 15),
            "the sent message shows in the chat"
        )

        // The reply comes in while the chat stays open (socket, or polling when it is down).
        let team = NSPredicate(format: "identifier IN %@", ["nara.chat.message.ai", "nara.chat.message.agent"])
        XCTAssertTrue(
            bubbles.matching(team).firstMatch.waitForExistence(timeout: 90),
            "a reply from the AI or an agent arrives"
        )
    }
}
