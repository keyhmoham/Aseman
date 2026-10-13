import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import 'rich_post_content.dart';

/// Opens the markup post editor as a bottom sheet on mobile and a centered
/// modal on desktop. Returns the authored markdown string (or null if cancelled).
Future<String?> showPostEditor(
  BuildContext context, {
  String? initial,
  String? hint,
}) =>
    showMarkupEditor(context,
        initial: initial,
        hint: hint,
        title: 'Publish a post',
        publishLabel: 'Publish');

/// Opens the markup message designer used in the room chat, so users can design
/// rich messages (charts, cards, media, tables) with markdown before sending.
Future<String?> showMessageDesigner(
  BuildContext context, {
  String? initial,
  String? hint,
}) =>
    showMarkupEditor(context,
        initial: initial,
        hint: hint ??
            'Write your message in markdown…\n\nUse the toolbar above to add headings, lists, links, images, video, audio, charts and info cards.',
        title: 'Design a message',
        publishLabel: 'Send to chat',
        publishIcon: Icons.send_rounded);

/// Opens a generic markup editor as a bottom sheet on mobile and a centered
/// modal on desktop. Returns the authored markdown string (or null if cancelled).
Future<String?> showMarkupEditor(
  BuildContext context, {
  String? initial,
  String? hint,
  String title = 'Publish a post',
  String publishLabel = 'Publish',
  IconData publishIcon = Icons.publish_rounded,
}) async {
  final editor = _PostEditorDialog(
      initial: initial ?? '',
      hint: hint,
      title: title,
      publishLabel: publishLabel,
      publishIcon: publishIcon);
  if (MediaQuery.sizeOf(context).width < 820) {
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(30))),
      builder: (_) => FractionallySizedBox(heightFactor: .94, child: editor),
    );
  }
  return showDialog<String>(
    context: context,
    builder: (_) => Dialog(
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 860, maxHeight: 820),
        child: editor,
      ),
    ),
  );
}

class _PostEditorDialog extends StatefulWidget {
  const _PostEditorDialog({
    required this.initial,
    this.hint,
    this.title = 'Publish a post',
    this.publishLabel = 'Publish',
    this.publishIcon = Icons.publish_rounded,
  });
  final String initial;
  final String? hint;
  final String title;
  final String publishLabel;
  final IconData publishIcon;
  @override
  State<_PostEditorDialog> createState() => _PostEditorDialogState();
}

class _PostEditorDialogState extends State<_PostEditorDialog> {
  late final TextEditingController controller;
  bool _preview = false;

