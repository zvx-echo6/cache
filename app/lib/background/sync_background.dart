import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../files.dart' show writeStringAtomic;
import '../platform/app_log.dart';
import '../platform/battery.dart';
import '../search/index_throttle.dart' show kHeatPause;
import '../settings/app_settings.dart';
import '../settings/data_policy.dart';
import '../sharing/sharing_state.dart' show SyncCoreLike, SyncOpener, drainSyncLogToLog, openSyncCore;
import '../platform.dart' as plat;
import '../weather/background.dart' show backgroundReady, runBackgroundUpdate;
import 'background_lock.dart';
import 'background_tasks.dart';

// Background sync (minimal, 1.1): one bounded round with the linked devices, with the app closed. Design: DESIGN-background-sync.
// - Android: a periodic WorkManager job (about hourly, a network, not on a low battery). iPhone: a BGAppRefreshTask and, while
//   charging, a BGProcessingTask, whenever iOS chooses to run them.
// - The run opens the same sync engine the app opens, from the settings the app last gave it (sync-config.json), runs ONE round
//   (the engine's first), waits for it to finish within a time budget, and closes the engine.
// - It never runs beside the app's engine (the one lock: the app's mark `engine-sync`, the run's `run-sync`), nor beside Add PDF.

/// How often Android may run it (WorkManager picks the moment; its least is 15 minutes).
const Duration kSyncEvery = Duration(hours: 1);

/// How long a round may take: Android's job, the iPhone processing task, and the iPhone refresh task (iOS gives about 30 s).
const Duration kSyncBudgetAndroid = Duration(minutes: 4);
const Duration kSyncBudgetProcessing = Duration(minutes: 4);
const Duration kSyncBudgetRefresh = Duration(seconds: 20);

/// The engine stops itself this long after the budget, in case the system stopped the run before it could close the engine.
const Duration kSyncEngineGrace = Duration(seconds: 90);

/// How long opening the engine may take before the round gives up on it (it opens in well under a second; an open that waits on
/// something, such as another engine's store, never came back on a Pixel, so the round's own time limit never began).
const Duration kSyncOpenLimit = Duration(seconds: 60);

String syncBackgroundDir(String support) => '$support${Platform.pathSeparator}background';

/// What the app last opened its engine with (the open call's settings, `only` and `off` as last given), kept for the background run.
File syncConfigFile(String support) => File('${syncBackgroundDir(support)}${Platform.pathSeparator}sync-config.json');

/// Writes the settings the background run opens the engine with.
Future<void> writeSyncConfig(String support, Map<String, Object?> config) async {
  try {
    final f = syncConfigFile(support);
    await f.parent.create(recursive: true);
    await writeStringAtomic(f, jsonEncode(config));
  } catch (e) {
    logError('Background sync: the settings it needs could not be written', error: e);
  }
}

Map<String, Object?>? readSyncConfig(String support) {
  try {
    final f = syncConfigFile(support);
    if (!f.existsSync()) return null;
    final j = jsonDecode(f.readAsStringSync());
    return j is Map ? j.cast<String, Object?>() : null;
  } catch (_) {
    return null;
  }
}

/// Everything that decides whether a run goes ahead.
class SyncFacts {
  const SyncFacts({
    this.configured = true,
    this.enabled = true,
    this.linked = true,
    this.readable = true,
    this.appOpen = false,
    this.engineRuns = false,
    this.addRuns = false,
    this.syncRuns = false,
    this.held,
    this.connection = ConnectionKind.wifi,
    this.mobileData = false,
  });

  /// The app has left its settings (sync-config.json), and sharing is switched on.
  final bool configured, enabled;

  /// At least one device is linked.
  final bool linked;

  /// The shared folders and the links file can be read (an iPhone woken before its first unlock cannot: reading nothing there
  /// must never look like every file deleted).
  final bool readable;
  final bool appOpen, engineRuns, addRuns, syncRuns;

  /// Why the battery or heat hold it ("battery low (12%)", "the phone is hot"), or null.
  final String? held;
  final ConnectionKind connection;

  /// Mobile data is allowed for downloads (Settings > Storage); sync follows the same rule as downloads.
  final bool mobileData;
}

