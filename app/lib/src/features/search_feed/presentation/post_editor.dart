import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../shared/widgets/overlay_panels.dart';
import 'markup_document.dart';
import 'rich_post_content.dart';

/// The most a post's body may hold (the server's limit).
const postMaxLength = 4000;

/// Opens the visual post designer as a bottom sheet on mobile and a centered
/// modal on desktop. Returns the designed post as markdown (null if
/// cancelled). [initial] opens an existing post for editing.
Future<String?> showPostEditor(
  BuildContext context, {
  String? initial,
  String? hint,
  String title = 'Create a post',
  String publishLabel = 'Publish',
}) => showMarkupEditor(
  context,
  initial: initial,
  hint: hint,
  title: title,
  publishLabel: publishLabel,
  maxLength: postMaxLength,
);

/// Opens the visual message designer used in chats, so users can design rich
/// messages (headings, lists, tables, charts, media, cards) before sending.
Future<String?> showMessageDesigner(
  BuildContext context, {
  String? initial,
  String? hint,
}) => showMarkupEditor(
  context,
  initial: initial,
  hint: hint ?? 'Write your message…',
  title: 'Design a message',
  publishLabel: 'Send to chat',
  publishIcon: Icons.send_rounded,
);

/// Opens the visual markup designer as a bottom sheet on mobile and a
/// centered modal on desktop. Every element of a post is a block with its
/// own controls; a Markdown tab stays for those who prefer writing it.
/// Returns the authored markdown (null if cancelled).
Future<String?> showMarkupEditor(
  BuildContext context, {
  String? initial,
  String? hint,
  String title = 'Create a post',
  String publishLabel = 'Publish',
  IconData publishIcon = Icons.publish_rounded,
  int? maxLength,
}) => showAdaptivePanel<String>(
  context,
  MarkupDesigner(
    initial: initial ?? '',
    hint: hint,
    title: title,
    publishLabel: publishLabel,
    publishIcon: publishIcon,
    maxLength: maxLength,
  ),
  breakpoint: 820,
  maxWidth: 1180,
  maxHeight: 860,
  heightFactor: .96,
);

enum _Mode { design, preview, markdown }

class MarkupDesigner extends StatefulWidget {
  const MarkupDesigner({
    super.key,
    required this.initial,
    this.hint,
    this.title = 'Create a post',
    this.publishLabel = 'Publish',
    this.publishIcon = Icons.publish_rounded,
    this.maxLength,
  });
  final String initial;
  final String? hint;
  final String title;
  final String publishLabel;
  final IconData publishIcon;
  final int? maxLength;

  @override
  State<MarkupDesigner> createState() => _MarkupDesignerState();
}

class _MarkupDesignerState extends State<MarkupDesigner> {
  late List<DesignBlock> _blocks;
  final _raw = TextEditingController();
  _Mode _mode = _Mode.design;

  /// The text field the formatting bar acts on, and its block.
  MarkupTextController? _activeText;
  DesignBlock? _activeBlock;

  /// The block whose first field takes the focus once it is built.
  Key? _focusOnBuild;

  @override
  void initState() {
    super.initState();
    _blocks = markupToDesign(widget.initial);
    if (_blocks.isEmpty) _blocks = [DesignBlock(DesignKind.paragraph)];
    _focusOnBuild = _blocks.first.key;
    _listen(_blocks);
  }

  @override
  void dispose() {
    for (final b in _blocks) {
      b.dispose();
    }
    _raw.dispose();
    super.dispose();
  }

  /// The controllers already rebuilding the designer.
  final _listened = <Listenable>{};

