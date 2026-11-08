import 'dart:convert';
import 'dart:io';

import 'package:cache/library/cds_shelf_source.dart';
import 'package:cache/library/shelf_source.dart';
import 'package:cache/sources/libraries_state.dart';
import 'package:flutter_test/flutter_test.dart';

import '../browse/fakes.dart';
import 'fake_shelves.dart';
import 'library_fixtures.dart';

const List<SampleBook> _field = [
  ('aid', 'Wilderness first aid', '210', '220'),
  ('surgery', 'Emergency war surgery', '210', null),
  ('bees', 'Keeping bees in cold climates', '350', '190'),
  ('engines', 'Small engine repair', '670', '690'),
  ('stone', 'Stone', null, null),
];

const _allChecked = ['aid', 'surgery', 'bees', 'engines', 'stone'];

/// The events this device wrote, without `v`, `dev` and `loc` (as a test reads them).
List<Map<String, dynamic>> _mine(FakeShelvesCalls f) => [
      for (final e in f.appended)
        if (e['dev'] == 'phone-test') {for (final k in e.keys) if (k != 'v' && k != 'dev' && k != 'loc') k: e[k]},
    ];

void main() {
  late Directory tmp;
  late FakeSources sources;
  late LibrariesState libs;
  final made = <CdsShelfSource>[];

  Directory shelvesDir([String name = 'bookshelves']) => Directory('${tmp.path}/$name');

  Future<CdsShelfSource> open(FakeShelvesCalls calls, {String dir = 'bookshelves', List<String> ownIds = const [], Duration? poll}) async {
    final s = CdsShelfSource(
      libs,
      calls: calls,
      bookshelvesDir: () async => shelvesDir(dir),
      deviceId: () async => 'phone-test',
      ownIds: () async => ownIds,
      pollEvery: poll,
      clock: () => 5000,
    );
    made.add(s);
    await s.whenRead();
    return s;
  }

  Future<void> library(String name, List<SampleBook> books, {Map<String, Map<String, dynamic>> extra = const {}, Map<String, Map<String, dynamic>> samebook = const {}, String? oldLog, String oldDev = 'phone-test'}) async {
    final d = writeBookLibrary(Directory('${tmp.path}/libraries'), name, books,
        extra: extra, samebook: samebook, compression: {'original_size': 58000000, 'stored_size': 41000000, 'level': 'smaller_scans', 'preset': 'balanced', 'kept_original': false});
    if (oldLog != null) {
      File('${d.path}/log/$oldDev.jsonl')
        ..createSync(recursive: true)
        ..writeAsStringSync(oldLog);
    }
  }

  Future<void> start() async {
    Directory('${tmp.path}/libraries').createSync(recursive: true);
    sources = FakeSources(Directory('${tmp.path}/zims')..createSync(recursive: true));
    libs = await librariesAt(Directory('${tmp.path}/libraries'), sources);
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('shelves');
    made.clear();
  });
  tearDown(() {
    for (final s in made) {
      s.dispose();
    }
    libs.dispose();
    sources.dispose();
    tmp.deleteSync(recursive: true);
  });

  test('the view: one book per group with its call number, title, also known as, spares, author, edition and year', () async {
    await library('field', const [('wm', 'Wilderness Medicine', '210', null), ('wm2', 'Wilderness Medicine, 7th ed', '210', null), ('water', 'Water', '530', null), ('gone', 'Gone', null, null)],
        extra: {'wm': {'original_blake3': 'A'}, 'wm2': {'original_blake3': 'B'}, 'water': {'original_blake3': 'C'}, 'gone': {'original_blake3': 'D'}});
    await start();
    // the view exactly as LIBRARY-LOG.md "The Bookshelves view" shows it
    final view = {
      'format': 1,
      'built_from': {'libraries': {'field': {'packs': 4, 'unreadable': 0}}, 'logs': {'tablet.jsonl': 812}},
      'books': {
        'A': {
          'title': 'Wilderness Medicine Handbook',
          'title_from': 'seed',
          'aka': ['Wilderness Medicine'],
          'reading': 'B',
          'copies': [
            {'copy': 'A', 'locs': ['field/wm'], 'available': true, 'title': 'Wilderness Medicine', 'own_call': {'div': '210', 'seq': 1, 'suffix': 0, 'text': 'CDS 210-001'}, 'locations': []},
            {'copy': 'B', 'locs': ['field/wm2'], 'available': true, 'title': 'Wilderness Medicine, 7th ed', 'own_call': {'div': '210', 'seq': 2, 'suffix': 0, 'text': 'CDS 210-002'}, 'locations': []},
            {'copy': 'E', 'locs': [], 'available': false, 'title': null, 'own_call': null,
             'locations': [{'dev': 'linux-a', 'folder_id': 'books', 'relpath': 'Medicine/wm.pdf', 'version': null, 'source_blake3': null}]},
          ],
          'shelf': '210', 'shelved': true, 'by': 'auto',
          'call': {'div': '210', 'seq': 1, 'suffix': 0, 'text': 'CDS 210-001'},
          'removed': false,
          'author': 'A. Writer', 'edition': '7th edition', 'year': 2018,
          'suggested': {'div': '610', 'label': 'Medicine', 'from': 'pack'},
        },
        'C': {
          'title': 'Water', 'title_from': 'pack', 'aka': [], 'reading': 'C',
          'copies': [{'copy': 'C', 'locs': ['field/water'], 'available': true, 'title': 'Water', 'own_call': null, 'locations': []}],
          'shelf': null, 'shelved': false, 'by': null, 'call': null, 'removed': false, 'author': null, 'edition': null, 'year': null,
          'suggested': {'div': '530', 'label': null, 'from': 'seed'},
        },
        'D': {
          'title': 'Gone', 'title_from': 'pack', 'aka': [], 'reading': 'D',
          'copies': [{'copy': 'D', 'locs': ['field/gone'], 'available': true, 'title': 'Gone', 'own_call': null, 'locations': []}],
          'shelf': null, 'shelved': true, 'by': 'user', 'call': null, 'removed': true, 'author': null, 'edition': null, 'year': null, 'suggested': null,
        },
      },
      'retired': {'210': [5]},
      'next': {'210': 6},
      'folders': [{'dev': 'linux-a', 'folder_id': 'books', 'label': 'Books', 'mode': 'keep'}],
    };
    writeShelves(shelvesDir(), checked: const ['A', 'B', 'C', 'D']);
    final s = await open(FakeShelvesCalls()..canned = view);
    expect(s.bookCount, 2, reason: 'one book for the two files; the hidden one is not shown');
    final b = s.booksOn('210').single;
    expect((b.id, b.title, b.callNumber, b.shelvedBy), ('A', 'Wilderness Medicine Handbook', 'CDS 210-001', ShelvedBy.cache));
    expect((b.author, b.edition), ('A. Writer', '7th edition, 2018'));
    expect(b.aka, ['Wilderness Medicine']);
    expect((b.reading, b.docId), ('B', 'wm2'), reason: 'read from the copy the view names');
    expect([for (final x in b.spares) (x.copy, x.title, x.where, x.here, x.bytes)], [
      ('A', 'Wilderness Medicine', 'Field library', true, 41000000),
      ('E', 'Wilderness Medicine Handbook', 'Books · Medicine/wm.pdf', false, null),
    ]);
    expect(s.book('B')?.id, 'A', reason: 'any of its files finds the book');
    expect(s.book('E')?.id, 'A');
    expect(s.unsorted.single.suggestions, ['530']);
    expect(s.nextNumber('210'), 'CDS 210-006');
    expect(s.nextNumber('350'), 'CDS 350-001');
    expect(s.book('D'), isNull);
    final written = jsonDecode(File('${shelvesDir().path}/.local/view.json').readAsStringSync());
    expect(written, view, reason: 'the view is kept in .local/view.json');
  });

  test('a library with neither copies.jsonl nor packs: its books are counted as not shelvable here, and old stubs are removed', () async {
    await library('field', _field);
    await library('more', const [('water', 'The water purification handbook', '530', null)]);
    Directory('${tmp.path}/libraries/field/packs').deleteSync(recursive: true);
    await start();
    writeShelves(shelvesDir(), placed: const [('water', '530', 1)], checked: const ['water']);
    final stubs = Directory('${shelvesDir().path}/.local/packs/field')..createSync(recursive: true);
    final s = await open(FakeShelvesCalls());
    expect(s.bookCount, 1);
    expect([for (final g in s.notShelved) (g.library, g.books)], [('Field library', 5)]);
    expect(stubs.existsSync(), isFalse, reason: 'the header stubs of the earlier build are gone');
    expect(File('${shelvesDir().path}/.local/view.json').existsSync(), isTrue, reason: 'the core keeps the view');
  });

  test('every action writes its events to this device\'s file: place, move, Undo, Unsorted, title, hide and show', () async {
    await library('field', _field);
    await start();
    writeShelves(shelvesDir(), placed: const [('aid', '210', 1), ('surgery', '210', 2)], checked: _allChecked);
    final f = FakeShelvesCalls();
    final s = await open(f);
    expect([for (final b in s.booksOn('210')) b.callNumber], ['CDS 210-001', 'CDS 210-002']);
    expect(s.unsorted.map((b) => b.title), ['Keeping bees in cold climates', 'Small engine repair', 'Stone']);
    expect(s.unsorted.first.suggestions, ['350', '190']);

    final bees = s.book('bees')!;
    expect(s.nextNumberFor(bees, '350'), 'CDS 350-001');
    final p = await s.place([(bees, '350')]);
    expect(p.books.single.callNumber, 'CDS 350-001');
    expect(s.book('bees')!.shelvedBy, ShelvedBy.person);
    expect(_mine(f), [
      {'at': 5000, 'ev': 'place', 'copy': 'bees', 'div': '350', 'by': 'user'},
      {'at': 5000, 'ev': 'assign', 'copy': 'bees', 'div': '350', 'seq': 1},
    ]);
    expect(File('${shelvesDir().path}/log/phone-test.jsonl').readAsLinesSync(), hasLength(2), reason: 'in this device\'s own file');
    f.appended.clear();
    await s.undo(p);
    expect(_mine(f), [
      {'at': 5000, 'ev': 'unsort', 'copy': 'bees', 'by': 'user'},
      {'at': 5000, 'ev': 'retire', 'copy': 'bees', 'div': '350', 'seq': 1},
    ]);
    expect(s.book('bees')!.unsorted, isTrue);
    expect(s.nextNumber('350'), 'CDS 350-002', reason: 'a number given out is never used again');

    f.appended.clear();
    final m = await s.place([(s.book('aid')!, '220')]);
    expect(_mine(f).map((e) => e['ev']), ['place', 'retire', 'assign']);
    expect(m.books.single.callNumber, 'CDS 220-001');
    expect(s.booksOn('210').map((b) => b.callNumber), ['CDS 210-002'], reason: 'the other keeps its number');
    await s.undo(m);
    expect(s.book('aid')!.callNumber, 'CDS 210-003', reason: 'back with the next free number: 001 is retired');

    f.appended.clear();
    await s.retitle(s.book('surgery')!, 'Emergency War Surgery, 5th US revision');
    expect(_mine(f), [{'at': 5000, 'ev': 'title', 'copy': 'surgery', 'title': 'Emergency War Surgery, 5th US revision'}]);
    expect(s.book('surgery')!.title, 'Emergency War Surgery, 5th US revision');
    final surgery = s.book('surgery')!;
    await s.hide(surgery);
    expect(s.book('surgery'), isNull);
    await s.hide(surgery, hidden: false);
    expect(s.book('surgery'), isNotNull);
    expect(_mine(f).skip(1).map((e) => e['ev']), ['remove', 'restore']);
  });

  test('a copy is checked for same books once: a match is one book with a spare, new books are shelved, a later copy alone is checked', () async {
    await library('field', const [('aid', 'Wilderness first aid', '210', null), ('aid2', 'Wilderness first aid, 2nd printing', '210', null), ('bees', 'Keeping bees in cold climates', '350', null)],
        samebook: {'aid': {'minhash': [1, 2, 3]}, 'aid2': {'minhash': [1, 2, 3]}, 'bees': {'minhash': [7, 8, 9]}});
    await start();
    final f = FakeShelvesCalls();
    final s = await open(f);
    expect(f.detectCalls, 1, reason: 'one batch call for every new copy');
    expect(f.detected, ['aid', 'aid2', 'bees']);
    expect(_mine(f), [
      {'at': 5000, 'ev': 'same', 'copy': 'aid2', 'with': 'aid', 'by': 'auto', 'how': 'text', 'score': 0.9},
      // new books in (title, copy) order, each in its suggested division with the next free number
      {'at': 5000, 'ev': 'place', 'copy': 'bees', 'div': '350', 'by': 'auto'},
      {'at': 5000, 'ev': 'assign', 'copy': 'bees', 'div': '350', 'seq': 1},
      {'at': 5000, 'ev': 'place', 'copy': 'aid', 'div': '210', 'by': 'auto'},
      {'at': 5000, 'ev': 'assign', 'copy': 'aid', 'div': '210', 'seq': 1},
    ]);
    final aid = s.booksOn('210').single;
    expect((aid.callNumber, aid.spares.single.title), ('CDS 210-001', 'Wilderness first aid, 2nd printing'));
    expect(aid.aka, ['Wilderness first aid, 2nd printing']);
    final checked = jsonDecode(File('${shelvesDir().path}/.local/detected.json').readAsStringSync());
    expect(checked['copies'], ['aid', 'aid2', 'bees']);

    // a new start: nothing is checked or written again
    s.dispose();
    made.remove(s);
    final f2 = FakeShelvesCalls();
    final again = await open(f2);
    expect(f2.detectCalls, 0);
    expect(f2.appended, isEmpty);
    expect(again.booksOn('210').single.spares, hasLength(1));

    // a library arrives: only its copy is checked
    await library('more', const [('water', 'The water purification handbook', '530', null)], samebook: {'water': {'minhash': [4, 5, 6]}});
    await libs.rescan();
    await again.whenRead();
    expect(f2.detectCalls, 1);
    expect(f2.detected, ['water'], reason: 'only the new copy is checked; the others are known');
    expect(again.booksOn('530').single.callNumber, 'CDS 530-001');
  });

  test('Read this copy instead, Not the same book, Same book as and its Undo write the person\'s choice', () async {
    await library('field', const [('aid', 'Wilderness first aid', '210', null), ('aid2', 'Wilderness first aid, 2nd printing', '210', null)],
        samebook: {'aid': {'minhash': [1, 2, 3]}, 'aid2': {'minhash': [1, 2, 3]}});
    await start();
    final f = FakeShelvesCalls();
    final s = await open(f);
    f.appended.clear();
    final book = s.booksOn('210').single;
    await s.readInstead(book, 'aid2');
    expect(_mine(f).single, {'at': 5000, 'ev': 'prefer', 'copy': 'aid2'});
    expect((s.book('aid')!.reading, s.book('aid')!.docId), ('aid2', 'aid2'));

    f.appended.clear();
    await s.notSame(s.book('aid')!, 'aid2');
    expect(_mine(f).single, {'at': 5000, 'ev': 'notsame', 'copy': 'aid2', 'with': 'aid', 'by': 'user'});
    expect(s.bookCount, 2);
    expect(s.booksOn('210').single.spares, isEmpty);
    expect(s.unsorted.single.id, 'aid2', reason: 'a file that was never shelved on its own goes to Unsorted');

    f.appended.clear();
    final (a2, a1) = (s.book('aid2')!, s.book('aid')!);
    final joined = await s.sameAs(a2, a1);
    expect(_mine(f).single, {'at': 5000, 'ev': 'same', 'copy': 'aid2', 'with': 'aid', 'by': 'user', 'how': 'user'});
    expect(s.bookCount, 1);
    expect(joined?.callNumber, 'CDS 210-001');
    f.appended.clear();
    await s.unjoin(a2, a1);
    expect(_mine(f).single['ev'], 'notsame');
    expect(s.bookCount, 2);
  });

  test('the import: this device\'s old per-library numbers carry over unchanged, and it runs once', () async {
    const old = '''
{"v":1,"at":10,"dev":"phone-test","ev":"place","doc":"aid","div":"210","by":"user"}
{"v":1,"at":11,"dev":"phone-test","ev":"assign","doc":"aid","div":"210","seq":4}
{"v":1,"at":12,"dev":"phone-test","ev":"place","doc":"bees","div":"350","by":"auto"}
{"v":1,"at":13,"dev":"phone-test","ev":"assign","doc":"bees","div":"350","seq":1}
''';
    await library('field', _field, oldLog: old);
    File('${tmp.path}/libraries/field/log/local-1234.jsonl').writeAsStringSync('{"v":1,"at":14,"dev":"local-1234","ev":"place","doc":"engines","div":"670","by":"user"}\n'
        '{"v":1,"at":15,"dev":"local-1234","ev":"assign","doc":"engines","div":"670","seq":2}\n');
    await start();
    final f = FakeShelvesCalls();
    final s = await open(f, ownIds: const ['local-1234']);
    expect(f.importedEvents, 6, reason: 'its own events, as this device and as this install before sharing');
    expect(s.book('aid')!.callNumber, 'CDS 210-004');
    expect(s.book('aid')!.shelvedBy, ShelvedBy.person);
    expect(s.book('bees')!.callNumber, 'CDS 350-001');
    expect(s.book('engines')!.callNumber, 'CDS 670-002');
    expect(s.book('surgery')!.callNumber, 'CDS 210-005', reason: 'a new book takes the next free number after the old ones');
    expect([for (final e in _mine(f)) if (e['copy'] == 'aid') e], isEmpty, reason: 'an imported book is not shelved again');

    s.dispose();
    made.remove(s);
    final f2 = FakeShelvesCalls();
    final again = await open(f2, ownIds: const ['local-1234']);
    expect(f2.imports, 2, reason: 'asked again on a new start...');
    expect(f2.importedEvents, 0, reason: '...and nothing is imported twice');
    expect([for (final b in [...again.booksOn('210'), ...again.booksOn('350'), ...again.booksOn('670')]) b.callNumber],
        ['CDS 210-004', 'CDS 210-005', 'CDS 350-001', 'CDS 670-002']);
  });

  test('two devices: the same logs give the same numbers, a clash shows its suffix, and a log arriving by sync is read', () async {
    await library('field', _field);
    await start();
    // apart, each device shelved a book in 210 as number 1
    final phone = writeShelves(shelvesDir('phone'), placed: const [('aid', '210', 1)], checked: _allChecked, dev: 'phone-test');
    final tablet = writeShelves(shelvesDir('tablet'), placed: const [('surgery', '210', 1)], checked: _allChecked);
    File('${tablet.path}/log/tablet.jsonl').writeAsStringSync(File('${tablet.path}/log/tablet.jsonl').readAsStringSync().replaceAll('"at":100', '"at":200'));
    final onPhone = await open(FakeShelvesCalls(), dir: 'phone', poll: const Duration(milliseconds: 20));
    expect(onPhone.booksOn('210').map((b) => b.callNumber), ['CDS 210-001']);
    // sync: each file reaches the other device; the phone reads it without being asked
    File('${phone.path}/log/tablet.jsonl').writeAsStringSync(File('${tablet.path}/log/tablet.jsonl').readAsStringSync());
    File('${tablet.path}/log/phone-test.jsonl').writeAsStringSync(File('${phone.path}/log/phone-test.jsonl').readAsStringSync());
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await onPhone.whenRead();
    final onTablet = await open(FakeShelvesCalls(), dir: 'tablet');
    List<(String, String?)> numbers(CdsShelfSource s) => [for (final b in s.booksOn('210')) (b.id, b.callNumber)];
    expect(numbers(onPhone), [('aid', 'CDS 210-001'), ('surgery', 'CDS 210-001.1')], reason: 'the first shelved keeps it; the other shows .1');
    expect(numbers(onTablet), numbers(onPhone), reason: 'both devices agree');
    expect(onPhone.nextNumber('210'), 'CDS 210-002');
  });
}
