import 'dart:convert';
import 'dart:io';

import 'package:cache/browse/browse_state.dart';
import 'package:cache/library/add_pdf/add_pdf_pages.dart';
import 'package:cache/library/add_pdf/add_pdf_state.dart';
import 'package:cache/library/cds_shelf_source.dart';
import 'package:cache/library/library_pages.dart';
import 'package:cache/search/index_scheduler.dart';
import 'package:cache/sources/libraries_state.dart';

import '../browse/fakes.dart';
import '../library/fake_shelves.dart';
import '../library/library_fixtures.dart';
import 'add_pdf_fixtures.dart';

/// The sample world of the Add PDF screens (the owner's mockups): My books (the person's own library) with a filed book, a book
/// in Unsorted and a spare copy; a Field library and a Homestead library of their own; the Bookshelves; a scheduler whose holds
/// the test sets; and the jobs each frame shows. Sample content only.
class AddPdfWorld {
  AddPdfWorld._(this.tmp);

  final Directory tmp;
  late FakeSources sources;
  late LibrariesState libs;
  late CdsShelfSource shelves;
  late BrowseState browse;
  late AddPdfState state;
  late FakeScheduler scheduler;
  late LibraryDeps deps;

  /// [own]: the Field and Homestead libraries are the person's own (the Change sheet lists them); [myBooks]: My books exists.
  static Future<AddPdfWorld> make({bool own = true, bool myBooks = true}) async {
    final w = AddPdfWorld._(Directory.systemTemp.createTempSync('add-pdf-world'));
    final root = Directory('${w.tmp.path}/libraries');
    const same = {'minhash': [7, 8, 9]};
    if (myBooks) {
      writeBookLibrary(root, 'my-books', const [
        ('water', 'Water purification manual', '530', null),
        ('radio', 'Field radio handbook', '720', '710'),
        ('water2', 'Water purification manual (2)', '530', null),
      ], pdfs: const {'water', 'radio', 'water2'}, samebook: {'water2': same});
      File('${root.path}/my-books/cache-library.json')
          .writeAsStringSync(jsonEncode({'format': 1, 'library_id': 'my-books-1', 'title': 'My books', 'version': '1', 'own': true, 'own_default': true}));
    } else {
      root.createSync(recursive: true);
    }
    writeBookLibrary(root, 'field', const [
      ('water1', 'Water purification manual', '530', null),
      ('engines', 'Small engine repair', '670', '690'),
    ], samebook: {'water1': same});
    File('${root.path}/field/cache-library.json').writeAsStringSync(jsonEncode({'format': 1, 'library_id': 'field', 'title': 'Field library', 'version': '1', 'own': own}));
    writeBookLibrary(root, 'homestead', const [('hives', 'Beekeeping notes', '350', null)]);
    File('${root.path}/homestead/cache-library.json').writeAsStringSync(jsonEncode({'format': 1, 'library_id': 'homestead', 'title': 'Homestead library', 'version': '1', 'own': own}));
    w.sources = FakeSources(Directory('${w.tmp.path}/zims')..createSync(recursive: true));
    w.libs = await librariesAt(root, w.sources);
    final shelvesDir = writeShelves(Directory('${w.tmp.path}/bookshelves'),
        placed: const [('water1', '530', 1), ('water', '530', 4), ('hives', '350', 1)], checked: const ['water1', 'water', 'radio', 'water2', 'engines', 'hives']);
    w.shelves = CdsShelfSource(w.libs, calls: FakeShelvesCalls(), bookshelvesDir: () async => shelvesDir, deviceId: () async => 'phone-test', ownIds: () async => const [], clock: () => 5000);
    await w.shelves.whenRead();
    w.browse = BrowseState(sources: w.sources, libraries: w.libs, policy: testPolicy(), settingsDirOverride: w.tmp, phoneLanguage: 'en');
    w.state = AddPdfState(calls: FakeIngestCalls(), dir: () async => Directory('${w.tmp.path}/ingest'), engines: () async => const {}, libraries: w.libs, permit: (_) async {});
    w.scheduler = FakeScheduler();
    w.deps = testDeps(browse: w.browse, shelves: w.shelves, files: FakeBookFiles());
    addPdfShared = w.state;
    indexSchedulerShared = w.scheduler;
    addPdfLibraryDeps = w.deps;
    return w;
  }

  // ---- the jobs of the frames

  /// Frame 4: reading scanned pages, page 41 of 82 scans.
  AddPdfJob get running => sampleJob('run', state: 'needs_ocr', pages: 310, pagesDone: 310, scans: 82, scansDone: 40, scanInBatch: 1);

