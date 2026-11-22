import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../app_fs.dart';
import 'build_api.dart';
import 'build_text.dart';
import 'device_api.dart' show DeviceException;
import '../../linked_folders/linked_folders.dart' show LinkedFolderController;
import 'local_files.dart';

/// Where the app remembers how many books were done when this tab last looked, so a reopened tab can say what happened meanwhile.
const String kBuildSeenFile = 'build-library.json';

/// One PDF in an upload.
class UploadEntry {
  UploadEntry(this.file, {this.compression}) : size = file.size;

  final CompressionChoice? compression;

  final LocalFile file;
  final int size;
  int sent = 0;

  /// `waiting`, `sending`, `done` or `failed`.
  String state = 'waiting';
  String? error;
  UploadTask? task;

  String get name => file.name;
  double get fraction => size <= 0 ? 0 : (sent / size).clamp(0.0, 1.0);
}

/// PDFs going to the device, one request each. Building starts on the first book, so this overlaps with the building.
class BuildUpload {
  BuildUpload({required this.libraryId, required this.libraryTitle, required this.newLibrary, required this.entries, this.leftOut = const [], this.replaceDocId, this.replaceTitle})
      : started = DateTime.now();

  final String libraryId;
  final String libraryTitle;
  final bool newLibrary;
  final List<UploadEntry> entries;

  /// Names of the files that were not PDFs and were left out.
  final List<String> leftOut;

  /// Set when this upload is one new copy of a book.
  final String? replaceDocId;
  final String? replaceTitle;
  final DateTime started;
  DateTime lastAt = DateTime.now();
  bool ended = false;
  bool cancelled = false;

  /// Set when the whole upload stopped for a reason; the words for people.
  String? stopped;
  final Completer<void> _done = Completer<void>();

  /// Completes when every PDF was sent, failed or was cancelled.
  Future<void> get done => _done.future;

  int get count => entries.length;
  int get totalBytes => entries.fold(0, (s, e) => s + e.size);
  int get sentBytes => entries.fold(0, (s, e) => s + (e.state == 'done' ? e.size : e.sent));
  int get doneCount => entries.where((e) => e.state == 'done').length;
  List<UploadEntry> get failed => [for (final e in entries) if (e.state == 'failed') e];
  bool get running => !ended;
  bool get finishing => !ended && entries.every((e) => e.state == 'done' || e.state == 'failed');
  double get fraction => totalBytes <= 0 ? 0 : (sentBytes / totalBytes).clamp(0.0, 1.0);

  /// The files in flight now.
  List<UploadEntry> get inFlight => [for (final e in entries) if (e.state == 'sending') e];

  double? get speed {
    final secs = lastAt.difference(started).inMilliseconds / 1000;
    return sentBytes <= 0 || secs <= 0 ? null : sentBytes / secs;
  }

  int? get secondsLeft {
    final s = speed;
    return s == null || s <= 0 ? null : ((totalBytes - sentBytes) / s).ceil();
  }
}

/// Building libraries from PDFs, as the browser sees it: the libraries and the queue (read every 2 seconds while books are being built,
/// every 30 otherwise), the PDFs going up, the books of the library being looked at, and the drop folder. The device carries on building
/// with the tab closed.
class BuildController extends ChangeNotifier {
  BuildController({
    required this.api,
    this.uploader,
    this.fs,
    this.fast = const Duration(seconds: 2),
    this.slow = const Duration(seconds: 30),
    this.concurrency = 3,
    this.poll = true,
    this.linkedFolders,
    void Function(bool)? leaveWarning,
    Future<List<LocalFile>> Function()? pickPdfs,
    Future<List<LocalFile>> Function()? pickFolder,
  })  : _leaveWarning = leaveWarning ?? setLeaveWarning,
        pickPdfs = pickPdfs ?? (() => pickLocalFiles(accept: const ['.pdf', 'application/pdf'])),
        pickFolder = pickFolder ?? (() => pickLocalFiles(directory: true));

  final BuildApi api;
  final RawUploader? uploader;
  final AppFs? fs;
  final Duration fast;
  final Duration slow;
  final int concurrency;

  /// Linked folders on this Cache device, shared by Library entry points.
  final LinkedFolderController? linkedFolders;

  /// False in a test that reads by hand: nothing is read on a timer.
  final bool poll;
  final void Function(bool) _leaveWarning;

  /// The file choosers (tests give their own).
  final Future<List<LocalFile>> Function() pickPdfs;
  final Future<List<LocalFile>> Function() pickFolder;

