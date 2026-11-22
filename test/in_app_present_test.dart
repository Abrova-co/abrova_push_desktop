import 'package:abrova_push_desktop/abrova_push_desktop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

AbrovaPushInAppMessage _msg(String id) => AbrovaPushInAppMessage.fromJson({
      'id': id,
      'type': 'modal',
      'content': {'title': 'New version', 'body': 'Release notes'},
    });

void main() {
  // Team on the Mac 11-22: two fetches close together (session start, app open) showed the same message twice in one
  // frame; the first, not drawn yet, was never removed: stacked dialogs, a dark page, a close button doing nothing.
  testWidgets('two shows in one frame leave one message, and close removes it', (tester) async {
    final key = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(navigatorKey: key, home: const Scaffold(body: Text('app'))));
    AbrovaPushDesktop.showInAppMessages(navigatorKey: key);

    AbrovaPushDesktop.debugPresentInApp(_msg('m1'));
    AbrovaPushDesktop.debugPresentInApp(_msg('m1'));
    await tester.pumpAndSettle();
    expect(find.text('New version'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.text('New version'), findsNothing);
    expect(find.text('app'), findsOneWidget);
  });
}
