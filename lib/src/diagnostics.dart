import 'dart:async';
import 'dart:io';

import 'store.dart';

/// The shared public error numbers every Abrova Push SDK reports (the same
/// numbers as on Android, iOS and the web).
abstract final class PushErrorCodes {
  static const connectionFailed = 1000;
  static const connectionTimeout = 1001;
  static const connectionLost = 1002;
  static const connectionRefused = 1003;
  static const authenticationFailed = 1004;
  static const sslError = 1005;
  static const brokerUnavailable = 1006;
  static const subscriptionFailed = 1100;
  static const unsubscriptionFailed = 1101;
  static const messageParseError = 1201;
  static const configurationFailed = 1304;
  static const registrationFailed = 1400;
  static const serverError = 1402;
  static const networkError = 1403;
}

/// SDK self-reports, as on the phones: the SDK counts its own errors by the
/// shared number and sends the counts with its next ordinary API request:
///
///     X-Abrova-SDK-Report: 1000=3 1400=1
///     X-Abrova-SDK-Report-Reasons: 1000:timeout.443=3 1400:http503=1
///
/// Counts only, and reasons only from a fixed list ([reasonOf]): never a
/// message, address, key, user or device detail. A count is cleared only after
/// the server answered 2xx, so nothing is lost while offline and nothing is
/// counted twice. Off with `AbrovaPushDesktopConfig.sendDiagnostics: false`.
class SdkDiagnostics {
  SdkDiagnostics({this.store, this.enabled = true}) {
    if (!enabled) unawaited(store?.set(_key, null));
  }

  static const header = 'X-Abrova-SDK-Report';
  static const reasonsHeader = 'X-Abrova-SDK-Report-Reasons';
  static const maxCodes = 16;
  static const maxCount = 9999;
  static const _maxReasonsHeader = 400;
  static const _key = 'diagnostics';
  static final _entry = RegExp(r'^\d{4}:[a-z][a-z0-9_]{0,19}(\.\d{1,5})?(\.(wifi|cellular|ethernet|vpn|none|other))?$');

  final DesktopPushStore? store;
  final bool enabled;

  Map<String, int> _codes = {};
  Map<String, int> _reasons = {};
  bool _loaded = false;

  void _load() {
    if (_loaded) return;
    _loaded = true;
    final saved = store?.get<Map>(_key);
    if (saved == null) return;
    Map<String, int> read(Object? m) => {
          for (final e in (m is Map ? m : const {}).entries)
            if (e.value is num && (e.value as num) > 0) '${e.key}': (e.value as num).toInt().clamp(1, maxCount),
        };
    _codes = read(saved['codes']);
    _reasons = read(saved['reasons']);
  }

  Future<void> _save() async {
    await store?.set(_key, _codes.isEmpty && _reasons.isEmpty ? null : {'codes': _codes, 'reasons': _reasons});
  }

  /// Adds one to [code] and, when given, to its [reason] (`timeout`, `http503`).
  /// [port]: the connection's port, for connection errors. Never throws.
  void count(int code, {String? reason, int? port}) {
    if (!enabled) return;
    try {
      _load();
      final key = '$code';
      if (!_codes.containsKey(key) && _codes.length >= maxCodes) return;
      _codes[key] = ((_codes[key] ?? 0) + 1).clamp(1, maxCount);
      if (reason != null) {
        final entry = port == null ? '$code:$reason' : '$code:$reason.$port';
        if (_entry.hasMatch(entry) && (_reasons.containsKey(entry) || _reasons.length < maxCodes)) {
          _reasons[entry] = ((_reasons[entry] ?? 0) + 1).clamp(1, maxCount);
        }
      }
      unawaited(_save());
    } catch (_) {
      // Counting never matters more than the SDK's work.
    }
  }

  /// What to send now, or null when there is nothing.
  DiagnosticsSnapshot? snapshot() {
    if (!enabled) return null;
    _load();
    if (_codes.isEmpty && _reasons.isEmpty) return null;
    final codes = (_codes.entries.toList()..sort((a, b) => a.key.compareTo(b.key))).take(maxCodes).toList();
    final reasons = <MapEntry<String, int>>[];
    var length = 0;
    for (final e in _reasons.entries.toList()..sort((a, b) => a.key.compareTo(b.key))) {
      if (reasons.length >= maxCodes) break;
      final next = length + '${e.key}=${e.value}'.length + (reasons.isEmpty ? 0 : 1);
      if (next > _maxReasonsHeader) break;
      reasons.add(e);
      length = next;
    }
    return DiagnosticsSnapshot(Map.fromEntries(codes), Map.fromEntries(reasons));
  }

  /// The server took [sent]: subtract it (counts added meanwhile stay).
  void acknowledge(DiagnosticsSnapshot sent) {
    try {
      void minus(Map<String, int> into, Map<String, int> what) {
        for (final e in what.entries) {
          final left = (into[e.key] ?? 0) - e.value;
          if (left > 0) {
            into[e.key] = left;
          } else {
            into.remove(e.key);
          }
        }
      }

      minus(_codes, sent.codes);
      minus(_reasons, sent.reasons);
      unawaited(_save());
    } catch (_) {}
  }

  /// The reason word for [error], from the fixed list in the shared spec.
  /// Looks only at the error's type and numbers, never sends its text.
  static String reasonOf(Object error) {
    if (error is TimeoutException) return 'timeout';
    if (error is HandshakeException) {
      return error.toString().contains('CERTIFICATE_VERIFY_FAILED') ? 'cert' : 'tls_handshake';
    }
    if (error is TlsException) return 'tls';
    if (error is SocketException) {
      final byErrno = _errnoReason(error.osError?.errorCode);
      if (byErrno != null) return byErrno;
      if (error.toString().contains('Failed host lookup')) return 'dns';
      return 'socket';
    }
    if (error is FormatException) return 'parse';
    if (error is StateError) return 'state';
    if (error is ArgumentError) return 'arg';
    if (error is OutOfMemoryError) return 'oom';
    return 'other';
  }

  /// POSIX numbers on Linux and macOS, Winsock numbers on Windows.
  static String? _errnoReason(int? n) {
    if (n == null) return null;
    if (Platform.isWindows) {
      return switch (n) {
        10060 => 'timeout',
        10061 => 'refused',
        10050 || 10051 || 10065 => 'noroute',
        10053 || 10054 => 'reset',
        11001 || 11002 || 11004 => 'dns',
        _ => null,
      };
    }
    if (Platform.isMacOS) {
      return switch (n) {
        60 => 'timeout',
        61 => 'refused',
        50 || 51 || 65 => 'noroute',
        32 || 53 || 54 => 'reset',
        _ => null,
      };
    }
    return switch (n) {
      110 => 'timeout',
      111 => 'refused',
      100 || 101 || 113 => 'noroute',
      32 || 103 || 104 => 'reset',
      _ => null,
    };
  }
}

class DiagnosticsSnapshot {
  DiagnosticsSnapshot(this.codes, this.reasons);
  final Map<String, int> codes;
  final Map<String, int> reasons;

  String? get headerValue => codes.isEmpty ? null : codes.entries.map((e) => '${e.key}=${e.value}').join(' ');
  String? get reasonsValue => reasons.isEmpty ? null : reasons.entries.map((e) => '${e.key}=${e.value}').join(' ');
}
