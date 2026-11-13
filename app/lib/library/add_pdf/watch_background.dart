import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cache_ocr/cache_ocr.dart' show deviceOcrEngine;

import '../../app_fs.dart';
import '../../background/background_lock.dart';
import '../../background/background_tasks.dart';
import '../../background/fgs_add.dart';
import '../../notebook/sync/folder.dart' show FolderFile;
import '../../pdf/pdfium_init.dart' show installNativePdfFonts;
import '../../platform/app_log.dart';
import '../../platform/battery.dart';
import '../../search/index_throttle.dart';
import '../../settings/app_settings.dart';
import '../../weather/background.dart' show backgroundReady;
import 'add_pdf_calls.dart';
import 'add_pdf_engines.dart';
import 'add_pdf_slice.dart';
import 'add_pdf_state.dart';
import 'watch_folders.dart';

// Watched folders in the background (Android only; iOS checks only when Cache opens):
// - watch-folder-detect, a few times a day: lists each watched folder and counts the files that are new or changed since its
//   last check (name, size and time). It reads no file, adds nothing and shows nothing; when it counts any, it queues one
//   watch-folder-add.
// - watch-folder-add, once, while charging and not on a low battery: the watched folders' check (content hashes, as when Cache
//   opens), then Add PDF's jobs in slices of about 8 minutes, each slice queueing the next while there is more. It holds the
//   one lock: it never runs while Cache is open, and stops when Cache comes to the front. Heat and the battery are checked
//   during it by the indexing rules.

/// How often Android counts new files in the watched folders with Cache closed.
const Duration kWatchDetectEvery = Duration(hours: 6);

/// How long a slice held by heat or the battery waits before the next try.
const Duration kWatchAddRetry = Duration(minutes: 30);

/// The folder under the app's support folder the background layer keeps its files in.
String backgroundDir(String support) => '$support${Platform.pathSeparator}background';

/// The detect task's record (`watch-detect.json`): per folder, how many new files it counted and when.
File watchDetectFile(String support) => File('${backgroundDir(support)}${Platform.pathSeparator}watch-detect.json');

/// What the add task needs from the app that it cannot work out itself (`add-context.json`, written by the app): the
/// `bookshelves` argument of the core's ingest job (the Bookshelves folder, this device's id, the libraries).
File watchAddContextFile(String support) => File('${backgroundDir(support)}${Platform.pathSeparator}add-context.json');

/// The files of [listed] that are PDFs and new or changed since [f]'s last check (by name, size and time; nothing is read).
int countNewFiles(WatchedFolder f, List<FolderFile> listed) {
  var n = 0;
  for (final x in listed) {
    if (!isWatchedPdf(x.path)) continue;
    final k = f.files[x.path];
    if (k == null || k.size != x.size || k.mtime != x.mtime) n++;
  }
  return n;
}

/// Schedules the detect task while folders are watched, and cancels it when none are. Android only.
Future<void> scheduleWatchDetect({required bool anyFolders, bool? android}) async {
  if (!(android ?? Platform.isAndroid)) return;
  try {
    await backgroundReady;
    if (!anyFolders) {
      await backgroundScheduler.cancel(kWatchDetectTask);
      await backgroundScheduler.cancel(kWatchAddTask);
      return;
    }
    await backgroundScheduler.periodic(kWatchDetectTask, every: kWatchDetectEvery, constraints: BackgroundPresets.light());
  } catch (e) {
    logError('Watch a folder: the background check could not be scheduled', error: e);
  }
}

/// Queues one add task (while charging, not on a low battery). [next]: a slice queues the one after it; [delay]: held by heat or
/// the battery, it tries again later. Android only.
Future<void> scheduleWatchAdd({bool next = false, Duration delay = Duration.zero, bool? android}) async {
  if (!(android ?? Platform.isAndroid)) return;
  try {
    await backgroundReady;
    await backgroundScheduler.once(kWatchAddTask, constraints: BackgroundPresets.charging(), delay: delay, after: next);
  } catch (e) {
    logError('Watch a folder: adding in the background could not be scheduled', error: e);
  }
}

