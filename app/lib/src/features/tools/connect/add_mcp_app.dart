import 'package:flutter/material.dart';

import '../../../data/models/bot.dart';
import '../../../data/services/tradera_service.dart';
import 'mcp_connect_dialog.dart';
import 'mcp_sign_in.dart';

/// Adds an MCP app to the space [spaceId]: one from the catalog, or a server
/// the person names by its address. An app that runs with each person's own
/// account asks them to sign in right after it is added. Returns whether
/// something was added.
Future<bool> showAddMcpApp(BuildContext context, TraderaService service,
        {required String spaceId}) async =>
    await showDialog<bool>(
        context: context,
        builder: (_) => AddMcpAppDialog(service: service, spaceId: spaceId)) ==
    true;

/// Whether registering a server failed because the server wants a sign-in.
bool mcpNeedsSignIn(Object error) =>
    RegExp(r'HTTP 40[13]\b|unauthor|forbidden', caseSensitive: false)
        .hasMatch('$error');

/// Why a server could not be added, in words a person can act on.
String mcpAddFailure(Object error) {
  final text = '$error';
  if (RegExp(r'HTTP 404').hasMatch(text)) {
    return 'That address answered “not found”. Check the path: most servers end in /mcp.';
  }
  if (RegExp(r'HTTP 30\d').hasMatch(text)) {
    return 'That address redirects somewhere else. Paste the final address.';
  }
  if (RegExp(r'HTTP 40[56]|no JSON-RPC result|initialization was refused')
      .hasMatch(text)) {
    return 'That address answered, but not as an MCP server. Check that it is the server’s MCP endpoint.';
  }
  if (RegExp(r'not reachable|no such host|timeout|deadline|connection refused',
          caseSensitive: false)
      .hasMatch(text)) {
    return 'The server could not be reached from here. Check the address, and that it is on the public internet.';
  }
  return mcpSignInMessage(error);
}

class AddMcpAppDialog extends StatefulWidget {
  const AddMcpAppDialog(
      {super.key, required this.service, required this.spaceId});
  final TraderaService service;
  final String spaceId;

  @override
  State<AddMcpAppDialog> createState() => _AddMcpAppDialogState();
}

