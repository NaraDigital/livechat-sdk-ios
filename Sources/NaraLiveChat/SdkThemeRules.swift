import Foundation

// MARK: - SDK style rules — pure & testable
//
// Mirrors the Android `naraColors()` 1:1 so both platforms render the same preset:
// - `style.sdk` (theme / accent / mode) is the source for the display mode, the
//   background and the Home hero surface. The legacy `style.colors.primary|
//   background|text` are NO LONGER consulted; `style.colors.bubble*` still style the
//   chat bubbles (BubblePalette).
// - The accent paints one place, the Home hero. theme "white": hero = background.
// - `primary` (main actions on every screen) is ink: #111111 in light mode, white in
//   dark, whatever the accent is.
// - The display mode comes from `style.sdk.mode` alone and defaults to light. The
//   phone's dark mode is never an input.
// - The app-side `NaraChat.themeOverride` still wins over everything it defines.
//
// Pure Foundation (UInt32 RGB slots) so the rules unit-test without SwiftUI; the
// view layer maps the palette into `Color`.

public enum SdkThemeRules {

    public static let defaultAccentHex = "#ffc400"

    /// Resolved theme slots as opaque 0xRRGGBB values.
    public struct Palette: Equatable, Sendable {
        /// True when the effective (override-aware) background is dark.
        public let dark: Bool
        public let background: UInt32
        public let text: UInt32
        public let primary: UInt32
        public let onPrimary: UInt32
        /// Home hero only (accent preset → accent, white preset → background).
        public let hero: UInt32
        public let onHero: UInt32
        /// Neutrals of the reference layout: the entry card, its hairline border, the FAQ band.
        public let card: UInt32
        public let cardBorder: UInt32
        public let band: UInt32
    }

    public static func palette(
        sdk: WidgetConfig.Style.SdkStyle?,
        override: NaraChat.ThemeOverride?
    ) -> Palette {
        let whiteTheme = sdk?.isWhiteTheme == true
        let accent = parseHex(sdk?.normalizedAccent) ?? 0xffc400

        let background = parseHex(override?.background) ?? (sdk?.isDarkMode == true ? 0x111111 : 0xffffff)
        let dark = luminance(background) < 0.5
        let text = parseHex(override?.text) ?? (dark ? 0xf5f5f5 : 0x1a1a1a)

        // Main actions are ink in both modes, whatever the accent.
        let primary = parseHex(override?.primary) ?? (dark ? 0xffffff : 0x111111)

        // Home hero surface: accent preset → accent; white preset → the page background.
        let hero = whiteTheme ? background : accent

        return Palette(
            dark: dark,
            background: background,
            text: text,
            primary: primary,
            onPrimary: onColor(primary),
            hero: hero,
            onHero: onColor(hero),
            // Measured in the reference (card #FBFBFB, border #EBEBEB, band #F3F3F3),
            // with their dark set.
            card: dark ? 0x2a2a2a : 0xfbfbfb,
            cardBorder: dark ? 0x3a3a3a : 0xebebeb,
            band: dark ? 0x1e1e1e : 0xf3f3f3
        )
    }

    /// Text color for a filled surface: black #111111 or white by WCAG luminance.
    public static func onColor(_ rgb: UInt32) -> UInt32 {
        luminance(rgb) >= 0.5 ? 0x111111 : 0xffffff
    }

    // MARK: Greeting

    /// Custom non-empty greeting wins for all locales; otherwise the locale default.
    public static func greetingTitle(_ sdk: WidgetConfig.Style.SdkStyle?, locale: String) -> String {
        if let t = sdk?.greetingTitle, !t.isEmpty { return t }
        return locale.hasPrefix("id") ? "Hai 👋" : "Hi There"
    }

    public static func greetingSubtitle(_ sdk: WidgetConfig.Style.SdkStyle?, locale: String) -> String {
        if let s = sdk?.greetingSubtitle, !s.isEmpty { return s }
        return locale.hasPrefix("id") ? "Ada yang bisa kami bantu?" : "How Can We Help?"
    }

    // MARK: UI language

    public static let localeId = "id"
    public static let localeEn = "en"

    /// A supported UI language for `raw`, or nil when it is missing or unsupported.
    /// Case and surrounding whitespace are ignored.
    public static func parseLocale(_ raw: String?) -> String? {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "id": return localeId
        case "en": return localeEn
        default: return nil
        }
    }

    /// SDK UI language: the developer override, then `style.sdk.locale`, then
    /// `settings.locale`, else Indonesian. The server sends "en" for INTL workspaces.
    public static func resolveLocale(
        override: String?, styleLocale: String?, settingsLocale: String?
    ) -> String {
        parseLocale(override) ?? parseLocale(styleLocale) ?? parseLocale(settingsLocale) ?? localeId
    }

    // MARK: Hex & luminance

    /// Parses `#RGB`, `#ARGB`, `#RRGGBB`, `#AARRGGBB` (case-insensitive) to 0xRRGGBB
    /// (alpha ignored — SDK surfaces are opaque). Short forms double each nibble,
    /// matching Android `Color.parseColor`. Returns nil for anything else.
    public static func parseHex(_ hex: String?) -> UInt32? {
        guard var s = hex?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        guard s.removeFirst() == "#" else { return nil }
        guard s.allSatisfy(\.isHexDigit), [3, 4, 6, 8].contains(s.count) else { return nil }

        // Short forms double each nibble (matches Android Color.parseColor).
        let normalized = (s.count == 3 || s.count == 4) ? s.map { String($0) + String($0) }.joined() : s
        guard let v = UInt64(normalized, radix: 16) else { return nil }
        let argb = UInt32(truncatingIfNeeded: v)
        switch normalized.count {
        case 8: return argb & 0xff_ff_ff   // AARRGGBB → drop alpha
        case 6: return argb                // RRGGBB
        default: return nil
        }
    }

    /// WCAG relative luminance of an sRGB color (0 = black, 1 = white).
    public static func luminance(_ rgb: UInt32) -> Double {
        func channel(_ shift: UInt32) -> Double {
            let c = Double((rgb >> shift) & 0xff) / 255.0
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }
}
