import Foundation
import os

/// URLSession implementation of `SdkApi` against `/sdk/v1` (SDK API v1).
/// Only Foundation — no third-party dependency, keeps the SDK light.
/// `@unchecked Sendable`: all stored state is immutable; the decoder is created per call.
public final class SdkApiURLSession: @unchecked Sendable, SdkApi {

    public let baseUrl: String
    public let wsUrl: String
    private let session: URLSession
    /// Gets one line per unreadable answer — status, content type and size, never the body.
    private let log: (String) -> Void

    public init(
        baseUrl: String,
        session: URLSession = .shared,
        log: @escaping (String) -> Void = { line in
            os_log(.error, log: SdkApiURLSession.osLog, "%{public}@", line)
        }
    ) {
        self.baseUrl = baseUrl.hasSuffix("/") ? String(baseUrl.dropLast()) : baseUrl
        self.wsUrl = Self.toWs(self.baseUrl) + "/sdk/v1/ws"
        self.session = session
        self.log = log
    }

    /// `@usableFromInline`: referenced from the public init's default argument, stays out of the public API.
    @usableFromInline static let osLog = OSLog(subsystem: "id.nara.livechat", category: "NaraLiveChat")

    private static func toWs(_ base: String) -> String {
        if base.hasPrefix("https://") { return String(base.dropFirst("https://".count)).withPrefix("wss://") }
        if base.hasPrefix("http://") { return String(base.dropFirst("http://".count)).withPrefix("ws://") }
        return base
    }

    /// `wsUrl` with the visitor token as its only query value; nil when `wsUrl` is not a ws(s) address.
    static func socketUrl(wsUrl: String, token: String) -> URL? {
        guard var parts = URLComponents(string: wsUrl),
              let scheme = parts.scheme, ["ws", "wss"].contains(scheme.lowercased()) else { return nil }
        parts.queryItems = [URLQueryItem(name: "token", value: token)]
        return parts.url
    }

    /// The path alone, for the log — never the query, which carries the token.
    static func socketPath(wsUrl: String) -> String {
        // iOS 17+ parses almost any string as a relative URL, so only a ws(s) address counts.
        guard let parts = URLComponents(string: wsUrl),
              let scheme = parts.scheme, ["ws", "wss"].contains(scheme.lowercased()),
              !parts.path.isEmpty else { return "/sdk/v1/ws" }
        return parts.path
    }

    private var api: String { baseUrl + "/sdk/v1" }

    // ---------------------------------------------------------------- routes

    public func initSdk(appKey: String, platform: String, bundleId: String, sdkVersion: String) async throws -> WidgetConfig {
        try await post("\(api)/init", body: [
            "appKey": appKey, "platform": platform, "package": bundleId, "sdkVersion": sdkVersion,
        ])
    }

    public func createSession(
        appKey: String, bundleId: String, token: String?,
        login: LoginPayload?, setUser: SetUserPayload?, page: PagePayload?
    ) async throws -> SdkSession {
        var body: [String: Any] = ["appKey": appKey, "package": bundleId]
        if let token { body["token"] = token }
        if let login {
            var l: [String: Any] = ["userId": login.userId, "userHash": login.userHash]
            if let n = login.name { l["name"] = n }
            if let e = login.email { l["email"] = e }
            body["login"] = l
        }
        if let setUser {
            var s: [String: Any] = [:]
            if let n = setUser.name { s["name"] = n }
            if let e = setUser.email { s["email"] = e }
            body["setUser"] = s
        }
        if let page { body["page"] = page.asBody } // object per tPage (controller), never a string
        return try await post("\(api)/session", body: body)
    }

    public func messages(token: String, before: String?, limit: Int) async throws -> MessagePage {
        var url = "\(api)/messages?limit=\(max(1, min(100, limit)))"
        if let before { url += "&before=\(encode(before))" }
        return try await get(url, token: token)
    }

    public func sendMessage(token: String, text: String, clientId: String) async throws -> ChatMessage {
        try await post("\(api)/messages", token: token, expected: 201, body: [
            "text": String(text.prefix(2000)), "clientId": clientId,
        ])
    }

