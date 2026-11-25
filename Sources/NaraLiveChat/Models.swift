import Foundation

// MARK: - DTOs (mirror of the Android SDK models; SDK API v1)
// All DTOs are value types → `Sendable` so they can cross actor boundaries freely.

public struct WidgetConfig: Codable, Sendable {
    public let key: String
    public let name: String
    public let style: Style?
    public let settings: Settings?
    public let aiAgent: AiAgent?
    public let online: Bool
    public let help: HelpCounts?
    public let mode: String?
    public let sdk: SdkInfo?
    /// Sent with `mode == "offline"`: what the widget says in place of the chat.
    public let offline: OfflineNotice?

    public var isOfflineMode: Bool { mode == "offline" }

    /// The widget's offline notice. A field is nil when the server sends none, null, or not a string.
    public struct OfflineNotice: Codable, Sendable, Equatable {
        public let title: String?
        public let text: String?

        private enum CodingKeys: String, CodingKey { case title, text }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? nil
            text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? nil
        }
    }

    /// The AI answering for the widget; `avatarUrl` is its own photo or the default robot the server sends for an AI without one. Nil only from an older server.
    public struct AiAgent: Codable, Sendable { public let name: String?; public let avatarUrl: String? }
    public struct HelpCounts: Codable, Sendable { public let faqs: Int; public let articles: Int }

    public struct SdkInfo: Codable, Sendable {
        public let minSupportedVersion: String?
        public let latestVersion: String?
        public let updateRequired: Bool
        public let updateRecommended: Bool
    }

    public struct Style: Codable, Sendable {
        public let colors: Colors?
        public let header: Header?
        /// Absolute, auth-free logo URL (`header.avatar` → `launcher.icon` → nil server-side). nil → initial badge.
        public let logoUrl: String?
        /// "SDK style" preset — drives background/primary/hero + greeting.
        public let sdk: SdkStyle?

        public struct Colors: Codable, Sendable {
            public var primary: String?
            public var background: String?
            public var text: String?
            public var bubbleVisitor: String?
            public var bubbleVisitorText: String?
            public var bubbleAgent: String?
            public var bubbleAgentText: String?
        }

        public struct Header: Codable, Sendable {
            public let title: String?
            public let subtitle: String?
        }

        /// Mirrors the owner DTO (`style.sdk`). Decoding is lenient: a missing, null or
        /// non-string key becomes nil, and the accessors below apply the defaults.
        public struct SdkStyle: Codable, Sendable, Equatable {
            public let theme: String?       // "accent" | "white"; nil/unknown → accent
            public let accent: String?      // "#rrggbb"; nil/invalid → #ffc400
            public let greetingTitle: String?
            public let greetingSubtitle: String?
            public let mode: String?        // "light" | "dark"; nil/unknown → light
            public let locale: String?      // "id" | "en"; nil/unknown → settings.locale

            public init(
                theme: String? = nil, accent: String? = nil,
                greetingTitle: String? = nil, greetingSubtitle: String? = nil,
                mode: String? = nil, locale: String? = nil
            ) {
                self.theme = theme; self.accent = accent
                self.greetingTitle = greetingTitle; self.greetingSubtitle = greetingSubtitle
                self.mode = mode; self.locale = locale
            }

            private enum CodingKeys: String, CodingKey {
                case theme, accent, greetingTitle, greetingSubtitle, mode, locale
            }

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                theme = Self.string(c, .theme)
                accent = Self.string(c, .accent)
                greetingTitle = Self.string(c, .greetingTitle)
                greetingSubtitle = Self.string(c, .greetingSubtitle)
                mode = Self.string(c, .mode)
                locale = Self.string(c, .locale)
            }

            /// The string at the key, or nil when it is missing, null or not a string.
            private static func string(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> String? {
                (try? c.decodeIfPresent(String.self, forKey: key)) ?? nil
            }

            public var isWhiteTheme: Bool { theme == "white" }
            /// Accent with the default applied (never empty/invalid at use sites).
            public var normalizedAccent: String {
                (accent?.isEmpty == false) ? accent! : SdkThemeRules.defaultAccentHex
            }
            /// True only for the exact value `dark`. The phone's dark mode is never an input.
            public var isDarkMode: Bool { mode == SdkStyle.modeDark }

            public static let accentTheme = "accent"
            public static let whiteTheme = "white"
            public static let modeLight = "light"
            public static let modeDark = "dark"
        }
    }

    public struct Settings: Codable, Sendable {
        public let greeting: Greeting?
        public let quickReplies: [String]?
        public let welcomeMessage: String?
        public let prechat: PrechatRules?
        public let showFaq: Bool?
        public let showArticles: Bool?
        public let allowImages: Bool?
        public let locale: String?

        public struct Greeting: Codable, Sendable { public let enabled: Bool?; public let text: String? }
        public struct PrechatRules: Codable, Sendable {
            public let enabled: Bool?
            public let requireName: Bool?
            public let requireEmail: Bool?
        }
    }
}

