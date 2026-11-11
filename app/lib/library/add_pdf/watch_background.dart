import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cache_ocr/cache_ocr.dart' show deviceOcrEngine;

import '../../app_fs.dart';
import '../../background/background_lock.dart';
import '../../background/background_tasks.dart';
import '../../notebook/sync/folder.dart' show FolderFile;
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

/// Add PDF over the real core in the background engine: the same ingest calls, engines and OCR engine as the app, and the
/// Bookshelves argument the app left in `add-context.json`.
Future<AddPdfState> _backgroundAddPdfState(String support, Directory ingest) async {
  Map<String, dynamic>? shelves;
  try {
    final f = watchAddContextFile(support);
    if (f.existsSync()) shelves = ((jsonDecode(await f.readAsString()) as Map)['bookshelves'] as Map?)?.cast<String, dynamic>();
  } catch (_) {}
  return AddPdfState(
    calls: const CoreIngestCalls(),
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