  void _listen(Iterable<DesignBlock> blocks) {
    // Rebuilt on every edit so the preview, counter and buttons follow.
    for (final b in blocks) {
      for (final l in [
        b.text,
        b.url,
        b.target,
        ...b.items,
        for (final row in b.cells) ...row,
        for (final (l, v) in b.points) ...[l, v],
      ]) {
        if (_listened.add(l)) l.addListener(_changed);
      }
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  String get _markup =>
      _mode == _Mode.markdown ? _raw.text.trim() : designToMarkup(_blocks);

  bool get _tooLong =>
      widget.maxLength != null && _markup.length > widget.maxLength!;

  void _setMode(_Mode mode) {
    if (mode == _mode) return;
    setState(() {
      if (mode == _Mode.markdown) {
        _raw.text = designToMarkup(_blocks);
      } else if (_mode == _Mode.markdown) {
        for (final b in _blocks) {
          b.dispose();
        }
        _blocks = markupToDesign(_raw.text);
        if (_blocks.isEmpty) _blocks = [DesignBlock(DesignKind.paragraph)];
        _listen(_blocks);
        _activeText = null;
        _activeBlock = null;
      }
      _mode = mode;
    });
  }

  /// Adds a block of [kind] after the block being edited (or at the end).
  void _add(DesignKind kind) {
    final block = DesignBlock.empty(kind);
    _listen([block]);
    setState(() {
      final at = _activeBlock == null ? -1 : _blocks.indexOf(_activeBlock!);
      // An empty paragraph being edited is replaced rather than left behind.
      final active = at < 0 ? null : _activeBlock;
      if (active != null &&
          active.kind == DesignKind.paragraph &&
          active.isEmpty &&
          kind != DesignKind.paragraph) {
        _blocks[at] = block;
        active.dispose();
      } else {
        _blocks.insert(at < 0 ? _blocks.length : at + 1, block);
      }
      _activeBlock = block;
      _activeText = block.kind.isText ? block.text : null;
      _focusOnBuild = block.key;
      if (_mode != _Mode.design) _mode = _Mode.design;
    });
  }

  void _remove(DesignBlock block) {
    setState(() {
      _blocks.remove(block);
      if (_activeBlock == block) {
        _activeBlock = null;
        _activeText = null;
      }
      if (_blocks.isEmpty) {
        final b = DesignBlock(DesignKind.paragraph);
        _listen([b]);
        _blocks.add(b);
      }
    });
    block.dispose();
  }

  void _duplicate(DesignBlock block) {
    final copy = block.duplicate();
    _listen([copy]);
    setState(() => _blocks.insert(_blocks.indexOf(block) + 1, copy));
  }

  void _move(DesignBlock block, int by) {
    final from = _blocks.indexOf(block);
    final to = (from + by).clamp(0, _blocks.length - 1);
    if (from == to) return;
    setState(() {
      _blocks.removeAt(from);
      _blocks.insert(to, block);
    });
  }

  /// Notes the block being edited and, when it is one, its formatted text
  /// field ([text] is null for a block's other fields).
  void _focus(DesignBlock block, MarkupTextController? text) {
    final next = text ?? (_activeBlock == block ? _activeText : null);
    if (_activeBlock == block && _activeText == next) return;
    setState(() {
      _activeBlock = block;
      _activeText = next;
    });
  }

  void _publish() {
    final md = _markup;
    if (md.isEmpty || _tooLong) return;
    Navigator.pop(context, md);
  }

  Future<void> _insertLink() async {
    final target = _activeText;
    if (target == null) return;
    final link = await showAppDialog<(String, String)>(
      context: context,
      builder: (_) => _LinkDialog(label: target.selectedText),
    );
    if (link == null) return;
    final (label, url) = link;
    target.insert('[${label.isEmpty ? url : label}]($url)');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, box) {
        final wide = box.maxWidth >= 980;
        final mode = wide && _mode == _Mode.preview ? _Mode.design : _mode;
        final editor = switch (mode) {
          _Mode.markdown => _markdownEditor(scheme),
          _Mode.preview => _Preview(markup: _markup),
          _Mode.design => _designer(scheme),
        };
        return CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.keyB, control: true): () =>
                _activeText?.toggleWrap('**', '**'),
            const SingleActivator(LogicalKeyboardKey.keyB, meta: true): () =>
                _activeText?.toggleWrap('**', '**'),
            const SingleActivator(LogicalKeyboardKey.keyI, control: true): () =>
                _activeText?.toggleWrap('*', '*'),
            const SingleActivator(LogicalKeyboardKey.keyI, meta: true): () =>
                _activeText?.toggleWrap('*', '*'),
            const SingleActivator(LogicalKeyboardKey.enter, control: true):
                _publish,
            const SingleActivator(LogicalKeyboardKey.enter, meta: true):
                _publish,
          },
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Column(
              children: [
                _header(wide, box.maxWidth < 520),
                const SizedBox(height: 10),
                if (mode != _Mode.preview) ...[
                  _Palette(onAdd: _add),
                  const SizedBox(height: 8),
                ],
                if (mode == _Mode.design)
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 150),
                    child: _activeText == null
                        ? const SizedBox(width: double.infinity)
                        : Container(
                            alignment: Alignment.centerLeft,
                            padding: const EdgeInsets.only(bottom: 8),
                            child: _FormatBar(
                              controller: _activeText!,
                              onLink: _insertLink,
                            ),
                          ),
                  ),
                Expanded(
                  child: wide && mode != _Mode.markdown
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(flex: 6, child: editor),
                            const SizedBox(width: 14),
                            Expanded(
                              flex: 5,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.only(
                                      left: 4,
                                      bottom: 6,
                                    ),
                                    child: Text(
                                      'LIVE PREVIEW',
                                      style: TextStyle(
                                        fontSize: 10.5,
                                        letterSpacing: 1,
                                        fontWeight: FontWeight.w800,
                                        color: scheme.onSurfaceVariant,
                                      ),
                                    ),
                                  ),
                                  Expanded(child: _Preview(markup: _markup)),
                                ],
                              ),
                            ),
                          ],
                        )
                      : editor,
                ),
                const SizedBox(height: 10),
                _footer(scheme, box.maxWidth < 520),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _header(bool wide, bool narrow) => Row(
    children: [
      if (!narrow) ...[
        const Icon(Icons.auto_awesome_mosaic_rounded, size: 24),
        const SizedBox(width: 10),
      ],
      Expanded(
        child: Text(
          widget.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w900),
        ),
      ),
      SegmentedButton<_Mode>(
        showSelectedIcon: false,
        segments: [
          ButtonSegment(
            value: _Mode.design,
            icon: const Icon(Icons.dashboard_customize_outlined, size: 17),
            tooltip: 'Design',
            label: narrow ? null : const Text('Design'),
          ),
          if (!wide)
            ButtonSegment(
              value: _Mode.preview,
              icon: const Icon(Icons.visibility_outlined, size: 17),
              tooltip: 'Preview',
              label: narrow ? null : const Text('Preview'),
            ),
          ButtonSegment(
            value: _Mode.markdown,
            icon: const Icon(Icons.code_rounded, size: 17),
            tooltip: 'Markdown',
            label: wide ? const Text('Markdown') : null,
          ),
        ],
        selected: {wide && _mode == _Mode.preview ? _Mode.design : _mode},
        onSelectionChanged: (s) => _setMode(s.first),
        style: const ButtonStyle(
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
      const SizedBox(width: 4),
      IconButton(
        tooltip: 'Close',
        onPressed: () => Navigator.pop(context),
        icon: const Icon(Icons.close_rounded),
      ),
    ],
  );

  Widget _designer(ColorScheme scheme) => ReorderableListView.builder(
    buildDefaultDragHandles: false,
    padding: const EdgeInsets.only(bottom: 12),
    itemCount: _blocks.length,
    onReorder: (from, to) => setState(() {
      final b = _blocks.removeAt(from);
      _blocks.insert(to > from ? to - 1 : to, b);
    }),
    proxyDecorator: (child, _, animation) => Material(
      color: Colors.transparent,
      elevation: 6,
      borderRadius: BorderRadius.circular(16),
      child: child,
    ),
    itemBuilder: (context, i) {
      final b = _blocks[i];
      final focus = _focusOnBuild == b.key;
      if (focus) _focusOnBuild = null;
      return _BlockCard(
        key: b.key,
        index: i,
        block: b,
        active: _activeBlock == b,
        first: i == 0,
        last: i == _blocks.length - 1,
        autofocus: focus,
        hint: i == 0 ? widget.hint : null,
        onFocus: (text) => _focus(b, text),
        onRemove: () => _remove(b),
        onDuplicate: () => _duplicate(b),
        onMove: (by) => _move(b, by),
        onChanged: () => setState(() {}),
        onConvert: (to) => setState(() {
          b.convert(to);
          _listen([b]);
        }),
      );
    },
  );

  Widget _markdownEditor(ColorScheme scheme) => TextField(
    controller: _raw,
    expands: true,
    maxLines: null,
    minLines: null,
    onChanged: (_) => setState(() {}),
    textAlignVertical: TextAlignVertical.top,
    style: const TextStyle(fontFamily: 'monospace', fontSize: 13, height: 1.5),
    decoration: InputDecoration(
      hintText: 'Markdown, for those who prefer writing it…',
      helperText:
          'Switch back to Design to edit each element with its own controls.',
      filled: true,
      fillColor: scheme.surfaceContainerHighest.withValues(alpha: .4),
    ),
  );

  Widget _footer(ColorScheme scheme, bool narrow) {
    final length = _markup.length;
    final max = widget.maxLength;
    final empty = _markup.isEmpty;
    return Row(
      children: [
        if (max != null) ...[
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              value: (length / max).clamp(0, 1).toDouble(),
              strokeWidth: 2.5,
              backgroundColor: scheme.surfaceContainerHighest,
              color: _tooLong
                  ? scheme.error
                  : length > max * .9
                  ? Colors.orange
                  : scheme.primary,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _tooLong ? '${length - max} over the limit' : '$length / $max',
            style: TextStyle(
              fontSize: 11.5,
              color: _tooLong ? scheme.error : scheme.onSurfaceVariant,
            ),
          ),
        ] else
          Text(
            '${_blocks.where((b) => !b.isEmpty).length} blocks',
            style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
          ),
        const Spacer(),
        // On a phone the header's close button cancels.
        if (!narrow) ...[
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          const SizedBox(width: 8),
        ],
        FilledButton.icon(
          onPressed: empty || _tooLong ? null : _publish,
          icon: Icon(widget.publishIcon, size: 18),
          label: Text(widget.publishLabel),
        ),
      ],
    );
  }
}