  List<BuildLibrary> libraries = const [];
  BuildQueue queue = const BuildQueue();
  bool loaded = false;

  BuildCompressionSettings? compressionSettings;

  /// The problem to show about the device itself (it could not be reached), or null.
  String? problem;

  /// The upload under way, or the last one that stopped with something to say (until dismissed).
  BuildUpload? upload;

  /// The books of the libraries that were looked at.
  final Map<String, List<BuildBook>> books = {};
  final Set<String> _watched = {};
  bool _watchDrop = false;
  DropState? drop;

  /// Lines of "While this tab was closed" for the books built meanwhile; empty when there is nothing to say.
  List<String> whileClosed = const [];

  /// How much room a built library's files take on the device, and how much the device has free (the Library on the device knows; null
  /// when it does not).
  int? Function(String libraryId)? sizeOf;

  /// What deleting library [libraryId] frees, in bytes: the figure the device gives for the library (its folder, work copy, stored
  /// PDFs and record), else the size of its folder as the device list gives it; null when neither is known. Never a guess of 0.
  int? freesOf(String libraryId) => library(libraryId)?.bytes ?? sizeOf?.call(libraryId);
  int? Function()? freeSpace;

  /// Whoever is showing a page that takes dropped PDFs sets this: the build page, a library's page.
  void Function(List<LocalFile> files)? sink;

  Timer? _timer;
  bool _disposed = false;
  bool _started = false;
  bool _ready = false;
  Future<void>? _running;
  bool _again = false;
  Map<String, int>? _seen;

  // ---- reading

  Future<void> start() async {
    if (_started) return;
    _started = true;
    await _readSeen();
    await refresh();
    final seen = _seen;
    if (seen != null) whileClosed = _linesSince(seen);
    _ready = true;
    if (whileClosed.isEmpty) await _writeSeen(_counts());
    notifyListeners();
  }

  void onFocus() {
    if (_started) unawaited(refresh());
  }

  Future<void> refresh() {
    final r = _running;
    if (r != null) {
      _again = true;
      return r;
    }
    return _running = () async {
      do {
        _again = false;
        await _readOnce();
      } while (_again && !_disposed);
    }()
        .whenComplete(() {
      _running = null;
      _schedule();
    });
  }

  Future<void> _readOnce() async {
    if (_disposed) return;
    try {
      final r = await Future.wait<Object>([api.libraries(), api.queue()]);
      libraries = r[0] as List<BuildLibrary>;
      queue = r[1] as BuildQueue;
      for (final id in _watched.toList()) {
        if (libraries.any((l) => l.id == id)) {
          books[id] = await api.books(id);
        }
      }
      if (_watchDrop) drop = await api.drop();
      problem = null;
      loaded = true;
    } on DeviceException catch (e) {
      problem = e.code == 'unauthorized' ? 'Sign in again to see the Library.' : 'This device could not be reached.';
    } catch (_) {
      problem = 'This device could not be reached.';
    }
    if (whileClosed.isEmpty && loaded && _ready) await _writeSeen(_counts());
    if (!_disposed) notifyListeners();
  }

  bool get _busy => (upload?.running ?? false) || (queue.items.any((i) => !i.finished) && !queue.paused && queue.blocked == null);

  void _schedule() {
    _timer?.cancel();
    if (_disposed || !_started || !poll) return;
    _timer = Timer(_busy || _watchDrop ? fast : slow, () => unawaited(refresh()));
  }

  Map<String, int> _counts() => {'done': queue.counts.done, 'failed': queue.counts.failed + queue.counts.ocrNeeded, 'skipped': queue.counts.skipped};

  Future<void> _readSeen() async {
    final f = fs;
    if (f == null) return;
    try {
      final text = await f.readString(AppRoot.support, kBuildSeenFile);
      if (text == null) return;
      final j = (jsonDecode(text) as Map).cast<String, dynamic>();
      _seen = {for (final e in j.entries) e.key: (e.value as num).toInt()};
    } catch (_) {}
  }

  Future<void> _writeSeen(Map<String, int> now) async {
    final f = fs;
    if (f == null || !loaded) return;
    if (_seen != null && mapEquals(_seen, now)) return;
    _seen = now;
    try {
      await f.writeStringAtomic(AppRoot.support, kBuildSeenFile, jsonEncode(now));
    } catch (_) {}
  }

