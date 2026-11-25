import XCTest
@testable import NaraLiveChat

/// Holds callers until `open()`; a test decides when a call may answer.
private actor Gate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        let all = waiting
        waiting = []
        all.forEach { $0.resume() }
    }
}

/// Records every session call and push binding; any of them can be held back until the test lets it go.
private actor FakeApi: SdkApi {
    /// Tests tune the fake from the main actor; actor state is only written in here.
    func tune(_ change: @Sendable (isolated FakeApi) -> Void) { change(self) }
    struct SessionCall {
        let appKey: String
        let token: String?
        let login: LoginPayload?
        let setUser: SetUserPayload?
    }

    private enum Unused: Error { case call }

    private(set) var calls: [String] = []
    private(set) var sessions: [SessionCall] = []

    /// While set, a session answer waits for it.
    var answerGate: Gate?
    var unbindGate: Gate?
    var failUnbind = false
    var rejectStoredToken = false
    var failWith: SdkError?

    /// What `init` answers; `initFailure` wins when set, and `initGate` holds every answer back.
    var initAnswer: WidgetConfig?
    var initFailure: SdkError?
    var initGate: Gate?
    private(set) var inits = 0

    func createSession(
        appKey: String, bundleId: String, token: String?,
        login: LoginPayload?, setUser: SetUserPayload?, page: PagePayload?
    ) async throws -> SdkSession {
        sessions.append(SessionCall(appKey: appKey, token: token, login: login, setUser: setUser))
        let number = sessions.count
        if let gate = answerGate { await gate.wait() }
        if rejectStoredToken, token != nil { throw SdkError.visitorTokenInvalid }
        if let error = failWith { throw error }
        return SdkSession(
            token: "s\(number)", expiresAt: "2026-12-01T00:00:00Z",
            visitor: .init(id: "v1", name: nil, email: nil), conversationId: nil,
            prechatRequired: false, handler: nil, messages: [], hasMore: false,
            identity: .init(verified: login != nil, userId: login?.userId)
        )
    }

    func registerDeviceToken(token: String, platform: String, deviceToken: String) async throws -> DeviceTokenResult {
        calls.append("bind \(token):\(deviceToken)")
        return DeviceTokenResult(ok: true)
    }

    func deleteDeviceToken(token: String, deviceToken: String) async throws {
        calls.append("unbind \(token):\(deviceToken)")
        if let gate = unbindGate { await gate.wait() }
        if failUnbind { throw SdkError.network(nil) }
    }

    func initSdk(appKey: String, platform: String, bundleId: String, sdkVersion: String) async throws -> WidgetConfig {
        inits += 1
        if let gate = initGate { await gate.wait() }
        if let error = initFailure { throw error }
        guard let answer = initAnswer else { throw Unused.call }
        return answer
    }

    func messages(token: String, before: String?, limit: Int) async throws -> MessagePage { throw Unused.call }

    func sendMessage(token: String, text: String, clientId: String) async throws -> ChatMessage { throw Unused.call }

    func upload(
        token: String, fileURL: URL, fileName: String, mime: String, caption: String?, clientId: String
    ) async throws -> ChatMessage { throw Unused.call }

    func markRead(token: String, upToMessageId: String) async throws { throw Unused.call }

    func unread(token: String) async throws -> UnreadCount { throw Unused.call }

    func helpOverview(appKey: String) async throws -> HelpOverview { throw Unused.call }

    func helpSearch(appKey: String, query: String) async throws -> HelpOverview { throw Unused.call }

    func helpArticle(appKey: String, slug: String) async throws -> HelpArticle { throw Unused.call }
}

private final class MemoryStore: SessionStoring {
    var visitorToken: String?
    var verifiedUserId: String?
    var pushToken: String?
    var tokenOwner: SdkApp?
}

/// Written by the test, read by the keeper's identity closure: a plain box, so that closure needs no isolation.
private final class IdentityBox {
    var value: IdentityRules.Identity = .anonymous
}

