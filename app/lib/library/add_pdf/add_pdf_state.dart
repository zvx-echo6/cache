import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cache_ocr/cache_ocr.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/foundation.dart';

import '../../platform/app_log.dart';
import '../../platform/battery.dart';
import '../../search/index_scheduler.dart';
import '../../search/index_throttle.dart';
import '../../sources/libraries_state.dart';
import 'add_pdf_calls.dart';

/// The kind of Add PDF's index work, before the "/" of its key.
const String kAddPdfKind = 'pdf-add';

/// The app's Add PDF state, set at start; null in tests that do not need it and on the web.
AddPdfState? addPdfShared;

/// The four phases of adding a PDF, in order. OCR shows only when a page needs it.
enum AddPdfPhase { reading, ocr, searchable, saving }

/// Where a PDF being added stands.
enum AddPdfStatus { active, done, failed }

/// The phase names, as the progress page and the Library's card say them.
String addPdfPhaseWords(AddPdfPhase p) => switch (p) {
  AddPdfPhase.reading => 'Reading pages',
  AddPdfPhase.ocr => 'Reading scanned pages (OCR)',
  AddPdfPhase.searchable => 'Making it searchable',
  AddPdfPhase.saving => 'Saving',
};

/// One PDF being added (or added, or stopped): what the person chose, where it goes, the core job's progress, and its result.
/// Kept in `<support>/ingest/jobs.json`, so a job carries on after Cache is closed or killed (the core resumes from the same
/// job folder).
class AddPdfJob {
  AddPdfJob({
    required this.id,
    required this.pdfPath,
    required this.fileName,
    required this.title,
    required this.bytes,
    required this.libraryPath,
    required this.libraryTitle,
    required this.jobDir,
    required this.added,
    this.ownsFile = false,
    this.ocr = 'host',
  });

  final String id;

  /// The PDF as the picker handed it (its own copy on a phone); never changed.
  final String pdfPath;
  final String fileName;
  final String title;
  final int bytes;
  final String libraryPath;
  final String libraryTitle;
  final String jobDir;
  final DateTime added;

  /// The file is the picker's copy, Cache's to move into the library when the book is saved (and to delete on Cancel).
  final bool ownsFile;

  /// `host` (the phone reads scanned pages) or `off`.
  String ocr;

  AddPdfStatus status = AddPdfStatus.active;

  /// The core's job number in this run of the app (null until started, and after a restart).
  int? coreJob;

  /// The core's state: reading, needs_ocr, embedding, writing, done, failed.
  String state = 'reading';
  int pages = 0;
  int pagesDone = 0;
  int pieces = 0;
  int piecesDone = 0;

  /// Scanned pages asked for so far, and read and handed back; [scanInBatch] are read in the batch now being read.
  int scans = 0;
  int scansDone = 0;
  int scanInBatch = 0;
  final Set<int> _scanPages = {};

  /// Paused by the person (Pause); Start now / Resume anyway lift the wait for charging and the battery.
  bool pausedByPerson = false;
  bool startNow = false;
  bool anyway = false;

  /// Another PDF is being saved into the same library (the core said busy): this one goes next.
  bool busy = false;

  /// Time spent working (not waiting), for the time left.
  Duration worked = Duration.zero;

  /// Why it stopped ([AddPdfStatus.failed]): the core's code, its message, and for no_space the bytes it needs.
  String? errorCode;
  String? errorMessage;
  int? needed;

  /// The core's `result` ([AddPdfStatus.done]).
  Map<String, dynamic>? result;

  /// The result's note has been seen on the book's page (it shows once).
  bool noteSeen = false;

  /// The result's note was dealt with (Leave, Undo, Place): the card keeps only its first line.
  bool noteDone = false;

  String get key => '$kAddPdfKind/$id';

  /// The phase it is in now.
  AddPdfPhase get phase => switch (state) {
    'needs_ocr' => AddPdfPhase.ocr,
    'embedding' => AddPdfPhase.searchable,
    'writing' || 'done' => AddPdfPhase.saving,
    _ => scanInBatch > 0 ? AddPdfPhase.ocr : AddPdfPhase.reading,
  };

