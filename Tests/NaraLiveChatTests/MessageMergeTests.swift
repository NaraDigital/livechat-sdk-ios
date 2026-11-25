import XCTest
@testable import NaraLiveChat

/// Folds the server's latest page into the list on screen without a duplicate or a jump.
final class MessageMergeTests: XCTestCase {

    func testAMessageTheListAlreadyHasIsRefreshedInPlace() {
        let existing = [message("m_1"), message("m_2", sentAt: "2026-11-23T10:00:05.000Z")]
        let fresh = [
            message("m_2", sentAt: "2026-11-23T10:00:05.000Z", clientId: "c_2"),
            message("m_1"),
        ]

        let merged = mergeMessages(existing: existing, fresh: fresh)

        XCTAssertEqual(merged.messages.map(\.id), ["m_1", "m_2"], "the order on screen is kept")
        XCTAssertEqual(merged.messages[1].clientId, "c_2")
        XCTAssertFalse(merged.newReply, "nothing new came in")
    }

    func testAPendingBubbleIsReplacedByTheSentMessageWithTheSameClientId() {
        let pending = ChatMessage(
            id: "optimistic-1", clientId: "c_1", from: "visitor", senderName: "Kamu", type: "text",
            body: "halo", media: nil, status: "pending", sentAt: "", quoted: nil
        )
        let sent = message("m_1", from: "visitor", clientId: "c_1")

        let merged = mergeMessages(existing: [message("m_0"), pending], fresh: [sent])

        XCTAssertEqual(merged.messages.map(\.id), ["m_0", "m_1"])
        XCTAssertEqual(merged.messages[1].status, "sent")
        XCTAssertFalse(merged.newReply)
    }

    func testAMissingMessageIsSlottedInByItsTimestamp() {
        let existing = [
            message("m_1", sentAt: "2026-11-23T10:00:01.000Z"),
            message("m_4", sentAt: "2026-11-23T10:00:04.000Z"),
        ]
        // The server sends the page newest first; both slots are filled.
        let fresh = [
            message("m_3", sentAt: "2026-11-23T10:00:03.000Z"),
            message("m_2", from: "visitor", sentAt: "2026-11-23T10:00:02.000Z"),
        ]

        let merged = mergeMessages(existing: existing, fresh: fresh)

        XCTAssertEqual(merged.messages.map(\.id), ["m_1", "m_2", "m_3", "m_4"])
        XCTAssertTrue(merged.newReply, "a reply that was missed arrived")
    }

    func testAMessageWithoutATimestampGoesLast() {
        let existing = [
            message("m_1", from: "visitor", sentAt: "2026-11-23T10:00:00.000Z"),
            message("optimistic-x", from: "visitor", sentAt: "", clientId: "x"),
        ]
        let fresh = [
            message("m_2"),
            message("m_0", from: "visitor", sentAt: "2026-11-23T09:59:59.000Z"),
        ]

        let merged = mergeMessages(existing: existing, fresh: fresh)

        XCTAssertEqual(merged.messages.map(\.id), ["m_0", "m_1", "optimistic-x", "m_2"])
        XCTAssertTrue(merged.newReply)
    }

    func testOnlyTheAiOrAnAgentCountsAsAReply() {
        func reply(from: String) -> Bool {
            mergeMessages(existing: [message("m_1", from: "visitor")], fresh: [message("m_2", from: from)]).newReply
        }

        XCTAssertFalse(reply(from: "visitor"))
        XCTAssertFalse(reply(from: "system"))
        XCTAssertTrue(reply(from: "ai"))
        XCTAssertTrue(reply(from: "agent"))
    }

    func testAnEmptyPageLeavesTheListAlone() {
        let existing = [message("m_1"), message("m_2")]

        let merged = mergeMessages(existing: existing, fresh: [])

        XCTAssertEqual(merged.messages.map(\.id), ["m_1", "m_2"])
        XCTAssertFalse(merged.newReply)
    }
}