/// Which API is on hand, read by the closure that hands it to the keeper: a plain box for the same reason.
private final class ApiBox {
    var value: SdkApi
    init(_ value: SdkApi) { self.value = value }
}

/// The API of an app that is not on hand, each kept by the address it was asked for; a plain box for the same reason.
private final class OffHandApis {
    private var stored: [String: FakeApi] = [:]

    func api(for baseUrl: String) -> FakeApi {
        if let api = stored[baseUrl] { return api }
        let api = FakeApi()
        stored[baseUrl] = api
        return api
    }

    var byBaseUrl: [String: FakeApi] { stored }
}

/// Whether the config on hand says the widget takes no chat, and what `init` answers when asked
/// again — a plain box, so the keeper's closures need no isolation.
private final class WidgetBox {
    var offline = false
    var reload: () async -> WidgetConfig? = { nil }
}

/// The keeper with everything it needs faked.
@MainActor
private final class Rig: SessionKeeper.Listener {
    let store = MemoryStore()
    let api = FakeApi()
    /// The API `configure` puts on hand for the next app; the tests of leaving an app swap to it.
    let nextApi = FakeApi()
    /// The API on hand, as `configure` replaces it.
    let onHand: ApiBox
    let identity = IdentityBox()
    let offHand = OffHandApis()
    let widget = WidgetBox()

    private(set) var applied: [String] = []
    private(set) var forgotten = 0
    private(set) var failures: [String] = []
    private(set) var errors: [Error] = []
    private(set) var suspended = 0

    init() {
        onHand = ApiBox(api)
    }

    lazy var keeper: SessionKeeper = {
        let onHand = self.onHand
        let identity = self.identity
        let offHand = self.offHand
        let widget = self.widget
        return SessionKeeper(
            api: { onHand.value }, apiFor: { offHand.api(for: $0.baseUrl) },
            store: self.store, platform: "ios",
            identity: { identity.value }, listener: self,
            suspended: { widget.offline }, config: { await widget.reload() }
        )
    }()

    /// The reload asks `init` on the API on hand, as in the app; the answer also says whether the
    /// widget is offline from then on.
    func askInitOnReload(_ api: FakeApi) {
        let widget = self.widget
        widget.reload = {
            let answer = try? await api.initSdk(appKey: "nk", platform: "ios", bundleId: "pkg", sdkVersion: "1")
            widget.offline = answer?.isOfflineMode == true
            return answer
        }
    }

    func sessionKeeper(_ keeper: SessionKeeper, didApply session: SdkSession) {
        applied.append(session.token)
    }

    func sessionKeeperDidForget(_ keeper: SessionKeeper) {
        forgotten += 1
    }

    func sessionKeeperDidSuspend(_ keeper: SessionKeeper) {
        suspended += 1
    }

    func sessionKeeper(_ keeper: SessionKeeper, didFail step: String, error: Error) {
        failures.append(step)
        errors.append(error)
    }
}

/// A verified identity for `user`, as the app hands it in after its backend signed it.
private func login(_ user: String) -> IdentityRules.Identity {
    .login(userId: user, userHash: "hash-\(user)", name: user, email: "\(user)@x.co")
}

/// The config `init` answers: nothing to it but whether the widget takes a chat.
private func widgetConfig(offline: Bool) -> WidgetConfig {
    let mode = offline ? "offline" : "live"
    let online = offline ? "false" : "true"
    return try! JSONDecoder().decode(
        WidgetConfig.self, from: #"{"key":"nk","name":"N","mode":"\#(mode)","online":\#(online)}"#.data(using: .utf8)!
    )
}

/// The session follows the identity, and this device's push follows the session.
@MainActor
final class SessionKeeperTests: XCTestCase {

    /// Waits for the push bindings queued so far, when the assertion is that nothing more was asked.
    private func settle() async {
        try? await Task.sleep(nanoseconds: 40_000_000)
    }