/// How long Cache, going to the back, waits for its index work to stop before handing off anyway (a PDF step in flight cannot
/// be cut short; a job folder still in use is then a hold and a retry for the background run, never a failure).
const Duration kHandOffWait = Duration(seconds: 30);

/// Cache going to the back hands Add PDF's work to the background: it waits for its index work to stop (at most [wait]), saves,
/// lets go of the lock and queues the background add when the watched folders have PDFs still to add. Each step is logged.
/// Returns what happened: "front" (back at the front meanwhile: nothing handed off), "nothing" (nothing to add), "queued", or
/// "queued after wait" (the work was still stopping after [wait]).
Future<String> backgroundHandOff({
  required Future<void> closed,
  required Future<void> Function() save,
  required bool Function() atFront,
  required void Function() release,
  required bool Function() hasWork,
  required Future<void> Function() queueAdd,
  Duration wait = kHandOffWait,
}) async {
  logInfo('Background hand-off: waiting for index work to stop');
  final stopped = await closed.then((_) => true).timeout(wait, onTimeout: () => false);
  logInfo(stopped
      ? 'Background hand-off: index work stopped'
      : 'Background hand-off: index work still stopping after ${wait.inSeconds} s; handing off anyway');
  await save();
  if (atFront()) {
    logInfo('Background hand-off: Cache is at the front again; nothing handed off');
    return 'front';
  }
  release();
  if (!hasWork()) {
    logInfo('Background hand-off: lock released; nothing to add');
    return 'nothing';
  }
  await queueAdd();
  logInfo('Background hand-off: lock released; adding queued for the background while charging');
  return stopped ? 'queued' : 'queued after wait';
}

/// The detect job: counts what is new in each watched folder that can be reached, records it, and queues an add when there is
/// any. Not while Cache is open (Cache checks for itself then).
Future<String> watchDetectJob({required String support, BackgroundLock? lock, WatchFolderAccess access = const WatchFolderAccess(), Future<void> Function()? queueAdd, DateTime Function()? clock}) async {
  final l = lock ?? BackgroundLock(Directory(backgroundDir(support)));
  if (l.appOpen) return 'skipped: Cache is open';
  final folders = await readWatchedFolders(support);
  if (folders.isEmpty) return 'no folders';
  final record = <String, Object?>{};
  var total = 0, looked = 0;
  for (final f in folders) {
    if (f.unreachable) continue;
    try {
      if (!await access.reachable(f.root)) continue;
      final n = countNewFiles(f, await access.list(f.root));
      looked++;
      total += n;
      record[f.id] = {'new': n, 'at': (clock ?? DateTime.now)().toIso8601String()};
    } catch (e) {
      logError('Watch a folder: a folder could not be listed in the background', error: e);
    }
  }
  try {
    final out = watchDetectFile(support);
    await out.parent.create(recursive: true);
    await out.writeAsString(jsonEncode(record), flush: true);
  } catch (_) {}
  if (total > 0) await (queueAdd ?? scheduleWatchAdd)();
  return '$total new in $looked of ${folders.length} folders';
}

/// The watched folders as `watched.json` keeps them (read only).
Future<List<WatchedFolder>> readWatchedFolders(String support) async {
  try {
    final f = File('$support${Platform.pathSeparator}ingest${Platform.pathSeparator}watched.json');
    if (!f.existsSync()) return const [];
    final j = jsonDecode(await f.readAsString()) as Map;
    return [for (final e in (j['folders'] as List? ?? const [])) WatchedFolder.fromJson((e as Map).cast<String, dynamic>())];
  } catch (e) {
    logError('Watch a folder: the list could not be read in the background', error: e);
    return const [];
  }
}

