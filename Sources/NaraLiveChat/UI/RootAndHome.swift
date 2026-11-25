import SwiftUI
import Combine
import UIKit

// MARK: - Root

struct NaraChatRootView: View {
    let start: NaraDestination
    let articleSlug: String?

    enum Screen { case home, messages, chat, help, article(String), prechat }

    @State private var screen: Screen
    @ObservedObject private var nara = NaraChat.shared
    @StateObject private var model = MessengerModel()

    init(start: NaraDestination, articleSlug: String?) {
        self.start = start
        self.articleSlug = articleSlug
        _screen = State(initialValue: articleSlug.map { Screen.article($0) } ?? {
            switch start {
            case .home: return .home
            case .messages: return .messages
            case .help: return .help
            }
        }())
    }

    /// Display mode of the loaded config: `style.sdk.mode` alone, light until it loads.
    private var palette: SdkThemeRules.Palette {
        SdkThemeRules.palette(sdk: nara.configValue?.style?.sdk, override: nara.themeOverride)
    }

    /// True while the accent hero sits under the status bar: Home and the offline notice, once
    /// the chat is allowed.
    private var heroUnderStatusBar: Bool {
        if nara.updateRequired { return false }
        if nara.configValue?.isOfflineMode == true { return true }
        if case .home = screen { return true }
        return false
    }

    /// The status bar icons contrast with the hero on Home and with the page background
    /// everywhere else; the hosting controller owns the style itself.
    private func syncStatusBar() {
        NaraChat.shared.hostingController?.heroUnderStatusBar = heroUnderStatusBar
    }

    var body: some View {
        Group {
            if nara.updateRequired {
                UpdateRequiredScreen()
            } else if let config = nara.configValue, config.isOfflineMode {
                // The widget takes no chat right now: one notice stands in for every screen.
                OfflineScreen(config: config)
            } else {
                switch screen {
                case .home:
                    HomeScreen(model: model, onMessages: { screen = .messages }, onHelp: { screen = .help }, onArticle: { screen = .article($0) })
                case .messages:
                    MessagesScreen(model: model, onBack: { screen = .home }, onOpenChat: { screen = .chat })
                case .chat:
                    ChatScreen(model: model, onBack: { screen = .home }, onNeedPrechat: { screen = .prechat })
                case .help:
                    HelpScreen(onBack: { screen = .home }, onArticle: { screen = .article($0) })
                case .article(let slug):
                    ArticleScreen(slug: slug, onBack: { screen = .help })
                case .prechat:
                    PrechatFormScreen(model: model, onDone: { screen = .chat })
                }
            }
        }
        // The SDK never follows the phone's dark mode: the display mode is pinned for
        // every color in the subtree, and the page paints its own background.
        .environment(\.colorScheme, palette.dark ? .dark : .light)
        .background(Color(rgb: palette.background).ignoresSafeArea())
        .onAppear {
            model.start()
            syncStatusBar()
        }
        .onDisappear {
            model.stop()
        }
        .onChange(of: heroUnderStatusBar) { _ in syncStatusBar() }
    }
}

