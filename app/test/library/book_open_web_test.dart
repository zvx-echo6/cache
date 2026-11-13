import 'dart:io';
import 'dart:typed_data';

import 'package:cache/app_fs.dart';
import 'package:cache/browse/browse_state.dart';
import 'package:cache/browse/web/device_files.dart';
import 'package:cache/library/book_pages.dart';
import 'package:cache/library/cds_shelf_source.dart';
import 'package:cache/linux_ui.dart';
import 'package:cache/pdf/pdf_reader_screen.dart';
import 'package:cache/pdf/pdf_source.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../browse/fakes.dart';
import 'fake_shelf_server.dart';
import 'library_fixtures.dart';

Map<String, dynamic> _view() => {
      'format': 1,
      'built_from': {'libraries': <String, dynamic>{}, 'logs': <String, dynamic>{}},
      'books': {
        'aid': {
          'title': 'Wilderness first aid',
          'title_from': 'pack',
          'aka': <String>[],
          'reading': 'aid',
          'copies': [
            {'copy': 'aid', 'locs': ['field/aid'], 'available': true, 'title': 'Wilderness first aid', 'own_call': null, 'locations': <Map<String, dynamic>>[]},
          ],
          'shelf': null,
          'shelved': false,
          'by': null,
          'call': null,
          'removed': false,
          'author': null,
          'edition': null,
          'year': null,
          'suggested': null,
        },
      },
      'retired': <String, dynamic>{},
      'next': <String, dynamic>{},
      'folders': <Map<String, dynamic>>[],
    };

/// Opens the server's book from its page in a window of [size]; [desktop] turns on Cache on Linux's desktop layout (the book pane
/// a browser shows at 1024 wide and up), which a widget test has to ask for.
Future<void> _opensFromServer(WidgetTester tester, Size size, {bool desktop = false}) async {
    if (desktop) {
      debugLinuxUi = true;
      addTearDown(() => debugLinuxUi = null);
    }
    final tmp = Directory.systemTemp.createTempSync('book-open-web');
    addTearDown(() => tmp.deleteSync(recursive: true));
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final server = FakeShelfServer()..viewJson = _view();
    final bytes = Uint8List.fromList([37, 80, 68, 70]);
    server.pdfs['field/aid'] = bytes;
    late FakeSources sources;
    late CdsShelfSource shelves;
    late BrowseState browse;
    await tester.runAsync(() async {
      writeBookLibrary(Directory('${tmp.path}/libraries'), 'field', const [('aid', 'Wilderness first aid', null, null)]);
      sources = FakeSources(Directory('${tmp.path}/zims')..createSync(recursive: true));
      final libs = await librariesAt(Directory('${tmp.path}/libraries'), sources);
      shelves = CdsShelfSource(libs, server: server, deviceFiles: DeviceFiles(createAppFs(docsOverride: tmp)), clock: () => 5000);
      await shelves.whenRead();
      browse = BrowseState(sources: sources, libraries: libs, policy: testPolicy(), settingsDirOverride: tmp, phoneLanguage: 'en');
    });
    addTearDown(() {
      shelves.dispose();
      browse.dispose();
    });
    final d = testDeps(browse: browse, shelves: shelves);
    await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.light), home: BookPage(deps: d, bookId: 'aid')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('book-open')), findsOneWidget, reason: 'the PDF is on the server: Open is offered');
    expect(find.byKey(const ValueKey('book-download')), findsNothing);
    await tester.ensureVisible(find.byKey(const ValueKey('book-open')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('book-open')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    final reader = tester.widget<PdfReaderScreen>(find.byType(PdfReaderScreen));
    final source = reader.source as PdfServerSource;
    expect((source.id, source.title, reader.initialPage), ('field/aid', 'Wilderness first aid', 1));
    expect(await tester.runAsync(source.fetch), bytes);
    expect(server.pdfAsked, ['field/aid']);
    await tester.pumpWidget(const SizedBox());
}

void main() {
  testWidgets('in a browser a book on the server has Open, which opens its PDF in the reader from the server\'s bytes', (tester) async {
    await _opensFromServer(tester, const Size(390, 1000));
  });

  testWidgets('at a desktop width the book pane has the same Open for a book on the server', (tester) async {
    await _opensFromServer(tester, const Size(1280, 900), desktop: true);
  });
}
