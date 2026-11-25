import XCTest
@testable import NaraLiveChat

/// The SDK style rules stay pure and mirror the Android `naraColors`: display mode and
/// language come from the config only, the accent paints the Home hero and `primary` is ink.
final class SdkThemeRulesTests: XCTestCase {

    private func sdk(
        _ theme: String? = nil, _ accent: String? = nil,
        title: String? = nil, subtitle: String? = nil,
        mode: String? = nil, locale: String? = nil
    ) -> WidgetConfig.Style.SdkStyle {
        .init(
            theme: theme, accent: accent, greetingTitle: title, greetingSubtitle: subtitle,
            mode: mode, locale: locale
        )
    }

    private func message(_ json: String) throws -> ChatMessage {
        try JSONDecoder().decode(ChatMessage.self, from: json.data(using: .utf8)!)
    }

    // MARK: - Palette

    func testDefaultsAreLightWithInkPrimaryAndDefaultAccent() {
        let p = SdkThemeRules.palette(sdk: nil, override: nil)
        XCTAssertFalse(p.dark)
        XCTAssertEqual(p.background, 0xffffff)
        XCTAssertEqual(p.text, 0x1a1a1a)
        XCTAssertEqual(p.primary, 0x111111) // main actions are ink
        XCTAssertEqual(p.onPrimary, 0xffffff)
        XCTAssertEqual(p.hero, 0xffc400)    // the accent paints the hero only
        XCTAssertEqual(p.onHero, 0x111111)  // yellow is light → dark text
    }

    func testDisplayModeComesFromStyleSdkModeOnly() {
        let dark = SdkThemeRules.palette(sdk: sdk(mode: "dark"), override: nil)
        XCTAssertTrue(dark.dark)
        XCTAssertEqual(dark.background, 0x111111)
        XCTAssertEqual(dark.text, 0xf5f5f5)
        XCTAssertEqual(dark.primary, 0xffffff)
        XCTAssertEqual(dark.onPrimary, 0x111111)
        XCTAssertEqual(dark.hero, 0xffc400) // the accent itself never changes
        XCTAssertEqual(dark.onHero, 0x111111)

        let lightModes: [String?] = [nil, "light", "Dark", "system", "neon"]
        for mode in lightModes {
            XCTAssertFalse(
                SdkThemeRules.palette(sdk: sdk(mode: mode), override: nil).dark,
                "mode \(mode ?? "nil")"
            )
        }
    }

    func testWhitePresetHeroIsThePageBackground() {
        let light = SdkThemeRules.palette(sdk: sdk("white"), override: nil)
        XCTAssertEqual(light.hero, light.background)
        XCTAssertEqual(light.primary, 0x111111)
        XCTAssertEqual(light.onPrimary, 0xffffff)

        let dark = SdkThemeRules.palette(sdk: sdk("white", mode: "dark"), override: nil)
        XCTAssertEqual(dark.hero, dark.background)
        XCTAssertEqual(dark.primary, 0xffffff)
        XCTAssertEqual(dark.onPrimary, 0x111111)
    }

    func testCustomAccentDrivesTheHeroNotPrimary() {
        let p = SdkThemeRules.palette(sdk: sdk(nil, "#0B5FFF"), override: nil)
        XCTAssertEqual(p.hero, 0x0b5fff)
        XCTAssertEqual(p.onHero, 0xffffff) // dark blue accent → white text (WCAG)
        XCTAssertEqual(p.primary, 0x111111)
    }

    func testUnknownThemeFallsBackToAccent() {
        let p = SdkThemeRules.palette(sdk: sdk("neon"), override: nil)
        XCTAssertEqual(p.hero, 0xffc400)
    }

    func testInvalidAccentFallsBackToDefault() {
        let p = SdkThemeRules.palette(sdk: sdk(nil, "not-a-color"), override: nil)
        XCTAssertEqual(p.hero, 0xffc400)
    }

