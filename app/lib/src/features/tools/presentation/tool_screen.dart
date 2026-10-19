import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../../data/models/bot.dart';
import '../../../shared/widgets/status_tag.dart';
import '../connect/mcp_connect_dialog.dart';
import '../data/tools_api.dart';
import '../domain/tool_models.dart';
import 'tool_frontend_view.dart';

/// A tool opened full screen in a space: its frontend, what its backend is,
/// and — for its owner — regenerating a generated frontend.
class ToolScreen extends StatefulWidget {
  const ToolScreen({
    super.key,
    required this.dependencies,
    required this.bot,
    required this.spaceId,
    this.roomId = '',
  });

  final AppDependencies dependencies;
  final Bot bot;
  final String spaceId;
  final String roomId;

  @override
  State<ToolScreen> createState() => _ToolScreenState();
}

class _ToolScreenState extends State<ToolScreen> {
  late final ToolsApi _api = ToolsApi.of(widget.dependencies.service);
  ToolInfo? _info;
  ToolFrontendPayload? _payload;

  /// Times the owner asked for the frontend to be generated again.
  int _generations = 0;

  /// For a tool each person connects with their own account: whether the
  /// caller has connected it in this space (null until known).
  bool? _connected;

  String get _me =>
      widget.dependencies.sessionController.session?.accountId ?? '';

  @override
  void initState() {
    super.initState();
    _api.get(widget.bot.id).then((info) {
      if (mounted) setState(() => _info = info);
      if (info.auth == 'user' && widget.spaceId.isNotEmpty) _checkConnection();
    }).catchError((Object _) {});
  }

  Future<void> _checkConnection() async {
    try {
      final state = await widget.dependencies.service
          .toolConnection(widget.bot.id, widget.spaceId);
      if (mounted) setState(() => _connected = state.connected);
    } catch (_) {}
  }

  Future<void> _connect() async {
    final ok = await connectMcpTool(context, widget.dependencies.service,
        botId: widget.bot.id,
        spaceId: widget.spaceId,
        name: widget.bot.name,
        reconnect: _connected == true);
    if (ok && mounted) {
      setState(() {
        _connected = true;
        _generations++; // reload what the tool shows, now as the person
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    final owner = widget.bot.ownerId.isNotEmpty && widget.bot.ownerId == _me;
    return Scaffold(
      appBar: AppBar(
        title: Text(_payload?.title.isNotEmpty == true
            ? _payload!.title
            : widget.bot.name),
        actions: [
          if (info != null) ...[
            StatusTag(info.mode.label.toUpperCase(),
                Theme.of(context).colorScheme.primary),
            const SizedBox(width: 6),
            if (info.hasFrontend)
              StatusTag(info.frontendMode.label.toUpperCase(),
                  Theme.of(context).colorScheme.tertiary),
          ],
          if (_connected != null)
            IconButton(
              tooltip: _connected!
                  ? 'Reconnect your account'
                  : 'Connect your account',
              icon: Icon(
                  _connected! ? Icons.link_rounded : Icons.link_off_rounded),
              onPressed: _connect,
            ),
          if (owner && info?.frontendMode == FrontendMode.generative)
            IconButton(
              tooltip: 'Generate the frontend again',
              icon: const Icon(Icons.auto_awesome_rounded),
              onPressed: () => setState(() => _generations++),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: ToolFrontendView(
        key: ValueKey('${widget.bot.id}/$_generations'),
        api: _api,
        botId: widget.bot.id,
        spaceId: widget.spaceId,
        roomId: widget.roomId,
        userId: _me,
        regenerate: _generations > 0,
        onConnected: () {
          if (mounted) setState(() => _connected = true);
        },
        onLoaded: (p) {
          if (mounted) setState(() => _payload = p);
        },
      ),
    );
  }
}
