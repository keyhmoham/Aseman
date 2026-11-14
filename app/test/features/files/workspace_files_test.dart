import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aseman/src/app.dart';
import 'package:aseman/src/app_dependencies.dart';
import 'package:aseman/src/core/network/api_client.dart';
import 'package:aseman/src/features/desk/data/desk_api.dart';
import 'package:aseman/src/features/desk/domain/desk_models.dart';
import 'package:aseman/src/features/desk/presentation/desk_controller.dart';
import 'package:aseman/src/features/files/data/workspace_files.dart';
import 'package:aseman/src/features/files/domain/documents.dart';
import 'package:aseman/src/features/files/domain/file_types.dart';
import 'package:aseman/src/features/files/presentation/code_view.dart';
import 'package:aseman/src/features/files/presentation/document_views.dart';
import 'package:aseman/src/features/files/presentation/file_tree.dart';
import 'package:aseman/src/features/files/presentation/file_viewer.dart';

import '../../fake_aseman_service.dart';

import '../../navigation.dart';

Uint8List _zip(Map<String, String> files) {
  final archive = Archive();
  for (final e in files.entries) {
    archive.addFile(ArchiveFile.string(e.key, e.value));
  }
  return ZipEncoder().encodeBytes(archive);
}

final _docx = _zip({
  'word/document.xml': '''
<w:document xmlns:w="w"><w:body>
  <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Quarterly report</w:t></w:r></w:p>
  <w:p><w:r><w:rPr><w:b/></w:rPr><w:t>Revenue</w:t></w:r><w:r><w:t xml:space="preserve"> grew.</w:t></w:r></w:p>
  <w:p><w:pPr><w:numPr><w:ilvl w:val="1"/></w:numPr></w:pPr><w:r><w:t>Second point</w:t></w:r></w:p>
  <w:tbl><w:tr><w:tc><w:p><w:r><w:t>Region</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>Sales</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
</w:body></w:document>''',
});

final _xlsx = _zip({
  'xl/workbook.xml':
      '<workbook xmlns:r="r"><sheets><sheet name="Prices" r:id="rId1"/></sheets></workbook>',
  'xl/_rels/workbook.xml.rels':
      '<Relationships><Relationship Id="rId1" Target="worksheets/sheet1.xml"/></Relationships>',
  'xl/sharedStrings.xml':
      '<sst><si><t>Ticker</t></si><si><t>AAPL</t></si></sst>',
  'xl/worksheets/sheet1.xml':
      '<worksheet><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="C1"><v>42</v></c></row>'
      '<row r="3"><c r="A3" t="s"><v>1</v></c></row></sheetData></worksheet>',
});

final _pptx = _zip({
  'ppt/slides/slide2.xml':
      '<p:sld xmlns:a="a" xmlns:p="p"><a:p><a:r><a:t>Next steps</a:t></a:r></a:p></p:sld>',
  'ppt/slides/slide1.xml':
      '<p:sld xmlns:a="a" xmlns:p="p"><a:p><a:r><a:t>Welcome</a:t></a:r></a:p><a:p><a:r><a:t>Agenda</a:t></a:r></a:p></p:sld>',
});

// A 1×1 transparent PNG.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
);

/// Plays the node's desk: windows opened are kept and read back.
class _DeskClient extends AsemanApiClient {
  _DeskClient() : super(baseUrl: 'http://localhost:8080');
  final windows = <Map<String, dynamic>>[];
  var version = 1;

  Map<String, dynamic> get desk => {
    'version': version,
    'viewport': {'w': 1000, 'h': 700},
    'windows': windows,
    'pins': <dynamic>[],
  };

  @override
  Future<ApiResponse> call(
    String namespace,
    String action, {
    Map<String, dynamic> body = const {},
    Duration? requestTimeout,
  }) async {
    if (action == 'desktop_get') return ApiResponse(200, {'desktop': desk});
    if (action == 'desktop_update') {
      final ids = <String>[];
      for (final op in (body['ops'] as List).cast<Map<String, dynamic>>()) {
        if (op['op'] != 'open') continue;
        final id = 'w${windows.length + 1}';
        windows.add({
          ...op,
          'id': id,
          'name': 'Files',
          'x': 40,
          'y': 40,
          'w': 600,
          'h': 480,
          'z': windows.length + 1,
        });
        ids.add(id);
      }
      version++;
      return ApiResponse(200, {'desktop': desk, 'ids': ids});
    }
    return super.call(
      namespace,
      action,
      body: body,
      requestTimeout: requestTimeout,
    );
  }
}

