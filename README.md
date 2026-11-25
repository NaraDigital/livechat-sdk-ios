# NaraChat Livechat SDK — iOS

Native live-chat messenger for iOS apps (Swift + SwiftUI, iOS 15+). A fully native UI, not a WebView.
Full parity with the Android SDK (`../android`).

## Install

**CocoaPods:**
```ruby
pod 'NaraLiveChat', '~> 1.0'
```

**Swift Package Manager:** in Xcode, *File → Add Package Dependencies…*, enter
`https://github.com/NaraDigital/livechat-sdk-ios.git` and pick version `1.0.1` or later.

## Setup

```swift
// App init. The default baseUrl is https://api.nara.ai.id/api, so `configure(appKey:)` is enough there.
// Pass baseUrl only for another host (international market: https://api.narachat.com/api).
NaraChat.shared.configure(appKey: "nk_…", baseUrl: "https://api.narachat.com/api")

// The user signs in to your app → send their identity (compute userHash on YOUR backend):
// userHash = hex(HMAC-SHA256(identitySecret, userId))
NaraChat.shared.login(userId: uid, email: e, name: n, userHash: h)  // skips the form, history across devices

// Or without verification:
NaraChat.shared.setUser(name: n, email: e)   // skips the form, history per device

// Open the UI:
NaraChat.shared.present()                     // Home
NaraChat.shared.presentMessages()
NaraChat.shared.presentHelp()
NaraChat.shared.presentArticle(slug: "how-to-order")
```

### Identity and prechat rules (server-driven) — exactly as on Android

| Situation | Result |
|---|---|
| `login` with a valid name + email + userHash | Form skipped; verified; history across devices |
| `setUser` / `login` without a hash | Form skipped; per device |
| Partial data + required form | The form asks only for the missing fields; known ones are prefilled |
| No data + required form | The form must be filled (the server answers `428 prechat_required`) |
| No data + optional form | Straight to an anonymous chat |

### Push (APNs)

```swift
// AppDelegate / UIApplicationDelegateAdaptor
func application(_ application: UIApplication,
                 didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    let token = deviceToken.map { String(format: "%02x", $0) }.joined()
    NaraChat.shared.setDeviceToken(token)
}

// UNUserNotificationCenterDelegate
func userNotificationCenter(_ center: UNUserNotificationCenter,
                            didReceive response: UNNotificationResponse) async {
    if NaraChat.shared.handlePush(userInfo: response.notification.request.content.userInfo) {
        NaraChat.shared.openChatFromPush()
    }
}
```

The token is posted again automatically on `login` / `logout` (it is re-bound to the current visitor).

### More

- `NaraChat.shared.unreadCount` (`@Published`) — for your app badge.
- `setLocale("en" | "id")`, `themeOverride` — override the server config.
- Changes to the **SDK style** in the dashboard (language, mode, colours, greeting, logo) apply when
  the messenger opens or when the app returns to the foreground; while the messenger is in front,
  the config does not change by itself. If a reload fails (e.g. offline), the last good config stays.
- A message type the SDK does not know → fallback "Update the app to view this message".
- `sdk.minSupportedVersion` → an automatic "Update required" screen.
- `NaraChat.shared.initError` (`@Published`) — why the last init failed (status, API code, URL, hint);
  `nil` before it ran, while it runs, or after it succeeded.

### Base URL and when init fails

`baseUrl` is the **API address** and always ends with `/api` — the SDK calls `<baseUrl>/sdk/v1/…`
(not the web chat address).

