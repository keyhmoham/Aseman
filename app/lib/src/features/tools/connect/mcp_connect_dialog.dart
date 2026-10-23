import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/app_shape.dart';
import '../../../data/services/aseman_service.dart';
import 'mcp_sign_in.dart';
import '../../../shared/widgets/overlay_panels.dart';

/// Asks the person to connect their own account to the tool [botId] in the
/// project [spaceId]: sign in with the provider (OAuth), with an OAuth client
/// they created when the provider requires one, or with a token. Returns
/// whether it is connected.
Future<bool> connectMcpTool(
  BuildContext context,
  AsemanService service, {
  required String botId,
  required String spaceId,
  required String name,
  bool reconnect = false,
  OAuthOpener? open,
}) async =>
    await showAppDialog<bool>(
      context: context,
      builder: (_) => McpConnectDialog(
          sign: McpSignIn(service),
          botId: botId,
          spaceId: spaceId,
          name: name,
          reconnect: reconnect,
          open: open),
    ) ==
    true;

/// After a per-person tool is added to a project, asks to connect it when the
/// caller has not yet. Returns whether it ends up connected (true for a tool
/// everyone shares).
Future<bool> connectMcpToolIfNeeded(
  BuildContext context,
  AsemanService service, {
  required String botId,
  required String spaceId,
  required String name,
}) async {
  try {
    final state = await service.toolConnection(botId, spaceId);
    if (state.auth != 'user' || state.connected) return true;
  } catch (_) {
    return false; // not an MCP tool, or the node could not say
  }
  if (!context.mounted) return false;
  return connectMcpTool(context, service,
      botId: botId, spaceId: spaceId, name: name);
}

class McpConnectDialog extends StatefulWidget {
  const McpConnectDialog(
      {super.key,
      required this.sign,
      required this.botId,
      required this.spaceId,
      required this.name,
      this.reconnect = false,
      this.open});

  final McpSignIn sign;
  final String botId;
  final String spaceId;
  final String name;
  final bool reconnect;
  final OAuthOpener? open;

  @override
  State<McpConnectDialog> createState() => _McpConnectDialogState();
}

class _McpConnectDialogState extends State<McpConnectDialog> {
  final _token = TextEditingController();
  final _clientId = TextEditingController();
  final _clientSecret = TextEditingController();
  bool _busy = false;
  bool _tokenMode = false;
  String? _error;

  /// Set when the provider wants an OAuth client: the redirect to create it with.
  String? _clientRedirect;

  @override
  void dispose() {
    _token.dispose();
    _clientId.dispose();
    _clientSecret.dispose();
    super.dispose();
  }

  // Runs inside the tap: on the web the sign-in window has to open before
  // anything is awaited.
  Future<void> _signIn() async {
    if (_clientRedirect != null && _clientId.text.trim().isEmpty) {
      setState(() => _error = 'Paste the client id you created first.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.sign.connect(context,
          botId: widget.botId,
          spaceId: widget.spaceId,
          clientId: _clientId.text.trim(),
          clientSecret: _clientSecret.text.trim(),
          open: widget.open);
      if (mounted) Navigator.of(context).pop(true);
    } on McpNeedsClient catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _clientRedirect = e.redirectUri;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = mcpSignInMessage(e);
        });
      }
    }
  }

  Future<void> _saveToken() async {
    if (_token.text.trim().isEmpty) {
      setState(() => _error = 'Paste a token first.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.sign
          .connectWithToken(widget.botId, widget.spaceId, _token.text);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = mcpSignInMessage(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final redirect = _clientRedirect;
    return AlertDialog(
      icon: const Icon(Icons.link_rounded),
      title: Text(widget.reconnect
          ? 'Reconnect ${widget.name}'
          : 'Connect ${widget.name}'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                    'Each person connects their own ${widget.name} account. Agents and you then use it in this project as you.',
                    style: TextStyle(color: scheme.onSurfaceVariant)),
                const SizedBox(height: 16),
                if (!_tokenMode) ...[
                  if (redirect != null) ...[
                    Text(
                        'This provider needs an OAuth client you create. Give it this redirect address, then paste the client id.',
                        style: TextStyle(color: scheme.onSurface)),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
                      decoration: BoxDecoration(
                          color: scheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(AppShape.inner)),
                      child: Row(children: [
                        Expanded(
                            child: SelectableText(redirect,
                                style: const TextStyle(
                                    fontFamily: 'monospace', fontSize: 12))),
                        IconButton(
                            tooltip: 'Copy redirect address',
                            onPressed: () => Clipboard.setData(
                                ClipboardData(text: redirect)),
                            icon: const Icon(Icons.copy_rounded, size: 18)),
                      ]),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                        controller: _clientId,
                        decoration: const InputDecoration(
                            labelText: 'Client id',
                            border: OutlineInputBorder())),
                    const SizedBox(height: 10),
                    TextField(
                        controller: _clientSecret,
                        obscureText: true,
                        decoration: const InputDecoration(
                            labelText: 'Client secret (if it has one)',
                            border: OutlineInputBorder())),
                    const SizedBox(height: 14),
                  ],
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                        onPressed: _busy ? null : _signIn,
                        icon: _busy
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.login_rounded),
                        label: Text('Sign in with ${widget.name}')),
                  ),
                  const SizedBox(height: 8),
                  Center(
                    child: TextButton(
                        onPressed: _busy
                            ? null
                            : () => setState(() {
                                  _tokenMode = true;
                                  _error = null;
                                }),
                        child: const Text('Use an access token instead')),
                  ),
                ] else ...[
                  TextField(
                      controller: _token,
                      obscureText: true,
                      autofocus: true,
                      decoration: const InputDecoration(
                          labelText: 'Access token',
                          helperText:
                              'A personal token from the provider. It is stored encrypted on the node.',
                          border: OutlineInputBorder())),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                        onPressed: _busy ? null : _saveToken,
                        child: const Text('Save connection')),
                  ),
                  Center(
                    child: TextButton(
                        onPressed: _busy
                            ? null
                            : () => setState(() {
                                  _tokenMode = false;
                                  _error = null;
                                }),
                        child: const Text('Sign in instead')),
                  ),
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
            onPressed: _busy ? null : () => Navigator.of(context).pop(false),
            child: const Text('Not now')),
      ],
    );
  }
}
