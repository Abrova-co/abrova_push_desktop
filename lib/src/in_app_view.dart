import 'dart:io';

import 'package:flutter/material.dart';

import 'in_app.dart';

/// What the built-in display does when a button is pressed, after it recorded the click and closed the message:
/// `url` buttons are opened in the browser by the SDK; use this for `deep_link` (route inside your app) and `custom`
/// (your own value).
typedef AbrovaPushInAppButtonTap = void Function(
  BuildContext context,
  AbrovaPushInAppMessage message,
  AbrovaPushInAppButton button,
);

/// Handed to a custom renderer: call them from your own buttons.
class AbrovaPushInAppActions {
  const AbrovaPushInAppActions({required this.onButtonTap, required this.onDismiss});

  /// Records the click, closes the message, then runs the button's action.
  final void Function(AbrovaPushInAppButton button) onButtonTap;

  /// Records the dismissal and closes the message.
  final VoidCallback onDismiss;
}

/// Draws one message type yourself; the SDK still inserts, closes and records.
typedef AbrovaPushInAppRendererBuilder = Widget Function(
  BuildContext context,
  AbrovaPushInAppMessage message,
  AbrovaPushInAppContent content,
  AbrovaPushInAppActions actions,
);

/// Your own renderer per type; a null one uses the built-in.
class AbrovaPushInAppBuilders {
  const AbrovaPushInAppBuilders({this.modal, this.banner, this.fullscreen, this.card});
  final AbrovaPushInAppRendererBuilder? modal;
  final AbrovaPushInAppRendererBuilder? banner;
  final AbrovaPushInAppRendererBuilder? fullscreen;
  final AbrovaPushInAppRendererBuilder? card;

  AbrovaPushInAppRendererBuilder? forType(String type) => switch (type) {
        'banner' => banner,
        'fullscreen' => fullscreen,
        'card' => card,
        _ => modal,
      };
}

/// Look of the built-in display. The message's own colours (Console › Content) win over these; these win over
/// your app's theme.
class AbrovaPushInAppTheme {
  const AbrovaPushInAppTheme({
    this.backdropColor,
    this.backgroundColor,
    this.textColor,
    this.borderRadius = 16,
    this.modalMaxWidth = 440,
    this.cardMaxWidth = 420,
    this.bannerMaxWidth = 720,
    this.animationDuration = const Duration(milliseconds: 200),
  });

  final Color? backdropColor;
  final Color? backgroundColor;
  final Color? textColor;
  final double borderRadius;
  final double modalMaxWidth;
  final double cardMaxWidth;
  final double bannerMaxWidth;
  final Duration animationDuration;
}

/// One message on screen, built by the SDK (see AbrovaPushDesktop.showInAppMessages).
Widget buildInAppView({
  required BuildContext context,
  required AbrovaPushInAppMessage message,
  required AbrovaPushInAppTheme theme,
  required AbrovaPushInAppBuilders builders,
  required AbrovaPushInAppActions actions,
}) {
  final locale = Localizations.maybeLocaleOf(context);
  final content = locale == null ? message.content : message.contentFor(locale.toLanguageTag());
  final custom = builders.forType(message.type);
  if (custom != null) return custom(context, message, content, actions);
  final style = _Style.of(context, content, theme);
  return switch (message.type) {
    'banner' => _banner(context, content, style, theme, actions),
    'fullscreen' => _fullscreen(context, content, style, theme, actions),
    'card' => _card(context, content, style, theme, actions),
    _ => _modal(context, content, style, theme, actions),
  };
}

/// `#RRGGBB` or `#AARRGGBB`.
Color? parseInAppColor(String? hex) {
  if (hex == null || hex.isEmpty) return null;
  var h = hex.replaceFirst('#', '');
  if (h.length == 6) h = 'FF$h';
  final v = int.tryParse(h, radix: 16);
  return v == null ? null : Color(v);
}

/// Opens a link in the browser or the app the system picks.
Future<bool> openInAppLink(String link) async {
  try {
    final ProcessResult r;
    if (Platform.isMacOS) {
      r = await Process.run('open', [link]);
    } else if (Platform.isWindows) {
      r = await Process.run('rundll32', ['url.dll,FileProtocolHandler', link]);
    } else {
      r = await Process.run('xdg-open', [link]);
    }
    return r.exitCode == 0;
  } catch (_) {
    return false;
  }
}