  /// A page needed OCR (the OCR phase shows only then).
  bool get sawOcr => scans > 0;

  /// How far, 0 to 1: reading (and OCR) is about a third, making it searchable about three fifths, saving the rest.
  double get fraction {
    if (status == AddPdfStatus.done) return 1;
    final read = pages <= 0 ? 0.0 : ((pagesDone + (scans > 0 ? scansDone + scanInBatch : 0)) / (pages + scans)).clamp(0.0, 1.0);
    final embed = pieces <= 0 ? 0.0 : (piecesDone / pieces).clamp(0.0, 1.0);
    return switch (state) {
      'embedding' => 0.35 + 0.55 * embed,
      'writing' => 0.92,
      'done' => 1.0,
      _ => 0.35 * read,
    };
  }

  /// The share of making it searchable done, in whole percent.
  int get searchablePercent => pieces <= 0 ? 0 : (100 * piecesDone / pieces).floor().clamp(0, 100);

  /// What it is doing, in a line: "Reading pages", "Making it searchable 62%".
  String get stepWords {
    final p = phase;
    if (p == AddPdfPhase.searchable && pieces > 0) return '${addPdfPhaseWords(p)} $searchablePercent%';
    return addPdfPhaseWords(p);
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'pdf_path': pdfPath,
    'file_name': fileName,
    'title': title,
    'bytes': bytes,
    'library_path': libraryPath,
    'library_title': libraryTitle,
    'job_dir': jobDir,
    'added': added.toIso8601String(),
    'owns_file': ownsFile,
    'ocr': ocr,
    'status': status.name,
    'state': state,
    'pages': pages,
    'pages_done': pagesDone,
    'pieces': pieces,
    'pieces_done': piecesDone,
    'scans': scans,
    'scans_done': scansDone,
    'paused': pausedByPerson,
    'start_now': startNow,
    'anyway': anyway,
    'worked_ms': worked.inMilliseconds,
    'error': errorCode == null ? null : {'code': errorCode, 'message': errorMessage, 'needed': needed},
    'result': result,
    'note_seen': noteSeen,
    'note_done': noteDone,
  };

  static AddPdfJob fromJson(Map<String, dynamic> j) {
    final job = AddPdfJob(
      id: j['id'] as String,
      pdfPath: j['pdf_path'] as String,
      fileName: (j['file_name'] ?? '') as String,
      title: (j['title'] ?? '') as String,
      bytes: (j['bytes'] as num?)?.toInt() ?? 0,
      libraryPath: j['library_path'] as String,
      libraryTitle: (j['library_title'] ?? '') as String,
      jobDir: j['job_dir'] as String,
      added: DateTime.tryParse((j['added'] ?? '') as String) ?? DateTime.now(),
      ownsFile: j['owns_file'] == true,
      ocr: (j['ocr'] ?? 'host') as String,
    );
    job
      ..status = AddPdfStatus.values.asNameMap()[j['status']] ?? AddPdfStatus.active
      ..state = (j['state'] ?? 'reading') as String
      ..pages = (j['pages'] as num?)?.toInt() ?? 0
      ..pagesDone = (j['pages_done'] as num?)?.toInt() ?? 0
      ..pieces = (j['pieces'] as num?)?.toInt() ?? 0
      ..piecesDone = (j['pieces_done'] as num?)?.toInt() ?? 0
      ..scans = (j['scans'] as num?)?.toInt() ?? 0
      ..scansDone = (j['scans_done'] as num?)?.toInt() ?? 0
      ..pausedByPerson = j['paused'] == true
      ..startNow = j['start_now'] == true
      ..anyway = j['anyway'] == true
      ..worked = Duration(milliseconds: (j['worked_ms'] as num?)?.toInt() ?? 0)
      ..result = (j['result'] as Map?)?.cast<String, dynamic>()
      ..noteSeen = j['note_seen'] == true
      ..noteDone = j['note_done'] == true;
    if (j['error'] case final Map e) {
      job
        ..errorCode = e['code'] as String?
        ..errorMessage = e['message'] as String?
        ..needed = (e['needed'] as num?)?.toInt();
    }
    // a job that was mid-OCR when Cache closed is reading again: the core asks for the same pages
    if (job.state == 'needs_ocr') job.state = 'reading';
    return job;
  }
}

