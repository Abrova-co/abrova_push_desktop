# Changelog

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
