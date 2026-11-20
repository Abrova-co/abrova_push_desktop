import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:abrova_push_desktop/abrova_push_desktop.dart';
import 'package:flutter/material.dart';

/// Run with your project's API key:
///   flutter run -d macos --dart-define=API_KEY=your_api_key
const _apiKey = String.fromEnvironment('API_KEY');
const _apiUrl = String.fromEnvironment('API_URL', defaultValue: AbrovaPushDesktopConfig.defaultApiUrl);
const _userId = String.fromEnvironment('USER_ID');

/// Testing against your own server with a private CA: --dart-define=LOCAL_CA_PEM_B64=(base64 of ca.pem)
/// (adds it to the trusted roots; certificates are still checked).
const _localCa = String.fromEnvironment('LOCAL_CA_PEM_B64');

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (_localCa.isNotEmpty) SecurityContext.defaultContext.setTrustedCertificatesBytes(base64Decode(_localCa));
  runApp(const ExampleApp());
}

class ExampleApp extends StatefulWidget {
  const ExampleApp({super.key});

  @override
  State<ExampleApp> createState() => _ExampleAppState();
}

class _ExampleAppState extends State<ExampleApp> {
  final _log = <String>[];
  AbrovaPushConnectionState _state = AbrovaPushConnectionState.disconnected;
  final _subs = <StreamSubscription>[];

  void _add(String line) {
    final t = DateTime.now().toIso8601String().substring(11, 19);
    setState(() => _log.insert(0, '$t  $line'));
  }

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    if (_apiKey.isEmpty) {
      _add('Pass your API key: --dart-define=API_KEY=…');
      return;
    }
    _subs.addAll([
      AbrovaPushDesktop.onConnectionState.listen((s) => setState(() => _state = s)),
      AbrovaPushDesktop.onMessage.listen((m) => _add('push: ${m.title} — ${m.body} ${m.data}')),
      AbrovaPushDesktop.onNotificationTapped.listen((m) => _add('clicked: ${m.title}')),
      AbrovaPushDesktop.onInAppMessage.listen((m) => _add('in-app: ${m.title} — ${m.body}')),
      AbrovaPushDesktop.onError.listen((e) => _add('error: $e')),
    ]);
    try {
      await AbrovaPushDesktop.init(const AbrovaPushDesktopConfig(
        apiKey: _apiKey,
        apiUrl: _apiUrl,
        appIdentifier: 'ir.abrova.push.desktop.example',
        debug: true,
      ));
      await AbrovaPushDesktop.register(userId: _userId.isEmpty ? null : _userId);
      _add('registered: ${AbrovaPushDesktop.deviceId}');
      _add('notifications: ${(await AbrovaPushDesktop.notificationPermission()).name}');
    } catch (e) {
      _add('failed: $e');
    }
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Abrova Push desktop example',
      home: Scaffold(
        appBar: AppBar(title: Text('Abrova Push · ${_state.name}')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            SelectableText('Install id: ${AbrovaPushDesktop.deviceId ?? '-'}'),
            const SizedBox(height: 12),
            for (final l in _log) Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: Text(l)),
          ],
        ),
      ),
    );
  }
}
