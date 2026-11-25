import Foundation
import Combine
import SwiftUI
import UIKit
import os

/**
 Public entry point of the SDK (the API app developers call).
 Full parity with the Android SDK.

 ```swift
 NaraChat.shared.configure(appKey: "nk_…", baseUrl: "https://api.nara.ai.id/api")
 NaraChat.shared.login(userId: uid, email: e, name: n, userHash: h) // hash = HMAC from your backend
 NaraChat.shared.present()                                          // presents the SwiftUI messenger
 ```

 `baseUrl` is the API address and must end with `/api` — the SDK calls `<baseUrl>/sdk/v1/…`.
 It defaults to `NaraChat.defaultBaseUrl`, so the parameter is only needed for another host.
 */
public final class NaraChat: ObservableObject {

    public static let shared = NaraChat()

    public static let VERSION = "1.0.1"
    public static let PLATFORM = "ios"

    /** API base URL for the ID market. INTL workspaces use `https://api.narachat.com/api`. */
    public static let defaultBaseUrl = "https://api.nara.ai.id/api"

    private static let log = OSLog(subsystem: "id.nara.livechat", category: "NaraLiveChat")

    // Public observable surface
    @Published public private(set) var unreadCount = 0
    @Published public private(set) var configValue: WidgetConfig?
    @Published public private(set) var updateRequired = false

    /**
     Why the last `configure` failed — status, API code and the URL called, for the host
     developer. Nil while init has not run, is in flight, or succeeded. The same text goes to
     the console (os_log, subsystem `id.nara.livechat`, category `NaraLiveChat`).
     */
    @Published public private(set) var initError: SdkInitError?

    public private(set) var appKey: String?
    public private(set) var baseUrl = NaraChat.defaultBaseUrl

    public var locale: String? // nil = follow server config
    public var themeOverride: ThemeOverride?

    public struct ThemeOverride {
        public var primary: String?
        public var background: String?
        public var text: String?
        public var bubbleVisitor: String?
        public var bubbleVisitorText: String?
        public var bubbleAgent: String?
        public var bubbleAgentText: String?
        public init(
            primary: String? = nil, background: String? = nil, text: String? = nil,
            bubbleVisitor: String? = nil, bubbleVisitorText: String? = nil,
            bubbleAgent: String? = nil, bubbleAgentText: String? = nil
        ) {
            self.primary = primary; self.background = background; self.text = text
            self.bubbleVisitor = bubbleVisitor; self.bubbleVisitorText = bubbleVisitorText
            self.bubbleAgent = bubbleAgent; self.bubbleAgentText = bubbleAgentText
        }
    }

    let store = SdkStore()
    var api: SdkApi = SdkApiURLSession(baseUrl: NaraChat.defaultBaseUrl)

    /// The messenger's hosting controller while it is on screen; the root view hands it
    /// the status bar style.
    weak var hostingController: NaraHostingController?

    /// In-memory pending identity until the next session call picks it up.
    var pendingIdentity: IdentityRules.Identity = .anonymous

    /// Bumped per `configure` so a slow answer from an earlier call cannot overwrite a newer one.
    private var initGeneration = 0

    private var cancellables = Set<AnyCancellable>()

    private init() {}

    // ------------------------------------------------------------ lifecycle

    /// Names the app the SDK serves. Called again for another app — another key, or another host —
    /// the previous app's session, identity and push binding go first, as by `logout`. That goes
    /// for the first call after a restart too: the app the stored session was made for is the one
    /// being left. Addresses that differ only in scheme, letter case or a closing slash name the same app.
    public func configure(appKey: String, baseUrl: String? = nil) {
        let next = SdkApp(appKey: appKey, baseUrl: baseUrl ?? self.baseUrl)
        // The keeper hears of the next app after the swap below, so the API of the app being left goes with it.
        let previous = api
        self.appKey = next.appKey
        self.baseUrl = next.baseUrl
        self.api = SdkApiURLSession(baseUrl: self.baseUrl)
        Task { [self] in _ = await refreshInit() }
        Task { @MainActor [self] in
            if SessionManager.shared.apiChanged(to: next, through: previous) {
                pendingIdentity = .anonymous
                unreadCount = 0 // @Published — publish on main
            }
        }
    }

    /// Swap the API (tests / preview).
    public func setApiForTesting(_ fake: SdkApi) {
        api = fake
    }

