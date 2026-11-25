import Foundation

/// What the session keeps on the device: `SdkStore` in the app, a few fields in tests.
protocol SessionStoring: AnyObject {
    var visitorToken: String? { get set }
    var verifiedUserId: String? { get set }
    var pushToken: String? { get set }
    /// The app the stored token was made for; nothing is stored without a token.
    var tokenOwner: SdkApp? { get set }
}

extension SdkStore: SessionStoring {}

/// The app the SDK serves: its key, and the address its API answers on. `key` names the app across
/// launches: the address in lower case, without its scheme and without a closing slash —
/// `https://A/api/` and `http://a/api` are one app; only another key, host, port or path is another.
struct SdkApp: Equatable {
    let appKey: String
    let baseUrl: String

    var key: String { appKey + "@" + Self.address(baseUrl) }

    /// `https://Host:port/path/` → `host:port/path`.
    static func address(_ baseUrl: String) -> String {
        let lower = baseUrl.lowercased()
        let bare = ["https://", "http://"]
            .first(where: { lower.hasPrefix($0) })
            .map { String(lower.dropFirst($0.count)) } ?? lower
        var end = bare.endIndex
        while end > bare.startIndex, bare[bare.index(before: end)] == "/" { end = bare.index(before: end) }
        return String(bare[..<end])
    }
}

/// The one visitor session: made for the identity at hand, replaced when that identity changes,
/// forgotten on logout, and left when `configure` names another app — after a restart, by the app
/// stored with the token. Everything it needs is handed in — `SessionManager` hands in the app's
/// API, store and identity — which is what makes these rules testable. Same rules as Android.
@MainActor
final class SessionKeeper {

    /// What one session call is made of.
    struct Request {
        var token: String?
        var login: LoginPayload?
        var setUser: SetUserPayload?
    }

    @MainActor
    protocol Listener: AnyObject {
        /// The session is on hand now: the list on screen is its own.
        func sessionKeeper(_ keeper: SessionKeeper, didApply session: SdkSession)
        /// No session is on hand; nothing of the previous one may stay on screen.
        func sessionKeeperDidForget(_ keeper: SessionKeeper)
        func sessionKeeper(_ keeper: SessionKeeper, didFail step: String, error: Error)
        /// The widget went offline, so no session was made — and none is missing on screen.
        func sessionKeeperDidSuspend(_ keeper: SessionKeeper)
    }

    private let api: () -> SdkApi
    /// The API of an app no longer on hand: the one the stored session was made through.
    private let apiFor: (SdkApp) -> SdkApi
    private let store: SessionStoring
    private let platform: String
    private let identity: () -> IdentityRules.Identity
    private let listener: Listener
    /// True while the widget takes no chat (`init` said `mode: "offline"`): no session is asked for then.
    private let suspended: () -> Bool
    /// `init` asked again; nil when that call failed.
    private let config: () async -> WidgetConfig?

    private(set) var current: SdkSession?

    /// Bumped whenever the session on hand is forgotten; a session in the making for an earlier one is not kept.
    private var generation = 0

    /// The app `configure` named last; nil until it names one.
    private var app: SdkApp?

    /// The session creation under way, so two callers never make a session each.
    private var creating: Task<SdkSession?, Never>?

    /// Push bindings run one at a time, in the order asked; this is the last one queued.
    private var pushTail: Task<Void, Never>?

    init(
        api: @escaping () -> SdkApi,
        apiFor: @escaping (SdkApp) -> SdkApi,
        store: SessionStoring,
        platform: String,
        identity: @escaping () -> IdentityRules.Identity,
        listener: Listener,
        suspended: @escaping () -> Bool = { false },
        config: @escaping () async -> WidgetConfig? = { nil }
    ) {
        self.api = api
        self.apiFor = apiFor
        self.store = store
        self.platform = platform
        self.identity = identity
        self.listener = listener
        self.suspended = suspended
        self.config = config
    }

    /// The session on hand, or a new one for the identity at hand: made with the stored token, so
    /// the server keeps it the same visitor when that identity changed.
    func ensure(appKey: String, bundleId: String, forceNew: Bool = false) async -> SdkSession? {
        // An offline widget answers no session call: its notice stands in for the chat.
        if suspended() { return nil }
        if !forceNew, let current { return current }
        // A creation under way is waited for, not duplicated: it ends in a session, or in none.
        while let running = creating {
            _ = await running.value
            if !forceNew, let current { return current }
        }
        let task = Task { @MainActor in
            defer { self.creating = nil }
            return await self.make(appKey: appKey, bundleId: bundleId)
        }
        creating = task
        return await task.value
    }

