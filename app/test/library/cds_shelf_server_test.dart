import 'dart:io';

import 'package:cache/app_fs.dart';
import 'package:cache/browse/web/device_files.dart';
import 'package:cache/library/cds_shelf_source.dart';
import 'package:cache/library/shelf_source.dart';
import 'package:cache/sources/libraries_state.dart';
import 'package:flutter_test/flutter_test.dart';

import '../browse/fakes.dart';
import 'fake_shelf_server.dart';
import 'library_fixtures.dart';

Map<String, dynamic> _book(String id, {String? shelf, String? call, bool removed = false, String? suggested, String? by, String? author, int? year, String? title}) => {
      'title': title ?? id,
      'title_from': 'pack',
      'aka': <String>[],
      'reading': id,
      'copies': [
        {
          'copy': id,
          'locs': ['field/$id'],
          'available': true,
          'title': title ?? id,
          'own_call': call == null ? null : {'div': shelf, 'seq': int.parse(call.split('-').last), 'suffix': 0, 'text': call},
          'locations': <Map<String, dynamic>>[],
        },
      ],
      'shelf': shelf,
      'shelved': shelf != null || removed,
      'by': by,
      'call': call == null ? null : {'div': shelf, 'seq': int.parse(call.split('-').last), 'suffix': 0, 'text': call},
      'removed': removed,
      'author': author,
      'edition': null,
      'year': year,
      'suggested': suggested == null ? null : {'div': suggested, 'label': null, 'from': 'pack'},
    };

