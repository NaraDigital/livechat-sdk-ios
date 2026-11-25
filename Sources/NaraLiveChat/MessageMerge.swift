import Foundation

/// A folded message list, and whether the fold brought in a reply from the AI or an agent.
struct MergeResult {
    var messages: [ChatMessage]
    var newReply: Bool
}

/// Folds the server's latest page into the list on screen. A message the list already has — by
/// `id`, or by `clientId` while its bubble is still the optimistic one — is refreshed in place;
/// one the list lacks is slotted in by `sentAt`; the order of what is already there never changes.
func mergeMessages(existing: [ChatMessage], fresh: [ChatMessage]) -> MergeResult {
    var messages = existing
    var newReply = false
    for m in fresh.sorted(by: { $0.sentAt < $1.sentAt }) {
        if let i = messages.firstIndex(where: { $0.id == m.id || (m.clientId != nil && $0.clientId == m.clientId) }) {
            messages[i] = m
            continue
        }
        if m.isTeam { newReply = true }
        var at = -1
        if !m.sentAt.isEmpty {
            at = messages.firstIndex(where: { !$0.sentAt.isEmpty && $0.sentAt > m.sentAt }) ?? -1
        }
        messages.insert(m, at: at < 0 ? messages.count : at)
    }
    return MergeResult(messages: messages, newReply: newReply)
}