struct UpdateRequiredScreen: View {
    var body: some View {
        VStack(spacing: 10) {
            Text("Update required").font(.title2).bold()
            Text("This version of the app is too old to chat. Please update the app to continue.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }
}

// MARK: - Model

/// Bridges SessionManager (Combine) into SwiftUI and owns the realtime link's lifecycle.
@MainActor
final class MessengerModel: ObservableObject {

    @Published var state = SessionManager.SessionUiState()
    @Published var config: WidgetConfig?
    /// The realtime link is down and being re-established.
    @Published var reconnecting = false

    private var cancellables = Set<AnyCancellable>()
    private var started = false
    /// The messenger was on screen when the app left the foreground.
    private var leftForeground = false

    init() {
        SessionManager.shared.realtimeState
            .map { $0 == .reconnecting }
            .receive(on: DispatchQueue.main)
            .assign(to: &$reconnecting)

        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .map { _ in false }
            .merge(with: NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification).map { _ in true })
            .sink { [weak self] active in self?.foregroundChanged(active: active) }
            .store(in: &cancellables)
    }

    func start() {
        config = NaraChat.shared.configValue
        NaraChat.shared.$configValue.receive(on: DispatchQueue.main).assign(to: &$config)

        SessionManager.shared.state
            .receive(on: DispatchQueue.main)
            .assign(to: &$state)

        guard !started else { return }
        started = true
        Task {
            let session = await SessionManager.shared.ensureSession()
            // With no session the call would only ask for one again — unless the widget is
            // offline, when it just keeps the link wanted for when its config turns live.
            if session != nil || NaraChat.shared.configValue?.isOfflineMode == true {
                SessionManager.shared.openRealtime()
            }
        }
    }

    func stop() {
        SessionManager.shared.closeRealtime()
        started = false
        leftForeground = false
    }

    /// The socket usually dies while the app is in the background: back on screen it is dialed
    /// again. The Style SDK may have been edited in the dashboard meanwhile, so it is fetched again.
    private func foregroundChanged(active: Bool) {
        guard started else { return }
        if active {
            guard leftForeground else { return }
            leftForeground = false
            SessionManager.shared.openRealtime(reopen: true)
            NaraChat.shared.refreshConfig()
        } else {
            leftForeground = true
        }
    }
}

// MARK: - Theme helpers

extension Color {
    /// A `#rrggbb` color from the server (short Android forms accepted), else [fallback].
    static func nara(_ hex: String?, fallback: Color) -> Color {
        guard let rgb = SdkThemeRules.parseHex(hex) else { return fallback }
        return Color(rgb: rgb)
    }

    /// Maps a resolved 0xRRGGBB slot from [SdkThemeRules.Palette] into a Color.
    init(rgb: UInt32) {
        self.init(
            red: Double((rgb >> 16) & 0xff) / 255,
            green: Double((rgb >> 8) & 0xff) / 255,
            blue: Double(rgb & 0xff) / 255
        )
    }
}

struct BubblePalette {
    let visitor: Color
    let visitorText: Color
    let agent: Color
    let agentText: Color
    /// The ink `primary` for main actions next to the bubbles (read ticks).
    let ink: Color

    /// `style.colors.bubble*`, the developer override above them, then the palette
    /// defaults: the ink primary for the visitor bubble, with a readable text on it.
    static func from(_ config: WidgetConfig?, palette: SdkThemeRules.Palette) -> BubblePalette {
        let c = config?.style?.colors
        let o = NaraChat.shared.themeOverride
        let visitorHex = o?.bubbleVisitor ?? c?.bubbleVisitor
        // Without a text color the visitor text follows the bubble's contrast.
        let onVisitor = SdkThemeRules.onColor(SdkThemeRules.parseHex(visitorHex) ?? palette.primary)
        return BubblePalette(
            visitor: Color.nara(visitorHex, fallback: Color(rgb: palette.primary)),
            visitorText: Color.nara(o?.bubbleVisitorText ?? c?.bubbleVisitorText, fallback: Color(rgb: onVisitor)),
            agent: Color.nara(o?.bubbleAgent ?? c?.bubbleAgent, fallback: Color(rgb: palette.dark ? 0x2a2a2a : 0xf0f0f0)),
            agentText: Color.nara(o?.bubbleAgentText ?? c?.bubbleAgentText, fallback: Color(rgb: palette.text)),
            ink: Color(rgb: palette.primary)
        )
    }
}

/// SDK UI language for every screen: `NaraChat.locale` → `style.sdk.locale` →
/// `settings.locale` → Indonesian. True for the Indonesian UI.
func sdkIsId(locale: String?, config: WidgetConfig?) -> Bool {
    SdkThemeRules.resolveLocale(
        override: locale,
        styleLocale: config?.style?.sdk?.locale,
        settingsLocale: config?.settings?.locale
    ) == SdkThemeRules.localeId
}

// MARK: - Home (reference layout)

struct HomeScreen: View {
    @ObservedObject var model: MessengerModel
    let onMessages: () -> Void
    let onHelp: () -> Void
    let onArticle: (String) -> Void

    @State private var help: HelpOverview?
    @State private var expandedFaq: String?
    @Environment(\.dismiss) private var dismiss

    var isId: Bool { sdkIsId(locale: NaraChat.shared.locale, config: model.config) }

    /// Resolved "SDK style" palette — pure rules in [SdkThemeRules].
    private var palette: SdkThemeRules.Palette {
        SdkThemeRules.palette(sdk: model.config?.style?.sdk, override: NaraChat.shared.themeOverride)
    }

    private var whiteTheme: Bool { model.config?.style?.sdk?.isWhiteTheme == true }

    /// Hero backdrop: accent fading into the page background (§2); the white preset
    /// keeps the plain page background with no fill (§4).
    private var heroBackground: LinearGradient {
        let from = whiteTheme ? Color(rgb: palette.background) : Color(rgb: palette.hero)
        return LinearGradient(colors: [from, Color(rgb: palette.background)], startPoint: .top, endPoint: .bottom)
    }

    var body: some View {
        ZStack(alignment: .top) {
            heroBackground.frame(height: 328).bleedingUnderStatusBar()

            ScrollView {
                VStack(spacing: 0) {
                    // Top bar: the logo at the start, the close button at the far right.
                    HStack {
                        TopBarLogo(
                            logoUrl: model.config?.style?.logoUrl,
                            fallbackTitle: model.config?.style?.header?.title?.isEmpty == false
                                ? model.config?.style?.header?.title : model.config?.name,
                            tint: Color(rgb: palette.onHero)
                        )
                        .lineLimit(1)
                        Spacer()
                        ClosePill(
                            fill: Color(rgb: palette.primary),
                            icon: Color(rgb: palette.onPrimary),
                            label: isId ? "Tutup" : "Close",
                            onClose: { dismiss() }
                        )
                        .layoutPriority(1)
                    }
                    .padding(.horizontal, 21).padding(.top, 16)

                    // Two-line greeting (§2): small muted title, large bold subtitle.
                    VStack(alignment: .leading, spacing: 6) {
                        Text(SdkThemeRules.greetingTitle(model.config?.style?.sdk, locale: isId ? "id" : "en"))
                            .font(.body).foregroundColor(Color(rgb: palette.onHero).opacity(0.65))
                        Text(SdkThemeRules.greetingSubtitle(model.config?.style?.sdk, locale: isId ? "id" : "en"))
                            .font(.title2).bold().foregroundColor(Color(rgb: palette.onHero))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 28).padding(.top, 32).padding(.bottom, 24)

                    // White 2-row entries card (Messages / Help) overlapping the hero.
                    VStack(spacing: 0) {
                        entryRow(label: isId ? "Pesan" : "Messages", systemImage: "bubble.left.and.bubble.right", action: onMessages)
                        DashedDivider(color: Color(rgb: palette.cardBorder))
                            .padding(.horizontal, 16)
                        entryRow(label: isId ? "Bantuan" : "Help", systemImage: "questionmark.circle", action: onHelp)
                    }
                    .background(Color(rgb: palette.card))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color(rgb: palette.cardBorder), lineWidth: 1))
                    .cornerRadius(16)
                    .padding(.horizontal, 21)

                    // Last conversation — outlined card, hidden until a conversation exists.
                    if let last = model.state.messages.last(where: { !$0.isSystem }) {
                        Button(action: onMessages) {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(model.config?.style?.header?.title?.isEmpty == false
                                        ? model.config?.style?.header?.title ?? "Chat" : model.config?.name ?? "Chat")
                                        .font(.body.bold()).foregroundColor(Color(rgb: palette.text))
                                    Text(last.displayBody(isId: isId)).font(.subheadline)
                                        .foregroundColor(Color(rgb: palette.text).opacity(0.6))
                                        .lineLimit(2)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.medium())
                                    .foregroundColor(Color(rgb: palette.text).opacity(0.4))
                            }
                            .padding(16)
                            .background(Color(rgb: palette.card))
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color(rgb: palette.cardBorder), lineWidth: 1))
                            .cornerRadius(16)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 21).padding(.top, 12)
                    }

