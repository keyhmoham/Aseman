import 'package:flutter/material.dart';

import 'client/client_app.dart';
import 'client/client_godot.dart';
import 'client/config.dart';
import 'client/node_api.dart';
import 'client/wake.dart';

/// A platform's lightweight client: the Elpian engine and what it needs to
/// reach Aseman, built for one platform's published frontend
/// (`platform_client_build`). See README.md.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final config = await ClientConfig.load();
  useGodot(config.godot);
  final api = NodeApi(config);
  await api.restore();
  final wake = WakeController(api.wake);
  if (!config.isValid) {
    runApp(const MaterialApp(
      home: Scaffold(body: Center(child: Text('This build names no platform (assets/client.json).'))),
    ));
    return;
  }
  runApp(PlatformClientApp(api: api, wake: wake));
}
