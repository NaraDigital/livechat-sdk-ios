import SwiftUI
import NaraLiveChat

/// Sample host app — `open sdk/ios/SampleApp/NaraSampleApp.xcodeproj`, scheme SampleApp, or
/// copy this folder into an Xcode project. Exercises the public API the way a customer app would.
/// The simulator reaches the dev API at `http://localhost:3000/api`.
@main
struct NaraSampleApp: App {
    var body: some Scene {
        WindowGroup { SampleScreen() }
    }
}

struct SampleScreen: View {
    @ObservedObject private var nara = NaraChat.shared
    // The UI smoke test (`SampleAppUITests`) hands both in through the launch environment.
    @State private var appKey = ProcessInfo.processInfo.environment["NARA_APP_KEY"] ?? "nk_"
    @State private var baseUrl = ProcessInfo.processInfo.environment["NARA_BASE_URL"] ?? "http://localhost:3000/api"
    @State private var name = ""
    @State private var email = ""
    @State private var userId = ""
    @State private var userHash = ""
    @State private var message: String?

    /// An empty field means "use the SDK default" (`https://api.nara.ai.id/api`).
    private var initUrl: String {
        let trimmed = baseUrl.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? NaraChat.defaultBaseUrl : trimmed
    }

    var body: some View {
        NavigationView {
            Form {
                Section("Widget") {
                    TextField("appKey (nk_…)", text: $appKey)
                    TextField("Base URL (API, diakhiri /api)", text: $baseUrl)
                        .keyboardType(.URL).autocapitalization(.none).autocorrectionDisabled()
                    Button("Init + open") {
                        nara.configure(appKey: appKey, baseUrl: initUrl)
                        nara.present()
                    }
                    Button("Tes koneksi") {
                        nara.configure(appKey: appKey, baseUrl: initUrl)
                    }
                    InitStatus(error: nara.initError, config: nara.configValue)
                    Button("Anonymous chat") {
                        nara.configure(appKey: appKey, baseUrl: initUrl)
                        nara.presentMessages()
                    }
                    .accessibilityIdentifier("sample.anonymousChat")
                }
                Section("setUser — skip form, per-device history") {
                    TextField("name", text: $name)
                    TextField("email", text: $email)
                    Button("setUser") {
                        nara.setUser(name: name, email: email)
                        nara.presentMessages()
                    }
                }
                Section("login — verified, cross-device history") {
                    TextField("userId", text: $userId)
                    TextField("userHash (HMAC from your backend)", text: $userHash)
                    Button("login") {
                        nara.login(userId: userId, email: email, name: name, userHash: userHash)
                        nara.presentMessages()
                    }
                }
                if let message {
                    Section { Text(message).foregroundColor(.red) }
                }
            }
            .navigationTitle("NaraChat SDK")
        }
    }
}

/// Result of the last init — the same facts the console shows under `NaraLiveChat`, in the UI.
private struct InitStatus: View {
    let error: SdkInitError?
    let config: WidgetConfig?

    var body: some View {
        if let error {
            VStack(alignment: .leading, spacing: 4) {
                Text("Init gagal — \(error.summary)").foregroundColor(.red)
                Text("POST \(error.url)").font(.caption)
                if let hint = error.hint {
                    Text(hint).font(.caption).foregroundColor(.red)
                }
            }
        } else if config == nil {
            Text("Menunggu respons init…").font(.caption)
        } else {
            Text("Init OK — \(config?.name ?? "")").font(.caption)
        }
    }
}