    func testLogoutDropsTheSessionItsTokenAndItsPushBindingAndTheNextSessionIsAnonymous() async {
        let r = Rig()
        r.identity.value = login("a")
        r.store.visitorToken = "stored-a"
        r.store.pushToken = "fcm"

        let first = await r.keeper.ensure(appKey: "nk", bundleId: "pkg")
        XCTAssertEqual(first?.token, "s1")
        XCTAssertEqual(r.store.verifiedUserId, "a")
        await waitUntil { await r.api.calls == ["bind s1:fcm"] }

        r.keeper.clear()
        XCTAssertNil(r.keeper.current)
        XCTAssertNil(r.store.visitorToken)
        XCTAssertNil(r.store.verifiedUserId)
        XCTAssertEqual(r.forgotten, 1)
        await waitUntil { await r.api.calls == ["bind s1:fcm", "unbind s1:fcm"] }

        r.identity.value = .anonymous
        let next = await r.keeper.ensure(appKey: "nk", bundleId: "pkg")
        XCTAssertEqual(next?.token, "s2")
        let sessions = await r.api.sessions
        XCTAssertEqual(sessions.map(\.token), ["stored-a", nil])
        XCTAssertNil(sessions.last?.login)
        XCTAssertNil(sessions.last?.setUser)
    }

    func testLoginReplacesTheSessionOnHandAndTheNextOneKeepsTheStoredTokenAndCarriesTheLogin() async {
        let r = Rig()
        r.store.pushToken = "fcm"
        _ = await r.keeper.ensure(appKey: "nk", bundleId: "pkg")

        r.identity.value = login("b")
        r.keeper.replace()

        XCTAssertNil(r.keeper.current)
        XCTAssertEqual(r.store.visitorToken, "s1")
        XCTAssertEqual(r.forgotten, 1)

        let next = await r.keeper.ensure(appKey: "nk", bundleId: "pkg")
        XCTAssertEqual(next?.token, "s2")
        let sessions = await r.api.sessions
        XCTAssertEqual(sessions.last?.token, "s1")
        XCTAssertEqual(sessions.last?.login?.userId, "b")
        await waitUntil { await r.api.calls == ["bind s1:fcm", "bind s2:fcm"] }
    }

    func testSetUserReplacesTheSessionOnHandAndIsCarriedByTheNextOne() async {
        let r = Rig()
        _ = await r.keeper.ensure(appKey: "nk", bundleId: "pkg")

        r.identity.value = .setUser(name: "Budi", email: "budi@x.co")
        r.keeper.replace()

        XCTAssertNil(r.keeper.current)
        _ = await r.keeper.ensure(appKey: "nk", bundleId: "pkg")
        let sessions = await r.api.sessions
        XCTAssertEqual(sessions.last?.token, "s1")
        XCTAssertNil(sessions.last?.login)
        XCTAssertEqual(sessions.last?.setUser?.email, "budi@x.co")
    }

    func testASessionAnsweredAfterLogoutIsNotKept() async {
        let r = Rig()
        r.identity.value = login("a")
        r.store.visitorToken = "stored-a"
        let gate = Gate()
        await r.api.tune { $0.answerGate = gate }

        let pending = Task { @MainActor in await r.keeper.ensure(appKey: "nk", bundleId: "pkg") }
        await waitUntil { await r.api.sessions.count == 1 }
        // The session made instead must not wait on the same gate.
        await r.api.tune { $0.answerGate = nil }

        r.keeper.clear()
        r.identity.value = .anonymous
        await gate.open()

        let session = await pending.value
        XCTAssertEqual(session?.token, "s2")
        let sessions = await r.api.sessions
        XCTAssertEqual(sessions.map(\.token), ["stored-a", nil])
        XCTAssertNil(sessions.last?.login)
        XCTAssertEqual(r.applied, ["s2"])
    }

    func testAPushUnbindThatFailsDoesNotHoldLogoutBack() async {
        let r = Rig()
        r.store.pushToken = "fcm"
        _ = await r.keeper.ensure(appKey: "nk", bundleId: "pkg")
        await waitUntil { await r.api.calls == ["bind s1:fcm"] }
        await r.api.tune { $0.failUnbind = true }

        r.keeper.clear()
        XCTAssertNil(r.keeper.current)
        XCTAssertNil(r.store.visitorToken)

        let next = await r.keeper.ensure(appKey: "nk", bundleId: "pkg")
        XCTAssertEqual(next?.token, "s2")
        await waitUntil { await r.api.calls == ["bind s1:fcm", "unbind s1:fcm", "bind s2:fcm"] }
    }

