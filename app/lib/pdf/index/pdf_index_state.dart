import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../settings/space.dart';
import '../../platform/battery.dart';
import 'pdf_index_core.dart';
import 'pdf_index_run.dart';
import 'pdf_pages.dart';

/// A ZIM as PDF indexing sees it.
class PdfZimRef {
  const PdfZimRef({required this.path, required this.uuid, required this.title, this.language});

  final String path;

  /// The ZIM's Language metadata ("eng"); null or empty when not known (the core then takes English).
  final String? language;

  /// Null until the core has opened the ZIM.
  final String? uuid;
  final String title;

  String get fileName => path.split(RegExp(r'[\\/]')).last;
}

/// Where a library's PDFs stand. Making them searchable is always on (owner, 2026-11-02): there is nothing to start, only a
/// status, Pause and Resume, and the fix when there is no room.
enum PdfPartPhase { waiting, starting, running, pausing, finishing, paused, needsSpace, failed, done }

/// Who paused it.
enum PdfPause { person, battery, closed }

/// What the PDFs part of one library shows.
class PdfPart {
  const PdfPart({
    required this.phase,
    required this.total,
    this.handled = 0,
    this.unreadable = 0,
    this.pause,
    this.failure,
    this.fromOtherDevice = false,
    this.finishFraction,
    this.needBytes = 0,
    this.newCount = 0,
  });

  final PdfPartPhase phase;

  /// PDFs in the ZIM.
  final int total;

  /// PDFs done or skipped so far.
  final int handled;

  /// Skipped PDFs (no text, locked, damaged): "12 could not be read".
  final int unreadable;
  final PdfPause? pause;
  final PdfRunFailure? failure;
  final bool fromOtherDevice;
  final double? finishFraction;

  /// The room the run needs when there is not enough ([PdfPartPhase.needsSpace]).
  final int needBytes;

  /// A new edition of a ZIM whose older edition's PDFs are reused: the PDFs not in it (new or changed), "22 new PDFs".
  final int newCount;

  double? get fraction => total > 0 ? (handled / total).clamp(0.0, 1.0) : null;

  /// Still being made searchable (or waiting to be): what the line under search results is about.
  bool get inProgress => phase != PdfPartPhase.done;
}

/// What a run is expected to take, measured on this device before it starts.
class PdfEstimate {
  const PdfEstimate({required this.pdfs, required this.low, required this.high, required this.indexBytes, required this.needBytes, required this.usable});

  /// PDFs still to read.
  final int pdfs;
  final Duration low;
  final Duration high;

  /// The finished index, about.
  final int indexBytes;

  /// The room the run needs: the build and the publish's copy of it.
  final int needBytes;

  /// Free space less the device reserve; null when the device cannot say.
  final int? usable;

  bool get fits => usable == null || needBytes <= usable!;

  /// A long job: it starts only while charging or above 50% battery.
  bool get long => high > kPdfLongJob;
}

/// Decides whether a library's PDFs are made searchable by themselves. On by default (owner, 2026-11-02: everything inside a ZIM
/// is searchable); [pdfAutoStartAlways] is the default.
typedef PdfAutoStart = bool Function(PdfZimRef zim);

bool pdfAutoStartAlways(PdfZimRef zim) => true;

/// Bytes the finished index takes for one piece: its stored text (about 200 words), title and page, and the keyword postings.
const int kPdfIndexBytesPerPiece = 2 * 1024;

/// A job longer than this starts only while charging or above [kPdfLongJobBattery]% battery.
const Duration kPdfLongJob = Duration(minutes: 10);
const int kPdfLongJobBattery = 50;

