import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'message.dart';

/// System notifications: a toast on Windows, the desktop's notification on
/// Linux, Notification Center on macOS.
class DesktopNotifications {
  DesktopNotifications({required this.appName, required this.appIdentifier, this.windowsAumid, this.windowsGuid});

  final String appName;
  final String appIdentifier;
  final String? windowsAumid;
  final String? windowsGuid;
  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;

  /// [onTap] gets the push that was clicked (and the button id, if any).
  Future<bool> init(void Function(String messageJson, String? actionId) onTap) async {
    try {
      final ok = await _plugin.initialize(
        settings: InitializationSettings(
          macOS: const DarwinInitializationSettings(),
          linux: const LinuxInitializationSettings(defaultActionName: 'Open'),
          windows: WindowsInitializationSettings(
            appName: appName,
            appUserModelId: windowsAumid ?? appIdentifier,
            guid: windowsGuid ?? guidFor(appIdentifier),
          ),
        ),
        onDidReceiveNotificationResponse: (r) {
          final p = r.payload;
          if (p != null && p.isNotEmpty) onTap(p, buttonIdOf(r.notificationResponseType, r.actionId, p));
        },
      );
      _ready = ok ?? true;
    } catch (_) {
      _ready = false;
    }
    return _ready;
  }

  Future<void> show(AbrovaPushMessage m) async {
    if (!_ready) return;
    final details = NotificationDetails(
      macOS: const DarwinNotificationDetails(),
      linux: LinuxNotificationDetails(
        actions: [for (final a in m.actions) LinuxNotificationAction(key: a.id, label: a.title)],
      ),
      windows: WindowsNotificationDetails(
        actions: [for (final a in m.actions) WindowsAction(content: a.title, arguments: a.id)],
      ),
    );
    await _plugin.show(
      id: notificationId(m.messageId ?? '${DateTime.now().microsecondsSinceEpoch}'),
      title: m.title,
      body: m.body,
      notificationDetails: details,
      payload: jsonEncode(m.raw),
    );
  }

  /// The push the app was started from by a click, if any.
  Future<String?> launchPayload() async {
    if (!_ready) return null;
    try {
      final d = await _plugin.getNotificationAppLaunchDetails();
      return d?.didNotificationLaunchApp == true ? d?.notificationResponse?.payload : null;
    } catch (_) {
      return null;
    }
  }

  /// macOS: whether notifications are allowed; null elsewhere (no permission).
  Future<bool?> isAllowed() async {
    if (!Platform.isMacOS) return null;
    try {
      final mac = _plugin.resolvePlatformSpecificImplementation<MacOSFlutterLocalNotificationsPlugin>();
      return (await mac?.checkPermissions())?.isEnabled ?? false;
    } catch (_) {
      return false;
    }
  }

  /// macOS asks the user the first time; Windows and Linux need no permission.
  Future<bool> requestPermission() async {
    if (!Platform.isMacOS) return true;
    final mac = _plugin.resolvePlatformSpecificImplementation<MacOSFlutterLocalNotificationsPlugin>();
    return await mac?.requestPermissions(alert: true, badge: true, sound: true) ?? false;
  }
}

/// The button that was clicked, or null for a click on the notification
/// itself (an "opened"). Windows passes the click's arguments as the action
/// id even for the notification itself (they are the payload then), so only
/// a button press whose id is one of the push's own buttons counts.
String? buttonIdOf(NotificationResponseType type, String? actionId, String payload) {
  if (type != NotificationResponseType.selectedNotificationAction) return null;
  if (actionId == null || actionId.isEmpty || actionId == payload) return null;
  try {
    final m = AbrovaPushMessage.fromJson(Map<String, dynamic>.from(jsonDecode(payload) as Map));
    return m.actions.any((a) => a.id == actionId) ? actionId : null;
  } catch (_) {
    return null;
  }
}

/// A notification id per push (positive 31-bit), so the same push replaces itself.
int notificationId(String messageId) {
  final b = sha256.convert(utf8.encode(messageId)).bytes;
  return ((b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3]) & 0x7fffffff;
}

/// A stable GUID for an app's Windows notifications, from its id.
String guidFor(String appIdentifier) {
  final h = sha256.convert(utf8.encode('abrova-push-desktop:$appIdentifier')).toString();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-4${h.substring(13, 16)}-a${h.substring(17, 20)}-${h.substring(20, 32)}';
}
