/// Reads office documents (Word / OpenDocument text, spreadsheets,
/// presentations), CSV and archives into plain structures the file viewer
/// lays out. Only what is shown is read: text, its structure and simple
/// formatting.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

/// A run of text with its formatting.
class DocRun {
  const DocRun(
    this.text, {
    this.bold = false,
    this.italic = false,
    this.underline = false,
  });
  final String text;
  final bool bold;
  final bool italic;
  final bool underline;
}

enum DocBlockKind { heading, paragraph, listItem, table }

/// A paragraph, heading, list item or table of a document.
class DocBlock {
  const DocBlock(
    this.kind, {
    this.runs = const [],
    this.level = 0,
    this.ordered = false,
    this.rows = const [],
  });
  final DocBlockKind kind;
  final List<DocRun> runs;

  /// A heading's level (1–6) or a list item's depth (0…).
  final int level;
  final bool ordered;

  /// A table's cells, as text.
  final List<List<String>> rows;

  String get text => runs.map((r) => r.text).join();
}

/// A sheet of a spreadsheet: its name and cells as text.
class Sheet {
  const Sheet(this.name, this.rows);
  final String name;
  final List<List<String>> rows;
}

/// A slide: its paragraphs (the first is usually its title).
class Slide {
  const Slide(this.paragraphs);
  final List<String> paragraphs;
}

/// An entry of an archive.
class ArchiveItem {
  const ArchiveItem(this.name, this.size, this.isDirectory);
  final String name;
  final int size;
  final bool isDirectory;
}

/// Thrown when a document's content cannot be read.
class DocumentUnreadable implements Exception {
  const DocumentUnreadable(this.message);
  final String message;
  @override
  String toString() => message;
}

Archive _zip(Uint8List bytes) {
  try {
    return ZipDecoder().decodeBytes(bytes);
  } catch (_) {
    throw const DocumentUnreadable('This file is not a readable document.');
  }
}

XmlDocument _xml(Archive zip, String name) {
  final file = zip.findFile(name);
  if (file == null) {
    throw DocumentUnreadable('This document has no $name.');
  }
  return XmlDocument.parse(utf8.decode(file.content, allowMalformed: true));
}

XmlDocument? _maybeXml(Archive zip, String name) {
  final file = zip.findFile(name);
  return file == null
      ? null
      : XmlDocument.parse(utf8.decode(file.content, allowMalformed: true));
}

bool _on(XmlElement? props, String name) {
  final el = props?.getElement(name);
  if (el == null) return false;
  final v = el.getAttribute('w:val');
  return v == null || (v != 'false' && v != '0' && v != 'none');
}

/// The blocks of a Word document (.docx).
List<DocBlock> readDocx(Uint8List bytes) {
  final body = _xml(
    _zip(bytes),
    'word/document.xml',
  ).findAllElements('w:body').firstOrNull;
  if (body == null) return const [];
  final blocks = <DocBlock>[];
  for (final el in body.childElements) {
    if (el.name.qualified == 'w:p') {
      final block = _docxParagraph(el);
      if (block != null) blocks.add(block);
    } else if (el.name.qualified == 'w:tbl') {
      blocks.add(
        DocBlock(
          DocBlockKind.table,
          rows: [
            for (final tr in el.findElements('w:tr'))
              [
                for (final tc in tr.findElements('w:tc'))
                  tc
                      .findAllElements('w:p')
                      .map((p) => _docxRuns(p).map((r) => r.text).join())
                      .join('\n'),
              ],
          ],
        ),
      );
    }
  }
  return blocks;
}

List<DocRun> _docxRuns(XmlElement p) => [
  for (final r in p.findAllElements('w:r'))
    DocRun(
      r.childElements
          .map(
            (c) => switch (c.name.qualified) {
              'w:t' => c.innerText,
              'w:tab' => '\t',
              'w:br' || 'w:cr' => '\n',
              _ => '',
            },
          )
          .join(),
      bold: _on(r.getElement('w:rPr'), 'w:b'),
      italic: _on(r.getElement('w:rPr'), 'w:i'),
      underline: _on(r.getElement('w:rPr'), 'w:u'),
    ),
];

