import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'auth_error.dart';
import 'diagnostics.dart';
import 'version.dart';

/// One place the live connection can be reached.
class PushEndpoint {
  const PushEndpoint(this.host, this.port, {this.tls = true});
  final String host;
  final int port;
  final bool tls;

  @override
  bool operator ==(Object other) => other is PushEndpoint && other.host == host && other.port == port && other.tls == tls;

  @override
  int get hashCode => Object.hash(host, port, tls);

  @override
  String toString() => '$host:$port';
}

/// What registering returns: this install's ids and its connection.
class Registration {
  Registration({
    required this.deviceId,
    required this.subscriptionId,
    required this.appId,
    required this.token,
    required this.endpoints,
  });

  final String deviceId;
  final String subscriptionId;

  /// The short project id the connection's channels are named with.
  final String appId;
  final String token;

  /// In the order to try: the server's failover list first, then the main one.
  final List<PushEndpoint> endpoints;

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'subscriptionId': subscriptionId,
        'appId': appId,
        'token': token,
        'endpoints': [for (final e in endpoints) {'host': e.host, 'port': e.port, 'tls': e.tls}],
      };

  static Registration? fromJson(Map<String, dynamic>? j) {
    if (j == null) return null;
    try {
      return Registration(
        deviceId: j['deviceId'] as String,
        subscriptionId: j['subscriptionId'] as String,
        appId: j['appId'] as String,
        token: j['token'] as String,
        endpoints: [
          for (final e in (j['endpoints'] as List).whereType<Map>())
            PushEndpoint(e['host'] as String, (e['port'] as num).toInt(), tls: e['tls'] != false),
        ],
      );
    } catch (_) {
      return null;
    }
  }

  /// From the server's register answer.
  static Registration parse(Map<String, dynamic> j) {
    final mqtt = Map<String, dynamic>.from(j['mqtt'] as Map);
    final main = PushEndpoint(
      mqtt['host'] as String,
      ((mqtt['tlsPort'] ?? mqtt['port']) as num).toInt(),
      tls: mqtt['secure'] != false,
    );
    final failover = <PushEndpoint>[
      for (final e in (j['mqttEndpoints'] is List ? j['mqttEndpoints'] as List : const []).whereType<Map>().take(5))
        PushEndpoint(e['host'] as String, (e['port'] as num).toInt(), tls: e['tls'] != false),
    ];
    return Registration(
      deviceId: (j['deviceId'] ?? '') as String,
      subscriptionId: (j['subscriptionId'] ?? j['id']) as String,
      appId: j['appId'] as String,
      token: mqtt['token'] as String,
      endpoints: {...failover, main}.toList(),
    );
  }
}

/// Register field: whether this computer shows the app's notifications (macOS only; unknown elsewhere).
const String notificationsEnabledField = 'notificationsEnabled';

/// A validation answer that names [field] as unknown ("property notificationsEnabled should not exist").
bool refusesField(String body, String field) => body.contains(field) && body.contains('should not exist');

class PushApiException implements Exception {
  PushApiException(this.status, this.message, {this.code, String? reason})
      : reason = reason ?? (status != null && status >= 400 && status <= 599 ? 'http$status' : 'other');
  final int? status;
  final String message;

  /// The fixed reason word for the SDK report (`http503`, `timeout`, `dns`, …).
  final String reason;

  /// The server's reason, when it gives one (for example `token_required`,
  /// `token_invalid`, `token_expired`).
  final String? code;

  /// Worth trying again later (offline, timeout, rate limit, server error).
  bool get retryable => status == null || status == 408 || status == 429 || (status ?? 0) >= 500;

  @override
  String toString() => 'PushApiException($status, ${code == null ? '' : '$code: '}$message)';
}

/// The Push HTTP API, with the project's API key and, when the app gives one,
/// the user token (`x-user-token`).
class PushApi {
  PushApi({required this.baseUrl, required this.apiKey, this.tokenProvider, this.diagnostics, http.Client? client})
      : _client = client ?? http.Client();

  /// Counts the SDK's errors and sends them with the next request (the same
  /// report the phone SDKs send).
  final SdkDiagnostics? diagnostics;

  final String baseUrl;
  final String apiKey;
  FutureOr<String?> Function()? tokenProvider;