public struct SdkSession: Codable, Sendable {
    public let token: String
    public let expiresAt: String
    public let visitor: Visitor
    public let conversationId: String?
    public let prechatRequired: Bool
    public let handler: Handler?
    public let messages: [ChatMessage]
    public let hasMore: Bool
    public let identity: Identity

    public struct Visitor: Codable, Sendable { public let id: String; public let name: String?; public let email: String? }
    public struct Handler: Codable, Sendable { public let type: String?; public let name: String?; public let avatarUrl: String? }
    public struct Identity: Codable, Sendable { public let verified: Bool; public let userId: String? }
}

public struct ChatMessage: Codable, Identifiable, Sendable {
    public let id: String
    public let clientId: String?
    public let from: String          // visitor | ai | agent | system | (unknown)
    public let senderName: String
    public let type: String          // text | image | document | system | unknown-server-type
    public let body: String
    public let media: Media?
    public let status: String        // pending | sent | delivered | read | failed | received
    public let sentAt: String
    public let quoted: Quote?
    /// The sender's photo on an AI or agent message; nil for the visitor, system notices and senders without one.
    public let senderAvatarUrl: String?

    public struct Media: Codable, Sendable { public let url: String; public let mime: String? }
    public struct Quote: Codable, Sendable { public let id: String?; public let senderName: String?; public let body: String?; public let type: String? }

    public init(
        id: String, clientId: String?, from: String, senderName: String, type: String, body: String,
        media: Media?, status: String, sentAt: String, quoted: Quote?, senderAvatarUrl: String? = nil
    ) {
        self.id = id; self.clientId = clientId; self.from = from; self.senderName = senderName
        self.type = type; self.body = body; self.media = media; self.status = status
        self.sentAt = sentAt; self.quoted = quoted; self.senderAvatarUrl = senderAvatarUrl
    }

    public var isMine: Bool { from == "visitor" }
    public var isSystem: Bool { from == "system" }
    public var isTeam: Bool { from == "agent" || from == "ai" }
    /// `senderAvatarUrl`, or nil when it is empty or only spaces.
    public var photoUrl: String? {
        guard let url = senderAvatarUrl, !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return url
    }

    public static let fallbackBodyEn = "Update the app to view this message"
    public static let fallbackBodyId = "Perbarui aplikasi untuk melihat pesan ini"

    /// Spec: unknown message types degrade to the fallback text so an old SDK never
    /// renders garbage from a newer server.
    public static func withFallback(_ m: ChatMessage, locale: String) -> ChatMessage {
        let known = ["text", "image", "document", "system"]
        guard !known.contains(m.type) else { return m }
        return ChatMessage(
            id: m.id, clientId: m.clientId, from: m.from, senderName: m.senderName,
            type: "fallback",
            body: locale.hasPrefix("id") ? fallbackBodyId : fallbackBodyEn,
            media: m.media, status: m.status, sentAt: m.sentAt, quoted: m.quoted,
            senderAvatarUrl: m.senderAvatarUrl
        )
    }

    /// Text to render. Messages are decoded before the UI language is known, so a
    /// fallback message gets its text here, in the current UI language.
    public func displayBody(isId: Bool) -> String {
        type == "fallback" ? (isId ? Self.fallbackBodyId : Self.fallbackBodyEn) : body
    }
}

public struct MessagePage: Codable, Sendable {
    public let items: [ChatMessage]
    public let hasMore: Bool
}

