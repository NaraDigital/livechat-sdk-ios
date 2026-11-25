import XCTest
@testable import NaraLiveChat

private let widget = "Nara POS Vip"

/// The avatar of the Messages row: the last answerer's name, else the widget's; photo, else the letter.
final class ThreadAvatarTests: XCTestCase {

    private func answered(_ senderName: String, from: String = "agent", photo: String? = nil) -> ChatMessage {
        ChatMessage(
            id: "m", clientId: nil, from: from, senderName: senderName, type: "text", body: "hi",
            media: nil, status: "received", sentAt: "", quoted: nil, senderAvatarUrl: photo
        )
    }

    private func avatar(
        _ messages: [ChatMessage], widgetName: String? = widget, headerTitle: String? = "",
        handlerAvatarUrl: String? = nil, aiAvatarUrl: String? = nil
    ) -> ThreadAvatar {
        ThreadAvatarRules.avatar(
            messages: messages, widgetName: widgetName, headerTitle: headerTitle, fallbackTitle: "Obrolan",
            handlerAvatarUrl: handlerAvatarUrl, aiAvatarUrl: aiAvatarUrl
        )
    }

    func testWhoeverAnsweredLastNamesTheAvatar() {
        let a = avatar([answered("Budi", from: "ai"), answered("Steve")])
        XCTAssertEqual(a, ThreadAvatar(initial: "S", source: "Steve"))
    }

    func testTheVisitorWritingLastLeavesTheAvatarToTheAnswerer() {
        let messages = [answered("Nara POS Vip", from: "ai"), answered("Zai", from: "visitor")]
        XCTAssertEqual(avatar(messages).initial, "N")
    }

    func testWithoutAnAnswerTheWidgetsNameDoes() {
        let a = avatar([answered("Zai", from: "visitor")])
        XCTAssertEqual(a, ThreadAvatar(initial: "N", source: "Nara POS Vip"))
        XCTAssertEqual(avatar([]).initial, "N")
    }

    func testAnEmptyWidgetNameFallsToTheHeaderTitleThenToTheScreenTitle() {
        let header = avatar([], widgetName: "", headerTitle: "Chat dengan kami")
        XCTAssertEqual(header, ThreadAvatar(initial: "C", source: "Chat dengan kami"))

        let none = avatar([], widgetName: nil, headerTitle: "  ")
        XCTAssertEqual(none, ThreadAvatar(initial: "O", source: "Obrolan"))
    }

    func testTheFirstLetterOrDigitIsTakenPastSpacesEmojiAndPunctuationUpperCased() {
        func letter(_ name: String) -> String { avatar([], widgetName: name).initial }

        XCTAssertEqual(letter("  😀 👋 steve"), "S")
        XCTAssertEqual(letter("\tnara"), "N")
        XCTAssertEqual(letter("24/7 Support"), "2")
        XCTAssertEqual(letter("éric"), "É")
        XCTAssertEqual(letter("田中 太郎"), "田")
        XCTAssertEqual(letter("𐐨bc"), "𐐀")
        XCTAssertEqual(letter("ß Cafe"), "ß")
        XCTAssertEqual(letter("😀!!"), "O")
    }

    func testSystemMessagesAreSkipped() {
        let only = avatar([answered("Pesan sistem", from: "system")], widgetName: "Toko")
        XCTAssertEqual(only.initial, "T")

        let both = avatar([answered("Steve"), answered("Pesan sistem", from: "system")])
        XCTAssertEqual(both.source, "Steve")
    }

    func testAnAnswerWithoutANameIsSkipped() {
        let older = avatar([answered("Steve"), answered("  ", from: "ai")])
        XCTAssertEqual(older.source, "Steve")
        XCTAssertEqual(avatar([answered("", from: "ai")]).initial, "N")
    }

    func testThePhotoOfWhoeverAnsweredLastIsTheAvatars() {
        let steve = "https://cdn.example.com/steve.jpg"
        let messages = [answered("Budi", from: "ai", photo: "https://cdn.example.com/ai.jpg"), answered("Steve", photo: steve)]

        let a = avatar(messages)
        XCTAssertEqual(a.photoUrl, steve)
        // The letter beside the photo is still the one it falls back to.
        XCTAssertEqual(a.initial, "S")
    }

    func testThePhotoOfAnEarlierAnswerIsNotBorrowedForALaterOne() {
        let messages = [answered("Steve", photo: "https://cdn.example.com/steve.jpg"), answered("Nara POS Vip", from: "ai")]
        XCTAssertNil(avatar(messages).photoUrl)
    }

    func testAVisitorOrSystemMessageNeverLendsItsPhoto() {
        let visitor = avatar([answered("Steve"), answered("Zai", from: "visitor", photo: "https://cdn.example.com/zai.jpg")])
        XCTAssertNil(visitor.photoUrl)

        let system = avatar([answered("Steve"), answered("Pesan sistem", from: "system", photo: "https://cdn.example.com/sys.jpg")])
        XCTAssertNil(system.photoUrl)
    }

    func testWithoutAPhotoOnTheLastAnswerTheHandlersIsShownThenTheAIs() {
        let blank = [answered("Steve", photo: "")]

        let handler = avatar(blank, handlerAvatarUrl: "https://cdn.example.com/h.jpg", aiAvatarUrl: "https://cdn.example.com/ai.jpg")
        XCTAssertEqual(handler.photoUrl, "https://cdn.example.com/h.jpg")
        XCTAssertEqual(avatar(blank, aiAvatarUrl: "https://cdn.example.com/ai.jpg").photoUrl, "https://cdn.example.com/ai.jpg")
        XCTAssertNil(avatar(blank).photoUrl)
    }

    func testBeforeTheFirstAnswerTheAIsPhotoShowsBesideTheWidgetsLetter() {
        let a = avatar([], aiAvatarUrl: "https://cdn.example.com/ai.jpg")

        XCTAssertEqual(a.photoUrl, "https://cdn.example.com/ai.jpg")
        XCTAssertEqual(a.initial, "N")
        XCTAssertEqual(a.source, "Nara POS Vip")
    }
}