                    // FAQ section — header band + top-4 rows; hidden without help content.
                    let faqItems = Array((help?.faqs ?? []).prefix(4))
                    let articleItems = Array((help?.articles ?? []).prefix(max(0, 4 - faqItems.count)))
                    if !faqItems.isEmpty || !articleItems.isEmpty {
                        VStack(spacing: 0) {
                            HStack {
                                Text(isId ? "Pusat Bantuan" : "Help Center")
                                    .font(.body.bold()).foregroundColor(Color(rgb: palette.text))
                                Spacer()
                                Button(action: onHelp) {
                                    Text(isId ? "Lihat semua" : "See all")
                                        .font(.subheadline.medium())
                                        .foregroundColor(Color(rgb: palette.primary))
                                }
                            }
                            .padding(.horizontal, 16).padding(.vertical, 12)
                            .background(Color(rgb: palette.band))

                            VStack(spacing: 0) {
                                ForEach(Array(faqItems.enumerated()), id: \.element.id) { i, f in
                                    faqRow(f, index: i, isLast: i == faqItems.count - 1 && articleItems.isEmpty)
                                }
                                ForEach(Array(articleItems.enumerated()), id: \.element.id) { i, a in
                                    Button { onArticle(a.slug) } label: {
                                        HStack {
                                            Text(a.title).font(.subheadline)
                                                .foregroundColor(Color(rgb: palette.text))
                                                .lineLimit(1)
                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .font(.caption.medium())
                                                .foregroundColor(Color(rgb: palette.text).opacity(0.4))
                                        }
                                        .padding(.horizontal, 16).padding(.vertical, 12)
                                    }
                                    .buttonStyle(.plain)
                                    if i < articleItems.count - 1 {
                                        Divider().overlay(Color(rgb: palette.cardBorder)).padding(.leading, 16)
                                    }
                                }
                            }
                        }
                        .background(Color(rgb: palette.card))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color(rgb: palette.cardBorder), lineWidth: 1))
                        .padding(.horizontal, 21).padding(.top, 24)
                    }

                    Spacer(minLength: 24)
                }
            }
        }
        .task {
            if let key = NaraChat.shared.appKey {
                help = try? await NaraChat.shared.api.helpOverview(appKey: key)
            }
        }
    }

    private func entryRow(label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.body.medium())
                    .foregroundColor(Color(rgb: palette.text))
                Text(label).font(.body.medium())
                    .foregroundColor(Color(rgb: palette.text))
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.medium())
                    .foregroundColor(Color(rgb: palette.text).opacity(0.4))
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
        }
        .buttonStyle(.plain)
    }

    private func faqRow(_ f: HelpOverview.Faq, index: Int, isLast: Bool) -> some View {
        let expanded = expandedFaq == "faq\(index)"
        return Button {
            withAnimation { expandedFaq = expanded ? nil : "faq\(index)" }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(f.question).font(.subheadline)
                        .foregroundColor(Color(rgb: palette.text))
                        .lineLimit(expanded ? 3 : 1)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.medium())
                        .foregroundColor(Color(rgb: palette.text).opacity(0.4))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                if expanded && !f.answer.isEmpty {
                    Text(f.answer).font(.caption)
                        .foregroundColor(Color(rgb: palette.text).opacity(0.6))
                        .padding(.horizontal, 16).padding(.bottom, 12)
                }
                if !isLast {
                    Divider().overlay(Color(rgb: palette.cardBorder)).padding(.leading, 16)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

/// The widget takes no chat right now — its owner's plan ended, or it is over its quota. What it
/// says is the server's (`offline.title` / `offline.text`); nothing else is offered, because the
/// SDK has no way to leave an offline message.
struct OfflineScreen: View {
    let config: WidgetConfig

    @Environment(\.dismiss) private var dismiss

    private var isId: Bool { sdkIsId(locale: NaraChat.shared.locale, config: config) }

    private var palette: SdkThemeRules.Palette {
        SdkThemeRules.palette(sdk: config.style?.sdk, override: NaraChat.shared.themeOverride)
    }

    private var notice: (title: String, text: String) { offlineNotice(config, isId: isId) }

    /// Same backdrop as Home: the white preset keeps the plain page background with no fill.
    private var heroBackground: LinearGradient {
        let from = config.style?.sdk?.isWhiteTheme == true ? Color(rgb: palette.background) : Color(rgb: palette.hero)
        return LinearGradient(colors: [from, Color(rgb: palette.background)], startPoint: .top, endPoint: .bottom)
    }

    var body: some View {
        ZStack(alignment: .top) {
            heroBackground.frame(height: 328).bleedingUnderStatusBar()

            ScrollView {
                VStack(spacing: 0) {
                    HStack {
                        TopBarLogo(
                            logoUrl: config.style?.logoUrl,
                            fallbackTitle: config.style?.header?.title?.isEmpty == false
                                ? config.style?.header?.title : config.name,
                            tint: Color(rgb: palette.onHero)
                        )
                        .lineLimit(1)
                        Spacer()
                        ClosePill(
                            fill: Color(rgb: palette.primary),
                            icon: Color(rgb: palette.onPrimary),
                            label: isId ? "Tutup" : "Close",
                            onClose: { dismiss() }
                        )
                        .layoutPriority(1)
                    }
                    .padding(.horizontal, 21).padding(.top, 16)

                    Text(notice.title)
                        .font(.title2).bold().foregroundColor(Color(rgb: palette.onHero))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 28).padding(.top, 36).padding(.bottom, 24)

                    Text(notice.text)
                        .font(.body).foregroundColor(Color(rgb: palette.text))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                        .background(Color(rgb: palette.card))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color(rgb: palette.cardBorder), lineWidth: 1))
                        .cornerRadius(16)
                        .padding(.horizontal, 21)

                    Spacer(minLength: 24)
                }
            }
        }
    }
}

