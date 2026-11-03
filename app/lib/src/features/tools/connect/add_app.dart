import 'package:flutter/material.dart';

import '../../../core/theme/theme_roles.dart';
import '../../../data/models/bot.dart';
import '../../../data/services/aseman_service.dart';
import '../../../shared/widgets/app_form.dart';
import '../../../shared/widgets/bot_avatar.dart';
import '../../../shared/widgets/skeleton.dart';
import 'mcp_connect_dialog.dart';
import 'mcp_sign_in.dart';

/// Adds an app to the space [spaceId]: one from the node's catalog, one the
/// person made, or an MCP server the person names by its address. An app that runs with each person's own
/// account asks them to sign in right after it is added. Returns whether
/// something was added. Opens as a dialog on wide screens and a bottom sheet
/// on phones, like the app's other forms.
Future<bool> showAddApp(BuildContext context, AsemanService service,
        {required String spaceId}) async =>
    await showAppForm<bool>(
        context, AddAppDialog(service: service, spaceId: spaceId)) ==
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

class AddAppDialog extends StatefulWidget {
  const AddAppDialog({super.key, required this.service, required this.spaceId});
  final AsemanService service;
  final String spaceId;

  @override
  State<AddAppDialog> createState() => _AddAppDialogState();
}

class _AddAppDialogState extends State<AddAppDialog> {
  final _name = TextEditingController();
  final _url = TextEditingController();
  List<({String id, String name, String auth, String avatar})> _catalog = const [];
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
        // The person's own apps; best-effort, the catalog stands alone.
        widget.service.fetchBots().catchError((_) => const <Bot>[]),
      ]);
      final inSpace = {for (final b in results[1] as List<Bot>) b.id};
      final catalog =
          results[0] as List<({String id, String name, String auth, String avatar})>;
      final listed = {for (final t in catalog) t.id};
      if (!mounted) return;
      setState(() {
        _catalog = [
          for (final t in catalog)
            if (!inSpace.contains(t.id)) t,
          for (final b in results[2] as List<Bot>)
            if (b.isTool &&
                !b.isSandbox &&
                !inSpace.contains(b.id) &&
                !listed.contains(b.id))
              (id: b.id, name: b.name, auth: '', avatar: b.avatar),
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
  /// runs with each person's own account. A cancelled sign-in takes the app
  /// back out, so the space only gets apps the person finished adding.
  Future<void> _attach(String botId, String name, String auth) async {
    setState(() => _step = 'Adding $name…');
    await widget.service.addBotToSpace(widget.spaceId, botId);
    if (!mounted) return;
    setState(() => _step = null);
    if (personalApp(auth)) {
      final connected = await connectMcpTool(context, widget.service,
          botId: botId, spaceId: widget.spaceId, name: name);
      if (!connected) {
        try {
          await widget.service.removeBotFromSpace(widget.spaceId, botId);
        } catch (_) {
          // It is still in the space; let the caller show it.
          _added = true;
          rethrow;
        }
        if (mounted) {
          setState(() {
            _busy = null;
            _error = 'Sign-in was cancelled, so $name was not added.';
          });
        }
        return;
      }
    }
    _added = true;
    if (mounted) Navigator.of(context).pop(true);
  }

  Future<void> _addFromCatalog(
      ({String id, String name, String auth, String avatar}) t) async {
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
    final compact = MediaQuery.sizeOf(context).width < 600;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Flexible(
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(24, compact ? 4 : 24, 24, 8),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 52,
              height: 52,
              decoration: ShapeDecoration(
                color: ThemeRoles.wellFill(context),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18)),
              ),
              child: Icon(Icons.extension_outlined,
                  color: ThemeRoles.wellInk(context), size: 26),
            ),
            const SizedBox(height: 16),
            const Text('Add an app',
                style: TextStyle(
                    fontSize: 24,
                    height: 1.15,
                    letterSpacing: -.4,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Text(
                'Apps give this space’s agents and people new abilities. One that runs with each person’s own account asks you to sign in once it is added.',
                style: TextStyle(
                    fontSize: 14, height: 1.4, color: scheme.onSurfaceVariant)),
            const SizedBox(height: 22),
            const Text('Apps you can add',
                style: TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            if (_loading)
              const SkeletonList(itemCount: 3, padding: EdgeInsets.zero)
            else if (_catalog.isEmpty)
              Text('Every available app is already here.',
                  style: TextStyle(color: scheme.onSurfaceVariant))
            else
              for (final t in _catalog)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: BotAvatar.fromFields(
                    id: t.id,
                    name: t.name.isEmpty ? t.id : t.name,
                    kind: 'tool',
                    avatar: t.avatar,
                    radius: 14,
                  ),
                  title: Text(t.name.isEmpty ? t.id : t.name),
                  subtitle: Text(personalApp(t.auth)
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
            const Text('Or connect an MCP server',
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
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 20),
        child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          TextButton(
              onPressed: busy ? null : () => Navigator.of(context).pop(_added),
              child: const Text('Close')),
        ]),
      ),
    ]);
  }
}
