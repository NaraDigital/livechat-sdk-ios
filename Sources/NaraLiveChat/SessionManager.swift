import Foundation
import Combine

/// Device-local SDK state. SK-L1: the credentials (visitor session token, push token) live
/// in the Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`), and so does the app the
/// session was made for; only non-secret display data (cached name/email, verified user id) stays
/// in UserDefaults. Values written by SDK 1.0.0 into UserDefaults migrate into the Keychain on
/// first access, so existing users keep their session. `logout()` clears everything
/// identity-related so the next session starts anonymous.
final class SdkStore {

    private let defaults: UserDefaults
    private let keychain: KeychainStore

    init(suiteName: String? = nil, keychain: KeychainStore = KeychainStore()) {
        self.defaults = suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
        self.keychain = keychain
        migrateFromUserDefaults()
    }

    private enum Key {
        static let token = "nara.visitor_token"
        static let verifiedUser = "nara.verified_user_id"
        static let name = "nara.cached_name"
        static let email = "nara.cached_email"
        static let push = "nara.push_token"
        static let ownerAppKey = "nara.owner_app_key"
        static let ownerBaseUrl = "nara.owner_base_url"
    }

    /// One-time move of plaintext credentials written by older SDK versions, then wipe.
    private func migrateFromUserDefaults() {
        for key in [Key.token, Key.push] {
            if keychain.string(key) == nil, let v = defaults.string(forKey: key) {
                keychain.set(v, key: key)
            }
            defaults.removeObject(forKey: key) // no-op when already absent
        }
    }

    var visitorToken: String? {
        get { keychain.string(Key.token) }
        set { keychain.set(newValue, key: Key.token) }
    }

    var verifiedUserId: String? {
        get { defaults.string(forKey: Key.verifiedUser) }
        set { defaults.set(newValue, forKey: Key.verifiedUser) }
    }

    var cachedName: String? {
        get { defaults.string(forKey: Key.name) }
        set { defaults.set(newValue, forKey: Key.name) }
    }

    var cachedEmail: String? {
        get { defaults.string(forKey: Key.email) }
        set { defaults.set(newValue, forKey: Key.email) }
    }

    var pushToken: String? {
        get { keychain.string(Key.push) }
        set { keychain.set(newValue, key: Key.push) }
    }

    /// The app the stored token was made for; kept with it, and goes with it.
    var tokenOwner: SdkApp? {
        get {
            guard let appKey = keychain.string(Key.ownerAppKey) else { return nil }
            return SdkApp(appKey: appKey, baseUrl: keychain.string(Key.ownerBaseUrl) ?? "")
        }
        set {
            keychain.set(newValue?.appKey, key: Key.ownerAppKey)
            keychain.set(newValue?.baseUrl, key: Key.ownerBaseUrl)
        }
    }

    func clearIdentity() {
        keychain.remove(Key.token)
        keychain.remove(Key.ownerAppKey)
        keychain.remove(Key.ownerBaseUrl)
        [Key.verifiedUser, Key.name, Key.email].forEach { defaults.removeObject(forKey: $0) }
        // pushToken stays — device-level, re-binds to the next session.
    }
}

/// Keeps the app's one visitor session — the rules are `SessionKeeper`'s — and exposes the live
/// message list, with optimistic clientId matching on send. Full parity with Android's
/// SessionManager.
@MainActor
final class SessionManager {

    static let shared = SessionManager()

    /// The session on hand: nil before the first one, after `logout()`, and between two identities.
    var current: SdkSession? { keeper.current }

    struct SessionUiState {
        var loading = false
        var messages: [ChatMessage] = []
        var hasMore = false
        var typing = false
        var typingName: String?
        var handler: SdkSession.Handler?
        var prechatMissingFields: [String] = []
        var error: String?
    }

    let state = CurrentValueSubject<SessionUiState, Never>(SessionUiState())

    /// Where the realtime link stands; `.reconnecting` is what the chat header shows.
    let realtimeState = CurrentValueSubject<RealtimeState, Never>(.stopped)

    private var nara: NaraChat { NaraChat.shared }
    private var api: SdkApi { nara.api }

