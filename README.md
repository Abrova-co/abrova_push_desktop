# Abrova Push for computers (Flutter)

Push notifications and in-app messages for Flutter apps on **macOS, Windows and Linux**, from the same
Abrova project and Console as your phone apps. No Firebase.

- Notifications that look native: Windows notifications, the Linux desktop's notifications, macOS
  Notification Center, with buttons and click handling
- In-app messages that appear as soon as you publish them in the Console
- Users and topics, silent pushes, localized titles
- Optional background mode, like a chat app: the app keeps running in the tray when its window is
  closed, and can start with the computer
- Pushes sent while the computer was off arrive when the app runs again

For Android, iOS and the web use [`abrova_push`](https://github.com/Abrova-co/abrova_push_flutter_sdk).

## Installation

The package is published on [Abrova Center](https://center.abrova.ir). Add it to your `pubspec.yaml`:

```yaml
dependencies:
  abrova_push_desktop:
    hosted: https://center.abrova.ir/api/packages/abrova/pub
    version: ^0.1.1
```

Requires Flutter 3.44 or newer.

**Windows:** to build, Visual Studio (or its Build Tools) needs the **Desktop development with C++**
workload and the **C++ ATL** component (Visual Studio Installer › Modify › Individual components).

**Linux:** your users need the desktop's notification service (standard on GNOME, KDE and most desktops).
For the tray icon, install `libayatana-appindicator3-1` (in your `.deb`, add it to `Depends`). To build:

```bash
sudo apt-get install libayatana-appindicator3-dev
```

**macOS:** allow outgoing connections in `macos/Runner/DebugProfile.entitlements` and
`Release.entitlements`:

```xml
<key>com.apple.security.network.client</key>
<true/>
```

## Quick start

```dart
import 'package:abrova_auth/abrova_auth.dart';
import 'package:abrova_push_desktop/abrova_push_desktop.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  await AbrovaAuth.initialize('YOUR_API_KEY');
  await AbrovaPushDesktop.init(AbrovaPushDesktopConfig(
    apiKey: 'YOUR_API_KEY', // Console › Project settings › API keys
    appIdentifier: 'com.example.app',
    tokenProvider: AbrovaAuth.instance.tokenProvider, // the signed-in user's token
  ));
  await AbrovaPushDesktop.register(userId: AbrovaAuth.instance.currentUser?.id);

  AbrovaPushDesktop.onMessage.listen((message) {
    print('${message.title}: ${message.body} ${message.data}');
  });
  AbrovaPushDesktop.onNotificationTapped.listen((message) {
    // Open the screen for message.deepLink or message.data
  });

  runApp(const MyApp());
}
```

Use your project's **API key**, the same one your phone apps use. Never put the server secret in an app:
it belongs on your server, which sends the pushes.

`register` is safe to call at every start: the computer keeps the same install id. Pass `userId` to send
pushes to a user on all their phones and computers at once.

### Signed user tokens

The API key in your app is public, so a user id alone does not prove who the user is. Give the SDK a
`tokenProvider`: the same Abrova user token, and the same function, you give Abrova Sync, Chat and the phone
Push SDK. With Abrova Auth that is `AbrovaAuth.instance.tokenProvider`; without it, a function that asks
**your server** (`https://auth.abrova.ir/users/token`). When the project requires signed user tokens,
registering with a `userId` or calling `setUserId` without one fails with `401 token_required`.

The SDK waits for the token before each request, asks again once if the server says it expired, and sends
the request without one if the provider fails or takes longer than 10 seconds. You can also set the provider
later with `AbrovaPushDesktop.setTokenProvider(...)`, or pass a token you fetched yourself with
`AbrovaPushDesktop.setUserToken(token)`.

```dart
// Revoked or invalid token, or the provider failed: send the user to sign in.
AbrovaPushDesktop.onAuthError((error) => print(error.code)); // token_required, token_invalid, ...
```

## Background mode (tray and start with the computer)

By default the app receives pushes while it runs. To keep receiving them when the user closes the window,
turn on background mode, as chat apps do:

```dart
await AbrovaPushDesktop.enableBackgroundMode(
  trayIconPath: Platform.isWindows ? 'assets/tray.ico' : 'assets/tray.png',
  keepRunningInTray: true,   // closing the window hides it to the tray
  launchAtStartup: true,     // start with the computer…
  startHidden: true,         // …in the tray, without opening the window
  openLabel: 'Open',
  quitLabel: 'Quit',
);
```

The tray menu opens the window or quits the app. When the app started at login in the tray,
`AbrovaPushDesktop.startedHidden(args)` is true (pass `main`'s `args`): call `AbrovaPushDesktop.hideWindow()` so the
window stays hidden (`showWindow()` brings it back). On macOS, `trayIconIsTemplate: true` makes a one-colour icon follow
the menu bar's light or dark look.

Give your users a setting for it, for example "Show notifications when the app is closed", and call
`AbrovaPushDesktop.setLaunchAtStartup(false)` when they turn it off.

**macOS:** an app quits when its last window closes unless its `AppDelegate` says otherwise. For background mode,
return `false` in `macos/Runner/AppDelegate.swift`, and bring the window back when the Dock icon is clicked:

```swift
override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
  return false
}

override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
  if !flag { sender.windows.first?.makeKeyAndOrderFront(self) }
  return true
}
```

When the app is fully quit, nothing runs on the computer: pushes wait on the server and arrive the next
time the app starts.

## Notifications

On macOS the SDK asks the user to allow notifications during `init` (once, without waiting for the
answer). To ask at a better moment, set `askNotificationPermission: false` and call
`AbrovaPushDesktop.requestNotificationPermission()` yourself. Windows and Linux need no permission.

```dart
final permission = await AbrovaPushDesktop.notificationPermission();
// allowed, notAllowed (macOS: ask, or point the user to System Settings › Notifications), notNeeded
```

Pushes still reach `onMessage` when notifications are not allowed.

| Option | Default | |
|---|---|---|
| `showNotifications` | `true` | Show a system notification for each push that is not silent |
| `showNotificationsWhileFocused` | `true` | Also when your window is in front (`onMessage` fires either way) |
| `askNotificationPermission` | `true` | macOS: ask to allow notifications during `init` |
| `appName` | the app's name | The name on notifications |
| `windowsAppUserModelId` | `appIdentifier` | Windows: the id notifications are grouped under |
| `windowsNotificationGuid` | from `appIdentifier` | Windows: keep it the same in every version of your app |

A click opens your window and fires `onNotificationTapped`; a button click carries the button's id.

### Notifications turned off

macOS asks the user once. If they say no, or later turn notifications off in System Settings, pushes still arrive
(`onMessage` fires) but no banner shows, and no app can switch them back on. The SDK tells you, so you can show a hint:

```dart
// macOS: the user turned notifications off (System Settings). The app can't turn them back on, so show a hint:
AbrovaPushDesktop.onNotificationPermissionChanged.listen((p) {
  if (p == AbrovaPushNotificationPermission.notAllowed) {
    // e.g. a bar: "Notifications are off" [Turn on] → opens this app's notification settings
    showNotificationsOffBar(onTurnOn: AbrovaPushDesktop.openNotificationSettings);
  }
});
```

`openNotificationSettings()` opens this app's page in System Settings › Notifications (macOS) or Settings ›
Notifications (Windows). Windows and Linux report `notNeeded`.

## In-app messages

Create them in the Console (Push › In-app). On computers they appear when the app opens, when a session
starts, or on your own event, with the same rules as on phones. When you publish or change one, running
apps show it within a minute.

```dart
final navigatorKey = GlobalKey<NavigatorState>(); // the one your MaterialApp uses

AbrovaPushDesktop.showInAppMessages(
  navigatorKey: navigatorKey,
  onButtonTap: (context, message, button) {
    // url buttons open in the browser by themselves; route deep links and handle custom values here
    if (button.action == 'deep_link') Navigator.of(context).pushNamed(button.value!);
  },
);

await AbrovaPushDesktop.triggerInAppEvent('opened_settings');
```

The SDK shows each message in your app's window and **in your app's language** (the Console's "Add language"): modal, banner (top or bottom), full screen or card, with the image, colours and up to two buttons from the Console, and records impressions, clicks and dismissals. Change the look with `theme: AbrovaPushInAppTheme(...)`, or draw a type yourself with `builders: AbrovaPushInAppBuilders(modal: ...)`.

To draw every message yourself instead, skip `showInAppMessages`, listen to `onInAppMessage`, pick the text with `message.contentFor(languageTag)` and call `recordInApp(message, 'button_click', buttonId: ...)` / `'dismiss'`.

On computers an app may run for days in the tray, so the SDK decides what "opening" means:

| Console trigger | Fires on a computer when |
|---|---|
| App open | the app starts, or its window comes back from the tray (also by a notification click) |
| Session start | the app starts, or the user comes back after `sessionTimeout` away (default 30 minutes: window hidden, minimised or behind other apps) |

Switching between windows alone is neither. `minSessionCount` counts these sessions.

## Users and topics

```dart
await AbrovaPushDesktop.setUserId('user-42');
await AbrovaPushDesktop.clearUserId();
await AbrovaPushDesktop.subscribeTopic('news');
await AbrovaPushDesktop.unsubscribeTopic('news');
```

## Connection state and errors

```dart
AbrovaPushDesktop.onConnectionState.listen((state) => print(state)); // connecting, connected, disconnected
AbrovaPushDesktop.onError.listen((error) => print(error));
```

The SDK reconnects by itself (with a growing wait between tries) and catches up on missed pushes.

Like the phone SDKs, it sends counts of its own errors with its next request (error numbers and short fixed
reasons only: never a message, user or device detail), so you and Abrova see them in the Console. Turn this
off with `sendDiagnostics: false`. Call
`AbrovaPushDesktop.reconnectNow()` to try at once, for example when your window comes to the front.

## Billing

Each computer that connects counts as one device, the same as a phone.

## License

MIT
