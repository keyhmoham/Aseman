import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../../data/services/tradera_service.dart';
import '../../../shared/widgets/overlay_panels.dart';
import '../../search_feed/presentation/rich_post_content.dart';
import '../data/workspace_files.dart';
import '../domain/documents.dart';
import '../domain/file_types.dart';
import 'code_view.dart';
import 'document_views.dart';
import 'file_actions.dart';
import 'html_preview/html_preview.dart';
import 'media_players.dart';

/// "1.4 MB".
String formatBytes(int bytes) {
  if (bytes >= 1 << 30) return '${(bytes / (1 << 30)).toStringAsFixed(1)} GB';
  if (bytes >= 1 << 20) return '${(bytes / (1 << 20)).toStringAsFixed(1)} MB';
  if (bytes >= 1 << 10) return '${(bytes / (1 << 10)).toStringAsFixed(0)} KB';
  return '$bytes B';
}

/// Opens a workspace file in a bottom sheet (phones).
Future<void> showWorkspaceFileSheet(
  BuildContext context, {
  required TraderaService service,
  required String spaceId,
  required String path,
}) => showAppSheet<void>(
  context,
  Builder(
    builder: (sheet) => WorkspaceFileViewer(
      service: service,
      spaceId: spaceId,
      path: path,
      onClose: () => Navigator.of(sheet).pop(),
    ),
  ),
  heightFactor: .94,
);

/// A file of the space's workspace, shown as what it is: highlighted code,
/// rendered Markdown, an image, a video or audio player, a PDF, a document,
/// a spreadsheet, slides, an archive's entries, a font, or bytes.
class WorkspaceFileViewer extends StatefulWidget {
  const WorkspaceFileViewer({
    super.key,
    required this.service,
    required this.spaceId,
    required this.path,
    this.showHeader = true,
    this.onClose,
  });

  final TraderaService service;
  final String spaceId;

  /// The file's path, `/workspace/…`.
  final String path;

  /// A card window has its own title bar; the header then only carries the
  /// file's actions.
  final bool showHeader;
  final VoidCallback? onClose;

  @override
  State<WorkspaceFileViewer> createState() => _WorkspaceFileViewerState();
}

class _WorkspaceFileViewerState extends State<WorkspaceFileViewer> {
  Uint8List? _bytes;
  Object? _error;
  bool _source = false;

  /// The text being edited, while it is.
  TextEditingController? _editor;
  bool _saving = false;

  bool get _dirty =>
      _editor != null && _bytes != null && _editor!.text != _text(_bytes!);

  @override
  void dispose() {
    _editor?.dispose();
    super.dispose();
  }

  void _edit(Uint8List bytes) => setState(() {
    _editor = TextEditingController(text: _text(bytes))
      ..addListener(() => setState(() {}));
  });

