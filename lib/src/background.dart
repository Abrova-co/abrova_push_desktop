import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'autostart.dart';

/// "Telegram style": closing the window keeps the app in the tray (so pushes
/// still arrive), the tray menu opens or quits it, and it can start with the
/// computer. Each option is the app's choice; offer your users a setting.
class DesktopBackground with TrayListener, WindowListener {
  DesktopBackground._();
  static final DesktopBackground instance = DesktopBackground._();

  bool _tray = false;

  /// Called when the window is hidden to the tray (false) or shown again (true).
  void Function(bool visible)? onVisibility;

  /// Whether [enable] ran (window_manager is set up only then).
  bool get enabled => _enabled;
  bool _enabled = false;
  String _openLabel = 'Open';
  String _quitLabel = 'Quit';

  Future<void> enable({
    required String appName,
    required String appIdentifier,
    required bool keepRunningInTray,
    required bool launchAtStartup,
    required bool startHidden,
    String? trayIconPath,
    bool trayIconIsTemplate = false,
    String? tooltip,
    String openLabel = 'Open',
    String quitLabel = 'Quit',
  }) async {
    _openLabel = openLabel;
    _quitLabel = quitLabel;
    await windowManager.ensureInitialized();
    _enabled = true;
    windowManager.addListener(this);
    await windowManager.setPreventClose(keepRunningInTray);
    if (keepRunningInTray && trayIconPath != null) {
      trayManager.addListener(this);
      await trayManager.setIcon(trayIconPath, isTemplate: Platform.isMacOS && trayIconIsTemplate);
      if (!Platform.isLinux) await trayManager.setToolTip(tooltip ?? appName);
      await trayManager.setContextMenu(Menu(items: [
        MenuItem(key: 'open', label: _openLabel),
        MenuItem.separator(),
        MenuItem(key: 'quit', label: _quitLabel),
      ]));
      _tray = true;
    }
    await setLaunchAtStartup(appName: appName, appIdentifier: appIdentifier, enabled: launchAtStartup, startHidden: startHidden);
  }

  /// Start (or stop starting) with the computer. With [startHidden] the app
  /// starts in the tray (the `--hidden` argument; see [startedHidden]).
  Future<void> setLaunchAtStartup({
    required String appName,
    required String appIdentifier,
    required bool enabled,
    bool startHidden = true,
  }) async {
    final a = Autostart(appName: appName, appIdentifier: appIdentifier);
    try {
      if (enabled) {
        await a.enable(startHidden ? const ['--hidden'] : const []);
      } else {
        await a.disable();
      }
    } catch (e) {
      debugPrint('AbrovaPush: launch at startup not changed ($e)');
    }
  }

  /// Whether this run was started at login with "start hidden".
  static bool startedHidden(List<String> args) => args.contains('--hidden');

  /// Brings the window back (from the tray). Does nothing without [enable]:
  /// window_manager must be set up first, and the system already brings the
  /// app forward when a notification is clicked.
  Future<void> showWindow() async {
    if (!_enabled) return;
    await windowManager.show();
    await windowManager.focus();
    onVisibility?.call(true);
  }

  /// Sends the window to the tray (e.g. when started hidden). Does nothing
  /// without [enable].
  Future<void> hideWindow() async {
    if (!_enabled) return;
    await windowManager.hide();
    onVisibility?.call(false);
  }

  @override
  void onWindowClose() async {
    if (_tray && await windowManager.isPreventClose()) {
      await windowManager.hide();
      onVisibility?.call(false);
    } else {
      await windowManager.destroy();
    }
  }

  @override
  void onTrayIconMouseDown() => showWindow();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) async {
    if (menuItem.key == 'open') {
      await showWindow();
    } else if (menuItem.key == 'quit') {
      await windowManager.setPreventClose(false);
      await trayManager.destroy();
      await windowManager.destroy();
    }
  }
}
