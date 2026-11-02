import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../settings/space.dart';
import 'battery.dart';
import 'pdf_index_core.dart';
import 'pdf_index_run.dart';
import 'pdf_pages.dart';

/// A ZIM as PDF indexing sees it.
class PdfZimRef {
  const PdfZimRef({required this.path, required this.uuid, required this.title});

  final String path;

  /// Null until the core has opened the ZIM.
  final String? uuid;
  final String title;

  String get fileName => path.split(RegExp(r'[\\/]')).last;
}

/// Where a library's PDFs part stands (UX-pdf-index-30, section 2).
enum PdfPartPhase { idle, measuring, waiting, starting, running, pausing, finishing, paused, failed, done, newVersion }

/// Who paused it.
enum PdfPause { person, battery, closed }

/// What the PDFs part of one library shows.
class PdfPart {
  const PdfPart({
    required this.phase,
    required this.total,
    this.handled = 0,
    this.unreadable = 0,
    this.newCount = 0,
    this.timeLeft,
    this.range,
    this.pause,
    this.failure,
    this.fromOtherDevice = false,
    this.finishFraction,
  });

  final PdfPartPhase phase;

  /// PDFs in the ZIM.
  final int total;

  /// PDFs done or skipped so far.
  final int handled;

  /// Skipped PDFs (no text, locked, damaged): "12 could not be read".
  final int unreadable;

  /// For a new ZIM version: PDFs the old index does not have.
  final int newCount;

  /// The live figure, after about 2 minutes of this run.
  final Duration? timeLeft;

  /// Before that: the start pop-up's range.
  final (Duration, Duration)? range;
  final PdfPause? pause;
  final PdfRunFailure? failure;
  final bool fromOtherDevice;
  final double? finishFraction;

  double? get fraction => total > 0 ? (handled / total).clamp(0.0, 1.0) : null;
}

/// What the start pop-up says (measured on this device before any work).
class PdfEstimate {
  const PdfEstimate({required this.pdfs, required this.low, required this.high, required this.indexBytes, required this.needBytes, required this.usable});

  /// PDFs still to read.
  final int pdfs;
  final Duration low;
  final Duration high;

  /// The finished index, about.
  final int indexBytes;

  /// The room the run needs: the staging and the publish's copy of it.
  final int needBytes;

  /// Free space less the device reserve; null when the device cannot say.
  final int? usable;

  bool get fits => usable == null || needBytes <= usable!;
}

/// Decides whether a library starts by itself when it arrives. Null (the default) never does: the owner has not decided
/// (UX-pdf-index-30 section 4 proposes "only under about 10 minutes and 100 MB").
typedef PdfAutoStart = bool Function(PdfEstimate estimate);

/// Bytes the finished index takes for one piece: its stored text (about 200 words), title and page, and the keyword postings.
const int kPdfIndexBytesPerPiece = 2 * 1024;

/// The time a run must have had before its own speed replaces the start pop-up's range.
const Duration kPdfLiveEstimateAfter = Duration(minutes: 2);

/// Making the libraries' PDFs searchable on this device: one run at a time (others wait), pause and resume, remove, the battery
/// pause, the estimate and space check, an index arriving from another device, and the progress kept across a kill. What this
/// device built and what the person paused is kept in a small file of its own (never synced).
class PdfIndexState extends ChangeNotifier {
  PdfIndexState({
    required this.core,
    required this.zims,
    required this.indexesDir,
    required this.recordFile,
    this.changes,
    this.readPages = readPdfPagesFromBytes,
    this.battery = readBattery,
    Space Function(String dir)? space,
    this.onIndexReady,
    this.autoStart,
    this.watchEvery = const Duration(seconds: 30),
    DateTime Function()? clock,
  }) : space = space ?? ((d) => Space.of(d)),
       clock = clock ?? DateTime.now {
    changes?.addListener(_onZims);
  }

  final PdfIndexCore core;
  final List<PdfZimRef> Function() zims;
  final Listenable? changes;

  /// The device's indexes folder (the core's indexes_dir): each ZIM's PDF index is zim-pdf/<uuid>/ in it.
  final Future<Directory> Function() indexesDir;
  String? _indexes;

  final Future<File> Function() recordFile;
  final PdfBytesReader readPages;
  final BatteryReader? battery;
  final Space Function(String dir) space;

  /// The core should look at a new snapshot (built here or arrived): the app gives it the sources again.
  final Future<void> Function()? onIndexReady;

  /// The single setting hook for starting by itself; null is off.
  PdfAutoStart? autoStart;
  final Duration watchEvery;
  final DateTime Function() clock;

