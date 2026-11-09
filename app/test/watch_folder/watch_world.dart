import 'dart:io';

import 'package:cache/library/add_pdf/add_pdf_state.dart';
import 'package:cache/library/add_pdf/watch_folders.dart';
import 'package:cache/search/index_scheduler.dart';

import '../add_pdf/add_pdf_fixtures.dart';
import '../add_pdf/add_pdf_world.dart';

/// The sample world of the Watch a folder screens (the owner's mockups): the Add PDF world (My books, Bookshelves, a scheduler the
/// test sets) and two watched folders, Manuals (Download/Manuals, checked 2 hours ago, 7 added) and Field guides (Documents/Field
/// guides, checked yesterday, 3 added). Sample content only.
class WatchWorld {
  WatchWorld._(this.pdf, this.watch);

  final AddPdfWorld pdf;
  final WatchFoldersState watch;

  /// The time the frames are drawn at.
  static final DateTime now = DateTime(2026, 11, 9, 13);

  static Future<WatchWorld> make({bool own = true, bool myBooks = true}) async {
    final p = await AddPdfWorld.make(own: own, myBooks: myBooks);
    final w = WatchFoldersState(addPdf: p.state, dir: () async => Directory('${p.tmp.path}/ingest'), every: kWatchEvery, clock: () => now);
    watchFoldersShared = w;
    return WatchWorld._(p, w);
  }

  WatchedFolder get manuals => folder('manuals', 'Manuals', 'Download/Manuals', checked: now.subtract(const Duration(hours: 2)), added: 7);
  WatchedFolder get fieldGuides => folder('field', 'Field guides', 'Documents/Field guides', checked: DateTime(2026, 11, 8, 9), added: 3);

  static WatchedFolder folder(String id, String name, String where, {DateTime? checked, int added = 0}) => WatchedFolder(
    id: id,
    root: '/tmp/watch-$id',
    name: name,
    where: where,
    libraryTitle: 'My books',
    libraryPath: '/tmp/my-books',
    since: DateTime(2026, 11, 1),
  )
    ..lastCheck = checked
    ..added = added;

  /// Frames 1b, 3 and 6: two folders, one library each.
  void two() => watch.debugSet([manuals, fieldGuides]);

  /// Frame 3, iPhone: Manuals being checked now.
  void checking() => watch.debugSet([
    manuals
      ..checking = true
      ..checkProgress = 0.4,
    fieldGuides,
  ]);

  /// Frame 5: Manuals can't be reached (last checked 3 days ago).
  void unreachable() => watch.debugSet([
    manuals
      ..unreachable = true
      ..lastCheck = DateTime(2026, 11, 6, 12),
    fieldGuides,
  ]);

  /// Decision 3: a PDF Manuals found could not be added.
  void skipped() => watch.debugSet([
    manuals..skipped.add(const WatchSkip(path: 'Old scan.pdf', name: 'Old scan.pdf', hash: 'h1', bytes: 3 << 20)),
    fieldGuides,
  ]);

  /// A job a check of Manuals found.
  static AddPdfJob job(
    String id, {
    required String title,
    required int bytes,
    String check = 'check1',
    String state = 'reading',
    AddPdfStatus status = AddPdfStatus.active,
    int pages = 212,
    int pagesDone = 0,
    Map<String, dynamic>? result,
  }) {
    final j = AddPdfJob(
      id: id,
      pdfPath: '/tmp/$id.pdf',
      fileName: '$title.pdf',
      title: title,
      bytes: bytes,
      libraryPath: '/tmp/my-books',
      libraryTitle: 'My books',
      jobDir: '/tmp/ingest/$id',
      added: DateTime.now(),
      ownsFile: true,
      folderRoot: '/tmp/watch-manuals',
      sourcePath: '$title.pdf',
      watchId: 'manuals',
      watchName: 'Manuals',
      checkId: check,
      watchHash: 'hash-$id',
    );
    j
      ..state = state
      ..status = status
      ..pages = pages
      ..pagesDone = pagesDone
      ..result = result
      ..worked = const Duration(minutes: 1);
    return j;
  }

  AddPdfJob get waterRunning => job('water-run', title: 'Water filter guide', bytes: 18 << 20, pagesDone: 40);
  AddPdfJob get pumpQueued => job('pump-q', title: 'Pump repair notes', bytes: 64 << 20, pages: 0);

  /// Frame 4: a check found 2 new PDFs; the first is being read, the second waits its turn.
  void found() {
    final r = waterRunning, q = pumpQueued;
    pdf.scheduler
      ..fixed = {
        r.key: runningItem(r),
        q.key: IndexItem(key: q.key, state: IndexState.queued, title: q.title, position: 1),
      }
      ..runningKey = r.key
      ..done = 0
      ..total = 2
      ..share = 0.1;
    pdf.state.debugSet([r, q]);
  }

  /// Frame 4, done: the check's summary (one filed, one in Unsorted).
  void foundDone() {
    pdf.scheduler
      ..fixed = {}
      ..runningKey = null
      ..done = 0
      ..total = 0;
    pdf.state.debugSet([
      job('pump-done', title: 'Pump repair notes', bytes: 64 << 20, status: AddPdfStatus.done, state: 'done', result: {
        'copy': 'radio',
        'pieces': 300,
        'same': const [],
        'shelf': null,
        'suggested': {'div': '620', 'score': 0.44, 'second_div': '630', 'classifier_version': 2},
      }),
      job('water-done', title: 'Water filter guide', bytes: 18 << 20, status: AddPdfStatus.done, state: 'done', result: {
        'copy': 'water',
        'pieces': 254,
        'same': const [],
        'shelf': {'div': '530', 'by': 'auto'},
        'suggested': {'div': '530', 'score': 0.91, 'second_div': '540', 'classifier_version': 2},
      }),
    ]);
  }

  void dispose() {
    watchFoldersShared = null;
    watch.dispose();
    pdf.dispose();
  }
}