  Future<void> _stopEditing() async {
    if (_dirty) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: const Text('Discard your changes?'),
          content: Text('$_name has changes that are not saved.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('Keep editing'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: const Text('Discard'),
            ),
          ],
        ),
      );
      if (discard != true || !mounted) return;
    }
    setState(() {
      _editor?.dispose();
      _editor = null;
    });
  }

  /// Saves the edited text. The computer is not woken for it.
  Future<void> _save() async {
    final editor = _editor;
    if (editor == null || !_dirty || _saving) return;
    setState(() => _saving = true);
    final bytes = Uint8List.fromList(utf8.encode(editor.text));
    final files = WorkspaceFiles(widget.service, widget.spaceId);
    final saved = await runWorkspaceChange(
      context,
      ({required wake}) => files.write(widget.path, bytes, wake: wake),
      done: '$_name saved',
    );
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (saved) _bytes = bytes;
    });
  }

  String get _name => widget.path.split('/').last;
  FileType get _type => FileType.of(_name);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant WorkspaceFileViewer old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path || old.spaceId != widget.spaceId) _load();
  }

  Future<void> _load() async {
    setState(() {
      _bytes = null;
      _error = null;
      _editor?.dispose();
      _editor = null;
    });
    try {
      final bytes = await WorkspaceFiles(
        widget.service,
        widget.spaceId,
      ).read(widget.path);
      if (mounted) setState(() => _bytes = bytes);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  /// Text files whose bytes are not text read as binary.
  static bool _looksBinary(Uint8List bytes) {
    final head = bytes.length > 8000 ? bytes.sublist(0, 8000) : bytes;
    return head.contains(0);
  }

  FileKind _kindOf(Uint8List bytes) {
    final kind = _type.kind;
    if ((kind == FileKind.code ||
            kind == FileKind.html ||
            kind == FileKind.text ||
            kind == FileKind.markdown) &&
        _looksBinary(bytes)) {
      return FileKind.binary;
    }
    return kind;
  }

  /// Kinds shown rendered, with their source a toggle away (HTML where a
  /// page can be rendered in the app; elsewhere its source).
  static Set<FileKind> get _renderable => {
    FileKind.markdown,
    FileKind.svg,
    if (htmlPreviewSupported) FileKind.html,
  };
  static const _textual = {
    FileKind.code,
    FileKind.html,
    FileKind.text,
    FileKind.markdown,
    FileKind.svg,
  };

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    final kind = bytes == null ? _type.kind : _kindOf(bytes);
    return Material(
      type: MaterialType.transparency,
      child: Column(
        children: [
          _header(context, bytes, kind),
          Divider(
            height: 1,
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
          Expanded(
            child: _error != null
                ? _Message(
                    icon: Icons.error_outline_rounded,
                    title: 'Could not open $_name',
                    detail: '$_error',
                    onRetry: _load,
                  )
                : bytes == null
                ? const Center(child: CircularProgressIndicator())
                : _editor != null
                ? CallbackShortcuts(
                    bindings: {
                      const SingleActivator(
                        LogicalKeyboardKey.keyS,
                        control: true,
                      ): _save,
                      const SingleActivator(
                        LogicalKeyboardKey.keyS,
                        meta: true,
                      ): _save,
                    },
                    child: TextField(
                      controller: _editor,
                      autofocus: true,
                      expands: true,
                      maxLines: null,
                      textAlignVertical: TextAlignVertical.top,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12.5,
                        height: 1.45,
                      ),
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        filled: false,
                        contentPadding: EdgeInsets.all(14),
                      ),
                    ),
                  )
                : _body(context, bytes, kind),
          ),
        ],
      ),
    );
  }

  Widget _header(BuildContext context, Uint8List? bytes, FileKind kind) {
    final scheme = Theme.of(context).colorScheme;
    final type = _type;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        widget.showHeader ? 14 : 10,
        widget.showHeader ? 10 : 4,
        6,
        4,
      ),
      child: Row(
        children: [
          if (widget.showHeader) ...[
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: type.color.withValues(alpha: .16),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(type.icon, size: 19, color: type.color),
            ),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (widget.showHeader)
                  Text(
                    _name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                Text(
                  [
                    widget.path,
                    if (bytes != null) formatBytes(bytes.length),
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (bytes != null && _editor != null) ...[
            Text(
              _saving
                  ? 'Saving…'
                  : _dirty
                  ? 'Unsaved'
                  : 'Saved',
              style: TextStyle(
                fontSize: 11,
                color: _dirty ? scheme.primary : scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonal(
              onPressed: _dirty && !_saving ? _save : null,
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
              ),
              child: const Text('Save'),
            ),
            IconButton(
              tooltip: 'Stop editing',
              visualDensity: VisualDensity.compact,
              onPressed: _stopEditing,
              icon: const Icon(Icons.done_rounded, size: 19),
            ),
          ] else ...[
            if (bytes != null &&
                _textual.contains(kind) &&
                kind != FileKind.svg)
              IconButton(
                tooltip: 'Edit',
                visualDensity: VisualDensity.compact,
                onPressed: () => _edit(bytes),
                icon: const Icon(Icons.edit_outlined, size: 18),
              ),
            if (bytes != null && _renderable.contains(kind))
              SegmentedButton<bool>(
                showSelectedIcon: false,
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
                segments: const [
                  ButtonSegment(
                    value: false,
                    tooltip: 'Preview',
                    icon: Icon(Icons.visibility_outlined, size: 16),
                  ),
                  ButtonSegment(
                    value: true,
                    tooltip: 'Source',
                    icon: Icon(Icons.code_rounded, size: 16),
                  ),
                ],
                selected: {_source},
                onSelectionChanged: (v) => setState(() => _source = v.first),
              ),
            if (bytes != null && _textual.contains(kind))
              IconButton(
                tooltip: 'Copy',
                visualDensity: VisualDensity.compact,
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: _text(bytes)));
                  if (context.mounted) {
                    ScaffoldMessenger.maybeOf(
                      context,
                    )?.showSnackBar(SnackBar(content: Text('Copied $_name')));
                  }
                },
                icon: const Icon(Icons.copy_rounded, size: 18),
              ),
            IconButton(
              tooltip: 'Reload',
              visualDensity: VisualDensity.compact,
              onPressed: _load,
              icon: const Icon(Icons.refresh_rounded, size: 19),
            ),
          ],
          if (widget.onClose != null)
            IconButton(
              tooltip: 'Close',
              visualDensity: VisualDensity.compact,
              onPressed: widget.onClose,
              icon: const Icon(Icons.close_rounded, size: 19),
            ),
        ],
      ),
    );
  }

  static String _text(Uint8List bytes) =>
      utf8.decode(bytes, allowMalformed: true);

  Widget _body(BuildContext context, Uint8List bytes, FileKind kind) {
    try {
      return switch (kind) {
        FileKind.code => CodeView(
          source: _text(bytes),
          language: _type.language,
        ),
        FileKind.text => CodeView(source: _text(bytes)),
        FileKind.html =>
          _source || !htmlPreviewSupported
              ? CodeView(source: _text(bytes), language: 'xml')
              : htmlPreview(
                  key: ValueKey('html-${widget.path}-${bytes.length}'),
                  html: _text(bytes),
                ),
        FileKind.markdown =>
          _source
              ? CodeView(source: _text(bytes), language: 'markdown')
              : _MarkdownPage(_text(bytes)),
        FileKind.svg =>
          _source
              ? CodeView(source: _text(bytes), language: 'xml')
              : _Zoomable(
                  child: SvgPicture.memory(
                    bytes,
                    errorBuilder: (_, __, ___) =>
                        const Text('This picture could not be drawn.'),
                  ),
                ),
        FileKind.image => _Zoomable(
          child: Image.memory(
            bytes,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) => const _Message(
              icon: Icons.broken_image_outlined,
              title: 'This picture could not be shown',
            ),
          ),
        ),
        FileKind.video => FileVideoPlayer(
          bytes: bytes,
          mime: FileType.mimeOf(_name),
        ),
        FileKind.audio => FileAudioPlayer(
          bytes: bytes,
          mime: FileType.mimeOf(_name),
          name: _name,
          color: _type.color,
        ),
        FileKind.pdf => _PdfView(bytes: bytes, name: widget.path),
        FileKind.document => DocumentPageView(
          blocks: FileType.extensionOf(_name) == 'odt'
              ? readOdt(bytes)
              : readDocx(bytes),
        ),
        FileKind.spreadsheet => SpreadsheetView(
          sheets: switch (FileType.extensionOf(_name)) {
            'xlsx' => readXlsx(bytes),
            'ods' => readOds(bytes),
            final ext => [
              Sheet(_name, readDelimited(_text(bytes), tabs: ext == 'tsv')),
            ],
          },
        ),
        FileKind.presentation => SlidesView(
          slides: FileType.extensionOf(_name) == 'odp'
              ? readOdp(bytes)
              : readPptx(bytes),
        ),
        FileKind.archive => ArchiveListView(
          items: readArchive(bytes, _name),
          size: formatBytes,
        ),
        FileKind.font => _FontPreview(bytes: bytes, name: _name),
        FileKind.binary => _HexView(bytes),
      };
    } on DocumentUnreadable catch (e) {
      return _Message(
        icon: _type.icon,
        title: 'Cannot show $_name',
        detail: e.message,
      );
    } catch (_) {
      return _HexView(bytes);
    }
  }
}