    func testTheUnbindOfALogoutFinishesBeforeTheNextSessionBind() async {
        let r = Rig()
        r.store.pushToken = "fcm"
        _ = await r.keeper.ensure(appKey: "nk", bundleId: "pkg")
        await waitUntil { await r.api.calls == ["bind s1:fcm"] }
        let gate = Gate()
        await r.api.tune { $0.unbindGate = gate }

        r.keeper.clear()
        _ = await r.keeper.ensure(appKey: "nk", bundleId: "pkg")
        await waitUntil { await r.api.calls.count == 2 }
        await settle()
        // The unbind is still waiting on the server: the bind of the new session has not started.
        let held = await r.api.calls
        XCTAssertEqual(held, ["bind s1:fcm", "unbind s1:fcm"])

        await gate.open()
        await waitUntil { await r.api.calls == ["bind s1:fcm", "unbind s1:fcm", "bind s2:fcm"] }
    }

    func testADeviceTokenThatArrivesAfterTheSessionIsBoundToTheSessionOnHand() async {
        let r = Rig()
        _ = await r.keeper.ensure(appKey: "nk", bundleId: "pkg")
        await settle()
        let none = await r.api.calls
        XCTAssertTrue(none.isEmpty)

        r.store.pushToken = "fcm"
        r.keeper.bindDeviceToken()
        await waitUntil { await r.api.calls == ["bind s1:fcm"] }
    }

    func testLogoutBeforeTheChatWasEverOpenedUnbindsTheStoredToken() async {
        let r = Rig()
        r.store.visitorToken = "stored-a"
        r.store.pushToken = "fcm"

        r.keeper.clear()
        await waitUntil { await r.api.calls == ["unbind stored-a:fcm"] }
        XCTAssertNil(r.store.visitorToken)
        XCTAssertEqual(r.forgotten, 1)
    }

    func testAPushUnbindGoesToTheAPIOnHandWhenItWasAskedForNotWhenItIsSent() async {
        let r = Rig()
        r.store.pushToken = "fcm"
        _ = await r.keeper.ensure(appKey: "nk", bundleId: "pkg")
        await waitUntil { await r.api.calls == ["bind s1:fcm"] }

        r.keeper.clear()
        // `configure` replaced the API before the unbind left.
        r.onHand.value = r.nextApi
        await waitUntil { await r.api.calls == ["bind s1:fcm", "unbind s1:fcm"] }
        let none = await r.nextApi.calls
        XCTAssertTrue(none.isEmpty)
    }

    func testConfigureAgainForAnotherAppLeavesThePreviousAppsSessionThroughItsOwnAPI() async {
        let r = Rig()
        r.identity.value = login("a")
        r.store.pushToken = "fcm"
        r.keeper.switchTo(SdkApp(appKey: "nk-a", baseUrl: "https://a/api"), through: r.api)
        _ = await r.keeper.ensure(appKey: "nk-a", bundleId: "pkg")
        XCTAssertEqual(r.store.verifiedUserId, "a")
        await waitUntil { await r.api.calls == ["bind s1:fcm"] }

        // By the time the keeper hears of the next app, `configure` has replaced the API.
        let previous = r.onHand.value
        r.onHand.value = r.nextApi
        XCTAssertTrue(r.keeper.switchTo(SdkApp(appKey: "nk-b", baseUrl: "https://a/api"), through: previous))

        XCTAssertNil(r.keeper.current)
        XCTAssertNil(r.store.visitorToken)
        XCTAssertNil(r.store.verifiedUserId)
        XCTAssertEqual(r.forgotten, 1)
        await waitUntil { await r.api.calls == ["bind s1:fcm", "unbind s1:fcm"] }
        let none = await r.nextApi.calls
        XCTAssertTrue(none.isEmpty)

        r.identity.value = .anonymous
        _ = await r.keeper.ensure(appKey: "nk-b", bundleId: "pkg")
        let sessions = await r.nextApi.sessions
        XCTAssertEqual(sessions.map(\.appKey), ["nk-b"])
        XCTAssertEqual(sessions.map(\.token), [nil])
        XCTAssertNil(sessions.first?.login)
        await waitUntil { await r.nextApi.calls == ["bind s1:fcm"] }
    }