    func testOverrideWinsOverPreset() {
        let o = NaraChat.ThemeOverride(primary: "#00FF00", background: "#111111")
        let p = SdkThemeRules.palette(sdk: sdk(nil, "#FF0000", mode: "light"), override: o)
        XCTAssertEqual(p.primary, 0x00ff00) // override beats the ink default
        XCTAssertEqual(p.background, 0x111111)
        XCTAssertTrue(p.dark) // a dark background switches the neutrals, whatever the mode says

        let lightBackground = SdkThemeRules.palette(
            sdk: sdk(mode: "dark"),
            override: NaraChat.ThemeOverride(background: "#FFFFFF")
        )
        XCTAssertFalse(lightBackground.dark)
        XCTAssertEqual(lightBackground.text, 0x1a1a1a)
    }

    func testNeutralsFollowTheDisplayMode() {
        // Measured in the reference: card #FBFBFB, border #EBEBEB, band #F3F3F3.
        let light = SdkThemeRules.palette(sdk: nil, override: nil)
        XCTAssertEqual(light.card, 0xfbfbfb)
        XCTAssertEqual(light.cardBorder, 0xebebeb)
        XCTAssertEqual(light.band, 0xf3f3f3)

        let dark = SdkThemeRules.palette(sdk: sdk(mode: "dark"), override: nil)
        XCTAssertEqual(dark.card, 0x2a2a2a)
        XCTAssertEqual(dark.cardBorder, 0x3a3a3a)
        XCTAssertEqual(dark.band, 0x1e1e1e)
    }

    // MARK: - Greeting

    func testGreetingDefaultsPerLocale() {
        XCTAssertEqual(SdkThemeRules.greetingTitle(nil, locale: "id"), "Hai 👋")
        XCTAssertEqual(SdkThemeRules.greetingSubtitle(nil, locale: "id"), "Ada yang bisa kami bantu?")
        XCTAssertEqual(SdkThemeRules.greetingTitle(nil, locale: "en"), "Hi There")
        XCTAssertEqual(SdkThemeRules.greetingSubtitle(nil, locale: "en"), "How Can We Help?")
    }

    func testCustomGreetingWinsForAllLocales() {
        let s = sdk(nil, nil, title: "Butuh bantuan?", subtitle: "Kami siap membantu")
        XCTAssertEqual(SdkThemeRules.greetingTitle(s, locale: "en"), "Butuh bantuan?")
        XCTAssertEqual(SdkThemeRules.greetingSubtitle(s, locale: "id"), "Kami siap membantu")
    }

    func testEmptyCustomGreetingFallsBackToLocaleDefault() {
        let s = sdk(nil, nil, title: "", subtitle: "")
        XCTAssertEqual(SdkThemeRules.greetingTitle(s, locale: "id"), "Hai 👋")
        XCTAssertEqual(SdkThemeRules.greetingSubtitle(s, locale: "en"), "How Can We Help?")
    }

    // MARK: - UI language

    func testUiLanguageResolutionOrder() {
        // The developer override, then style.sdk.locale, then settings.locale, else Indonesian.
        XCTAssertEqual(
            SdkThemeRules.resolveLocale(override: "en", styleLocale: "id", settingsLocale: "id"), "en"
        )
        XCTAssertEqual(
            SdkThemeRules.resolveLocale(override: nil, styleLocale: "en", settingsLocale: "id"), "en"
        )
        XCTAssertEqual(
            SdkThemeRules.resolveLocale(override: nil, styleLocale: nil, settingsLocale: "en"), "en"
        )
        XCTAssertEqual(
            SdkThemeRules.resolveLocale(override: nil, styleLocale: nil, settingsLocale: nil), "id"
        )
        // Unsupported values are skipped, so a later source still decides.
        XCTAssertEqual(
            SdkThemeRules.resolveLocale(override: "fr", styleLocale: "xx", settingsLocale: "EN"), "en"
        )
        XCTAssertEqual(
            SdkThemeRules.resolveLocale(override: "fr", styleLocale: "xx", settingsLocale: "ja"), "id"
        )
    }

