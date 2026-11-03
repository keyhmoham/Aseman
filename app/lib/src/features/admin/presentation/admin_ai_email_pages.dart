import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../../shared/widgets/overlay_panels.dart';
import '../../../shared/widgets/skeleton.dart';
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
                  if (r is Map) r.cast<String, dynamic>(),
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

  void _open(Map<String, dynamic> r) {
    showAppDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('AI log entry'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: SelectableText(
              'Prompt:\n${r['prompt'] ?? ''}\n\n'
              'Answer:\n${r['answer'] ?? r['result'] ?? ''}',
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AdminSearchField(
          controller: _q,
          hint: 'Search prompt or answer',
          onChanged: (_) => setState(() {}),
          trailing: IconButton.filledTonal(
            tooltip: 'Search',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.search_rounded),
          ),
        ),
        const SizedBox(height: 16),
        if (_loading && _rows.isEmpty)
          const SkeletonList(itemCount: 5)
        else if (_error != null)
          AdminEmptyState(
            'Could not load AI log',
            _error!,
            icon: Icons.cloud_off_rounded,
          )
        else if (_rows.isEmpty)
          const AdminEmptyState(
            'No AI log rows',
            'Questions people ask their Aseman appear here.',
            icon: Icons.history_edu_outlined,
          )
        else
          AdminSectionCard(
            title: 'Recent AI activity',
            icon: Icons.history_edu_rounded,
            subtitle: '${_rows.length} most recent entries',
            trailing: IconButton(
              tooltip: 'Refresh',
              onPressed: _loading ? null : _load,
              icon: const Icon(Icons.refresh_rounded),
            ),
            child: Column(
              children: [
                for (final r in _rows)
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(vertical: 4),
                    leading: AdminAvatar(
                      '${r['handle'] ?? r['kind'] ?? 'AI'}',
                      icon: Icons.auto_awesome_rounded,
                    ),
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
                        if ('${r['created_at'] ?? ''}'.isNotEmpty)
                          '${r['created_at']}',
                      ].join(' · '),
                    ),
                    trailing: AdminStatusPill('${r['status'] ?? ''}'),
                    onTap: () => _open(r),
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
                  if (row is Map) row.cast<String, dynamic>(),
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

  Future<void> _previewTemplate(String key, String title) async {
    try {
      final res = await widget.deps.service.emailPreview(key);
      if (!mounted) return;
      final body =
          '${res['subject'] ?? key}\n\n${res['html'] ?? res['text'] ?? res['body'] ?? res}';
      await showAppDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: SelectableText(
                body,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const SkeletonList(itemCount: 4);
    if (_error != null) {
      return AdminEmptyState(
        'Could not load templates',
        _error!,
        icon: Icons.cloud_off_rounded,
      );
    }
    return AdminSectionCard(
      title: 'Email templates',
      icon: Icons.email_rounded,
      subtitle: 'Site emails the node may send. Preview with sample values.',
      trailing: IconButton(
        tooltip: 'Refresh',
        onPressed: _load,
        icon: const Icon(Icons.refresh_rounded),
      ),
      child: _templates.isEmpty
          ? const AdminEmptyState(
              'No templates configured',
              'When the node registers site emails they appear here.',
              icon: Icons.email_outlined,
            )
          : Column(
              children: [
                for (final t in _templates)
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(vertical: 4),
                    leading: AdminAvatar(
                      '${t['name'] ?? t['key'] ?? 'Email'}',
                      icon: Icons.mark_email_read_outlined,
                    ),
                    title: Text(
                      '${t['name'] ?? t['key'] ?? 'Email'}',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text(
                      '${t['description'] ?? (t['content'] is Map ? (t['content'] as Map)['subject'] : '')}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: FilledButton.tonal(
                      onPressed: () => _previewTemplate(
                        '${t['key'] ?? ''}',
                        '${t['name'] ?? t['key'] ?? 'Preview'}',
                      ),
                      child: const Text('Preview'),
                    ),
                  ),
              ],
            ),
    );
  }
}