/// A library the person may add a PDF to: one of their own, or My books before it exists ([path] null: made on first use).
class AddPdfTarget {
  const AddPdfTarget({required this.title, this.path, this.isDefault = false});

  final String title;
  final String? path;
  final bool isDefault;

  /// My books, not made yet: the confirm screen says so once.
  bool get isNew => path == null;
}

/// About how long a PDF takes on a phone while charging, before anything is known of its pages: about six seconds a megabyte
/// (the owner's mockup: 41 MB about 4 minutes). Corrected while it runs.
Duration addPdfEstimate(int bytes) {
  final s = (bytes / (1 << 20) * 6).round();
  return Duration(seconds: s < 60 ? 60 : s);
}

/// "About 4 min", "Less than a minute".
String aboutMinutes(Duration d) {
  final m = (d.inSeconds / 60).round();
  return m < 1 ? 'Less than a minute' : 'About $m min';
}

/// Adding PDFs: the jobs, kept on disk, run by the app's one index scheduler as its work (so they wait for charging, pause for a
/// low battery and heat, and give way to Ask), each step a call to the core's ingest job.
class AddPdfState extends ChangeNotifier implements IndexWorkSource {
  AddPdfState({
    required this.calls,
    required this.dir,
    required this.engines,
    this.libraries,
    this.bookshelves,
    this.ocrEngine,
    this.battery,
    this.onDone,
    this.permit,
    this.stepBudgetMs = 400,
    this.busyWait = const Duration(seconds: 4),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final IngestCalls calls;

  /// Where the jobs list and the job folders live (`<support>/ingest`); null when there is none.
  final Future<Directory?> Function() dir;

  /// `engines` for cs_ingest_start: PDFium, the embedder and model, the classifier.
  final Future<Map<String, dynamic>> Function() engines;
  final LibrariesState? libraries;

  /// `bookshelves` for cs_ingest_start (`{dir, dev, libraries}`), or null when there are no Bookshelves to write.
  final Future<Map<String, dynamic>?> Function()? bookshelves;

  /// The phone's own OCR engine (null where there is none: scanned pages are then skipped).
  final Future<OcrEngine?> Function()? ocrEngine;
  final BatteryReader? battery;

  /// After a book is saved: the Library and Bookshelves read again.
  final Future<void> Function(AddPdfJob job)? onDone;

  /// Awaited before each step and between OCR pages; the app's throttle by default.
  final Future<void> Function(AddPdfJob job)? permit;
  final int stepBudgetMs;
  final Duration busyWait;
  final DateTime Function() _clock;

  final List<AddPdfJob> _jobs = [];
  bool _loaded = false;
  int _beat = 0;
  OcrEngine? _ocr;
  bool _ocrAsked = false;
  final Map<String, AddPdfRun> _runs = {};

  /// Every job, newest first: being added, then stopped, then added.
  List<AddPdfJob> get jobs => List.unmodifiable(_jobs);
  List<AddPdfJob> get active => [for (final j in _jobs) if (j.status == AddPdfStatus.active) j];
  List<AddPdfJob> get failed => [for (final j in _jobs) if (j.status == AddPdfStatus.failed) j];

  /// Being added (shown on Bookshelves' row: "1 being added").
  int get adding => active.length;

  /// Tests and renders: puts [job] in the list as it is.
  @visibleForTesting
  void debugAdd(AddPdfJob job) {
    _loaded = true;
    _jobs.add(job);
    notifyListeners();
  }

  /// Tests and renders: the list is [jobs], as they are.
  @visibleForTesting
  void debugSet(List<AddPdfJob> jobs) {
    _loaded = true;
    _jobs
      ..clear()
      ..addAll(jobs);
    notifyListeners();
  }

  AddPdfJob? byId(String id) => _jobs.where((j) => j.id == id).firstOrNull;

  /// The job whose book is [copy] and whose note has not been seen on the book's page yet.
  AddPdfJob? freshNoteFor(String? copy) {
    if (copy == null) return null;
    return _jobs.where((j) => j.status == AddPdfStatus.done && !j.noteSeen && !j.noteDone && j.result?['copy'] == copy).firstOrNull;
  }

  Future<File?> _listFile() async {
    final d = await dir();
    return d == null ? null : File('${d.path}${Platform.pathSeparator}jobs.json');
  }

  /// Reads the jobs kept on disk (once).
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final f = await _listFile();
      if (f != null && f.existsSync()) {
        final j = jsonDecode(await f.readAsString()) as Map;
        for (final e in (j['jobs'] as List? ?? const [])) {
          try {
            _jobs.add(AddPdfJob.fromJson((e as Map).cast<String, dynamic>()));
          } catch (e) {
            logError('Add PDF: a kept job could not be read', error: e);
          }
        }
      }
    } catch (e) {
      logError('Add PDF: the jobs list could not be read', error: e);
    }
    notifyListeners();
  }