/// Why a run does not go ahead (the words the log gets), or null when it may. The order is the order of the checks.
String? syncSkipReason(SyncFacts f) {
  if (!f.configured || !f.enabled) return 'skipped: sharing is not set up';
  if (!f.linked) return 'skipped: no linked devices';
  if (!f.readable) return 'skipped: the shared folders cannot be read yet (the phone has not been unlocked since it started)';
  if (f.appOpen) return 'skipped: Cache is open';
  if (f.engineRuns) return "skipped: the app's own sync is running";
  if (f.addRuns) return 'skipped: Add PDF is running';
  if (f.syncRuns) return 'skipped: another background sync is running';
  if (f.held != null) return 'held: ${f.held}';
  if (f.connection == ConnectionKind.none) return 'skipped: no network';
  if (f.connection == ConnectionKind.mobile && !f.mobileData) return 'skipped: on mobile data, which downloads may not use';
  return null;
}

/// The battery and heat rules the other background jobs follow: under 20% and not charging, or a hot phone, holds it.
String? syncHeld(BatteryReading? b) {
  if (b == null) return null;
  if (b.low) return 'battery low (${b.percent}%)';
  if (b.thermal.index >= Thermal.severe.index || (b.headroom ?? 0) >= kHeatPause) return 'the phone is hot';
  return null;
}

/// How a bounded round ended: [why] is `done`, `alone` (nobody in reach), `time`, `asked`, `held` or `paused`.
class RoundResult {
  const RoundResult(this.why, this.words, {this.arrived = 0, this.left = 0});

  final String why;
  final String words;

  /// Files here after the round minus before it (never below 0), and the files still to fetch when it ended.
  final int arrived, left;
}

int _sum(Map<String, dynamic> st, String key) {
  var n = 0;
  for (final s in (st['shares'] as List? ?? const [])) {
    if (s is Map) n += (s[key] as num?)?.toInt() ?? 0;
  }
  return n;
}

/// Waits for the engine's first round (the engine starts one at once; callers set a long interval so there is no second) and
/// returns when it has finished fetching, when [budget] is used, when [stopAsked] says so, or when [held] gives a reason (looked
/// at every [heldEvery]). The engine is left running: the caller closes it.
Future<RoundResult> runBoundedRound({
  required SyncCoreLike core,
  required Duration budget,
  bool Function()? stopAsked,
  Future<String?> Function()? held,
  void Function()? alive,
  Duration look = const Duration(seconds: 1),
  Duration heldEvery = const Duration(seconds: 10),
  DateTime Function()? clock,
  Future<void> Function(Duration)? sleep,
}) async {
  final now = clock ?? DateTime.now;
  final nap = sleep ?? (Duration d) => Future<void>.delayed(d);
  final start = now();
  final end = start.add(budget);
  var nextHeld = start.add(heldEvery);
  var st = await core.call('status');
  final before = _sum(st, 'files');
  RoundResult finish(String why, String words) {
    final files = _sum(st, 'files');
    return RoundResult(why, words, arrived: files > before ? files - before : 0, left: _sum(st, 'pending_files'));
  }

  while (true) {
    final t = now();
    if (!t.isBefore(end)) {
      final left = _sum(st, 'pending_files');
      return finish('time', 'out of time (${budget.inSeconds} s)${left > 0 ? ', $left files still to fetch' : ''}');
    }
    if (stopAsked?.call() ?? false) return finish('asked', 'stopped: Cache needs the engine');
    if (held != null && !t.isBefore(nextHeld)) {
      nextHeld = t.add(heldEvery);
      final why = await held();
      if (why != null) return finish('held', 'stopped: $why');
    }
    await nap(look);
    st = await core.call('status');
    alive?.call();
    final rounds = (st['rounds'] as num?)?.toInt() ?? 0;
    if (rounds < 1) continue;
    final pending = _sum(st, 'pending_files');
    final busy = st['transfer'] != null;
    if (!busy && pending == 0) {
      final live = [for (final p in (st['peers'] as List? ?? const [])) if (p is Map && p['live'] == true && p['error'] == null) p].length;
      if (live == 0) return finish('alone', 'no linked device in reach');
      final got = _sum(st, 'files') - before;
      return finish('done', got > 0 ? 'synced with $live of ${(st['peers'] as List).length} devices, $got more files here' : 'synced with $live of ${(st['peers'] as List).length} devices, nothing new');
    }
    final paused = st['paused'];
    if (!busy && paused is String) return finish('paused', 'paused: $paused');
  }
}