    /// The session rules, handed the app's API, store and identity; this class is their wiring.
    private lazy var keeper = SessionKeeper(
        api: { NaraChat.shared.api },
        apiFor: { SdkApiURLSession(baseUrl: $0.baseUrl) },
        store: NaraChat.shared.store,
        platform: NaraChat.PLATFORM,
        identity: { NaraChat.shared.pendingIdentity },
        listener: self,
        suspended: { NaraChat.shared.configValue?.isOfflineMode == true },
        config: { await NaraChat.shared.reloadConfig() }
    )

    // ------------------------------------------------------------ realtime

    private var realtime: RealtimeConnection?
    private var realtimeCancellable: AnyCancellable?
    /// The messenger is open and wants the link up.
    private var realtimeWanted = false
    /// A session renewal for an expired token is under way.
    private var renewing = false
    /// Catches the list up over HTTP whenever the realtime link cannot be relied on.
    private lazy var syncer = MessageSyncer(source: self)
    /// Latest page fetched after a reconnect and by the fallback polling.
    private static let resyncLimit = 50
    /// The session the page in hand was read for; a page of a replaced session is dropped.
    private var pageOf: String?

    func ensureSession(forceNew: Bool = false) async -> SdkSession? {
        guard let appKey = nara.appKey else { return nil }
        return await keeper.ensure(
            appKey: appKey, bundleId: Bundle.main.bundleIdentifier ?? "", forceNew: forceNew
        )
    }

    /// `login()` / `setUser()`: the session on hand was made for another identity.
    func replaceSession() {
        sessionReplaced { keeper.replace() }
    }

    /// `logout()`. The session goes first: its token is what the push unbind is sent with. What is
    /// stored about the user goes with it, the push token stays for the next session to bind.
    func logout() {
        sessionReplaced { keeper.clear() }
        nara.store.clearIdentity()
    }

    /// A device token that arrived while a session was on hand; otherwise the next session binds it.
    func bindDeviceToken() {
        keeper.bindDeviceToken()
    }

    /// The socket of the session on hand is closed before the session goes, so nothing of it arrives after.
    private func sessionReplaced(_ forget: () -> Void) {
        realtime?.close()
        forget()
        // With the messenger open the next session is due now: the screen has nothing to show without one.
        if realtimeWanted { Task { _ = await self.ensureSession() } }
    }

    /// False once `session` was replaced: anything read with its token is then nobody's on screen.
    private func onHand(_ session: SdkSession) -> Bool {
        current?.token == session.token
    }

    /// The form shows only fields that are actually missing; provided ones arrive pre-filled.
    private func missingFields(from s: SdkSession) -> [String] {
        guard let rules = nara.configValue?.settings?.prechat, rules.enabled == true else { return [] }
        var missing: [String] = []
        if rules.requireName == true && (s.visitor.name ?? "").isEmpty { missing.append("name") }
        if rules.requireEmail == true && (s.visitor.email ?? "").isEmpty { missing.append("email") }
        return missing
    }

    private func setError(_ error: Error) {
        var st = state.value
        // Friendly, locale-aware message (parity with Android) — raw codes /
        // bodies never reach the user; the technical detail stays in the console log.
        let isId = sdkIsId(locale: nara.locale, config: nara.configValue)
        st.error = friendlyError(error, isId: isId)
        #if DEBUG
        print("[NaraLiveChat] error: \(error.localizedDescription)")
        #endif
        state.send(st)
    }

    /// Submit the prechat form — sent as setUser data on a fresh session.
    func submitPrechat(name: String, email: String?) async {
        nara.adoptPrechatAnswer(name: name, email: email)
        _ = await ensureSession(forceNew: true)
    }

    func loadMore() async -> Bool {
        guard let s = current, let oldest = state.value.messages.first?.id else { return false }
        do {
            let page = try await api.messages(token: s.token, before: oldest, limit: 50)
            guard onHand(s) else { return false }
            var st = state.value
            st.messages = page.items + st.messages
            st.hasMore = page.hasMore
            state.send(st)
            return page.hasMore
        } catch {
            return false
        }
    }