/// The add job: holds the lock, checks the watched folders (folders whose library does not exist yet are left to Cache, which
/// makes it), then runs one slice of Add PDF's jobs and queues the next slice while there is more. [state] and [watch]: tests
/// give their own; on a phone they are made here over the real core.
Future<String> watchAddJob({
  required String support,
  BackgroundLock? lock,
  BatteryReader battery = readBattery,
  AddPdfState? state,
  WatchFoldersState? watch,
  Duration budget = kAddPdfSliceBudget,
  Future<void> Function({bool next, Duration delay})? queue,
  IndexThrottle? throttle,
}) async {
  final l = lock ?? BackgroundLock(Directory(backgroundDir(support)));
  final again = queue ?? ({bool next = false, Duration delay = Duration.zero}) => scheduleWatchAdd(next: next, delay: delay);
  // the app's own indexing rules: its throttle (thermal headroom and status, battery, the person's speed) over cache_device's
  // readings, the same as adding a PDF in the app
  final th = throttle ?? IndexThrottle(read: battery, mobile: Platform.isAndroid || Platform.isIOS, speed: await _indexSpeed());
  final first = await addPdfHeldNow(th);
  if (first != null) {
    if (throttle == null) th.dispose();
    await again(delay: kWatchAddRetry);
    return 'held: $first';
  }
  if (!l.hold(kAddPdfWork)) {
    if (throttle == null) th.dispose();
    return l.appOpen ? 'skipped: Cache is open' : 'skipped: another run is adding';
  }
  final before = indexThrottleShared;
  indexThrottleShared = th;
  final refresh = Timer.periodic(BackgroundLock.refreshEvery, (_) => l.refresh(kAddPdfWork));
  final ingest = Directory('$support${Platform.pathSeparator}ingest');
  final s = state ?? await _backgroundAddPdfState(support, ingest);
  final w = watch ?? WatchFoldersState(addPdf: s, dir: () async => ingest);
  try {
    await w.load();
    for (final f in w.folders) {
      if (l.stopAsked(kAddPdfWork)) break;
      if (f.unreachable || f.libraryPath == null) continue;
      await w.check(f);
    }
    final r = await AddPdfSlice(
      s,
      budget: budget,
      stopAsked: () => l.stopAsked(kAddPdfWork),
      // only what the watched folders found: a PDF added by hand is added while Cache is open, as always
      only: (j) => j.watchId != null,
      throttle: th,
      held: () async => addPdfHeld(th),
    ).run();
    // more to do: the next slice, unless Cache took over (it carries on itself)
    if (r.more && r.why != 'app') await again(next: r.why == 'time', delay: r.why == 'time' ? Duration.zero : kWatchAddRetry);
    return r.words;
  } finally {
    indexThrottleShared = before;
    if (throttle == null) th.dispose();
    refresh.cancel();
    await s.save();
    await w.save();
    if (watch == null) w.dispose();
    if (state == null) s.dispose();
    l.release(kAddPdfWork);
  }
}

/// How long the foreground service's add may run: the slice's budget (it has no 8-minute slice; Android 15's own limit, 6 hours in
/// 24, ends it with `onTimeout`, handled by the service).
const Duration kFgsAddBudget = Duration(hours: 7);

/// How long the service waits for Cache to finish going to the back (it is started while Cache is still in front, and the app's
/// hand-off then lets go of the lock) before it gives up.
const Duration kFgsWaitForBack = Duration(seconds: 90);

/// The service's side of a run: what it is told (stop, with why: "person" Pause, "timeout" Android's limit) and what it tells.
class FgsAddControl {
  FgsAddControl({this.onProgress});

  /// Set by a stop message; read by the slice's checks.
  String? stopWhy;

  /// How the run ended, set when it does (also written to the result file for the in-app notice).
  FgsAddResult? result;

  /// When exactly one PDF could not be added: its name and the Add PDF page's own words for the error (title and body).
  (String, String, String)? failedWords;

  /// A change of progress (at most one a second).
  final void Function(FgsProgress p)? onProgress;

  void stop(String why) => stopWhy ??= why;
}

/// How the service's add ended, in a few words for the log (the result is on [FgsAddControl.result]).
class FgsAddEnd {
  const FgsAddEnd(this.words);
  final String words;
}

