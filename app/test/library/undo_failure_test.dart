import 'dart:io';

import 'package:cache/app_fs.dart';
import 'package:cache/browse/browse_state.dart';
import 'package:cache/browse/web/device_files.dart';
import 'package:cache/library/book_pages.dart';
import 'package:cache/library/cds_shelf_source.dart';
import 'package:cache/library/library_pages.dart' show undoAndSay;
import 'package:cache/library/shelf_source.dart' show PartialPlacementException;
import 'package:cache/sources/libraries_state.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../browse/fakes.dart';
import 'fake_shelf_server.dart';
import 'library_fixtures.dart';

const _books = 3;

Map<String, dynamic> _unsorted(String id) => {
      'title': 'A rather long title for book number $id, kept long on purpose',
      'title_from': 'pack',
      'aka': <String>[],
      'reading': id,
      'copies': [
        {'copy': id, 'locs': ['field/$id'], 'available': true, 'title': id, 'own_call': null, 'locations': <Map<String, dynamic>>[]},
      ],
      'shelf': null,
      'shelved': false,
      'by': null,
      'call': null,
      'removed': false,
      'author': null,
      'edition': null,
      'year': null,
      'suggested': {'div': '350', 'label': null, 'from': 'pack'},
    };

void main() {
  late Directory tmp;
  late FakeSources sources;
  late LibrariesState libs;
  late FakeShelfServer server;
  late CdsShelfSource shelves;
  late BrowseState browse;
  var made = false;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('undo-fail');
    server = FakeShelfServer()
      ..viewJson = {
        'format': 1,
        'built_from': {'libraries': <String, dynamic>{}, 'logs': <String, dynamic>{}},
        'books': {for (var i = 0; i < _books; i++) 'b$i': _unsorted('b$i')},
        'retired': <String, dynamic>{},
        'next': <String, dynamic>{},
        'folders': <Map<String, dynamic>>[],
      };
    Directory('${tmp.path}/libraries').createSync(recursive: true);
    sources = FakeSources(Directory('${tmp.path}/zims')..createSync(recursive: true));
    libs = await librariesAt(Directory('${tmp.path}/libraries'), sources);
    shelves = CdsShelfSource(libs, server: server, deviceFiles: DeviceFiles(createAppFs(docsOverride: tmp)), clock: () => 5000);
    await shelves.whenRead();
    browse = BrowseState(sources: sources, libraries: libs, policy: testPolicy(), settingsDirOverride: tmp, phoneLanguage: 'en');
    made = true;
  });
  tearDown(() {
    if (made) {
      shelves.dispose();
      browse.dispose();
      libs.dispose();
      sources.dispose();
    }
    tmp.deleteSync(recursive: true);
  });

  Future<void> placeAll(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final d = testDeps(browse: browse, shelves: shelves);
    await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.light), home: UnsortedPage(deps: d)));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('place-all')));
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pumpAndSettle();
    expect(find.text('Placed 3 books. Each has its new call number.'), findsOneWidget);
  }

  testWidgets('Undo of Place all best guesses: when saving the undo fails the person sees an error, not silence', (tester) async {
    await placeAll(tester);
    server.failOnCall = server.eventCalls + 1;
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('placed-undo')));
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pumpAndSettle();
    expect(find.text('That could not be saved. Try again.'), findsOneWidget, reason: 'the person is told the undo did not happen');
    expect(shelves.unsorted, isEmpty, reason: 'the books are still placed');
  });

  Future<void> run(WidgetTester tester, Future<void> Function() undo) async {
    late ScaffoldMessengerState m;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (c) {
      m = ScaffoldMessenger.of(c);
      return const SizedBox();
    }))));
    await undoAndSay(m, undo);
    await tester.pumpAndSettle();
  }

  testWidgets('an Undo that stopped part way says how many books were put back', (tester) async {
    await run(tester, () async => throw const PartialPlacementException(2, 5, 'boom'));
    expect(find.text('Only 2 of 5 books put back. The rest could not be saved. Try again.'), findsOneWidget);
  });

  testWidgets('an Undo that fails with any other error says it could not be saved', (tester) async {
    await run(tester, () async => throw StateError('down'));
    expect(find.text('That could not be saved. Try again.'), findsOneWidget);
  });

  testWidgets('an Undo that works says nothing', (tester) async {
    await run(tester, () async {});
    expect(find.byType(SnackBar), findsNothing);
  });
}