    /// Optimistic send; the pending bubble is matched by clientId when the WS echoes it.
    @discardableResult
    func send(_ text: String) async -> ChatMessage? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let s = await ensureSession() else { return nil }
        let clientId = UUID().uuidString
        let optimistic = ChatMessage(
            id: "optimistic-\(clientId)", clientId: clientId, from: "visitor",
            senderName: s.visitor.name ?? "Kamu", type: "text", body: trimmed,
            media: nil, status: "pending", sentAt: "", quoted: nil
        )
        appendOrUpdate(optimistic)
        do {
            let sent = try await api.sendMessage(token: s.token, text: trimmed, clientId: clientId)
            guard onHand(s) else { return nil }
            appendOrUpdate(sent)
            // Without the socket the reply only shows up if the SDK goes looking for it.
            syncer.pollForReply()
            return sent
        } catch SdkError.prechatRequired(let fields) {
            guard onHand(s) else { return nil }
            var st = state.value
            st.prechatMissingFields = fields
            state.send(st)
            return nil
        } catch {
            guard onHand(s) else { return nil }
            appendOrUpdate(ChatMessage(
                id: optimistic.id, clientId: clientId, from: "visitor",
                senderName: optimistic.senderName, type: "text", body: trimmed,
                media: nil, status: "failed", sentAt: "", quoted: nil
            ))
            return nil
        }
    }

    func upload(fileURL: URL, mime: String, caption: String?) async -> ChatMessage? {
        guard let s = await ensureSession() else { return nil }
        do {
            let sent = try await api.upload(
                token: s.token, fileURL: fileURL,
                fileName: fileURL.lastPathComponent, mime: mime,
                caption: caption, clientId: UUID().uuidString
            )
            guard onHand(s) else { return nil }
            appendOrUpdate(sent)
            syncer.pollForReply()
            return sent
        } catch SdkError.prechatRequired(let fields) {
            guard onHand(s) else { return nil }
            var st = state.value
            st.prechatMissingFields = fields
            state.send(st)
            return nil
        } catch {
            guard onHand(s) else { return nil }
            setError(error)
            return nil
        }
    }

    func markRead(upToMessageId: String) async {
        guard let s = current else { return }
        try? await api.markRead(token: s.token, upToMessageId: upToMessageId)
        nara.refreshUnread()
    }

    // ------------------------------------------------------------ realtime

    /// Opens the realtime link for the current session; it reconnects on its own after a drop.
    /// An offline widget answers no socket: the call then only keeps the link wanted, for when
    /// its config turns live.
    func openRealtime(reopen: Bool = false) {
        realtimeWanted = true
        guard let impl = nara.api as? SdkApiURLSession else { return }
        if nara.configValue?.isOfflineMode == true { return }
        guard let s = current else {
            // No session on hand — e.g. `logout()` ran while the app was in the background: the next one dials.
            Task { _ = await self.ensureSession() }
            return
        }
        let link: RealtimeConnection
        if let realtime {
            link = realtime
        } else {
            let created = RealtimeConnection(listener: self, wsUrl: impl.wsUrl) { url, listener in
                VisitorSocket(url: url, listener: listener)
            }
            realtime = created
            realtimeCancellable = created.states.sink { [weak self] value in self?.realtimeChanged(value) }
            link = created
        }
        link.open(token: s.token, reopen: reopen)
    }

    /// The messenger closed: the link and the fallback polling stop until it opens again.
    func closeRealtime() {
        realtimeWanted = false
        realtime?.close()
        syncer.stop()
    }

    /// The config on hand changed. An offline widget keeps no socket and asks for no reply; a
    /// messenger opened onto its notice gets the link back — and a session — once the widget is
    /// live again.
    func configChanged(wasOffline: Bool, isOffline: Bool) {
        if isOffline {
            realtime?.close()
            syncer.stop()
        }
        if wasOffline && !isOffline && realtimeWanted { openRealtime(reopen: true) }
    }

    /// `configure` again: the link is built over the API anew, and another app than before is
    /// left as by `logout()` — unbound through `previous`, the API it was made with, no longer the
    /// one on hand. After a restart that API is gone with the process: the unbind then leaves through
    /// the host stored with the token.
    func apiChanged(to app: SdkApp, through previous: SdkApi) -> Bool {
        let link = realtime
        realtime = nil
        realtimeCancellable = nil
        link?.close()
        let left = keeper.switchTo(app, through: previous)
        if left { nara.store.clearIdentity() }
        if realtimeWanted { openRealtime(reopen: true) }
        return left
    }

    private func realtimeChanged(_ value: RealtimeState) {
        realtimeState.send(value)
        // Nobody can be typing over a link that is not connected: the hint would never clear.
        if value != .connected, state.value.typing { onTyping(typing: false, name: nil) }
    }

    /// Close code 4401: a fresh session for the same identity, without the dead token; the new
    /// session dials the link itself. A second ask while that runs starts no second session.
    func renewSessionAfterExpiry() {
        guard !renewing else { return }
        renewing = true
        Task {
            defer { self.renewing = false }
            _ = await self.renewSession()
        }
    }

    private func renewSession() async -> SdkSession? {
        nara.store.visitorToken = nil
        return await ensureSession(forceNew: true)
    }

    func onTyping(typing: Bool, name: String?) {
        var st = state.value
        st.typing = typing
        st.typingName = name
        state.send(st)
    }

    private func appendOrUpdate(_ m: ChatMessage) {
        var st = state.value
        if let i = st.messages.firstIndex(where: { $0.id == m.id || (m.clientId != nil && $0.clientId == m.clientId) }) {
            st.messages[i] = m
        } else {
            st.messages.append(m)
        }
        st.error = nil
        state.send(st)
    }
}

