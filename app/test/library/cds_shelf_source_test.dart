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

  Future<CdsShelfSource> open(FakeShelvesCalls calls,
      {String dir = 'bookshelves', List<String> ownIds = const [], Duration? poll, String dev = 'phone-test', int clock = 5000, void Function(String)? log}) async {
    final s = CdsShelfSource(
      libs,
      calls: calls,
      bookshelvesDir: () async => shelvesDir(dir),
      deviceId: () async => dev,
      ownIds: () async => ownIds,
      pollEvery: poll,
      clock: () => clock,
      log: log ?? (_) {},
    );
    made.add(s);
    await s.whenRead();
    return s;
  }

  Future<void> library(String name, List<SampleBook> books,
      {Map<String, Map<String, dynamic>> extra = const {},
      Map<String, Map<String, dynamic>> samebook = const {},
      String? oldLog,
      String oldDev = 'phone-test',
      bool own = false,
      Set<String> unsure = const {},
      Set<String> noFlag = const {}}) async {
    final d = writeBookLibrary(Directory('${tmp.path}/libraries'), name, books,
        extra: extra, samebook: samebook, own: own, unsure: unsure, noFlag: noFlag, compression: {'original_size': 58000000, 'stored_size': 41000000, 'level': 'smaller_scans', 'preset': 'balanced', 'kept_original': false});
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
    expect(s.unsorted.first.suggestions, ['350', '190', '120'], reason: 'the pack keeps the sorter\'s three');

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


  group('a book the sorter is not confident about stays in Unsorted', () {
    const books = <SampleBook>[
      ('aid', 'Wilderness first aid', '210', '220'),
      ('bees', 'Keeping bees in cold climates', '350', '190'),
      ('engines', 'Small engine repair', '670', '690'),
    ];

    test('an unconfident add stays in Unsorted with the sorter\'s three; a confident add is shelved; the counts agree', () async {
      await library('field', books, unsure: const {'bees'});
      await start();
      final f = FakeShelvesCalls();
      final s = await open(f);
      expect(s.booksOn('210').map((b) => b.id), ['aid'], reason: 'confident: shelved in its division');
      expect(s.booksOn('670').map((b) => b.id), ['engines']);
      final bees = s.book('bees')!;
      expect([bees.shelf, bees.unsorted], [null, true], reason: 'not confident: left in Unsorted');
      expect(bees.suggestions, ['350', '190', '120'], reason: 'with the top three offered');
      expect(_mine(f).where((e) => e['copy'] == 'bees'), isEmpty, reason: 'nothing is written for it: no place, no number');
      expect([for (final e in _mine(f)) if (e['ev'] == 'place') e['copy']], ['engines', 'aid'], reason: 'in (title, copy) order');
      var shelved = 0;
      for (final sh in s.shelves) {
        shelved += s.countUnder(sh);
      }
      expect((shelved, s.unsorted.length, s.bookCount), (2, 1, 3), reason: 'shelved + Unsorted = every book');
      // and it stays there on the next start
      s.dispose();
      made.remove(s);
      final f2 = FakeShelvesCalls();
      final again = await open(f2);
      expect(again.book('bees')!.unsorted, isTrue);
      expect(f2.appended, isEmpty);
    });

    test('a pack from before the flag has none: the book stays in Unsorted, offering its division and the second', () async {
      await library('field', books, noFlag: const {'aid'});
      await start();
      final f = FakeShelvesCalls();
      final s = await open(f);
      final aid = s.book('aid')!;
      expect([aid.shelf, aid.unsorted, aid.suggestions], [null, true, ['210', '220']]);
      expect(_mine(f).where((e) => e['copy'] == 'aid'), isEmpty);
      expect(s.book('bees')!.shelf, '350', reason: 'a pack that says filed is still shelved');
    });

    test('the pack header\'s flag and the three are read; no flag is null', () async {
      await start();
      final h = {
        'book': {
          'suggested': {
            'div': '210', 'second_div': '220', 'filed': false,
            'suggestions': [{'div': '210'}, {'div': '220'}, {'div': '350'}, {'div': '670'}],
          },
        },
      };
      final f = PackFacts.fromHeader(h);
      expect([f.filed, f.suggested], [false, ['210', '220', '350']], reason: 'up to three');
      expect(PackFacts.fromHeader({'book': {'suggested': {'div': '210', 'second_div': '220'}}}).filed, isNull);
      expect(PackFacts.fromHeader({'book': {'suggested': {'div': '210', 'second_div': '220'}}}).suggested, ['210', '220']);
      expect(PackFacts.fromHeader({'book': {'suggested': {'div': '210', 'filed': true}}}).filed, isTrue);
    });

    test('with no pack on this device the synced view\'s stored suggestions are offered (its three), else the one it has', () async {
      await library('field', books);
      Directory('${tmp.path}/libraries/field/packs').deleteSync(recursive: true);
      await start();
      Map<String, dynamic> book(String copy, Map<String, dynamic> suggested) => {
            'title': copy, 'title_from': 'pack', 'aka': [], 'reading': copy,
            'copies': [{'copy': copy, 'locs': ['field/$copy'], 'available': true, 'title': copy, 'own_call': null, 'locations': []}],
            'shelf': null, 'shelved': false, 'by': null, 'call': null, 'removed': false, 'author': null, 'edition': null, 'year': null, 'suggested': suggested,
          };
      final view = {
        'format': 1,
        'built_from': {'libraries': {}, 'logs': {}},
        'books': {
          'aid': book('aid', {'div': '210', 'label': null, 'from': 'pack', 'filed': false, 'suggestions': [{'div': '210'}, {'div': '220'}, {'div': '350'}]}),
          'bees': book('bees', {'div': '350', 'label': null, 'from': 'pack', 'filed': false}),
        },
        'retired': {}, 'next': {}, 'folders': [],
      };
      writeShelves(shelvesDir(), checked: const ['aid', 'bees']);
      final s = await open(FakeShelvesCalls()..canned = view);
      expect(s.book('aid')!.suggestions, ['210', '220', '350'], reason: 'the three the view stored');
      expect(s.book('bees')!.suggestions, ['350'], reason: 'an older pack: the view only has the one, and the page offers only that');
    });
  });

  group('the one-time return to Unsorted', () {
    // an app-built library ("mine", own) and a published one ("pub"), each shelved by an earlier build with `place ... by: auto` and a loc
    const mine = <SampleBook>[
      ('a1', 'Alpha 1', '210', '220'),
      ('a2', 'Alpha 2', '350', '190'),
      ('a3', 'Alpha 3', '670', '690'),
      ('moved', 'Moved by a person', '210', '220'),
      ('addtime', 'Placed when added', '350', '190'),
      ('sure', 'Pack says filed', '670', '690'),
      ('byuser', 'Placed by a person', '210', '220'),
    ];
    const pub = <SampleBook>[('p1', 'Published one', '530', '540')];

    Map<String, dynamic> ev(int at, String ev, String copy, {String? div, String? by, int? seq, String? loc, String dev = 'old-phone'}) =>
        {'v': 1, 'at': at, 'dev': dev, 'ev': ev, 'copy': copy, 'div': ?div, 'by': ?by, 'seq': ?seq, 'loc': ?loc};

    /// What the earlier build wrote: each placed by auto with a loc, but `addtime` (no loc), `byuser` (by user), `moved` (a person moved it
    /// after) and `sure` (its pack says filed).
    List<Map<String, dynamic>> oldEvents() => [
          ev(1000, 'place', 'a1', div: '210', by: 'auto', loc: 'mine/a1'), ev(1000, 'assign', 'a1', div: '210', seq: 1),
          ev(1001, 'place', 'a2', div: '350', by: 'auto', loc: 'mine/a2'), ev(1001, 'assign', 'a2', div: '350', seq: 1),
          ev(1002, 'place', 'a3', div: '670', by: 'auto', loc: 'mine/a3'), ev(1002, 'assign', 'a3', div: '670', seq: 1),
          ev(1003, 'place', 'moved', div: '210', by: 'auto', loc: 'mine/moved'), ev(1003, 'assign', 'moved', div: '210', seq: 2),
          ev(1500, 'place', 'moved', div: '220', by: 'user'), ev(1500, 'retire', 'moved', div: '210', seq: 2), ev(1500, 'assign', 'moved', div: '220', seq: 1),
          ev(1004, 'place', 'addtime', div: '350', by: 'auto'), ev(1004, 'assign', 'addtime', div: '350', seq: 2),
          ev(1005, 'place', 'sure', div: '670', by: 'auto', loc: 'mine/sure'), ev(1005, 'assign', 'sure', div: '670', seq: 2),
          ev(1006, 'place', 'byuser', div: '210', by: 'user', loc: 'mine/byuser'), ev(1006, 'assign', 'byuser', div: '210', seq: 3),
          ev(1007, 'place', 'p1', div: '530', by: 'auto', loc: 'pub/p1'), ev(1007, 'assign', 'p1', div: '530', seq: 1),
        ];

    void writeLog(String dir, String dev, List<Map<String, dynamic>> events) {
      File('${shelvesDir(dir).path}/log/$dev.jsonl')
        ..createSync(recursive: true)
        ..writeAsStringSync([for (final e in events) '${jsonEncode({...e, 'dev': dev})}\n'].join(), mode: FileMode.append);
    }

    Future<void> setUpLibraries() async {
      // a1..a3, moved, addtime and byuser: the sorter was not sure; `sure` is filed
      await library('mine', mine, own: true, unsure: const {'a1', 'a2', 'a3', 'moved', 'addtime', 'byuser'});
      await library('pub', pub, unsure: const {'p1'});
      await start();
    }

    void checkedAll(String dir) => File('${shelvesDir(dir).path}/.local/detected.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode({'format': 1, 'copies': [...mine.map((b) => b.$1), 'p1']..sort()}));

    test('it returns only what Cache shelved with a loc in a library built on a device, with the sorter unsure; a person\'s own choice is left', () async {
      await setUpLibraries();
      writeLog('bookshelves', 'old-phone', oldEvents());
      checkedAll('bookshelves');
      final lines = <String>[];
      final f = FakeShelvesCalls();
      final s = await open(f, log: lines.add);
      // three books come back: a1, a2, a3 (the data's only auto place with a loc, an own library and an unsure pack)
      expect([for (final b in s.unsorted) b.id], ['a1', 'a2', 'a3']);
      expect(s.unsorted.map((b) => b.suggestions), [['210', '220', '120'], ['350', '190', '120'], ['670', '690', '120']], reason: 'with their suggestions');
      // one unsort and one retire each, written one millisecond after the place so a later move always wins
      expect(_mine(f), [
        for (final (i, c) in [('a1', '210'), ('a2', '350'), ('a3', '670')].indexed) ...[
          {'at': 1001 + i, 'ev': 'unsort', 'copy': c.$1, 'by': 'auto'},
          {'at': 1001 + i, 'ev': 'retire', 'copy': c.$1, 'div': c.$2, 'seq': 1},
        ],
      ]);
      expect(lines, hasLength(3), reason: 'one log line per book');
      expect(lines.first, allOf(contains('Alpha 1'), contains('a1'), contains('Unsorted')));
      // everything else is as it was
      expect(s.book('moved')!.shelf, '220', reason: 'the latest event is a person\'s');
      expect(s.book('byuser')!.shelf, '210');
      expect(s.book('addtime')!.shelf, '350', reason: 'the add-time place has no loc');
      expect(s.book('sure')!.shelf, '670', reason: 'its pack says the sorter was confident');
      expect(s.book('p1')!.shelf, '530', reason: 'a published library is never touched');
      expect(s.nextNumber('210'), 'CDS 210-004', reason: 'the returned number is retired, not reused');
      expect(s.book('byuser')!.shelvedBy, ShelvedBy.person);
    });

    test('it runs once: a restart does nothing, and a device that syncs in later with old events is left alone', () async {
      await setUpLibraries();
      writeLog('bookshelves', 'old-phone', oldEvents());
      checkedAll('bookshelves');
      final f = FakeShelvesCalls();
      final s = await open(f);
      expect(s.unsorted, hasLength(3));
      final marker = jsonDecode(File('${shelvesDir().path}/.local/unconfident-return.json').readAsStringSync()) as Map;
      expect((marker['done'], marker['first_run_at'], marker['returned']), (true, 5000, 3));
      // a restart
      s.dispose();
      made.remove(s);
      final f2 = FakeShelvesCalls();
      final again = await open(f2, clock: 9000);
      expect(f2.appended, isEmpty);
      expect(again.unsorted, hasLength(3));
      // another device's old events arrive by sync (an auto place with a loc, from before the fix): not acted on
      writeLog('bookshelves', 'old-tablet', [
        ev(1100, 'place', 'moved2', div: '350', by: 'auto', loc: 'mine2/moved2', dev: 'old-tablet'),
      ]);
      await library('mine2', const [('moved2', 'Late old placement', '350', '190')], own: true, unsure: const {'moved2'});
      await libs.rescan();
      await again.whenRead();
      expect(f2.appended, isEmpty, reason: 'nothing runs after done');
      expect(again.book('moved2')!.shelf, '350', reason: 'it stays as that device left it; that device returns it when it runs the fix itself');
    });

    test('two devices that both run it agree: the same books come back whichever ran first, and neither runs it again', () async {
      await setUpLibraries();
      for (final d in ['phone', 'tablet']) {
        writeLog(d, 'old-phone', oldEvents());
        checkedAll(d);
      }
      // both run before they have seen each other's log
      final fp = FakeShelvesCalls(), ft = FakeShelvesCalls();
      final onPhone = await open(fp, dir: 'phone', dev: 'phone-test', clock: 5000);
      final onTablet = await open(ft, dir: 'tablet', dev: 'tablet', clock: 8000);
      expect(onPhone.unsorted.map((b) => b.id), ['a1', 'a2', 'a3']);
      expect(onTablet.unsorted.map((b) => b.id), ['a1', 'a2', 'a3']);
      // sync: each file reaches the other device
      for (final (from, to, dev) in [('phone', 'tablet', 'phone-test'), ('tablet', 'phone', 'tablet')]) {
        File('${shelvesDir(to).path}/log/$dev.jsonl')
          ..createSync(recursive: true)
          ..writeAsStringSync(File('${shelvesDir(from).path}/log/$dev.jsonl').readAsStringSync());
      }
      onPhone.dispose();
      onTablet.dispose();
      made
        ..remove(onPhone)
        ..remove(onTablet);
      final p2 = await open(FakeShelvesCalls(), dir: 'phone', dev: 'phone-test');
      final t2 = await open(FakeShelvesCalls(), dir: 'tablet', dev: 'tablet');
      List<(String, String?, String?)> state(CdsShelfSource s) => [
            for (final id in ['a1', 'a2', 'a3', 'moved', 'addtime', 'sure', 'byuser', 'p1']) (id, s.book(id)!.shelf, s.book(id)!.callNumber),
          ];
      expect(state(p2), state(t2), reason: 'both devices see the same shelves');
      expect([for (final x in state(p2)) if (x.$2 == null) x.$1], ['a1', 'a2', 'a3']);
      expect([p2.nextNumber('210'), p2.nextNumber('350'), p2.nextNumber('670')], ['CDS 210-004', 'CDS 350-003', 'CDS 670-003']);
      expect([t2.nextNumber('210'), t2.nextNumber('350'), t2.nextNumber('670')], [p2.nextNumber('210'), p2.nextNumber('350'), p2.nextNumber('670')]);
    });

    test('the device that runs second finds the other\'s unsort already there and writes nothing', () async {
      await setUpLibraries();
      writeLog('bookshelves', 'old-phone', oldEvents());
      checkedAll('bookshelves');
      final first = await open(FakeShelvesCalls(), dev: 'phone-test');
      expect(first.unsorted, hasLength(3));
      first.dispose();
      made.remove(first);
      // the tablet has the phone's log already, and has never run the fix
      Directory('${tmp.path}/tablet').createSync();
      Directory('${shelvesDir().path}/log').listSync().whereType<File>().forEach((f) => File('${shelvesDir('tablet').path}/log/${f.uri.pathSegments.last}')
        ..createSync(recursive: true)
        ..writeAsStringSync(f.readAsStringSync()));
      checkedAll('tablet');
      final ft = FakeShelvesCalls();
      final second = await open(ft, dir: 'tablet', dev: 'tablet', clock: 9000);
      expect(ft.appended, isEmpty);
      expect(second.unsorted.map((b) => b.id), ['a1', 'a2', 'a3']);
      expect(File('${shelvesDir('tablet').path}/.local/unconfident-return.json').existsSync(), isTrue, reason: 'it too has run, and will not again');
    });

    test('a device with no library of its own books yet keeps its one run for when there is one', () async {
      await library('pub', pub, unsure: const {'p1'});
      await start();
      writeLog('bookshelves', 'old-phone', [ev(1007, 'place', 'p1', div: '530', by: 'auto', loc: 'pub/p1'), ev(1007, 'assign', 'p1', div: '530', seq: 1)]);
      checkedAll('bookshelves');
      final f = FakeShelvesCalls();
      final s = await open(f);
      expect(f.appended, isEmpty);
      expect(s.book('p1')!.shelf, '530');
      expect(File('${shelvesDir().path}/.local/unconfident-return.json').existsSync(), isFalse);
    });
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
