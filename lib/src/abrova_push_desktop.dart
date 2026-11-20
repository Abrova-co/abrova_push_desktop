import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'api.dart';
import 'auth_error.dart';
import 'background.dart';
import 'config.dart';
import 'connection.dart';
import 'diagnostics.dart';
import 'in_app.dart';
import 'message.dart';
import 'notifications.dart';
import 'store.dart';
import 'version.dart';

/// Abrova Push for Flutter apps on macOS, Windows and Linux.
///
/// ```dart
/// await AbrovaPushDesktop.init(const AbrovaPushDesktopConfig(apiKey: 'YOUR_API_KEY'));
/// await AbrovaPushDesktop.register(userId: 'user-42');
/// AbrovaPushDesktop.onMessage.listen((m) => print(m.title));
/// ```
class AbrovaPushDesktop {
  AbrovaPushDesktop._();

  static AbrovaPushDesktopConfig? _config;
  static PushApi? _api;
  static SdkDiagnostics? _diagnostics;
  static DesktopPushStore? _store;
  static DesktopNotifications? _notifications;
  static PushConnection? _connection;
  static String _appIdentifier = '';
  static String _appName = '';
  static int _sessionCount = 0;

  static List<Map<String, dynamic>> _inApp = const [];
  static String? _inAppEtag;
  static final Set<String> _inAppShown = {};
  static Timer? _signalTimer;

  static final _messages = StreamController<AbrovaPushMessage>.broadcast();
  static final _taps = StreamController<AbrovaPushMessage>.broadcast();
  static final _state = StreamController<AbrovaPushConnectionState>.broadcast();
  static final _inAppReady = StreamController<AbrovaPushInAppMessage>.broadcast();
  static final _errors = StreamController<Object>.broadcast();
  static final _permission = StreamController<AbrovaPushNotificationPermission>.broadcast();
  static AbrovaPushNotificationPermission? _lastPermission;
  static AppLifecycleListener? _lifecycle;
  static AbrovaPushConnectionState _current = AbrovaPushConnectionState.disconnected;

  /// Every push this computer receives (silent ones too).
  static Stream<AbrovaPushMessage> get onMessage => _messages.stream;

  /// A notification (or one of its buttons) was clicked.
  static Stream<AbrovaPushMessage> get onNotificationTapped => _taps.stream;

  /// The live connection's state.
  static Stream<AbrovaPushConnectionState> get onConnectionState => _state.stream;
  static AbrovaPushConnectionState get connectionState => _current;

  /// An in-app message to show now.
  static Stream<AbrovaPushInAppMessage> get onInAppMessage => _inAppReady.stream;

  /// The notification permission changed (checked at [init] and whenever the app
  /// comes back to the front): for example the user turned notifications off in
  /// System Settings. Show your own "notifications are off" hint with a button
  /// that calls [openNotificationSettings]. macOS only; Windows and Linux report
  /// [AbrovaPushNotificationPermission.notNeeded].
  static Stream<AbrovaPushNotificationPermission> get onNotificationPermissionChanged => _permission.stream;

  /// Errors the SDK handled (it keeps retrying); for your logs.
  static Stream<Object> get onError => _errors.stream;

  /// This install's id, after [register].
  static String? get deviceId => _connection?.registration.deviceId ?? _store?.get<String>('deviceId');

  static bool get isSupported => !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

  static void _log(String line) {
    if (_config?.debug == true) debugPrint('AbrovaPush: $line');
  }

  /// Counts [e] for the SDK report under [code].
  static void _count(int code, Object e) =>
      _diagnostics?.count(code, reason: e is PushApiException ? e.reason : SdkDiagnostics.reasonOf(e));

  static void _error(Object e) {
    _log('$e');
    if (!_errors.isClosed) _errors.add(e);
  }

