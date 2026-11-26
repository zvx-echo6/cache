// Background sync (minimal, 1.1): when a run goes ahead or is skipped, the one lock with the app's own engine and Add PDF, the
// bounded round, the job over a fake engine, the scheduling on Android and iPhone, and the app's side (the engine's mark, the
// settings it keeps for the run, a run asked to stop before the app's engine opens).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cache/background/background_lock.dart';
import 'package:cache/background/background_tasks.dart';
import 'package:cache/background/sync_background.dart';
import 'package:cache/platform/battery.dart';
import 'package:cache/screens/settings/sharing_page.dart' show syncBackgroundNote;
import 'package:cache/settings/app_settings.dart';
import 'package:cache/settings/data_policy.dart';
import 'package:cache/sharing/sharing_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:workmanager/workmanager.dart';

import '../browse/fakes.dart';

class FakeScheduler implements BackgroundScheduler, ProcessingScheduler {
  final List<(String, String, Duration, Constraints)> calls = [];

  @override
  Future<void> periodic(String task, {required Duration every, required Constraints constraints}) async => calls.add(('periodic', task, every, constraints));

  @override
  Future<void> once(String task, {required Constraints constraints, Duration delay = Duration.zero, bool after = false}) async =>
      calls.add(('once', task, delay, constraints));

  @override
  Future<void> cancel(String task) async => calls.add(('cancel', task, Duration.zero, Constraints()));

  @override
  Future<void> processing(String task, {required Constraints constraints, Duration delay = Duration.zero}) async => calls.add(('processing', task, delay, constraints));
}

/// An engine that answers `status` from a script: [rounds] and the rest change with each look.
class RoundCore implements SyncCoreLike {
  RoundCore({this.roundsAfter = 1, this.files = 10, this.arriving = 0, this.pending = 0, this.live = 1, this.paused, this.onStatus});

  /// The look (1, 2, ...) at which the first round is done; null: never.
  int? roundsAfter;
  int files, arriving, pending, live;
  String? paused;
  void Function(int look)? onStatus;
  int looks = 0;
  bool closed = false;
  final calls = <String>[];
  final args = <Map<String, Object?>>[];

  @override
  Future<Map<String, dynamic>> call(String method, [Map<String, Object?> a = const {}]) async {
    calls.add(method);
    args.add(Map.of(a));
    if (method != 'status') return {'ok': true};
    looks++;
    onStatus?.call(looks);
    final done = roundsAfter != null && looks >= roundsAfter!;
    return {
      'rounds': done ? 1 : 0,
      'transfer': null,
      'paused': paused,
      'shares': [
        {'id': 'models', 'files': done ? files + arriving : files, 'pending_files': pending},
      ],
      'peers': [
        for (var i = 0; i < 2; i++) {'id': 'p$i', 'live': i < live, 'error': i < live ? null : 'not reachable'},
      ],
    };
  }

  @override
  Future<void> close() async => closed = true;
}

/// A clock the test moves by sleeping.
class FakeTime {
  DateTime now = DateTime(2026, 11, 14, 12);
  DateTime clock() => now;
  Future<void> sleep(Duration d) async => now = now.add(d);
}