    public func upload(token: String, fileURL: URL, fileName: String, mime: String, caption: String?, clientId: String) async throws -> ChatMessage {
        let boundary = "nara-\(UUID().uuidString)"
        var req = URLRequest(url: try url("\(api)/upload"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var data = Data()
        func part(name: String, value: String) {
            data.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        part(name: "clientId", value: clientId)
        if let caption { part(name: "caption", value: caption) }
        let fileData = try Data(contentsOf: fileURL)
        data.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\nContent-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
        data.append(fileData)
        data.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = data
        return try await perform(req, expected: 201)
    }

    public func markRead(token: String, upToMessageId: String) async throws {
        struct Body: Codable { let upToMessageId: String }
        let _: EmptyResponse = try await post("\(api)/read", token: token, body: ["upToMessageId": upToMessageId])
    }

    public func unread(token: String) async throws -> UnreadCount {
        try await get("\(api)/unread", token: token)
    }

    public func helpOverview(appKey: String) async throws -> HelpOverview {
        try await get("\(api)/help?appKey=\(encode(appKey))")
    }

    public func helpSearch(appKey: String, query: String) async throws -> HelpOverview {
        try await get("\(api)/help/search?appKey=\(encode(appKey))&q=\(encode(query))")
    }

    public func helpArticle(appKey: String, slug: String) async throws -> HelpArticle {
        try await get("\(api)/help/articles/\(encode(slug))?appKey=\(encode(appKey))")
    }

    public func registerDeviceToken(token: String, platform: String, deviceToken: String) async throws -> DeviceTokenResult {
        try await post("\(api)/device-token", token: token, body: ["platform": platform, "token": deviceToken])
    }

    public func deleteDeviceToken(token: String, deviceToken: String) async throws {
        var req = URLRequest(url: try url("\(api)/device-token?token=\(encode(deviceToken))"))
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let _: EmptyResponse = try await perform(req, expected: 204)
    }

    // ---------------------------------------------------------------- plumbing

    private struct EmptyResponse: Codable {}

    /// Never trap on a malformed URL (e.g. a bad user-typed baseUrl) — surface it as an error.
    private func url(_ s: String) throws -> URL {
        guard let u = URL(string: s) else { throw SdkError.network(URLError(.badURL)) }
        return u
    }

    private func get<T: Decodable>(_ url: String, token: String? = nil) async throws -> T {
        var req = URLRequest(url: try self.url(url))
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return try await perform(req)
    }

    private func post<T: Decodable>(_ url: String, token: String? = nil, expected: Int = 200, body: [String: Any]) async throws -> T {
        var req = URLRequest(url: try self.url(url))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await perform(req, expected: expected)
    }

    private func perform<T: Decodable>(_ req: URLRequest, expected: Int = 200) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw SdkError.network(error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == expected || (expected == 200 && (200..<300).contains(status)) else {
            throw SdkError.from(status: status, body: data)
        }
        if T.self == EmptyResponse.self { return EmptyResponse() as! T }
        if data.isEmpty { throw unreadable(req, response: response, data: data, what: "empty body") }
        // One decoder per call — JSONDecoder is not documented safe for concurrent decode().
        let decoder = JSONDecoder()
        let value: T
        do {
            value = try Self.decode(from: data, decoder: decoder)
        } catch {
            throw unreadable(req, response: response, data: data, what: Self.reason(error))
        }
        return value
    }

    /// Reads one JSON body; chat messages get the unknown-type fallback applied per spec.
    private static func decode<T: Decodable>(from data: Data, decoder: JSONDecoder) throws -> T {
        if T.self == ChatMessage.self, let m = try? decoder.decode(ChatMessage.self, from: data) {
            return ChatMessage.withFallback(m, locale: "id") as! T
        }
        if T.self == SdkSession.self, let s = try? decoder.decode(SdkSession.self, from: data) {
            let mapped = SdkSession(
                token: s.token, expiresAt: s.expiresAt, visitor: s.visitor,
                conversationId: s.conversationId, prechatRequired: s.prechatRequired,
                handler: s.handler,
                messages: s.messages.map { ChatMessage.withFallback($0, locale: "id") },
                hasMore: s.hasMore, identity: s.identity
            )
            return mapped as! T
        }
        if T.self == MessagePage.self, let p = try? decoder.decode(MessagePage.self, from: data) {
            let mapped = MessagePage(items: p.items.map { ChatMessage.withFallback($0, locale: "id") }, hasMore: p.hasMore)
            return mapped as! T
        }
        return try decoder.decode(T.self, from: data)
    }

    /// An unreadable 2xx body leaves the SDK as `bad_response`, never as a bare decoding error.
    /// The log line carries method, path, status, content type and size — never the body or query.
    private func unreadable(_ req: URLRequest, response: URLResponse, data: Data, what: String) -> SdkError {
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let type = http?.value(forHTTPHeaderField: "Content-Type").map { String($0.prefix(80)) } ?? "no content-type"
        log("\(req.httpMethod ?? "GET") \(req.url?.path ?? "") → \(SdkError.badResponseCode): \(what) (HTTP \(status), \(type), \(data.count) bytes)")
        return .badResponse(status: status)
    }

    /// What was wrong with the body — for the log line only.
    private static func reason(_ error: Error) -> String {
        if case DecodingError.keyNotFound = error { return "missing field" }
        return "not JSON or cut off"
    }

    private func encode(_ v: String) -> String {
        v.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? v
    }
}

extension CharacterSet {
    /// Query value encoding that keeps `/` escaped inside path segments too.
    static let urlQueryValueAllowed: CharacterSet = {
        var c = CharacterSet.alphanumerics
        c.insert(charactersIn: "-._~")
        return c
    }()
}

private extension String {
    func withPrefix(_ p: String) -> String { p + self }
}