  /// Call once at start, before [register].
  static Future<void> init(AbrovaPushDesktopConfig config) async {
    if (!isSupported) throw UnsupportedError('AbrovaPushDesktop runs on macOS, Windows and Linux');
    _config = config;
    _store = await DesktopPushStore.open();
    _diagnostics = SdkDiagnostics(store: _store, enabled: config.sendDiagnostics);
    _api = PushApi(
      baseUrl: config.apiUrl,
      apiKey: config.apiKey,
      tokenProvider: _providerSet ? _pendingProvider : config.tokenProvider,
      diagnostics: _diagnostics,
    )
      ..userToken = _pendingToken
      ..onAuthError = (e) {
        _log('auth error ${e.code}');
        _onAuthError?.call(e);
      };
    final info = await PackageInfo.fromPlatform();
    _appIdentifier = (config.appIdentifier?.trim().isNotEmpty ?? false)
        ? config.appIdentifier!.trim()
        : (info.packageName.isNotEmpty ? info.packageName : info.appName);
    _appName = config.appName ?? (info.appName.isNotEmpty ? info.appName : _appIdentifier);
    _sessionCount = (_store!.get<num>('sessions')?.toInt() ?? 0) + 1;
    await _store!.set('sessions', _sessionCount);
    if (config.showNotifications) {
      _notifications = DesktopNotifications(
        appName: _appName,
        appIdentifier: _appIdentifier,
        windowsAumid: config.windowsAppUserModelId,
        windowsGuid: config.windowsNotificationGuid,
      );
      await _notifications!.init(_onTap);
      if (Platform.isMacOS && config.askNotificationPermission) {
        // Not awaited: the user may answer later; pushes still arrive meanwhile.
        unawaited(_notifications!.requestPermission().catchError((_) => false).then((_) => _checkPermission()));
      }
      final launch = await _notifications!.launchPayload();
      if (launch != null) scheduleMicrotask(() => _onTap(launch, null));
    }
    _log('init $abrovaPushDesktopVersion for $_appIdentifier');
    if (Platform.isMacOS && config.showNotifications) {
      // With askNotificationPermission, the first check runs once the user answered (above).
      if (!config.askNotificationPermission) unawaited(_checkPermission());
      _lifecycle ??= AppLifecycleListener(onResume: () => unawaited(_checkPermission()));
    }
  }

  static Future<void> _checkPermission() async {
    try {
      final now = await notificationPermission();
      if (now == _lastPermission) return;
      _lastPermission = now;
      if (!_permission.isClosed) _permission.add(now);
    } catch (_) {}
  }

  /// Opens the system's notification settings for this app, where the user can
  /// turn notifications back on (an app can't do it itself, and macOS asks only
  /// once). macOS: this app's page in System Settings › Notifications. Windows:
  /// Settings › System › Notifications. Linux: returns false (no standard place).
  static Future<bool> openNotificationSettings() async {
    try {
      if (Platform.isMacOS) {
        final id = Uri.encodeComponent(_appIdentifier);
        final r = await Process.run('open', ['x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=$id']);
        return r.exitCode == 0;
      }
      if (Platform.isWindows) {
        await Process.start('explorer.exe', ['ms-settings:notifications'], mode: ProcessStartMode.detached);
        return true;
      }
    } catch (e) {
      _error(e);
    }
    return false;
  }

  /// Whether notifications may be shown now (see [AbrovaPushNotificationPermission]).
  static Future<AbrovaPushNotificationPermission> notificationPermission() async {
    if (!Platform.isMacOS) return AbrovaPushNotificationPermission.notNeeded;
    final ok = await _notifications?.isAllowed() ?? false;
    return ok ? AbrovaPushNotificationPermission.allowed : AbrovaPushNotificationPermission.notAllowed;
  }

  /// macOS: asks the user to allow notifications (once; after a "no" only
  /// System Settings can change it). Windows and Linux need no permission.
  /// Returns whether they are allowed.
  static Future<bool> requestNotificationPermission() async =>
      Platform.isMacOS ? await _notifications?.requestPermission() ?? false : true;

  /// Registers this computer with the project and keeps it connected. Safe to
  /// call at every start (the same install keeps its id).
  static Future<void> register({String? userId, Map<String, dynamic>? metadata}) async {
    final api = _require();
    final store = _store!;
    final deviceId = await store.deviceId();
    final body = <String, dynamic>{
      'deviceId': deviceId,
      'platform': Platform.operatingSystem,
      'appIdentifier': _appIdentifier,
      'userId': ?userId,
      'metadata': ?metadata,
      ...await _deviceFields(),
      'sdkName': abrovaPushDesktopSdkName,
      'sdkVersion': abrovaPushDesktopVersion,
    };
    Registration reg;
    try {
      reg = await api.register(body);
    } catch (e) {
      _count(PushErrorCodes.registrationFailed, e);
      // Offline at start: use the last registration and keep trying in the background.
      final last = Registration.fromJson(store.get<Map>('registration')?.cast<String, dynamic>());
      if (last == null) rethrow;
      _error(e);
      reg = last;
      unawaited(_retryRegister(body));
    }
    if (reg.deviceId.isEmpty) {
      reg = Registration(
        deviceId: deviceId,
        subscriptionId: reg.subscriptionId,
        appId: reg.appId,
        token: reg.token,
        endpoints: reg.endpoints,
      );
    }
    await store.set('registration', reg.toJson());
    if (!await store.claimInstall()) {
      // Another copy of this app runs on this computer and keeps the connection.
      _log('registered $deviceId; another copy of the app is connected, this one stays offline');
      return;
    }
    _connect(reg);
    _log('registered $deviceId');
    unawaited(_fetchInApp(thenShow: InAppTrigger.appOpen));
  }