/// The foreground service's add job: the same Add PDF slice as [watchAddJob], over the same lock (`run-pdf-add`: it never runs
/// at the same time as the charging run, and Cache coming to the front stops it), with three differences: it runs on the battery
/// too (above the low-battery threshold), it takes every PDF the person left pending (not only the watched folders'), and it has no
/// 8-minute slice. It waits (at most [waitForBack]) for Cache to finish going to the back, since it is started while Cache is
/// still in front. What is left when it ends falls to the charging run ([queue]).
Future<FgsAddEnd> fgsAddJob({
  required String support,
  required FgsAddControl control,
  BackgroundLock? lock,
  BatteryReader battery = readBattery,
  AddPdfState? state,
  IndexThrottle? throttle,
  Duration budget = kFgsAddBudget,
  Duration waitForBack = kFgsWaitForBack,
  Duration look = const Duration(milliseconds: 500),
  Duration progressEvery = const Duration(seconds: 1),
  // how often it looks at the stop, the battery and the heat: Pause answers within this
  Duration lookEvery = const Duration(seconds: 5),
  bool resume = false,
  bool anyway = false,
  Future<void> Function({bool next, Duration delay})? queue,
}) async {
  final l = lock ?? BackgroundLock(Directory(backgroundDir(support)));
  final again = queue ?? ({bool next = false, Duration delay = Duration.zero}) => scheduleWatchAdd(next: next, delay: delay);
  final th = throttle ?? IndexThrottle(read: battery, mobile: Platform.isAndroid || Platform.isIOS, speed: await _indexSpeed());
  void dispose() {
    if (throttle == null) th.dispose();
  }

  // the battery rule: held only below the low-battery threshold (or by heat), not for being unplugged
  // Resume anyway: a low battery does not hold this run (heat still does)
  String? ok(String? w) => anyway && w == 'battery' ? null : w;
  final first = ok(await addPdfHeldNow(th, unplugged: true));
  if (first != null) {
    dispose();
    control.result = FgsAddResult(at: DateTime.now(), why: first, total: 0, added: 0, failedIds: const [], leftIds: const [], batteryPercent: th.reading?.percent, warm: th.reading?.thermal.hot ?? false);
    return FgsAddEnd('held: $first');
  }
  // the one lock: the charging run holds it, or Cache is still in front (the hand-off lets go of it in a moment)
  final end = DateTime.now().add(waitForBack);
  while (!l.hold(kAddPdfWork)) {
    if (l.runs(kAddPdfWork)) {
      dispose();
      return const FgsAddEnd('skipped: another run is adding');
    }
    if (control.stopWhy != null || !DateTime.now().isBefore(end)) {
      dispose();
      return FgsAddEnd(control.stopWhy != null ? 'stopped before it started' : 'skipped: Cache is open');
    }
    await Future<void>.delayed(look);
  }
  final before = indexThrottleShared;
  indexThrottleShared = th;
  final refresh = Timer.periodic(BackgroundLock.refreshEvery, (_) => l.refresh(kAddPdfWork));
  final ingest = Directory('$support${Platform.pathSeparator}ingest');
  final s = state ?? await _backgroundAddPdfState(support, ingest);
  Timer? tick;
  var ids = <String>{};
  AddPdfSliceResult? r;
  try {
    await s.load();
    // the notification's Resume (and Resume anyway: the low battery does not hold it) started this run
    if (resume) {
      for (final j in s.active) {
        j.pausedByPerson = false;
        if (anyway) {
          j.anyway = true;
          j.startNow = true;
        }
      }
    }
    ids = {for (final j in s.active) if (fgsJobMayRun(j, th.reading)) j.id};
    if (ids.isEmpty) return const FgsAddEnd('nothing to add');
    String? lastSent;
    void send() {
      final p = FgsProgress.of(ids, s.jobs);
      if (p == null) return;
      final j = jsonEncode(p.toJson());
      if (j == lastSent) return;
      lastSent = j;
      control.onProgress?.call(p);
    }

    send();
    tick = Timer.periodic(progressEvery, (_) => send());
    r = await AddPdfSlice(
      s,
      budget: budget,
      stopAsked: () => l.stopAsked(kAddPdfWork) || control.stopWhy != null,
      // everything the person left pending that may run now, not only the watched folders' PDFs
      only: (j) => ids.contains(j.id) && fgsJobMayRun(j, th.reading),
      throttle: th,
      lookEvery: lookEvery,
      held: () async => ok(addPdfHeld(th, unplugged: true)),
    ).run();
    return FgsAddEnd(r.words);
  } finally {
    tick?.cancel();
    indexThrottleShared = before;
    refresh.cancel();
    final why = control.stopWhy ?? r?.why ?? 'stopped';
    // Pause: what was running is paused the way the card's Pause pauses it, so it shows "Paused by you" and the charging run leaves it
    if (why == 'person') {
      for (final j in s.active) {
        if (ids.contains(j.id)) j.pausedByPerson = true;
      }
    }
    await s.save();
    final jobs = s.jobs;
    final result = FgsAddResult(
      at: DateTime.now(),
      why: why,
      total: ids.length,
      added: [for (final j in jobs) if (ids.contains(j.id) && j.status == AddPdfStatus.done) j].length,
      failedIds: [for (final j in jobs) if (ids.contains(j.id) && j.status == AddPdfStatus.failed) j.id],
      leftIds: [for (final j in jobs) if (ids.contains(j.id) && j.status == AddPdfStatus.active) j.id],
      batteryPercent: th.reading?.percent,
      warm: th.reading?.thermal.hot ?? false,
      library: switch (jobs.where((j) => ids.contains(j.id)).firstOrNull) { final j? => fgsLibraryWords(j), _ => 'Bookshelves' },
    );
    if (result.failedIds.length == 1) {
      final j = jobs.firstWhere((j) => j.id == result.failedIds.first);
      final w = addPdfErrorWords(j);
      control.failedWords = (j.title, w.title, w.body);
    }
    if (ids.isNotEmpty) {
      await writeFgsResult(backgroundDir(support), result);
      control.result = result;
    }
    // what is left falls to the charging run (watched folders' PDFs; the rest waits for Cache)
    final left = result.leftIds.isNotEmpty;
    if (left && why != 'app' && why != 'person') {
      try {
        await again(delay: kWatchAddRetry);
      } catch (_) {}
    }
    if (throttle == null) th.dispose();
    if (state == null) s.dispose();
    l.release(kAddPdfWork);
  }
}

