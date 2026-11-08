import 'dart:io';

import 'package:cache/library/cds_shelf_source.dart';
import 'package:cache/library/library_log.dart';
import 'package:cache/library/shelf_source.dart';
import 'package:cache/sources/libraries_state.dart';
import 'package:flutter_test/flutter_test.dart';

import '../browse/fakes.dart';
import 'library_fixtures.dart';

const _seed = '''
{"v":1,"at":1000,"dev":"builder-field","ev":"place","doc":"aid","div":"210","by":"auto"}
{"v":1,"at":1000,"dev":"builder-field","ev":"assign","doc":"aid","div":"210","seq":1}
{"v":1,"at":1000,"dev":"builder-field","ev":"place","doc":"surgery","div":"210","by":"auto"}
{"v":1,"at":1000,"dev":"builder-field","ev":"assign","doc":"surgery","div":"210","seq":2}
''';

void main() {
  late Directory tmp;
  late FakeSources sources;
  late LibrariesState libs;
  late CdsShelfSource shelves;

  Future<void> setUpShelves({String? log = _seed}) async {
    writeBookLibrary(Directory('${tmp.path}/libraries'), 'field', const [
      ('aid', 'Wilderness first aid', '210', '220'),
      ('surgery', 'Emergency war surgery', '210', null),
      ('bees', 'Keeping bees in cold climates', '350', '190'),
      ('engines', 'Small engine repair', '670', '690'),
      ('stone', 'Stone', null, null),
    ], log: log, compression: {'original_size': 58000000, 'stored_size': 41000000, 'level': 'smaller_scans', 'preset': 'balanced', 'kept_original': false});
    sources = FakeSources(Directory('${tmp.path}/zims')..createSync(recursive: true));
    libs = await librariesAt(Directory('${tmp.path}/libraries'), sources);
    shelves = CdsShelfSource(libs, deviceId: () async => 'phone-test', clock: () => 5000);
    await shelves.whenRead();
  }

  setUp(() => tmp = Directory.systemTemp.createTempSync('shelves'));
  tearDown(() {
    shelves.dispose();
    libs.dispose();
    sources.dispose();
    tmp.deleteSync(recursive: true);
  });

  test('a library of books: shelved by its log, the rest in Unsorted with the best guesses its packs hold', () async {
    await setUpShelves();
    expect(shelves.bookCount, 5);
    expect(shelves.shelves, hasLength(10), reason: 'every class shows, empty ones too');
    expect(shelves.shelf('000')!.children, hasLength(8), reason: '060 is never shown');
    final aid = shelves.booksOn('210');
    expect([for (final b in aid) b.callNumber], ['CDS 210-001', 'CDS 210-002']);
    expect(aid.first.title, 'Wilderness first aid');
    expect(aid.first.shelvedBy, ShelvedBy.cache);
    expect(aid.first.stored, 'Stored 39.1 MB (was 55.3 MB) · Smaller scans: Balanced');
    expect(shelves.countUnder(shelves.shelf('200')!), 2);
    expect([for (final b in shelves.unsorted) b.title], ['Keeping bees in cold climates', 'Small engine repair', 'Stone']);
    expect(shelves.unsorted.first.suggestions, ['350', '190']);
    expect(shelves.unsorted.last.suggestions, isEmpty, reason: 'nothing suggested: no guess is made up');
    expect(shelves.holdsBooks(libs.libraries.single), isTrue);
    expect(shelves.searchOf(aid.first).state, BookSearchState.waiting);
  });

  test('Go to a number: a class, a division, a call number', () async {
    await setUpShelves();
    expect(shelves.goTo('200')!.shelfId, '200');
    expect(shelves.goTo('530')!.shelfId, '530');
    final t = shelves.goTo('210-002')!;
    expect(shelves.book(t.bookId!)!.title, 'Emergency war surgery');
    expect(shelves.goTo('999'), isNull);
  });

  test('Place it writes place and assign in this device\'s own log; Undo puts it back in Unsorted and retires the number', () async {
    await setUpShelves();
    final bees = shelves.unsorted.first;
    expect(shelves.nextNumberFor(bees, '350'), 'CDS 350-001');
    final p = await shelves.place([(bees, '350')]);
    expect(p.books.single.callNumber, 'CDS 350-001');
    expect(shelves.book(bees.id)!.shelf, '350');
    expect(shelves.book(bees.id)!.shelvedBy, ShelvedBy.person);
    final log = File('${libs.libraries.single.path}/log/phone-test.jsonl').readAsStringSync();
    expect(log, '{"v":1,"at":5000,"dev":"phone-test","ev":"place","doc":"bees","div":"350","by":"user"}\n'
        '{"v":1,"at":5000,"dev":"phone-test","ev":"assign","doc":"bees","div":"350","seq":1}\n');
    await shelves.undo(p);
    expect(shelves.book(bees.id)!.unsorted, isTrue);
    expect(shelves.book(bees.id)!.callNumber, isNull);
    expect(shelves.nextNumberFor(bees, '350'), 'CDS 350-002', reason: 'the number given out is never used again');
    expect(readLogs(libs.libraries.single.dir).where((e) => e.dev == 'phone-test').map((e) => e.ev), [LogEv.place, LogEv.assign, LogEv.unsort, LogEv.retire]);
  });

  test('a move gets a new number in its new division; the old one is retired', () async {
    await setUpShelves();
    final aid = shelves.booksOn('210').first;
    final p = await shelves.place([(aid, '220')]);
    expect(p.books.single.callNumber, 'CDS 220-001');
    expect(shelves.booksOn('210').map((b) => b.callNumber), ['CDS 210-002'], reason: 'the other keeps its number');
    await shelves.undo(p);
    expect(shelves.book(aid.id)!.callNumber, 'CDS 210-003', reason: 'back in 210 with the next free number: 001 is retired');
  });

  test('Place all best guesses files each at its first suggestion; Undo reverses the whole batch', () async {
    await setUpShelves();
    final guessed = [for (final b in shelves.unsorted) if (b.suggestions.isNotEmpty) b];
    final p = await shelves.place([for (final b in guessed) (b, b.suggestions.first)]);
    expect([for (final x in p.books) x.callNumber], ['CDS 350-001', 'CDS 670-001']);
    expect(shelves.unsorted.map((b) => b.title), ['Stone']);
    await shelves.undo(p);
    expect(shelves.unsorted, hasLength(3));
  });

  test('a library with no log yet: every book in Unsorted; the guide and libraries without a catalogue are not books', () async {
    await setUpShelves(log: null);
    expect(shelves.unsorted, hasLength(5));
    expect(shelves.booksOn('210'), isEmpty);
  });
}