  Future<void>? _saving;
  bool _saveAgain = false;

  /// Writes the jobs list (one write at a time; a change during it writes once more after it).
  Future<void> save() {
    if (_saving != null) {
      _saveAgain = true;
      return _saving!;
    }
    return _saving = () async {
      try {
        do {
          _saveAgain = false;
          final f = await _listFile();
          if (f == null) return;
          await f.parent.create(recursive: true);
          final tmp = File('${f.path}.tmp');
          // the 20 newest finished jobs are kept for their result cards; every job not finished is kept
          final done = [for (final j in _jobs) if (j.status == AddPdfStatus.done) j].take(20).toSet();
          await tmp.writeAsString(jsonEncode({'jobs': [for (final j in _jobs) if (j.status != AddPdfStatus.done || done.contains(j)) j.toJson()]}), flush: true);
          await tmp.rename(f.path);
        } while (_saveAgain);
      } catch (e) {
        logError('Add PDF: the jobs list could not be written', error: e);
      } finally {
        _saving = null;
      }
    }();
  }

  void _changed() {
    _beat++;
    notifyListeners();
  }

  /// Adds the PDF at [pdfPath] to [target] (My books is made first when it does not exist yet). The job waits its turn in the
  /// index scheduler.
  Future<AddPdfJob> add({required String pdfPath, required String fileName, required int bytes, required String title, required AddPdfTarget target, bool ownsFile = false}) async {
    await load();
    var path = target.path;
    var libTitle = target.title;
    if (path == null) {
      final made = await libraries!.ensureOwnLibrary(title: target.title);
      path = made.path;
      libTitle = libraries!.titleOf(made);
    }
    final d = await dir();
    if (d == null) throw StateError('Cache has no folder to add PDFs in');
    final id = _clock().microsecondsSinceEpoch.toRadixString(36);
    final engine = await _engine();
    final job = AddPdfJob(
      id: id,
      pdfPath: pdfPath,
      fileName: fileName,
      title: title,
      bytes: bytes,
      libraryPath: path,
      libraryTitle: libTitle,
      jobDir: '${d.path}${Platform.pathSeparator}$id',
      added: _clock(),
      ownsFile: ownsFile,
      ocr: engine == null ? 'off' : 'host',
    );
    _jobs.insert(0, job);
    await save();
    logInfo('Add PDF: a PDF was queued (${(bytes / (1 << 20)).toStringAsFixed(1)} MB, OCR ${job.ocr})', job: job.key);
    _changed();
    unawaited(indexSchedulerShared?.kick());
    return job;
  }

  Future<OcrEngine?> _engine() async {
    if (!_ocrAsked) {
      _ocrAsked = true;
      try {
        _ocr = await ocrEngine?.call();
      } catch (e) {
        logError('Add PDF: the OCR engine could not be opened', error: e);
      }
    }
    return _ocr;
  }

  // ---- the scheduler's work