DocBlock? _docxParagraph(XmlElement p) {
  final props = p.getElement('w:pPr');
  final style =
      props?.getElement('w:pStyle')?.getAttribute('w:val')?.toLowerCase() ?? '';
  final runs = _docxRuns(p);
  final heading = style == 'title'
      ? 1
      : style == 'subtitle'
      ? 2
      : int.tryParse(RegExp(r'^heading\s*(\d)$').firstMatch(style)?[1] ?? '');
  if (heading != null) {
    return DocBlock(
      DocBlockKind.heading,
      runs: runs,
      level: heading.clamp(1, 6),
    );
  }
  final numbering = props?.getElement('w:numPr');
  if (numbering != null || style.contains('list')) {
    final depth =
        int.tryParse(
          numbering?.getElement('w:ilvl')?.getAttribute('w:val') ?? '',
        ) ??
        0;
    return DocBlock(
      DocBlockKind.listItem,
      runs: runs,
      level: depth,
      ordered: style.contains('number'),
    );
  }
  return DocBlock(DocBlockKind.paragraph, runs: runs);
}

/// The blocks of an OpenDocument text (.odt).
List<DocBlock> readOdt(Uint8List bytes) {
  final text = _xml(
    _zip(bytes),
    'content.xml',
  ).findAllElements('office:text').firstOrNull;
  if (text == null) return const [];
  final blocks = <DocBlock>[];
  void walk(XmlElement el, int depth) {
    for (final c in el.childElements) {
      switch (c.name.qualified) {
        case 'text:h':
          blocks.add(
            DocBlock(
              DocBlockKind.heading,
              runs: [DocRun(c.innerText)],
              level:
                  (int.tryParse(c.getAttribute('text:outline-level') ?? '') ??
                          1)
                      .clamp(1, 6),
            ),
          );
        case 'text:p':
          blocks.add(
            DocBlock(
              depth > 0 ? DocBlockKind.listItem : DocBlockKind.paragraph,
              runs: [DocRun(c.innerText)],
              level: depth > 0 ? depth - 1 : 0,
            ),
          );
        case 'text:list':
          walk(c, depth + 1);
        case 'text:list-item' || 'text:section':
          walk(c, depth);
        case 'table:table':
          blocks.add(
            DocBlock(
              DocBlockKind.table,
              rows: [
                for (final row in c.findAllElements('table:table-row'))
                  [
                    for (final cell in row.findElements('table:table-cell'))
                      cell.innerText,
                  ],
              ],
            ),
          );
      }
    }
  }

  walk(text, 0);
  return blocks;
}

/// The sheets of an Excel workbook (.xlsx).
List<Sheet> readXlsx(Uint8List bytes) {
  final zip = _zip(bytes);
  final shared = [
    for (final si
        in _maybeXml(zip, 'xl/sharedStrings.xml')?.findAllElements('si') ??
            const <XmlElement>[])
      si.findAllElements('t').map((t) => t.innerText).join(),
  ];
  final rels = {
    for (final r
        in _maybeXml(
              zip,
              'xl/_rels/workbook.xml.rels',
            )?.findAllElements('Relationship') ??
            const <XmlElement>[])
      r.getAttribute('Id') ?? '': r.getAttribute('Target') ?? '',
  };
  final sheets = <Sheet>[];
  final listed = _xml(zip, 'xl/workbook.xml').findAllElements('sheet').toList();
  for (var i = 0; i < listed.length; i++) {
    final s = listed[i];
    var target = rels[s.getAttribute('r:id')] ?? 'worksheets/sheet${i + 1}.xml';
    target = target.startsWith('/') ? target.substring(1) : 'xl/$target';
    final doc = _maybeXml(zip, target);
    if (doc == null) continue;
    final rows = <List<String>>[];
    for (final row in doc.findAllElements('row')) {
      final cells = <String>[];
      for (final c in row.findElements('c')) {
        final col = _column(c.getAttribute('r') ?? '');
        while (col != null && cells.length < col) {
          cells.add('');
        }
        final type = c.getAttribute('t');
        final v = c.getElement('v')?.innerText ?? '';
        cells.add(switch (type) {
          's' => shared.elementAtOrNull(int.tryParse(v) ?? -1) ?? '',
          'inlineStr' => c.findAllElements('t').map((t) => t.innerText).join(),
          'b' => v == '1' ? 'TRUE' : 'FALSE',
          _ => v,
        });
      }
      final at =
          (int.tryParse(row.getAttribute('r') ?? '') ?? rows.length + 1) - 1;
      while (rows.length < at) {
        rows.add(const []);
      }
      rows.add(cells);
    }
    sheets.add(Sheet(s.getAttribute('name') ?? 'Sheet ${i + 1}', rows));
  }
  return sheets;
}

