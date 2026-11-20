import 'dart:convert';
import 'dart:ui' show PlatformDispatcher;

/// A push received by this computer.
class AbrovaPushMessage {
  AbrovaPushMessage({
    required this.messageId,
    this.title,
    this.body,
    this.data = const {},
    this.silent = false,
    this.imageUrl,
    this.deepLink,
    this.campaignId,
    this.actions = const [],
    this.raw = const {},
  });

  /// Unique per push; also used to drop a push that arrives twice.
  final String? messageId;
  final String? title;
  final String? body;
  final Map<String, dynamic> data;

  /// A silent push shows no notification; your app still gets it in onMessage.
  final bool silent;
  final String? imageUrl;
  final String? deepLink;
  final String? campaignId;
  final List<AbrovaPushAction> actions;

  /// The push as sent, for fields this version does not model.
  final Map<String, dynamic> raw;

  /// From the push payload. The title and body are taken in the computer's
  /// language when the push carries localized versions.
  factory AbrovaPushMessage.fromJson(Map<String, dynamic> json, {String? locale}) {
    String? title = json['title'] as String?;
    String? body = json['body'] as String?;
    final lang = (locale ?? PlatformDispatcher.instance.locale.toLanguageTag()).toLowerCase();
    final locs = json['localizations'];
    if (locs is List) {
      Map? best;
      for (final l in locs.whereType<Map>()) {
        final code = '${l['locale'] ?? ''}'.toLowerCase();
        if (code.isEmpty) continue;
        if (code == lang) {
          best = l;
          break;
        }
        if (best == null && lang.split('-').first == code.split('-').first) best = l;
      }
      if (best != null) {
        title = (best['title'] as String?) ?? title;
        body = (best['body'] as String?) ?? body;
      }
    }
    final data = json['data'];
    return AbrovaPushMessage(
      messageId: json['messageId'] as String?,
      title: title,
      body: body,
      data: data is Map ? Map<String, dynamic>.from(data) : const {},
      silent: json['silent'] == true,
      imageUrl: (json['imageUrl'] ?? json['image']) as String?,
      deepLink: json['deepLink'] as String?,
      campaignId: json['campaignId'] as String?,
      actions: [
        for (final a in (json['actions'] is List ? json['actions'] as List : const []).whereType<Map>())
          AbrovaPushAction(id: '${a['id'] ?? ''}', title: '${a['title'] ?? ''}', action: a['action'] as String?),
      ],
      raw: json,
    );
  }

  @override
  String toString() => 'AbrovaPushMessage($messageId, ${jsonEncode(title)})';
}

/// A button on a notification.
class AbrovaPushAction {
  const AbrovaPushAction({required this.id, required this.title, this.action});
  final String id;
  final String title;

  /// What the button does: a deep link or URL, if the push set one.
  final String? action;
}

/// Whether this computer may show the app's notifications.
enum AbrovaPushNotificationPermission {
  /// Allowed (macOS: the user said yes).
  allowed,

  /// macOS: not allowed yet, or turned off in System Settings › Notifications.
  notAllowed,

  /// Windows and Linux: no permission needed (users can still mute an app in
  /// their system settings).
  notNeeded,
}

/// The live connection's state.
enum AbrovaPushConnectionState { disconnected, connecting, connected }
