import XCTest
import Security
@testable import NaraLiveChat

final class IdentityRulesTests: XCTestCase {

    // Email sanitizing (spec: invalid email from the app = empty)
    func testValidEmailPasses() {
        XCTAssertEqual(IdentityRules.sanitizeEmail("a@b.co"), "a@b.co")
        XCTAssertEqual(IdentityRules.sanitizeEmail("  a@b.co  "), "a@b.co")
    }

    func testInvalidEmailIsNull() {
        XCTAssertNil(IdentityRules.sanitizeEmail("not-an-email"))
        XCTAssertNil(IdentityRules.sanitizeEmail("a@b"))
        XCTAssertNil(IdentityRules.sanitizeEmail("a b@c.com"))
        XCTAssertNil(IdentityRules.sanitizeEmail(""))
        XCTAssertNil(IdentityRules.sanitizeEmail(nil))
    }

    func testNameTrimmed() {
        XCTAssertNil(IdentityRules.sanitizeName("   "))
        XCTAssertEqual(IdentityRules.sanitizeName(" Zai "), "Zai")
    }

    // Prechat rules table
    func testFormDisabledNeverAsks() {
        XCTAssertTrue(IdentityRules.missingPrechatFields(formEnabled: false, requireName: true, requireEmail: true, suppliedName: "x", suppliedEmail: nil).isEmpty)
    }

    func testLoginWithNameAndEmailSkipsForm() {
        XCTAssertTrue(IdentityRules.missingPrechatFields(formEnabled: true, requireName: true, requireEmail: true, suppliedName: "Zai", suppliedEmail: "zai@x.co").isEmpty)
    }

    func testSetUserWithoutEmailShowsOnlyEmail() {
        XCTAssertEqual(IdentityRules.missingPrechatFields(formEnabled: true, requireName: true, requireEmail: true, suppliedName: "Zai", suppliedEmail: nil), ["email"])
    }

    func testNothingSuppliedAsksBoth() {
        XCTAssertEqual(IdentityRules.missingPrechatFields(formEnabled: true, requireName: true, requireEmail: true, suppliedName: nil, suppliedEmail: nil), ["name", "email"])
    }

    // Identity decision table
    func testLoginWithHashWins() {
        if case .login(let userId, _, _, _) = IdentityRules.decideIdentity(loginUserId: "u1", loginUserHash: "h", loginName: "Zai", loginEmail: "zai@x.co", setUser: nil) {
            XCTAssertEqual(userId, "u1")
        } else {
            XCTFail("expected login")
        }
    }

    func testLoginWithInvalidEmailSanitizes() {
        if case .login(_, _, _, let email) = IdentityRules.decideIdentity(loginUserId: "u1", loginUserHash: "h", loginName: "Zai", loginEmail: "broken", setUser: nil) {
            XCTAssertNil(email)
        } else {
            XCTFail("expected login")
        }
    }

    func testSetUserWithoutHash() {
        if case .setUser = IdentityRules.decideIdentity(loginUserId: nil, loginUserHash: nil, loginName: nil, loginEmail: nil, setUser: ("Zai", "zai@x.co")) {
        } else {
            XCTFail("expected setUser")
        }
    }

    func testAnonymousWhenNothing() {
        XCTAssertEqual(IdentityRules.decideIdentity(loginUserId: nil, loginUserHash: nil, loginName: nil, loginEmail: nil, setUser: nil), .anonymous)
    }

    func testLoginMissingHashDegradesToSetUser() {
        if case .setUser(let name, _) = IdentityRules.decideIdentity(loginUserId: "u1", loginUserHash: nil, loginName: "Zai", loginEmail: "zai@x.co", setUser: nil) {
            XCTAssertEqual(name, "Zai")
        } else {
            XCTFail("expected setUser")
        }
    }
}

final class VersionCheckTests: XCTestCase {