/// Top-bar logo (§3.1): `style.logoUrl`, falling back to a one-line wordmark.
private struct TopBarLogo: View {
    let logoUrl: String?
    let fallbackTitle: String?
    let tint: Color

    var body: some View {
        if let url = logoUrl.flatMap(URL.init(string:)), !url.absoluteString.isEmpty {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFit().frame(height: 34).clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    wordmark
                }
            }
        } else {
            wordmark
        }
    }

    private var wordmark: some View {
        Text(fallbackTitle?.isEmpty == false ? fallbackTitle! : "Help")
            .font(.title3.bold())
            .foregroundColor(tint)
            .lineLimit(1)
    }
}

/// Close button: a solid 44pt circle with the ✕ icon only — ink with a white icon in
/// light mode, inverted in dark. The accessible name keeps the word for VoiceOver.
private struct ClosePill: View {
    let fill: Color
    let icon: Color
    let label: String
    let onClose: () -> Void

    var body: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(icon)
                .frame(width: 44, height: 44)
                .background(Circle().fill(fill))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Dashed hairline divider between the entries card rows (reference wireframe).
private struct DashedDivider: View {
    let color: Color

    var body: some View {
        GeometryReader { geo in
            Path { path in
                path.move(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: geo.size.width, y: 0))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1, dash: [8, 6]))
        }
        .frame(height: 1)
    }
}