    func testConfigureAgainForTheSameAppKeepsTheSession() async {
        let r = Rig()
        r.store.pushToken = "fcm"
        // The first app named has no previous one to leave.
        XCTAssertFalse(r.keeper.switchTo(SdkApp(appKey: "nk", baseUrl: "https://a/api"), through: r.api))
        _ = await r.keeper.ensure(appKey: "nk", bundleId: "pkg")
        await waitUntil { await r.api.calls == ["bind s1:fcm"] }

        r.onHand.value = r.nextApi
        XCTAssertFalse(r.keeper.switchTo(SdkApp(appKey: "nk", baseUrl: "https://a/api"), through: r.api))

        XCTAssertEqual(r.keeper.current?.token, "s1")
        XCTAssertEqual(r.store.visitorToken, "s1")
        XCTAssertEqual(r.forgotten, 0)
        let again = await r.keeper.ensure(appKey: "nk", bundleId: "pkg")
        XCTAssertEqual(again?.token, "s1")
        let one = await r.api.sessions
        XCTAssertEqual(one.count, 1)
        await settle()
        let bindings = await r.api.calls
        XCTAssertEqual(bindings, ["bind s1:fcm"])
    }

    func testConfigureAgainForTheSameAppKeyOnAnotherHostLeavesTheSessionToo() async {
        let r = Rig()
        r.store.pushToken = "fcm"
        r.keeper.switchTo(SdkApp(appKey: "nk", baseUrl: "https://a/api"), through: r.api)
        _ = await r.keeper.ensure(appKey: "nk", bundleId: "pkg")
        await waitUntil { await r.api.calls == ["bind s1:fcm"] }

        r.onHand.value = r.nextApi
        XCTAssertTrue(r.keeper.switchTo(SdkApp(appKey: "nk", baseUrl: "https://b/api"), through: r.api))

        XCTAssertNil(r.keeper.current)
        XCTAssertNil(r.store.visitorToken)
        await waitUntil { await r.api.calls == ["bind s1:fcm", "unbind s1:fcm"] }
        let none = await r.nextApi.calls
        XCTAssertTrue(none.isEmpty)
    }

    func testConfigureAgainForTheSameAppUnderAnotherSpellingOfItsAddressKeepsTheSession() async {
        let r = Rig()
        r.store.pushToken = "fcm"
        r.keeper.switchTo(SdkApp(appKey: "nk", baseUrl: "https://a/api"), through: r.api)
        _ = await r.keeper.ensure(appKey: "nk", bundleId: "pkg")
        await waitUntil { await r.api.calls == ["bind s1:fcm"] }

        r.onHand.value = r.nextApi
        XCTAssertFalse(r.keeper.switchTo(SdkApp(appKey: "nk", baseUrl: "HTTP://A/api/"), through: r.api))

        XCTAssertEqual(r.keeper.current?.token, "s1")
        XCTAssertEqual(r.store.visitorToken, "s1")
        XCTAssertEqual(r.forgotten, 0)
        XCTAssertTrue(r.offHand.byBaseUrl.isEmpty)
        await settle()
        let bindings = await r.api.calls
        XCTAssertEqual(bindings, ["bind s1:fcm"])
    }

    func testTheStoredTokenCarriesTheAppItWasMadeForAndLogoutDropsBoth() async {
        let r = Rig()
        r.keeper.switchTo(SdkApp(appKey: "nk", baseUrl: "https://a/api"), through: r.api)
        _ = await r.keeper.ensure(appKey: "nk", bundleId: "pkg")
        XCTAssertEqual(r.store.tokenOwner, SdkApp(appKey: "nk", baseUrl: "https://a/api"))

        r.keeper.clear()

        XCTAssertNil(r.store.visitorToken)
        XCTAssertNil(r.store.tokenOwner)
    }