  List<String> _linesSince(Map<String, int> seen) {
    final now = _counts();
    int d(String k) => ((now[k] ?? 0) - (seen[k] ?? 0)).clamp(0, 1 << 30);
    final built = d('done');
    final failed = d('failed');
    final skipped = d('skipped');
    final out = <String>[];
    if (built > 0) out.add(built == 1 ? '1 book was built.' : '${thousands(built)} books were built.');
    final active = <String>{
      for (final i in queue.items)
        if (i.active) libraries.where((l) => l.id == i.libraryId).map((l) => l.title).firstOrNull ?? 'A library',
    };
    for (final t in active) {
      out.add('$t is still building.');
    }
    if (failed > 0) out.add(failed == 1 ? "1 book couldn't be built." : "${thousands(failed)} books couldn't be built.");
    if (skipped > 0) out.add(skipped == 1 ? '1 book was skipped as a duplicate.' : '${thousands(skipped)} books were skipped as duplicates.');
    return out;
  }

  /// Dismiss on "While this tab was closed".
  Future<void> dismissWhileClosed() async {
    whileClosed = const [];
    await _writeSeen(_counts());
    notifyListeners();
  }

  Future<BuildCompressionSettings> loadCompressionSettings() async {
    final apiWithSettings = api;
    if (apiWithSettings is! BuildCompressionApi) {
      throw const DeviceException('unsupported', 'PDF settings are not available on this device.');
    }
    final settings = await apiWithSettings.getCompressionSettings();
    compressionSettings = settings;
    if (!_disposed) notifyListeners();
    return settings;
  }

  Future<BuildCompressionSettings> saveCompressionSettings(BuildCompressionSettings settings) async {
    final apiWithSettings = api;
    if (apiWithSettings is! BuildCompressionApi) {
      throw const DeviceException('unsupported', 'PDF settings are not available on this device.');
    }
    final saved = await apiWithSettings.putCompressionSettings(settings);
    compressionSettings = saved;
    if (!_disposed) notifyListeners();
    return saved;
  }

  // ---- libraries and books

  BuildLibrary? library(String id) => libraries.where((l) => l.id == id).firstOrNull;

  /// The library called [title], whatever the case, or null: the same name cannot be used twice.
  BuildLibrary? libraryNamed(String title) {
    final t = title.trim().toLowerCase();
    return t.isEmpty ? null : libraries.where((l) => l.title.trim().toLowerCase() == t).firstOrNull;
  }

  List<QueueItem> itemsOf(String libraryId) => [for (final i in queue.items) if (i.libraryId == libraryId) i];

  /// What the library's books are doing in the queue: how many there are, how many are finished, how many need a look.
  ({int total, int finished, int attention, int waiting, bool active}) progressOf(String libraryId) {
    final items = itemsOf(libraryId);
    return (
      total: items.length,
      finished: items.where((i) => i.finished).length,
      attention: items.where((i) => i.needsAttention).length,
      waiting: items.where((i) => i.waiting).length,
      active: items.any((i) => i.active),
    );
  }

  /// Any book anywhere is waiting or being built.
  bool get isAnythingBuilding => queue.items.any((i) => !i.finished);

  /// Anything of this library still to be built (waiting or being built).
  bool isBuilding(String libraryId) => itemsOf(libraryId).any((i) => !i.finished);

  /// Looks at the books of [id] from now on (they are read again with the rest). Call [unwatchBooks] when the page goes.
  void watchBooks(String id) {
    _watched.add(id);
    unawaited(loadBooks(id));
  }

  void unwatchBooks(String id) => _watched.remove(id);

  Future<void> loadBooks(String id) async {
    try {
      books[id] = await api.books(id);
      if (!_disposed) notifyListeners();
    } on DeviceException {
      // The next reading tries again.
    }
  }

  void watchDropFolder(bool on) {
    _watchDrop = on;
    if (on) unawaited(refresh());
  }

  Future<BuildLibrary> createLibrary(String title) async {
    final l = await api.createLibrary(title.trim());
    libraries = [...libraries, l];
    notifyListeners();
    unawaited(refresh());
    return l;
  }

  Future<void> renameLibrary(String id, String title) async {
    final l = await api.renameLibrary(id, title.trim());
    libraries = [for (final x in libraries) x.id == id ? l : x];
    notifyListeners();
  }

  /// Whether the device can delete a whole built library.
  bool get canDeleteLibrary => api is BuildLibraryDeleteApi;

  /// Deletes a built library: its books, search data and PDF copies on the device. The PDFs the person gave are not touched.
  Future<void> deleteLibrary(String id) async {
    final a = api;
    if (a is! BuildLibraryDeleteApi) return;
    await a.deleteLibrary(id);
    libraries = [for (final x in libraries) if (x.id != id) x];
    books.remove(id);
    notifyListeners();
    unawaited(refresh());
  }