  @override
  void initState() {
    super.initState();
    controller = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void _insert(String snippet, {bool block = false}) {
    final text = controller.text;
    final sel = controller.selection;
    final at = sel.isValid ? sel.start : text.length;
    final needsSpace = block &&
        at > 0 &&
        text[at - 1] != '\n' &&
        !(text.endsWith('\n') && at == text.length);
    final prefix = needsSpace ? '\n\n' : '';
    final newText =
        text.substring(0, at) + prefix + snippet + text.substring(at);
    controller.text = newText;
    final caret =
        (at + prefix.length + snippet.length).clamp(0, newText.length);
    controller.selection = TextSelection.collapsed(offset: caret);
    setState(() {});
  }

  void _wrap(String left, String right, {String? selection}) {
    final text = controller.text;
    final sel = controller.selection;
    final start = sel.isValid ? sel.start : text.length;
    final end = sel.isValid ? sel.end : start;
    final selected =
        selection ?? (end > start ? text.substring(start, end) : 'text');
    final newText = text.substring(0, start) +
        left +
        selected +
        right +
        text.substring(end);
    controller.text = newText;
    controller.selection = TextSelection.collapsed(
        offset:
            (start + left.length + selected.length).clamp(0, newText.length));
    setState(() {});
  }

  void _promptUrl(String title, String label, void Function(String url) done) {
    final field = TextEditingController();
    showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: Text(title),
              content: TextField(
                controller: field,
                autofocus: true,
                decoration:
                    InputDecoration(labelText: label, hintText: 'https://…'),
              ),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Cancel')),
                FilledButton(
                    onPressed: () {
                      final v = field.text.trim();
                      Navigator.pop(ctx);
                      if (v.isNotEmpty) done(v);
                    },
                    child: const Text('Insert')),
              ],
            ));
  }

  void _insertChart() {
    _insert(
        ':::chart {"type":"bar","labels":["Q1","Q2","Q3","Q4"],"values":[12,18,15,24]}',
        block: true);
  }

  void _insertCard() {
    showDialog<String>(
        context: context,
        builder: (ctx) => SimpleDialog(
              title: const Text('Insert an info card'),
              children: [
                for (final (label, kind) in const [
                  ('Trader card', 'user'),
                  ('Agent card', 'agent'),
                  ('Tool card', 'tool'),
                  ('Workspace card', 'space'),
                ])
                  ListTile(
                    leading: Icon(switch (kind) {
                      'user' => Icons.person_rounded,
                      'agent' => Icons.smart_toy_rounded,
                      'tool' => Icons.extension_rounded,
                      _ => Icons.hub_rounded,
                    }),
                    title: Text(label),
                    onTap: () => Navigator.pop(ctx, kind),
                  ),
              ],
            )).then((kind) {
      if (kind == null || !mounted) return;
      final target = switch (kind) {
        'user' => '@handle',
        'agent' => 'AgentName',
        'tool' => 'ToolName',
        _ => 'WorkspaceName',
      };
      _insert(':::card $kind $target', block: true);
    });
  }

  List<Widget> _toolbar() {
    final scheme = Theme.of(context).colorScheme;
    final b = (
        {required IconData icon,
        required String tooltip,
        VoidCallback? onTap,
        bool active = false}) {
      return Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: active
                  ? scheme.primaryContainer
                  : scheme.surfaceContainerHighest.withValues(alpha: .6),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon,
                size: 17,
                color: active
                    ? scheme.onPrimaryContainer
                    : scheme.onSurfaceVariant),
          ),
        ),
      );
    };
    return [
      b(
          icon: Icons.title_rounded,
          tooltip: 'Heading',
          onTap: () => _insert('# Heading', block: true)),
      b(
          icon: Icons.format_bold_rounded,
          tooltip: 'Bold',
          onTap: () => _wrap('**', '**')),
      b(
          icon: Icons.format_italic_rounded,
          tooltip: 'Italic',
          onTap: () => _wrap('*', '*')),
      b(
          icon: Icons.format_strikethrough_rounded,
          tooltip: 'Strikethrough',
          onTap: () => _wrap('~~', '~~')),
      b(
          icon: Icons.code_rounded,
          tooltip: 'Inline code',
          onTap: () => _wrap('`', '`')),
      b(
          icon: Icons.format_quote_rounded,
          tooltip: 'Quote',
          onTap: () => _insert('> Quote', block: true)),
      b(
          icon: Icons.format_list_bulleted_rounded,
          tooltip: 'Bullet list',
          onTap: () => _insert('- item', block: true)),
      b(
          icon: Icons.format_list_numbered_rounded,
          tooltip: 'Numbered list',
          onTap: () => _insert('1. item', block: true)),
      b(
          icon: Icons.terminal_rounded,
          tooltip: 'Code block',
          onTap: () => _insert('```dart\n// code\n```', block: true)),
      b(
          icon: Icons.link_rounded,
          tooltip: 'Link',
          onTap: () => _promptUrl(
              'Insert link', 'URL', (url) => _insert('[text]($url)'))),
      b(
          icon: Icons.image_outlined,
          tooltip: 'Image',
          onTap: () => _promptUrl('Insert image', 'Image URL',
              (url) => _insert(':::image $url', block: true))),
      b(
          icon: Icons.videocam_outlined,
          tooltip: 'Video',
          onTap: () => _promptUrl('Insert video', 'Video URL',
              (url) => _insert(':::video $url', block: true))),
      b(
          icon: Icons.audio_file_rounded,
          tooltip: 'Audio',
          onTap: () => _promptUrl('Insert audio', 'Audio URL',
              (url) => _insert(':::audio $url', block: true))),
      b(icon: Icons.bar_chart_rounded, tooltip: 'Chart', onTap: _insertChart),
      b(
          icon: Icons.credit_card_rounded,
          tooltip: 'Info card',
          onTap: _insertCard),
      b(
          icon: Icons.table_chart_rounded,
          tooltip: 'Table',
          onTap: () => _insert('| A | B |\n|---|---|\n| 1 | 2 |', block: true)),
      b(
          icon: Icons.horizontal_rule_rounded,
          tooltip: 'Divider',
          onTap: () => _insert('---', block: true)),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(children: [
        Row(children: [
          const Icon(Icons.edit_note_rounded, size: 26),
          const SizedBox(width: 10),
          Expanded(
              child: Text(widget.title,
                  style: const TextStyle(
                      fontSize: 19, fontWeight: FontWeight.w900))),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('Write')),
              ButtonSegment(value: true, label: Text('Preview')),
            ],
            selected: {_preview},
            onSelectionChanged: (s) => setState(() => _preview = s.first),
            style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap),
          ),
          const SizedBox(width: 6),
          IconButton(
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close_rounded)),
        ]),
        const SizedBox(height: 10),
        SizedBox(
          height: 40,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: _toolbar().length,
            separatorBuilder: (_, __) => const SizedBox(width: 5),
            itemBuilder: (_, i) => _toolbar()[i],
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: _preview
              ? Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                      color:
                          scheme.surfaceContainerHighest.withValues(alpha: .5),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                          color: scheme.outlineVariant.withValues(alpha: .5))),
                  child: SingleChildScrollView(
                      child: controller.text.trim().isEmpty
                          ? const Text('Nothing to preview yet.',
                              style: TextStyle(
                                  color: AppColors.muted, fontSize: 12))
                          : RichPostContent(controller.text)),
                )
              : TextField(
                  controller: controller,
                  autofocus: true,
                  expands: true,
                  maxLines: null,
                  minLines: null,
                  textAlignVertical: TextAlignVertical.top,
                  decoration: InputDecoration(
                    hintText: widget.hint ??
                        'Write your post in markdown…\n\nUse the toolbar above to add headings, lists, links, images, video, audio, charts and info cards.',
                  ),
                ),
        ),
        const SizedBox(height: 10),
        Row(children: [
          Text('${controller.text.length} chars',
              style: const TextStyle(fontSize: 10, color: AppColors.muted)),
          const Spacer(),
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: () {
              final md = controller.text.trim();
              if (md.isEmpty) return;
              Navigator.pop(context, md);
            },
            icon: Icon(widget.publishIcon, size: 18),
            label: Text(widget.publishLabel),
          ),
        ]),
      ]),
    );
  }
}