  /// A token the app handed over itself ([AbrovaPushDesktop.setUserToken]),
  /// used when there is no provider.
  String? userToken;

  /// The server refused the user token, or the provider failed.
  void Function(AbrovaPushAuthErrorEvent event)? onAuthError;
  final http.Client _client;

  /// Waits for the provider's token. Null when there is no provider, no one is
  /// signed in, or the provider failed (the server then decides).
  Future<String?> _userToken() async {
    final provider = tokenProvider;
    if (provider == null) return userToken;
    try {
      final t = await Future.value(provider()).timeout(const Duration(seconds: 10));
      return (t == null || t.isEmpty) ? null : t;
    } catch (e) {
      _authError(AbrovaPushAuthErrorEvent(
        code: AbrovaPushAuthErrorEvent.tokenProviderFailed,
        message: 'tokenProvider failed or did not answer in 10 s',
        error: e,
      ));
      return null;
    }
  }

  void _authError(AbrovaPushAuthErrorEvent e) {
    try {
      onAuthError?.call(e);
    } catch (_) {}
  }

  static const _tokenCodes = {
    AbrovaPushAuthErrorEvent.tokenExpired,
    AbrovaPushAuthErrorEvent.tokenInvalid,
    AbrovaPushAuthErrorEvent.tokenRequired,
  };

  /// The identity error a response carries, or null (as on Android).
  static AbrovaPushAuthErrorEvent? authFailureOf(http.Response r) {
    if (r.statusCode != 401 && r.statusCode != 403) return null;
    try {
      final j = jsonDecode(r.body);
      if (j is! Map) return null;
      final message = '${j['message'] ?? ''}';
      if (r.statusCode == 401) {
        final code = j['code'];
        return _tokenCodes.contains(code)
            ? AbrovaPushAuthErrorEvent(code: code as String, message: message.isEmpty ? code : message)
            : null;
      }
      return message.toLowerCase().contains('does not match the user token')
          ? AbrovaPushAuthErrorEvent(code: AbrovaPushAuthErrorEvent.tokenMismatch, message: message)
          : null;
    } catch (_) {
      return null;
    }
  }

  Map<String, String> get _headers => {
        'x-api-key': apiKey,
        'Content-Type': 'application/json',
        'X-Abrova-SDK': '$abrovaPushDesktopSdkName/$abrovaPushDesktopVersion',
      };

  Uri _u(String path) => Uri.parse('${baseUrl.replaceAll(RegExp(r'/+$'), '')}$path');

  Future<http.Response> _send(String method, String path, {Object? body, Map<String, String>? headers}) async {
    final token = await _userToken();
    final first = await _sendOnce(method, path, body: body, headers: headers, userToken: token);
    final failure = authFailureOf(first);
    if (failure == null) return first;
    // An expired token: the provider renews it, so ask once more and retry.
    if (failure.code == AbrovaPushAuthErrorEvent.tokenExpired && token != null && tokenProvider != null) {
      final fresh = await _userToken();
      if (fresh != null) {
        final retried = await _sendOnce(method, path, body: body, headers: headers, userToken: fresh);
        final again = authFailureOf(retried);
        if (again != null) _authError(again);
        return retried;
      }
    }
    _authError(failure);
    return first;
  }

  Future<http.Response> _sendOnce(
    String method,
    String path, {
    Object? body,
    Map<String, String>? headers,
    String? userToken,
  }) async {
    final report = diagnostics?.snapshot();
    final req = http.Request(method, _u(path))
      ..headers.addAll({
        ..._headers,
        'x-user-token': ?userToken,
        SdkDiagnostics.header: ?report?.headerValue,
        SdkDiagnostics.reasonsHeader: ?report?.reasonsValue,
        ...?headers,
      });
    if (body != null) req.body = jsonEncode(body);
    http.Response r;
    try {
      r = await http.Response.fromStream(await _client.send(req).timeout(const Duration(seconds: 20)));
    } on TimeoutException {
      throw PushApiException(null, 'timeout', reason: 'timeout');
    } on http.ClientException catch (e) {
      throw PushApiException(null, 'network', reason: _causeReason(e));
    } catch (e) {
      throw PushApiException(null, 'network', reason: SdkDiagnostics.reasonOf(e));
    }
    if (report != null && r.statusCode >= 200 && r.statusCode < 300) diagnostics!.acknowledge(report);
    return r;
  }