  Future<void> renameBook(String libraryId, String docId, String title) async {
    await api.renameBook(libraryId, docId, title.trim());
    await loadBooks(libraryId);
  }

  Future<void> removeBook(String libraryId, String docId) async {
    await api.removeBook(libraryId, docId);
    await loadBooks(libraryId);
    unawaited(refresh());
  }

  // ---- the queue

  Future<void> _queueCall(Future<BuildQueue> Function() call) async {
    queue = await call();
    notifyListeners();
    unawaited(refresh());
  }

  Future<void> pause() => _queueCall(api.pause);
  Future<void> resume() => _queueCall(api.resume);
  Future<void> retry(String itemId) => _queueCall(() => api.retry(itemId));
  Future<void> dismiss(String itemId) => _queueCall(() => api.dismiss(itemId));

  /// Takes the waiting books off the list; the book being built finishes. [alsoDropFolderOff] turns the drop folder off too, so its files
  /// are not taken again at the next check.
  Future<void> stop({bool alsoDropFolderOff = false}) async {
    if (alsoDropFolderOff) {
      try {
        drop = await api.putDrop(enabled: false);
      } on DeviceException {
        // The queue is stopped all the same; the page says the folder is still on.
      }
    }
    await _queueCall(api.stop);
  }

  // ---- uploads

  /// Sends [files] to the library [libraryId], or to a new library called [newTitle] (made first). Only PDFs go; the others are named
  /// in [BuildUpload.leftOut]. Returns the upload, or null when there was nothing to send (see [notice]). A name that is taken or other
  /// refusal of the device throws a [DeviceException].
  Future<BuildUpload?> addFiles(List<LocalFile> files, {String? libraryId, String? newTitle, CompressionChoice? compression}) async {
    final choice = compression ?? compressionSettings?.compression;
    final up = uploader;
    if (up == null) return null;
    final split = splitPdfs(files);
    notice = null;
    if (split.pdfs.isEmpty) {
      notice = split.leftOutWords == null ? 'There are no PDFs to add.' : 'There are no PDFs to add. ${split.leftOutWords}';
      notifyListeners();
      return null;
    }
    final running = upload;
    if (running != null && running.running) {
      if (libraryId != null && running.libraryId == libraryId && running.replaceDocId == null) {
        running.entries.addAll([for (final f in split.pdfs) UploadEntry(f, compression: choice)]);
        _pump(running);
        notifyListeners();
        return running;
      }
      notice = 'Wait for the upload that is running to end.';
      notifyListeners();
      return null;
    }
    String id;
    String title;
    final fresh = libraryId == null;
    if (fresh) {
      final l = await createLibrary(newTitle ?? '');
      id = l.id;
      title = l.title;
    } else {
      id = libraryId;
      title = library(libraryId)?.title ?? '';
    }
    final u = upload = BuildUpload(libraryId: id, libraryTitle: title, newLibrary: fresh, entries: [for (final f in split.pdfs) UploadEntry(f, compression: choice)], leftOut: split.leftOut);
    _leaveWarning(true);
    notifyListeners();
    _pump(u);
    return u;
  }

  /// Sends one new copy of a book of [libraryId].
  Future<BuildUpload?> replaceBook(String libraryId, BuildBook book, LocalFile file, {CompressionChoice? compression}) async {
    final choice = compression ?? compressionSettings?.compression;
    final up = uploader;
    if (up == null) return null;
    notice = null;
    if (!isPdfName(file.name)) {
      notice = '${file.name} is not a PDF. Nothing was uploaded.';
      notifyListeners();
      return null;
    }
    if (upload?.running == true) {
      notice = 'Wait for the upload that is running to end.';
      notifyListeners();
      return null;
    }
    final u = upload = BuildUpload(
      libraryId: libraryId,
      libraryTitle: library(libraryId)?.title ?? '',
      newLibrary: false,
      entries: [UploadEntry(file, compression: choice)],
      replaceDocId: book.id,
      replaceTitle: book.title,
    );
    _leaveWarning(true);
    notifyListeners();
    _pump(u);
    return u;
  }

  /// A line to show about the last try that sent nothing (no PDFs among the files, an upload already running); cleared by the next try.
  String? notice;

  void clearNotice() {
    if (notice == null) return;
    notice = null;
    notifyListeners();
  }

