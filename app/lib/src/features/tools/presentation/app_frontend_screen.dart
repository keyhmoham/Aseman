import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../../core/theme/app_colors.dart';
import '../../../data/models/bot.dart';
import '../../../elpian/elpian.dart';
import '../elpian/miniapp_bridge.dart';
import 'miniapp_theme.dart';

/// Full-screen sandbox that runs a miniapp's elpian frontend inside the
/// client. The frontend talks to its wasm backend through the user-signed
/// host bridge (message.ask / message.send). When [spaceId] is provided the
/// shared per-space sandbox bridge (sandbox.exec, sandbox.upload, …) is also
/// exposed so sandbox tooling (e.g. the file explorer) can drive the docker
/// sandbox. The app's color system is injected as a stylesheet so the frontend
/// follows the host theme.
class MiniappSandboxScreen extends StatefulWidget {
  const MiniappSandboxScreen({
    super.key,
    required this.dependencies,
    required this.bot,
    this.spaceId = '',
  });

  final AppDependencies dependencies;
  final Bot bot;
  final String spaceId;

  @override
  State<MiniappSandboxScreen> createState() => _MiniappSandboxScreenState();
}

class _MiniappSandboxScreenState extends State<MiniappSandboxScreen> {
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
              tooltip: 'Reload miniapp',
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
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.error_outline_rounded,
                size: 44, color: AppColors.danger),
            const SizedBox(height: 12),
            const Text('Could not load miniapp frontend',
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
      return const Center(child: Text('This miniapp has no frontend bundle.'));
    }
    final bridge = MiniappHostBridge(
      widget.dependencies.service,
      botId: widget.bot.id,
      userId: widget.dependencies.sessionController.session?.accountId ?? '',
      spaceId: widget.spaceId,
    );
    return ElpianVmWidget.fromCode(
      machineId: 'miniapp-${widget.bot.id}',
      code: _source!,
      runtime: ElpianRuntime.quickJs,
      stylesheet: MiniappTheme.stylesheet(Theme.of(context)),
      hostHandlers: bridge.buildHostHandlers(),
      onUpdateApp: (data) {
        debugPrint('miniapp updateApp: $data');
      },
    );
  }
}

/// Default QuickJS template shipped for newly created miniapps. It renders a
/// minimal card and echoes a backend call through `server.call`.
const String kDefaultMiniappTemplate = r'''
function MainComponent() {
  return { type: 'Column', props: { style: { padding: '20', gap: '12' } }, children: [
    { type: 'Text', props: { text: 'Hello from elpian', style: { fontSize: '22', fontWeight: 'bold' } } },
    { type: 'Text', props: { text: 'This miniapp runs inside the Tradera sandbox.' } },
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