  @override
  Future<List<IndexTask>> pending() async {
    await load();
    return [
      for (final j in _jobs.reversed)
        if (j.status == AddPdfStatus.active && !j.pausedByPerson)
          IndexTask(
            key: j.key,
            title: j.title,
            // asked for by the person: before the automatic work
            uses: 1 << 30,
            size: j.bytes,
            long: !(j.startNow || j.anyway),
            anyway: j.anyway,
            progress: () => ((j.fraction * 1000).round(), 1000),
            pulse: () => (j.state, j.pagesDone, j.piecesDone, j.scansDone, j.scanInBatch, j.busy, _beat),
            step: () => j.stepWords,
            start: () async => _runs[j.id] = AddPdfRun(this, j),
          ),
    ];
  }

  Future<void> _permitFor(AddPdfJob job) async {
    final p = permit;
    if (p != null) return p(job);
    final t = indexThrottleShared;
    if (t == null) return;
    // Resume anyway: a low battery does not hold this one
    if (job.anyway && t.duty.paused && t.duty.hold == IndexHold.battery) return;
    await t.permit();
  }

  // ---- what the person does

  /// Pause: it stops after the step it is on and keeps what is done.
  Future<void> pause(AddPdfJob job) async {
    job.pausedByPerson = true;
    _changed();
    await save();
    await _runs[job.id]?.stop();
    unawaited(indexSchedulerShared?.kick());
  }

  /// Resume after Pause.
  Future<void> resume(AddPdfJob job) async {
    job.pausedByPerson = false;
    _changed();
    await save();
    unawaited(indexSchedulerShared?.kick());
  }

  /// Start now: it does not wait for charging (a low battery and heat still hold it).
  Future<void> startNow(AddPdfJob job) async {
    job
      ..startNow = true
      ..pausedByPerson = false;
    _changed();
    await save();
    unawaited(indexSchedulerShared?.kick());
  }

  /// Resume anyway: it goes on while the battery is low.
  Future<void> resumeAnyway(AddPdfJob job) async {
    job
      ..anyway = true
      ..startNow = true
      ..pausedByPerson = false;
    _changed();
    await save();
    unawaited(indexSchedulerShared?.kick());
  }

  /// Stop adding: the job and its folder go; nothing was added to the library. Also how a stopped job is put away.
  Future<void> cancel(AddPdfJob job) async {
    await _runs[job.id]?.stop();
    if (job.status != AddPdfStatus.done) await _cancelCore(job);
    _jobs.remove(job);
    if (job.ownsFile && job.status != AddPdfStatus.done) _deleteQuietly(File(job.pdfPath));
    logInfo('Add PDF: stopped by the person', job: job.key);
    _changed();
    await save();
    unawaited(indexSchedulerShared?.kick());
  }

  /// A finished job's card is put away.
  Future<void> dismiss(AddPdfJob job) async {
    _jobs.remove(job);
    _changed();
    await save();
  }

  /// Try again after it stopped: from the start, in the same job folder.
  Future<void> retry(AddPdfJob job, {String? ocr}) async {
    await _cancelCore(job);
    job
      ..status = AddPdfStatus.active
      ..state = 'reading'
      ..coreJob = null
      ..pages = 0
      ..pagesDone = 0
      ..pieces = 0
      ..piecesDone = 0
      ..scans = 0
      ..scansDone = 0
      ..scanInBatch = 0
      ..worked = Duration.zero
      ..errorCode = null
      ..errorMessage = null
      ..needed = null
      ..pausedByPerson = false;
    job._scanPages.clear();
    if (ocr != null) job.ocr = ocr;
    _changed();
    await save();
    unawaited(indexSchedulerShared?.kick());
  }

  /// "Turn on scanned pages": the same PDF again, the phone reading its scanned pages.
  Future<void> turnOnScans(AddPdfJob job) => retry(job, ocr: 'host');

  /// The note on a finished job was dealt with (Leave, Undo, Place).
  void noteHandled(AddPdfJob job) {
    job.noteDone = true;
    _changed();
    unawaited(save());
  }

  /// The note was shown on the book's page: it does not show there again.
  void noteShown(AddPdfJob job) {
    if (job.noteSeen) return;
    job.noteSeen = true;
    unawaited(save());
  }

