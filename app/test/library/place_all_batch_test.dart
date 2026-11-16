import 'dart:convert';
import 'dart:io';

import 'package:cache/app_fs.dart';
import 'package:cache/browse/browse_state.dart';
import 'package:cache/browse/web/device_files.dart';
import 'package:cache/library/book_pages.dart';
import 'package:cache/library/cds_shelf_source.dart';
import 'package:cache/sources/libraries_state.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../browse/fakes.dart';
import 'fake_shelf_server.dart';
import 'library_fixtures.dart';

const _books = 6000;
const _limit = 1 << 20; // the server's MAX_BODY

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
    tmp = Directory.systemTemp.createTempSync('placeall-batch');
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

  int bytes(List<Map<String, dynamic>> e) => utf8.encode(jsonEncode(e)).length;

  test('placing thousands of books sends several requests, each well under the server body limit, and every book is placed once', () async {
    expect(shelves.unsorted, hasLength(_books));
    final moves = [for (final b in shelves.unsorted) (b, '350')];
    final p = await shelves.place(moves);
    expect(p.books, hasLength(_books));
    expect(server.sent.length, greaterThan(1));
    for (final call in server.sent) {
      expect(bytes(call), lessThan(_limit ~/ 2), reason: 'each request stays well under 1 MiB');
    }
    final events = [for (final c in server.sent) ...c];
    expect(events.where((e) => e['ev'] == 'place'), hasLength(_books));
    expect(events.where((e) => e['ev'] == 'assign'), hasLength(_books));
    final seqs = [for (final e in events) if (e['ev'] == 'assign') e['seq'] as int];
    expect(seqs.toSet(), hasLength(_books), reason: 'no number is used twice across the batches');
  });

  testWidgets('Place all best guesses: when a batch fails the person sees an error, and the batches already sent stay', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    server.failOnCall = 2;
    final d = testDeps(browse: browse, shelves: shelves);
    await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.light), home: UnsortedPage(deps: d)));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('place-all')));
      await Future<void>.delayed(const Duration(seconds: 3));
    });
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('placed-snack')), findsNothing, reason: 'it did not all work, so no success message');
    expect(find.byType(SnackBar), findsOneWidget, reason: 'the person is told');
    expect(find.textContaining('could not'), findsOneWidget);
    expect(server.sent, hasLength(1), reason: 'the first batch was sent and is not rolled back');
  });
}
