import 'dart:io';

/// Start with the computer, the standard way on each system (no extra
/// packages): Windows' Run key for the user, a macOS LaunchAgent, a Linux
/// autostart entry. [args] are passed at start (e.g. `--hidden`).
class Autostart {
  Autostart({required this.appName, required this.appIdentifier, String? executable, String? home})
      : executable = executable ?? Platform.resolvedExecutable,
        home = home ?? Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '';

  final String appName;
  final String appIdentifier;
  final String executable;
  final String home;

  static const _runKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';

  String get _safeId => appIdentifier.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

  /// macOS LaunchAgent file.
  String get macPlistPath => '$home/Library/LaunchAgents/$_safeId.plist';

  /// Linux autostart entry.
  String get linuxDesktopPath => '$home/.config/autostart/$_safeId.desktop';

  Future<void> enable(List<String> args) async {
    if (Platform.isWindows) {
      final value = ['"$executable"', ...args].join(' ');
      final r = await Process.run('reg', ['add', _runKey, '/v', appName, '/t', 'REG_SZ', '/d', value, '/f']);
      if (r.exitCode != 0) throw ProcessException('reg', const [], '${r.stderr}', r.exitCode);
    } else if (Platform.isMacOS) {
      final f = File(macPlistPath);
      await f.parent.create(recursive: true);
      await f.writeAsString(macPlist(_safeId, [executable, ...args]));
    } else if (Platform.isLinux) {
      final f = File(linuxDesktopPath);
      await f.parent.create(recursive: true);
      await f.writeAsString(linuxDesktop(appName, [executable, ...args]));
    }
  }

  Future<void> disable() async {
    if (Platform.isWindows) {
      await Process.run('reg', ['delete', _runKey, '/v', appName, '/f']);
    } else if (Platform.isMacOS) {
      final f = File(macPlistPath);
      if (await f.exists()) await f.delete();
    } else if (Platform.isLinux) {
      final f = File(linuxDesktopPath);
      if (await f.exists()) await f.delete();
    }
  }

  Future<bool> isEnabled() async {
    if (Platform.isWindows) {
      final r = await Process.run('reg', ['query', _runKey, '/v', appName]);
      return r.exitCode == 0;
    }
    if (Platform.isMacOS) return File(macPlistPath).exists();
    if (Platform.isLinux) return File(linuxDesktopPath).exists();
    return false;
  }
}

String _xml(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

/// A LaunchAgent that runs [command] once at login.
String macPlist(String label, List<String> command) => '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${_xml(label)}</string>
  <key>ProgramArguments</key>
  <array>
${command.map((a) => '    <string>${_xml(a)}</string>').join('\n')}
  </array>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
''';

/// A freedesktop autostart entry for [command].
String linuxDesktop(String name, List<String> command) {
  String q(String a) => RegExp(r'[\s"\\$`]').hasMatch(a) ? '"${a.replaceAll(r'\', r'\\').replaceAll('"', r'\"').replaceAll(r'$', r'\$').replaceAll('`', r'\`')}"' : a;
  return '[Desktop Entry]\nType=Application\nName=$name\nExec=${command.map(q).join(' ')}\nX-GNOME-Autostart-enabled=true\nTerminal=false\n';
}