/// A workspace with a few files, answering `spaces.sandbox_files`.
class _Service extends FakeAsemanService {
  _Service({super.client});
  final reads = <String>[];
  final changes = <String>[];
  bool needsComputer = false;
  bool awake = false;
  final files = <String, Uint8List>{
    'README.md': utf8.encode(
      '# Atlas\n\nThe **desk** of the fund.\n\n- one\n- two',
    ),
    'src/main.dart': utf8.encode('void main() {\n  print("hi");\n}\n'),
    'data/prices.csv': utf8.encode('ticker,price\nAAPL,"1,234.5"\n'),
    'docs/report.docx': _docx,
    'docs/prices.xlsx': _xlsx,
    'docs/deck.pptx': _pptx,
    'logo.png': _png,
    'site/index.html': utf8.encode('<html><body><h1>Hi</h1></body></html>'),
    'blob.bin': Uint8List.fromList([0, 1, 2, 65, 66, 255]),
  };

  @override
  Future<dynamic> invokeAction(
    String namespace,
    String action, {
    Map<String, dynamic> body = const {},
    Duration? timeout,
    bool anonymous = false,
  }) async {
    if ('$namespace.$action' == 'spaces.computer') {
      if (body['operation'] == 'provision') awake = true;
      return {'ok': true, 'operation': body['operation']};
    }
    if ('$namespace.$action' != 'spaces.sandbox_files') {
      return super.invokeAction(
        namespace,
        action,
        body: body,
        timeout: timeout,
        anonymous: anonymous,
      );
    }
    final path = '${body['path']}';
    final op = '${body['operation']}';
    if (const {'write', 'mkdir', 'move', 'delete'}.contains(op)) {
      changes.add(
        '$op $path${body['to'] == null ? '' : ' ${body['to']}'}'
        '${body['wake'] == true ? ' (wake)' : ''}',
      );
      // Simulate asleep computer until a spaces.computer provision ran.
      if (needsComputer && !awake) {
        return {
          'ok': false,
          'asleep': true,
          'needs_wake': true,
          'error': 'This change needs the computer awake.',
        };
      }
      switch (op) {
        case 'write':
          files[path] = base64Decode('${body['data_base64']}');
        case 'mkdir':
          files['$path/.keep'] = Uint8List(0);
        case 'move':
          for (final k in files.keys.toList()) {
            if (k == path || k.startsWith('$path/')) {
              files['${body['to']}${k.substring(path.length)}'] = files.remove(
                k,
              )!;
            }
          }
        case 'delete':
          files.removeWhere((k, _) => k == path || k.startsWith('$path/'));
      }
      return {'ok': true};
    }
    if (body['operation'] == 'list') {
      final prefix = path.isEmpty ? '' : '$path/';
      final names = <String, bool>{};
      for (final f in files.keys) {
        if (!f.startsWith(prefix)) continue;
        final rest = f.substring(prefix.length).split('/');
        names[rest.first] = rest.length > 1;
      }
      return {
        'items': [
          for (final e in names.entries)
            {
              'name': e.key,
              'type': e.value ? 'dir' : 'file',
              'size': files['$prefix${e.key}']?.length ?? 0,
            },
        ],
      };
    }
    reads.add(path);
    final bytes = files[path];
    if (bytes == null) {
      return {
        'ok': false,
        'missing': true,
        'error': 'That file does not exist.',
      };
    }
    return {
      'content': utf8.decode(bytes, allowMalformed: true),
      'data_base64': base64Encode(bytes),
      'size': bytes.length,
    };
  }
}