    func testAfterARestartATokenStoredForAnotherAppIsLeftThroughThatAppsOwnHost() async {
        let r = Rig()
        // Left by the previous process: no app is on hand, only what the store kept.
        r.store.visitorToken = "stored-a"
        r.store.pushToken = "fcm"
        r.store.tokenOwner = SdkApp(appKey: "nk-a", baseUrl: "https://a/api")
        r.onHand.value = r.nextApi

        XCTAssertTrue(r.keeper.switchTo(SdkApp(appKey: "nk-b", baseUrl: "https://b/api"), through: r.nextApi))

        XCTAssertNil(r.store.visitorToken)
        XCTAssertNil(r.store.tokenOwner)
        XCTAssertEqual(r.forgotten, 1)
        XCTAssertEqual(r.offHand.byBaseUrl.keys.sorted(), ["https://a/api"])
        let oldHost = r.offHand.byBaseUrl["https://a/api"]
        await waitUntil { await oldHost?.calls == ["unbind stored-a:fcm"] }
        let none = await r.nextApi.calls
        XCTAssertTrue(none.isEmpty)

        _ = await r.keeper.ensure(appKey: "nk-b", bundleId: "pkg")
        XCTAssertEqual(r.store.tokenOwner, SdkApp(appKey: "nk-b", baseUrl: "https://b/api"))
        let sessions = await r.nextApi.sessions
        XCTAssertEqual(sessions.map(\.token), [nil])
        await waitUntil { await r.nextApi.calls == ["bind s1:fcm"] }
    }

    func testAfterARestartTheSameAppKeepsTheStoredSession() async {
        let r = Rig()
        r.store.visitorToken = "stored-a"
        r.store.pushToken = "fcm"
        r.store.tokenOwner = SdkApp(appKey: "nk", baseUrl: "https://a/api")

        XCTAssertFalse(r.keeper.switchTo(SdkApp(appKey: "nk", baseUrl: "https://a/api"), through: r.api))

        XCTAssertEqual(r.store.visitorToken, "stored-a")
        XCTAssertEqual(r.forgotten, 0)
        XCTAssertTrue(r.offHand.byBaseUrl.isEmpty)
        await settle()
        let none = await r.api.calls
        XCTAssertTrue(none.isEmpty)
        _ = await r.keeper.ensure(appKey: "nk", bundleId: "pkg")
        let sessions = await r.api.sessions
        XCTAssertEqual(sessions.map(\.token), ["stored-a"])
    }

    func testAfterARestartAnotherSpellingOfTheSameAddressKeepsTheSession() async {
        let r = Rig()
        r.store.visitorToken = "stored-a"
        r.store.pushToken = "fcm"
        r.store.tokenOwner = SdkApp(appKey: "nk", baseUrl: "https://A/api")

        XCTAssertFalse(r.keeper.switchTo(SdkApp(appKey: "nk", baseUrl: "http://a/api/"), through: r.api))

        XCTAssertEqual(r.store.visitorToken, "stored-a")
        XCTAssertEqual(r.forgotten, 0)
        XCTAssertTrue(r.offHand.byBaseUrl.isEmpty)
        await settle()
        let none = await r.api.calls
        XCTAssertTrue(none.isEmpty)
    }

    func testAfterARestartWithoutAStoredTokenNothingIsDropped() async {
        let r = Rig()
        r.store.pushToken = "fcm"
        r.store.tokenOwner = SdkApp(appKey: "nk-a", baseUrl: "https://a/api")

        XCTAssertFalse(r.keeper.switchTo(SdkApp(appKey: "nk-b", baseUrl: "https://b/api"), through: r.api))

        XCTAssertEqual(r.forgotten, 0)
        XCTAssertTrue(r.offHand.byBaseUrl.isEmpty)
        await settle()
        let none = await r.api.calls
        XCTAssertTrue(none.isEmpty)
    }

