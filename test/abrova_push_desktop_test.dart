import 'dart:convert';
import 'dart:math';

import 'package:abrova_push_desktop/src/api.dart';
import 'package:abrova_push_desktop/src/autostart.dart';
import 'package:abrova_push_desktop/src/connection.dart';
import 'package:abrova_push_desktop/src/in_app.dart';
import 'package:abrova_push_desktop/src/message.dart';
import 'package:abrova_push_desktop/src/notifications.dart';
import 'package:abrova_push_desktop/src/store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final reg = Registration(
    deviceId: 'desktop_0123456789abcdef0123456789abcdef',
    subscriptionId: '6f1c2c3e-1111-4222-8333-944455556666',
    appId: 'abcdefghijklmnop',
    token: 't',
    endpoints: const [PushEndpoint('pn.example', 8883)],
  );

  group('connection', () {
    test('client id: the form the server maps to the install (and bills like a phone)', () {
      final id = connectionClientId(reg.appId, reg.deviceId, 'com.example.app');
      // Server: ^(rp_|<ns>_)[A-Za-z0-9_.:-]{1,190}$ and startsWith rp_{appId}_{deviceId}_
      expect(RegExp(r'^rp_[A-Za-z0-9_.:-]{1,190}$').hasMatch(id), isTrue);
      expect(id.startsWith('rp_${reg.appId}_${reg.deviceId}_'), isTrue);
      expect(connectionClientId(reg.appId, reg.deviceId, 'com.example.other'), isNot(id));
    });

    test('channels: own, broadcast and the in-app signal', () {
      expect(channelsFor(reg), [
        'abrova_push/abcdefghijklmnop/sub/6f1c2c3e-1111-4222-8333-944455556666',
        'abrova_push/abcdefghijklmnop/broadcast',
        'abrova_push/abcdefghijklmnop/topic/__in_app',
      ]);
    });

    test('backoff: 1 s doubling, never over 60 s (±20 %)', () {
      final r = Random(1);
      expect(backoff(0, r).inMilliseconds, inInclusiveRange(800, 1200));
      expect(backoff(3, r).inMilliseconds, inInclusiveRange(6400, 9600));
      expect(backoff(50, r).inMilliseconds, inInclusiveRange(48000, 72000));
    });
  });

  group('register answer', () {
    test('failover endpoints first, then the main TLS port', () {
      final r = Registration.parse({
        'deviceId': 'd',
        'subscriptionId': 's',
        'appId': 'a',
        'mqtt': {'host': 'pn.example', 'port': 8883, 'tlsPort': 8883, 'secure': true, 'token': 'tok'},
        'mqttEndpoints': [
          {'host': 'pn.example', 'port': 443, 'tls': true},
        ],
      });
      expect(r.endpoints, const [PushEndpoint('pn.example', 443), PushEndpoint('pn.example', 8883)]);
      expect(r.token, 'tok');
      expect(Registration.fromJson(r.toJson())!.endpoints, r.endpoints);
    });
  });

  group('api', () {
    test('register sends the API key and the SDK name, never a server secret', () async {
      late http.Request seen;
      final api = PushApi(
        baseUrl: 'https://push.example/',
        apiKey: 'key-1',
        client: MockClient((req) async {
          seen = req;
          return http.Response(
            jsonEncode({
              'deviceId': 'd',
              'subscriptionId': 's',
              'appId': 'a',
              'mqtt': {'host': 'h', 'port': 8883, 'token': 't'},
            }),
            200,
          );
        }),
      );
      await api.register({'deviceId': 'd', 'platform': 'windows'});
      expect(seen.url.toString(), 'https://push.example/devices/register');
      expect(seen.headers['x-api-key'], 'key-1');
      expect(seen.headers['X-Abrova-SDK'], startsWith('flutter-desktop/'));
      expect(seen.headers.keys.map((k) => k.toLowerCase()), isNot(contains('x-server-secret')));
      expect(jsonDecode(seen.body)['platform'], 'windows');
    });

    test('in-app fetch: sends the ETag back; 304 means nothing changed', () async {
      String? sentTag;
      var call = 0;
      final api = PushApi(
        baseUrl: 'https://push.example',
        apiKey: 'k',
        client: MockClient((req) async {
          sentTag = req.headers['If-None-Match'];
          call++;
          if (call == 1) return http.Response(jsonEncode([{'id': 'm1'}]), 200, headers: {'etag': 'W/"abc"'});
          return http.Response('', 304);
        }),
      );
      final first = await api.fetchInApp({'deviceId': 'd'});
      expect(first!.messages.single['id'], 'm1');
      expect(first.etag, 'W/"abc"');
      expect(sentTag, isNull);
      expect(await api.fetchInApp({'deviceId': 'd'}, etag: first.etag), isNull);
      expect(sentTag, 'W/"abc"');
    });

    final okRegister = http.Response(
      jsonEncode({'deviceId': 'd', 'subscriptionId': 's', 'appId': 'a', 'mqtt': {'host': 'h', 'port': 8883, 'token': 't'}}),
      200,
    );

    test('user token: waits for the provider and sends x-user-token', () async {
      final seen = <String?>[];
      final api = PushApi(
        baseUrl: 'https://x',
        apiKey: 'k',
        tokenProvider: () async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return 'tok-1';
        },
        client: MockClient((req) async {
          seen.add(req.headers['x-user-token']);
          return okRegister;
        }),
      );
      await api.register({'deviceId': 'd', 'userId': 'u1'});
      expect(seen, ['tok-1']);
    });

    test('user token: none without a provider or when signed out', () async {
      final seen = <String?>[];
      final client = MockClient((req) async {
        seen.add(req.headers['x-user-token']);
        return okRegister;
      });
      await PushApi(baseUrl: 'https://x', apiKey: 'k', client: client).register({'deviceId': 'd'});
      await PushApi(baseUrl: 'https://x', apiKey: 'k', tokenProvider: () => null, client: client).register({'deviceId': 'd'});
      await PushApi(baseUrl: 'https://x', apiKey: 'k', tokenProvider: () => throw StateError('x'), client: client)
          .register({'deviceId': 'd'});
      expect(seen, [null, null, null]);
    });

    test('user token: 401 token_expired asks the provider again and retries once', () async {
      var asked = 0;
      final seen = <String?>[];
      final api = PushApi(
        baseUrl: 'https://x',
        apiKey: 'k',
        tokenProvider: () => 'tok-${++asked}',
        client: MockClient((req) async {
          seen.add(req.headers['x-user-token']);
          if (seen.length == 1) {
            return http.Response(jsonEncode({'statusCode': 401, 'code': 'token_expired', 'message': 'expired'}), 401);
          }
          return okRegister;
        }),
      );
      await api.register({'deviceId': 'd', 'userId': 'u1'});
      expect(seen, ['tok-1', 'tok-2']);
    });

    test('user token: 401 token_required is not retried and carries its code', () async {
      var calls = 0;
      final api = PushApi(
        baseUrl: 'https://x',
        apiKey: 'k',
        tokenProvider: () => null,
        client: MockClient((req) async {
          calls++;
          return http.Response(jsonEncode({'statusCode': 401, 'code': 'token_required', 'message': 'needs token'}), 401);
        }),
      );
      await expectLater(
        api.register({'deviceId': 'd', 'userId': 'u1'}),
        throwsA(isA<PushApiException>()
            .having((e) => e.code, 'code', 'token_required')
            .having((e) => e.retryable, 'retryable', false)),
      );
      expect(calls, 1);
    });

    test('errors: offline and 5xx are retryable, 4xx is not', () async {
      final api = PushApi(baseUrl: 'https://x', apiKey: 'k', client: MockClient((_) async => http.Response('{"message":"bad"}', 400)));
      await expectLater(api.receipt('delivered', {}), throwsA(isA<PushApiException>().having((e) => e.retryable, 'retryable', false)));
      expect(PushApiException(null, 'network').retryable, isTrue);
      expect(PushApiException(503, 'x').retryable, isTrue);
    });
  });

  group('messages', () {
    test('localized title and body in the computer language', () {
      final m = AbrovaPushMessage.fromJson({
        'messageId': 'm1',
        'title': 'Hello',
        'body': 'Body',
        'localizations': [
          {'locale': 'fa', 'title': 'سلام', 'body': 'متن'},
        ],
        'data': {'k': 'v'},
      }, locale: 'fa-IR');
      expect((m.title, m.body, m.data['k']), ('سلام', 'متن', 'v'));
      expect(AbrovaPushMessage.fromJson({'title': 'Hello'}, locale: 'de').title, 'Hello');
    });

    test('a push seen once is remembered', () async {
      final s = DesktopPushStore.memory();
      expect(s.seen('m1'), isFalse);
      await s.markSeen('m1');
      expect(s.seen('m1'), isTrue);
      for (var i = 0; i < 600; i++) {
        await s.markSeen('x$i');
      }
      expect(s.seen('m1'), isFalse, reason: 'only the last 500 are kept');
    });

    test('notification ids and the Windows GUID are stable', () {
      expect(notificationId('m1'), notificationId('m1'));
      expect(notificationId('m1'), isNonNegative);
      expect(guidFor('com.example.app'), matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-a[0-9a-f]{3}-[0-9a-f]{12}$')));
      expect(guidFor('com.example.app'), guidFor('com.example.app'));
    });
  });

  group('in-app matching', () {
    final now = DateTime.utc(2026, 11, 20, 12);
    Map<String, dynamic> m(String id, {String trigger = 'on_app_open', int priority = 0, Object? start, Object? end, int minSessions = 0, String? event}) => {
          'id': id,
          'triggerType': trigger,
          'priority': priority,
          'startDate': start,
          'endDate': end,
          'minSessionCount': minSessions,
          'triggerEvent': event,
        };

    test('highest priority that applies, once per run', () {
      final list = [m('a', priority: 1), m('b', priority: 5), m('c', trigger: 'on_event', event: 'opened_plans')];
      expect(pickInApp(list, InAppTrigger.appOpen, sessionCount: 1, now: now)?['id'], 'b');
      expect(pickInApp(list, InAppTrigger.appOpen, sessionCount: 1, now: now, shownThisRun: {'b'})?['id'], 'a');
      expect(pickInApp(list, InAppTrigger.event, event: 'opened_plans', sessionCount: 1, now: now)?['id'], 'c');
    });

    test('dates (ms or ISO) and minimum sessions', () {
      expect(inAppMatches(m('x', start: now.add(const Duration(days: 1)).toIso8601String()), InAppTrigger.appOpen, sessionCount: 1, now: now), isFalse);
      expect(inAppMatches(m('x', end: now.subtract(const Duration(days: 1)).millisecondsSinceEpoch), InAppTrigger.appOpen, sessionCount: 1, now: now), isFalse);
      expect(inAppMatches(m('x', minSessions: 3), InAppTrigger.appOpen, sessionCount: 2, now: now), isFalse);
      expect(inAppMatches(m('x', minSessions: 3), InAppTrigger.appOpen, sessionCount: 3, now: now), isTrue);
    });

    test('after a change signal installs wait 0–60 s', () {
      expect(signalJitter(Random(2)).inMilliseconds, inInclusiveRange(0, 60000));
    });
  });

  group('start with the computer', () {
    test('macOS LaunchAgent runs the app at login with its arguments', () {
      final p = macPlist('ir.example.app', ['/Applications/Ex & Co.app/Contents/MacOS/ex', '--hidden']);
      expect(p, contains('<string>ir.example.app</string>'));
      expect(p, contains('<string>/Applications/Ex &amp; Co.app/Contents/MacOS/ex</string>'));
      expect(p, contains('<string>--hidden</string>'));
      expect(p, contains('<key>RunAtLoad</key>'));
    });

    test('Linux autostart entry quotes paths with spaces', () {
      final d = linuxDesktop('Example', ['/opt/my app/example', '--hidden']);
      expect(d, contains('Exec="/opt/my app/example" --hidden'));
      expect(d, contains('X-GNOME-Autostart-enabled=true'));
    });

    test('file names come from the app id, made safe', () {
      final a = Autostart(appName: 'Example', appIdentifier: 'ir.example/app', executable: '/x', home: '/home/u');
      expect(a.linuxDesktopPath, '/home/u/.config/autostart/ir.example_app.desktop');
      expect(a.macPlistPath, '/home/u/Library/LaunchAgents/ir.example_app.plist');
    });
  });
}
