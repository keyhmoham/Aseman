import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../data/services/aseman_service.dart';
import '../domain/mcp_directory.dart';
import 'mcp_connect_dialog.dart';
import 'mcp_sign_in.dart';
import 'oauth_window.dart';

/// Why adding a server failed, in words a person can act on.
String mcpInstallFailure(Object error) {
  final text = '$error';
  if (RegExp(r'could not be reached|having trouble|not answering',
          caseSensitive: false)
      .hasMatch(text)) {
    return mcpSignInMessage(error);
  }
  if (RegExp(r'not as an MCP server').hasMatch(text)) {
    return 'That app answered, but not as an MCP server. It may have moved: try another.';
  }
  return mcpSignInMessage(error);
}

/// A link out of the app (Glama's licence asks that listings are linked).
class ExternalLink extends StatelessWidget {
  const ExternalLink({super.key, required this.url, required this.label});
  final String url;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () {
        final uri = Uri.tryParse(url);
        if (uri != null && uri.hasScheme) {
          unawaited(launchUrl(uri, mode: LaunchMode.externalApplication));
        }
      },
      child: Text(label,
          style: TextStyle(
              fontSize: 12,
              color: scheme.primary,
              decoration: TextDecoration.underline)),
    );
  }
}

/// Browse the Glama directory of MCP servers and add one to a space with one
/// tap. The node reads the directory; the person signs in at the app's own
/// website (or pastes its key) and the connection is theirs, in every space.
class McpDirectoryView extends StatefulWidget {
  const McpDirectoryView({
    super.key,
    required this.service,
    required this.spaceId,
    required this.installed,
    required this.onInstalled,
    this.sign,
  });

  final AsemanService service;
  final String spaceId;

  /// Keys of the directory servers this space already has.
  final Set<String> installed;

  /// A server was added (or connected): the space's lists are read again.
  final VoidCallback onInstalled;

  /// Replaces the sign-in flow (tests).
  final McpSignIn? sign;

  @override
  State<McpDirectoryView> createState() => _McpDirectoryViewState();
}

class _McpDirectoryViewState extends State<McpDirectoryView> {
  final _search = TextEditingController();
  Timer? _debounce;
  bool? _enabled;
  String? _failed;
  List<GlamaFilter> _attributes = const [];
  String _filter = 'all';
  final _pages = <GlamaPage>[];
  bool _loading = true;
  bool _loadingMore = false;
  String _term = '';
  String? _open; // the server whose detail is open
  final _details = <String, GlamaConnector>{};
  String? _busy;
  String? _message;
  final _added = <String>{};

