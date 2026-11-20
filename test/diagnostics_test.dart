import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:abrova_push_desktop/src/api.dart';
import 'package:abrova_push_desktop/src/auth_error.dart';
import 'package:abrova_push_desktop/src/connection.dart';
import 'package:abrova_push_desktop/src/diagnostics.dart';
import 'package:abrova_push_desktop/src/notifications.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart' show NotificationResponseType;
import 'package:abrova_push_desktop/src/store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mqtt_client/mqtt_client.dart';

// The server's grammar (push backend sdk-report.ts), so the SDK never sends what it would drop.
final _reportToken = RegExp(r'^(\d{4})=(\d{1,4})$');
final _reasonToken =
    RegExp(r'^(\d{4}):([a-z][a-z0-9_]{0,19})(?:\.(\d{1,5}))?(?:\.(wifi|cellular|ethernet|vpn|none|other))?=(\d{1,4})$');

void main() {
  group('SDK report headers', () {
    test('counts go out on the next request in the server format', () async {
      final d = SdkDiagnostics(store: DesktopPushStore.memory());
      d.count(PushErrorCodes.connectionTimeout, reason: 'timeout', port: 8883);
      d.count(PushErrorCodes.connectionTimeout, reason: 'timeout', port: 8883);
      d.count(PushErrorCodes.registrationFailed, reason: 'http503');
      late http.Request seen;
      final api = PushApi(
        baseUrl: 'https://x',
        apiKey: 'k',
        diagnostics: d,
        client: MockClient((req) async {
          seen = req;
          return http.Response('{}', 200);
        }),
      );
      await api.receipt('delivered', {});
      final report = seen.headers[SdkDiagnostics.header]!;
      final reasons = seen.headers[SdkDiagnostics.reasonsHeader]!;
      expect(report, '1001=2 1400=1');
      expect(reasons, '1001:timeout.8883=2 1400:http503=1');
      expect(report.split(' ').every(_reportToken.hasMatch), isTrue);
      expect(reasons.split(' ').every(_reasonToken.hasMatch), isTrue);
      expect(d.snapshot(), isNull, reason: 'cleared after 2xx');
    });

    test('kept when the server did not answer 2xx', () async {
      final d = SdkDiagnostics(store: DesktopPushStore.memory())..count(1000, reason: 'refused', port: 443);
      final api = PushApi(
        baseUrl: 'https://x',
        apiKey: 'k',
        diagnostics: d,
        client: MockClient((_) async => http.Response('{}', 503)),
      );
      await expectLater(api.receipt('delivered', {}), throwsA(isA<PushApiException>()));
      expect(d.snapshot()!.headerValue, '1000=1');
    });

    test('kept across restarts in the state file', () {
      final store = DesktopPushStore.memory();
      SdkDiagnostics(store: store).count(1400, reason: 'dns');
      expect(SdkDiagnostics(store: store).snapshot()!.reasonsValue, '1400:dns=1');
    });

    test('off: nothing counted or sent, old counts dropped', () async {
      final store = DesktopPushStore.memory();
      SdkDiagnostics(store: store).count(1400);
      final off = SdkDiagnostics(store: store, enabled: false)..count(1000);
      expect(off.snapshot(), isNull);
      expect(store.get<Map>('diagnostics'), isNull);
    });

    test('caps: 16 codes, count 9999, reasons only from the fixed grammar', () {
      final d = SdkDiagnostics();
      for (var i = 0; i < 20; i++) {
        d.count(1000 + i);
      }
      for (var i = 0; i < 10005; i++) {
        d.count(1000);
      }
      d.count(1001, reason: 'Some Free Text!');
      final s = d.snapshot()!;
      expect(s.codes.length, 16);
      expect(s.codes['1000'], 9999);
      expect(s.reasons, isEmpty);
    });

    test('reason words come from the error type, never its text', () {
      expect(SdkDiagnostics.reasonOf(TimeoutException('x')), 'timeout');
      expect(SdkDiagnostics.reasonOf(const FormatException('secret host a.b')), 'parse');
      expect(SdkDiagnostics.reasonOf(const SocketException('Failed host lookup: push.example')), 'dns');
      expect(SdkDiagnostics.reasonOf(StateError('x')), 'state');
      expect(SdkDiagnostics.reasonOf(Exception('x')), 'other');
      expect(PushApiException(503, 'x').reason, 'http503');
      expect(PushApiException(null, 'network').reason, 'other');
    });

    test('broker refusals map to mqtt<N>', () {
      expect(connackNumber(MqttConnectReturnCode.notAuthorized), 5);
      expect(connackNumber(MqttConnectReturnCode.badUsernameOrPassword), 4);
      expect(connackNumber(MqttConnectReturnCode.connectionAccepted), isNull);
      expect(connackNumber(null), isNull);
    });
  });

  group('auth errors', () {
    test('a refused token is reported to onAuthError, as on phones', () async {
      final events = <String>[];
      final api = PushApi(
        baseUrl: 'https://x',
        apiKey: 'k',
        tokenProvider: () => 'tok',
        client: MockClient((_) async =>
            http.Response(jsonEncode({'statusCode': 401, 'code': 'token_invalid', 'message': 'not valid'}), 401)),
      )..onAuthError = (e) => events.add(e.code);
      await expectLater(api.register({'deviceId': 'd', 'userId': 'u'}), throwsA(isA<PushApiException>()));
      expect(events, [AbrovaPushAuthErrorEvent.tokenInvalid]);
    });

    test('userId not matching the token: token_mismatch', () async {
      final events = <String>[];
      final api = PushApi(
        baseUrl: 'https://x',
        apiKey: 'k',
        client: MockClient((_) async =>
            http.Response(jsonEncode({'statusCode': 403, 'message': 'userId does not match the user token'}), 403)),
      )..onAuthError = (e) => events.add(e.code);
      await expectLater(api.setUser('d', 'u2'), throwsA(isA<PushApiException>()));
      expect(events, [AbrovaPushAuthErrorEvent.tokenMismatch]);
    });

    test('a provider that fails: sent without a token, token_provider_failed', () async {
      final events = <String>[];
      String? sent = 'unset';
      final api = PushApi(
        baseUrl: 'https://x',
        apiKey: 'k',
        tokenProvider: () => throw StateError('auth not ready'),
        client: MockClient((req) async {
          sent = req.headers['x-user-token'];
          return http.Response('{}', 200);
        }),
      )..onAuthError = (e) => events.add(e.code);
      await api.receipt('opened', {});
      expect(sent, isNull);
      expect(events, [AbrovaPushAuthErrorEvent.tokenProviderFailed]);
    });

    test('setUserToken: a token the app fetched itself is sent', () async {
      String? sent;
      final api = PushApi(
        baseUrl: 'https://x',
        apiKey: 'k',
        client: MockClient((req) async {
          sent = req.headers['x-user-token'];
          return http.Response('{}', 200);
        }),
      )..userToken = 'mine';
      await api.receipt('opened', {});
      expect(sent, 'mine');
    });
  });

  group('notification clicks', () {
    const payload = '{"messageId":"m1","title":"t","actions":[{"id":"later","title":"Later"}]}';

    test('a click on the notification itself is an open (Windows passes the payload as the action id)', () {
      expect(buttonIdOf(NotificationResponseType.selectedNotification, payload, payload), isNull);
      expect(buttonIdOf(NotificationResponseType.selectedNotificationAction, payload, payload), isNull);
      expect(buttonIdOf(NotificationResponseType.selectedNotificationAction, '', payload), isNull);
    });

    test("a button counts only when it is one of the push's own buttons", () {
      expect(buttonIdOf(NotificationResponseType.selectedNotificationAction, 'later', payload), 'later');
      expect(buttonIdOf(NotificationResponseType.selectedNotificationAction, 'other', payload), isNull);
    });
  });
}
