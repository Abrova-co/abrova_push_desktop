import 'package:abrova_push_desktop/src/in_app.dart';
import 'package:abrova_push_desktop/src/in_app_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

AbrovaPushInAppMessage msg(String type, {String position = 'top'}) => AbrovaPushInAppMessage.fromJson({
      'id': 'm1',
      'type': type,
      'content': {
        'title': 'New version',
        'body': 'Gozar 1.0.1 is out',
        'backgroundColor': '#102030',
        'textColor': '#FFFFFF',
        'position': position,
        'buttons': [
          {'id': 'b1', 'text': 'Update', 'action': 'url', 'value': 'https://example.com'},
          {'id': 'b2', 'text': 'Later', 'action': 'dismiss'},
        ],
      },
      'localizations': [
        {
          'locale': 'fa',
          'content': {
            'title': 'نسخه‌ی تازه',
            'body': 'گذر ۱.۰.۱ آمد',
            'buttons': [
              {'id': 'b1', 'text': 'به‌روزرسانی', 'action': 'url', 'value': 'https://example.com'},
            ],
          },
        },
      ],
    });

Future<List<String>> pump(WidgetTester tester, AbrovaPushInAppMessage m, {Locale locale = const Locale('en')}) async {
  final calls = <String>[];
  await tester.pumpWidget(MaterialApp(
    locale: locale,
    supportedLocales: const [Locale('en'), Locale('fa')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    home: Builder(
      builder: (context) => Stack(children: [
        const SizedBox.expand(),
        buildInAppView(
          context: context,
          message: m,
          theme: const AbrovaPushInAppTheme(),
          builders: const AbrovaPushInAppBuilders(),
          actions: AbrovaPushInAppActions(
            onButtonTap: (b) => calls.add('button:${b.id}'),
            onDismiss: () => calls.add('dismiss'),
          ),
        ),
      ]),
    ),
  ));
  await tester.pumpAndSettle();
  return calls;
}

void main() {
  test('content for the app language: exact, then language, else the default', () {
    final m = msg('modal');
    expect(m.contentFor('fa-IR').title, 'نسخه‌ی تازه');
    expect(m.contentFor('fa').title, 'نسخه‌ی تازه');
    expect(m.contentFor('en-US').title, 'New version');
    expect(m.title, 'New version');
    expect(m.content.buttons.length, 2);
  });

  for (final type in ['modal', 'banner', 'fullscreen', 'card']) {
    testWidgets('$type: title, body, both buttons, close', (tester) async {
      final calls = await pump(tester, msg(type));
      expect(find.text('New version'), findsOneWidget);
      expect(find.text('Gozar 1.0.1 is out'), findsOneWidget);
      await tester.tap(find.text('Update'));
      await tester.tap(find.text('Later'));
      await tester.tap(find.byIcon(Icons.close));
      expect(calls, ['button:b1', 'button:b2', 'dismiss']);
    });
  }

  testWidgets('the app in Persian shows the Persian text', (tester) async {
    await pump(tester, msg('modal'), locale: const Locale('fa'));
    expect(find.text('نسخه‌ی تازه'), findsOneWidget);
    expect(find.text('به‌روزرسانی'), findsOneWidget);
    expect(find.text('New version'), findsNothing);
  });

  testWidgets("the message's own colours are used", (tester) async {
    await pump(tester, msg('card'));
    final title = tester.widget<Text>(find.text('New version'));
    expect(title.style?.color, const Color(0xFFFFFFFF));
    final panel = tester.widgetList<Material>(find.byType(Material)).where((m) => m.color == const Color(0xFF102030));
    expect(panel, isNotEmpty);
  });

  testWidgets('banner at the bottom when the Console says bottom', (tester) async {
    await pump(tester, msg('banner', position: 'bottom'));
    final dy = tester.getCenter(find.text('New version')).dy;
    expect(dy, greaterThan(tester.view.physicalSize.height / tester.view.devicePixelRatio / 2));
  });

  test('colours: #RRGGBB and #AARRGGBB, junk ignored', () {
    expect(parseInAppColor('#FFFFFF'), const Color(0xFFFFFFFF));
    expect(parseInAppColor('80000000'), const Color(0x80000000));
    expect(parseInAppColor('nope'), isNull);
  });
}