  McpSignIn get _sign => widget.sign ?? McpSignIn(widget.service);

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    try {
      final enabled = await widget.service.glamaEnabled();
      if (!mounted) return;
      setState(() => _enabled = enabled);
      if (!enabled) return;
      try {
        final attributes = await widget.service.glamaAttributes();
        if (mounted) setState(() => _attributes = attributes);
      } catch (_) {
        // Filters are an extra: the search stands alone.
      }
      await _run();
    } catch (e) {
      if (mounted) setState(() => _failed = mcpSignInMessage(e));
    }
  }

  List<String> get _filterAttributes => authFilters(_attributes)
      .firstWhere((f) => f.id == _filter,
          orElse: () => (id: 'all', label: 'All', attributes: const <String>[]))
      .attributes;

  Future<void> _run() async {
    setState(() {
      _loading = true;
      _failed = null;
    });
    try {
      final page = await widget.service
          .glamaSearch(query: _term, attributes: _filterAttributes);
      if (!mounted) return;
      setState(() {
        _pages
          ..clear()
          ..add(page);
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _failed = mcpSignInMessage(e);
        });
      }
    }
  }

  Future<void> _more() async {
    final last = _pages.isEmpty ? null : _pages.last;
    if (last == null || !last.hasMore || _loadingMore) return;
    setState(() => _loadingMore = true);
    try {
      final page = await widget.service.glamaSearch(
          query: _term, attributes: _filterAttributes, after: last.next);
      if (mounted) setState(() => _pages.add(page));
    } catch (e) {
      if (mounted) setState(() => _message = mcpSignInMessage(e));
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  void _typed(String raw) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      final term = searchTerm(raw);
      if (term == _term) return;
      _term = term;
      unawaited(_run());
    });
  }

  Future<void> _toggle(GlamaConnector c) async {
    if (_open == c.key) {
      setState(() => _open = null);
      return;
    }
    setState(() => _open = c.key);
    if (_details.containsKey(c.key)) return;
    try {
      final detail = await widget.service.glamaGet(c.key);
      if (mounted) setState(() => _details[c.key] = detail);
    } catch (_) {
      // The row already says what it can.
    }
  }

  /// Adds the server, then signs the person in when it wants that. The
  /// sign-in window opens in this very tap, before anything is awaited.
  Future<void> _add(GlamaConnector c) async {
    setState(() {
      _busy = c.key;
      _message = null;
    });
    final window = c.auth == 'oauth2' ? OAuthWindow.open() : null;
    try {
      final res = await widget.service
          .mcpInstall(spaceId: widget.spaceId, key: c.key);
      _added.add(c.key);
      widget.onInstalled();
      final next = res.next;
      if (!mounted) return;
      if (next.kind == 'oauth') {
        try {
          final out = await _sign.connect(context,
              botId: res.botId, spaceId: widget.spaceId, window: window);
          if (!mounted) return;
          if (out.needsToken) {
            await connectMcpTool(context, widget.service,
                botId: res.botId,
                spaceId: widget.spaceId,
                name: res.name,
                credential: out.credential,
                startWithKey: true);
          }
        } on McpNeedsClient {
          if (!mounted) return;
          // The provider registers no clients: the dialog asks for one.
          await connectMcpTool(context, widget.service,
              botId: res.botId, spaceId: widget.spaceId, name: res.name);
        } catch (e) {
          if (mounted) {
            setState(() => _message =
                '${res.name} was added, but signing in did not finish: ${mcpSignInMessage(e)}');
          }
        }
      } else {
        window?.close();
        if (next.kind == 'token') {
          await connectMcpTool(context, widget.service,
              botId: res.botId,
              spaceId: widget.spaceId,
              name: res.name,
              credential: next.credential,
              startWithKey: true);
        }
      }
      widget.onInstalled();
    } catch (e) {
      window?.close();
      if (mounted) setState(() => _message = mcpInstallFailure(e));
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_enabled == null && _failed == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (_enabled == false || (_enabled == null && _failed != null)) {
      return Text(
        _failed != null
            ? 'The MCP directory could not be reached just now.'
            : 'The MCP directory is not set up on this node yet. An administrator adds a Glama API key. You can still connect an app by its address below.',
        style: TextStyle(color: scheme.onSurfaceVariant),
      );
    }
    final rows = mergePages(_pages);
    final filters = authFilters(_attributes);
    final last = _pages.isEmpty ? null : _pages.last;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      TextField(
        controller: _search,
        onChanged: _typed,
        textInputAction: TextInputAction.search,
        decoration: const InputDecoration(
          prefixIcon: Icon(Icons.search_rounded),
          hintText: 'Search apps (GitHub, tickets, payments…)',
          border: OutlineInputBorder(),
          isDense: true,
        ),
      ),
      if (filters.length > 1) ...[
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 4, children: [
          for (final f in filters)
            ChoiceChip(
              label: Text(f.label),
              selected: f.id == _filter,
              onSelected: (_) {
                setState(() => _filter = f.id);
                unawaited(_run());
              },
            ),
        ]),
      ],
      const SizedBox(height: 6),
      if (_loading)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 16),
          child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
        )
      else if (_failed != null)
        Row(children: [
          Expanded(
              child: Text(_failed!, style: TextStyle(color: scheme.error))),
          TextButton(onPressed: _run, child: const Text('Try again')),
        ])
      else if (rows.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(
              _term.isEmpty
                  ? 'Nothing is listed for this filter.'
                  : 'No matching apps. Try a different word, or connect the app by its address below.',
              style: TextStyle(color: scheme.onSurfaceVariant)),
        )
      else
        for (final c in rows) _row(context, c),
      if (last != null && last.hasMore)
        Center(
          child: TextButton(
            onPressed: _loadingMore ? null : _more,
            child: _loadingMore
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Show more'),
          ),
        ),
      if (_message != null) ...[
        const SizedBox(height: 6),
        Text(_message!, style: TextStyle(color: scheme.error)),
      ],
      const SizedBox(height: 6),
      // Glama's licence: a visible credit on every screen that shows its data.
      Center(
          child:
              ExternalLink(url: glamaCredit.url, label: glamaCredit.text)),
    ]);
  }

  Widget _row(BuildContext context, GlamaConnector c) {
    final scheme = Theme.of(context).colorScheme;
    final has = widget.installed.contains(c.key) || _added.contains(c.key);
    final open = _open == c.key;
    final detail = _details[c.key] ?? c;
    final tools = toolPreview(detail.tools);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      ListTile(
        contentPadding: EdgeInsets.zero,
        onTap: () => _toggle(c),
        leading: CircleAvatar(
          radius: 18,
          backgroundColor: scheme.primary.withValues(alpha: .14),
          foregroundImage:
              c.thumbnail.isEmpty ? null : NetworkImage(c.thumbnail),
          child: Text(c.name.isEmpty ? '?' : c.name[0].toUpperCase()),
        ),
        title: Row(children: [
          Flexible(child: Text(c.name, overflow: TextOverflow.ellipsis)),
          if (c.boosted) ...[
            const SizedBox(width: 6),
            Text('Promoted',
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
          ],
        ]),
        subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (c.description.isNotEmpty)
            Text(c.description, maxLines: 2, overflow: TextOverflow.ellipsis),
          Wrap(spacing: 10, children: [
            Text(c.summary,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            ExternalLink(url: c.glamaUrl, label: 'View on Glama'),
          ]),
        ]),
        trailing: _busy == c.key
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2))
            : has
                ? Text('Added',
                    style: TextStyle(color: scheme.onSurfaceVariant))
                : FilledButton.tonal(
                    onPressed: _busy != null ? null : () => _add(c),
                    child: const Text('Add')),
      ),
      if (open)
        Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(authSentence(c.auth)),
            if (tools.shown.isNotEmpty) ...[
              const SizedBox(height: 8),
              const Text('What it can do',
                  style: TextStyle(fontWeight: FontWeight.w700)),
              for (final t in tools.shown)
                Text('${t.label}${t.description.isEmpty ? '' : ' — ${t.description}'}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12, color: scheme.onSurfaceVariant)),
              if (tools.more > 0)
                Text('and ${tools.more} more',
                    style: TextStyle(
                        fontSize: 12, color: scheme.onSurfaceVariant)),
            ],
            const SizedBox(height: 8),
            Wrap(spacing: 12, children: [
              if (c.qualityLabel.isNotEmpty)
                Text('Tool quality ${c.qualityLabel}',
                    style: TextStyle(
                        fontSize: 12, color: scheme.onSurfaceVariant)),
              if (detail.repository.isNotEmpty)
                ExternalLink(url: detail.repository, label: 'Source'),
              if (detail.docs.isNotEmpty)
                ExternalLink(url: detail.docs, label: 'Docs'),
            ]),
          ]),
        ),
    ]);
  }
}
