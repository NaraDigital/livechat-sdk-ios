# Changelog

All notable changes to the NaraChat Livechat SDK for iOS (`NaraLiveChat`).

## [1.0.1] — 2026-11-25

First public release, through CocoaPods and Swift Package Manager. Version aligned with the Android
SDK 1.0.1, with full feature parity.

### Added
- Public API: `configure(appKey:baseUrl:)`, `login(userId:email:name:userHash:)`, `setUser`, `logout`,
  `updateUser`, `present`, `presentMessages`, `presentHelp`, `presentArticle(slug:)`, `setDeviceToken`,
  `handlePush(userInfo:)`, `openChatFromPush`, `unreadCount` (`@Published`), `setLocale`,
  `themeOverride`, `initError`.
- Native SwiftUI screens: Home, Messages, Chat, Help center and articles, prechat form, and an
  "Update required" screen.
- Server-driven SDK style (language, mode, colours, greeting, logo), agent and AI profile photos.
- Identity rules identical to Android (verified users with `userHash`, `setUser`, anonymous chats).
- Realtime replies over `wss://<baseUrl>/sdk/v1/ws` with automatic reconnect, session renewal on
  `4401`, merge without duplicates, and polling while disconnected.
- Push (APNs) with token re-binding on login and logout.
- Init diagnostics through `initError` and the unified log (subsystem `id.nara.livechat`); the appKey
  and tokens are never logged in full.
- Lenient API decoding with the same defaults as Android: a missing or null field (e.g. `online`,
  `status`) no longer fails `configure` or a message list.
- Stable accessibility identifiers for UI tests: `nara.messages.thread`, `nara.chat.input`,
  `nara.chat.send`, `nara.chat.message.<from>`.
- iOS 15+.