/// The blocks a post can hold, as buttons that add one.
class _Palette extends StatelessWidget {
  const _Palette({required this.onAdd});
  final ValueChanged<DesignKind> onAdd;

  static const kinds = [
    DesignKind.paragraph,
    DesignKind.heading,
    DesignKind.bullets,
    DesignKind.numbers,
    DesignKind.quote,
    DesignKind.table,
    DesignKind.chart,
    DesignKind.image,
    DesignKind.video,
    DesignKind.audio,
    DesignKind.card,
    DesignKind.code,
    DesignKind.divider,
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final k in kinds)
          Tooltip(
            message: 'Add ${k.label.toLowerCase()}',
            child: Material(
              color: scheme.surfaceContainerHighest.withValues(alpha: .6),
              shape: const StadiumBorder(),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => onAdd(k),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 9,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(k.icon, size: 17, color: scheme.primary),
                      const SizedBox(width: 6),
                      Text(
                        k.label,
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Bold, italic, strikethrough, code, link and mention for the text being
/// edited; each wraps (or unwraps) the selection.
class _FormatBar extends StatelessWidget {
  const _FormatBar({required this.controller, required this.onLink});
  final MarkupTextController controller;
  final VoidCallback onLink;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget button(IconData icon, String tip, VoidCallback onTap) => IconButton(
      tooltip: tip,
      visualDensity: VisualDensity.compact,
      iconSize: 19,
      onPressed: onTap,
      icon: Icon(icon),
    );
    // Inside the text fields' tap region: tapping a button keeps the field
    // focused, its selection and the phone's keyboard.
    return TextFieldTapRegion(
      child: Container(
        decoration: BoxDecoration(
          color: scheme.primaryContainer.withValues(alpha: .35),
          borderRadius: BorderRadius.circular(14),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 0,
          runSpacing: 0,
          children: [
            button(
              Icons.format_bold_rounded,
              'Bold (Ctrl+B)',
              () => controller.toggleWrap('**', '**'),
            ),
            button(
              Icons.format_italic_rounded,
              'Italic (Ctrl+I)',
              () => controller.toggleWrap('*', '*'),
            ),
            button(
              Icons.format_strikethrough_rounded,
              'Strikethrough',
              () => controller.toggleWrap('~~', '~~'),
            ),
            button(
              Icons.code_rounded,
              'Inline code',
              () => controller.toggleWrap('`', '`', placeholder: 'code'),
            ),
            button(Icons.link_rounded, 'Link', onLink),
            button(
              Icons.alternate_email_rounded,
              'Mention',
              () => controller.insert('@'),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                'Select text, then format it',
                style: TextStyle(
                  fontSize: 11.5,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One block of the designer: its kind, its own editor and its actions.
class _BlockCard extends StatelessWidget {
  const _BlockCard({
    super.key,
    required this.index,
    required this.block,
    required this.active,
    required this.first,
    required this.last,
    required this.autofocus,
    required this.onFocus,
    required this.onRemove,
    required this.onDuplicate,
    required this.onMove,
    required this.onChanged,
    required this.onConvert,
    this.hint,
  });
  final int index;
  final DesignBlock block;
  final bool active, first, last, autofocus;
  final String? hint;
  final ValueChanged<MarkupTextController?> onFocus;
  final VoidCallback onRemove, onDuplicate, onChanged;
  final ValueChanged<int> onMove;
  final ValueChanged<DesignKind> onConvert;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Focus(
        skipTraversal: true,
        canRequestFocus: false,
        onFocusChange: (has) {
          if (has) onFocus(null);
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          decoration: BoxDecoration(
            color: active
                ? scheme.surfaceContainerLow
                : scheme.surfaceContainerLow.withValues(alpha: .6),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: active
                  ? scheme.primary.withValues(alpha: .7)
                  : scheme.outlineVariant.withValues(alpha: .45),
              width: active ? 1.5 : 1,
            ),
          ),
          padding: const EdgeInsets.fromLTRB(6, 4, 6, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  ReorderableDragStartListener(
                    index: index,
                    child: MouseRegion(
                      cursor: SystemMouseCursors.grab,
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: Icon(
                          Icons.drag_indicator_rounded,
                          size: 18,
                          color: scheme.outline,
                        ),
                      ),
                    ),
                  ),
                  Icon(block.kind.icon, size: 16, color: scheme.primary),
                  const SizedBox(width: 6),
                  Text(
                    block.kind.label,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: _headerControls(context, scheme)),
                  _BlockMenu(
                    first: first,
                    last: last,
                    kind: block.kind,
                    onRemove: onRemove,
                    onDuplicate: onDuplicate,
                    onMove: onMove,
                    onConvert: onConvert,
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 2, 8, 0),
                child: _editor(context, scheme),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Controls that belong in the block's header: a heading's level, a
  /// list's kind, a chart's type, a code block's language.
  Widget _headerControls(BuildContext context, ColorScheme scheme) {
    Widget chips<T>(
      List<(T, String)> options,
      T selected,
      ValueChanged<T> on,
    ) => Align(
      alignment: Alignment.centerLeft,
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: [
          for (final (value, label) in options)
            ChoiceChip(
              label: Text(label, style: const TextStyle(fontSize: 11.5)),
              selected: value == selected,
              showCheckmark: false,
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              onSelected: (_) => on(value),
            ),
        ],
      ),
    );
    switch (block.kind) {
      case DesignKind.heading:
        return chips(
          [(1, 'H1'), (2, 'H2'), (3, 'H3')],
          block.level.clamp(1, 3),
          (v) {
            block.level = v;
            onChanged();
          },
        );
      case DesignKind.bullets:
      case DesignKind.numbers:
        return chips(
          [
            (DesignKind.bullets, '• Bullets'),
            (DesignKind.numbers, '1. Numbers'),
          ],
          block.kind,
          onConvert,
        );
      case DesignKind.chart:
        return chips([('bar', 'Bars'), ('line', 'Line')], block.chartType, (v) {
          block.chartType = v;
          onChanged();
        });
      case DesignKind.code:
        return Align(
          alignment: Alignment.centerLeft,
          child: DropdownButton<String>(
            value: designCodeLanguages.contains(block.language)
                ? block.language
                : '',
            isDense: true,
            underline: const SizedBox.shrink(),
            borderRadius: BorderRadius.circular(12),
            style: TextStyle(fontSize: 12, color: scheme.onSurface),
            items: [
              for (final l in designCodeLanguages)
                DropdownMenuItem(
                  value: l,
                  child: Text(l.isEmpty ? 'Plain text' : l),
                ),
            ],
            onChanged: (v) {
              block.language = v ?? '';
              onChanged();
            },
          ),
        );
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _editor(BuildContext context, ColorScheme scheme) {
    InputDecoration plain(String hint) => InputDecoration(
      hintText: hint,
      isDense: true,
      filled: false,
      border: InputBorder.none,
      enabledBorder: InputBorder.none,
      focusedBorder: InputBorder.none,
      contentPadding: const EdgeInsets.symmetric(vertical: 8),
    );
    Widget text(
      MarkupTextController c, {
      required String hint,
      TextStyle? style,
      bool autofocus = false,
      int? maxLines,
      TextInputAction? action,
      ValueChanged<String>? onSubmitted,
    }) => Focus(
      onFocusChange: (has) {
        if (has) onFocus(c);
      },
      child: TextField(
        controller: c,
        autofocus: autofocus,
        minLines: 1,
        maxLines: maxLines,
        textInputAction: action,
        onSubmitted: onSubmitted,
        textCapitalization: TextCapitalization.sentences,
        style: style ?? const TextStyle(fontSize: 15, height: 1.45),
        decoration: plain(hint),
      ),
    );
    switch (block.kind) {
      case DesignKind.paragraph:
        return text(
          block.text,
          hint: hint ?? 'Write something…',
          autofocus: autofocus,
        );
      case DesignKind.heading:
        return text(
          block.text,
          hint: 'Heading',
          autofocus: autofocus,
          maxLines: 2,
          style: TextStyle(
            fontSize: switch (block.level) {
              1 => 22.0,
              2 => 19.0,
              _ => 16.5,
            },
            fontWeight: FontWeight.w900,
            height: 1.25,
          ),
        );
      case DesignKind.quote:
        return Container(
          padding: const EdgeInsets.only(left: 12),
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: scheme.primary, width: 3)),
          ),
          child: text(
            block.text,
            hint: 'A quote worth sharing',
            autofocus: autofocus,
            style: TextStyle(
              fontSize: 15,
              height: 1.45,
              fontStyle: FontStyle.italic,
              color: scheme.onSurfaceVariant,
            ),
          ),
        );
      case DesignKind.bullets:
      case DesignKind.numbers:
        return _ListEditor(
          block: block,
          autofocus: autofocus,
          onFocus: onFocus,
          onChanged: onChanged,
          decoration: plain,
        );
      case DesignKind.code:
      case DesignKind.raw:
        return Container(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: .6),
            borderRadius: BorderRadius.circular(10),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Focus(
            onFocusChange: (has) {
              if (has) onFocus(null);
            },
            child: TextField(
              controller: block.text,
              autofocus: autofocus,
              minLines: 3,
              maxLines: 14,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12.5,
                height: 1.45,
              ),
              decoration: plain(
                block.kind == DesignKind.code
                    ? '// Paste or write code'
                    : 'Markup',
              ),
            ),
          ),
        );
      case DesignKind.table:
        return _TableEditor(block: block, onChanged: onChanged);
      case DesignKind.chart:
        return _ChartEditor(block: block, onChanged: onChanged);
      case DesignKind.image:
      case DesignKind.video:
      case DesignKind.audio:
        return _MediaEditor(block: block, autofocus: autofocus);
      case DesignKind.card:
        return _CardEditor(
          block: block,
          autofocus: autofocus,
          onChanged: onChanged,
        );
      case DesignKind.divider:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Divider(
            height: 1,
            color: scheme.outlineVariant.withValues(alpha: .8),
          ),
        );
    }
  }
}

class _BlockMenu extends StatelessWidget {
  const _BlockMenu({
    required this.first,
    required this.last,
    required this.kind,
    required this.onRemove,
    required this.onDuplicate,
    required this.onMove,
    required this.onConvert,
  });
  final bool first, last;
  final DesignKind kind;
  final VoidCallback onRemove, onDuplicate;
  final ValueChanged<int> onMove;
  final ValueChanged<DesignKind> onConvert;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    PopupMenuItem<VoidCallback> item(
      IconData icon,
      String label,
      VoidCallback on, {
      bool enabled = true,
      Color? color,
    }) => PopupMenuItem(
      value: on,
      enabled: enabled,
      child: ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: Icon(icon, size: 20, color: color),
        title: Text(label, style: TextStyle(color: color)),
      ),
    );
    final turnInto = [
      if (kind.isText || kind.isList)
        for (final k in [
          DesignKind.paragraph,
          DesignKind.heading,
          DesignKind.quote,
          DesignKind.bullets,
          DesignKind.numbers,
        ])
          if (k != kind) k,
    ];
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: 'Remove block',
          visualDensity: VisualDensity.compact,
          iconSize: 18,
          onPressed: onRemove,
          icon: Icon(Icons.delete_outline_rounded, color: scheme.outline),
        ),
        PopupMenuButton<VoidCallback>(
          tooltip: 'Block actions',
          icon: Icon(Icons.more_vert_rounded, size: 18, color: scheme.outline),
          onSelected: (on) => on(),
          itemBuilder: (_) => [
            item(
              Icons.arrow_upward_rounded,
              'Move up',
              () => onMove(-1),
              enabled: !first,
            ),
            item(
              Icons.arrow_downward_rounded,
              'Move down',
              () => onMove(1),
              enabled: !last,
            ),
            item(Icons.copy_all_rounded, 'Duplicate', onDuplicate),
            if (turnInto.isNotEmpty) ...[
              const PopupMenuDivider(),
              for (final k in turnInto)
                item(
                  k.icon,
                  'Turn into ${k.label.toLowerCase()}',
                  () => onConvert(k),
                ),
            ],
            const PopupMenuDivider(),
            item(
              Icons.delete_outline_rounded,
              'Remove',
              onRemove,
              color: scheme.error,
            ),
          ],
        ),
      ],
    );
  }
}

/// A list's items, each its own line with a bullet or number; Enter adds
/// the next item.
class _ListEditor extends StatefulWidget {
  const _ListEditor({
    required this.block,
    required this.autofocus,
    required this.onFocus,
    required this.onChanged,
    required this.decoration,
  });
  final DesignBlock block;
  final bool autofocus;
  final ValueChanged<MarkupTextController?> onFocus;
  final VoidCallback onChanged;
  final InputDecoration Function(String hint) decoration;

  @override
  State<_ListEditor> createState() => _ListEditorState();
}

class _ListEditorState extends State<_ListEditor> {
  final _nodes = <MarkupTextController, FocusNode>{};

  FocusNode _node(MarkupTextController c) => _nodes.putIfAbsent(c, () {
    final n = FocusNode();
    n.addListener(() {
      if (n.hasFocus) widget.onFocus(c);
    });
    return n;
  });

  @override
  void dispose() {
    for (final n in _nodes.values) {
      n.dispose();
    }
    super.dispose();
  }

  void _addAfter(int i) {
    final c = MarkupTextController();
    c.addListener(widget.onChanged);
    setState(() => widget.block.items.insert(i + 1, c));
    widget.onChanged();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _node(c).requestFocus(),
    );
  }

  void _remove(int i) {
    final items = widget.block.items;
    if (items.length == 1) {
      items.first.clear();
      return;
    }
    final c = items.removeAt(i);
    _nodes.remove(c)?.dispose();
    setState(() {});
    widget.onChanged();
    c.dispose();
    final next = items[(i - 1).clamp(0, items.length - 1)];
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _node(next).requestFocus(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final items = widget.block.items;
    final numbered = widget.block.kind == DesignKind.numbers;
    return Column(
      children: [
        for (var i = 0; i < items.length; i++)
          Row(
            children: [
              SizedBox(
                width: 26,
                child: Text(
                  numbered ? '${i + 1}.' : '•',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: scheme.primary,
                  ),
                ),
              ),
              Expanded(
                child: CallbackShortcuts(
                  bindings: {
                    const SingleActivator(LogicalKeyboardKey.backspace): () {
                      if (items[i].text.isEmpty) {
                        _remove(i);
                      } else {
                        // Not handled: let the field delete a character.
                        final c = items[i];
                        final sel = c.selection;
                        if (sel.isValid) {
                          final start = sel.isCollapsed
                              ? sel.start - 1
                              : sel.start;
                          if (start >= 0) {
                            c.value = TextEditingValue(
                              text:
                                  c.text.substring(0, start) +
                                  c.text.substring(sel.end),
                              selection: TextSelection.collapsed(offset: start),
                            );
                          }
                        }
                      }
                    },
                  },
                  child: TextField(
                    controller: items[i],
                    focusNode: _node(items[i]),
                    autofocus: widget.autofocus && i == 0,
                    textInputAction: TextInputAction.next,
                    textCapitalization: TextCapitalization.sentences,
                    onSubmitted: (_) => _addAfter(i),
                    style: const TextStyle(fontSize: 15, height: 1.4),
                    decoration: widget.decoration('List item'),
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Remove item',
                visualDensity: VisualDensity.compact,
                iconSize: 16,
                onPressed: () => _remove(i),
                icon: Icon(Icons.close_rounded, color: scheme.outline),
              ),
            ],
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => _addAfter(items.length - 1),
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('Add item'),
          ),
        ),
      ],
    );
  }
}

/// A table as a grid of cells, its first row the header, with buttons to
/// add or remove rows and columns.
class _TableEditor extends StatelessWidget {
  const _TableEditor({required this.block, required this.onChanged});
  final DesignBlock block;
  final VoidCallback onChanged;

  void _addRow() {
    final width = block.cells.isEmpty ? 2 : block.cells.first.length;
    block.cells.add([
      for (var i = 0; i < width; i++)
        TextEditingController()..addListener(onChanged),
    ]);
    onChanged();
  }

  void _addColumn() {
    for (final (i, row) in block.cells.indexed) {
      row.add(
        TextEditingController(text: i == 0 ? 'Column ${row.length + 1}' : '')
          ..addListener(onChanged),
      );
    }
    onChanged();
  }

  void _removeRow(int r) {
    if (block.cells.length <= 2) return;
    for (final c in block.cells.removeAt(r)) {
      c.dispose();
    }
    onChanged();
  }

  void _removeColumn(int col) {
    if (block.cells.first.length <= 1) return;
    for (final row in block.cells) {
      row.removeAt(col).dispose();
    }
    onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cols = block.cells.isEmpty ? 0 : block.cells.first.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: .7),
              ),
            ),
            child: Column(
              children: [
                for (final (r, row) in block.cells.indexed)
                  Container(
                    color: r == 0 ? scheme.primary.withValues(alpha: .1) : null,
                    child: Row(
                      children: [
                        for (final (c, cell) in row.indexed)
                          Container(
                            width: 150,
                            decoration: BoxDecoration(
                              border: Border(
                                right: BorderSide(
                                  color: scheme.outlineVariant.withValues(
                                    alpha: .5,
                                  ),
                                ),
                                bottom: BorderSide(
                                  color: scheme.outlineVariant.withValues(
                                    alpha: .5,
                                  ),
                                ),
                              ),
                            ),
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: cell,
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: r == 0
                                          ? FontWeight.w800
                                          : FontWeight.w500,
                                    ),
                                    decoration: InputDecoration(
                                      isDense: true,
                                      border: InputBorder.none,
                                      enabledBorder: InputBorder.none,
                                      focusedBorder: InputBorder.none,
                                      filled: false,
                                      hintText: r == 0 ? 'Header' : '—',
                                    ),
                                  ),
                                ),
                                if (r == 0 && cols > 1)
                                  InkWell(
                                    onTap: () => _removeColumn(c),
                                    child: Tooltip(
                                      message: 'Remove column',
                                      child: Icon(
                                        Icons.close_rounded,
                                        size: 14,
                                        color: scheme.outline,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        SizedBox(
                          width: 36,
                          child: r == 0 || block.cells.length <= 2
                              ? null
                              : IconButton(
                                  tooltip: 'Remove row',
                                  visualDensity: VisualDensity.compact,
                                  iconSize: 16,
                                  onPressed: () => _removeRow(r),
                                  icon: Icon(
                                    Icons.remove_circle_outline_rounded,
                                    color: scheme.outline,
                                  ),
                                ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 4,
          children: [
            TextButton.icon(
              onPressed: _addRow,
              icon: const Icon(Icons.table_rows_outlined, size: 18),
              label: const Text('Add row'),
            ),
            TextButton.icon(
              onPressed: _addColumn,
              icon: const Icon(Icons.view_column_outlined, size: 18),
              label: const Text('Add column'),
            ),
          ],
        ),
      ],
    );
  }
}

/// A chart's points, each a label and a value, with the chart drawn below.
class _ChartEditor extends StatelessWidget {
  const _ChartEditor({required this.block, required this.onChanged});
  final DesignBlock block;
  final VoidCallback onChanged;

  void _add() {
    block.points.add((
      TextEditingController(text: 'Item ${block.points.length + 1}')
        ..addListener(onChanged),
      TextEditingController(text: '10')..addListener(onChanged),
    ));
    onChanged();
  }

  void _remove(int i) {
    if (block.points.length <= 1) return;
    final (l, v) = block.points.removeAt(i);
    l.dispose();
    v.dispose();
    onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const dense = InputDecoration(isDense: true);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (i, (label, value)) in block.points.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: label,
                    decoration: dense.copyWith(labelText: 'Label'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: value,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                      signed: true,
                    ),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[-0-9.]')),
                    ],
                    decoration: dense.copyWith(
                      labelText: 'Value',
                      errorText:
                          value.text.trim().isEmpty ||
                              num.tryParse(value.text.trim()) != null
                          ? null
                          : 'Not a number',
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Remove point',
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  onPressed: block.points.length <= 1 ? null : () => _remove(i),
                  icon: Icon(
                    Icons.remove_circle_outline_rounded,
                    color: scheme.outline,
                  ),
                ),
              ],
            ),
          ),
        TextButton.icon(
          onPressed: _add,
          icon: const Icon(Icons.add_rounded, size: 18),
          label: const Text('Add point'),
        ),
        const SizedBox(height: 4),
        RichPostContent(block.toMarkup()),
      ],
    );
  }
}