  void _pump(BuildUpload u) {
    if (u.ended) return;
    final up = uploader!;
    final stopNow = u.stopped != null || u.cancelled;
    while (!stopNow && u.entries.where((e) => e.state == 'sending').length < concurrency) {
      final next = u.entries.where((e) => e.state == 'waiting').firstOrNull;
      if (next == null) break;
      next.state = 'sending';
      final name = Uri.encodeComponent(next.name);
      final url = u.replaceDocId != null
          ? '/api/build/libraries/${Uri.encodeComponent(u.libraryId)}/books/${Uri.encodeComponent(u.replaceDocId!)}/replace?name=$name'
          : '/api/build/upload?library_id=${Uri.encodeComponent(u.libraryId)}&name=$name';
      final choice = next.compression;
      final compressionQuery = choice == null ? '' : '&compression=${choice.level}${choice.preset == null ? '' : '&preset=${choice.preset}'}';
      unawaited(_send(u, next, up, url + compressionQuery));
    }
    if (u.entries.every((e) => e.state == 'done' || e.state == 'failed')) _end(u);
  }

  Future<void> _send(BuildUpload u, UploadEntry e, RawUploader up, String url) async {
    try {
      final task = e.task = up.post(e.file, url, (sent, total) {
        e.sent = sent;
        u.lastAt = DateTime.now();
        if (!_disposed) notifyListeners();
      });
      await task.done;
      e.sent = e.size;
      e.state = 'done';
    } on UploadCancelled {
      e.state = 'failed';
      e.error = 'Canceled.';
    } on DeviceException catch (x) {
      e.state = 'failed';
      e.error = _uploadWords(x, e.name);
      if (x.status == 507 || x.code == 'no_space') {
        u.stopped = 'Not enough space on this device. The PDFs already sent are kept.';
      } else if (x.code == 'unauthorized') {
        u.stopped = 'Sign in again, then add the rest.';
      } else if (x.code == 'interrupted') {
        u.stopped = 'The connection was lost. The PDFs already sent are kept; add the rest again.';
      }
    } catch (_) {
      e.state = 'failed';
      e.error = 'The upload stopped.';
    }
    e.task = null;
    if (u.stopped != null || u.cancelled) {
      for (final w in u.entries.where((x) => x.state == 'waiting')) {
        w.state = 'failed';
        w.error = u.cancelled ? 'Canceled.' : 'Not sent.';
      }
    }
    unawaited(refresh());
    _pump(u);
    if (!_disposed) notifyListeners();
  }

  static String _uploadWords(DeviceException e, String name) {
    if (e.status == 507 || e.code == 'no_space') return 'Not enough space on this device.';
    if (e.code == 'not_pdf') return '$name is not a PDF.';
    if (e.code == 'invalid_name') return '$name has a name that is not allowed. Rename the file and add it again.';
    if (e.code == 'not_found') return 'That library is not on this device any more.';
    if (e.code == 'interrupted') return 'The connection was lost.';
    return e.message.isEmpty ? 'The upload failed.' : e.message;
  }

  void _end(BuildUpload u) {
    if (u.ended) return;
    u.ended = true;
    _leaveWarning(false);
    // An upload that went well is gone from the list; one with something to say stays until it is dismissed.
    if (identical(upload, u) && u.failed.isEmpty && u.stopped == null) upload = null;
    if (!u._done.isCompleted) u._done.complete();
    unawaited(refresh());
    notifyListeners();
  }

  /// Cancel on the upload card: what is being sent stops; the PDFs already on the device stay and keep building.
  void cancelUpload() {
    final u = upload;
    if (u == null || u.ended) return;
    u.cancelled = true;
    for (final e in u.entries) {
      e.task?.cancel();
    }
    for (final w in u.entries.where((x) => x.state == 'waiting')) {
      w.state = 'failed';
      w.error = 'Canceled.';
    }
    _pump(u);
    if (u.entries.every((e) => e.state == 'done' || e.state == 'failed')) _end(u);
    upload = null;
    notifyListeners();
  }

  void dismissUpload() {
    if (upload != null && upload!.ended) {
      upload = null;
      notifyListeners();
    }
  }

  // ---- the drop folder

  Future<DropState> _drop(Future<DropState> Function() call) async {
    final d = drop = await call();
    notifyListeners();
    return d;
  }

  Future<void> loadDrop() => _drop(api.drop);
  Future<void> setDrop({String? folder, bool? enabled, String? libraryId}) => _drop(() => api.putDrop(folder: folder, enabled: enabled, libraryId: libraryId));
  Future<void> checkDrop() => _drop(api.checkDrop);
  Future<void> retryDrop(String name) => _drop(() => api.retryDrop(name));

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    linkedFolders?.dispose();
    if (upload?.running == true) _leaveWarning(false);
    super.dispose();
  }
}