void main() {
  tearDown(
    () => TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher
        .clearAllTestValues(),
  );

  test('each file type has its viewer, icon and language', () {
    expect(FileType.of('main.dart').language, 'dart');
    expect(FileType.of('app/server.py').language, 'python');
    expect(FileType.of('index.TSX').language, 'typescript');
    expect(FileType.of('Dockerfile').language, 'dockerfile');
    expect(FileType.of('Dockerfile').icon, Icons.directions_boat_outlined);
    expect(FileType.of('.gitignore').kind, FileKind.code);
    expect(FileType.of('notes.md').kind, FileKind.markdown);
    expect(FileType.of('a.png').kind, FileKind.image);
    expect(FileType.of('a.svg').kind, FileKind.svg);
    expect(FileType.of('site/index.html').kind, FileKind.html);
    expect(FileType.of('site/index.html').language, 'xml');
    expect(FileType.of('site/index.html').icon, Icons.html_rounded);
    expect(FileType.of('clip.mp4').kind, FileKind.video);
    expect(FileType.of('song.mp3').kind, FileKind.audio);
    expect(FileType.of('book.pdf').kind, FileKind.pdf);
    expect(FileType.of('memo.docx').kind, FileKind.document);
    expect(FileType.of('sheet.xlsx').kind, FileKind.spreadsheet);
    expect(FileType.of('deck.pptx').kind, FileKind.presentation);
    expect(FileType.of('dist.tar.gz').kind, FileKind.archive);
    expect(FileType.of('noext').kind, FileKind.text);
    expect(FileType.of('a.ts').color, isNot(FileType.of('a.py').color));
    expect(FileType.mimeOf('x.webm'), 'video/webm');
  });

  test('workspace paths are relative to /workspace for the node', () {
    expect(WorkspaceFiles.relative('/workspace'), '');
    expect(WorkspaceFiles.relative('/workspace/src/a.go'), 'src/a.go');
    expect(WorkspaceFiles.relative('src/a.go'), 'src/a.go');
  });

  test('documents read their structure', () {
    final doc = readDocx(_docx);
    expect(doc[0].kind, DocBlockKind.heading);
    expect(doc[0].text, 'Quarterly report');
    expect(doc[1].runs.first.bold, isTrue);
    expect(doc[1].text, 'Revenue grew.');
    expect(doc[2].kind, DocBlockKind.listItem);
    expect(doc[2].level, 1);
    expect(doc[3].rows, [
      ['Region', 'Sales'],
    ]);

    final sheet = readXlsx(_xlsx).single;
    expect(sheet.name, 'Prices');
    expect(sheet.rows[0], ['Ticker', '', '42']);
    expect(sheet.rows[1], isEmpty);
    expect(sheet.rows[2], ['AAPL']);

    final slides = readPptx(_pptx);
    expect(slides.map((s) => s.paragraphs.first), ['Welcome', 'Next steps']);

    expect(readDelimited('a,"b,""c"""\n1\t2\r\n', tabs: false), [
      ['a', 'b,"c"'],
      ['1\t2'],
    ]);
    expect(readArchive(_docx, 'x.zip').single.name, 'word/document.xml');
    expect(
      () => readDocx(Uint8List.fromList([1, 2, 3])),
      throwsA(isA<DocumentUnreadable>()),
    );
  });

  test('code is highlighted by language', () {
    const view = CodeView(source: 'void main() {}', language: 'dart');
    final spans = view.highlighted('void main() {}', {
      'keyword': Colors.red,
      'title': Colors.blue,
    });
    expect(spans.length, greaterThan(1));
    const plain = CodeView(source: 'x');
    expect(plain.highlighted('x', const {}).single.text, 'x');
  });

  Future<void> pumpViewer(
    WidgetTester tester,
    _Service service,
    String path,
  ) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WorkspaceFileViewer(
            key: ValueKey(path),
            service: service,
            spaceId: 's1',
            path: '/workspace/$path',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the viewer shows each kind of file as what it is', (
    tester,
  ) async {
    final service = _Service();

    await pumpViewer(tester, service, 'src/main.dart');
    expect(service.reads.last, 'src/main.dart');
    expect(find.byType(CodeView), findsOneWidget);
    expect(
      find.textContaining('print("hi")', findRichText: true),
      findsWidgets,
    );
    expect(find.byTooltip('Copy'), findsOneWidget);

    await pumpViewer(tester, service, 'README.md');
    expect(find.textContaining('Atlas', findRichText: true), findsWidgets);
    expect(find.textContaining('# Atlas', findRichText: true), findsNothing);
    await tester.tap(find.byTooltip('Source'));
    await tester.pumpAndSettle();
    expect(find.textContaining('# Atlas', findRichText: true), findsWidgets);

    await pumpViewer(tester, service, 'data/prices.csv');
    expect(find.text('1,234.5'), findsOneWidget);
    expect(find.text('A'), findsOneWidget);

    await pumpViewer(tester, service, 'docs/report.docx');
    expect(find.byType(DocumentPageView), findsOneWidget);
    expect(
      find.textContaining('Quarterly report', findRichText: true),
      findsOneWidget,
    );
    expect(find.text('Region'), findsOneWidget);

    await pumpViewer(tester, service, 'docs/prices.xlsx');
    expect(find.text('Ticker'), findsOneWidget);
    expect(find.text('42'), findsOneWidget);

    await pumpViewer(tester, service, 'docs/deck.pptx');
    expect(find.text('Slide 2'), findsOneWidget);
    expect(find.text('Next steps'), findsOneWidget);

    await pumpViewer(tester, service, 'logo.png');
    expect(find.byType(Image), findsOneWidget);
    expect(find.byTooltip('Zoom in'), findsOneWidget);

    // Where pages cannot be rendered in the app, HTML is its source.
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    await pumpViewer(tester, service, 'site/index.html');
    expect(find.byType(CodeView), findsOneWidget);
    expect(find.byTooltip('Preview'), findsNothing);
    expect(
      find.textContaining('<h1>Hi</h1>', findRichText: true),
      findsWidgets,
    );
    debugDefaultTargetPlatformOverride = null;
    // Where they can, it opens rendered, its source a toggle away.
    await pumpViewer(tester, service, 'site/index.html');
    expect(find.byTooltip('Preview'), findsOneWidget);
    expect(find.byType(CodeView), findsNothing);
    await tester.tap(find.byTooltip('Source'));
    await tester.pumpAndSettle();
    expect(find.byType(CodeView), findsOneWidget);

    await pumpViewer(tester, service, 'blob.bin');
    expect(find.textContaining('Binary file'), findsOneWidget);

    await pumpViewer(tester, service, 'gone.txt');
    expect(find.text('Could not open gone.txt'), findsOneWidget);
    expect(find.text('That file does not exist.'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('the tree opens folders as they are expanded', (tester) async {
    final opened = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 260,
            child: WorkspaceFileTree(
              service: _Service(),
              spaceId: 's1',
              onOpen: (e) => opened.add(e.path),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // Folders first.
    expect(
      tester.getTopLeft(find.text('src')).dy,
      lessThan(tester.getTopLeft(find.text('README.md')).dy),
    );
    expect(find.text('main.dart'), findsNothing);
    await tester.tap(find.text('src'));
    await tester.pumpAndSettle();
    expect(find.text('main.dart'), findsOneWidget);
    await tester.tap(find.text('main.dart'));
    expect(opened, ['/workspace/src/main.dart']);
    await tester.tap(find.byTooltip('Collapse folders'));
    await tester.pumpAndSettle();
    expect(find.text('main.dart'), findsNothing);
  });

  testWidgets('files and folders are made, renamed and deleted in the tree', (
    tester,
  ) async {
    final service = _Service();
    final opened = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 260,
            child: WorkspaceFileTree(
              service: service,
              spaceId: 's1',
              onOpen: (e) => opened.add(e.path),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // A new folder, from the tree's New menu; its placeholder is not shown.
    await tester.tap(find.byTooltip('New'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New folder'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'notes');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(service.changes, ['mkdir notes']);
    expect(find.text('notes'), findsOneWidget);
    expect(find.text('.keep'), findsNothing);

    // A new file in it, from the folder's own menu (a right click); it opens.
    await tester.tap(find.text('notes'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('New file'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'todo.md');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(service.changes.last, 'write notes/todo.md');
    expect(opened, ['/workspace/notes/todo.md']);
    expect(find.text('todo.md'), findsOneWidget);

    // Renamed (a long press opens the menu on a touch screen) …
    await tester.longPress(find.text('todo.md'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'plan.md');
    await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
    await tester.pumpAndSettle();
    expect(service.changes.last, 'move notes/todo.md notes/plan.md');
    expect(find.text('plan.md'), findsOneWidget);

    // … and deleted, once confirmed. The computer was never woken.
    await tester.longPress(find.text('plan.md'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(service.changes.last, 'delete notes/plan.md');
    expect(find.text('plan.md'), findsNothing);
    expect(service.changes.where((c) => c.contains('(wake)')), isEmpty);
  });

  testWidgets('a text file is edited and saved in the viewer', (tester) async {
    final service = _Service();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WorkspaceFileViewer(
            service: service,
            spaceId: 's1',
            path: '/workspace/src/main.dart',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Edit'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'void main() {}\n');
    await tester.pump();
    expect(find.text('Unsaved'), findsOneWidget);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(service.changes, ['write src/main.dart']);
    expect(utf8.decode(service.files['src/main.dart']!), 'void main() {}\n');
    expect(find.text('Saved'), findsOneWidget);
  });

  testWidgets('a change only the computer can make asks before waking it', (
    tester,
  ) async {
    final service = _Service()..needsComputer = true;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WorkspaceFileViewer(
            service: service,
            spaceId: 's1',
            path: '/workspace/README.md',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Edit'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '# New');
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Wake the computer?'), findsOneWidget);
    await tester.tap(find.text('Wake and continue'));
    await tester.pumpAndSettle();
    // First write fails (asleep); after provision, write succeeds (no wake flag).
    expect(service.changes, ['write README.md', 'write README.md']);
    expect(utf8.decode(service.files['README.md']!), '# New');
  });

  test('a file opens as a file window on the desk', () async {
    final sent = <Map<String, dynamic>>[];
    final controller = DeskController(
      DeskApi((ns, action, body, {timeout}) async {
        if (action == 'desktop_get') {
          return {
            'desktop': {
              'version': 1,
              'windows': <dynamic>[],
              'pins': <dynamic>[],
            },
          };
        }
        sent.addAll((body['ops'] as List).cast<Map<String, dynamic>>());
        return {
          'desktop': {
            'version': 2,
            'windows': <dynamic>[],
            'pins': <dynamic>[],
          },
          'ids': ['w1'],
        };
      }),
      pollEvery: const Duration(hours: 1),
    );
    controller.attach('space1', 'home');
    expect(await controller.openFile('/workspace/src/main.dart'), 'w1');
    expect(sent.single, {
      'op': 'open',
      'tool': 'files',
      'kind': 'file',
      'title': 'main.dart',
      'args': {'path': '/workspace/src/main.dart'},
      'w': 680.0,
      'h': 620.0,
    });
    controller.dispose();

    final w = DeskWindow.fromJson({
      'id': 'w1',
      'tool': 'files',
      'kind': 'file',
      'args': {'path': '/workspace/a.md'},
    });
    expect(w.isFile, isTrue);
    expect(w.filePath, '/workspace/a.md');
    expect(w.argsSummary, isEmpty);
  });

  testWidgets('on a wide screen a file opens as a card window on the desk', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'aseman.session':
          '{"account_id":"00000000000000010000000000000001","handle":"test",'
          '"token":"x","private_key":"","public_key":"",'
          '"home_space_id":"00000000000000010000000000000002"}',
    });
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    final client = _DeskClient();
    final service = _Service(client: client);
    await tester.pumpWidget(
      AsemanApp(dependencies: AppDependencies.withService(service)),
    );
    await tester.pumpAndSettle();
    await openSpaceRoom(tester);
    await tester.tap(find.byTooltip('Files'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('src'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('main.dart'));
    await tester.pumpAndSettle();

    final opened = client.windows.single;
    expect(opened['kind'], 'file');
    expect(opened['tool'], 'files');
    expect(opened['args'], {'path': '/workspace/src/main.dart'});
    // The window shows the file with the viewer, under its own title bar.
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.byType(WorkspaceFileViewer), findsOneWidget);
    expect(find.byType(CodeView), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'the space has a Files tab, not a Sandbox Explorer app, and on a phone '
    'a file opens in a bottom sheet',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'aseman.session':
            '{"account_id":"00000000000000010000000000000001","handle":"test",'
            '"token":"x","private_key":"","public_key":"",'
            '"home_space_id":"00000000000000010000000000000002"}',
      });
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      final service = _Service();
      await tester.pumpWidget(
        AsemanApp(dependencies: AppDependencies.withService(service)),
      );
      await tester.pumpAndSettle();
      await openSpaceRoom(tester);

      await tester.tap(find.byTooltip('Apps'));
      await tester.pumpAndSettle();
      expect(find.text('Sandbox Explorer'), findsNothing);

      tester.view.physicalSize = const Size(390, 844);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Rooms and workspace'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Files'));
      await tester.pumpAndSettle();
      expect(find.text('README.md'), findsOneWidget);
      await tester.tap(find.text('README.md'));
      await tester.pumpAndSettle();
      expect(find.byType(WorkspaceFileViewer), findsOneWidget);
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.textContaining('The ', findRichText: true), findsWidgets);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(WorkspaceFileViewer), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