class _AddMcpAppDialogState extends State<AddMcpAppDialog> {
  final _name = TextEditingController();
  final _url = TextEditingController();
  List<({String id, String name, String auth})> _catalog = const [];
  bool _loading = true;
  String? _busy; // what is being added, by id ('custom' for a new server)
  String? _step;
  String? _error;
  bool _added = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait<Object>([
        widget.service.mcpCatalog(),
        widget.service.fetchSpaceBots(widget.spaceId),
      ]);
      final inSpace = {for (final b in results[1] as List<Bot>) b.id};
      if (!mounted) return;
      setState(() {
        _catalog = [
          for (final t
              in results[0] as List<({String id, String name, String auth})>)
            if (!inSpace.contains(t.id)) t
        ];
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = mcpSignInMessage(e);
        });
      }
    }
  }

  /// Adds the app to the space, then asks for the person's sign-in when it
  /// runs with each person's own account.
  Future<void> _attach(String botId, String name, String auth) async {
    setState(() => _step = 'Adding $name…');
    await widget.service.addBotToSpace(widget.spaceId, botId);
    _added = true;
    if (!mounted) return;
    setState(() => _step = null);
    if (auth == 'user') {
      await connectMcpTool(context, widget.service,
          botId: botId, spaceId: widget.spaceId, name: name);
    }
    if (mounted) Navigator.of(context).pop(true);
  }

  Future<void> _addFromCatalog(
      ({String id, String name, String auth}) t) async {
    setState(() {
      _busy = t.id;
      _error = null;
    });
    try {
      await _attach(t.id, t.name.isEmpty ? 'this app' : t.name, t.auth);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = null;
          _step = null;
          _error = mcpAddFailure(e);
        });
      }
    }
  }

  Future<void> _addServer() async {
    final url = _url.text.trim();
    var name = _name.text.trim();
    if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(url)) {
      setState(() => _error = 'Paste the server’s https address.');
      return;
    }
    if (name.isEmpty) name = Uri.tryParse(url)?.host ?? 'My app';
    setState(() {
      _busy = 'custom';
      _error = null;
      _step = 'Checking the server…';
    });
    try {
      // A bare address says nothing about sign-in. Many servers are open, so
      // try it as it is (the node only registers a server that answers) and
      // ask for each person's sign-in only when the server asks for one.
      var auth = '';
      String botId;
      try {
        botId = await widget.service.mcpRegister(
            name: name,
            url: url,
            descriptor: {'description': 'An app connected for this space.'});
      } catch (e) {
        if (!mcpNeedsSignIn(e)) rethrow;
        if (mounted) setState(() => _step = 'This app needs you to sign in…');
        auth = 'user';
        botId = await widget.service.mcpRegister(
            name: name,
            url: url,
            auth: 'user',
            descriptor: {
              'description': 'An app connected for this space.',
              'mcp_oauth': 'auto'
            });
      }
      await _attach(botId, name, auth);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = null;
          _step = null;
          _error = mcpAddFailure(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final busy = _busy != null;
    return AlertDialog(
      icon: const Icon(Icons.extension_outlined),
      title: const Text('Add an app'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                    'Apps (MCP servers) give this space’s agents and people new tools. One that runs with each person’s own account asks you to sign in once it is added.',
                    style: TextStyle(color: scheme.onSurfaceVariant)),
                const SizedBox(height: 16),
                const Text('From the catalog',
                    style: TextStyle(fontWeight: FontWeight.w800)),
                const SizedBox(height: 6),
                if (_loading)
                  const Padding(
                      padding: EdgeInsets.all(12),
                      child: Center(child: CircularProgressIndicator()))
                else if (_catalog.isEmpty)
                  Text('Nothing new to add from the catalog.',
                      style: TextStyle(color: scheme.onSurfaceVariant))
                else
                  for (final t in _catalog)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.hub_outlined),
                      title: Text(t.name.isEmpty ? t.id : t.name),
                      subtitle: Text(t.auth == 'user'
                          ? 'Sign in with your own account'
                          : 'Ready to use'),
                      trailing: _busy == t.id
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : FilledButton.tonal(
                              onPressed: busy ? null : () => _addFromCatalog(t),
                              child: const Text('Add')),
                    ),
                const Divider(height: 28),
                const Text('Connect another server',
                    style: TextStyle(fontWeight: FontWeight.w800)),
                const SizedBox(height: 10),
                TextField(
                    controller: _name,
                    enabled: !busy,
                    decoration: const InputDecoration(
                        labelText: 'Name',
                        hintText: 'GitHub',
                        border: OutlineInputBorder())),
                const SizedBox(height: 10),
                TextField(
                    controller: _url,
                    enabled: !busy,
                    keyboardType: TextInputType.url,
                    onSubmitted: (_) => busy ? null : _addServer(),
                    decoration: const InputDecoration(
                        labelText: 'Server address',
                        hintText: 'https://example.com/mcp',
                        border: OutlineInputBorder())),
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.icon(
                      onPressed: busy ? null : _addServer,
                      icon: _busy == 'custom'
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.add_link_rounded),
                      label: const Text('Add server')),
                ),
                if (_step != null) ...[
                  const SizedBox(height: 8),
                  Text(_step!,
                      style: TextStyle(color: scheme.onSurfaceVariant)),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(_error!, style: TextStyle(color: scheme.error)),
                ],
              ]),
        ),
      ),
      actions: [
        TextButton(
            onPressed: busy ? null : () => Navigator.of(context).pop(_added),
            child: const Text('Close')),
      ],
    );
  }
}
