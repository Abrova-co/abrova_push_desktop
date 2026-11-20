import 'dart:math';

/// The words and look of an in-app message in one language: what the Console's
/// Content and Buttons sections set.
class AbrovaPushInAppContent {
  const AbrovaPushInAppContent({
    this.title,
    this.body,
    this.imageUrl,
    this.backgroundColor,
    this.textColor,
    this.buttons = const [],
    this.position = 'top',
  });

  final String? title;
  final String? body;

  /// Shown 2:1 on modal and full screen, 3:1 on cards, as a thumbnail on banners.
  final String? imageUrl;

  /// `#RRGGBB`.
  final String? backgroundColor;
  final String? textColor;

  /// Up to two.
  final List<AbrovaPushInAppButton> buttons;

  /// Banners: `top` or `bottom`.
  final String position;

  factory AbrovaPushInAppContent.fromJson(Map<String, dynamic> c) => AbrovaPushInAppContent(
        title: c['title'] as String?,
        body: c['body'] as String?,
        imageUrl: (c['imageUrl'] as String?)?.trim().isEmpty ?? true ? null : c['imageUrl'] as String,
        backgroundColor: c['backgroundColor'] as String?,
        textColor: c['textColor'] as String?,
        position: c['position'] == 'bottom' ? 'bottom' : 'top',
        buttons: [
          for (final b in (c['buttons'] is List ? c['buttons'] as List : const []).whereType<Map>().take(2))
            AbrovaPushInAppButton(
              id: '${b['id'] ?? ''}',
              text: '${b['text'] ?? ''}',
              action: '${b['action'] ?? 'dismiss'}',
              value: b['value'] as String?,
            ),
        ],
      );
}

/// An in-app message to show now. With [AbrovaPushDesktop.showInAppMessages]
/// the SDK shows it; otherwise show it your way, then call
/// [AbrovaPushDesktop.recordInApp] for clicks and dismissals.
class AbrovaPushInAppMessage {
  AbrovaPushInAppMessage({
    required this.id,
    required this.type,
    this.name,
    this.content = const AbrovaPushInAppContent(),
    this.translations = const {},
    this.priority = 0,
    this.raw = const {},
  });

  final String id;

  /// modal, banner, fullscreen or card.
  final String type;
  final String? name;

  /// The default content (the Console's "Default" tab).
  final AbrovaPushInAppContent content;

  /// Other languages ("Add language"), by language tag (`fa`, `en-US`).
  final Map<String, AbrovaPushInAppContent> translations;
  final int priority;
  final Map<String, dynamic> raw;

  String? get title => content.title;
  String? get body => content.body;
  String? get imageUrl => content.imageUrl;
  String? get backgroundColor => content.backgroundColor;
  String? get textColor => content.textColor;
  List<AbrovaPushInAppButton> get buttons => content.buttons;

  /// The content for the app's language: an exact match (`fa-IR`), then the
  /// language (`fa`), else the default.
  AbrovaPushInAppContent contentFor(String languageTag) {
    final want = languageTag.replaceAll('_', '-').toLowerCase();
    final lang = want.split('-').first;
    for (final e in translations.entries) {
      if (e.key.toLowerCase() == want) return e.value;
    }
    for (final e in translations.entries) {
      if (e.key.toLowerCase().split('-').first == lang) return e.value;
    }
    return content;
  }

  factory AbrovaPushInAppMessage.fromJson(Map<String, dynamic> j) {
    final content = j['content'] is Map ? Map<String, dynamic>.from(j['content'] as Map) : <String, dynamic>{};
    return AbrovaPushInAppMessage(
      id: '${j['id']}',
      type: '${j['type'] ?? 'modal'}',
      name: j['name'] as String?,
      content: AbrovaPushInAppContent.fromJson(content),
      translations: {
        for (final l in (j['localizations'] is List ? j['localizations'] as List : const []).whereType<Map>())
          if (l['locale'] is String && l['content'] is Map)
            l['locale'] as String: AbrovaPushInAppContent.fromJson(Map<String, dynamic>.from(l['content'] as Map)),
      },
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

  /// The link (deep_link, url) or your value (custom).
  final String? value;
}

/// A button pressed in the built-in in-app display.
class AbrovaPushInAppButtonEvent {
  const AbrovaPushInAppButtonEvent(this.message, this.button);
  final AbrovaPushInAppMessage message;
  final AbrovaPushInAppButton button;
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
  Map<String, int> shownCounts = const {},
  DateTime? now,
}) {
  // "Show at most N per install" (the Console's maxImpressions), counted on this install: the list may come from
  // the cache (304), so the server's own count can't be relied on alone.
  final hits = messages
      .where((m) => (shownCounts['${m['id']}'] ?? 0) < (((m['maxImpressions'] as num?)?.toInt() ?? 1).clamp(1, 100)))
      .where((m) => inAppMatches(m, trigger, event: event, sessionCount: sessionCount, now: now))
      .toList()
    ..sort((a, b) => ((b['priority'] as num?) ?? 0).compareTo((a['priority'] as num?) ?? 0));
  return hits.isEmpty ? null : hits.first;
}

/// After a change signal: wait 0–60 s so a project's installs don't all fetch
/// in the same second.
Duration signalJitter([Random? random]) => Duration(milliseconds: (random ?? Random()).nextInt(60000));