/// Making the libraries' PDFs searchable on this device, by itself: every ZIM with PDFs and no snapshot for its edition is
/// queued (on download, at start and on a new edition, which reuses the old edition's unchanged PDFs) and run one at a time
/// while the app is open. A long job waits for charging or 50% battery; a run pauses on low battery and stops on low storage;
/// the space is checked against the reserve first, and when there is not enough that is the state, with Free space. A snapshot
/// that is here or arrives from a linked device means nothing to do. What this device built and what the person paused is kept
/// in a small file of its own (never synced).
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
    this.autoStart = pdfAutoStartAlways,
    this.watchEvery = const Duration(seconds: 30),
    DateTime Function()? clock,
  }) : space = space ?? ((d) => Space.of(d)),
       clock = clock ?? DateTime.now {
    changes?.addListener(_onZims);
  }

  final PdfIndexCore core;
  final List<PdfZimRef> Function() zims;
  final Listenable? changes;

  /// The device's indexes folder (the core's indexes_dir): each ZIM's PDF index is `zim-pdf/<uuid>/` in it.
  final Future<Directory> Function() indexesDir;
  String? _indexes;

  final Future<File> Function() recordFile;
  final PdfBytesReader readPages;
  final BatteryReader? battery;
  final Space Function(String dir) space;

  /// The core should look at a new snapshot (built here or arrived): the app gives it the sources again.
  final Future<void> Function()? onIndexReady;

  /// The one setting hook for starting by itself: on for every ZIM by default; null never starts by itself.
  PdfAutoStart? autoStart;
  final Duration watchEvery;
  final DateTime Function() clock;

  /// The index scheduler's throttle (its permit call), awaited before each PDF and between pages; null never waits. Set by the
  /// app where the scheduler is made.
  PdfPermit? permit;

  /// Shows a short message (a snackbar): set by the app shell.
  void Function(String text)? say;

  bool get available => core.available;

  Map<String, dynamic> _record = {};
  bool _loaded = false;
  final Map<String, ZimPdfList> _lists = {};
  final Set<String> _listing = {};
  final Map<String, (DateTime, PdfSnapshot?)> _snaps = {};
  final Map<String, PdfEstimate> _estimates = {};
  final Map<String, PdfRunFailure> _failures = {};

  /// Libraries held back before they start: no room (with the room needed), or a long job on a low battery.
  final Map<String, (PdfPartPhase, int)> _blocked = {};
  final List<String> _queue = [];
  PdfIndexRun? _run;
  String? _runPath;
  bool _picking = false;
  Timer? _watch;
  Set<String>? _known;

  /// The run in progress, for tests.
  PdfIndexRun? get run => _run;

  Future<void> init() async {
    if (_loaded) return;
    try {
      await core.prepare();
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
    if (_disposed) return;
    try {
      final f = await recordFile();
      await f.parent.create(recursive: true);
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(jsonEncode(_record), flush: true);
      await tmp.rename(f.path);
    } catch (_) {}
  });

  PdfZimRef? _zim(String path) => zims().where((z) => z.path == path).firstOrNull;

  /// The ZIMs changed: list the new ones' PDFs, stop a run whose ZIM went (and remove its index), and queue what needs doing.
  void _onZims() {
    if (!_loaded || !available) return;
    final now = zims();
    final paths = {for (final z in now) z.path};
    if (_runPath != null && !paths.contains(_runPath)) _run?.stop(PdfRunStop.cancel);
    _queue.removeWhere((p) => !paths.contains(p));
    final known = _known;
    _known = paths;
    for (final gone in known?.difference(paths) ?? const <String>{}) {
      unawaited(forget(gone));
    }
    for (final z in now) {
      if (z.uuid != null) _ensureList(z);
    }
    _schedule();
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
        await _put(z.fileName, {'count': l.pdfs.length, 'count_uuid': l.zimUuid, 'zim_name': l.zimName});
      } catch (_) {
      } finally {
        _listing.remove(z.path);
        _schedule();
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

  /// The name cs_pdfindex_open is given for [z]: the ZIM's metadata Name (the same for every edition).
  String zimNameOf(PdfZimRef z, ZimPdfList? list) => _zimName(z, list);

  PdfIndexPaths? _paths(PdfZimRef z) => z.uuid == null || _indexes == null ? null : PdfIndexPaths(_indexes!, z.uuid!);

  String _zimName(PdfZimRef z, ZimPdfList? list) {
    final n = list?.zimName ?? '';
    return n.isNotEmpty ? n : z.fileName.replaceFirst(RegExp(r'\.zim$', caseSensitive: false), '');
  }

  /// The snapshot every device uses for [z]'s edition, or null. Read again after 10 seconds.
  PdfSnapshot? _snapshot(PdfZimRef z, {bool fresh = false}) {
    final m = _snaps[z.path];
    final now = clock();
    if (!fresh && m != null && now.difference(m.$1) < const Duration(seconds: 10)) return m.$2;
    final s = _paths(z)?.current();
    _snaps[z.path] = (now, s);
    return s;
  }

  /// An older edition of [z] (the same metadata Name, another uuid) with a snapshot on this device: its PDFs are reused.
  String? _previous(PdfZimRef z, ZimPdfList list) {
    final root = _indexes;
    if (root == null || list.zimName.isEmpty) return null;
    PdfSnapshot? best;
    String? uuid;
    for (final u in pdfIndexUuids(root)) {
      if (u == z.uuid) continue;
      final s = PdfIndexPaths(root, u).current();
      if (s == null || s.zimName != list.zimName) continue;
      if (best == null || s.created.compareTo(best.created) > 0) {
        best = s;
        uuid = u;
      }
    }
    return uuid;
  }

  final Map<String, (String, int)> _newCounts = {};

  /// For a new edition: the PDFs of [z] that its older edition's snapshot does not hold at the same path and size (its pdfs.tsv);
  /// 0 when there is no older edition here.
  int _newCount(PdfZimRef z) {
    final list = _lists[z.path];
    final root = _indexes;
    if (list == null || list.zimUuid != z.uuid || root == null) return 0;
    final prev = _previous(z, list);
    if (prev == null) return 0;
    final have = _newCounts[z.path];
    if (have != null && have.$1 == prev) return have.$2;
    final paths = PdfIndexPaths(root, prev);
    final snap = paths.current();
    var n = 0;
    if (snap != null) {
      final known = <String>{};
      try {
        final f = File('${paths.snaps.path}${Platform.pathSeparator}${snap.id}${Platform.pathSeparator}pdfs.tsv');
        for (final line in f.readAsLinesSync()) {
          final c = line.split('\t');
          if (c.length >= 2) known.add('${c[0]}\t${c[1]}');
        }
      } catch (_) {}
      n = list.pdfs.where((p) => !known.contains('${p.path}\t${p.size}')).length;
    }
    _newCounts[z.path] = (prev, n);
    return n;
  }

  /// Every [watchEvery]: a snapshot that arrived from another device is noticed (a run of the same edition gives way), and what
  /// was held back (battery, space) is tried again.
  void _rewatch() {
    if (!available) return;
    var changed = false;
    for (final z in zims()) {
      final before = _snaps[z.path]?.$2?.id;
      final m = _snapshot(z, fresh: true);
      if (m?.id != before) changed = true;
      if (m != null && z.path == _runPath && m.id != _rec(z.fileName)['built'] && !(_run?.finishing ?? false)) {
        _run?.stop(PdfRunStop.superseded);
      }
    }
    _blocked.clear();
    _sweep();
    // "Device is full" is tried again (the space is checked first, so it only starts when there is room).
    _failures.removeWhere((_, f) => f.kind == PdfRunFailureKind.full);
    if (changed) {
      notifyListeners();
      unawaited(onIndexReady?.call());
    }
    unawaited(() async {
      // A run paused by a low battery goes on by itself once charging or above 50%.
      final paused = [for (final e in _record.entries) if (e.value is Map && (e.value as Map)['pause'] == 'battery') e.key];
      if (paused.isNotEmpty && await _batteryAllows()) {
        for (final name in paused) {
          await _put(name, {'pause': null});
        }
      }
      _schedule();
    }());
  }

  int? _total(PdfZimRef z) {
    final list = _lists[z.path];
    if (list != null && list.zimUuid == z.uuid) return list.pdfs.length;
    final rec = _rec(z.fileName);
    return rec['count_uuid'] == z.uuid ? (rec['count'] as num?)?.toInt() : null;
  }

  /// The PDFs part of [z]; null when there is nothing to show (no PDFs, not listed yet, the core cannot index).
  PdfPart? partOf(PdfZimRef z) {
    if (!available || !_loaded || z.uuid == null || _indexes == null) return null;
    final total = _total(z);
    if (total == null) {
      _ensureList(z);
      return null;
    }
    if (total == 0) return null;
    final rec = _rec(z.fileName);
    final run = _runPath == z.path ? _run : null;
    if (run != null) {
      if (run.finishing) return PdfPart(phase: PdfPartPhase.finishing, total: total, handled: run.handled, unreadable: run.skipped, finishFraction: run.finishFraction);
      if (run.stopped != PdfRunStop.none) return PdfPart(phase: PdfPartPhase.pausing, total: total, handled: run.handled);
      if (run.starting) return PdfPart(phase: PdfPartPhase.starting, total: total, handled: run.handled, newCount: _newCount(z));
      return PdfPart(phase: PdfPartPhase.running, total: total, handled: run.handled, unreadable: run.skipped, newCount: _newCount(z));
    }
    final m = _snapshot(z);
    if (m != null) {
      return PdfPart(phase: PdfPartPhase.done, total: total, handled: m.pdfs + m.skipped, unreadable: m.skipped, fromOtherDevice: rec['built'] != m.id);
    }
    final handled = _paths(z)!.build.existsSync() ? (rec['handled'] as num?)?.toInt() ?? 0 : 0;
    final failure = _failures[z.path];
    if (failure != null) {
      if (failure.kind == PdfRunFailureKind.full) {
        return PdfPart(phase: PdfPartPhase.needsSpace, total: total, handled: handled, needBytes: _estimates[z.path]?.needBytes ?? 0);
      }
      return PdfPart(phase: PdfPartPhase.failed, total: total, handled: handled, failure: failure);
    }
    final blocked = _blocked[z.path];
    if (blocked?.$1 == PdfPartPhase.needsSpace) return PdfPart(phase: PdfPartPhase.needsSpace, total: total, handled: handled, needBytes: blocked!.$2);
    if (blocked?.$1 == PdfPartPhase.paused) return PdfPart(phase: PdfPartPhase.paused, total: total, handled: handled, pause: PdfPause.battery);
    switch (rec['pause']) {
      case 'person':
        return PdfPart(phase: PdfPartPhase.paused, total: total, handled: handled, pause: PdfPause.person);
      case 'battery':
        return PdfPart(phase: PdfPartPhase.paused, total: total, handled: handled, pause: PdfPause.battery);
    }
    if (_queue.contains(z.path) || _picking) return PdfPart(phase: PdfPartPhase.waiting, total: total, handled: handled, newCount: _newCount(z));
    // Nothing queued it (start-by-itself off): a build left by an earlier run is a pause.
    if (handled > 0 || _paths(z)!.build.existsSync()) return PdfPart(phase: PdfPartPhase.paused, total: total, handled: handled, pause: PdfPause.closed);
    return PdfPart(phase: PdfPartPhase.waiting, total: total, handled: handled);
  }

  /// Libraries whose PDFs are still being made searchable, for the line under search results: (library, part), hidden ones left
  /// out.
  List<(PdfZimRef, PdfPart)> pending() => [
    for (final z in zims())
      if (partOf(z) case final p? when p.inProgress && _rec(z.fileName)['note_hidden'] != true) (z, p),
  ];

  /// The close mark on that line: hides it for these libraries.
  Future<void> hideNote(Iterable<PdfZimRef> libs) async {
    for (final z in libs) {
      await _put(z.fileName, {'note_hidden': true});
    }
    notifyListeners();
  }

  /// Times a short sample on this device (up to 3 PDFs, about 20 seconds) and checks the space: whether the run fits and is long.
  Future<PdfEstimate?> measure(PdfZimRef z, {Duration budget = const Duration(seconds: 20)}) async {
    if (z.uuid == null) return null;
    final list = await listOf(z);
    if (list == null) return null;
    final paths = _paths(z)!;
    final doneHere = paths.build.existsSync() ? ((_rec(z.fileName)['handled'] as num?)?.toInt() ?? 0) : 0;
    final todo = (list.pdfs.length - doneHere).clamp(0, list.pdfs.length);
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
        paths: paths,
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
    final e = PdfEstimate(
      pdfs: todo,
      low: Duration(milliseconds: (estMs * 0.7).round()),
      high: Duration(milliseconds: (estMs * 1.5).round()),
      indexBytes: indexBytes,
      needBytes: indexBytes * 2,
      usable: sp.usable,
    );
    _estimates[z.path] = e;
    return e;
  }

  /// Queues every library that needs doing and starts the next one when nothing runs: each ZIM with PDFs and no snapshot for its
  /// edition, not paused by the person, not held back.
  void _schedule() {
    if (!_loaded || !available || _disposed) return;
    final hook = autoStart;
    for (final z in zims()) {
      if (z.uuid == null || z.path == _runPath || _queue.contains(z.path) || _blocked.containsKey(z.path) || _failures.containsKey(z.path)) continue;
      final total = _total(z);
      if (total == null || total == 0 || _snapshot(z) != null) continue;
      final pause = _rec(z.fileName)['pause'];
      if (pause == 'person' || pause == 'battery') continue;
      if (hook == null || !hook(z)) continue;
      _queue.add(z.path);
    }
    unawaited(_next());
  }

  /// Starts the next queued library that may run now: the space checked against the reserve first, a long job only while
  /// charging or above 50% battery (unless the person pressed Resume). One run at a time: [_picking] holds until the run has
  /// begun.
  Future<void> _next({String? forced}) async {
    if (_run != null || _picking) return;
    _picking = true;
    var handedOff = false;
    try {
      while (_queue.isNotEmpty && _run == null && !_disposed) {
        final path = forced != null && _queue.contains(forced) ? forced : _queue.first;
        _queue.remove(path);
        final z = _zim(path);
        if (z == null || z.uuid == null) continue;
        final e = _estimates[path] ?? await measure(z);
        if (e == null) continue;
        final usable = space(File(z.path).parent.path).usable;
        if (usable != null && e.needBytes > usable) {
          _blocked[path] = (PdfPartPhase.needsSpace, e.needBytes);
          notifyListeners();
          continue;
        }
        if (e.long && path != forced && !await _batteryAllows()) {
          _blocked[path] = (PdfPartPhase.paused, 0);
          notifyListeners();
          continue;
        }
        handedOff = true;
        unawaited(_go(z));
        return;
      }
    } finally {
      if (!handedOff) _picking = false;
      notifyListeners();
    }
  }

  Future<bool> _batteryAllows() async {
    final b = battery;
    if (b == null) return true;
    final r = await b();
    return r == null || r.charging || r.percent > kPdfLongJobBattery;
  }

  Future<void> _go(PdfZimRef z) async {
    final list = await listOf(z);
    final paths = _paths(z);
    if (list == null || paths == null) {
      _picking = false;
      _failures[z.path] = const PdfRunFailure(PdfRunFailureKind.other, 'The library could not be read.');
      notifyListeners();
      _schedule();
      return;
    }
    await _put(z.fileName, {'pause': null});
    final run = _run = PdfIndexRun(
      core: core,
      paths: paths,
      zimName: _zimName(z, list),
      previousZimUuid: _previous(z, list),
      language: (z.language ?? '').trim().isEmpty ? null : z.language,
      list: list,
      readPages: readPages,
      battery: battery,
      spaceOk: () => (space(File(z.path).parent.path).usable ?? 1) > 0,
      // This device's note of the PDF being extracted (never synced), beside its record.
      permit: permit,
      attemptFile: File('${(await recordFile()).parent.path}${Platform.pathSeparator}pdf-index-attempt-${z.uuid}.json'),
      clock: clock,
    );
    _runPath = z.path;
    _picking = false;
    var lastSaved = -1;
    void onRun() {
      if (run.committed != lastSaved && !run.starting) {
        lastSaved = run.committed;
        // What a kill keeps: the committed PDFs (the core commits in batches), added and skipped.
        unawaited(_put(z.fileName, {'handled': run.committed, 'uuid': z.uuid}));
      }
      notifyListeners();
    }

    run.addListener(onRun);
    notifyListeners();
    final end = await run.run();
    run.removeListener(onRun);
    // This device built it: recorded before the run lets go, so the snapshot never shows as one from another device (a kill
    // right after the publish would otherwise leave it so).
    if (end == PdfRunEnd.finished) {
      await _put(z.fileName, {'pause': null, 'handled': null, 'built': run.result?['snapshot'] ?? _snapshot(z, fresh: true)?.id, 'built_uuid': z.uuid});
    }
    _run = null;
    _runPath = null;
    switch (end) {
      case PdfRunEnd.finished:
        _cleanOldEditions(z, list);
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
        await _put(z.fileName, {'handled': run.handled});
    }
    _snaps.remove(z.path);
    notifyListeners();
    _schedule();
  }

  /// A new edition is searchable: the index of an older edition (the same metadata Name) that no ZIM here uses goes from this
  /// device.
  void _cleanOldEditions(PdfZimRef z, ZimPdfList list) {
    final root = _indexes;
    if (root == null || list.zimName.isEmpty) return;
    final kept = {for (final x in zims()) ?x.uuid};
    for (final u in pdfIndexUuids(root)) {
      // Never the edition just published (its ZIM may have gone meanwhile: an update arriving as it finished, whose new edition
      // reuses it).
      if (kept.contains(u) || u == z.uuid) continue;
      final p = PdfIndexPaths(root, u);
      if (p.current()?.zimName == list.zimName) p.deleteAll();
    }
  }

  /// Pause (the person's): the build stays; it does not start again by itself until Resume.
  Future<void> pause(PdfZimRef z) async {
    if (_runPath == z.path) {
      _run?.stop(PdfRunStop.person);
      return;
    }
    _queue.remove(z.path);
    _blocked.remove(z.path);
    await _put(z.fileName, {'pause': 'person'});
    notifyListeners();
  }

  // ---- The entry points for the app-wide index scheduler ----
  // The scheduler that decides when automatic index work runs sets [autoStart] to null (this state then queues nothing by
  // itself), asks [needsIndex] which ZIMs have PDFs to make searchable, and calls [start] and [pause]; [partOf] is the state.

  /// True when [z]'s PDFs need making searchable on this device: it has PDFs (listed), no snapshot for its edition, nothing
  /// running for it, and the person has not paused it. Null while that is not known yet (not listed).
  bool? needsIndex(PdfZimRef z) {
    if (!available || !_loaded || z.uuid == null) return null;
    final total = _total(z);
    if (total == null) {
      _ensureList(z);
      return null;
    }
    return total > 0 && _snapshot(z) == null && z.path != _runPath && _rec(z.fileName)['pause'] != 'person';
  }

  /// Starts (or resumes) [z] now, ahead of anything queued, on any battery; the space is checked first ("Needs ... free" when
  /// there is not enough). The same as the person's Resume.
  Future<void> start(PdfZimRef z) => resume(z);

  /// The index scheduler's pause (the app went to the back, the battery ran low): a run of [z] stops and keeps its build, but not
  /// as the person's Pause, so the scheduler starts it again later; a queued [z] leaves the queue.
  Future<void> hold(PdfZimRef z) async {
    _queue.remove(z.path);
    if (_runPath == z.path) _run?.stop(PdfRunStop.battery);
    notifyListeners();
  }

  /// What a run of [z] was measured to take, when it has been (null before).
  PdfEstimate? estimateOf(PdfZimRef z) => _estimates[z.path];

  /// Resume (or Free space done, or Try again): starts now, ahead of the queue, on any battery; the space is checked again.
  Future<void> resume(PdfZimRef z) async {
    _failures.remove(z.path);
    _blocked.remove(z.path);
    await _put(z.fileName, {'pause': null});
    if (!_queue.contains(z.path) && z.path != _runPath) _queue.insert(0, z.path);
    notifyListeners();
    unawaited(_next(forced: z.path));
  }

  /// Deletes [z]'s build (a run is cancelled); used when its ZIM goes.
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

  /// The ZIM at [zimPath] is gone: its build and record go. Its snapshots are left to [_sweep], which keeps them while a ZIM
  /// here is the same ZIM or a newer edition of it that may still reuse them.
  Future<void> forget(String zimPath) async {
    if (_runPath == zimPath) _run?.stop(PdfRunStop.cancel);
    _queue.remove(zimPath);
    _blocked.remove(zimPath);
    _failures.remove(zimPath);
    final name = zimPath.split(RegExp(r'[\\/]')).last;
    final rec = _rec(name);
    final uuids = {rec['count_uuid'], rec['built_uuid'], rec['uuid']}.whereType<String>();
    _record.remove(name);
    await _save();
    final kept = {for (final z in zims()) ?z.uuid};
    final root = _indexes;
    if (root != null) {
      for (final u in uuids) {
        if (kept.contains(u)) continue;
        try {
          final b = PdfIndexPaths(root, u).build;
          if (b.existsSync()) b.deleteSync(recursive: true);
        } catch (_) {}
      }
    }
    _lists.remove(zimPath);
    _snaps.remove(zimPath);
    notifyListeners();
    _sweep(afterRemove: true);
  }

  /// Removes from this device the indexes no ZIM here uses: neither the same ZIM nor an edition with the same metadata Name
  /// (which may still reuse it until its own is published). Only once every ZIM here has been listed (its Name known). A delete
  /// under snap/ never syncs, so other devices keep theirs.
  void _sweep({bool afterRemove = false}) {
    final root = _indexes;
    if (root == null) return;
    final present = zims();
    // No ZIM listed at all is a library not read yet (unless one was just removed): nothing is swept on it.
    if (present.isEmpty && !afterRemove) return;
    if (present.any((z) => z.uuid == null || _lists[z.path]?.zimUuid != z.uuid)) return;
    final uuids = {for (final z in present) z.uuid!};
    final names = {for (final z in present) _lists[z.path]!.zimName}..remove('');
    for (final u in pdfIndexUuids(root)) {
      if (uuids.contains(u)) continue;
      final p = PdfIndexPaths(root, u);
      final n = p.current()?.zimName;
      if (n == null || !names.contains(n)) p.deleteAll();
    }
  }
}
