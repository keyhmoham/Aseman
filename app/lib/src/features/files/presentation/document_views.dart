import 'package:flutter/material.dart';

import '../domain/documents.dart';

/// A text document as a page of paper: headings, paragraphs, lists and
/// tables, with their bold, italic and underline.
class DocumentPageView extends StatelessWidget {
  const DocumentPageView({super.key, required this.blocks});
  final List<DocBlock> blocks;

  static const _ink = Color(0xFF1F2328);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surfaceContainerLowest,
      child: LayoutBuilder(
        builder: (context, box) {
          final narrow = box.maxWidth < 520;
          return SingleChildScrollView(
            padding: EdgeInsets.all(narrow ? 10 : 28),
            child: Center(
              child: Container(
                constraints: const BoxConstraints(maxWidth: 780),
                padding: EdgeInsets.symmetric(
                  horizontal: narrow ? 20 : 64,
                  vertical: narrow ? 24 : 56,
                ),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(4),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x33000000),
                      blurRadius: 18,
                      offset: Offset(0, 6),
                    ),
                  ],
                ),
                child: DefaultTextStyle(
                  style: const TextStyle(
                    fontFamily: 'serif',
                    fontSize: 14,
                    height: 1.6,
                    color: _ink,
                  ),
                  child: blocks.isEmpty
                      ? const Text('This document is empty.')
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [for (final b in blocks) _block(b)],
                        ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _block(DocBlock b) {
    switch (b.kind) {
      case DocBlockKind.heading:
        final size = const [26.0, 21.0, 18.0, 16.0, 15.0, 14.0][b.level - 1];
        return Padding(
          padding: EdgeInsets.only(top: b.level <= 2 ? 18 : 12, bottom: 6),
          child: Text.rich(
            _runs(b.runs),
            style: TextStyle(
              fontFamily: 'serif',
              fontSize: size,
              height: 1.25,
              fontWeight: FontWeight.w700,
              color: b.level == 1 ? _ink : const Color(0xFF24292F),
            ),
          ),
        );
      case DocBlockKind.paragraph:
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: b.text.trim().isEmpty
              ? const SizedBox(height: 8)
              : Text.rich(_runs(b.runs)),
        );
      case DocBlockKind.listItem:
        return Padding(
          padding: EdgeInsets.only(left: 18.0 + b.level * 22, bottom: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 18,
                child: Text(
                  b.level.isEven ? '•' : '◦',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              Expanded(child: Text.rich(_runs(b.runs))),
            ],
          ),
        );
      case DocBlockKind.table:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Table(
              defaultColumnWidth: const IntrinsicColumnWidth(),
              border: TableBorder.all(color: const Color(0xFFD0D7DE)),
              children: [
                for (final (i, row) in _even(b.rows).indexed)
                  TableRow(
                    decoration: BoxDecoration(
                      color: i == 0 ? const Color(0xFFF6F8FA) : null,
                    ),
                    children: [
                      for (final cell in row)
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 280),
                            child: Text(
                              cell,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: i == 0 ? FontWeight.w700 : null,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        );
    }
  }

  static TextSpan _runs(List<DocRun> runs) => TextSpan(
    children: [
      for (final r in runs)
        TextSpan(
          text: r.text,
          style: TextStyle(
            fontWeight: r.bold ? FontWeight.w700 : null,
            fontStyle: r.italic ? FontStyle.italic : null,
            decoration: r.underline ? TextDecoration.underline : null,
          ),
        ),
    ],
  );
}

/// Rows padded to the same width (a table needs it).
List<List<String>> _even(List<List<String>> rows) {
  final width = rows.fold<int>(0, (w, r) => r.length > w ? r.length : w);
  return [
    for (final r in rows)
      if (width > 0) [...r, for (var i = r.length; i < width; i++) ''],
  ];
}

String _columnName(int i) {
  var n = i + 1, name = '';
  while (n > 0) {
    final r = (n - 1) % 26;
    name = String.fromCharCode(65 + r) + name;
    n = (n - 1) ~/ 26;
  }
  return name;
}

/// Spreadsheet sheets as a grid with lettered columns, numbered rows and a
/// tab per sheet.
class SpreadsheetView extends StatefulWidget {
  const SpreadsheetView({super.key, required this.sheets});
  final List<Sheet> sheets;
  @override
  State<SpreadsheetView> createState() => _SpreadsheetViewState();
}

class _SpreadsheetViewState extends State<SpreadsheetView> {
  int _sheet = 0;

  /// Cells beyond these are not laid out (the grid stays responsive).
  static const _maxRows = 2000, _maxColumns = 100;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (widget.sheets.isEmpty) {
      return const Center(child: Text('This spreadsheet has no sheets.'));
    }
    final sheet = widget.sheets[_sheet.clamp(0, widget.sheets.length - 1)];
    final rows = _even([
      for (final r in sheet.rows.take(_maxRows))
        r.length > _maxColumns ? r.sublist(0, _maxColumns) : r,
    ]);
    final columns = rows.isEmpty ? 0 : rows.first.length;
    final header = TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w700,
      color: scheme.onSurfaceVariant,
    );
    Widget cell(String text, {TextStyle? style, Color? fill}) => Container(
      constraints: const BoxConstraints(minWidth: 64, maxWidth: 260),
      color: fill,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      child: Text(
        text,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: style ?? const TextStyle(fontSize: 12),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: rows.isEmpty
              ? const Center(child: Text('This sheet is empty.'))
              : SingleChildScrollView(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Table(
                      defaultColumnWidth: const IntrinsicColumnWidth(),
                      border: TableBorder.all(color: scheme.outlineVariant),
                      children: [
                        TableRow(
                          decoration: BoxDecoration(
                            color: scheme.surfaceContainerHigh,
                          ),
                          children: [
                            cell('', style: header),
                            for (var c = 0; c < columns; c++)
                              cell(_columnName(c), style: header),
                          ],
                        ),
                        for (final (i, row) in rows.indexed)
                          TableRow(
                            children: [
                              cell(
                                '${i + 1}',
                                style: header,
                                fill: scheme.surfaceContainerHigh,
                              ),
                              for (final v in row)
                                cell(
                                  v,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontFeatures: const [
                                      FontFeature.tabularFigures(),
                                    ],
                                    fontWeight: i == 0 ? FontWeight.w700 : null,
                                  ),
                                ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
        ),
        if (widget.sheets.length > 1 || sheet.rows.length > _maxRows)
          Container(
            color: scheme.surfaceContainer,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final (i, s) in widget.sheets.indexed)
                  ChoiceChip(
                    visualDensity: VisualDensity.compact,
                    label: Text(s.name),
                    selected: i == _sheet,
                    onSelected: (_) => setState(() => _sheet = i),
                  ),
                if (sheet.rows.length > _maxRows)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      'First $_maxRows of ${sheet.rows.length} rows',
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
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

/// A deck's slides as 16:9 cards: the first paragraph as the title, the
/// rest as points.
class SlidesView extends StatelessWidget {
  const SlidesView({super.key, required this.slides});
  final List<Slide> slides;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (slides.isEmpty) {
      return const Center(child: Text('This presentation has no slides.'));
    }
    return ColoredBox(
      color: scheme.surfaceContainerLowest,
      child: ListView.separated(
        padding: const EdgeInsets.all(18),
        itemCount: slides.length,
        separatorBuilder: (_, __) => const SizedBox(height: 18),
        itemBuilder: (context, i) {
          final s = slides[i];
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Slide ${i + 1}',
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 6),
              AspectRatio(
                aspectRatio: 16 / 9,
                child: Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x33000000),
                        blurRadius: 14,
                        offset: Offset(0, 5),
                      ),
                    ],
                  ),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.topLeft,
                    child: SizedBox(
                      width: 640,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (s.paragraphs.isNotEmpty)
                            Text(
                              s.paragraphs.first,
                              style: const TextStyle(
                                fontSize: 30,
                                height: 1.2,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFF1F2328),
                              ),
                            ),
                          const SizedBox(height: 16),
                          for (final p in s.paragraphs.skip(1))
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Text(
                                '•  $p',
                                style: const TextStyle(
                                  fontSize: 18,
                                  height: 1.35,
                                  color: Color(0xFF3B4048),
                                ),
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
        },
      ),
    );
  }
}

/// The entries of an archive.
class ArchiveListView extends StatelessWidget {
  const ArchiveListView({super.key, required this.items, required this.size});
  final List<ArchiveItem> items;
  final String Function(int bytes) size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: items.length + 1,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        if (i == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              '${items.length} entries in this archive',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          );
        }
        final it = items[i - 1];
        return ListTile(
          dense: true,
          leading: Icon(
            it.isDirectory
                ? Icons.folder_rounded
                : Icons.insert_drive_file_outlined,
            size: 18,
          ),
          title: Text(
            it.name,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
          trailing: it.isDirectory
              ? null
              : Text(
                  size(it.size),
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
        );
      },
    );
  }
}
