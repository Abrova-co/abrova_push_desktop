import 'dart:math';

/// An in-app message to show now. Show it your way (or with any UI), then call
/// [AbrovaPushDesktop.recordInApp] for clicks and dismissals.
class AbrovaPushInAppMessage {
  AbrovaPushInAppMessage({
    required this.id,
    required this.type,
    this.name,
    this.title,
    this.body,
    this.imageUrl,
    this.backgroundColor,
    this.textColor,
    this.buttons = const [],
    this.priority = 0,
    this.raw = const {},
  });

  final String id;

  /// modal, banner, fullscreen or card.
  final String type;
  final String? name;
  final String? title;
  final String? body;
  final String? imageUrl;
  final String? backgroundColor;
  final String? textColor;
  final List<AbrovaPushInAppButton> buttons;
  final int priority;
  final Map<String, dynamic> raw;

  /// From the fetch answer (the server already put in the content for the
  /// locale the SDK sent).
  factory AbrovaPushInAppMessage.fromJson(Map<String, dynamic> j) {
    final content = j['content'] is Map ? Map<String, dynamic>.from(j['content'] as Map) : <String, dynamic>{};
    final title = content['title'] as String?;
    final body = content['body'] as String?;
    return AbrovaPushInAppMessage(
      id: '${j['id']}',
      type: '${j['type'] ?? 'modal'}',
      name: j['name'] as String?,
      title: title,
      body: body,
      imageUrl: content['imageUrl'] as String?,
      backgroundColor: content['backgroundColor'] as String?,
      textColor: content['textColor'] as String?,
      buttons: [
        for (final b in (content['buttons'] is List ? content['buttons'] as List : const []).whereType<Map>())
          AbrovaPushInAppButton(
            id: '${b['id'] ?? ''}',
            text: '${b['text'] ?? ''}',
            action: '${b['action'] ?? 'dismiss'}',
            value: b['value'] as String?,
          ),
      ],
      priority: (j['priority'] as num?)?.toInt() ?? 0,
      raw: j,
    );
  }
}

class AbrovaPushInAppButton {
  const AbrovaPushInAppButton({required this.id, required this.text, required this.action, this.value});
  final String id;
  final String text;

  /// dismiss, deep_link, url or custom.
  final String action;
  final String? value;
}

/// What an in-app message reacts to.
enum InAppTrigger { appOpen, sessionStart, event }

DateTime? _date(Object? v) {
  if (v == null) return null;
  if (v is num) return DateTime.fromMillisecondsSinceEpoch(v.toInt());
  return DateTime.tryParse('$v');
}

/// Whether [m] should show for [trigger] (and [event]) now, the way the phone
/// SDKs decide; the server already checked audience and how often it showed.
bool inAppMatches(
  Map<String, dynamic> m,
  InAppTrigger trigger, {
  String? event,
  required int sessionCount,
  DateTime? now,
}) {
  final t = now ?? DateTime.now();
  final start = _date(m['startDate']);
  final end = _date(m['endDate']);
  if (start != null && t.isBefore(start)) return false;
  if (end != null && t.isAfter(end)) return false;
  final minSessions = (m['minSessionCount'] as num?)?.toInt() ?? 0;
  if (sessionCount < minSessions) return false;
  final type = '${m['triggerType'] ?? 'on_app_open'}';
  switch (trigger) {
    case InAppTrigger.appOpen:
      return type == 'on_app_open';
    case InAppTrigger.sessionStart:
      return type == 'on_session_start' || type == 'on_app_open';
    case InAppTrigger.event:
      return type == 'on_event' && event != null && '${m['triggerEvent'] ?? ''}'.trim() == event.trim();
  }
}

/// The one to show: the highest priority that matches.
Map<String, dynamic>? pickInApp(
  List<Map<String, dynamic>> messages,
  InAppTrigger trigger, {
  String? event,
  required int sessionCount,
  Set<String> shownThisRun = const {},
  DateTime? now,
}) {
  final hits = messages
      .where((m) => !shownThisRun.contains('${m['id']}'))
      .where((m) => inAppMatches(m, trigger, event: event, sessionCount: sessionCount, now: now))
      .toList()
    ..sort((a, b) => ((b['priority'] as num?) ?? 0).compareTo((a['priority'] as num?) ?? 0));
  return hits.isEmpty ? null : hits.first;
}

/// After a change signal: wait 0–60 s so a project's installs don't all fetch
/// in the same second.
Duration signalJitter([Random? random]) => Duration(milliseconds: (random ?? Random()).nextInt(60000));