  /// Shows a short message (a snackbar): set by the app shell.
  void Function(String text)? say;

  bool get available => core.available;

  Map<String, dynamic> _record = {};
  bool _loaded = false;
  final Map<String, ZimPdfList> _lists = {};
  final Set<String> _listing = {};
  final Map<String, String> _listFailed = {};
  final Map<String, (DateTime, PdfSnapshot?, bool)> _manifests = {};
  final Set<String> _measuring = {};
  final Map<String, (Duration, Duration)> _ranges = {};
  final Map<String, PdfRunFailure> _failures = {};
  final List<String> _queue = [];
  PdfIndexRun? _run;
  String? _runPath;
  Timer? _watch;
  Set<String>? _known;

  /// The run in progress, for tests.
  PdfIndexRun? get run => _run;

  Future<void> init() async {
    if (_loaded) return;
    try {
      _indexes = (await indexesDir()).path;
      final f = await recordFile();
      if (f.existsSync()) _record = (jsonDecode(f.readAsStringSync()) as Map).cast<String, dynamic>();
    } catch (_) {
      _record = {};
    }
    _loaded = true;
    _watch = Timer.periodic(watchEvery, (_) => _rewatch());
    _onZims();
    notifyListeners();
  }

  bool _disposed = false;

  /// Work that finishes after dispose (a listing, a run) tells no one.
  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    changes?.removeListener(_onZims);
    _watch?.cancel();
    _run?.stop(PdfRunStop.person);
    super.dispose();
  }

  Map<String, dynamic> _rec(String fileName) => (_record[fileName] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};

  Future<void> _put(String fileName, Map<String, dynamic> values) async {
    final r = {..._rec(fileName), ...values}..removeWhere((_, v) => v == null);
    _record[fileName] = r;
    await _save();
  }

  Future<void> _saving = Future<void>.value();

  /// Writes the record, one write at a time (a new file renamed over the old).
  Future<void> _save() => _saving = _saving.then((_) async {
    try {
      final f = await recordFile();
      await f.parent.create(recursive: true);
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(jsonEncode(_record), flush: true);
      await tmp.rename(f.path);
    } catch (_) {}
  });

  PdfZimRef? _zim(String path) => zims().where((z) => z.path == path).firstOrNull;

  /// The ZIMs changed: list the new ones' PDFs, stop a run whose ZIM went, and offer the start-by-itself hook a ZIM that has
  /// just arrived.
  void _onZims() {
    if (!_loaded || !available) return;
    final now = zims();
    final paths = {for (final z in now) z.path};
    if (_runPath != null && !paths.contains(_runPath)) _run?.stop(PdfRunStop.cancel);
    _queue.removeWhere((p) => !paths.contains(p));
    final known = _known;
    _known = paths;
    // A ZIM that went (deleted here or by sync, or replaced by an update): its index goes from this device.
    for (final gone in known?.difference(paths) ?? const <String>{}) {
      unawaited(forget(gone));
    }
    for (final z in now) {
      if (z.uuid == null) continue;
      _ensureList(z);
      if (known != null && !known.contains(z.path)) unawaited(_maybeAutoStart(z));
    }
    notifyListeners();
  }

  void _ensureList(PdfZimRef z) {
    final have = _lists[z.path];
    if ((have != null && have.zimUuid == z.uuid) || _listing.contains(z.path)) return;
    _listing.add(z.path);
    unawaited(() async {
      try {
        final l = await core.zimPdfs(z.uuid!);
        _lists[z.path] = l;
        _listFailed.remove(z.path);
        await _put(z.fileName, {'count': l.pdfs.length, 'count_uuid': l.zimUuid});
      } catch (e) {
        _listFailed[z.path] = '$e';
      } finally {
        _listing.remove(z.path);
        notifyListeners();
      }
    }());
  }

  /// The PDF list of [z], listing it when needed.
  Future<ZimPdfList?> listOf(PdfZimRef z) async {
    final have = _lists[z.path];
    if (have != null && have.zimUuid == z.uuid) return have;
    if (z.uuid == null) return null;
    try {
      final l = await core.zimPdfs(z.uuid!);
      _lists[z.path] = l;
      return l;
    } catch (_) {
      return null;
    }
  }

  /// [z]'s folders in the indexes folder; null until its uuid is known.
  PdfIndexPaths? pathsOf(PdfZimRef z) => _paths(z);

  /// The name cs_pdfindex_open is given for [z].
  String zimNameOf(PdfZimRef z, ZimPdfList? list) => _zimName(z, list);

  PdfIndexPaths? _paths(PdfZimRef z) => z.uuid == null || _indexes == null ? null : PdfIndexPaths(_indexes!, z.uuid!);

  /// The ZIM's name for cs_pdfindex_open: its own, else the file name without ".zim".
  String _zimName(PdfZimRef z, ZimPdfList? list) {
    final n = list?.zimName ?? '';
    return n.isNotEmpty ? n : z.fileName.replaceFirst(RegExp(r'\.zim$', caseSensitive: false), '');
  }

  /// The snapshot every device uses for [z]'s ZIM version (null when none is complete here), and whether the version this file
  /// had before has one (a new ZIM version: that index is not this ZIM's). Read again after 10 seconds.
  (PdfSnapshot?, bool) _snapshot(PdfZimRef z, {bool fresh = false}) {
    final m = _manifests[z.path];
    final now = clock();
    if (!fresh && m != null && now.difference(m.$1) < const Duration(seconds: 10)) return (m.$2, m.$3);
    final paths = _paths(z);
    final mine = paths?.current();
    final before = _rec(z.fileName)['index_uuid'];
    if (mine != null && before != z.uuid) unawaited(_put(z.fileName, {'index_uuid': z.uuid}));
    final other = mine == null && before is String && before != z.uuid && _indexes != null && PdfIndexPaths(_indexes!, before).current() != null;
    _manifests[z.path] = (now, mine, other);
    return (mine, other);
  }

  /// Every [watchEvery]: an index that arrived from another device (sync) is noticed, and a run of the same version gives way.
  void _rewatch() {
    if (!available) return;
    var changed = false;
    for (final z in zims()) {
      final before = _manifests[z.path]?.$2?.id;
      final m = _snapshot(z, fresh: true).$1;
      if (m?.id != before) changed = true;
      if (m != null && z.path == _runPath && m.id != _rec(z.fileName)['built'] && !(_run?.finishing ?? false)) {
        _run?.stop(PdfRunStop.superseded);
      }
    }
    if (changed) {
      notifyListeners();
      unawaited(onIndexReady?.call());
    }
  }

  /// The PDFs part of [z]; null when there is nothing to show (no PDFs, not listed yet, the core cannot index).
  PdfPart? partOf(PdfZimRef z) {
    if (!available || !_loaded || z.uuid == null || _indexes == null) return null;
    final rec = _rec(z.fileName);
    final list = _lists[z.path];
    final total = list?.zimUuid == z.uuid ? list!.pdfs.length : (rec['count_uuid'] == z.uuid ? (rec['count'] as num?)?.toInt() : null);
    if (total == null) {
      _ensureList(z);
      return null;
    }
    if (total == 0) return null;
    final run = _runPath == z.path ? _run : null;
    if (run != null) {
      if (run.finishing) return PdfPart(phase: PdfPartPhase.finishing, total: total, handled: run.handled, unreadable: run.skipped, finishFraction: run.finishFraction);
      if (run.stopped == PdfRunStop.person || run.stopped == PdfRunStop.battery || run.stopped == PdfRunStop.cancel) {
        return PdfPart(phase: PdfPartPhase.pausing, total: total, handled: run.handled);
      }
      if (run.starting) return PdfPart(phase: PdfPartPhase.starting, total: total, handled: run.handled);
      final live = run.elapsed >= kPdfLiveEstimateAfter ? run.timeLeft : null;
      final range = live == null && run.timeLeft != null ? _ranges[z.path] : null;
      return PdfPart(phase: PdfPartPhase.running, total: total, handled: run.handled, unreadable: run.skipped, timeLeft: live ?? (range == null ? run.timeLeft : null), range: range);
    }
    if (_queue.contains(z.path)) return PdfPart(phase: PdfPartPhase.waiting, total: total, handled: (rec['handled'] as num?)?.toInt() ?? 0);
    if (_measuring.contains(z.path)) return PdfPart(phase: PdfPartPhase.measuring, total: total);
    final (m, otherVersion) = _snapshot(z);
    final paths = _paths(z)!;
    final handled = (rec['handled'] as num?)?.toInt() ?? 0;
    final failure = _failures[z.path];
    if (failure != null && paths.build.existsSync()) {
      return PdfPart(phase: PdfPartPhase.failed, total: total, handled: handled, failure: failure);
    }
    if (m != null) {
      return PdfPart(
        phase: PdfPartPhase.done,
        total: total,
        handled: m.pdfs + m.skipped,
        unreadable: m.skipped,
        fromOtherDevice: rec['built'] != m.id,
      );
    }
    if (paths.build.existsSync()) {
      final pause = switch (rec['pause']) {
        'person' => PdfPause.person,
        'battery' => PdfPause.battery,
        _ => PdfPause.closed,
      };
      return PdfPart(phase: PdfPartPhase.paused, total: total, handled: handled, pause: pause);
    }
    // Snapshots for another version only: a new ZIM version (v2 snapshots do not list their PDFs, so no "new" count).
    if (otherVersion) return PdfPart(phase: PdfPartPhase.newVersion, total: total);
    return PdfPart(phase: PdfPartPhase.idle, total: total);
  }

  /// Libraries whose PDFs are not all searchable, for the line under search results: (library, part), hidden ones left out.
  List<(PdfZimRef, PdfPart)> pending() => [
    for (final z in zims())
      if (partOf(z) case final p? when p.phase != PdfPartPhase.done && _rec(z.fileName)['note_hidden'] != true) (z, p),
  ];

  /// The close mark on that line: hides it for these libraries (the library still offers the action).
  Future<void> hideNote(Iterable<PdfZimRef> libs) async {
    for (final z in libs) {
      await _put(z.fileName, {'note_hidden': true});
    }
    notifyListeners();
  }

  /// Times a short sample on this device (up to 3 PDFs, about 20 seconds) and checks the space: what the start pop-up shows.
  Future<PdfEstimate?> measure(PdfZimRef z, {Duration budget = const Duration(seconds: 20)}) async {
    if (z.uuid == null) return null;
    _measuring.add(z.path);
    notifyListeners();
    try {
      final list = await listOf(z);
      if (list == null) return null;
      final build = _paths(z)!.build;
      final doneHere = build.existsSync() ? ((_rec(z.fileName)['handled'] as num?)?.toInt() ?? 0) : 0;
      final todo = list.pdfs.length - doneHere;
      final bytes = list.bytes;
      final sp = space(File(z.path).parent.path);
      final sorted = [...list.pdfs]..sort((a, b) => a.size.compareTo(b.size));
      final picks = <ZimPdf>{
        if (sorted.isNotEmpty) sorted[sorted.length ~/ 2],
        if (sorted.length > 3) sorted[sorted.length ~/ 4],
        if (sorted.length > 3) sorted[(sorted.length * 3) ~/ 4],
      }.toList();
      final rows = <PdfTimingRow>[];
      final clockStart = clock();
      for (final p in picks) {
        final run = PdfIndexRun(
          core: core,
          paths: _paths(z)!,
          zimName: _zimName(z, list),
          list: ZimPdfList(zimUuid: list.zimUuid, zimName: list.zimName, pdfs: [p]),
          readPages: readPages,
          stage: false,
          onTiming: rows.add,
        );
        await run.run();
        if (clock().difference(clockStart) > budget) break;
      }
      final ms = rows.fold(0, (s, r) => s + r.totalMs);
      final sampleBytes = rows.fold(0, (s, r) => s + r.bytes);
      final samplePieces = rows.fold(0, (s, r) => s + r.pieces);
      final double perPdfMs = rows.isEmpty ? 2000 : ms / rows.length;
      final remainingBytes = (bytes * (todo / (list.pdfs.isEmpty ? 1 : list.pdfs.length))).round();
      final estMs = sampleBytes > 0 && bytes > 0 ? ms / sampleBytes * remainingBytes : perPdfMs * todo;
      final pieces = sampleBytes > 0 && bytes > 0 ? samplePieces / sampleBytes * bytes : (rows.isEmpty ? 0 : samplePieces / rows.length * list.pdfs.length);
      final indexBytes = (pieces * kPdfIndexBytesPerPiece).round();
      final low = Duration(milliseconds: (estMs * 0.7).round());
      final high = Duration(milliseconds: (estMs * 1.5).round());
      _ranges[z.path] = (low, high);
      return PdfEstimate(pdfs: todo, low: low, high: high, indexBytes: indexBytes, needBytes: indexBytes * 2, usable: sp.usable);
    } finally {
      _measuring.remove(z.path);
      notifyListeners();
    }
  }

  /// Starts (or resumes) [z]; it waits when another library is running.
  Future<void> start(PdfZimRef z) async {
    _failures.remove(z.path);
    if (_run != null) {
      if (_runPath != z.path && !_queue.contains(z.path)) _queue.add(z.path);
      notifyListeners();
      return;
    }
    await _put(z.fileName, {'pause': null});
    unawaited(_go(z));
  }

  Future<void> _go(PdfZimRef z) async {
    final list = await listOf(z);
    if (list == null) {
      _failures[z.path] = const PdfRunFailure(PdfRunFailureKind.other, 'The library could not be read.');
      notifyListeners();
      return;
    }
    final run = _run = PdfIndexRun(core: core, paths: _paths(z)!, zimName: _zimName(z, list), list: list, readPages: readPages, battery: battery, clock: clock);
    _runPath = z.path;
    var lastSaved = -1;
    void onRun() {
      if (run.handled != lastSaved && !run.starting) {
        lastSaved = run.handled;
        // What a kill keeps: the committed PDFs (the core commits in batches) and the skipped ones.
        unawaited(_put(z.fileName, {'handled': run.committed + run.skipped, 'skipped': run.skipped, 'uuid': z.uuid}));
      }
      notifyListeners();
    }

    run.addListener(onRun);
    notifyListeners();
    final end = await run.run();
    run.removeListener(onRun);
    _run = null;
    _runPath = null;
    switch (end) {
      case PdfRunEnd.finished:
        await _put(z.fileName, {'pause': null, 'handled': null, 'built': run.result?['snapshot'] ?? _snapshot(z, fresh: true).$1?.id, 'built_uuid': z.uuid});
        await onIndexReady?.call();
      case PdfRunEnd.paused:
        await _put(z.fileName, {'pause': run.stopped == PdfRunStop.battery ? 'battery' : 'person', 'handled': run.handled});
      case PdfRunEnd.cancelled:
        await _put(z.fileName, {'pause': null, 'handled': null});
      case PdfRunEnd.superseded:
        await _put(z.fileName, {'pause': null, 'handled': null});
        say?.call('Another device finished this. Using its index.');
        await onIndexReady?.call();
      case PdfRunEnd.failed:
        _failures[z.path] = run.failure ?? const PdfRunFailure(PdfRunFailureKind.other);
        await _put(z.fileName, {'pause': 'person', 'handled': run.handled});
    }
    _manifests.remove(z.path);
    notifyListeners();
    _next();
  }

  void _next() {
    while (_queue.isNotEmpty && _run == null) {
      final z = _zim(_queue.removeAt(0));
      if (z != null) {
        unawaited(start(z));
        return;
      }
    }
  }

  /// Pause (the person's): the build stays; Resume continues from the last committed PDF.
  void pause(PdfZimRef z) {
    if (_runPath == z.path) {
      _run?.stop(PdfRunStop.person);
    } else if (_queue.remove(z.path)) {
      notifyListeners();
    }
  }

  /// Remove under a paused line: the build is deleted (a run is cancelled).
  Future<void> remove(PdfZimRef z) async {
    _queue.remove(z.path);
    _failures.remove(z.path);
    if (_runPath == z.path) {
      _run?.stop(PdfRunStop.cancel);
      return;
    }
    final paths = _paths(z);
    try {
      if (paths != null) await core.discard(indexesDir: paths.indexesDir, zimUuid: paths.zimUuid);
    } catch (_) {}
    await _put(z.fileName, {'pause': null, 'handled': null});
    notifyListeners();
  }

  /// A library that has just arrived starts by itself when the hook says so (off by default).
  Future<void> _maybeAutoStart(PdfZimRef z) async {
    final hook = autoStart;
    if (hook == null || _run != null) return;
    final e = await measure(z);
    if (e == null || !e.fits || !hook(e)) return;
    await start(z);
    say?.call('Making ${e.pdfs} PDFs searchable.');
  }

  /// The ZIM at [zimPath] is gone: its index (every snapshot and the build) and record go from this device. The delete of a
  /// snapshot never syncs, so other devices keep theirs.
  Future<void> forget(String zimPath) async {
    if (_runPath == zimPath) _run?.stop(PdfRunStop.cancel);
    _queue.remove(zimPath);
    final name = zimPath.split(RegExp(r'[\\/]')).last;
    final rec = _rec(name);
    final uuids = {rec['count_uuid'], rec['index_uuid'], rec['built_uuid'], rec['uuid']}.whereType<String>();
    _record.remove(name);
    await _save();
    // Only an index no ZIM still here uses (two files may be the same ZIM).
    final kept = {for (final z in zims()) ?z.uuid};
    final root = _indexes;
    if (root != null) {
      for (final u in uuids) {
        if (!kept.contains(u)) PdfIndexPaths(root, u).deleteAll();
      }
    }
    _lists.remove(zimPath);
    _manifests.remove(zimPath);
    notifyListeners();
  }
}