    /// `init` answered, or nil when the call failed. An answer a later call outran is still handed
    /// back — whoever asked needed to know — but only the latest answer is put on hand.
    private func refreshInit() async -> WidgetConfig? {
        guard let appKey else { return nil }
        let bundleId = Bundle.main.bundleIdentifier ?? ""
        // Init is a POST with a JSON body — nothing sensitive is ever in this URL.
        let base = baseUrl.hasSuffix("/") ? String(baseUrl.dropLast()) : baseUrl
        let initUrl = base + "/sdk/v1/init"
        initGeneration += 1
        let generation = initGeneration
        do {
            let cfg = try await api.initSdk(appKey: appKey, platform: Self.PLATFORM, bundleId: bundleId, sdkVersion: Self.VERSION)
            guard generation == initGeneration else { return cfg }
            await MainActor.run {
                let wasOffline = configValue?.isOfflineMode == true
                configValue = cfg
                updateRequired = cfg.sdk?.updateRequired == true
                initError = nil
                SessionManager.shared.configChanged(wasOffline: wasOffline, isOffline: cfg.isOfflineMode)
            }
            return cfg
        } catch {
            guard generation == initGeneration else { return nil }
            // The config on hand stays (nil at first → the UI falls back to defaults). The host
            // developer gets status, code and URL in the console and `initError`; the user never
            // sees raw codes.
            let failure = SdkInitError.from(error, url: initUrl, appKey: appKey)
            os_log(.error, log: Self.log, "%{public}@", failure.logLine)
            await MainActor.run { initError = failure }
            return nil
        }
    }

    /// Fetches the config again — the Style SDK edited in the dashboard (language, mode, colors,
    /// greeting, logo) applies when the messenger opens and when it returns to the foreground.
    /// Nothing before `configure`; on failure the config on hand stays.
    func refreshConfig() {
        Task { [self] in _ = await refreshInit() }
    }

    /// `init` again, answered with the config now on hand — for whoever has to know whether the
    /// widget takes a chat before going on. A failed call answers with what was on hand before.
    func reloadConfig() async -> WidgetConfig? {
        if let answer = await refreshInit() { return answer }
        return await MainActor.run { configValue }
    }

    // ------------------------------------------------------------ identity

    /// Verified identity. `userHash = hex(HMAC-SHA256(identitySecret, userId))` — computed by the
    /// app's own backend; the secret never ships in the app. Skips the prechat form; history
    /// follows the user across devices and reinstalls. The session on hand is replaced at once —
    /// with the stored token, so the server keeps it the same visitor.
    public func login(userId: String, email: String?, name: String?, userHash: String) {
        let cleanName = IdentityRules.sanitizeName(name)
        let cleanEmail = IdentityRules.sanitizeEmail(email)
        pendingIdentity = .login(userId: userId, userHash: userHash, name: cleanName, email: cleanEmail)
        store.cachedName = cleanName
        store.cachedEmail = cleanEmail
        sessionReplaced()
    }

    /// Unverified identity: skips the prechat form, history stays on this device only. Replaces
    /// the session on hand, like `login`.
    public func setUser(name: String?, email: String?) {
        pendingIdentity = unverified(name: name, email: email)
        sessionReplaced()
    }

    /// The prechat form's answer; the form's caller replaces the session in the same step.
    func adoptPrechatAnswer(name: String, email: String?) {
        pendingIdentity = unverified(name: name, email: email)
    }

    /// An unverified identity out of what the app handed in; the cache is filled with it too.
    private func unverified(name: String?, email: String?) -> IdentityRules.Identity {
        let cleanName = IdentityRules.sanitizeName(name)
        let cleanEmail = IdentityRules.sanitizeEmail(email)
        store.cachedName = cleanName
        store.cachedEmail = cleanEmail
        return .setUser(name: cleanName, email: cleanEmail)
    }

    /// The identity changed: the session on hand was made for another one.
    private func sessionReplaced() {
        Task { @MainActor in SessionManager.shared.replaceSession() }
    }

    /// Logs out: the session and its stored token go, this device's push is unbound from them,
    /// and the next session starts anonymous and follows the form rules again.
    public func logout() {
        pendingIdentity = .anonymous
        Task { @MainActor in
            SessionManager.shared.logout()
            self.unreadCount = 0 // @Published — publish on main
        }
    }

