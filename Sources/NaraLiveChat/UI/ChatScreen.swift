import SwiftUI
import PhotosUI

// MARK: - Chat (spec screen 3)

struct ChatScreen: View {
    @ObservedObject var model: MessengerModel
    let onBack: () -> Void
    let onNeedPrechat: () -> Void

    @State private var input = ""
    @State private var replyingTo: ChatMessage?
    @State private var pickerShown = false

    var isId: Bool { sdkIsId(locale: NaraChat.shared.locale, config: model.config) }
    var palette: BubblePalette { .from(model.config, palette: theme) }

    /// SDK style palette — the page background, the main text color and the ink primary.
    private var theme: SdkThemeRules.Palette {
        SdkThemeRules.palette(sdk: model.config?.style?.sdk, override: NaraChat.shared.themeOverride)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            messageList
            if model.state.prechatMissingFields.isEmpty {
                quickReplies
                errorBanner
                replyStrip
                composer
            }
        }
        .onChange(of: model.state.prechatMissingFields) { fields in
            if !fields.isEmpty { onNeedPrechat() }
        }
        .sheet(isPresented: $pickerShown) {
            PhotoPicker { url, mime in
                guard let url else { return }
                Task { await SessionManager.shared.upload(fileURL: url, mime: mime ?? "application/octet-stream", caption: nil) }
            }
        }
    }

    /// Header: the page background with the main text color. The accent belongs to the
    /// Home hero only.
    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "chevron.left").font(.body.medium())
                    .foregroundColor(Color(rgb: theme.text))
            }
            .accessibilityLabel(isId ? "Kembali" : "Back")
            VStack(alignment: .leading, spacing: 2) {
                Text(handlerTitle).font(.headline).bold()
                    .foregroundColor(Color(rgb: theme.text))
                if model.state.typing {
                    Text((model.state.typingName ?? "") + (isId ? " sedang mengetik…" : " is typing…"))
                        .font(.caption).foregroundColor(Color(rgb: theme.text).opacity(0.75))
                } else if model.reconnecting {
                    Text(isId ? "Menyambungkan ulang…" : "Reconnecting…").font(.caption)
                        .foregroundColor(Color(rgb: theme.text).opacity(0.75))
                } else if model.state.handler?.type == "ai" {
                    Text(isId ? "Dilayani AI" : "Handled by AI").font(.caption)
                        .foregroundColor(Color(rgb: theme.text).opacity(0.75))
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color(rgb: theme.background))
    }

    private var handlerTitle: String {
        if let h = model.state.handler, h.type != "none", let n = h.name, !n.isEmpty { return n }
        if let t = model.config?.style?.header?.title, !t.isEmpty { return t }
        return model.config?.name ?? "Chat"
    }

    /// The sender's photo, beside the first bubble of a run from one sender — and only when there is one.
    private func photoBeside(_ m: ChatMessage, at index: Int) -> ThreadAvatar? {
        guard ThreadAvatarRules.opensSenderRun(model.state.messages, index),
              let url = ThreadAvatarRules.messagePhoto(m, handler: model.state.handler, aiAvatarUrl: model.config?.aiAgent?.avatarUrl)
        else { return nil }
        var avatar = ThreadAvatarRules.avatar(
            messages: [m], widgetName: model.config?.name, headerTitle: model.config?.style?.header?.title,
            fallbackTitle: isId ? "Obrolan" : "Conversation"
        )
        avatar.photoUrl = url
        return avatar
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    if model.state.hasMore {
                        Button(isId ? "Muat pesan lebih awal" : "Load earlier messages") {
                            Task { _ = await SessionManager.shared.loadMore() }
                        }
                        .font(.caption)
                        .foregroundColor(Color(rgb: theme.primary))
                    }
                    ForEach(Array(model.state.messages.enumerated()), id: \.element.id) { index, m in
                        MessageBubble(m: m, photo: photoBeside(m, at: index), palette: palette, theme: theme, isId: isId)
                            .id(m.id)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("nara.chat.message.\(m.from)")
                            .onLongPressGesture { replyingTo = m }
                    }
                    if model.state.typing {
                        TypingIndicator(band: Color(rgb: theme.band))
                    }
                }
                .padding(.horizontal, 16)
            }
            .onChange(of: model.state.messages.count) { _ in
                if let last = model.state.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    Task { await SessionManager.shared.markRead(upToMessageId: last.id) }
                }
            }
        }
    }

    @ViewBuilder
    private var quickReplies: some View {
        let qrs = model.config?.settings?.quickReplies ?? []
        if model.state.messages.first(where: { $0.isMine }) == nil, !qrs.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(qrs.prefix(3), id: \.self) { qr in
                        Button(qr) {
                            Task { await SessionManager.shared.send(qr) }
                        }
                        .font(.caption)
                        .foregroundColor(Color(rgb: theme.text))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Color(rgb: theme.band)).cornerRadius(18)
                    }
                }
                .padding(.horizontal, 12)
            }
        }
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let err = model.state.error {
            Text(err).font(.caption).foregroundColor(.red).padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private var replyStrip: some View {
        if let r = replyingTo {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text((isId ? "Membalas " : "Replying to ") + r.senderName).font(.caption2)
                        .foregroundColor(palette.ink)
                    Text(r.displayBody(isId: isId)).font(.caption).lineLimit(1)
                }
                Spacer()
                Button { replyingTo = nil } label: { Image(systemName: "xmark") }
                    .accessibilityLabel(isId ? "Batalkan balasan" : "Cancel reply")
            }
            .padding(12)
            .background(Color(rgb: theme.band))
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if model.config?.settings?.allowImages != false {
                Button { pickerShown = true } label: {
                    Image(systemName: "plus").foregroundColor(Color(rgb: theme.text))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(isId ? "Lampirkan" : "Attach")
            }
            TextField(isId ? "Tulis pesan…" : "Write a message…", text: $input)
                .padding(10)
                .background(Color(rgb: theme.band))
                .cornerRadius(22)
                .accessibilityIdentifier("nara.chat.input")
            Button {
                let text = input
                input = ""
                Task {
                    await SessionManager.shared.send(text)
                    replyingTo = nil
                }
            } label: {
                Image(systemName: "paperplane.fill")
                    .foregroundColor(input.isBlank ? Color(rgb: theme.text).opacity(0.35) : Color(rgb: theme.primary))
            }
            .disabled(input.isBlank)
            .accessibilityLabel(isId ? "Kirim" : "Send")
            .accessibilityIdentifier("nara.chat.send")
        }
        .padding(10)
    }
}

private extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

struct MessageBubble: View {
    let m: ChatMessage
    /// Shown beside the bubble when the sender has a photo and this bubble opens its run.
    let photo: ThreadAvatar?
    let palette: BubblePalette
    let theme: SdkThemeRules.Palette
    let isId: Bool

    /// The message text in the current UI language.
    private var text: String { m.displayBody(isId: isId) }

    var body: some View {
        if m.isSystem {
            Text(text)
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
                .padding(.vertical, 4)
        } else {
            HStack {
                if m.isMine { Spacer(minLength: 40) }
                HStack(alignment: .top, spacing: 8) {
                    if let photo {
                        AvatarCircle(avatar: photo, size: 24, font: .system(size: 11, weight: .semibold), palette: theme)
                    }
                    VStack(alignment: m.isMine ? .trailing : .leading, spacing: 3) {
                        bubbleContent
                        HStack(spacing: 4) {
                            if m.isMine { statusIcon }
                            Text(metaText).font(.caption2).foregroundColor(.secondary)
                        }
                    }
                }
                if !m.isMine { Spacer(minLength: 40) }
            }
        }
    }

    @ViewBuilder
    private var bubbleContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let q = m.quoted {
                VStack(alignment: .leading, spacing: 2) {
                    Text(q.senderName ?? "").font(.caption2).bold()
                    Text(q.body ?? "").font(.caption).lineLimit(2)
                }
                .padding(6)
                .background((m.isMine ? palette.agent : palette.visitor).opacity(0.15))
                .cornerRadius(6)
            }
            switch m.type {
            case "image":
                if let media = m.media {
                    AsyncImageView(url: media.url, spinnerTint: palette.ink)
                        .frame(maxWidth: .infinity, maxHeight: 180)
                        .cornerRadius(10)
                } else {
                    Text(text).foregroundColor(m.isMine ? palette.visitorText : palette.agentText)
                }
            case "document":
                HStack(spacing: 6) {
                    Image(systemName: "doc.fill")
                    Text(text.isEmpty ? URL(string: m.media?.url ?? "")?.lastPathComponent ?? "file" : text)
                }
                .foregroundColor(m.isMine ? palette.visitorText : palette.agentText)
            default:
                Text(text)
                    .foregroundColor(m.isMine ? palette.visitorText : palette.agentText)
            }
        }
        .padding(10)
        .background(m.isMine ? palette.visitor : palette.agent)
        .cornerRadius(16)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch m.status {
        case "pending": Image(systemName: "clock").font(.caption2).foregroundColor(.secondary)
        case "failed": Image(systemName: "exclamationmark.circle").font(.caption2).foregroundColor(.red)
        case "read": Image(systemName: "checkmark").font(.caption2).foregroundColor(palette.ink)
        case "sent", "delivered", "received": Image(systemName: "checkmark").font(.caption2).foregroundColor(.secondary)
        default: EmptyView()
        }
    }

    private var metaText: String {
        let name = (!m.isMine && !m.senderName.isEmpty) ? m.senderName + " · " : ""
        return name + Self.time(m.sentAt)
    }

    static func time(_ iso: String) -> String {
        // The API sends fractional seconds ("…T10:00:00.000Z"), which the plain
        // .withInternetDateTime format rejects — try both.
        let formatter = ISO8601DateFormatter()
        let withFractions = ISO8601DateFormatter()
        withFractions.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let d = formatter.date(from: iso) ?? withFractions.date(from: iso) else { return "" }
        let out = DateFormatter()
        out.timeStyle = .short
        return out.string(from: d)
    }
}