extension View {
    /// The hero backdrop bleeds up behind the status bar like the Android root insets.
    func bleedingUnderStatusBar() -> some View {
        ignoresSafeArea(.container, edges: .top)
    }
}

extension Font {
    func medium() -> Font { self.weight(.medium) }
}

// MARK: - Messages (spec screen 2)

struct MessagesScreen: View {
    @ObservedObject var model: MessengerModel
    let onBack: () -> Void
    let onOpenChat: () -> Void
    @ObservedObject private var nara = NaraChat.shared

    var isId: Bool { sdkIsId(locale: nara.locale, config: model.config) }

    private var palette: SdkThemeRules.Palette {
        SdkThemeRules.palette(sdk: model.config?.style?.sdk, override: nara.themeOverride)
    }

    var body: some View {
        VStack(spacing: 0) {
            NaraBackHeader(title: isId ? "Pesan" : "Messages", backLabel: isId ? "Kembali" : "Back", onBack: onBack)
            let thread = model.state.messages.last { !$0.isSystem }
            let avatar = ThreadAvatarRules.avatar(
                messages: model.state.messages,
                widgetName: model.config?.name,
                headerTitle: model.config?.style?.header?.title,
                fallbackTitle: isId ? "Obrolan" : "Conversation",
                handlerAvatarUrl: model.state.handler?.avatarUrl,
                aiAvatarUrl: model.config?.aiAgent?.avatarUrl
            )
            Button(action: onOpenChat) {
                HStack(spacing: 12) {
                    AvatarCircle(
                        avatar: avatar, size: 40, font: .system(size: 16, weight: .semibold), palette: palette
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.config?.style?.header?.title ?? model.config?.name ?? (isId ? "Obrolan" : "Conversation"))
                            .font(.body.medium()).foregroundColor(Color(rgb: palette.text))
                        Text(thread.map { $0.displayBody(isId: isId) } ?? (isId ? "Belum ada pesan — mulai ngobrol" : "No messages yet — say hi"))
                            .font(.caption).foregroundColor(Color(rgb: palette.text).opacity(0.6)).lineLimit(1)
                    }
                    Spacer()
                    if nara.unreadCount > 0 {
                        Text("\(nara.unreadCount)")
                            .font(.caption2).bold().foregroundColor(.white)
                            .padding(6).background(Circle().fill(.red))
                    } else if let h = model.state.handler, h.type != "none", let name = h.name {
                        Text(name).font(.caption).foregroundColor(Color(rgb: palette.text).opacity(0.6))
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("nara.messages.thread")
            Spacer()
        }
        .background(Color(rgb: palette.background))
    }
}

struct NaraBackHeader: View {
    let title: String
    /// Accessible name of the back button, in the SDK UI language.
    var backLabel: String = "Back"
    let onBack: () -> Void

    var body: some View {
        HStack {
            Button(action: onBack) {
                Image(systemName: "chevron.left").font(.body.medium())
                    .foregroundColor(Color(rgb: palette.text))
            }
            .accessibilityLabel(backLabel)
            Text(title).font(.title3).bold().foregroundColor(Color(rgb: palette.text))
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var palette: SdkThemeRules.Palette {
        SdkThemeRules.palette(
            sdk: NaraChat.shared.configValue?.style?.sdk,
            override: NaraChat.shared.themeOverride
        )
    }
}