    /// Extra / custom contact attributes (spec parity with Android).
    public func updateUser(attributes: [String: String]) {
        let name = attributes["name"] ?? store.cachedName
        let email = attributes["email"] ?? store.cachedEmail
        if store.verifiedUserId != nil {
            store.cachedName = name
            store.cachedEmail = email
        } else {
            setUser(name: name, email: email)
        }
    }

    // ------------------------------------------------------------ UI

    /// Presents the messenger UI full screen from the top-most view controller.
    /// Safe to call from any thread — UIKit work is always hopped to the main thread.
    public func present(destination: NaraDestination = .home) {
        DispatchQueue.main.async {
            // The Style SDK may have been edited in the dashboard since `configure`.
            self.refreshConfig()
            let vc = NaraHostingController(rootView: NaraChatRootView(start: destination, articleSlug: nil))
            vc.modalPresentationStyle = .fullScreen
            self.hostingController = vc
            Self.topMostViewController()?.present(vc, animated: true)
        }
    }

    public func presentMessages() { present(destination: .messages) }
    public func presentHelp() { present(destination: .help) }
    public func presentArticle(slug: String) {
        DispatchQueue.main.async {
            self.refreshConfig()
            let vc = NaraHostingController(rootView: NaraChatRootView(start: .help, articleSlug: slug))
            vc.modalPresentationStyle = .fullScreen
            self.hostingController = vc
            Self.topMostViewController()?.present(vc, animated: true)
        }
    }

    private static func topMostViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow)
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    // ------------------------------------------------------------ push & unread

    /// Register the APNs token. It is bound to the session on hand; without one, the next session binds it.
    public func setDeviceToken(_ token: String) {
        store.pushToken = token
        Task { @MainActor in SessionManager.shared.bindDeviceToken() }
    }

    /**
     Call from `UNUserNotificationCenter` didReceive / notification tap.
     Returns true when the payload is a Nara chat push (open the chat); false so the app
     can handle other pushes itself.
     */
    public func handlePush(userInfo: [AnyHashable: Any]) -> Bool {
        // Read the key directly — the APNs payload also carries a nested `aps` dict, so a
        // whole-dictionary cast to [String: String] would always fail.
        guard (userInfo["type"] as? String) == "agent_reply", appKey != nil else {
            return false
        }
        Task { @MainActor in _ = await SessionManager.shared.ensureSession() }
        return true
    }

    /// Reads `@MainActor`-isolated session state, so everything happens inside the task.
    func refreshUnread() {
        Task { @MainActor in
            guard let session = SessionManager.shared.current, self.appKey != nil else { return }
            let count = try? await self.api.unread(token: session.token)
            // The session was replaced meanwhile: its unread count is not the one on screen.
            guard SessionManager.shared.current?.token == session.token, let u = count else { return }
            self.unreadCount = u.count
        }
    }

    public func setLocale(_ locale: String?) {
        self.locale = locale
    }

    /// Open the chat from a push notification tap.
    public func openChatFromPush() {
        present(destination: .messages)
    }
}

/// The messenger's hosting controller: the interface style is pinned to the SDK display mode
/// (`style.sdk.mode`) so the status bar, keyboard and sheets follow the widget, not the phone.
final class NaraHostingController: UIHostingController<NaraChatRootView> {
    private var modeObserver: AnyCancellable?

    /// True while the Home hero sits under the status bar: the icons take their contrast
    /// from the hero there and from the page background everywhere else.
    var heroUnderStatusBar = false {
        didSet { if heroUnderStatusBar != oldValue { setNeedsStatusBarAppearanceUpdate() } }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        applyDisplayMode()
        // Published emits before the property is set, so the style is read on a later main turn.
        modeObserver = NaraChat.shared.$configValue
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyDisplayMode() }
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        let palette = Self.palette()
        let surface = heroUnderStatusBar ? palette.hero : palette.background
        return SdkThemeRules.luminance(surface) < 0.5 ? .lightContent : .darkContent
    }

    private func applyDisplayMode() {
        overrideUserInterfaceStyle = Self.palette().dark ? .dark : .light
        setNeedsStatusBarAppearanceUpdate()
    }

    private static func palette() -> SdkThemeRules.Palette {
        SdkThemeRules.palette(
            sdk: NaraChat.shared.configValue?.style?.sdk,
            override: NaraChat.shared.themeOverride
        )
    }
}

/// Destinations inside the SDK UI.
public enum NaraDestination {
    case home, messages, help
}