/// An image, video or audio address with its preview.
class _MediaEditor extends StatelessWidget {
  const _MediaEditor({required this.block, required this.autofocus});
  final DesignBlock block;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final url = block.url.text.trim();
    final valid = Uri.tryParse(url)?.hasScheme ?? false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: block.url,
          autofocus: autofocus,
          keyboardType: TextInputType.url,
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: Icon(block.kind.icon, size: 18),
            labelText: '${block.kind.label} address',
            hintText: 'https://…',
            errorText: url.isEmpty || valid ? null : 'Enter a full web address',
            suffixIcon: IconButton(
              tooltip: 'Paste',
              icon: const Icon(Icons.content_paste_rounded, size: 18),
              onPressed: () async {
                final data = await Clipboard.getData(Clipboard.kTextPlain);
                final text = data?.text?.trim() ?? '';
                if (text.isNotEmpty) block.url.text = text;
              },
            ),
          ),
        ),
        const SizedBox(height: 8),
        if (valid)
          RichPostContent(block.toMarkup())
        else
          Text(
            'Paste a web address. On publish it is saved on Aseman and '
            'readers load it from here, not the original link.',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }
}

/// An info card: who or what it is about, and its look.
class _CardEditor extends StatelessWidget {
  const _CardEditor({
    required this.block,
    required this.autofocus,
    required this.onChanged,
  });
  final DesignBlock block;
  final bool autofocus;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final hint = switch (block.cardKind) {
      'user' => '@handle',
      'agent' => 'Agent name',
      'tool' => 'App name',
      _ => 'Workspace name',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final (kind, label, icon) in designCardKinds)
              ChoiceChip(
                avatar: Icon(icon, size: 16),
                label: Text(label),
                selected: block.cardKind == kind,
                showCheckmark: false,
                onSelected: (_) {
                  block.cardKind = kind;
                  onChanged();
                },
              ),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          controller: block.target,
          autofocus: autofocus,
          decoration: InputDecoration(
            isDense: true,
            labelText: 'About',
            hintText: hint,
          ),
        ),
        if (block.target.text.trim().isNotEmpty) ...[
          const SizedBox(height: 8),
          RichPostContent(block.toMarkup()),
        ],
      ],
    );
  }
}