| Market | Base URL |
|---|---|
| Indonesia (nara.ai.id) | `https://api.nara.ai.id/api` — default, no need to pass it |
| International (narachat.com) | `https://api.narachat.com/api` — pass it as `baseUrl` |
| Local API + simulator | `http://localhost:3000/api` (on a real device, replace `localhost` with the Mac's LAN IP) |

`configure` never throws when the connection fails — the UI still opens with default styling.
If the greeting or colours never change from the defaults, check `NaraChat.shared.initError` or the
Console (filter subsystem `id.nara.livechat`, category `NaraLiveChat`):

| Code | Meaning | Fix |
|---|---|---|
| `HTTP 404 · route_not_found` | `/sdk/v1` is unknown → `baseUrl` is not the API address | Make sure it ends with `/api` |
| `HTTP 404 · not_found` | Unknown appKey | Copy the appKey from the dashboard again |
| `HTTP 403 · sdk_package_not_allowed` | The app's bundle id is not allowed yet | Add it to the package list (dashboard → Mobile SDK) |
| `network_error` | The host cannot be reached | Check the internet connection and `baseUrl` |
| `HTTP 200 · bad_response` | Something other than the API answered (e.g. a web page): success status, but the body is not JSON | `baseUrl` must be the API address |

The log line looks like `init failed — POST <url> → HTTP <status> · <code> · appKey …<last 4 characters> · <hint>`.
The appKey and tokens are **never** printed in full.

### Realtime (AI and agent replies appear at once)

Replies arrive over the socket `wss://<baseUrl>/sdk/v1/ws?token=…` — the SDK route on the API host,
the same host as the HTTP `baseUrl`. The SDK opens, keeps and restores the socket itself; your app
does not need any code for it:

| Situation | What the SDK does |
|---|---|
| Disconnected / handshake refused | Reconnects automatically, backing off 1 → 2 → 4 … up to 30 s |
| Token expired (server closes with `4401`) | Renews the session, then opens the socket with the new token |
| Connected again | Fetches the latest messages and merges them — no duplicates |
| Not connected and the user just sent a message | Polls every 3 s (up to 30 s) until the reply arrives |
| App back in the foreground | Reopens the socket |
| While reconnecting | A small "Reconnecting…" text in the Chat header (not a dialog) |

While the socket is down, sending still works over HTTP, and replies still come in through polling.
An application ping (`{"type":"ping"}`) is sent every 25 s while connected.

If replies are late, check the Console (Xcode / Console.app, filter subsystem `id.nara.livechat`,
category `NaraLiveChat`). The socket only logs a status and the path, never the token:

```
socket handshake refused (HTTP 404) at /api/sdk/v1/ws — reconnect #1 in 1.0s
socket connection lost (URLError -1005) at /api/sdk/v1/ws — reconnect #1 in 1.0s
socket closed 4401 at /api/sdk/v1/ws — waiting for a new session, reconnect #1 in 1.0s
socket not opened: invalid_url
```

| Log line | Meaning | Fix |
|---|---|---|
| `handshake refused (HTTP 404) at /api/sdk/v1/ws` | The API has no SDK socket route | Point `baseUrl` at a NaraChat API that serves `GET /api/sdk/v1/ws` |
| `handshake refused (URLError -1011)` | The upgrade was refused; iOS usually does not report the HTTP status | Check the session token and the bundle id allowlist |
| `handshake refused (URLError -1004 / -1009)` | Host unreachable / offline | Check the internet connection and `baseUrl` |
| `socket not opened: invalid_url` | `baseUrl` is not a valid `http(s)` URL | Check the `baseUrl` format |
| `closed 4404` | This chat has no socket | The widget is not available — chat still works over HTTP |

iOS note: the SDK sends no protocol-level ping. A connection that dies silently (e.g. after a network
switch) is detected when the system reports an error or when the app returns to the foreground.

## Building

Building and testing need a Mac with Xcode:

```bash
cd ios
# The library imports UIKit, so tests run on a simulator (`swift test` on macOS does not work):
xcodebuild test -scheme NaraLiveChat -destination 'platform=iOS Simulator,name=iPhone 15'
open Package.swift            # open in Xcode → run the SampleApp target on an iOS Simulator
```

## License

Apache License 2.0 — see [LICENSE](LICENSE).
