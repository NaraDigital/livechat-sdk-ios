import Foundation

/// Safe HTML parsing without WKWebView: only whitelisted tags survive (h1-h6, p, b/strong,
/// i/em, u, br, li/ul/ol, a); attributes are dropped; entities are decoded. Pure — unit-testable.
/// Full parity with the Android `parseSafeHtml`.
public enum SafeHtmlParser {

    public struct Block: Equatable {
        public let tag: String
        public let text: String
        public let href: String?
    }

    static let blockTags: Set<String> = ["h1", "h2", "h3", "h4", "h5", "h6", "p", "li", "a", "div", "br"]
    static let entities: [String: String] = [
        "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&nbsp;": " ",
    ]

    public static func parse(_ html: String) -> [Block] {
        var out: [Block] = []
        var sb = ""
        var tag = "p"
        var href: String? = nil
        var i = html.startIndex

        func flush() {
            var text = sb.trimmingCharacters(in: .whitespacesAndNewlines)
            for (k, v) in entities { text = text.replacingOccurrences(of: k, with: v) }
            if !text.isEmpty { out.append(Block(tag: tag, text: text, href: href)) }
            sb = ""
            tag = "p"
            href = nil
        }

        while i < html.endIndex {
            let c = html[i]
            if c == "<" {
                guard let close = html[i...].firstIndex(of: ">") else {
                    sb += String(html[i...]) // unterminated tag → shown as text
                    break
                }
                let raw = String(html[html.index(after: i)..<close]).trimmingCharacters(in: .whitespaces)
                let isClosing = raw.hasPrefix("/")
                let name = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    .split(whereSeparator: { $0 == " " || $0 == "\t" }).first?.lowercased() ?? ""
                if name == "br" {
                    sb += "\n"
                } else if blockTags.contains(name) {
                    if isClosing {
                        flush()
                    } else {
                        tag = name
                        href = Self.firstMatch(pattern: "href\\s*=\\s*\"([^\"]*)\"", in: raw)
                    }
                }
                // Non-whitelisted tag: dropped entirely.
                i = html.index(after: close)
            } else {
                sb.append(c)
                i = html.index(after: i)
            }
        }
        flush()
        return out
    }

    static func firstMatch(pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
}