    func testUiLanguageIgnoresCaseAndWhitespace() {
        XCTAssertEqual(SdkThemeRules.parseLocale(" EN "), "en")
        XCTAssertEqual(SdkThemeRules.parseLocale("ID"), "id")
        XCTAssertNil(SdkThemeRules.parseLocale(nil))
        XCTAssertNil(SdkThemeRules.parseLocale(""))
        XCTAssertNil(SdkThemeRules.parseLocale("en-US"))
    }

    func testEveryScreenSharesTheLanguageResolver() throws {
        let json = #"{"key":"k","name":"N","style":{"sdk":{"locale":"en"}},"settings":{"locale":"id"}}"#
        let c = try JSONDecoder().decode(WidgetConfig.self, from: json.data(using: .utf8)!)
        XCTAssertFalse(sdkIsId(locale: nil, config: c)) // style.sdk.locale beats settings.locale
        XCTAssertTrue(sdkIsId(locale: "id", config: c)) // the developer override beats both
        XCTAssertFalse(sdkIsId(locale: "en", config: nil))
        XCTAssertTrue(sdkIsId(locale: nil, config: nil))
    }

    func testFallbackTextFollowsTheUiLanguage() throws {
        let unknown = try message(
            #"{"id":"m1","from":"agent","senderName":"Ana","type":"product_card","body":"{}","status":"received","sentAt":"2026-11-22T00:00:00Z"}"#
        )
        let m = ChatMessage.withFallback(unknown, locale: "id")
        XCTAssertEqual(m.type, "fallback")
        XCTAssertEqual(m.displayBody(isId: true), ChatMessage.fallbackBodyId)
        XCTAssertEqual(m.displayBody(isId: false), ChatMessage.fallbackBodyEn)
    }