  static Future<void> _retryRegister(Map<String, dynamic> body) async {
    for (var attempt = 0; attempt < 8; attempt++) {
      await Future.delayed(backoff(attempt + 2));
      try {
        final reg = await _api!.register(body);
        await _store!.set('registration', reg.toJson());
        return;
      } catch (e) {
        _count(PushErrorCodes.registrationFailed, e);
        if (e is PushApiException && !e.retryable) return;
      }
    }
  }

  static void _connect(Registration reg) {
    final old = _connection;
    if (old != null) unawaited(old.stop());
    final c = PushConnection(
      clientId: connectionClientId(reg.appId, reg.deviceId, _appIdentifier),
      registration: reg,
      refreshToken: () async {
        try {
          final token = await _api!.refreshToken(reg.deviceId);
          final now = _connection?.registration;
          if (now != null) {
            await _store!.set('registration', {...now.toJson(), 'token': token});
          }
          return token;
        } catch (e) {
          _count(PushErrorCodes.authenticationFailed, e);
          _error(e);
          return null;
        }
      },
      onPayload: _onPayload,
      onError: (code, reason, port) => _diagnostics?.count(code, reason: reason, port: port),
      onState: (s) {
        _current = s;
        if (!_state.isClosed) _state.add(s);
      },
      log: _log,
    );
    _connection = c;
    c.start();
  }

  static Future<Map<String, dynamic>> _deviceFields() async {
    final locale = PlatformDispatcher.instance.locale;
    final info = await PackageInfo.fromPlatform();
    final out = <String, dynamic>{
      'appVersion': info.version,
      'appBuild': ?int.tryParse(info.buildNumber),
      'language': locale.languageCode,
      'country': ?locale.countryCode,
    };
    try {
      final d = DeviceInfoPlugin();
      String? machine;
      if (Platform.isMacOS) {
        final m = await d.macOsInfo;
        out['osVersion'] = m.osRelease;
        out['deviceModel'] = m.model;
        machine = m.systemGUID;
      } else if (Platform.isWindows) {
        final w = await d.windowsInfo;
        out['osVersion'] = '${w.majorVersion}.${w.minorVersion}.${w.buildNumber}';
        out['deviceModel'] = w.productName;
        machine = w.deviceId;
      } else if (Platform.isLinux) {
        final l = await d.linuxInfo;
        out['osVersion'] = l.versionId ?? l.version;
        out['deviceModel'] = l.prettyName;
        machine = l.machineId;
      }
      if (machine != null && machine.isNotEmpty) {
        // Lets the server tell a reinstall from a new computer; not the machine id itself.
        out['installId'] = sha256.convert(utf8.encode('$machine:$_appIdentifier')).toString().substring(0, 32);
      }
    } catch (_) {}
    out.removeWhere((_, v) => v == null || (v is String && v.isEmpty));
    return out;
  }

  static void _onPayload(String topic, String payload) {
    if (topic.endsWith('/topic/$inAppSignalTopic')) {
      _signalTimer?.cancel();
      _signalTimer = Timer(signalJitter(), () => unawaited(_fetchInApp(thenShow: InAppTrigger.sessionStart)));
      return;
    }
    Map<String, dynamic> json;
    try {
      final j = jsonDecode(payload);
      if (j is! Map) return;
      json = Map<String, dynamic>.from(j);
    } catch (_) {
      return;
    }
    if (json['type'] == 'inbox_update') return; // Inbox: not on computers yet.
    final m = AbrovaPushMessage.fromJson(json);
    unawaited(_handleMessage(m));
  }

