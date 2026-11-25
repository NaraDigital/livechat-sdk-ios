import Foundation

/// Maps SDK errors to human-friendly, locale-aware messages — parity with the Android
/// SDK's `friendlyError(code:isId:httpStatus:)`. Raw codes/bodies ("not_found",
/// "http_500 …", JSON) must never be shown to end users.
public func friendlyError(_ error: Error?, isId: Bool) -> String {
    switch error as? SdkError {
    case .network:
        return isId
            ? "Koneksi bermasalah. Periksa internet kamu lalu coba lagi."
            : "Connection problem. Check your internet and try again."
    case .notFound, .http(404, "route_not_found"):
        // route_not_found is the 404 a baseUrl without the /api prefix gets back.
        return isId
            ? "Chat tidak bisa dimuat. Coba lagi nanti."
            : "Couldn't load the chat. Please try again later."
    case .packageNotAllowed:
        return isId
            ? "Aplikasi ini belum diizinkan memakai live chat."
            : "This app isn't allowed to use live chat yet."
    case .visitorTokenInvalid:
        return isId
            ? "Sesi berakhir. Coba buka kembali chat-nya."
            : "Session expired. Please reopen the chat."
    case .validation:
        return isId
            ? "Data belum lengkap atau tidak valid. Periksa kembali lalu coba lagi."
            : "Some details are missing or invalid. Please check and try again."
    case .http(429, _), .http(_, "too_many_requests"):
        return isId
            ? "Terlalu banyak percobaan. Tunggu sebentar ya."
            : "Too many requests. Please wait a moment."
    case .http(401, _), .http(403, _):
        // Without a known code, 401/403 means the session was revoked server-side.
        return isId
            ? "Sesi kamu berakhir. Buka ulang chat."
            : "Your session ended. Please reopen the chat."
    case .prechatRequired, .http, nil:
        // prechat is handled by the form flow; http_*/unknown errors stay generic.
        return isId
            ? "Ada yang salah. Coba lagi nanti."
            : "Something went wrong. Please try again later."
    }
}

/// What the offline notice says: the widget's own title and text, or the standby lines when
/// `init` sent none or left them blank. Same lines as Android.
func offlineNotice(_ config: WidgetConfig, isId: Bool) -> (title: String, text: String) {
    func own(_ value: String?) -> String? {
        guard let value = value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    return (
        title: own(config.offline?.title) ?? (isId ? "Kami sedang tidak online" : "We are offline right now"),
        text: own(config.offline?.text)
            ?? (isId ? "Chat sedang tidak tersedia. Coba lagi nanti." : "Chat isn't available right now. Please try again later.")
    )
}
