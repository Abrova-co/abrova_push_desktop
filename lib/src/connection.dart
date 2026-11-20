import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

import 'api.dart';
import 'diagnostics.dart';
import 'message.dart';

/// Abrova's channel names.
const String pushNamespace = 'abrova_push';

/// The in-app change signal's channel (a reserved topic name).
const String inAppSignalTopic = '__in_app';

/// The live connection's name. The `rp_{appId}_{deviceId}_` start is how the
/// server maps a connection to its install (online state, monthly connected
/// installs), the same as on phones; the end tells apart two apps of one
/// project on the same computer.
String connectionClientId(String appId, String deviceId, String appIdentifier) {
  final h = sha256.convert(utf8.encode(appIdentifier)).toString().substring(0, 8);
  return 'rp_${appId}_${deviceId}_$h';
}

/// The channels an install listens on.
List<String> channelsFor(Registration r) => [
      '$pushNamespace/${r.appId}/sub/${r.subscriptionId}',
      '$pushNamespace/${r.appId}/broadcast',
      '$pushNamespace/${r.appId}/topic/$inAppSignalTopic',
    ];

/// Delay before attempt [attempt] (0-based): 1 s doubling to 60 s, ±20 %.
Duration backoff(int attempt, [Random? random]) {
  final base = min(60, pow(2, min(attempt, 6)).toInt());
  final jitter = 0.8 + (random ?? Random()).nextDouble() * 0.4;
  return Duration(milliseconds: (base * 1000 * jitter).round());
}

/// Why a connect attempt ended.
enum ConnectOutcome { connected, refused, unauthorized, failed }

/// Keeps the install connected: tries each endpoint, refreshes the token when
/// the server refuses it, waits longer after each failed round, and hands
/// every message to [onPayload] with the channel it came on.
class PushConnection {
  PushConnection({
    required this.clientId,
    required Registration registration,
    required this.refreshToken,
    required this.onPayload,
    required this.onState,
    this.log,
    this.onError,
    this.keepAlive = const Duration(seconds: 30),
  }) : _reg = registration;

  final String clientId;
  final Future<String?> Function() refreshToken;
  final void Function(String topic, String payload) onPayload;
  final void Function(AbrovaPushConnectionState state) onState;
  final void Function(String line)? log;

  /// A connect attempt failed or a live connection dropped: the shared error
  /// number, the reason word and the port (for the SDK report).
  final void Function(int code, String reason, int port)? onError;
  final Duration keepAlive;

  Registration _reg;
  MqttServerClient? _client;

  /// The install's ids and token now (the token changes on refresh).
  Registration get registration => _reg;
  StreamSubscription? _updates;
  bool _stopped = false;
  bool _running = false;
  Completer<void>? _wake;

  /// Starts the keep-connected loop (once).
  void start() {
    if (_running) return;
    _running = true;
    _stopped = false;
    unawaited(_loop());
  }

  /// Ends the current attempt's wait and tries now (network back, app focused).
  void retryNow() {
    final w = _wake;
    if (w != null && !w.isCompleted) w.complete();
  }

  Future<void> _loop() async {
    var attempt = 0;
    while (!_stopped) {
      onState(AbrovaPushConnectionState.connecting);
      var outcome = ConnectOutcome.failed;
      for (final ep in _reg.endpoints) {
        if (_stopped) break;
        outcome = await _connectOnce(ep);
        if (outcome == ConnectOutcome.unauthorized) {
          // Token expired or revoked: get a new one and try the same endpoint again.
          final token = await refreshToken();
          if (token != null) {
            _reg = Registration(
              deviceId: _reg.deviceId,
              subscriptionId: _reg.subscriptionId,
              appId: _reg.appId,
              token: token,
              endpoints: _reg.endpoints,
            );
            outcome = await _connectOnce(ep);
          }
        }
        if (outcome == ConnectOutcome.connected) break;
        // A refusal (not a network failure) means another port will say the same.
        if (outcome == ConnectOutcome.refused || outcome == ConnectOutcome.unauthorized) break;
      }
      if (_stopped) break;
      if (outcome == ConnectOutcome.connected) {
        attempt = 0;
        onState(AbrovaPushConnectionState.connected);
        await _untilDisconnected();
        if (_stopped) break;
        final port = _connectedPort;
        if (port != null) onError?.call(PushErrorCodes.connectionLost, 'eof', port);
        onState(AbrovaPushConnectionState.disconnected);
        continue;
      }
      onState(AbrovaPushConnectionState.disconnected);
      final wait = backoff(attempt++);
      log?.call('connection failed ($outcome), next try in ${wait.inSeconds}s');
      _wake = Completer<void>();
      await Future.any([Future.delayed(wait), _wake!.future]);
    }
    _running = false;
  }