  Future<void> _cancelCore(AddPdfJob job) async {
    try {
      var id = job.coreJob;
      if (id == null && Directory(job.jobDir).existsSync()) {
        // a job of an earlier run of Cache: the core knows it again from its folder, then removes it
        id = ((await calls('start', await _startArgs(job)))['job'] as num).toInt();
      }
      if (id != null) await calls('cancel', {'job': id});
    } on CacheSearchException catch (e) {
      if (e.code != 'not_found') logError('Add PDF: the job could not be removed', error: e, job: job.key);
    } catch (e) {
      logError('Add PDF: the job could not be removed', error: e, job: job.key);
    }
    job.coreJob = null;
  }

  Future<Map<String, dynamic>> _startArgs(AddPdfJob job) async {
    final shelves = await bookshelves?.call();
    final threads = indexThrottleShared?.duty.threads;
    return {
      'library_dir': job.libraryPath,
      'pdf_path': job.pdfPath,
      'job_dir': job.jobDir,
      'bookshelves': ?shelves,
      'engines': await engines(),
      'opts': {
        'title': job.title,
        'ocr': job.ocr,
        'ocr_batch': 4,
        'embed_batch': 8,
        // gentle on a phone: the throttle's thread cap, else two
        'embed_threads': threads == null || threads > 2 ? 2 : (threads < 1 ? 1 : threads),
      },
    };
  }

  // ---- the run's side

  Future<int> _startCore(AddPdfJob job) async {
    final r = await calls('start', await _startArgs(job));
    job
      ..coreJob = (r['job'] as num).toInt()
      ..pages = (r['pages'] as num?)?.toInt() ?? job.pages;
    logInfo('Add PDF: ${r['resumed'] == true ? 'resumed' : 'started'} (${job.pages} pages)', job: job.key);
    _changed();
    return job.coreJob!;
  }

  void _status(AddPdfJob job, Map<String, dynamic> s) {
    final before = job.state;
    job.state = (s['state'] ?? job.state) as String;
    final p = (s['progress'] as Map?)?.cast<String, dynamic>();
    if (p != null) {
      job
        ..pages = (p['pages'] as num?)?.toInt() ?? job.pages
        ..pagesDone = (p['pages_done'] as num?)?.toInt() ?? job.pagesDone
        ..pieces = (p['pieces'] as num?)?.toInt() ?? job.pieces
        ..piecesDone = (p['pieces_done'] as num?)?.toInt() ?? job.piecesDone;
    }
    if (job.state == 'needs_ocr') {
      for (final e in (s['needs_ocr'] as List? ?? const [])) {
        final page = ((e as Map)['page'] as num?)?.toInt();
        if (page != null && job._scanPages.add(page)) job.scans++;
      }
    }
    if (before != job.state) {
      logInfo('Add PDF: ${job.state} (pages ${job.pagesDone} of ${job.pages}, pieces ${job.piecesDone} of ${job.pieces})', job: job.key);
      unawaited(save());
    }
    _changed();
  }

  Future<void> _done(AddPdfJob job, Map<String, dynamic>? result) async {
    job
      ..status = AddPdfStatus.done
      ..state = 'done'
      ..coreJob = null
      ..busy = false
      ..result = result ?? const {};
    // The PDF goes into the library beside its book (`bookshelf/<BLAKE3>.pdf`, where Bookshelves looks for a book's file): the
    // picker's own copy is moved there, any other file is copied.
    final copy = result?['copy'] as String?;
    if (copy != null && RegExp(r'^[0-9a-f]{64}$').hasMatch(copy)) {
      final sep = Platform.pathSeparator;
      final to = File('${job.libraryPath}${sep}bookshelf$sep$copy.pdf');
      try {
        if (!to.existsSync()) {
          await to.parent.create(recursive: true);
          final from = File(job.pdfPath);
          if (job.ownsFile) {
            try {
              await from.rename(to.path);
            } on FileSystemException {
              await from.copy(to.path);
              _deleteQuietly(from);
            }
          } else {
            await from.copy(to.path);
          }
        } else if (job.ownsFile) {
          _deleteQuietly(File(job.pdfPath));
        }
      } catch (e) {
        logError('Add PDF: the PDF could not be put beside its book', error: e, job: job.key);
      }
    }
    final same = (result?['same'] as List?)?.length ?? 0;
    final shelf = result?['shelf'] is Map ? 'filed' : (same > 0 ? 'a spare copy' : 'unsorted');
    logInfo('Add PDF: done, ${result?['pieces'] ?? 0} pieces, ${result?['pages_without_text'] ?? 0} pages without text, '
        'OCR ${(result?['ocr'] as Map?)?['pages_ocrd'] ?? 0} pages, $shelf', job: job.key);
    _changed();
    await save();
    try {
      await onDone?.call(job);
    } catch (e) {
      logError('Add PDF: the Library could not be read again', error: e, job: job.key);
    }
  }

