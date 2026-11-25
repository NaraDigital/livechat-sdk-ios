import SwiftUI

// MARK: - Prechat form (spec screen 5)

struct PrechatFormScreen: View {
    @ObservedObject var model: MessengerModel
    let onDone: () -> Void

    @State private var name = NaraChat.shared.store.cachedName ?? ""
    @State private var email = NaraChat.shared.store.cachedEmail ?? ""
    @State private var submitting = false
    @State private var error: String?

    var isId: Bool { sdkIsId(locale: NaraChat.shared.locale, config: model.config) }

    private var palette: SdkThemeRules.Palette {
        SdkThemeRules.palette(sdk: model.config?.style?.sdk, override: NaraChat.shared.themeOverride)
    }

    /// Only the fields the server still requires are shown; supplied ones are pre-filled.
    var required: [String] {
        if !model.state.prechatMissingFields.isEmpty { return model.state.prechatMissingFields }
        guard let r = model.config?.settings?.prechat, r.enabled == true else { return [] }
        var f: [String] = []
        if r.requireName == true { f.append("name") }
        if r.requireEmail == true { f.append("email") }
        return f
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer().frame(height: 32)
            Text(isId ? "Sebelum mulai" : "Before we start").font(.title).bold()
            Text(isId ? "Isi data berikut agar tim bisa membalas kamu." : "Tell us a little about you so we can help.")
                .font(.subheadline).foregroundColor(.secondary)

            if required.contains("name") {
                TextField(isId ? "Nama" : "Name", text: $name)
                    .textFieldStyle(.roundedBorder)
            }
            if required.contains("email") {
                TextField("Email", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            if let error {
                Text(error).font(.caption).foregroundColor(.red)
            }

            Button {
                let cleanName = IdentityRules.sanitizeName(name)
                let cleanEmail = IdentityRules.sanitizeEmail(email)
                if required.contains("name"), cleanName == nil {
                    error = isId ? "Nama wajib diisi" : "Name is required"
                    return
                }
                if required.contains("email"), cleanEmail == nil {
                    error = isId ? "Email tidak valid" : "Enter a valid email"
                    return
                }
                submitting = true
                Task {
                    await SessionManager.shared.submitPrechat(name: cleanName ?? "", email: cleanEmail)
                    submitting = false
                    onDone()
                }
            } label: {
                // Ink, the main action color of every SDK screen.
                Text(submitting ? (isId ? "Mengirim…" : "Submitting…") : (isId ? "Mulai chat" : "Start chat"))
                    .font(.body.medium())
                    .foregroundColor(Color(rgb: palette.onPrimary))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(rgb: palette.primary).opacity(submitting ? 0.5 : 1))
                    )
            }
            .buttonStyle(.plain)
            .disabled(submitting)

            Spacer()
        }
        .padding(24)
        .onAppear {
            if required.isEmpty { onDone() }
        }
    }
}

// MARK: - Help (spec screen 4)

struct HelpScreen: View {
    let onBack: () -> Void
    let onArticle: (String) -> Void

    @State private var query = ""
    @State private var overview: HelpOverview?
    @State private var searchTask: Task<Void, Never>?
    @State private var expandedFaq: String?
    @ObservedObject private var nara = NaraChat.shared

    var isId: Bool { sdkIsId(locale: nara.locale, config: nara.configValue) }

    var body: some View {
        VStack(spacing: 0) {
            NaraBackHeader(title: isId ? "Pusat Bantuan" : "Help Center",
                           backLabel: isId ? "Kembali" : "Back", onBack: onBack)
            TextField(isId ? "Cari artikel…" : "Search articles…", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 20)
                .onChange(of: query) { q in
                    searchTask?.cancel()
                    searchTask = Task {
                        try? await Task.sleep(nanoseconds: 300_000_000) // debounce
                        guard !Task.isCancelled, let key = NaraChat.shared.appKey else { return }
                        overview = try? await NaraChat.shared.api.helpSearch(appKey: key, query: q)
                    }
                }
            List {
                if let o = overview {
                    if query.isEmpty, let cats = o.categories, !cats.isEmpty {
                        Section(isId ? "Kategori" : "Categories") {
                            ForEach(cats) { c in
                                Text(c.name)
                            }
                        }
                    }
                    if let faqs = o.faqs, !faqs.isEmpty {
                        Section("FAQ") {
                            ForEach(faqs) { f in
                                VStack(alignment: .leading, spacing: 4) {
                                    Button {
                                        withAnimation { expandedFaq = expandedFaq == f.id ? nil : f.id }
                                    } label: {
                                        Text(f.question).font(.body.medium()).foregroundColor(.primary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    if expandedFaq == f.id {
                                        Text(f.answer).font(.caption).foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    if let articles = o.articles, !articles.isEmpty {
                        Section(isId ? "Artikel" : "Articles") {
                            ForEach(articles) { a in
                                Button { onArticle(a.slug) } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(a.title).foregroundColor(.primary)
                                        if let s = a.snippet {
                                            Text(s).font(.caption).foregroundColor(.secondary).lineLimit(2)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
        .task {
            if let key = NaraChat.shared.appKey {
                overview = try? await NaraChat.shared.api.helpOverview(appKey: key)
            }
        }
    }
}

// MARK: - Article (safe HTML render)

struct ArticleScreen: View {
    let slug: String
    let onBack: () -> Void

    @State private var article: HelpArticle?
    @State private var failed = false
    @ObservedObject private var nara = NaraChat.shared

    var isId: Bool { sdkIsId(locale: nara.locale, config: nara.configValue) }

    private var palette: SdkThemeRules.Palette {
        SdkThemeRules.palette(sdk: nara.configValue?.style?.sdk, override: nara.themeOverride)
    }

    var body: some View {
        VStack(spacing: 0) {
            NaraBackHeader(title: article?.title ?? "",
                           backLabel: isId ? "Kembali" : "Back", onBack: onBack)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let article {
                        ForEach(Array(SafeHtmlParser.parse(article.html).enumerated()), id: \.offset) { _, block in
                            switch block.tag {
                            case "h1", "h2":
                                Text(block.text).font(.title3).bold().padding(.vertical, 4)
                            case "h3", "h4", "h5", "h6":
                                Text(block.text).font(.body).bold().padding(.vertical, 2)
                            case "li":
                                Text("•  " + block.text).font(.subheadline).padding(.leading, 8)
                            case "a":
                                Text(block.text + (block.href.map { " (\($0))" } ?? ""))
                                    .font(.subheadline).foregroundColor(Color(rgb: palette.primary))
                            default:
                                Text(block.text).font(.subheadline)
                            }
                        }
                    } else if failed {
                        Text(isId ? "Artikel tidak ditemukan." : "Article not found.").foregroundColor(.red)
                    } else {
                        // View.tint needs iOS 16, so the spinner takes its color this way.
                        ProgressView().accentColor(Color(rgb: palette.primary))
                            .frame(maxWidth: .infinity).padding(.top, 40)
                    }
                }
                .padding(20)
            }
        }
        .task {
            guard let key = NaraChat.shared.appKey else { return }
            do {
                article = try await NaraChat.shared.api.helpArticle(appKey: key, slug: slug)
            } catch {
                failed = true
            }
        }
    }
}