  /// `http` wraps socket errors in a ClientException whose text names them.
  static String _causeReason(http.ClientException e) {
    final t = e.toString();
    if (t.contains('Failed host lookup')) return 'dns';
    if (t.contains('CERTIFICATE_VERIFY_FAILED')) return 'cert';
    if (t.contains('HandshakeException')) return 'tls_handshake';
    if (t.contains('Connection refused')) return 'refused';
    if (t.contains('Connection reset')) return 'reset';
    if (t.contains('timed out')) return 'timeout';
    if (t.contains('SocketException')) return 'socket';
    return 'other';
  }

  static String? _codeOf(http.Response r) {
    try {
      final j = jsonDecode(r.body);
      if (j is Map && j['code'] is String) return j['code'] as String;
    } catch (_) {}
    return null;
  }

  Map<String, dynamic> _json(http.Response r) {
    if (r.statusCode < 200 || r.statusCode >= 300) {
      String msg = 'HTTP ${r.statusCode}';
      try {
        final j = jsonDecode(r.body);
        if (j is Map && j['message'] != null) msg = '${j['message']}';
      } catch (_) {}
      throw PushApiException(r.statusCode, msg, code: _codeOf(r));
    }
    final j = r.body.isEmpty ? <String, dynamic>{} : jsonDecode(r.body);
    return j is Map ? Map<String, dynamic>.from(j) : <String, dynamic>{};
  }

  /// Called when the server refused [notificationsEnabledField] (a server from before it).
  void Function()? onNotificationsFieldRefused;

  /// POST /devices/register. A server from before notificationsEnabled answers 400 "should not exist": the same
  /// registration goes again without it, so the app keeps working whichever is deployed first.
  Future<Registration> register(Map<String, dynamic> body) async {
    final r = await _send('POST', '/devices/register', body: body);
    if (r.statusCode == 400 && body.containsKey(notificationsEnabledField) && refusesField(r.body, notificationsEnabledField)) {
      onNotificationsFieldRefused?.call();
      return register(Map.of(body)..remove(notificationsEnabledField));
    }
    return Registration.parse(_json(r));
  }

  Future<String> refreshToken(String deviceId) async {
    final j = _json(await _send('POST', '/devices/${Uri.encodeComponent(deviceId)}/mqtt-token/refresh'));
    return j['token'] as String;
  }

  /// delivered / opened / clicked / dismissed.
  Future<void> receipt(String kind, Map<String, dynamic> body) async {
    _json(await _send('POST', '/receipts/$kind', body: body));
  }

  Future<void> subscribeTopic(String deviceId, String topic) async {
    _json(await _send('POST', '/devices/${Uri.encodeComponent(deviceId)}/topics/${Uri.encodeComponent(topic)}'));
  }

  Future<void> unsubscribeTopic(String deviceId, String topic) async {
    _json(await _send('DELETE', '/devices/${Uri.encodeComponent(deviceId)}/topics/${Uri.encodeComponent(topic)}'));
  }

  Future<void> setUser(String deviceId, String userId) async {
    _json(await _send('POST', '/devices/${Uri.encodeComponent(deviceId)}/user', body: {'userId': userId}));
  }

  Future<void> clearUser(String deviceId) async {
    _json(await _send('DELETE', '/devices/${Uri.encodeComponent(deviceId)}/user'));
  }

  /// In-app messages for this install. Returns null when nothing changed since
  /// [etag] (the server answered 304).
  Future<({List<Map<String, dynamic>> messages, String? etag})?> fetchInApp(
    Map<String, dynamic> body, {
    String? etag,
  }) async {
    final r = await _send('POST', '/in-app/fetch', body: body, headers: {'If-None-Match': ?etag});
    if (r.statusCode == 304) return null;
    if (r.statusCode < 200 || r.statusCode >= 300) _json(r);
    final j = jsonDecode(r.body.isEmpty ? '[]' : r.body);
    return (
      messages: [for (final m in (j is List ? j : const []).whereType<Map>()) Map<String, dynamic>.from(m)],
      etag: r.headers['etag'],
    );
  }

  Future<void> inAppEvent(Map<String, dynamic> body) async {
    _json(await _send('POST', '/in-app/impression', body: body));
  }

  void close() => _client.close();
}