  /// Frame 4, held: battery low, waiting for charging, slowed for heat, paused by the person.
  List<AddPdfJob> get held => [
    sampleJob('battery', state: 'embedding', pages: 310, pagesDone: 310, pieces: 254, piecesDone: 158),
    sampleJob('charging', title: 'Field radio handbook', bytes: 212 << 20, state: 'reading', pages: 400, pagesDone: 90),
    sampleJob('heat', title: 'Root cellar plans', state: 'needs_ocr', pages: 120, pagesDone: 120, scans: 30, scansDone: 10, scanInBatch: 0),
    sampleJob('person', title: 'Beekeeping notes', state: 'embedding', pages: 80, pagesDone: 80, pieces: 100, piecesDone: 20, paused: true),
  ];

  void holdAll() {
    final h = held;
    scheduler
      ..fixed = {
        h[0].key: runningItem(h[0], why: IndexWait.battery),
        h[1].key: heldItem(h[1], IndexWait.charging),
        h[2].key: runningItem(h[2], slowed: true),
      }
      ..runningKey = h[0].key
      ..done = 0
      ..total = 4;
    state.debugSet(h);
  }

  void runOne() {
    final r = running;
    scheduler
      ..fixed = {r.key: runningItem(r)}
      ..runningKey = r.key
      ..done = 0
      ..total = 3
      ..share = 0.14;
    state.debugSet([r]);
  }

  /// Several PDFs added at once: one runs, the others wait their turn.
  void queueSeveral() {
    final r = running;
    final a = sampleJob('q1', title: 'Field radio handbook', bytes: 40 << 20);
    final b = sampleJob('q2', title: 'Root cellar plans', bytes: 14 << 20);
    scheduler
      ..fixed = {
        r.key: runningItem(r),
        a.key: IndexItem(key: a.key, state: IndexState.queued, title: a.title, position: 1),
        b.key: IndexItem(key: b.key, state: IndexState.queued, title: b.title, position: 2),
      }
      ..runningKey = r.key
      ..done = 0
      ..total = 3;
    state.debugSet([r, a, b]);
  }

  AddPdfJob get filed => sampleJob('filed', status: AddPdfStatus.done, state: 'done', result: {
    'copy': 'water',
    'pieces': 254,
    'same': const [],
    'shelf': {'div': '530', 'by': 'auto'},
    'suggested': {'div': '530', 'score': 0.91, 'second_div': '540', 'classifier_version': 2},
  });

  AddPdfJob get unsure => sampleJob('unsure', title: 'Field radio handbook', status: AddPdfStatus.done, state: 'done', result: {
    'copy': 'radio',
    'pieces': 400,
    'same': const [],
    'shelf': null,
    'suggested': {'div': '720', 'score': 0.41, 'second_div': '710', 'classifier_version': 2},
  });

  AddPdfJob get spare => sampleJob('spare', title: 'Water purification manual (2)', status: AddPdfStatus.done, state: 'done', result: {
    'copy': 'water2',
    'pieces': 250,
    'same': [
      {'with': 'water1', 'how': 'blake3', 'score': 1.0},
    ],
    'shelf': null,
    'suggested': null,
  });

  void done(AddPdfJob j) {
    scheduler
      ..fixed = {}
      ..runningKey = null
      ..done = 0
      ..total = 0;
    state.debugSet([j]);
  }

  List<AddPdfJob> get errorsA => [
    sampleJob('notext', status: AddPdfStatus.failed, error: 'no_text', ocr: 'off'),
    sampleJob('ocrfail', status: AddPdfStatus.failed, error: 'no_text'),
    sampleJob('busy', title: 'Root cellar plans', busy: true),
  ];

  List<AddPdfJob> get errorsB => [
    sampleJob('notpdf', status: AddPdfStatus.failed, error: 'not_pdf'),
    sampleJob('locked', status: AddPdfStatus.failed, error: 'locked'),
    sampleJob('space', status: AddPdfStatus.failed, error: 'no_space', needed: 380 << 20),
  ];

  void errors(List<AddPdfJob> jobs) {
    scheduler
      ..fixed = {}
      ..runningKey = null
      ..done = 0
      ..total = 1;
    state.debugSet(jobs);
  }

  /// Frame 8, the Library's card: a PDF stopped (no readable text), one other piece of work.
  void stopped() {
    scheduler
      ..fixed = {}
      ..runningKey = null
      ..done = 0
      ..total = 1;
    state.debugSet([sampleJob('notext', status: AddPdfStatus.failed, error: 'no_text', ocr: 'off')]);
  }

  void dispose() {
    addPdfShared = null;
    indexSchedulerShared = null;
    addPdfLibraryDeps = null;
    shelves.dispose();
    browse.dispose();
    libs.dispose();
    sources.dispose();
    state.dispose();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  }
}