/// The zero-based column of a cell reference ("C7" → 2).
int? _column(String ref) {
  final letters = RegExp(r'^[A-Z]+').firstMatch(ref)?[0];
  if (letters == null) return null;
  var n = 0;
  for (final c in letters.codeUnits) {
    n = n * 26 + (c - 64);
  }
  return n - 1;
}

/// The sheets of an OpenDocument spreadsheet (.ods).
List<Sheet> readOds(Uint8List bytes) => [
  for (final t in _xml(
    _zip(bytes),
    'content.xml',
  ).findAllElements('table:table'))
    Sheet(t.getAttribute('table:name') ?? 'Sheet', [
      for (final row in t.findAllElements('table:table-row'))
        [
          for (final cell in row.findElements('table:table-cell'))
            for (
              var k = 0;
              k <
                  (int.tryParse(
                            cell.getAttribute(
                                  'table:number-columns-repeated',
                                ) ??
                                '',
                          ) ??
                          1)
                      .clamp(1, 64);
              k++
            )
              cell.innerText,
        ],
    ]),
];

/// The rows of delimited text (CSV, or TSV when [tabs]), with quoted fields.
List<List<String>> readDelimited(String text, {bool tabs = false}) {
  final sep = tabs ? '\t' : ',';
  final rows = <List<String>>[];
  var row = <String>[];
  final field = StringBuffer();
  var quoted = false;
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (quoted) {
      if (c == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          field.write('"');
          i++;
        } else {
          quoted = false;
        }
      } else {
        field.write(c);
      }
    } else if (c == '"' && field.isEmpty) {
      quoted = true;
    } else if (c == sep) {
      row.add(field.toString());
      field.clear();
    } else if (c == '\n' || c == '\r') {
      if (c == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
      row.add(field.toString());
      field.clear();
      rows.add(row);
      row = <String>[];
    } else {
      field.write(c);
    }
  }
  if (field.isNotEmpty || row.isNotEmpty) {
    row.add(field.toString());
    rows.add(row);
  }
  return rows;
}

/// The slides of a PowerPoint deck (.pptx), in order.
List<Slide> readPptx(Uint8List bytes) {
  final zip = _zip(bytes);
  final names = [
    for (final f in zip.files)
      if (RegExp(r'^ppt/slides/slide(\d+)\.xml$').hasMatch(f.name)) f.name,
  ]..sort((a, b) => _number(a).compareTo(_number(b)));
  return [
    for (final name in names)
      Slide([
        for (final p in _xml(zip, name).findAllElements('a:p'))
          if (p.findAllElements('a:t').map((t) => t.innerText).join().trim()
              case final text when text.isNotEmpty)
            text,
      ]),
  ];
}

int _number(String name) =>
    int.tryParse(RegExp(r'(\d+)\.xml$').firstMatch(name)?[1] ?? '') ?? 0;

/// The slides of an OpenDocument presentation (.odp).
List<Slide> readOdp(Uint8List bytes) => [
  for (final page in _xml(
    _zip(bytes),
    'content.xml',
  ).findAllElements('draw:page'))
    Slide([
      for (final p in page.findAllElements('text:p'))
        if (p.innerText.trim() case final text when text.isNotEmpty) text,
    ]),
];

/// The entries of a zip, tar or gzipped tar archive.
List<ArchiveItem> readArchive(Uint8List bytes, String name) {
  final lower = name.toLowerCase();
  try {
    final Archive archive;
    if (lower.endsWith('.zip')) {
      archive = ZipDecoder().decodeBytes(bytes);
    } else if (lower.endsWith('.tar')) {
      archive = TarDecoder().decodeBytes(bytes);
    } else if (lower.endsWith('.tar.gz') || lower.endsWith('.tgz')) {
      archive = TarDecoder().decodeBytes(
        const GZipDecoder().decodeBytes(bytes),
      );
    } else {
      throw const DocumentUnreadable('This archive cannot be listed here.');
    }
    return [
      for (final f in archive.files) ArchiveItem(f.name, f.size, !f.isFile),
    ];
  } on DocumentUnreadable {
    rethrow;
  } catch (_) {
    throw const DocumentUnreadable('This archive could not be read.');
  }
}