/// What the files on disk say: whether a device is linked, and whether the links file and the shared folders can be read.
({bool linked, bool readable}) readSyncFiles(String support) {
  try {
    final f = File('$support${Platform.pathSeparator}sync${Platform.pathSeparator}sync.json');
    if (!f.existsSync()) return (linked: false, readable: true);
    final String text;
    try {
      text = f.readAsStringSync();
    } catch (_) {
      return (linked: true, readable: false);
    }
    Object? j;
    try {
      j = jsonDecode(text);
    } catch (_) {
      return (linked: true, readable: true);
    }
    if (j is! Map) return (linked: true, readable: true);
    final peers = j['peers'];
    final linked = peers is! List || peers.isNotEmpty;
    for (final s in (j['shares'] as List? ?? const [])) {
      final path = s is Map ? s['path'] : null;
      if (path is! String) continue;
      try {
        final d = Directory(path);
        if (!d.existsSync()) return (linked: linked, readable: false);
        d.listSync(followLinks: false).take(1).toList();
      } catch (_) {
        return (linked: linked, readable: false);
      }
    }
    return (linked: linked, readable: true);
  } catch (_) {
    return (linked: true, readable: false);
  }
}

bool _sharingOn(String support) {
  try {
    final f = File('$support${Platform.pathSeparator}sharing.json');
    return f.existsSync() && (jsonDecode(f.readAsStringSync()) as Map)['enabled'] == true;
  } catch (_) {
    return false;
  }
}

Future<bool> _mobileDataAllowed() async {
  try {
    final s = AppSettings();
    await s.init();
    return s.mobileForDownloads;
  } catch (_) {
    return false;
  }
}

/// The background sync job: decides (see [syncSkipReason]), holds the lock, opens the engine from the app's last settings, runs one
/// bounded round, closes the engine and lets go. Returns how it ended, in a few words, for the one log line of the run.
Future<String> syncBackgroundJob({
  required String support,
  Duration budget = kSyncBudgetAndroid,
  Duration openLimit = kSyncOpenLimit,
  void Function()? drainLog,
  BackgroundLock? lock,
  SyncOpener opener = openSyncCore,
  BatteryReader battery = readBattery,
  Future<ConnectionKind> Function()? connection,
  bool? mobileData,
  Duration look = const Duration(seconds: 1),
  DateTime Function()? clock,
  Future<void> Function(Duration)? sleep,
}) async {
  final l = lock ?? BackgroundLock(Directory(syncBackgroundDir(support)));
  final config = readSyncConfig(support);
  final files = readSyncFiles(support);
  BatteryReading? b;
  try {
    b = await battery();
  } catch (_) {}
  ConnectionKind kind;
  try {
    kind = await (connection ?? ConnectivityProbe().current)();
  } catch (_) {
    kind = ConnectionKind.other;
  }
  final facts = SyncFacts(
    configured: config != null,
    enabled: _sharingOn(support),
    linked: files.linked,
    readable: files.readable,
    appOpen: l.appOpen,
    engineRuns: l.engineRuns(kSyncWork),
    addRuns: l.runs(kAddPdfWork),
    syncRuns: l.runs(kSyncWork),
    held: syncHeld(b),
    connection: kind,
    mobileData: mobileData ?? await _mobileDataAllowed(),
  );
  final skip = syncSkipReason(facts);
  if (skip != null) return skip;
  // No bump of the generation: a sync round changes no state the app keeps; it reads the folders as it opens.
  if (!l.hold(kSyncWork, bump: false)) return l.appOpen ? 'skipped: Cache is open' : "skipped: the app's own sync or another run holds it";
  final refresh = Timer.periodic(BackgroundLock.refreshEvery, (_) => l.refresh(kSyncWork));
  SyncCoreLike? core;
  // The engine's own lines about its start are taken every second, while it opens and while it runs, so a start that hangs leaves
  // its last step in the log (the engine never calls into Dart; the lines are asked for).
  final drain = drainLog ?? drainSyncLogToLog;
  final drainTimer = Timer.periodic(const Duration(seconds: 1), (_) => drain());
  try {
    logInfo('Background sync: a round starts (${budget.inSeconds} s at most)');
    try {
      final opening = opener({
        ...config!,
        // Iroh only here: the Wi-Fi multicast lock is held by the app, and a round has none, so no multicast runs without it.
        'reticulum': false,
        'dir': '$support${Platform.pathSeparator}sync',
        // one automatic round (the engine's first); the engine stops itself shortly after the budget if this run is cut off
        'interval_secs': 3600,
        'lifetime_secs': (budget + kSyncEngineGrace).inSeconds,
        // Never a new identity here: a key missing from the folder is brought back (or, when every copy is gone, made) by the app's
        // own start, which can reach the second copy beside the install marker (sharing/identity_keep.dart). The open fails and the
        // round is skipped until then.
        'make_identity': false,
      });
      try {
        core = await opening.timeout(openLimit);
      } on TimeoutException {
        // The open is left to finish (it cannot be called back); an engine it opens late is closed at once.
        unawaited(opening.then((c) => c.close(), onError: (Object _) {}));
        drain();
        logInfo('Background sync: the engine did not open within ${openLimit.inSeconds} s; the round is given up');
        return 'skipped: the engine did not open in time';
      }
      await core.call('set_policy', {'network': true});
    } catch (e) {
      // most likely another engine holds the folder: nothing was started, and the next run tries again
      logInfo('Background sync: the engine could not be opened ($e)');
      return 'skipped: the engine could not be opened';
    }
    final r = await runBoundedRound(
      core: core,
      budget: budget,
      look: look,
      clock: clock,
      sleep: sleep,
      stopAsked: () => l.stopAsked(kSyncWork) || l.runs(kAddPdfWork),
      held: () async => syncHeld(await battery()),
      alive: () => l.refresh(kSyncWork),
    );
    logInfo('Background sync: ${r.words}');
    return r.words;
  } finally {
    drainTimer.cancel();
    drain();
    refresh.cancel();
    try {
      await core?.close().timeout(const Duration(seconds: 10));
    } catch (_) {}
    l.release(kSyncWork);
  }
}