  void _failed(AddPdfJob job, String code, String message, {int? needed}) {
    job
      ..status = AddPdfStatus.failed
      ..busy = false
      ..scanInBatch = 0
      ..errorCode = code
      ..errorMessage = message
      ..needed = needed;
    logError('Add PDF: stopped: $code', error: message, job: job.key);
    _changed();
    unawaited(save());
  }

  void _endRun(AddPdfJob job) {
    _runs.remove(job.id);
    job
      ..busy = false
      ..scanInBatch = 0;
    _changed();
    unawaited(save());
  }

  static void _deleteQuietly(File f) {
    try {
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  @override
  void dispose() {
    for (final r in _runs.values.toList()) {
      unawaited(r.stop());
    }
    super.dispose();
  }
}

class _Stopped implements Exception {
  const _Stopped();
}

/// One job running for the scheduler: start (or resume) the core's job, then step it, the throttle permitting before each step;
/// a `needs_ocr` batch is read with the phone's engine and handed back. Finished true when the book is saved, false when it
/// stopped (paused, held, failed).
class AddPdfRun implements IndexRun {
  AddPdfRun(this.state, this.job) {
    unawaited(_go());
  }

  final AddPdfState state;
  final AddPdfJob job;
  final Completer<bool> _done = Completer<bool>();
  bool _stop = false;

  @override
  Future<bool> get finished => _done.future;

  void _finish(bool ok) {
    if (_done.isCompleted) return;
    state._endRun(job);
    _done.complete(ok);
  }

  Future<void> stop() async {
    _stop = true;
    await _done.future;
  }

  @override
  Future<void> pause([IndexWait why = IndexWait.none]) => stop();

  /// The run follows the throttle itself (it awaits the permit before each step and between OCR pages).
  @override
  void setDuty(IndexDuty duty) {}

  Future<void> _go() async {
    final calls = state.calls;
    try {
      if (job.coreJob == null) await state._startCore(job);
      while (!_stop) {
        await state._permitFor(job);
        if (_stop) break;
        final t0 = state._clock();
        Map<String, dynamic> s;
        try {
          // reading and drawing pages use PDFium; making it searchable and saving do not
          s = await calls('step', {'job': job.coreJob, 'budget_ms': state.stepBudgetMs}, pdfium: job.state == 'reading' || job.state == 'needs_ocr');
        } on CacheSearchException catch (e) {
          if (e.code == 'busy') {
            // another PDF is being saved into this library: this one goes next, and tries again by itself
            if (!job.busy) {
              job.busy = true;
              logInfo('Add PDF: waiting for another PDF to be saved', job: job.key);
            }
            state._changed();
            await Future<void>.delayed(state.busyWait);
            continue;
          }
          if (e.code == 'not_found') {
            // the core no longer has this job (it was started in an earlier run of Cache): it carries on from its folder
            await state._startCore(job);
            continue;
          }
          rethrow;
        }
        job
          ..busy = false
          ..worked += state._clock().difference(t0);
        state._status(job, s);
        switch (s['state']) {
          case 'needs_ocr':
            await _readScans((s['needs_ocr'] as List?) ?? const []);
          case 'done':
            await state._done(job, (s['result'] as Map?)?.cast<String, dynamic>());
            _finish(true);
            return;
          case 'failed':
            final e = (s['error'] as Map?)?.cast<String, dynamic>() ?? const {};
            state._failed(job, (e['code'] ?? 'io') as String, (e['message'] ?? '') as String, needed: (e['needed'] as num?)?.toInt());
            _finish(false);
            return;
        }
      }
      _finish(false);
    } on _Stopped {
      _finish(false);
    } on CacheSearchException catch (e) {
      state._failed(job, e.code, e.message, needed: e.needed);
      _finish(false);
    } catch (e, st) {
      logError('Add PDF: the job broke', error: e, stack: st, job: job.key);
      state._failed(job, 'io', '$e');
      _finish(false);
    }
  }

  Future<void> _readScans(List<Object?> needs) async {
    final engine = await state._engine();
    if (engine == null) {
      // no engine on this device: the pages are handed back blank (the job counts them as without text)
      await state.calls('ocr', pdfium: false, {
        'job': job.coreJob,
        'engine': 'none',
        'version': '0',
        'pages': [for (final e in needs) {'page': (e as Map)['page'], 'text': ''}],
      });
      return;
    }
    job.scanInBatch = 0;
    final t0 = state._clock();
    final batch = await ocrForIngest(
      job.coreJob!,
      needs,
      engine,
      betweenPages: () async {
        job.worked += state._clock().difference(t0);
        await state._permitFor(job);
        if (_stop) throw const _Stopped();
      },
      onPage: (_) {
        job.scanInBatch++;
        state._changed();
      },
    );
    if (batch.failed.isNotEmpty) logInfo('Add PDF: ${batch.failed.length} scanned pages could not be read', job: job.key);
    if (_stop) throw const _Stopped();
    await state.calls('ocr', batch.ingestParams, pdfium: false);
    job
      ..scansDone += batch.pages.length
      ..scanInBatch = 0;
    state._changed();
  }
}

/// The time left while it runs: from how fast it has gone so far, once a little is done; before that, the estimate from its size.
Duration addPdfTimeLeft(AddPdfJob job) {
  final f = job.fraction;
  if (f >= 0.05 && job.worked.inSeconds > 10) {
    return Duration(seconds: (job.worked.inSeconds * (1 - f) / f).round());
  }
  return Duration(seconds: (addPdfEstimate(job.bytes).inSeconds * (1 - f)).round());
}

/// The words of an error, as the progress page shows it: a heading, what is safe, and the stopped words for the Library's card.
class AddPdfErrorWords {
  const AddPdfErrorWords(this.title, this.body, this.stopped);

  final String title;
  final String body;

  /// After "Stopped: " on the Library's card.
  final String stopped;
}

String _mb(int bytes) => bytes >= (1 << 30) ? '${(bytes / (1 << 30)).toStringAsFixed(1)} GB' : '${(bytes / (1 << 20)).round()} MB';

AddPdfErrorWords addPdfErrorWords(AddPdfJob job) => switch (job.errorCode) {
  'no_text' when job.ocr == 'off' => const AddPdfErrorWords('No readable text', 'This PDF is scans, and reading scanned pages is off.', 'no readable text'),
  'no_text' => const AddPdfErrorWords('Scanned pages could not be read', 'They may be too faint or blank. A clearer scan may work.', 'no readable text'),
  'not_pdf' || 'damaged' => const AddPdfErrorWords("This file can't be read", 'It may not be a PDF, or it may be damaged. Your file was not changed.', "the file can't be read"),
  'locked' => const AddPdfErrorWords('This PDF has a password', 'Remove the password, then add it again.', 'it has a password'),
  'no_space' => AddPdfErrorWords(job.needed == null ? 'Needs more free space' : 'Needs ${_mb(job.needed!)} free', 'Nothing was added. Your PDF was not changed.', 'not enough space'),
  'embed' => const AddPdfErrorWords("Search isn't ready on this phone", 'Nothing was added. Your PDF was not changed.', "search isn't ready"),
  _ => const AddPdfErrorWords('This PDF could not be added', 'Nothing was added. Your PDF was not changed.', 'it could not be added'),
};