    func testDisplayBodyPassesTextThrough() throws {
        let m = try message(#"{"id":"m1","from":"visitor","senderName":"Zai","type":"text","body":"hai","status":"sent","sentAt":"2026-11-22T00:00:00Z"}"#)
        XCTAssertEqual(m.displayBody(isId: true), "hai")
        XCTAssertEqual(m.displayBody(isId: false), "hai")
    }

    // MARK: - Hex & luminance

    func testHexParserAcceptsColorFormsAndRejectsTheRest() {
        XCTAssertEqual(SdkThemeRules.parseHex("#FF00AA"), 0xff00aa)
        XCTAssertEqual(SdkThemeRules.parseHex("#80FF00AA"), 0xff00aa) // AARRGGBB, alpha dropped
        XCTAssertEqual(SdkThemeRules.parseHex("#F00"), 0xff0000)      // short RGB, nibble doubled
        XCTAssertEqual(SdkThemeRules.parseHex("#AF00"), 0xff0000)     // short ARGB, nibbles doubled
        XCTAssertNil(SdkThemeRules.parseHex(nil))
        XCTAssertNil(SdkThemeRules.parseHex(""))
        XCTAssertNil(SdkThemeRules.parseHex("FF00AA"))   // missing #
        XCTAssertNil(SdkThemeRules.parseHex("#GGGGGG"))
        XCTAssertNil(SdkThemeRules.parseHex("#FF00AAFF00")) // too long
    }

    func testLuminanceExtremes() {
        XCTAssertLessThan(SdkThemeRules.luminance(0x000000), 0.5)
        XCTAssertGreaterThanOrEqual(SdkThemeRules.luminance(0xffffff), 0.5)
    }

    func testOnColorFollowsLuminance() {
        XCTAssertEqual(SdkThemeRules.onColor(0xffc400), 0x111111)
        XCTAssertEqual(SdkThemeRules.onColor(0x0b5fff), 0xffffff)
        XCTAssertEqual(SdkThemeRules.onColor(0x111111), 0xffffff)
    }

    // MARK: - Lenient decoding

    func testConfigDecodesSdkStyleAndLogoUrl() throws {
        let json = """
        {"key":"nk_x","name":"Nara","online":true,
         "style":{"logoUrl":"https://cdn.example.com/logo.png",
                  "sdk":{"theme":"white","accent":"#00AAFF","greetingTitle":"Halo!","greetingSubtitle":"Siap bantu"}},
         "settings":{"locale":"id"}}
        """.data(using: .utf8)!
        let c = try JSONDecoder().decode(WidgetConfig.self, from: json)
        XCTAssertEqual(c.style?.logoUrl, "https://cdn.example.com/logo.png")
        XCTAssertEqual(c.style?.sdk?.theme, "white")
        XCTAssertEqual(c.style?.sdk?.accent, "#00AAFF")
        XCTAssertEqual(c.style?.sdk?.greetingTitle, "Halo!")
        XCTAssertEqual(c.style?.sdk?.greetingSubtitle, "Siap bantu")
        XCTAssertTrue(c.style?.sdk?.isWhiteTheme ?? false)
        XCTAssertFalse(c.style?.sdk?.isDarkMode ?? true)
        XCTAssertNil(c.style?.sdk?.locale)
    }

    func testConfigWithoutStyleSdkDecodesToDefaults() throws {
        let json = #"{"key":"k","name":"N","style":{"colors":{}},"settings":{}}"#.data(using: .utf8)!
        let c = try JSONDecoder().decode(WidgetConfig.self, from: json)
        XCTAssertNil(c.style?.logoUrl)
        XCTAssertNil(c.style?.sdk)
        XCTAssertFalse(c.style?.sdk?.isWhiteTheme ?? false) // nil sdk → accent preset
        XCTAssertEqual(c.style?.sdk?.normalizedAccent ?? SdkThemeRules.defaultAccentHex, "#ffc400")

        // Entire style missing → still no crash, defaults everywhere.
        let bare = #"{"key":"k","name":"N"}"#.data(using: .utf8)!
        let b = try JSONDecoder().decode(WidgetConfig.self, from: bare)
        XCTAssertNil(b.style?.logoUrl)
        XCTAssertNil(b.style?.sdk)
    }

    func testExplicitNullLogoUrlDecodesToNil() throws {
        let json = #"{"key":"k","name":"N","style":{"logoUrl":null,"sdk":{}},"settings":{}}"#.data(using: .utf8)!
        let c = try JSONDecoder().decode(WidgetConfig.self, from: json)
        XCTAssertNil(c.style?.logoUrl)
        XCTAssertEqual(c.style?.sdk, .init()) // empty block → all nils → the defaults
    }

    func testStyleSdkModeAndLocaleDecodeLeniently() throws {
        let json = #"{"key":"k","name":"N","style":{"sdk":{"mode":"dark","locale":"en"}}}"#.data(using: .utf8)!
        let c = try JSONDecoder().decode(WidgetConfig.self, from: json)
        XCTAssertEqual(c.style?.sdk?.isDarkMode, true)
        XCTAssertEqual(c.style?.sdk?.locale, "en")

        // A null or non-string value is simply ignored.
        let odd = #"{"key":"k","name":"N","style":{"sdk":{"mode":null,"locale":7}}}"#.data(using: .utf8)!
        let o = try JSONDecoder().decode(WidgetConfig.self, from: odd)
        XCTAssertFalse(o.style?.sdk?.isDarkMode ?? true)
        XCTAssertNil(o.style?.sdk?.locale)

        let unknownMode = #"{"key":"k","name":"N","style":{"sdk":{"mode":"blue","locale":"id"}}}"#.data(using: .utf8)!
        let u = try JSONDecoder().decode(WidgetConfig.self, from: unknownMode)
        XCTAssertFalse(u.style?.sdk?.isDarkMode ?? true)
        XCTAssertEqual(u.style?.sdk?.locale, "id")
    }
}