struct TypingIndicator: View {
    let band: Color

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle().fill(Color.secondary.opacity(0.6)).frame(width: 8, height: 8)
            }
        }
        .padding(12)
        .background(band)
        .cornerRadius(16)
    }
}

struct AsyncImageView: View {
    let url: String
    /// Color of the loading spinner: the ink primary, like every SDK action.
    let spinnerTint: Color
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(Color(.systemGray5))
                    // View.tint needs iOS 16, so the spinner takes its color this way.
                    .overlay { ProgressView().accentColor(spinnerTint) }
            }
        }
        .task {
            guard let u = URL(string: url) else { return }
            // Async fetch — Data(contentsOf:) here would block the main thread.
            if let (data, _) = try? await URLSession.shared.data(from: u), let img = UIImage(data: data) {
                image = img
            }
        }
    }
}

/// PHPicker wrapper — images from the photo library (spec: kamera/galeri/dokumen;
/// file/document picking rides the same upload path via `SessionManager.upload`).
struct PhotoPicker: UIViewControllerRepresentable {
    let onPick: (URL?, String?) -> Void
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ vc: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: (URL?, String?) -> Void
        init(onPick: @escaping (URL?, String?) -> Void) { self.onPick = onPick }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let provider = results.first?.itemProvider, provider.hasItemConformingToTypeIdentifier("public.image") else {
                onPick(nil, nil)
                return
            }
            provider.loadFileRepresentation(forTypeIdentifier: "public.image") { url, _ in
                // Copy to a stable temp file — the provider URL is deleted on return.
                guard let url else {
                    DispatchQueue.main.async { self.onPick(nil, nil) }
                    return
                }
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
                try? FileManager.default.copyItem(at: url, to: tmp)
                DispatchQueue.main.async { self.onPick(tmp, "image/jpeg") }
            }
        }
    }
}