class _Style {
  const _Style(this.bg, this.fg);
  final Color bg;
  final Color fg;

  static _Style of(BuildContext context, AbrovaPushInAppContent c, AbrovaPushInAppTheme t) {
    final scheme = Theme.of(context).colorScheme;
    return _Style(
      parseInAppColor(c.backgroundColor) ?? t.backgroundColor ?? scheme.surface,
      parseInAppColor(c.textColor) ?? t.textColor ?? scheme.onSurface,
    );
  }
}

Widget _image(String url, double ratio) => AspectRatio(
      aspectRatio: ratio,
      child: Image.network(
        url,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => const SizedBox.shrink(),
      ),
    );

Widget _title(BuildContext context, String? text, Color fg, TextStyle? base, {int? maxLines}) =>
    (text == null || text.isEmpty)
        ? const SizedBox.shrink()
        : Text(text, maxLines: maxLines, overflow: maxLines == null ? null : TextOverflow.ellipsis, style: base?.copyWith(color: fg, fontWeight: FontWeight.w600));

Widget _body(BuildContext context, String? text, Color fg, TextStyle? base, {int? maxLines}) =>
    (text == null || text.isEmpty)
        ? const SizedBox.shrink()
        : Text(text, maxLines: maxLines, overflow: maxLines == null ? null : TextOverflow.ellipsis, style: base?.copyWith(color: fg));

/// The first button is the main one (filled), the second a text button, as in the Console's preview.
List<Widget> _buttons(AbrovaPushInAppContent c, _Style s, AbrovaPushInAppActions a) => [
      for (var i = c.buttons.length - 1; i >= 0; i--)
        i == 0
            ? FilledButton(
                style: FilledButton.styleFrom(backgroundColor: s.fg, foregroundColor: s.bg),
                onPressed: () => a.onButtonTap(c.buttons[i]),
                child: Text(c.buttons[i].text),
              )
            : TextButton(
                style: TextButton.styleFrom(foregroundColor: s.fg),
                onPressed: () => a.onButtonTap(c.buttons[i]),
                child: Text(c.buttons[i].text),
              ),
    ];

Widget _close(BuildContext context, Color fg, VoidCallback onDismiss, {double size = 20}) => IconButton(
      icon: Icon(Icons.close, size: size, color: fg),
      onPressed: onDismiss,
      tooltip: Localizations.of<MaterialLocalizations>(context, MaterialLocalizations)?.closeButtonTooltip ?? 'Close',
    );

Widget _appear(Duration d, Widget child, {Offset from = Offset.zero}) => TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: d,
      curve: Curves.easeOut,
      builder: (_, v, c) => Opacity(
        opacity: v,
        child: Transform.translate(offset: Offset(from.dx * (1 - v), from.dy * (1 - v)), child: c),
      ),
      child: child,
    );

Widget _panel(_Style s, AbrovaPushInAppTheme t, Widget child, {double elevation = 8}) => Material(
      color: s.bg,
      elevation: elevation,
      borderRadius: BorderRadius.circular(t.borderRadius),
      clipBehavior: Clip.antiAlias,
      child: child,
    );

Widget _modal(BuildContext context, AbrovaPushInAppContent c, _Style s, AbrovaPushInAppTheme t, AbrovaPushInAppActions a) {
  final text = Theme.of(context).textTheme;
  return _appear(
    t.animationDuration,
    Stack(children: [
      Positioned.fill(
        child: GestureDetector(onTap: a.onDismiss, child: ColoredBox(color: t.backdropColor ?? Colors.black54)),
      ),
      Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: t.modalMaxWidth),
            child: _panel(
              s,
              t,
              Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (c.imageUrl != null) _image(c.imageUrl!, 2),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 12, 16),
                  child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Expanded(child: _title(context, c.title, s.fg, text.titleLarge)),
                      _close(context, s.fg, a.onDismiss),
                    ]),
                    const SizedBox(height: 8),
                    Padding(padding: const EdgeInsetsDirectional.only(end: 8), child: _body(context, c.body, s.fg, text.bodyMedium)),
                    if (c.buttons.isNotEmpty) ...[
                      const SizedBox(height: 20),
                      Wrap(alignment: WrapAlignment.end, spacing: 8, runSpacing: 8, children: _buttons(c, s, a)),
                    ],
                  ]),
                ),
              ]),
            ),
          ),
        ),
      ),
    ]),
  );
}