/// Markdown laid out as the app's messages and posts are.
class _MarkdownPage extends StatelessWidget {
  const _MarkdownPage(this.source);
  final String source;
  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(22, 18, 22, 32),
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 820),
        // Read as a page: a little larger than a message.
        child: MediaQuery.withClampedTextScaling(
          minScaleFactor: 1.15,
          maxScaleFactor: 1.6,
          child: SelectionArea(child: RichPostContent(source)),
        ),
      ),
    ),
  );
}

/// A picture on a checkerboard, zoomed and panned with the fingers, the
/// wheel or the buttons.
class _Zoomable extends StatefulWidget {
  const _Zoomable({required this.child});
  final Widget child;
  @override
  State<_Zoomable> createState() => _ZoomableState();
}

class _ZoomableState extends State<_Zoomable> {
  final _transform = TransformationController();

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  void _zoom(double by) {
    final scale = (_transform.value.getMaxScaleOnAxis() * by).clamp(.5, 12.0);
    setState(() => _transform.value = Matrix4.diagonal3Values(scale, scale, 1));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      children: [
        Positioned.fill(
          child: CustomPaint(
            painter: _Checkerboard(
              scheme.surfaceContainerLow,
              scheme.surfaceContainerHigh,
            ),
          ),
        ),
        Positioned.fill(
          child: InteractiveViewer(
            transformationController: _transform,
            minScale: .5,
            maxScale: 12,
            boundaryMargin: const EdgeInsets.all(200),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: widget.child,
              ),
            ),
          ),
        ),
        Positioned(
          right: 10,
          bottom: 10,
          child: Material(
            color: scheme.surfaceContainerHighest.withValues(alpha: .9),
            borderRadius: BorderRadius.circular(14),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'Zoom out',
                  onPressed: () => _zoom(1 / 1.4),
                  icon: const Icon(Icons.zoom_out_rounded, size: 19),
                ),
                IconButton(
                  tooltip: 'Fit',
                  onPressed: () =>
                      setState(() => _transform.value = Matrix4.identity()),
                  icon: const Icon(Icons.fit_screen_rounded, size: 19),
                ),
                IconButton(
                  tooltip: 'Zoom in',
                  onPressed: () => _zoom(1.4),
                  icon: const Icon(Icons.zoom_in_rounded, size: 19),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _Checkerboard extends CustomPainter {
  _Checkerboard(this.a, this.b);
  final Color a, b;
  @override
  void paint(Canvas canvas, Size size) {
    const cell = 12.0;
    canvas.drawRect(Offset.zero & size, Paint()..color = a);
    final paint = Paint()..color = b;
    for (var y = 0.0; y < size.height; y += cell) {
      for (
        var x = ((y / cell).floor().isEven ? 0.0 : cell);
        x < size.width;
        x += cell * 2
      ) {
        canvas.drawRect(Rect.fromLTWH(x, y, cell, cell), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_Checkerboard old) => old.a != a || old.b != b;
}

/// A PDF as pages of a book, with the page number and zoom.
class _PdfView extends StatefulWidget {
  const _PdfView({required this.bytes, required this.name});
  final Uint8List bytes;
  final String name;
  @override
  State<_PdfView> createState() => _PdfViewState();
}

class _PdfViewState extends State<_PdfView> {
  final _controller = PdfViewerController();
  int _page = 1, _pages = 0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      children: [
        Positioned.fill(
          child: PdfViewer.data(
            widget.bytes,
            sourceName: widget.name,
            controller: _controller,
            params: PdfViewerParams(
              margin: 12,
              backgroundColor: scheme.surfaceContainerLowest,
              onViewerReady: (doc, controller) =>
                  setState(() => _pages = doc.pages.length),
              onPageChanged: (page) {
                if (page != null) setState(() => _page = page);
              },
              errorBannerBuilder: (context, error, stack, ref) => _Message(
                icon: Icons.picture_as_pdf_outlined,
                title: 'This PDF could not be opened',
                detail: '$error',
              ),
            ),
          ),
        ),
        if (_pages > 0)
          Positioned(
            bottom: 12,
            left: 0,
            right: 0,
            child: Center(
              child: Material(
                color: scheme.surfaceContainerHighest.withValues(alpha: .92),
                borderRadius: BorderRadius.circular(18),
                elevation: 2,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Previous page',
                      onPressed: _page <= 1
                          ? null
                          : () => _controller.goToPage(pageNumber: _page - 1),
                      icon: const Icon(Icons.chevron_left_rounded),
                    ),
                    Text(
                      '$_page / $_pages',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Next page',
                      onPressed: _page >= _pages
                          ? null
                          : () => _controller.goToPage(pageNumber: _page + 1),
                      icon: const Icon(Icons.chevron_right_rounded),
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      tooltip: 'Zoom out',
                      onPressed: () => _controller.zoomDown(),
                      icon: const Icon(Icons.zoom_out_rounded, size: 19),
                    ),
                    IconButton(
                      tooltip: 'Zoom in',
                      onPressed: () => _controller.zoomUp(),
                      icon: const Icon(Icons.zoom_in_rounded, size: 19),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// A font file: its name and a sample set in it.
class _FontPreview extends StatefulWidget {
  const _FontPreview({required this.bytes, required this.name});
  final Uint8List bytes;
  final String name;
  @override
  State<_FontPreview> createState() => _FontPreviewState();
}

class _FontPreviewState extends State<_FontPreview> {
  String? _family;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _loadFont();
  }

  Future<void> _loadFont() async {
    final family =
        'workspace-font-${widget.name.hashCode}-${widget.bytes.length}';
    try {
      await (FontLoader(
        family,
      )..addFont(Future.value(ByteData.sublistView(widget.bytes)))).load();
      if (mounted) setState(() => _family = family);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) return _HexView(widget.bytes);
    final family = _family;
    if (family == null) return const Center(child: CircularProgressIndicator());
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(widget.name, style: TextStyle(fontFamily: family, fontSize: 34)),
        const SizedBox(height: 18),
        for (final size in const [12.0, 18.0, 24.0, 36.0, 54.0])
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Text(
              'The quick brown fox jumps over the lazy dog 0123456789',
              style: TextStyle(fontFamily: family, fontSize: size),
            ),
          ),
        Text(
          'ABCDEFGHIJKLMNOPQRSTUVWXYZ\nabcdefghijklmnopqrstuvwxyz\n!@#\$%^&*()[]{}<>?',
          style: TextStyle(fontFamily: family, fontSize: 22, height: 1.5),
        ),
      ],
    );
  }
}

/// Bytes as a hex dump (the first part of a large file).
class _HexView extends StatelessWidget {
  const _HexView(this.bytes);
  final Uint8List bytes;
  static const _limit = 64 * 1024;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final shown = bytes.length > _limit ? bytes.sublist(0, _limit) : bytes;
    final rows = (shown.length / 16).ceil();
    return Column(
      children: [
        Container(
          width: double.infinity,
          color: scheme.surfaceContainer,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Text(
            'Binary file · ${formatBytes(bytes.length)}'
            '${bytes.length > _limit ? ' · first ${formatBytes(_limit)} shown' : ''}',
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: rows,
            itemBuilder: (_, r) {
              final line = shown.sublist(
                r * 16,
                (r * 16 + 16).clamp(0, shown.length),
              );
              final hex = [
                for (final b in line) b.toRadixString(16).padLeft(2, '0'),
              ].join(' ');
              final ascii = String.fromCharCodes([
                for (final b in line) b >= 32 && b < 127 ? b : 46,
              ]);
              return Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: '${(r * 16).toRadixString(16).padLeft(8, '0')}  ',
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                    TextSpan(text: hex.padRight(49)),
                    TextSpan(
                      text: ' $ascii',
                      style: TextStyle(color: scheme.primary),
                    ),
                  ],
                ),
                softWrap: false,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.title,
    this.detail = '',
    this.onRetry,
  });
  final IconData icon;
  final String title;
  final String detail;
  final VoidCallback? onRetry;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: scheme.outline),
            const SizedBox(height: 10),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            if (detail.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                detail,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ],
            if (onRetry != null) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Try again'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
