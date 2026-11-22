# Changelog

## [0.1.3] - 2026-11-22
### Fixed
- macOS: with `showNotificationsWhileFocused: false`, a push now shows a notification when the window is closed to
  the tray (background mode). The hidden window counted as "in front" and the notification was skipped.
- An in-app message that two triggers picked at almost the same time (for example "Session start" and "App open")
  showed twice, stacked, with a darker page behind it, and its close button did nothing. It now shows once and closes.

## [0.1.2] - 2026-11-22
### Added
- macOS: the SDK tells Abrova when notifications are turned off or on, so the Console shows the computer as
  "Notifications off" and says why its messages were not seen. Windows and Linux report nothing (no such setting).

## [0.1.1] - 2026-11-21

### Added
- Built-in in-app display: `showInAppMessages(navigatorKey: …)` shows modal, banner (top or bottom), full screen and
  card messages in your app's window, with the image, colours and buttons from the Console, and records impressions,
  clicks and dismissals. `theme` and `builders` change the look or replace a type.
- In-app messages follow your app's language (the Console's "Add language"): `message.contentFor(languageTag)`.
- `onInAppButton`: which button of an in-app message was pressed, with its value (`custom`, `deep_link`).
- Sessions for apps that stay in the tray: "App open" also fires when the window comes back from the tray, and a new
  session (and "Session start") begins when the user returns after `sessionTimeout` (default 30 minutes).

### Fixed
- A second copy of the app on one computer still shows the in-app messages (it stays off the live connection).

## [0.1.0] - 2026-11-20

First release: Abrova Push for Flutter apps on macOS, Windows and Linux.

### Added
- Register a computer with your project (the same API key as your phone apps) and keep it connected; it
  reconnects by itself and gets the pushes it missed while it was offline.
- System notifications: Windows notifications, the Linux desktop's notifications and macOS Notification
  Center, with buttons, localized titles and click handling (`onNotificationTapped`).
- `onMessage` for every push, silent pushes included; each push is shown once, even if it arrives twice.
- In-app messages, shown at once when you change them in the Console, with the same triggers as on phones.
- Users and topics: `setUserId`, `clearUserId`, `subscribeTopic`, `unsubscribeTopic`.
- Signed user tokens, as in the phone SDKs: `tokenProvider` (with Abrova Auth:
  `AbrovaAuth.instance.tokenProvider`), `setTokenProvider`, `setUserToken` and `onAuthError`. The SDK waits for the
  token before each request and asks again once when it expired.
- Error counts sent with the next request, as the phone SDKs do (numbers and fixed reasons only); off with
  `sendDiagnostics: false`.
- Optional background mode: keep running in the tray when the window is closed, and start with the computer.
- macOS: asks to allow notifications during `init` (`askNotificationPermission`); `notificationPermission()`;
  `onNotificationPermissionChanged` when the user turns them off or on; `openNotificationSettings()` opens the system's
  notification settings for the app (macOS and Windows).
- The app opened twice on one computer: only the first copy connects, so the two never replace each other.
- Works beside packages built on `win32` 6 (for example a recent `file_picker`).
