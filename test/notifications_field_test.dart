import 'dart:convert';

import 'package:abrova_push_desktop/src/api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// notificationsEnabled on register, and a server from before the field: the register goes again without it.
void main() {
  const ok = '{"id":"r1","deviceId":"d1","subscriptionId":"s1","appId":"a1","mqtt":{"host":"h","port":8883,"token":"t"}}';

  test('register sends notificationsEnabled', () async {
    final bodies = <Map<String, dynamic>>[];
    final api = PushApi(
      baseUrl: 'https://push.test',
      apiKey: 'ab_test',
      client: MockClient((req) async {
        bodies.add(jsonDecode(req.body) as Map<String, dynamic>);
        return http.Response(ok, 200);
      }),
    );
    await api.register({'deviceId': 'd1', 'notificationsEnabled': false});
    expect(bodies.single['notificationsEnabled'], false);
  });

  test('an older server that refuses the field gets the register again without it', () async {
    final bodies = <Map<String, dynamic>>[];
    var refused = 0;
    final api = PushApi(
      baseUrl: 'https://push.test',
      apiKey: 'ab_test',
      client: MockClient((req) async {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        bodies.add(body);
        if (body.containsKey('notificationsEnabled')) {
          return http.Response('{"statusCode":400,"message":["property notificationsEnabled should not exist"]}', 400);
        }
        return http.Response(ok, 200);
      }),
    )..onNotificationsFieldRefused = () => refused++;

    final reg = await api.register({'deviceId': 'd1', 'notificationsEnabled': true});

    expect(reg.deviceId, 'd1');
    expect(refused, 1);
    expect(bodies, hasLength(2));
    expect(bodies[1].containsKey('notificationsEnabled'), isFalse);
  });

  test('another 400 is an error, not a retry', () async {
    var calls = 0;
    final api = PushApi(
      baseUrl: 'https://push.test',
      apiKey: 'ab_test',
      client: MockClient((_) async {
        calls++;
        return http.Response('{"message":["deviceId must be a string"]}', 400);
      }),
    );
    await expectLater(api.register({'deviceId': 'd1', 'notificationsEnabled': true}), throwsA(isA<PushApiException>()));
    expect(calls, 1);
  });
}
