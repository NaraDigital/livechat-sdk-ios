import XCTest
@testable import NaraLiveChat

/// The photo beside a Chat bubble: only on the first bubble of a run from one sender, only when there is one.
final class BubbleAvatarTests: XCTestCase {

    private let photo = "https://cdn.example.com/steve.jpg"
    private let aiPhoto = "https://cdn.example.com/ai.jpg"

    private var steve: SdkSession.Handler { SdkSession.Handler(type: "agent", name: "Steve", avatarUrl: photo) }
    private var ai: SdkSession.Handler { SdkSession.Handler(type: "ai", name: "Nara AI", avatarUrl: nil) }

    private func msg(_ id: String, from: String, senderName: String, ownPhoto: String? = nil) -> ChatMessage {
        ChatMessage(
            id: id, clientId: nil, from: from, senderName: senderName, type: "text", body: "hi",
            media: nil, status: "received", sentAt: "", quoted: nil, senderAvatarUrl: ownPhoto
        )
    }

    private func beside(_ m: ChatMessage, handler: SdkSession.Handler, aiPhoto: String? = nil) -> String? {
        ThreadAvatarRules.messagePhoto(m, handler: handler, aiAvatarUrl: aiPhoto)
    }

    func testThePhotoTheMessageWasSentWithComesFirst() {
        let own = "https://cdn.example.com/old.jpg"

        XCTAssertEqual(own, beside(msg("m", from: "agent", senderName: "Budi", ownPhoto: own), handler: steve, aiPhoto: aiPhoto))
    }

    func testAnAIMessageWithoutItsOwnPhotoFallsToTheAIs() {
        let m = msg("m", from: "ai", senderName: "Nara AI")

        XCTAssertEqual(aiPhoto, beside(m, handler: ai, aiPhoto: aiPhoto))
        XCTAssertNil(beside(m, handler: ai))
    }

    func testAnAgentsMessageFallsToTheHandlersPhotoOnlyWhenItIsTheSameAgent() {
        XCTAssertEqual(photo, beside(msg("m", from: "agent", senderName: " Steve "), handler: steve, aiPhoto: aiPhoto))

        // Another agent wrote it, or the handler now is the AI: the photo is not theirs.
        XCTAssertNil(beside(msg("m", from: "agent", senderName: "Budi"), handler: steve, aiPhoto: aiPhoto))
        XCTAssertNil(beside(msg("m", from: "agent", senderName: "Steve"), handler: ai, aiPhoto: aiPhoto))
    }

    func testTheVisitorAndSystemNoticesNeverGetAPhoto() {
        XCTAssertNil(beside(msg("m", from: "visitor", senderName: "Zai", ownPhoto: photo), handler: steve, aiPhoto: aiPhoto))
        XCTAssertNil(beside(msg("m", from: "system", senderName: "Pesan sistem", ownPhoto: photo), handler: steve, aiPhoto: aiPhoto))
    }

    func testOnlyTheFirstBubbleOfARunFromOneSenderOpensIt() {
        let messages = [
            msg("1", from: "visitor", senderName: "Zai"),
            msg("2", from: "agent", senderName: "Steve"),
            msg("3", from: "agent", senderName: "Steve"),
            msg("4", from: "agent", senderName: "Budi"),
            msg("5", from: "ai", senderName: "Nara AI"),
            msg("6", from: "ai", senderName: "nara ai"),
            msg("7", from: "system", senderName: "Pesan sistem"),
            msg("8", from: "agent", senderName: "Steve"),
        ]

        XCTAssertEqual(
            [false, true, false, true, true, false, false, true],
            messages.indices.map { ThreadAvatarRules.opensSenderRun(messages, $0) }
        )
    }

    func testAnAnswerOpeningTheChatOpensARunAQuestionDoesNot() {
        XCTAssertTrue(ThreadAvatarRules.opensSenderRun([msg("1", from: "agent", senderName: "Steve")], 0))
        XCTAssertFalse(ThreadAvatarRules.opensSenderRun([msg("1", from: "visitor", senderName: "Zai")], 0))
        XCTAssertFalse(ThreadAvatarRules.opensSenderRun([], 0))
    }
}