    func testAStoredTokenTheServerNoLongerKnowsCostsOneMoreTryWithoutIt() async {
        let r = Rig()
        r.store.visitorToken = "expired"
        await r.api.tune { $0.rejectStoredToken = true }

        let session = await r.keeper.ensure(appKey: "nk", bundleId: "pkg")
        XCTAssertEqual(session?.token, "s2")
        let sessions = await r.api.sessions
        XCTAssertEqual(sessions.map(\.token), ["expired", nil])
    }

    func testASessionThatCannotBeMadeIsReportedAndNothingIsKept() async {
        let r = Rig()
        await r.api.tune { $0.failWith = .network(nil) }

        let session = await r.keeper.ensure(appKey: "nk", bundleId: "pkg")
        XCTAssertNil(session)
        XCTAssertNil(r.keeper.current)
        XCTAssertNil(r.store.visitorToken)
        XCTAssertEqual(r.failures, ["createSession"])
        XCTAssertEqual(r.errors.count, 1)
        guard case .network = r.errors.first as? SdkError else { return XCTFail("expected a network error") }
    }

    // MARK: - A widget that takes no chat (its owner's plan ended, or it is over its quota)

    func testAnOfflineWidgetIsAskedForNoSession() async {
        let r = Rig()
        r.widget.offline = true

        let session = await r.keeper.ensure(appKey: "nk", bundleId: "pkg")
        let anew = await r.keeper.ensure(appKey: "nk", bundleId: "pkg", forceNew: true)

        XCTAssertNil(session)
        XCTAssertNil(anew)
        XCTAssertNil(r.keeper.current)
        let sessions = await r.api.sessions
        XCTAssertTrue(sessions.isEmpty)
        let calls = await r.api.calls
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(r.suspended, 0)
        XCTAssertTrue(r.failures.isEmpty)
    }

    func testGoingOfflineKeepsTheSessionOnHandAndStopsEveryLaterAsk() async {
        let r = Rig()
        _ = await r.keeper.ensure(appKey: "nk", bundleId: "pkg")

        r.widget.offline = true
        let none = await r.keeper.ensure(appKey: "nk", bundleId: "pkg")
        let anew = await r.keeper.ensure(appKey: "nk", bundleId: "pkg", forceNew: true)

        XCTAssertNil(none)
        XCTAssertNil(anew)
        XCTAssertEqual(r.keeper.current?.token, "s1")
        XCTAssertEqual(r.store.visitorToken, "s1")
        XCTAssertEqual(r.forgotten, 0)
        XCTAssertEqual(r.suspended, 0)
        let sessions = await r.api.sessions
        XCTAssertEqual(sessions.count, 1)
    }

    func testASessionRefusedWithNotFoundAsksInitOnceAndEndsOfflineNotAsAnError() async {
        let r = Rig()
        r.askInitOnReload(r.api)
        await r.api.tune { $0.failWith = .notFound }
        await r.api.tune { $0.initAnswer = widgetConfig(offline: true) }

        let session = await r.keeper.ensure(appKey: "nk", bundleId: "pkg")

        XCTAssertNil(session)
        XCTAssertNil(r.keeper.current)
        XCTAssertNil(r.store.visitorToken)
        XCTAssertEqual(r.suspended, 1)
        XCTAssertTrue(r.failures.isEmpty)
        var sessions = await r.api.sessions
        XCTAssertEqual(sessions.count, 1)
        var inits = await r.api.inits
        XCTAssertEqual(inits, 1)

        // The reloaded config is on hand now: the next ask is not a call, and never a retry.
        let again = await r.keeper.ensure(appKey: "nk", bundleId: "pkg", forceNew: true)
        XCTAssertNil(again)
        sessions = await r.api.sessions
        XCTAssertEqual(sessions.count, 1)
        inits = await r.api.inits
        XCTAssertEqual(inits, 1)
    }