/// Keeps the background sync scheduled while sharing is set up, and cancelled when it is not. Safe to call often. Android: the
/// periodic job, its network rule following "mobile data for downloads". iPhone: the app-refresh task and the processing task
/// (iOS decides when, if at all). [android] and [ios] are tests' stand-ins for the platform.
Future<void> scheduleBackgroundSync({required bool enabled, required bool mobileData, bool? android, bool? ios}) async {
  final a = android ?? Platform.isAndroid;
  final i = ios ?? Platform.isIOS;
  if (!a && !i) return;
  try {
    await backgroundReady;
    if (!enabled) {
      for (final t in [if (a) kSyncTask, if (i) ...[kSyncRefreshTask, kSyncProcessingTask]]) {
        await backgroundScheduler.cancel(t);
      }
      return;
    }
    if (a) await backgroundScheduler.periodic(kSyncTask, every: kSyncEvery, constraints: BackgroundPresets.sync(mobileData: mobileData));
    if (i) {
      await backgroundScheduler.periodic(kSyncRefreshTask, every: kSyncEvery, constraints: BackgroundPresets.network());
      await scheduleProcessing(kSyncProcessingTask, constraints: BackgroundPresets.syncCharging(), delay: kSyncEvery);
    }
  } catch (e) {
    logError('Background sync could not be scheduled', error: e);
  }
}

/// The iPhone's refresh task (the one background run iOS gives for the app, no new task name): the sync round, then the weather
/// update if it is due (nothing else runs weather on an iPhone with Cache closed). Android has its own weather job, so there
/// this is only the sync round. A weather update that throws is logged and never changes how the sync round ends.
/// [sync], [weather] and [ios] are a test's stand-ins.
Future<String> syncRefreshRun({
  required Future<String> Function() sync,
  Future<void> Function()? weather,
  bool? ios,
}) async {
  String outcome;
  try {
    outcome = await sync();
  } finally {
    if (ios ?? plat.isIOS) {
      try {
        await (weather ?? () => runBackgroundUpdate(onlyIfDue: true))();
      } catch (e, st) {
        logError('Background weather update (with the sync round) failed', error: e, stack: st);
      }
    }
  }
  return outcome;
}