    /// Asked for an identity that changed while the server answered: that session is not kept; the
    /// next one is made for the identity at hand now.
    private func make(appKey: String, bundleId: String) async -> SdkSession? {
        while true {
            let asked = generation
            let request = requestFor(identity())
            do {
                let session = try await createSession(appKey: appKey, bundleId: bundleId, request: request)
                if asked == generation {
                    keep(session)
                    return session
                }
            } catch {
                if asked == generation {
                    // `notFound` is also what a widget that went offline since `init` answers:
                    // one more look, never a retry.
                    var offline = false
                    if (error as? SdkError) == .notFound {
                        offline = (await config())?.isOfflineMode == true
                    }
                    // The session may have been forgotten while `init` answered.
                    if asked != generation { return nil }
                    if offline {
                        listener.sessionKeeperDidSuspend(self)
                    } else {
                        listener.sessionKeeper(self, didFail: "createSession", error: error)
                    }
                    return nil
                }
            }
        }
    }

    private func requestFor(_ identity: IdentityRules.Identity) -> Request {
        var request = Request(token: store.visitorToken)
        switch identity {
        case .login(let userId, let userHash, let name, let email):
            request.login = LoginPayload(userId: userId, userHash: userHash, name: name, email: email)
        case .setUser(let name, let email):
            request.setUser = SetUserPayload(name: name, email: email)
        case .anonymous:
            break
        }
        return request
    }

    /// A stored token the server no longer knows costs one more try without it.
    private func createSession(appKey: String, bundleId: String, request: Request) async throws -> SdkSession {
        do {
            return try await api().createSession(
                appKey: appKey, bundleId: bundleId, token: request.token,
                login: request.login, setUser: request.setUser, page: nil
            )
        } catch SdkError.visitorTokenInvalid {
            store.visitorToken = nil
            return try await api().createSession(
                appKey: appKey, bundleId: bundleId, token: nil,
                login: request.login, setUser: request.setUser, page: nil
            )
        }
    }

    private func keep(_ session: SdkSession) {
        current = session
        store.visitorToken = session.token
        // Goes with the token: after a restart it says whose session this is.
        store.tokenOwner = app
        store.verifiedUserId = session.identity.verified ? session.identity.userId : nil
        listener.sessionKeeper(self, didApply: session)
        bindPush(to: session.token)
    }

    /// The identity changed: the session on hand goes, what is stored stays — the next one is the same visitor.
    func replace() {
        forget(dropToken: false)
    }

    /// Logout: with the session go its stored token and this device's push binding.
    func clear() {
        forget(dropToken: true)
    }

    /// `configure` named the app again. Another app than before gets none of the previous one's
    /// session, token or push binding; `previous` is the API those were made with.
    ///
    /// After a restart no app is on hand: the one stored with the token stands in for the previous
    /// app, and the unbind leaves through that host's API. The same app, or no token stored: nothing goes.
    @discardableResult
    func switchTo(_ next: SdkApp, through previous: SdkApi) -> Bool {
        if let before = app {
            app = next
            guard before.key != next.key else { return false }
            forget(dropToken: true, unbindingThrough: previous)
            return true
        }
        app = next
        guard let owner = store.tokenOwner, store.visitorToken != nil, owner.key != next.key else { return false }
        forget(dropToken: true, unbindingThrough: apiFor(owner))
        return true
    }

    /// `previous` is the API the unbind has to leave through when the one on hand is no longer it.
    private func forget(dropToken: Bool, unbindingThrough previous: SdkApi? = nil) {
        generation += 1
        let old = current
        let stored = store.visitorToken
        current = nil
        if dropToken {
            store.visitorToken = nil
            store.verifiedUserId = nil
            store.tokenOwner = nil
            // The stored token counts too: the chat may not have been opened since the last launch.
            if let sessionToken = old?.token ?? stored, let device = store.pushToken {
                unbindPush(sessionToken: sessionToken, device: device, through: previous ?? api())
            }
        }
        listener.sessionKeeperDidForget(self)
    }

    /// A device token that arrived while a session was already on hand.
    func bindDeviceToken() {
        if let current, store.pushToken != nil { bindPush(to: current.token) }
    }

    /// The device's push token follows the session on hand, so a reply for the previous user no longer arrives.
    private func bindPush(to sessionToken: String) {
        guard let device = store.pushToken else { return }
        let target = api()
        enqueuePush { [platform] in
            _ = try? await target.registerDeviceToken(token: sessionToken, platform: platform, deviceToken: device)
        }
    }

    /// The API is taken here, not when the call runs: `configure` may have put another app's on hand by then.
    private func unbindPush(sessionToken: String, device: String, through target: SdkApi) {
        enqueuePush { _ = try? await target.deleteDeviceToken(token: sessionToken, deviceToken: device) }
    }

    /// Push bindings run one at a time, in the order asked. The server unbinds by device token
    /// alone, so an unbind that overtook a later bind would cut the new session off.
    private func enqueuePush(_ call: @escaping () async -> Void) {
        let before = pushTail
        pushTail = Task { @MainActor in
            if let before { _ = await before.value }
            await call()
        }
    }
}