/// Add PDF over the real core in the background engine: the same ingest calls, engines and OCR engine as the app, and the
/// Bookshelves argument the app left in `add-context.json`.
Future<AddPdfState> _backgroundAddPdfState(String support, Directory ingest) async {
  // the core's one PDFium font mapper, before the first PDF is read (pdfrx is not started in the background run)
  await installNativePdfFonts();
  Map<String, dynamic>? shelves;
  try {
    final f = watchAddContextFile(support);
    if (f.existsSync()) shelves = ((jsonDecode(await f.readAsString()) as Map)['bookshelves'] as Map?)?.cast<String, dynamic>();
  } catch (_) {}
  return AddPdfState(
    calls: const CoreIngestCalls.withoutPdfrx(),
    dir: () async => ingest,
    engines: () async => addPdfEngines(support: Directory(support), modelsDir: Directory('${await appFilesPath()}${Platform.pathSeparator}models')),
    ocrEngine: deviceOcrEngine,
    bookshelves: () async => shelves,
    // no permit of its own: the jobs follow the throttle the job set up (indexThrottleShared), as in the app
  );
}

/// The person's indexing speed (Settings > Storage), as the app's throttle uses it.
Future<IndexSpeed> _indexSpeed() async {
  try {
    final s = AppSettings();
    await s.init();
    return s.indexingNormal ? IndexSpeed.normal : IndexSpeed.gentle;
  } catch (_) {
    return IndexSpeed.gentle;
  }
}

/// The app writes what the add task needs (see [watchAddContextFile]).
Future<void> writeWatchAddContext({required String support, Map<String, dynamic>? bookshelves}) async {
  try {
    final f = watchAddContextFile(support);
    await f.parent.create(recursive: true);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode({'bookshelves': bookshelves}), flush: true);
    await tmp.rename(f.path);
  } catch (e) {
    logError('Watch a folder: what the background needs could not be written', error: e);
  }
}
