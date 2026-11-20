import 'dart:async';

/// Returns the Abrova user token for the signed-in user, or null when no one
/// is signed in. With Abrova Auth: `AbrovaAuth.instance.tokenProvider`.
/// The same function you pass to Abrova Sync and the phone Push SDK.
typedef AbrovaPushDesktopTokenProvider = FutureOr<String?> Function();

/// Settings for [AbrovaPushDesktop.init].
class AbrovaPushDesktopConfig {
  const AbrovaPushDesktopConfig({
    required this.apiKey,
    this.tokenProvider,
    this.appName,
    this.appIdentifier,
    this.windowsAppUserModelId,
    this.windowsNotificationGuid,
    this.showNotifications = true,
    this.showNotificationsWhileFocused = true,
    this.askNotificationPermission = true,
    this.apiUrl = defaultApiUrl,
    this.debug = false,
    this.sendDiagnostics = true,
  });

  static const String defaultApiUrl = 'https://push-api.abrova.ir';

  /// Your project's API key from the Console (the same key your phone apps use).
  /// Never put the server secret in an app.
  final String apiKey;

  /// Gives the signed-in user's Abrova user token, which proves who the user
  /// is. Pass it whenever your app has users: registering with a `userId` or
  /// calling [AbrovaPushDesktop.setUserId] needs it (the server answers 401
  /// `token_required` without it). The SDK waits for it before each request,
  /// as the phone SDKs do, and asks again once when the server says it expired.
  /// Null (no one signed in) sends the request without a user token.
  final AbrovaPushDesktopTokenProvider? tokenProvider;

  /// The name shown on notifications. Defaults to the app's name.
  final String? appName;

  /// The app's id, e.g. `com.example.app`. Defaults to the bundle id on macOS and
  /// the app name on Windows and Linux. Phones and computers of one project may
  /// use the same id.
  final String? appIdentifier;

  /// Windows only: the AppUserModelID notifications are shown under, e.g.
  /// `Example.App`. Defaults to [appIdentifier].
  final String? windowsAppUserModelId;

  /// Windows only: a fixed GUID for this app's notifications (keep it the same in
  /// every version). Defaults to one derived from [appIdentifier].
  final String? windowsNotificationGuid;

  /// Show a system notification for each push that is not silent.
  final bool showNotifications;

  /// Also when the app's window is in front. When false, [AbrovaPushDesktop.onMessage]
  /// still fires.
  final bool showNotificationsWhileFocused;

  /// macOS: ask the user to allow notifications during [AbrovaPushDesktop.init]
  /// (once; the SDK does not wait for the answer). Turn off to ask yourself later
  /// with [AbrovaPushDesktop.requestNotificationPermission]. Windows and Linux
  /// need no permission.
  final bool askNotificationPermission;

  /// Only change this if Abrova support asks you to.
  final String apiUrl;

  /// Print what the SDK does (never keys or tokens).
  final bool debug;

  /// Send the SDK's own error counts with its requests (the same report the
  /// phone SDKs send; counts and fixed reason words only, never a message,
  /// user or device detail). False: nothing is counted, kept or sent.
  final bool sendDiagnostics;
}