void main() {
  late Directory support;
  late BackgroundLock lock;

  setUp(() {
    support = Directory.systemTemp.createTempSync('sync-bg-');
    lock = BackgroundLock(Directory(syncBackgroundDir(support.path)));
  });
  tearDown(() => support.deleteSync(recursive: true));

  /// What the app leaves for a run: sharing on, its settings, a linked device and a shared folder that can be read.
  void appLeaves({bool linked = true, bool folder = true, bool enabled = true}) {
    File('${support.path}/sharing.json').writeAsStringSync(jsonEncode({'enabled': enabled}));
    Directory('${support.path}/background').createSync(recursive: true);
    File('${support.path}/background/sync-config.json').writeAsStringSync(jsonEncode({'dir': '/old/place/sync', 'name': 'Phone', 'dht': false, 'reticulum': true, 'only': {'indexes': <String>[]}}));
    final shared = Directory('${support.path}/models')..createSync();
    if (folder) File('${shared.path}/a.gguf').writeAsStringSync('x');
    Directory('${support.path}/sync').createSync();
    File('${support.path}/sync/sync.json').writeAsStringSync(jsonEncode({
      'name': 'Phone',
      'peers': linked ? [{'id': 'p0', 'name': 'Desk'}] : <Object>[],
      'shares': [{'id': 'models', 'path': folder ? shared.path : '${support.path}/gone'}],
    }));
  }

  group('when a run goes ahead', () {
    test('only when everything allows it, and the reason otherwise is told in words', () {
      expect(syncSkipReason(const SyncFacts()), isNull);
      expect(syncSkipReason(const SyncFacts(configured: false)), contains('not set up'));
      expect(syncSkipReason(const SyncFacts(enabled: false)), contains('not set up'));
      expect(syncSkipReason(const SyncFacts(linked: false)), contains('no linked devices'));
      expect(syncSkipReason(const SyncFacts(readable: false)), contains('cannot be read yet'));
      expect(syncSkipReason(const SyncFacts(appOpen: true)), 'skipped: Cache is open');
      expect(syncSkipReason(const SyncFacts(engineRuns: true)), contains("app's own sync"));
      expect(syncSkipReason(const SyncFacts(addRuns: true)), contains('Add PDF'));
      expect(syncSkipReason(const SyncFacts(syncRuns: true)), contains('another background sync'));
      expect(syncSkipReason(const SyncFacts(held: 'battery low (12%)')), 'held: battery low (12%)');
      expect(syncSkipReason(const SyncFacts(connection: ConnectionKind.none)), 'skipped: no network');
      // the network-off rule is the downloads' rule: mobile data only when downloads may use it
      expect(syncSkipReason(const SyncFacts(connection: ConnectionKind.mobile)), contains('mobile data'));
      expect(syncSkipReason(const SyncFacts(connection: ConnectionKind.mobile, mobileData: true)), isNull);
      expect(syncSkipReason(const SyncFacts(connection: ConnectionKind.other)), isNull);
      // a phone that cannot be read must not be synced, whatever else is true
      expect(syncSkipReason(const SyncFacts(readable: false, appOpen: true)), contains('cannot be read yet'));
    });

    test('low battery or heat hold it; charging or an unknown battery do not', () {
      expect(syncHeld(null), isNull);
      expect(syncHeld(const BatteryReading(percent: 80, charging: false, thermal: Thermal.nominal)), isNull);
      expect(syncHeld(const BatteryReading(percent: 12, charging: false)), 'battery low (12%)');
      expect(syncHeld(const BatteryReading(percent: 12, charging: true)), isNull);
      expect(syncHeld(const BatteryReading(percent: 80, charging: false, thermal: Thermal.severe)), 'the phone is hot');
      expect(syncHeld(const BatteryReading(percent: 80, charging: false, headroom: 0.95)), 'the phone is hot');
    });

    test('the files on disk: linked or not, and a shared folder that cannot be read', () {
      appLeaves();
      expect(readSyncFiles(support.path), (linked: true, readable: true));
      appLeaves(linked: false);
      expect(readSyncFiles(support.path).linked, isFalse);
      appLeaves(folder: false);
      expect(readSyncFiles(support.path).readable, isFalse, reason: 'a folder that is not there reads as empty, which would look like deletes');
      File('${support.path}/sync/sync.json').deleteSync();
      expect(readSyncFiles(support.path), (linked: false, readable: true));
    });
  });

  group('the one lock', () {
    test('the app being open, its own engine, or another run keeps a run out; a run bumps nothing', () {
      expect(lock.hold(kSyncWork, bump: false), isTrue);
      expect(lock.generation, 0, reason: 'sync changes no state the app keeps');
      expect(lock.hold(kSyncWork), isFalse, reason: 'one run at a time');
      lock.release(kSyncWork);
      lock.appOpened();
      expect(lock.hold(kSyncWork), isFalse);
      lock.appClosed();
      // the app in the back with its engine still running (one engine for the life of the process)
      lock.engineStarted(kSyncWork);
      expect(lock.appOpen, isFalse);
      expect(lock.hold(kSyncWork), isFalse);
      lock.engineStopped(kSyncWork);
      expect(lock.hold(kSyncWork), isTrue);
    });

    test("the app's engine mark goes stale after five minutes (a killed app), and Add PDF's work is not blocked by it", () {
      var t = DateTime(2026, 11, 14, 12);
      final l = BackgroundLock(Directory('${support.path}/lk'), clock: () => t);
      l.engineStarted(kSyncWork);
      expect(l.engineRuns(kSyncWork), isTrue);
      t = t.add(const Duration(minutes: 4));
      expect(l.engineRuns(kSyncWork), isTrue);
      t = t.add(const Duration(minutes: 2));
      expect(l.engineRuns(kSyncWork), isFalse);
      l.engineStarted(kSyncWork);
      expect(l.hold(kAddPdfWork), isTrue, reason: 'the sync engine mark is about sync only');
    });

    test('the app asks a running round to stop and waits for it to let go', () async {
      expect(lock.hold(kSyncWork, bump: false), isTrue);
      Timer(const Duration(milliseconds: 400), () {
        if (lock.stopAsked(kSyncWork)) lock.release(kSyncWork);
      });
      expect(await lock.takeOver(kSyncWork), isTrue);
      expect(lock.runs(kSyncWork), isFalse);
    });
  });

  group('the bounded round', () {
    test('ends when the first round has fetched everything, and says what came', () async {
      final tm = FakeTime();
      final core = RoundCore(roundsAfter: 3, arriving: 4);
      final r = await runBoundedRound(core: core, budget: const Duration(minutes: 4), clock: tm.clock, sleep: tm.sleep);
      expect(r.why, 'done');
      expect(r.arrived, 4);
      expect(r.words, contains('4 more files'));
      expect(core.looks, 3, reason: 'one look before, then one a second until the round is done');
    });

    test('nobody in reach: told so, not called synced', () async {
      final tm = FakeTime();
      final r = await runBoundedRound(core: RoundCore(live: 0), budget: const Duration(minutes: 4), clock: tm.clock, sleep: tm.sleep);
      expect(r.why, 'alone');
      expect(r.words, 'no linked device in reach');
    });

    test('stops at its time budget, with what is left', () async {
      final tm = FakeTime();
      final core = RoundCore(roundsAfter: null, pending: 7);
      final r = await runBoundedRound(core: core, budget: const Duration(seconds: 30), clock: tm.clock, sleep: tm.sleep);
      expect(r.why, 'time');
      expect(r.left, 7);
      expect(tm.now.difference(DateTime(2026, 11, 14, 12)), const Duration(seconds: 30));
    });

    test('stops when the app asks, at its next look', () async {
      final tm = FakeTime();
      var ask = false;
      final core = RoundCore(roundsAfter: null, onStatus: (n) => ask = n == 3);
      final r = await runBoundedRound(core: core, budget: const Duration(minutes: 4), stopAsked: () => ask, clock: tm.clock, sleep: tm.sleep);
      expect(r.why, 'asked');
      expect(core.looks, 3);
    });

    test('stops on heat or a low battery, looked at every ten seconds and no oftener', () async {
      final tm = FakeTime();
      var looked = 0;
      final r = await runBoundedRound(
        core: RoundCore(roundsAfter: null),
        budget: const Duration(minutes: 4),
        held: () async => ++looked == 2 ? 'the phone is hot' : null,
        clock: tm.clock,
        sleep: tm.sleep,
      );
      expect(r.why, 'held');
      expect(looked, 2);
      expect(tm.now.difference(DateTime(2026, 11, 14, 12)).inSeconds, inInclusiveRange(20, 21));
    });

    test('a pause with files left (no room, no network it may use) ends it with the reason', () async {
      final tm = FakeTime();
      final r = await runBoundedRound(core: RoundCore(pending: 3, paused: 'Paused: low on space'), budget: const Duration(minutes: 4), clock: tm.clock, sleep: tm.sleep);
      expect(r.why, 'paused');
      expect(r.words, 'paused: Paused: low on space');
    });
  });

  group('the job', () {
    Future<String> run(SyncCoreLike core, {SyncOpener? opener, Duration budget = const Duration(minutes: 4), BatteryReader? battery, ConnectionKind kind = ConnectionKind.wifi, bool mobile = false, FakeTime? tm, Duration? openLimit, void Function()? drainLog}) {
      tm ??= FakeTime();
      return syncBackgroundJob(
        support: support.path,
        lock: lock,
        budget: budget,
        openLimit: openLimit ?? const Duration(seconds: 60),
        drainLog: drainLog ?? () {},
        opener: opener ?? (_) async => core,
        battery: battery ?? () async => const BatteryReading(percent: 70, charging: false, thermal: Thermal.nominal),
        connection: () async => kind,
        mobileData: mobile,
        clock: tm.clock,
        sleep: tm.sleep,
      );
    }

    test('opens the engine from the app\'s settings, runs one round, closes it, and lets go of the lock', () async {
      appLeaves();
      Map<String, Object?>? opened;
      final core = RoundCore(roundsAfter: 2, arriving: 2);
      final out = await run(core, opener: (c) async {
        opened = c;
        return core;
      });
      expect(out, contains('synced with 1 of 2 devices, 2 more files here'));
      expect(opened!['dir'], '${support.path}/sync', reason: 'this install\'s folder, wherever the app kept it last time');
      expect(opened!['interval_secs'], 3600, reason: 'one round, not one every 30 seconds');
      expect(opened!['lifetime_secs'], 240 + 90, reason: 'the engine ends itself if the run is cut off');
      expect(opened!['dht'], false);
      expect(opened!['reticulum'], false, reason: 'no multicast runs without the lock, which only the app holds');
      expect(opened!['only'], {'indexes': <String>[]});
      expect(core.calls, contains('set_policy'));
      expect(core.closed, isTrue);
      expect(lock.runs(kSyncWork), isFalse);
      expect(lock.generation, 0);
    });

    test('a background round never makes a new identity: a missing or bad key is left for the app\'s own start to restore', () async {
      appLeaves();
      Map<String, Object?>? opened;
      final core = RoundCore(roundsAfter: 2, arriving: 2);
      await run(core, opener: (c) async {
        opened = c;
        return core;
      });
      expect(opened!['make_identity'], false);
    });

    test('an engine that never opens ends the round at the open limit with a log line, lets go of the lock, and closes it if it opens late', () async {
      appLeaves();
      final hung = Completer<SyncCoreLike>();
      final late = RoundCore();
      final out = await run(RoundCore(), opener: (_) => hung.future, openLimit: const Duration(milliseconds: 150));
      expect(out, 'skipped: the engine did not open in time');
      expect(lock.runs(kSyncWork), isFalse, reason: 'the lock is let go, so the next run (or the app) can start');
      hung.complete(late);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(late.closed, isTrue, reason: 'an engine opened after the round gave up is closed at once');
    });

    test('the engine\'s step lines are taken every second while the open is still running', () async {
      appLeaves();
      var drains = 0;
      final hung = Completer<SyncCoreLike>();
      await run(RoundCore(), opener: (_) => hung.future, openLimit: const Duration(milliseconds: 2300), drainLog: () => drains++);
      expect(drains, greaterThanOrEqualTo(3), reason: 'two timer drains while it hung, one at the end');
    });

    test('opens nothing when the app is open, its own engine runs, Add PDF runs, or another run holds it', () async {
      appLeaves();
      var opens = 0;
      Future<SyncCoreLike> opener(Map<String, Object?> _) async {
        opens++;
        return RoundCore();
      }

      lock.appOpened();
      expect(await run(RoundCore(), opener: opener), 'skipped: Cache is open');
      lock.appClosed();
      lock.engineStarted(kSyncWork);
      expect(await run(RoundCore(), opener: opener), contains("app's own sync"));
      lock.engineStopped(kSyncWork);
      expect(lock.hold(kAddPdfWork), isTrue);
      expect(await run(RoundCore(), opener: opener), contains('Add PDF'));
      lock.release(kAddPdfWork);
      expect(lock.hold(kSyncWork, bump: false), isTrue);
      expect(await run(RoundCore(), opener: opener), contains('another background sync'));
      lock.release(kSyncWork);
      expect(opens, 0);
    });

    test('opens nothing for no setup, no link, an unreadable folder, the battery, heat, or a network it may not use', () async {
      var opens = 0;
      Future<SyncCoreLike> opener(Map<String, Object?> _) async {
        opens++;
        return RoundCore();
      }

      // nothing left by the app
      expect(await run(RoundCore(), opener: opener), contains('not set up'));
      appLeaves(enabled: false);
      expect(await run(RoundCore(), opener: opener), contains('not set up'));
      appLeaves(linked: false);
      expect(await run(RoundCore(), opener: opener), contains('no linked devices'));
      appLeaves(folder: false);
      expect(await run(RoundCore(), opener: opener), contains('cannot be read yet'));
      appLeaves();
      expect(await run(RoundCore(), opener: opener, battery: () async => const BatteryReading(percent: 9, charging: false)), 'held: battery low (9%)');
      expect(await run(RoundCore(), opener: opener, kind: ConnectionKind.none), 'skipped: no network');
      expect(await run(RoundCore(), opener: opener, kind: ConnectionKind.mobile), contains('mobile data'));
      expect(opens, 0);
      // ... and the same with mobile data allowed goes ahead
      expect(await run(RoundCore(), opener: opener, kind: ConnectionKind.mobile, mobile: true), contains('synced'));
      expect(opens, 1);
    });

    test('an engine that cannot open (another holds the folder) is a skipped run, never a failure, and lets go of the lock', () async {
      appLeaves();
      final out = await run(RoundCore(), opener: (_) async => throw StateError('store is locked'));
      expect(out, 'skipped: the engine could not be opened');
      expect(lock.runs(kSyncWork), isFalse);
    });

    test('Add PDF starting during the round stops it, and the engine is closed', () async {
      appLeaves();
      final core = RoundCore(roundsAfter: null, onStatus: (n) {
        if (n == 3) File('${lock.dir.path}/run-pdf-add').writeAsStringSync(DateTime.now().toIso8601String());
      });
      final out = await run(core);
      expect(out, contains('stopped'));
      expect(core.closed, isTrue);
      expect(lock.runs(kSyncWork), isFalse);
    });

    test('the app coming to the front stops it', () async {
      appLeaves();
      final core = RoundCore(roundsAfter: null, onStatus: (n) {
        if (n == 2) lock.appOpened();
      });
      final out = await run(core);
      expect(out, contains('stopped'));
      expect(core.closed, isTrue);
    });

    test('an engine that closes slowly never holds the run past ten seconds', () async {
      appLeaves();
      final core = _SlowClose();
      final w = Stopwatch()..start();
      await run(core);
      expect(core.closeCalled, isTrue);
      expect(lock.runs(kSyncWork), isFalse);
      expect(w.elapsed, lessThan(const Duration(seconds: 12)));
    }, timeout: const Timeout(Duration(seconds: 20)));
  });

  group('the scheduling', () {
    late FakeScheduler sched;

    setUp(() {
      sched = FakeScheduler();
      backgroundScheduler = sched;
    });
    tearDown(() => backgroundScheduler = const WorkmanagerScheduler());

    test('Android: hourly, on an unmetered network unless downloads may use mobile data, not on a low battery', () async {
      await scheduleBackgroundSync(enabled: true, mobileData: false, android: true, ios: false);
      expect(sched.calls.single.$1, 'periodic');
      expect(sched.calls.single.$2, kSyncTask);
      expect(sched.calls.single.$3, const Duration(hours: 1));
      expect(sched.calls.single.$4.networkType, NetworkType.unmetered);
      expect(sched.calls.single.$4.requiresBatteryNotLow, isTrue);
      expect(sched.calls.single.$4.requiresCharging, isNot(true));
      sched.calls.clear();
      await scheduleBackgroundSync(enabled: true, mobileData: true, android: true, ios: false);
      expect(sched.calls.single.$4.networkType, NetworkType.connected);
    });

    test('iPhone: the app-refresh task and a charging processing task; nothing of the Android job', () async {
      await scheduleBackgroundSync(enabled: true, mobileData: false, android: false, ios: true);
      expect([for (final c in sched.calls) (c.$1, c.$2)], [('periodic', kSyncRefreshTask), ('processing', kSyncProcessingTask)]);
      expect(sched.calls.last.$4.requiresCharging, isTrue);
    });

    test('sharing off cancels what was scheduled, per platform; a desktop schedules nothing', () async {
      await scheduleBackgroundSync(enabled: false, mobileData: false, android: true, ios: false);
      expect([for (final c in sched.calls) (c.$1, c.$2)], [('cancel', kSyncTask)]);
      sched.calls.clear();
      await scheduleBackgroundSync(enabled: false, mobileData: false, android: false, ios: true);
      expect([for (final c in sched.calls) c.$2], [kSyncRefreshTask, kSyncProcessingTask]);
      sched.calls.clear();
      await scheduleBackgroundSync(enabled: true, mobileData: false, android: false, ios: false);
      expect(sched.calls, isEmpty);
    });

    test('the dispatcher has an entry for each of the three tasks, and names them in the log', () {
      for (final t in [kSyncTask, kSyncRefreshTask, kSyncProcessingTask]) {
        expect(kBackgroundTaskNames[t], isNotNull);
      }
      expect(kSyncRefreshTask, isNot(kSyncProcessingTask));
    });
  });

  group("the app's side", () {
    late FakeCoreForState core;
    late SharingState sharing;

    setUp(() {
      core = FakeCoreForState();
      sharing = SharingState(
        policy: DataPolicy(settings: AppSettings(), probe: FakeProbe(ConnectionKind.wifi)),
        supportDir: () async => support,
        kinds: const [],
        phone: true,
        opener: (_) async => core,
      );
    });
    tearDown(() => sharing.dispose());

    test('marks its engine while it runs, keeps the settings for a run, and takes the mark away when it stops', () async {
      File('${support.path}/sharing.json').writeAsStringSync(jsonEncode({'enabled': true}));
      await sharing.init();
      expect(sharing.running, isTrue);
      expect(lock.engineRuns(kSyncWork), isTrue);
      final snap = jsonDecode(File('${support.path}/background/sync-config.json').readAsStringSync()) as Map;
      expect(snap['dht'], false);
      expect(snap['dir'], '${support.path}/sync');
      expect(snap.containsKey('only') && snap.containsKey('off') && snap.containsKey('never_fetch'), isTrue);
      sharing.dispose();
      expect(lock.engineRuns(kSyncWork), isFalse);
      sharing = SharingState(policy: DataPolicy(settings: AppSettings(), probe: FakeProbe(ConnectionKind.wifi)), supportDir: () async => support, kinds: const [], opener: (_) async => core);
    });

    test('what is set after the start (what it fetches) reaches the settings kept for a run', () async {
      File('${support.path}/sharing.json').writeAsStringSync(jsonEncode({'enabled': true}));
      final s = SharingState(
        policy: DataPolicy(settings: AppSettings(), probe: FakeProbe(ConnectionKind.wifi)),
        supportDir: () async => support,
        kinds: const [],
        always: [AlwaysShared(id: 'indexes', name: 'Search indexes', dir: () => null)],
        opener: (_) async => core,
      );
      await s.init();
      Map snap() => jsonDecode(File('${support.path}/background/sync-config.json').readAsStringSync()) as Map;
      expect(snap()['only'], {'indexes': <String>[]});
      await s.setOnly('indexes', ['b/*', 'a/*']);
      await s.setNeverFetch('indexes', ['b/bad']);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(snap()['only'], {'indexes': ['a/*', 'b/*']});
      expect(snap()['never_fetch'], {'indexes': ['b/bad']});
      s.dispose();
    });

    test('a background round is asked to stop and given its time before the engine opens', () async {
      File('${support.path}/sharing.json').writeAsStringSync(jsonEncode({'enabled': true}));
      expect(lock.hold(kSyncWork, bump: false), isTrue);
      var asked = false;
      Timer(const Duration(milliseconds: 300), () {
        asked = lock.stopAsked(kSyncWork);
        lock.release(kSyncWork);
      });
      await sharing.init();
      expect(asked, isTrue, reason: 'it was asked, not killed');
      expect(sharing.running, isTrue);
      expect(sharing.error, isNull);
    });
  });

  group('the words on the Sharing page', () {
    test('Android and iPhone get their own sentence, any other platform none', () {
      expect(syncBackgroundNote(android: true, ios: false), contains('syncs about once an hour'));
      expect(syncBackgroundNote(android: false, ios: true), contains('runs only when iOS allows it'));
      expect(syncBackgroundNote(android: false, ios: false), isNull);
    });
  });
}

class _SlowClose implements SyncCoreLike {
  bool closeCalled = false;

  @override
  Future<Map<String, dynamic>> call(String method, [Map<String, Object?> args = const {}]) async =>
      method == 'status' ? {'rounds': 1, 'transfer': null, 'shares': [], 'peers': [{'live': true, 'error': null}]} : {'ok': true};

  @override
  Future<void> close() {
    closeCalled = true;
    return Completer<void>().future;
  }
}

class FakeCoreForState implements SyncCoreLike {
  @override
  Future<Map<String, dynamic>> call(String method, [Map<String, Object?> args = const {}]) async =>
      method == 'status' ? {'id': 'me', 'name': 'Phone', 'network': true, 'peers': [], 'shares': []} : {'ok': true, 'items': []};

  @override
  Future<void> close() async {}
}
