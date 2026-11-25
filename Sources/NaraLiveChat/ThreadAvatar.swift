import Foundation

/// The avatar of the one thread on Messages: the letter, the name it was taken from and — when
/// there is a photo — where it comes from.
struct ThreadAvatar: Equatable, Sendable {
    let initial: String
    let source: String
    var photoUrl: String? = nil
}

enum ThreadAvatarRules {
    /// Avatar of the one thread on Messages: named after whoever answered last, else the widget's
    /// name, else its header title, else the screen's own title. The photo is the last answer's,
    /// else the handler's, else the AI's.
    static func avatar(
        messages: [ChatMessage], widgetName: String?, headerTitle: String?, fallbackTitle: String,
        handlerAvatarUrl: String? = nil, aiAvatarUrl: String? = nil
    ) -> ThreadAvatar {
        let named = messages.last {
            !$0.isMine && !$0.isSystem && !$0.senderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let source = [named?.senderName, widgetName, headerTitle, fallbackTitle]
            .compactMap { $0 }
            .first { firstLetter(of: $0) != nil } ?? fallbackTitle
        let photo = [messages.last { !$0.isMine && !$0.isSystem }?.photoUrl, unblank(handlerAvatarUrl), unblank(aiAvatarUrl)]
            .compactMap { $0 }
            .first
        return ThreadAvatar(initial: firstLetter(of: source) ?? "", source: source, photoUrl: photo)
    }

    /// The photo beside an AI or agent bubble: the message's own, else the AI's for an AI message,
    /// else the handler's when the handler is that agent. Visitor and system messages get none.
    static func messagePhoto(_ m: ChatMessage, handler: SdkSession.Handler?, aiAvatarUrl: String?) -> String? {
        if m.isMine || m.isSystem { return nil }
        if let own = m.photoUrl { return own }
        switch m.from {
        case "ai":
            return unblank(aiAvatarUrl)
        case "agent":
            guard handler?.type == "agent", sameName(handler?.name, m.senderName) else { return nil }
            return unblank(handler?.avatarUrl)
        default:
            return nil
        }
    }

    /// True on the first bubble of a run from one sender — the only bubble its photo stands beside.
    static func opensSenderRun(_ messages: [ChatMessage], _ index: Int) -> Bool {
        guard messages.indices.contains(index) else { return false }
        let m = messages[index]
        if m.isMine || m.isSystem { return false }
        guard index > 0 else { return true }
        let before = messages[index - 1]
        return before.from != m.from || !sameName(before.senderName, m.senderName)
    }

    /// The first letter or digit — past spaces, emoji and punctuation — upper-cased; nil without one.
    static func firstLetter(of name: String) -> String? {
        for scalar in name.unicodeScalars {
            guard CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) else { continue }
            // "ß" would grow into "SS": a letter that cannot be capitalised in place stays as it is.
            let letter = String(scalar)
            let upper = letter.uppercased()
            return upper.unicodeScalars.count == 1 ? upper : letter
        }
        return nil
    }

    /// Sender names match past spaces and letter case, so "steve" continues Steve's run.
    private static func sameName(_ a: String?, _ b: String?) -> Bool {
        let trim = { (s: String?) in (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        return trim(a).caseInsensitiveCompare(trim(b)) == .orderedSame
    }

    private static func unblank(_ url: String?) -> String? {
        guard let url, !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return url
    }
}