/// The post as it will look.
class _Preview extends StatelessWidget {
  const _Preview({required this.markup});
  final String markup;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: .35),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: .5)),
      ),
      child: markup.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.visibility_outlined,
                    size: 28,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Your design shows here as you build it.',
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: DefaultTextStyle.merge(
                style: const TextStyle(fontSize: 15, height: 1.45),
                child: RichPostContent(markup),
              ),
            ),
    );
  }
}

/// Asks for a link's text and address.
class _LinkDialog extends StatefulWidget {
  const _LinkDialog({required this.label});
  final String label;
  @override
  State<_LinkDialog> createState() => _LinkDialogState();
}

class _LinkDialogState extends State<_LinkDialog> {
  late final _label = TextEditingController(text: widget.label);
  final _url = TextEditingController();

  @override
  void dispose() {
    _label.dispose();
    _url.dispose();
    super.dispose();
  }

  void _done() {
    final url = _url.text.trim();
    if (url.isEmpty) return;
    Navigator.pop(context, (
      _label.text.trim(),
      Uri.tryParse(url)?.hasScheme ?? false ? url : 'https://$url',
    ));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    icon: const Icon(Icons.link_rounded),
    title: const Text('Add a link'),
    content: SizedBox(
      width: 380,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _label,
            decoration: const InputDecoration(
              labelText: 'Text',
              hintText: 'What readers see',
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _url,
            autofocus: true,
            keyboardType: TextInputType.url,
            onSubmitted: (_) => _done(),
            decoration: const InputDecoration(
              labelText: 'Address',
              hintText: 'https://…',
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _done, child: const Text('Add link')),
    ],
  );
}