void main() {
  late Directory tmp;
  late FakeSources sources;
  late LibrariesState libs;
  late FakeShelfServer server;
  final made = <CdsShelfSource>[];

  Future<CdsShelfSource> open({Duration? poll}) async {
    final s = CdsShelfSource(
      libs,
      server: server,
      deviceFiles: DeviceFiles(createAppFs(docsOverride: tmp)),
      pollEvery: poll,
      clock: () => 5000,
    );
    made.add(s);
    await s.whenRead();
    return s;
  }

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('shelves-web');
    made.clear();
    server = FakeShelfServer()
      ..viewJson = {
        'format': 1,
        'built_from': {'libraries': <String, dynamic>{}, 'logs': <String, dynamic>{}},
        'books': {
          'aid': _book('aid', shelf: '210', call: 'CDS 210-001', by: 'auto', author: 'A. Writer', year: 2018, title: 'Wilderness first aid'),
          'bees': _book('bees', suggested: '350', title: 'Keeping bees in cold climates'),
          'surgery': _book('surgery', shelf: '210', call: 'CDS 210-002', removed: true, title: 'Emergency war surgery'),
        },
        'retired': <String, dynamic>{},
        'next': {'210': 3},
        'folders': <Map<String, dynamic>>[],
      }
      ..factsJson = {
        'field': {
          'aid': {
            'cdoc': 1,
            'doc_id': 'aid',
            'page_count': 120,
            'source': {'size': 58000000, 'blake3': sampleHash('aid')},
            'book': {
              'compression': {'original_size': 58000000, 'stored_size': 41000000, 'level': 'smaller_scans', 'preset': 'balanced', 'kept_original': false},
              'suggested': {'div': '210', 'second_div': '220'},
            },
          },
        },
      };
    writeBookLibrary(Directory('${tmp.path}/libraries'), 'field', const [
      ('aid', 'Wilderness first aid', '210', null),
      ('surgery', 'Emergency war surgery', '210', null),
      ('bees', 'Keeping bees in cold climates', '350', null),
      ('engines', 'Small engine repair', '670', null),
      ('stone', 'Stone', null, null),
    ]);
    sources = FakeSources(Directory('${tmp.path}/zims')..createSync(recursive: true));
    libs = await librariesAt(Directory('${tmp.path}/libraries'), sources);
  });
  tearDown(() {
    for (final s in made) {
      s.dispose();
    }
    libs.dispose();
    sources.dispose();
    tmp.deleteSync(recursive: true);
  });

  test('the shelves are the server\'s: books, call numbers, hidden books and the packs\' facts, with no file of the book here', () async {
    final s = await open();
    expect(s.bookCount, 2, reason: 'aid and bees; the hidden one is not shown');
    final aid = s.booksOn('210').single;
    expect((aid.id, aid.title, aid.callNumber, aid.shelvedBy), ('aid', 'Wilderness first aid', 'CDS 210-001', ShelvedBy.cache));
    expect((aid.author, aid.edition, aid.pages), ('A. Writer', '2018', 120));
    expect(aid.suggestions, ['210', '220'], reason: 'from the pack\'s header the server gave');
    expect(aid.stored, isNotNull, reason: 'what the pack says was stored');
    expect(aid.bytes, 41000000);
    expect(aid.onServer, isTrue, reason: 'the PDF is on the server');
    expect(aid.pdfPath, isNull, reason: 'the browser has no file of it');
    final bees = s.unsorted.single;
    expect(bees.id, 'bees');
    expect(bees.suggestions, ['350'], reason: 'a book without facts shows what the view suggests');
    expect(bees.onServer, isTrue);
    expect(s.hidden.single.id, 'surgery');
    expect(s.nextNumber('210'), 'CDS 210-003');
    expect([for (final g in s.notShelved) (g.library, g.books)], [('Field library', 2)], reason: 'engines and stone are in the catalogue and not in the view');
    expect(s.holdsBooks(libs.libraries.single), isTrue);
    expect(s.placer, isNotNull);
    expect(s.copies, isNotNull);
  });

  test('what a person does is sent to the server as events, one call each, and the books are read again', () async {
    final s = await open();
    final before = server.views;
    final bees = s.book('bees')!;
    expect(s.nextNumberFor(bees, '350'), 'CDS 350-001');
    final p = await s.place([(bees, '350')]);
    expect(p.books.single.callNumber, 'CDS 350-001');
    expect(server.sent.single, [
      {'at': 5000, 'ev': 'place', 'copy': 'bees', 'div': '350', 'by': 'user'},
      {'at': 5000, 'ev': 'assign', 'copy': 'bees', 'div': '350', 'seq': 1},
    ]);
    expect(server.views, greaterThan(before), reason: 'the view is read again after a change');
    server.sent.clear();
    await s.hide(s.book('aid')!);
    expect(server.sent.single, [
      {'at': 5000, 'ev': 'remove', 'copy': 'aid'},
    ]);
    server.sent.clear();
    await s.retitle(s.book('aid')!, 'First aid in the wild');
    expect(server.sent.single, [
      {'at': 5000, 'ev': 'title', 'copy': 'aid', 'title': 'First aid in the wild'},
    ]);
    server.sent.clear();
    await s.unsort(s.book('aid')!);
    expect([for (final e in server.sent.single) e['ev']], ['unsort', 'retire'], reason: 'the server numbers and files a book itself; it takes these as the page wrote them');
  });

  test('a change on the server shows without being asked, and an unchanged stamp reads nothing', () async {
    final s = await open(poll: const Duration(milliseconds: 20));
    await Future<void>.delayed(const Duration(milliseconds: 120));
    await s.whenRead();
    expect(server.views, 1, reason: 'the stamp did not change');
    expect(server.stamps, greaterThan(1));
    server.viewJson['books']['bees'] = _book('bees', shelf: '350', call: 'CDS 350-001', by: 'user', title: 'Keeping bees in cold climates');
    server.stampText = 's2';
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await s.whenRead();
    expect(s.booksOn('350').single.callNumber, 'CDS 350-001');
    expect(s.booksOn('350').single.shelvedBy, ShelvedBy.person);
  });

  test('with the server down the books show from their catalogues, in Unsorted, and nothing can be placed', () async {
    server.down = true;
    final s = await open();
    expect(s.bookCount, 5);
    expect(s.unsorted, hasLength(5));
    expect(s.placer, isNull);
    expect(s.copies, isNull);
    expect(() => s.hide(s.unsorted.first), throwsA(anything));
  });
}