  static Future<void> _handleMessage(AbrovaPushMessage m) async {
    final id = m.messageId;
    final dupe = id != null && _store!.seen(id);
    if (id != null) {
      // Confirm delivery every time (a repeat may mean the first confirm was lost).
      unawaited(_receipt('delivered', {'messageId': id, 'deviceId': deviceId, 'transport': 'pn'}));
      if (!dupe) await _store!.markSeen(id);
    }
    if (dupe) return;
    if (!_messages.isClosed) _messages.add(m);
    final cfg = _config!;
    final focused = WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    if (!m.silent && cfg.showNotifications && (cfg.showNotificationsWhileFocused || !focused)) {
      try {
        await _notifications?.show(m);
      } catch (e) {
        _error(e);
      }
    }
  }

  static void _onTap(String payload, String? actionId) {
    try {
      final m = AbrovaPushMessage.fromJson(Map<String, dynamic>.from(jsonDecode(payload) as Map));
      if (!_taps.isClosed) _taps.add(m);
      if (m.messageId != null) {
        unawaited(_receipt(actionId == null ? 'opened' : 'clicked', {
          'messageId': m.messageId,
          'deviceId': deviceId,
          'actionId': ?actionId,
        }));
      }
      if (DesktopBackground.instance.enabled) {
        unawaited(DesktopBackground.instance.showWindow().catchError((_) {}));
      }
    } catch (e) {
      _error(e);
    }
  }

  static Future<void> _receipt(String kind, Map<String, dynamic> body) async {
    for (final wait in const [Duration.zero, Duration(seconds: 5), Duration(seconds: 30), Duration(seconds: 120)]) {
      if (wait > Duration.zero) await Future.delayed(wait);
      try {
        await _api!.receipt(kind, body);
        return;
      } catch (e) {
        if (e is PushApiException && !e.retryable) return;
      }
    }
  }

  // ─── In-app messages ────────────────────────────────────────────────────

  /// Shows the in-app message for the app opening, if one applies (called by
  /// [register]; call it again when your UI is ready if you listen later).
  static Future<void> triggerInAppOnAppOpen() => _fetchInApp(thenShow: InAppTrigger.appOpen);

  /// Shows the in-app message set to your custom event [name], if any.
  static Future<void> triggerInAppEvent(String name) => _fetchInApp(thenShow: InAppTrigger.event, event: name);

  static Future<void> _fetchInApp({InAppTrigger? thenShow, String? event}) async {
    final id = deviceId;
    if (_api == null || id == null) return;
    try {
      final r = await _api!.fetchInApp({
        'deviceId': id,
        'sessionCount': _sessionCount,
        'locale': PlatformDispatcher.instance.locale.toLanguageTag(),
      }, etag: _inAppEtag);
      if (r != null) {
        _inApp = r.messages;
        _inAppEtag = r.etag;
      }
    } catch (e) {
      _error(e);
    }
    if (thenShow == null) return;
    final pick = pickInApp(_inApp, thenShow, event: event, sessionCount: _sessionCount, shownThisRun: _inAppShown);
    if (pick == null) return;
    _inAppShown.add('${pick['id']}');
    final delay = Duration(seconds: (pick['delaySeconds'] as num?)?.toInt() ?? 0);
    Future.delayed(delay, () {
      final msg = AbrovaPushInAppMessage.fromJson(pick);
      if (!_inAppReady.isClosed) _inAppReady.add(msg);
      unawaited(_inAppAction(msg.id, 'impression'));
    });
  }

  /// Tell Abrova what the user did with an in-app message: `click`, `dismiss`
  /// or `button_click` (with [buttonId]).
  static Future<void> recordInApp(AbrovaPushInAppMessage message, String action, {String? buttonId}) =>
      _inAppAction(message.id, action, buttonId: buttonId);

  static Future<void> _inAppAction(String messageId, String action, {String? buttonId}) async {
    final id = deviceId;
    if (_api == null || id == null) return;
    try {
      await _api!.inAppEvent({'messageId': messageId, 'deviceId': id, 'action': action, 'buttonId': ?buttonId});
    } catch (e) {
      _error(e);
    }
  }

  // ─── Users and topics ───────────────────────────────────────────────────

  // ─── Signed user tokens (the same calls as the phone SDK) ────────────────

  static AbrovaPushDesktopTokenProvider? _pendingProvider;
  static bool _providerSet = false;
  static String? _pendingToken;
  static OnAuthErrorCallback? _onAuthError;

