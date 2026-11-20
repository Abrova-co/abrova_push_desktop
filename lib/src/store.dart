import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path_provider/path_provider.dart';

/// What the SDK keeps between runs, in one small JSON file in the app's
/// support folder (no secrets beyond this install's own connection token).
class DesktopPushStore {
  DesktopPushStore._(this._file, this._data);

  final File? _file;
  final Map<String, dynamic> _data;
  RandomAccessFile? _lock;

  /// Whether this process is the only copy of the app using this install. Two
  /// copies (the app opened twice) share one install id; if both connected, the
  /// server would keep replacing one with the other. The first copy keeps a lock
  /// on a file next to the state until it exits (the system frees it then).
  Future<bool> claimInstall() async {
    if (_lock != null) return true;
    final f = _file;
    if (f == null) return true;
    try {
      final raf = await File('${f.parent.path}${Platform.pathSeparator}install.lock').open(mode: FileMode.append);
      try {
        await raf.lock(FileLock.exclusive); // fails at once if another copy holds it
      } catch (_) {
        await raf.close();
        return false;
      }
      _lock = raf;
      return true;
    } catch (_) {
      return true; // no lock file possible: behave as before
    }
  }

  static Future<DesktopPushStore> open() async {
    try {
      final dir = Directory('${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}abrova_push');
      await dir.create(recursive: true);
      final file = File('${dir.path}${Platform.pathSeparator}state.json');
      Map<String, dynamic> data = {};
      if (await file.exists()) {
        try {
          data = Map<String, dynamic>.from(jsonDecode(await file.readAsString()) as Map);
        } catch (_) {
          data = {};
        }
      }
      return DesktopPushStore._(file, data);
    } catch (_) {
      return DesktopPushStore._(null, {});
    }
  }

  /// In memory only (tests).
  factory DesktopPushStore.memory([Map<String, dynamic>? data]) => DesktopPushStore._(null, data ?? {});

  T? get<T>(String key) => _data[key] as T?;

  Future<void> set(String key, Object? value) async {
    if (value == null) {
      _data.remove(key);
    } else {
      _data[key] = value;
    }
    await _save();
  }

  Future<void> _save() async {
    final f = _file;
    if (f == null) return;
    try {
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(jsonEncode(_data), flush: true);
      await tmp.rename(f.path);
    } catch (_) {}
  }

  /// This install's id: random, made once, kept.
  Future<String> deviceId() async {
    final existing = get<String>('deviceId');
    if (existing != null && existing.isNotEmpty) return existing;
    final r = Random.secure();
    final hex = List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    final id = 'desktop_$hex';
    await set('deviceId', id);
    return id;
  }

  /// Message ids already handled (newest last), so a push that arrives twice
  /// is shown once.
  bool seen(String id) => (get<List>('seenIds') ?? const []).contains(id);

  Future<void> markSeen(String id, {int keep = 500}) async {
    final list = [...(get<List>('seenIds') ?? const []).cast<String>()]..remove(id);
    list.add(id);
    await set('seenIds', list.length > keep ? list.sublist(list.length - keep) : list);
  }
}
