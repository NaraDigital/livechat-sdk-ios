import Foundation

/// The `/sdk/v1` contract as seen by the SDK. Pure protocol so tests and the sample app
/// can swap in a fake without touching URLSession — full parity with Android's `SdkApi`.
public protocol SdkApi: Sendable {
    func initSdk(appKey: String, platform: String, bundleId: String, sdkVersion: String) async throws -> WidgetConfig

    func createSession(
        appKey: String,
        bundleId: String,
        token: String?,
        login: LoginPayload?,
        setUser: SetUserPayload?,
        page: PagePayload?
    ) async throws -> SdkSession

    func messages(token: String, before: String?, limit: Int) async throws -> MessagePage

    func sendMessage(token: String, text: String, clientId: String) async throws -> ChatMessage

    func upload(token: String, fileURL: URL, fileName: String, mime: String, caption: String?, clientId: String) async throws -> ChatMessage

    func markRead(token: String, upToMessageId: String) async throws

    func unread(token: String) async throws -> UnreadCount

    func helpOverview(appKey: String) async throws -> HelpOverview

    func helpSearch(appKey: String, query: String) async throws -> HelpOverview

    func helpArticle(appKey: String, slug: String) async throws -> HelpArticle

    func registerDeviceToken(token: String, platform: String, deviceToken: String) async throws -> DeviceTokenResult

    func deleteDeviceToken(token: String, deviceToken: String) async throws
}

public struct LoginPayload: Sendable, Codable {
    public let userId: String
    public let userHash: String
    public let name: String?
    public let email: String?
    public init(userId: String, userHash: String, name: String?, email: String?) {
        self.userId = userId; self.userHash = userHash; self.name = name; self.email = email
    }
}

public struct SetUserPayload: Sendable, Codable {
    public let name: String?
    public let email: String?
    public init(name: String?, email: String?) { self.name = name; self.email = email }
}