  /// Set, replace or remove (null) the user token provider. Same as
  /// [AbrovaPushDesktopConfig.tokenProvider]; may be called before [init].
  /// The SDK waits for it before each request. If it throws or does not answer
  /// within 10 seconds, the request is sent without a token and [onAuthError]
  /// reports `token_provider_failed`.
  static void setTokenProvider(AbrovaPushDesktopTokenProvider? provider) {
    _pendingProvider = provider;
    _providerSet = true;
    _api?.tokenProvider = provider;
  }

  /// Hand the SDK a user token you fetched yourself (null forgets it). Without
  /// a provider the SDK cannot renew it: call this again when you refresh it.
  static void setUserToken(String? token) {
    _pendingToken = token;
    _api?.userToken = token;
  }

  /// Identity errors: the server refused the user token, or the provider
  /// failed. Typically: send the user to sign in.
  static void onAuthError(OnAuthErrorCallback callback) {
    _onAuthError = callback;
  }

  static Future<void> setUserId(String userId) => _require().setUser(_deviceIdOrThrow(), userId);
  static Future<void> clearUserId() => _require().clearUser(_deviceIdOrThrow());
  static Future<void> subscribeTopic(String topic) =>
      _counted(PushErrorCodes.subscriptionFailed, () => _require().subscribeTopic(_deviceIdOrThrow(), topic));
  static Future<void> unsubscribeTopic(String topic) =>
      _counted(PushErrorCodes.unsubscriptionFailed, () => _require().unsubscribeTopic(_deviceIdOrThrow(), topic));

  static Future<void> _counted(int code, Future<void> Function() call) async {
    try {
      await call();
    } on PushApiException catch (e) {
      _count(code, e);
      rethrow;
    }
  }

  // ─── Telegram style ─────────────────────────────────────────────────────

  /// Keep receiving pushes when the window is closed: the app stays in the
  /// tray ([trayIconPath]: a .ico on Windows, a .png on macOS and Linux; on
  /// macOS [trayIconIsTemplate] for a one-colour icon that follows the menu
  /// bar's light or dark look), and
  /// optionally starts with the computer, hidden in the tray. Let your users
  /// switch these off in your settings.
  static Future<void> enableBackgroundMode({
    required String trayIconPath,
    bool trayIconIsTemplate = false,
    bool keepRunningInTray = true,
    bool launchAtStartup = false,
    bool startHidden = true,
    String? tooltip,
    String openLabel = 'Open',
    String quitLabel = 'Quit',
  }) =>
      DesktopBackground.instance.enable(
        appName: _appName.isEmpty ? 'App' : _appName,
        appIdentifier: _appIdentifier,
        keepRunningInTray: keepRunningInTray,
        launchAtStartup: launchAtStartup,
        startHidden: startHidden,
        trayIconPath: trayIconPath,
        trayIconIsTemplate: trayIconIsTemplate,
        tooltip: tooltip,
        openLabel: openLabel,
        quitLabel: quitLabel,
      );

  /// Turn starting with the computer on or off (e.g. from your settings).
  static Future<void> setLaunchAtStartup(bool enabled, {bool startHidden = true}) =>
      DesktopBackground.instance.setLaunchAtStartup(
        appName: _appName,
        appIdentifier: _appIdentifier,
        enabled: enabled,
        startHidden: startHidden,
      );

  /// Whether this run started at login in the tray (pass `main`'s args).
  static bool startedHidden(List<String> args) => DesktopBackground.startedHidden(args);

  /// Brings the window back, or sends it to the tray. Only after
  /// [enableBackgroundMode].
  static Future<void> showWindow() => DesktopBackground.instance.showWindow();
  static Future<void> hideWindow() => DesktopBackground.instance.hideWindow();

  // ─── Lifecycle ──────────────────────────────────────────────────────────

  /// Try the connection now (e.g. when your window comes to the front).
  static void reconnectNow() => _connection?.retryNow();

  /// Stops the connection (the app keeps its registration).
  static Future<void> dispose() async {
    _signalTimer?.cancel();
    await _connection?.stop();
    _connection = null;
  }

  static PushApi _require() {
    final api = _api;
    if (api == null) throw StateError('Call AbrovaPushDesktop.init first');
    return api;
  }

  static String _deviceIdOrThrow() {
    final id = deviceId;
    if (id == null) throw StateError('Call AbrovaPushDesktop.register first');
    return id;
  }
}