    func testBelowMinimum() { XCTAssertTrue(VersionCheck.lessThan("0.9.0", "1.0.0")) }
    func testEqualNotLess() { XCTAssertFalse(VersionCheck.lessThan("1.0.0", "1.0.0")) }
    func testMissingPartsAreZero() {
        XCTAssertFalse(VersionCheck.lessThan("1.2", "1.2.0"))
        XCTAssertTrue(VersionCheck.lessThan("1.2", "1.2.1"))
    }
    func testNumericNotLexicographic() { XCTAssertTrue(VersionCheck.lessThan("1.9.0", "1.10.0")) }
    func testGarbageNeverBlocks() {
        XCTAssertFalse(VersionCheck.lessThan("garbage", "1.0.0"))
        XCTAssertFalse(VersionCheck.lessThan("1.0.0", nil))
    }
}

final class SafeHtmlParserTests: XCTestCase {

    func testDropsScriptAndAttributes() {
        let blocks = SafeHtmlParser.parse("<p onclick=\"evil()\">Hi<script>alert(1)</script></p>")
        XCTAssertEqual(blocks, [.init(tag: "p", text: "Hialert(1)", href: nil)])
    }

    func testHeadingsAndLists() {
        let blocks = SafeHtmlParser.parse("<h1>Title</h1><p>Body</p><ul><li>One</li><li>Two</li></ul>")
        XCTAssertEqual(blocks[0].tag, "h1")
        XCTAssertEqual(blocks[0].text, "Title")
        XCTAssertEqual(blocks[2].tag, "li")
        XCTAssertEqual(blocks[2].text, "One")
    }

    func testEntitiesDecoded() {
        let blocks = SafeHtmlParser.parse("<p>A &amp; B &lt;tag&gt;</p>")
        XCTAssertEqual(blocks[0].text, "A & B <tag>")
    }

    func testHrefKeptOnAnchor() {
        let blocks = SafeHtmlParser.parse("<a href=\"https://x.co/a?b=1\">Docs</a>")
        XCTAssertEqual(blocks[0].tag, "a")
        XCTAssertEqual(blocks[0].href, "https://x.co/a?b=1")
        XCTAssertEqual(blocks[0].text, "Docs")
    }

    func testUnterminatedTagShownAsText() {
        let blocks = SafeHtmlParser.parse("<p>ok</p><div")
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[1].text, "<div")
    }
}

final class SdkStoreSecurityTests: XCTestCase {

    private var service: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        service = "id.nara.livechat.sdk.test-\(UUID().uuidString)"
        // A test bundle without a host app (the SPM scheme on the simulator) gets no Keychain at
        // all. These tests run for real in the hosted suite: SampleApp scheme, target HostedTests.
        let probe: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service!, kSecAttrAccount as String: "probe",
            kSecValueData as String: Data("x".utf8),
        ]
        let status = SecItemAdd(probe as CFDictionary, nil)
        SecItemDelete(probe as CFDictionary)
        if status == errSecMissingEntitlement {
            throw XCTSkip("No Keychain without a host app; run the SampleApp scheme (HostedTests) instead.")
        }
    }

    override func tearDown() {
        KeychainStore(service: service).removeAll()
        super.tearDown()
    }

    func testKeychainRoundTripAndDelete() {
        let kc = KeychainStore(service: service)
        XCTAssertNil(kc.string("nara.visitor_token"))
        kc.set("tok-1", key: "nara.visitor_token")
        XCTAssertEqual(kc.string("nara.visitor_token"), "tok-1")
        kc.set("tok-2", key: "nara.visitor_token") // update, not duplicate
        XCTAssertEqual(kc.string("nara.visitor_token"), "tok-2")
        kc.set(nil, key: "nara.visitor_token")
        XCTAssertNil(kc.string("nara.visitor_token"))
    }

    func testUserDefaultsCredentialsMigrateToKeychain() throws {
        let suite = "test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // What SDK 1.0.0 would have left behind:
        defaults.set("tok-legacy", forKey: "nara.visitor_token")
        defaults.set("fcm-legacy", forKey: "nara.push_token")
        defaults.set("Zai", forKey: "nara.cached_name")

        let store = SdkStore(suiteName: suite, keychain: KeychainStore(service: service))

        // Credentials moved to the Keychain, plaintext wiped:
        XCTAssertEqual(store.visitorToken, "tok-legacy")
        XCTAssertEqual(store.pushToken, "fcm-legacy")
        XCTAssertNil(defaults.string(forKey: "nara.visitor_token"))
        XCTAssertNil(defaults.string(forKey: "nara.push_token"))
        // Non-secret display data stays in UserDefaults:
        XCTAssertEqual(store.cachedName, "Zai")
        XCTAssertEqual(defaults.string(forKey: "nara.cached_name"), "Zai")
    }

    func testClearIdentityKeepsPushToken() {
        let store = SdkStore(keychain: KeychainStore(service: service))
        store.visitorToken = "tok-1"
        store.pushToken = "fcm-1"

        store.clearIdentity()

        XCTAssertNil(store.visitorToken)
        XCTAssertEqual(store.pushToken, "fcm-1") // device-level: survives logout
    }

    func testTheSessionOwnerIsKeptWithTheTokenAndGoesWithTheIdentity() throws {
        let suite = "test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SdkStore(suiteName: suite, keychain: KeychainStore(service: service))
        XCTAssertNil(store.tokenOwner)

        store.tokenOwner = SdkApp(appKey: "nk_1", baseUrl: "https://api.nara.ai.id/api")
        XCTAssertEqual(KeychainStore(service: service).string("nara.owner_app_key"), "nk_1")
        XCTAssertEqual(store.tokenOwner, SdkApp(appKey: "nk_1", baseUrl: "https://api.nara.ai.id/api"))
        // With the token, not with the name and email.
        XCTAssertNil(defaults.string(forKey: "nara.owner_app_key"))

        store.clearIdentity()
        XCTAssertNil(store.tokenOwner)
    }
}