public struct UnreadCount: Codable, Sendable { public let count: Int }

/// Session page context (`POST /sdk/v1/session` → `page`, validated server-side as an
/// object: `{url?, title?, referrer?, language?}`). Native apps normally pass nil.
public struct PagePayload: Codable, Sendable {
    public let url: String?
    public let title: String?
    public let referrer: String?
    public let language: String?

    public init(url: String? = nil, title: String? = nil, referrer: String? = nil, language: String? = nil) {
        self.url = url; self.title = title; self.referrer = referrer; self.language = language
    }

    var asBody: [String: Any] {
        var b: [String: Any] = [:]
        if let url { b["url"] = url }
        if let title { b["title"] = title }
        if let referrer { b["referrer"] = referrer }
        if let language { b["language"] = language }
        return b
    }
}

public struct HelpOverview: Codable, Sendable {
    public let faqs: [Faq]?
    public let categories: [HelpCategory]?
    public let articles: [HelpArticleRef]?

    public struct Faq: Codable, Identifiable, Sendable {
        public var id: String { question }
        public let question: String
        public let answer: String
    }
    public struct HelpCategory: Codable, Identifiable, Sendable {
        public let id: String
        public let name: String
        public let icon: String?
    }
    public struct HelpArticleRef: Codable, Identifiable, Sendable {
        public var id: String { slug }
        public let slug: String
        public let title: String
        public let snippet: String?
    }
}

public struct HelpArticle: Codable, Sendable {
    public let slug: String
    public let title: String
    public let html: String
    public let updatedAt: String?
}

public struct DeviceTokenResult: Codable, Sendable { public let ok: Bool }

// MARK: - Errors

public enum SdkError: Error, LocalizedError, Equatable {
    case notFound
    case packageNotAllowed
    case visitorTokenInvalid
    case validation
    case prechatRequired([String])   // required: name/email
    case http(status: Int, code: String)
    case network(Error?)

    /// A successful status whose body is not the JSON the endpoint promised — a web page, an
    /// empty or cut-off body, a missing field.
    static func badResponse(status: Int) -> SdkError {
        .http(status: status, code: badResponseCode)
    }

    /// The same string as Android's `SdkException.BAD_RESPONSE`.
    static let badResponseCode = "bad_response"

    /// Hand-written because `Error?` cannot be compared (no synthesized `==`).
    public static func == (lhs: SdkError, rhs: SdkError) -> Bool {
        switch (lhs, rhs) {
        case (.notFound, .notFound),
             (.packageNotAllowed, .packageNotAllowed),
             (.visitorTokenInvalid, .visitorTokenInvalid),
             (.validation, .validation),
             (.network, .network):
            return true
        case let (.prechatRequired(a), .prechatRequired(b)):
            return a == b
        case let (.http(s1, c1), .http(s2, c2)):
            return s1 == s2 && c1 == c2
        default:
            return false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .notFound: return "not_found"
        case .packageNotAllowed: return "sdk_package_not_allowed"
        case .visitorTokenInvalid: return "visitor_token_invalid"
        case .validation: return "validation_failed"
        case .prechatRequired(let f): return "prechat_required \(f)"
        case .http(let s, let c): return "http_\(s) \(c)"
        case .network: return "network_error"
        }
    }

    /// Parses the error body the API sends (SDK API v1):
    /// `{"error":{"code","message","details"}}`. Older flat bodies stay readable too —
    /// `code`/`details` at the root, or `error` holding a bare code string.
    static func from(status: Int, body: Data) -> SdkError {
        let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let nested = root?["error"] as? [String: Any]
        let code = (nested?["code"] as? String).nonBlank
            ?? (root?["code"] as? String).nonBlank
            ?? (root?["error"] as? String).nonBlank
            ?? ""
        if status == 428 || code == "prechat_required" {
            let details = (nested?["details"] as? [String: Any]) ?? (root?["details"] as? [String: Any])
            let required = (details?["required"] as? [Any])?.compactMap { $0 as? String } ?? []
            return .prechatRequired(required.isEmpty ? ["name", "email"] : required)
        }
        switch code {
        case "not_found": return .notFound
        case "sdk_package_not_allowed": return .packageNotAllowed
        case "visitor_token_invalid": return .visitorTokenInvalid
        case "validation_failed": return .validation
        default: return .http(status: status, code: code.isEmpty ? "http_\(status)" : code)
        }
    }