extension SessionManager: SessionKeeper.Listener {

    /// A new session is on hand: the list on screen is its own.
    func sessionKeeper(_ keeper: SessionKeeper, didApply s: SdkSession) {
        if let n = s.visitor.name { nara.store.cachedName = n }
        if let e = s.visitor.email { nara.store.cachedEmail = e }
        var st = state.value
        st.messages = s.messages
        st.hasMore = s.hasMore
        st.handler = s.handler
        st.prechatMissingFields = s.prechatRequired ? missingFields(from: s) : []
        st.error = nil
        state.send(st)
        nara.refreshUnread()
        if realtimeWanted { openRealtime() }
    }

    /// No session is on hand: nothing of the previous one may stay on screen.
    func sessionKeeperDidForget(_ keeper: SessionKeeper) {
        syncer.stop()
        state.send(SessionUiState(loading: true))
    }

    /// The widget went offline, so no session was made. No error goes on screen: its notice
    /// stands in for the chat.
    func sessionKeeperDidSuspend(_ keeper: SessionKeeper) {
        syncer.stop()
        var st = state.value
        st.loading = false
        st.error = nil
        state.send(st)
        #if DEBUG
        print("[NaraLiveChat] session refused: the widget is offline")
        #endif
    }

    func sessionKeeper(_ keeper: SessionKeeper, didFail step: String, error: Error) {
        setError(error)
    }
}

extension SessionManager: RealtimeListener {

    func onRealtimeReady(afterDrop: Bool) {
        syncer.socketReady(afterDrop: afterDrop)
    }

    func onRealtimeMessage(_ m: ChatMessage) {
        appendOrUpdate(m)
        if m.isTeam { syncer.stop() }
        nara.refreshUnread()
    }

    func onRealtimeUpdate(_ m: ChatMessage) {
        appendOrUpdate(m)
    }

    func onRealtimeTyping(typing: Bool, name: String?) {
        onTyping(typing: typing, name: name)
    }

    func onRealtimeTokenExpired() {
        renewSessionAfterExpiry()
    }
}

extension SessionManager: MessageSyncSource {

    var isRealtimeLive: Bool { realtimeState.value == .connected }

    func fetchLatestMessages() async -> [ChatMessage]? {
        guard let s = current, let page = try? await api.messages(token: s.token, before: nil, limit: Self.resyncLimit) else { return nil }
        pageOf = s.token
        return onHand(s) ? page.items : nil
    }

    /// Folds the server's latest page into the list on screen and says whether a reply came with it.
    @discardableResult
    func foldLatest(_ fresh: [ChatMessage]) -> Bool {
        guard pageOf == current?.token else { return false }
        let merged = mergeMessages(existing: state.value.messages, fresh: fresh)
        var st = state.value
        st.messages = merged.messages
        st.error = nil
        state.send(st)
        if merged.newReply { nara.refreshUnread() }
        return merged.newReply
    }
}