  Completer<void>? _gone;
  int? _connectedPort;

  Future<void> _untilDisconnected() async {
    final g = _gone;
    if (g != null) await g.future;
  }

  Future<ConnectOutcome> _connectOnce(PushEndpoint ep) async {
    await _closeClient();
    final c = MqttServerClient.withPort(ep.host, clientId, ep.port)
      ..secure = ep.tls
      ..keepAlivePeriod = keepAlive.inSeconds
      ..connectTimeoutPeriod = 15000
      ..autoReconnect = false
      ..logging(on: false)
      ..setProtocolV311();
    c.connectionMessage = MqttConnectMessage()
        .withClientIdentifier(clientId)
        .authenticateAs('jwt', _reg.token)
        .startClean();
    final gone = Completer<void>();
    c.onDisconnected = () {
      if (!gone.isCompleted) gone.complete();
    };
    _client = c;
    _connectedPort = null;
    try {
      log?.call('connecting to $ep');
      await c.connect();
    } catch (e) {
      _report(c, ep, e);
      return _refusalOf(c);
    }
    if (c.connectionStatus?.state != MqttConnectionState.connected) {
      _report(c, ep, null);
      return _refusalOf(c);
    }
    _gone = gone;
    _connectedPort = ep.port;
    _updates = c.updates?.listen((events) {
      for (final e in events) {
        final m = e.payload;
        if (m is! MqttPublishMessage) continue;
        String text;
        try {
          text = utf8.decode(m.payload.message);
        } catch (_) {
          continue;
        }
        onPayload(e.topic, text);
      }
    });
    for (final ch in channelsFor(_reg)) {
      c.subscribe(ch, MqttQos.atLeastOnce);
    }
    log?.call('connected to $ep');
    return ConnectOutcome.connected;
  }

  /// The broker's answer (`mqtt<N>`, N = CONNACK code) wins; else the
  /// network error's reason word.
  void _report(MqttServerClient c, PushEndpoint ep, Object? error) {
    final rc = connackNumber(c.connectionStatus?.returnCode);
    if (rc != null) {
      final code = switch (rc) {
        2 => PushErrorCodes.connectionRefused,
        3 => PushErrorCodes.brokerUnavailable,
        4 || 5 => PushErrorCodes.authenticationFailed,
        _ => PushErrorCodes.connectionFailed,
      };
      onError?.call(code, 'mqtt$rc', ep.port);
      return;
    }
    final reason = error == null ? 'other' : SdkDiagnostics.reasonOf(_causeOf(error));
    final code = switch (reason) {
      'timeout' => PushErrorCodes.connectionTimeout,
      'cert' || 'tls_handshake' || 'tls' => PushErrorCodes.sslError,
      'refused' => PushErrorCodes.connectionRefused,
      _ => PushErrorCodes.connectionFailed,
    };
    onError?.call(code, reason, ep.port);
  }

  /// mqtt_client wraps socket errors; the first wrapped one says more.
  static Object _causeOf(Object e) {
    try {
      final inner = (e as dynamic).innerException;
      if (inner is Object) return inner;
    } catch (_) {}
    return e;
  }

  ConnectOutcome _refusalOf(MqttServerClient c) {
    final code = c.connectionStatus?.returnCode;
    if (code == MqttConnectReturnCode.notAuthorized || code == MqttConnectReturnCode.badUsernameOrPassword) {
      return ConnectOutcome.unauthorized;
    }
    if (code == MqttConnectReturnCode.identifierRejected) return ConnectOutcome.refused;
    return ConnectOutcome.failed;
  }

  Future<void> _closeClient() async {
    await _updates?.cancel();
    _updates = null;
    final c = _client;
    _client = null;
    if (c != null) {
      try {
        c.disconnect();
      } catch (_) {}
    }
  }

  Future<void> stop() async {
    _stopped = true;
    retryNow();
    await _closeClient();
    final g = _gone;
    if (g != null && !g.isCompleted) g.complete();
  }
}

/// The CONNACK number of a refusal (1 to 5), or null when the broker did not refuse.
int? connackNumber(MqttConnectReturnCode? code) => switch (code) {
      MqttConnectReturnCode.unacceptedProtocolVersion => 1,
      MqttConnectReturnCode.identifierRejected => 2,
      MqttConnectReturnCode.brokerUnavailable => 3,
      MqttConnectReturnCode.badUsernameOrPassword => 4,
      MqttConnectReturnCode.notAuthorized => 5,
      _ => null,
    };
