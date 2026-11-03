import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../../core/theme/app_colors.dart';
import '../../../data/models/bot.dart';
import '../../../elpian/elpian.dart';
import '../../../shared/widgets/skeleton.dart';
import '../elpian/app_bridge.dart';
import 'app_frontend_theme.dart';

/// Full-screen sandbox that runs an app's elpian frontend inside the
/// client. The frontend talks to its wasm backend through the user-signed
/// host bridge (message.ask / message.send). When [spaceId] is provided the
/// shared per-space sandbox bridge (sandbox.exec, sandbox.upload, …) is also
/// exposed so sandbox tooling (e.g. the file explorer) can drive the docker
/// sandbox. The app's color system is injected as a stylesheet so the frontend
/// follows the host theme.
class AppFrontendScreen extends StatefulWidget {
  const AppFrontendScreen({
    super.key,
    required this.dependencies,
    required this.bot,
    this.spaceId = '',
  });

  final AppDependencies dependencies;
  final Bot bot;
  final String spaceId;

  @override
  State<AppFrontendScreen> createState() => _AppFrontendScreenState();
}

class _AppFrontendScreenState extends State<AppFrontendScreen> {
  String? _source;
  Map<String, dynamic>? _manifest;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final bundle =
          await widget.dependencies.service.fetchBotFrontend(widget.bot.id);
      final decoded = jsonDecode(bundle);
      final manifest = decoded is Map ? decoded['manifest'] : null;
      final source = decoded is Map ? decoded['source'] : null;
      setState(() {
        _manifest = manifest is Map<String, dynamic> ? manifest : null;
        _source = source?.toString();
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_manifest != null
            ? '${widget.bot.name} v${_manifest!['version'] ?? '?'}'
            : widget.bot.name),
        actions: [
          if (_source != null)
            IconButton(
              tooltip: 'Reload app',
              icon: const Icon(Icons.refresh_rounded),
              onPressed: () {
                setState(() => _loading = true);
                _load();
              },
            ),
        ],
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const SkeletonPage();
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.error_outline_rounded,
                size: 44, color: AppColors.dangerOf(context)),
            const SizedBox(height: 12),
            const Text('Could not load the app',
                style: TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Text(_error!,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 16),
            FilledButton(onPressed: _load, child: const Text('Retry')),
          ]),
        ),
      );
    }
    if (_source == null || _source!.isEmpty) {
      return const Center(child: Text('This app has no screen.'));
    }
    final bridge = AppHostBridge(
      widget.dependencies.service,
      botId: widget.bot.id,
      userId: widget.dependencies.sessionController.session?.accountId ?? '',
      spaceId: widget.spaceId,
    );
    return ElpianVmWidget.fromCode(
      machineId: 'app-${widget.bot.id}',
      code: _source!,
      runtime: ElpianRuntime.quickJs,
      stylesheet: AppFrontendTheme.stylesheet(Theme.of(context)),
      hostHandlers: bridge.buildHostHandlers(),
      onUpdateApp: (data) {
        debugPrint('app updateApp: $data');
      },
    );
  }
}

/// Default QuickJS template shipped for newly created apps. It renders a
/// minimal card and echoes a backend call through `server.call`.
const String kDefaultAppTemplate = r'''
function MainComponent() {
  return { type: 'Column', props: { style: { padding: '20', gap: '12' } }, children: [
    { type: 'Text', props: { text: 'Hello from elpian', style: { fontSize: '22', fontWeight: 'bold' } } },
    { type: 'Text', props: { text: 'This app runs inside the Aseman sandbox.' } },
    { type: 'Button', props: { text: 'Call backend', className: 'primary' }, events: { tap: 'ping' } },
    { type: 'Text', key: 'reply', props: { text: 'Press the button to ask the backend.' } }
  ] };
}

function ping() {
  var raw = askHost('server.call', ['ping', { ts: Date.now() }]);
  var reply = 'no reply';
  try {
    var parsed = JSON.parse(raw);
    if (parsed && parsed.data && parsed.data.value != null) {
      reply = JSON.stringify(parsed.data.value);
    }
  } catch (e) { reply = 'parse error'; }
  askHost('updateApp', JSON.stringify({
    reply: reply
  }));
  askHost('render', JSON.stringify({
    type: 'Column', props: { style: { padding: '20', gap: '12' } }, children: [
      { type: 'Text', props: { text: 'Hello from elpian', style: { fontSize: '22', fontWeight: 'bold' } } },
      { type: 'Button', props: { text: 'Call backend', className: 'primary' }, events: { tap: 'ping' } },
      { type: 'Text', key: 'reply', props: { text: 'Backend says: ' + reply } }
    ]
  }));
}

askHost('render', JSON.stringify(MainComponent()));
''';