    /// The API code this case stands for; `network_error` when the request never completed.
    var apiCode: String {
        switch self {
        case .notFound: return "not_found"
        case .packageNotAllowed: return "sdk_package_not_allowed"
        case .visitorTokenInvalid: return "visitor_token_invalid"
        case .validation: return "validation_failed"
        case .prechatRequired: return "prechat_required"
        case .http(_, let code): return code
        case .network: return "network_error"
        }
    }

    /// HTTP status behind the error (the contract's status for the named codes); 0 for a network failure.
    var httpStatus: Int {
        switch self {
        case .notFound: return 404
        case .packageNotAllowed: return 403
        case .visitorTokenInvalid: return 401
        case .validation: return 422
        case .prechatRequired: return 428
        case .http(let status, _): return status
        case .network: return 0
        }
    }
}

// MARK: - Init diagnostics

/// Why the last `POST /sdk/v1/init` failed — diagnostics for the host developer, never shown to
/// end users. Safe to print as is: the appKey is reduced to its last 4 characters and init never
/// carries a token.
public struct SdkInitError: Equatable, Sendable {
    /// HTTP status; 0 when the request got no response.
    public let status: Int
    /// API error code (`not_found`, `route_not_found`, …), `network_error`, or `http_<status>`.
    public let code: String
    /// URL that was called.
    public let url: String
    /// What to check first; nil when the code says it all.
    public let hint: String?
    /// The appKey that was sent, already reduced to its last 4 characters.
    public let appKeyHint: String

    /// `HTTP 404 · route_not_found`, or just the code when there is no status.
    public var summary: String { status > 0 ? "HTTP \(status) · \(code)" : code }

    /// One line for the console (os_log) — the same text `initError` carries.
    public var logLine: String {
        "init failed — POST \(url) → \(summary) · appKey \(appKeyHint)" + (hint.map { " · \($0)" } ?? "")
    }

    /// API base URL for the ID market, used in the hints. INTL workspaces use `https://api.narachat.com/api`.
    public static let exampleBaseUrl = "https://api.nara.ai.id/api"

    /// Classifies whatever `NaraChat.configure` threw. A non-`SdkError` means the answer was not a
    /// JSON config (a web page instead of the API) — `url` must come without a query string.
    static func from(_ error: Error, url: String, appKey: String?) -> SdkInitError {
        let sdk = error as? SdkError
        let status = sdk?.httpStatus ?? 0
        let code = sdk?.apiCode ?? String(describing: type(of: error))
        return SdkInitError(
            status: status, code: code, url: url,
            hint: hint(status: status, code: code), appKeyHint: mask(appKey)
        )
    }

    /// At most the last 4 characters; a short secret yields no character at all.
    static func mask(_ secret: String?) -> String {
        guard let secret, secret.count > 4 else { return "…" }
        return "…" + String(secret.suffix(4))
    }

    static func hint(status: Int, code: String) -> String? {
        if status == 404 {
            // A wrong baseUrl (no /api prefix) answers route_not_found; an unknown key answers not_found.
            let extra = code == "route_not_found"
                ? " — rute /sdk/v1 tidak dikenal: baseUrl harus alamat API, diakhiri /api"
                : ""
            return "cek appKey & baseUrl (contoh \(exampleBaseUrl))" + extra
        }
        switch code {
        case "sdk_package_not_allowed":
            return "tambahkan bundle id app ini ke daftar yang diizinkan (dashboard → Mobile SDK)"
        case "network_error":
            return "periksa koneksi internet & baseUrl (contoh \(exampleBaseUrl))"
        case "DecodingError", "bad_response":
            return "respons bukan JSON config — cek baseUrl, harus alamat API (contoh \(exampleBaseUrl))"
        default:
            return nil
        }
    }
}

private extension Optional where Wrapped == String {
    var nonBlank: String? {
        guard let value = self, !value.isEmpty, value != "null" else { return nil }
        return value
    }
}
