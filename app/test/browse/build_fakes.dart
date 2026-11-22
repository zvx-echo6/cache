import 'dart:async';

import 'package:cache/browse/web/build_api.dart';
import 'package:cache/browse/web/device_api.dart';
import 'package:cache/browse/web/local_files.dart';

import 'web_fakes.dart';

/// The device's building service, as the browser's code sees it: what the test sets is what it answers, and what it is asked is kept.
class FakeBuildApi implements BuildApi, BuildLibraryDeleteApi {
  List<BuildLibrary> libs = [];
  final Map<String, List<BuildBook>> bookMap = {};
  BuildQueue q = const BuildQueue();
  DropState dropState = const DropState();
  final List<String> calls = [];
  DeviceException? failWith;
  int _n = 0;

  void _check() {
    if (failWith != null) throw failWith!;
  }

  @override
  Future<List<BuildLibrary>> libraries() async {
    _check();
    return List.of(libs);
  }

  @override
  Future<BuildLibrary> createLibrary(String title) async {
    _check();
    calls.add('create $title');
    if (libs.any((l) => l.title.toLowerCase() == title.toLowerCase())) {
      throw DeviceException('name_taken', 'You already have a library called "$title". Choose another name, or add to it.', status: 409);
    }
    final l = BuildLibrary(id: 'lib${++_n}', title: title);
    libs = [...libs, l];
    return l;
  }

  @override
  Future<void> deleteLibrary(String id) async {
    calls.add('delete-library $id');
    libs = [for (final x in libs) if (x.id != id) x];
  }

  @override
  Future<BuildLibrary> renameLibrary(String id, String title) async {
    calls.add('rename-library $id $title');
    final l = libs.firstWhere((x) => x.id == id);
    final n = BuildLibrary(id: l.id, title: title, books: l.books, passages: l.passages, pages: l.pages, createdAt: l.createdAt);
    libs = [for (final x in libs) x.id == id ? n : x];
    return n;
  }

  @override
  Future<List<BuildBook>> books(String libraryId) async {
    _check();
    return List.of(bookMap[libraryId] ?? const []);
  }

  @override
  Future<void> renameBook(String libraryId, String docId, String title) async {
    calls.add('rename-book $docId $title');
    bookMap[libraryId] = [
      for (final b in bookMap[libraryId] ?? <BuildBook>[])
        b.id == docId ? BuildBook(id: b.id, title: title, pages: b.pages, passages: b.passages, fileName: b.fileName, size: b.size, addedAt: b.addedAt) : b,
    ];
  }

  @override
  Future<void> removeBook(String libraryId, String docId) async {
    calls.add('remove-book $docId');
    bookMap[libraryId] = [for (final b in bookMap[libraryId] ?? <BuildBook>[]) if (b.id != docId) b];
  }

  @override
  Future<BuildQueue> queue() async {
    _check();
    return q;
  }

  BuildQueue _paused(bool p) => BuildQueue(paused: p, blocked: q.blocked, counts: q.counts, etaLow: p ? null : q.etaLow, etaHigh: p ? null : q.etaHigh, items: q.items);

  @override
  Future<BuildQueue> pause() async {
    calls.add('pause');
    return q = _paused(true);
  }

  @override
  Future<BuildQueue> resume() async {
    calls.add('resume');
    return q = _paused(false);
  }

  @override
  Future<BuildQueue> stop() async {
    calls.add('stop');
    q = BuildQueue(paused: q.paused, counts: q.counts, items: [for (final i in q.items) if (!i.waiting) i]);
    return q;
  }

  @override
  Future<BuildQueue> retry(String itemId) async {
    calls.add('retry $itemId');
    return q;
  }

  @override
  Future<BuildQueue> dismiss(String itemId) async {
    calls.add('dismiss $itemId');
    q = BuildQueue(paused: q.paused, blocked: q.blocked, counts: q.counts, items: [for (final i in q.items) if (i.id != itemId) i]);
    return q;
  }

  @override
  Future<DropState> drop() async {
    _check();
    return dropState;
  }

  @override
  Future<DropState> putDrop({String? folder, bool? enabled, String? libraryId}) async {
    calls.add('put-drop folder=$folder enabled=$enabled library=$libraryId');
    final s = dropState.settings;
    final lib = libraryId == null ? null : libs.where((l) => l.id == libraryId).firstOrNull;
    dropState = DropState(
      settings: DropSettings(folder: folder ?? s.folder, enabled: enabled ?? s.enabled, libraryId: libraryId ?? s.libraryId, libraryTitle: lib?.title ?? s.libraryTitle),
      status: DropStatus(state: (enabled ?? s.enabled) ? 'ok' : 'off', lastCheck: dropState.status.lastCheck, found: dropState.status.found, all: dropState.status.all, queue: dropState.status.queue, complete: dropState.status.complete, failed: dropState.status.failed, error: dropState.status.error, stale: dropState.status.stale),
      files: dropState.files,
    );
    return dropState;
  }

  @override
  Future<DropState> checkDrop() async {
    calls.add('check-drop');
    return dropState;
  }

  @override
  Future<DropState> retryDrop(String name) async {
    calls.add('retry-drop $name');
    return dropState;
  }
}

BuildBook book(String id, String title, {int pages = 100, int passages = 200, String? file, int size = 1 << 20, DateTime? added, String status = 'ready'}) =>
    BuildBook(id: id, title: title, pages: pages, passages: passages, fileName: file ?? '$title.pdf', size: size, addedAt: added ?? DateTime.now().subtract(const Duration(hours: 1)), status: status);

QueueItem qitem(String id, String lib, String state, {String? title, String? file, int pieces = 0, int? total, String? error, String? duplicateOf, int? position}) => QueueItem(
      id: id,
      libraryId: lib,
      fileName: file ?? '$id.pdf',
      title: title,
      state: state,
      progress: QueueProgress(pieces: pieces, piecesTotal: total),
      error: error,
      duplicateOf: duplicateOf,
      position: position,
    );

BuildQueue queueOf(List<QueueItem> items, {bool paused = false, String? blocked, int? low, int? high}) {
  int n(bool Function(QueueItem) f) => items.where(f).length;
  return BuildQueue(
    paused: paused,
    blocked: blocked,
    etaLow: low,
    etaHigh: high,
    counts: QueueCounts(
      total: items.length,
      waiting: n((i) => i.waiting),
      working: n((i) => i.active),
      done: n((i) => i.state == 'done'),
      skipped: n((i) => i.skipped),
      failed: n((i) => i.state == 'failed'),
      ocrNeeded: n((i) => i.state == 'ocr_needed'),
    ),
    items: items,
  );
}

/// PDFs uploaded with a hand on each one.
class FakeRawUploader implements RawUploader {
  final List<FakeUpload> started = [];
  final List<String> urls = [];

  @override
  UploadTask post(LocalFile file, String url, UploadProgress onProgress) {
    final u = FakeUpload(file, 'pdf', url, onProgress);
    started.add(u);
    urls.add(url);
    return u;
  }

  /// Finishes every upload so far (and every one that starts while the test waits).
  void finishAll() {
    for (final u in started) {
      if (!u.finished) u.finish({'id': 'item'});
    }
  }
}