Widget _banner(BuildContext context, AbrovaPushInAppContent c, _Style s, AbrovaPushInAppTheme t, AbrovaPushInAppActions a) {
  final text = Theme.of(context).textTheme;
  final top = c.position != 'bottom';
  return Align(
    alignment: top ? Alignment.topCenter : Alignment.bottomCenter,
    child: _appear(
      t.animationDuration,
      from: Offset(0, top ? -24 : 24),
      Padding(
        padding: const EdgeInsets.all(12),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: t.bannerMaxWidth),
          child: _panel(
            s,
            t,
            elevation: 4,
            InkWell(
              onTap: c.buttons.isEmpty ? a.onDismiss : null,
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Row(children: [
                  if (c.imageUrl != null)
                    Padding(
                      padding: const EdgeInsetsDirectional.only(end: 12),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: SizedBox(width: 44, height: 44, child: _image(c.imageUrl!, 1)),
                      ),
                    ),
                  Expanded(
                    child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                      _title(context, c.title, s.fg, text.titleSmall, maxLines: 1),
                      _body(context, c.body, s.fg, text.bodySmall, maxLines: 2),
                    ]),
                  ),
                  ..._buttons(c, s, a).map((b) => Padding(padding: const EdgeInsetsDirectional.only(start: 8), child: b)),
                  _close(context, s.fg, a.onDismiss, size: 18),
                ]),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

Widget _fullscreen(BuildContext context, AbrovaPushInAppContent c, _Style s, AbrovaPushInAppTheme t, AbrovaPushInAppActions a) {
  final text = Theme.of(context).textTheme;
  return _appear(
    t.animationDuration,
    Material(
      color: s.bg,
      child: SafeArea(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Align(alignment: AlignmentDirectional.topEnd, child: _close(context, s.fg, a.onDismiss, size: 24)),
          Expanded(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 8),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    if (c.imageUrl != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 24),
                        child: ClipRRect(borderRadius: BorderRadius.circular(12), child: _image(c.imageUrl!, 2)),
                      ),
                    _title(context, c.title, s.fg, text.headlineSmall),
                    const SizedBox(height: 12),
                    _body(context, c.body, s.fg, text.bodyLarge),
                    if (c.buttons.isNotEmpty) ...[
                      const SizedBox(height: 28),
                      Wrap(alignment: WrapAlignment.end, spacing: 8, runSpacing: 8, children: _buttons(c, s, a)),
                    ],
                  ]),
                ),
              ),
            ),
          ),
        ]),
      ),
    ),
  );
}

Widget _card(BuildContext context, AbrovaPushInAppContent c, _Style s, AbrovaPushInAppTheme t, AbrovaPushInAppActions a) {
  final text = Theme.of(context).textTheme;
  return Align(
    alignment: AlignmentDirectional.bottomEnd,
    child: _appear(
      t.animationDuration,
      from: const Offset(0, 24),
      Padding(
        padding: const EdgeInsets.all(20),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: t.cardMaxWidth),
          child: _panel(
            s,
            t,
            elevation: 6,
            Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (c.imageUrl != null) _image(c.imageUrl!, 3),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 14),
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(child: _title(context, c.title, s.fg, text.titleMedium)),
                    _close(context, s.fg, a.onDismiss, size: 18),
                  ]),
                  const SizedBox(height: 4),
                  Padding(padding: const EdgeInsetsDirectional.only(end: 8), child: _body(context, c.body, s.fg, text.bodyMedium)),
                  if (c.buttons.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Wrap(alignment: WrapAlignment.end, spacing: 8, runSpacing: 8, children: _buttons(c, s, a)),
                  ],
                ]),
              ),
            ]),
          ),
        ),
      ),
    ),
  );
}