final class ModelsTests: XCTestCase {

    func testUnknownMessageTypeDegradesToFallback() throws {
        let json = """
        {"id":"m1","from":"agent","senderName":"Ana","type":"product_card",
         "body":"{}","status":"received","sentAt":"2026-11-22T00:00:00Z"}
        """
        let m = try JSONDecoder().decode(ChatMessage.self, from: json.data(using: .utf8)!)
        let fallback = ChatMessage.withFallback(m, locale: "en")
        XCTAssertEqual(fallback.type, "fallback")
        XCTAssertEqual(fallback.body, ChatMessage.fallbackBodyEn)
        XCTAssertEqual(ChatMessage.withFallback(m, locale: "id").body, ChatMessage.fallbackBodyId)
    }

    func testKnownTypePassesThrough() throws {
        let json = """
        {"id":"m1","from":"visitor","senderName":"Zai","type":"text","body":"hai",
         "status":"sent","sentAt":"2026-11-22T00:00:00Z","clientId":"c1"}
        """
        let m = try JSONDecoder().decode(ChatMessage.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(ChatMessage.withFallback(m, locale: "en").body, "hai")
    }

    func testAvatarURLsAreReadWhereverTheServerSendsThem() throws {
        let config = try JSONDecoder().decode(
            WidgetConfig.self,
            from: #"{"key":"k","name":"N","online":true,"aiAgent":{"name":"Nara AI","avatarUrl":"https://cdn.example.com/ai.jpg"}}"#.data(using: .utf8)!
        )
        XCTAssertEqual(config.aiAgent?.avatarUrl, "https://cdn.example.com/ai.jpg")

        let session = try JSONDecoder().decode(
            SdkSession.self,
            from: """
            {"token":"t1","expiresAt":"x","visitor":{"id":"v1"},"prechatRequired":false,
             "handler":{"type":"agent","name":"Steve","avatarUrl":"https://cdn.example.com/steve.jpg"},
             "messages":[{"id":"m1","from":"agent","senderName":"Steve","senderAvatarUrl":"https://cdn.example.com/steve.jpg",
                          "type":"text","body":"hai","sentAt":"x"}],
             "hasMore":false,"identity":{"verified":false}}
            """.data(using: .utf8)!
        )
        XCTAssertEqual(session.handler?.avatarUrl, "https://cdn.example.com/steve.jpg")
        XCTAssertEqual(session.messages.first?.photoUrl, "https://cdn.example.com/steve.jpg")
    }

    func testAServerFromBeforeAvatarsStillDecodesWithoutPhotos() throws {
        let config = try JSONDecoder().decode(
            WidgetConfig.self,
            from: #"{"key":"k","name":"N","online":true,"aiAgent":{"name":"Nara AI"}}"#.data(using: .utf8)!
        )
        XCTAssertNil(config.aiAgent?.avatarUrl)

        let session = try JSONDecoder().decode(
            SdkSession.self,
            from: """
            {"token":"t1","expiresAt":"x","visitor":{"id":"v1"},"prechatRequired":false,
             "handler":{"type":"ai","name":"Nara AI"},
             "messages":[{"id":"m1","from":"ai","senderName":"Nara AI","type":"text","body":"hai","sentAt":"x"}],
             "hasMore":false,"identity":{"verified":false}}
            """.data(using: .utf8)!
        )
        XCTAssertNil(session.handler?.avatarUrl)
        XCTAssertNil(session.messages.first?.senderAvatarUrl)
        XCTAssertNil(session.messages.first?.photoUrl)
    }

    func testAnOfflineConfigIsReadAsOfflineWithItsNotice() throws {
        // What `init` answers for a widget whose owner's plan ended, or that is over its quota.
        let offline = try JSONDecoder().decode(
            WidgetConfig.self,
            from: #"{"key":"k","name":"N","mode":"offline","online":false,"help":null,"aiAgent":null,"offline":{"title":"We are offline right now","text":"Leave a message and we will get back to you by email.","fields":{"name":{"required":true}}}}"#.data(using: .utf8)!
        )
        XCTAssertTrue(offline.isOfflineMode)
        XCTAssertFalse(offline.online)
        XCTAssertNil(offline.help)
        XCTAssertNil(offline.aiAgent)
        XCTAssertEqual(offline.offline?.title, "We are offline right now")
        XCTAssertEqual(offline.offline?.text, "Leave a message and we will get back to you by email.")

        // Null, a non-string or no notice at all: the config still reads, and nothing else is taken for it.
        let odd = try JSONDecoder().decode(
            WidgetConfig.self,
            from: #"{"key":"k","name":"N","mode":"offline","online":false,"offline":{"title":null,"text":7}}"#.data(using: .utf8)!
        )
        XCTAssertTrue(odd.isOfflineMode)
        XCTAssertNil(odd.offline?.title)
        XCTAssertNil(odd.offline?.text)

        let live = try JSONDecoder().decode(
            WidgetConfig.self,
            from: #"{"key":"k","name":"N","mode":"live","online":true,"offline":null}"#.data(using: .utf8)!
        )
        XCTAssertFalse(live.isOfflineMode)
        XCTAssertNil(live.offline)
    }

    func testANullEmptyOrBlankAvatarURLIsNoPhoto() throws {
        let json = """
        {"id":"m1","from":"agent","senderName":"Steve","type":"text","body":"hai","sentAt":"x","senderAvatarUrl":null}
        """
        let nilPhoto = try JSONDecoder().decode(ChatMessage.self, from: json.data(using: .utf8)!)
        XCTAssertNil(nilPhoto.senderAvatarUrl)
        XCTAssertNil(nilPhoto.photoUrl)

        for url in ["", "  "] {
            let m = ChatMessage(
                id: "m1", clientId: nil, from: "agent", senderName: "Steve", type: "text", body: "hai",
                media: nil, status: "received", sentAt: "", quoted: nil, senderAvatarUrl: url
            )
            XCTAssertNil(m.photoUrl)
        }
    }

    func testErrorMappingPrechat() {
        // The shape the API sends: {"error":{"code","message","details"}}.
        let body = #"{"error":{"code":"prechat_required","message":"Prechat required","details":{"required":["email"]}}}"#.data(using: .utf8)!
        XCTAssertEqual(SdkError.from(status: 428, body: body), .prechatRequired(["email"]))
        // Older flat bodies stay readable.
        let flat = #"{"error":"prechat_required","details":{"required":["name"]}}"#.data(using: .utf8)!
        XCTAssertEqual(SdkError.from(status: 428, body: flat), .prechatRequired(["name"]))
    }
}
