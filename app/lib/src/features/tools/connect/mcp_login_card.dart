import 'dart:async';

import 'package:flutter/material.dart';

import '../../../data/services/aseman_service.dart';
import '../domain/mcp_directory.dart';
import 'mcp_connect_dialog.dart';
import 'mcp_directory_view.dart';
import 'mcp_sign_in.dart';
import 'oauth_window.dart';

/// The login card: an app the person needs asks them to sign in, in the chat
/// (an agent added it, an agent called it, or the personal chat needs it). It
/// carries no credential. "Sign in" opens the app's own provider page; an app
/// that takes a key asks for it in a dialog; and once the person is connected
/// the card says so, wherever it is read again.
class McpLoginCardView extends StatefulWidget {
  const McpLoginCardView({
    super.key,
    required this.service,
    required this.card,
    this.sign,
  });

  final AsemanService service;
  final LoginCard card;

  /// Replaces the sign-in flow (tests).
  final McpSignIn? sign;

  @override
  State<McpLoginCardView> createState() => _McpLoginCardViewState();
}

class _McpLoginCardViewState extends State<McpLoginCardView> {
  LoginCardState _state = LoginCardState.loading;
  bool _busy = false;
  String? _problem;

  McpSignIn get _sign => widget.sign ?? McpSignIn(widget.service);

  @override
  void initState() {
    super.initState();
    unawaited(_read());
  }

  /// Whether the person is signed in is the node's to say.
  Future<void> _read() async {
    try {
      final c = await widget.service
          .toolConnection(widget.card.bot, widget.card.space);
      if (!mounted) return;
      setState(() => _state = loginCardState(
          loading: false,
          failed: false,
          auth: c.auth,
          connected: c.connected));
    } catch (_) {
      if (mounted) {
        setState(() => _state = loginCardState(loading: false, failed: true));
      }
    }
  }

  /// Runs inside the tap: on the web the sign-in window has to open before
  /// anything is awaited.
  Future<void> _signIn({bool reconnect = false}) async {
    final window = OAuthWindow.open();
    setState(() {
      _busy = true;
      _problem = null;
    });
    final card = widget.card;
    try {
      final out = await _sign.connect(context,
          botId: card.bot,
          spaceId: card.space,
          reconnect: reconnect,
          window: window);
      if (!mounted) return;
      if (out.needsToken) {
        await connectMcpTool(context, widget.service,
            botId: card.bot,
            spaceId: card.space,
            name: card.name,
            credential: out.credential.isEmpty
                ? card.credential
                : out.credential,
            startWithKey: true);
      }
    } on McpNeedsClient {
      if (!mounted) return;
      // The provider registers no clients: the dialog asks for one.
      await connectMcpTool(context, widget.service,
          botId: card.bot,
          spaceId: card.space,
          name: card.name,
          reconnect: reconnect);
    } catch (e) {
      if (mounted) setState(() => _problem = mcpSignInMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    unawaited(_read());
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final card = widget.card;
    final connected = _state == LoginCardState.connected;
    final open = _state == LoginCardState.open;
    final title = connected
        ? 'Signed in to ${card.name}'
        : open
            ? '${card.name} needs no sign-in'
            : 'Sign in to ${card.name}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(children: [
          Icon(connected ? Icons.check_circle_rounded : Icons.login_rounded,
              size: 18, color: scheme.primary),
          const SizedBox(width: 8),
          Expanded(
              child: Text(title,
                  style: const TextStyle(fontWeight: FontWeight.w800))),
        ]),
        if (card.reason.isNotEmpty && !connected) ...[
          const SizedBox(height: 4),
          Text(card.reason),
        ],
        const SizedBox(height: 8),
        if (_state == LoginCardState.loading)
          const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2))
        else if (connected)
          Row(children: [
            Text('Connected',
                style: TextStyle(
                    fontWeight: FontWeight.w700, color: scheme.primary)),
            const SizedBox(width: 12),
            InkWell(
              onTap: _busy ? null : () => _signIn(reconnect: true),
              child: Text('Use another account',
                  style: TextStyle(
                      fontSize: 12,
                      color: scheme.primary,
                      decoration: TextDecoration.underline)),
            ),
          ])
        else if (!open) ...[
          Text(
              'You sign in at ${card.name}’s own website. Nothing you sign in with is shown to the agents or kept in the chat.',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          const SizedBox(height: 8),
          Wrap(spacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
            FilledButton.icon(
              onPressed: _busy ? null : () => _signIn(),
              icon: _busy
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.login_rounded, size: 18),
              label: Text(_busy ? 'Waiting for sign-in…' : 'Sign in'),
            ),
            if (card.glamaUrl.isNotEmpty)
              ExternalLink(url: card.glamaUrl, label: 'View on Glama'),
          ]),
        ],
        if (_problem != null) ...[
          const SizedBox(height: 6),
          Text(_problem!, style: TextStyle(color: scheme.error, fontSize: 12)),
        ],
      ],
    );
  }
}