    func testARefusedSessionStaysAnErrorWhileInitStillSaysTheWidgetIsLive() async {
        let r = Rig()
        r.askInitOnReload(r.api)
        await r.api.tune { $0.failWith = .notFound }
        await r.api.tune { $0.initAnswer = widgetConfig(offline: false) }

        let session = await r.keeper.ensure(appKey: "nk", bundleId: "pkg")

        XCTAssertNil(session)
        XCTAssertEqual(r.failures, ["createSession"])
        XCTAssertEqual(r.suspended, 0)
        // One session call, one look at init — not a retry in sight.
        let sessions = await r.api.sessions
        XCTAssertEqual(sessions.count, 1)
        let inits = await r.api.inits
        XCTAssertEqual(inits, 1)
    }

    func testARefusedSessionIsAnErrorTooWhenInitCannotBeAsked() async {
        let r = Rig()
        r.askInitOnReload(r.api)
        await r.api.tune { $0.failWith = .notFound }
        await r.api.tune { $0.initFailure = .network(nil) }

        let session = await r.keeper.ensure(appKey: "nk", bundleId: "pkg")

        XCTAssertNil(session)
        XCTAssertEqual(r.failures, ["createSession"])
        XCTAssertEqual(r.suspended, 0)
        XCTAssertFalse(r.widget.offline)
        let sessions = await r.api.sessions
        XCTAssertEqual(sessions.count, 1)
    }

    func testAnotherRefusalNeverAsksInit() async {
        let r = Rig()
        // Had `init` been asked, the answer would have ended the call offline.
        r.widget.reload = { widgetConfig(offline: true) }

        await r.api.tune { $0.failWith = .packageNotAllowed }
        let first = await r.keeper.ensure(appKey: "nk", bundleId: "pkg")
        await r.api.tune { $0.failWith = .http(status: 401, code: "unauthorized") }
        let second = await r.keeper.ensure(appKey: "nk", bundleId: "pkg")
        await r.api.tune { $0.failWith = .network(nil) }
        let third = await r.keeper.ensure(appKey: "nk", bundleId: "pkg")

        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertNil(third)
        XCTAssertEqual(r.failures, ["createSession", "createSession", "createSession"])
        XCTAssertEqual(r.suspended, 0)
        let inits = await r.api.inits
        XCTAssertEqual(inits, 0)
    }

    func testAStoredTokenTheServerNoLongerKnowsIsDroppedBeforeTheRefusalIsLookedInto() async {
        let r = Rig()
        r.askInitOnReload(r.api)
        r.store.visitorToken = "expired"
        await r.api.tune { $0.rejectStoredToken = true }
        await r.api.tune { $0.failWith = .notFound }
        await r.api.tune { $0.initAnswer = widgetConfig(offline: true) }

        let session = await r.keeper.ensure(appKey: "nk", bundleId: "pkg")

        XCTAssertNil(session)
        // The stored token cost its one extra try; the refusal that followed was settled by init.
        let sessions = await r.api.sessions
        XCTAssertEqual(sessions.map(\.token), ["expired", nil])
        let inits = await r.api.inits
        XCTAssertEqual(inits, 1)
        XCTAssertEqual(r.suspended, 1)
        XCTAssertTrue(r.failures.isEmpty)
        XCTAssertNil(r.store.visitorToken)
    }

    func testARefusalLookedIntoAfterALogoutReportsNothing() async {
        let r = Rig()
        r.askInitOnReload(r.api)
        await r.api.tune { $0.failWith = .notFound }
        await r.api.tune { $0.initAnswer = widgetConfig(offline: true) }
        let gate = Gate()
        await r.api.tune { $0.initGate = gate }

        let pending = Task { @MainActor in await r.keeper.ensure(appKey: "nk", bundleId: "pkg") }
        await waitUntil { await r.api.inits == 1 }
        // `init` is still to answer: the logout runs while the refusal is being looked into.
        r.keeper.clear()

        await gate.open()
        let session = await pending.value

        XCTAssertNil(session)
        XCTAssertEqual(r.forgotten, 1)
        // Neither "offline" nor an error: the session it was made for is nobody's now.
        XCTAssertEqual(r.suspended, 0)
        XCTAssertTrue(r.failures.isEmpty)
    }
}
