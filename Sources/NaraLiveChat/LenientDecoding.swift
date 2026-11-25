import Foundation

// Lenient decoding for the SDK API payloads, field for field the rules of the Android SDK's
// parser (`model/Models.kt`, `Json`): a missing, null or wrongly typed field takes the same
// default as on Android instead of failing the whole answer. Only the fields Android reads
// with `getString` stay required (config: none; session: token and expiresAt; message: id).

struct AnyKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

extension KeyedDecodingContainer where Key == AnyKey {
    /// Android `str(key)`: nil when missing, null, not a string, or empty.
    func str(_ k: String) -> String? {
        guard let s = (try? decodeIfPresent(String.self, forKey: AnyKey(k))) ?? nil, !s.isEmpty else { return nil }
        return s
    }
    /// Android `str(key, default)`: the default for a missing, null or non-string value.
    func str(_ k: String, _ fallback: String) -> String {
        ((try? decodeIfPresent(String.self, forKey: AnyKey(k))) ?? nil) ?? fallback
    }
    func bool(_ k: String, _ fallback: Bool) -> Bool {
        ((try? decodeIfPresent(Bool.self, forKey: AnyKey(k))) ?? nil) ?? fallback
    }
    func int(_ k: String, _ fallback: Int) -> Int {
        ((try? decodeIfPresent(Int.self, forKey: AnyKey(k))) ?? nil) ?? fallback
    }
    /// The nested object, or nil when it is missing, null or unreadable.
    func obj<T: Decodable>(_ k: String) -> T? {
        (try? decodeIfPresent(T.self, forKey: AnyKey(k))) ?? nil
    }
    /// The readable elements of an array; empty when the key is missing, null or not an array.
    func list<T: Decodable>(_ k: String) -> [T] {
        let items = ((try? decodeIfPresent([Lenient<T>].self, forKey: AnyKey(k))) ?? nil) ?? []
        return items.compactMap(\.value)
    }
    func required(_ k: String) throws -> String {
        try decode(String.self, forKey: AnyKey(k))
    }
}

/// One array element that may fail to decode on its own without failing the array.
struct Lenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

extension WidgetConfig {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        key = c.str("key", "")
        name = c.str("name", "")
        style = c.obj("style")
        settings = c.obj("settings")
        aiAgent = c.obj("aiAgent")
        // Android: `optBoolean("online", true)`. A config without it is a live widget.
        online = c.bool("online", true)
        help = c.obj("help")
        mode = c.str("mode")
        sdk = c.obj("sdk")
        offline = c.obj("offline")
    }
}

extension WidgetConfig.AiAgent {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        name = c.str("name"); avatarUrl = c.str("avatarUrl")
    }
}

extension WidgetConfig.HelpCounts {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        faqs = c.int("faqs", 0); articles = c.int("articles", 0)
    }
}

extension WidgetConfig.SdkInfo {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        minSupportedVersion = c.str("minSupportedVersion")
        latestVersion = c.str("latestVersion")
        updateRequired = c.bool("updateRequired", false)
        updateRecommended = c.bool("updateRecommended", false)
    }
}

extension SdkSession {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        token = try c.required("token")
        expiresAt = try c.required("expiresAt")
        visitor = c.obj("visitor") ?? Visitor(id: "", name: nil, email: nil)
        conversationId = c.str("conversationId")
        prechatRequired = c.bool("prechatRequired", false)
        handler = c.obj("handler")
        messages = c.list("messages")
        hasMore = c.bool("hasMore", false)
        identity = c.obj("identity") ?? Identity(verified: false, userId: nil)
    }
}

extension SdkSession.Visitor {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        id = c.str("id", ""); name = c.str("name"); email = c.str("email")
    }
}

extension SdkSession.Handler {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        type = c.str("type"); name = c.str("name"); avatarUrl = c.str("avatarUrl")
    }
}

extension SdkSession.Identity {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        verified = c.bool("verified", false); userId = c.str("userId")
    }
}

extension ChatMessage {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        self.init(
            id: try c.required("id"),
            clientId: c.str("clientId"),
            from: c.str("from", "unknown"),
            senderName: c.str("senderName", ""),
            type: c.str("type", "text"),
            body: c.str("body", ""),
            media: c.obj("media"),
            status: c.str("status", "unknown"),
            sentAt: c.str("sentAt", ""),
            quoted: c.obj("quoted"),
            senderAvatarUrl: c.str("senderAvatarUrl")
        )
    }
}

extension ChatMessage.Media {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        url = c.str("url", ""); mime = c.str("mime")
    }
}

extension ChatMessage.Quote {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        id = c.str("id"); senderName = c.str("senderName"); body = c.str("body"); type = c.str("type")
    }
}

extension MessagePage {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        items = c.list("items"); hasMore = c.bool("hasMore", false)
    }
}

extension UnreadCount {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        count = c.int("count", 0)
    }
}
