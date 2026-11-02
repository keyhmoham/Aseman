import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../../shared/widgets/overlay_panels.dart';
import 'admin_widgets.dart';

/// Admin: what people asked their Aseman / chat assistant.
Widget adminAILogPage(AppDependencies deps) => _Padded(_AILogPage(deps));

/// Admin: site email templates + preview.
Widget adminEmailTemplatesPage(AppDependencies deps) =>
    _Padded(_EmailTemplatesPage(deps));

class _Padded extends StatelessWidget {
  const _Padded(this.child);
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final gutter = MediaQuery.sizeOf(context).width < 600 ? 16.0 : 28.0;
    return ListView(
      padding: EdgeInsets.fromLTRB(gutter, 8, gutter, 48),
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: child,
        ),
      ],
    );
  }
}

class _AILogPage extends StatefulWidget {
  const _AILogPage(this.deps);
  final AppDependencies deps;
  @override
  State<_AILogPage> createState() => _AILogPageState();
}

class _AILogPageState extends State<_AILogPage> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _rows = const [];
  final _q = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await widget.deps.service.adminAILog(body: {
        if (_q.text.trim().isNotEmpty) 'q': _q.text.trim(),
        'limit': 50,
      });
      if (!mounted) return;
      final rows = res['rows'];
      setState(() {
        _rows = rows is List
            ? [
                for (final r in rows)
                  if (r is Map) r.cast<String, dynamic>()
              ]
            : const [];
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _q,
                decoration: const InputDecoration(
                  hintText: 'Search prompt or answer',
                  prefixIcon: Icon(Icons.search),
                  isDense: true,
                ),
                onSubmitted: (_) => _load(),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: 'Refresh',
              onPressed: _loading ? null : _load,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (_loading)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_error != null)
          Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))
        else if (_rows.isEmpty)
          const AdminEmptyState('No AI log rows',
              'Questions people ask their Aseman appear here.')
        else
          AdminSectionCard(
            title: 'Recent AI activity',
            child: Column(
              children: [
                for (final r in _rows)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      '${r['prompt'] ?? r['plan'] ?? 'Ask'}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text(
                      [
                        if ('${r['handle'] ?? ''}'.isNotEmpty)
                          '@${r['handle']}',
                        if ('${r['kind'] ?? ''}'.isNotEmpty) '${r['kind']}',
                        if ('${r['status'] ?? ''}'.isNotEmpty)
                          '${r['status']}',
                        if ('${r['created_at'] ?? ''}'.isNotEmpty)
                          '${r['created_at']}',
                      ].join(' · '),
                    ),
                    trailing: AdminStatusPill('${r['status'] ?? ''}'),
                    onTap: () => showAppDialog<void>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('AI log entry'),
                        content: SingleChildScrollView(
                          child: SelectableText(
                            'Prompt:\n${r['prompt'] ?? ''}\n\n'
                            'Answer:\n${r['answer'] ?? r['result'] ?? ''}',
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: const Text('Close'),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _EmailTemplatesPage extends StatefulWidget {
  const _EmailTemplatesPage(this.deps);
  final AppDependencies deps;
  @override
  State<_EmailTemplatesPage> createState() => _EmailTemplatesPageState();
}

class _EmailTemplatesPageState extends State<_EmailTemplatesPage> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _templates = const [];
  String? _preview;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await widget.deps.service.emailTemplates();
      if (!mounted) return;
      final t = res['templates'];
      setState(() {
        _templates = t is List
            ? [
                for (final row in t)
                  if (row is Map) row.cast<String, dynamic>()
              ]
            : const [];
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _previewTemplate(String key) async {
    try {
      final res = await widget.deps.service.emailPreview(key);
      if (!mounted) return;
      setState(() {
        _preview =
            '${res['subject'] ?? key}\n\n${res['html'] ?? res['text'] ?? res['body'] ?? res}';
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null) {
      return Text(_error!,
          style: TextStyle(color: Theme.of(context).colorScheme.error));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AdminSectionCard(
          title: 'Email templates',
          subtitle: 'Site emails the node may send. Preview with sample values.',
          child: _templates.isEmpty
              ? const Text('No templates configured.')
              : Column(
                  children: [
                    for (final t in _templates)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text('${t['name'] ?? t['key'] ?? 'Email'}',
                            style:
                                const TextStyle(fontWeight: FontWeight.w700)),
                        subtitle: Text(
                          '${t['description'] ?? (t['content'] is Map ? (t['content'] as Map)['subject'] : '')}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: TextButton(
                          onPressed: () =>
                              _previewTemplate('${t['key'] ?? ''}'),
                          child: const Text('Preview'),
                        ),
                      ),
                  ],
                ),
        ),
        if (_preview != null) ...[
          const SizedBox(height: 16),
          AdminSectionCard(
            title: 'Preview',
            child: SelectableText(_preview!,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
          ),
        ],
      ],
    );
  }
}
