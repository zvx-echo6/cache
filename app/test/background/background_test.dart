// The shared background layer: the dispatcher routes each task to its job and writes one log line per run; the weather task is
// scheduled exactly as before (same name, every 30 minutes, a network connection, update); watch-folder-detect and
// watch-folder-add are scheduled with their presets; the one lock keeps the app and a background run from doing the same work.

import 'dart:io';

import 'package:cache/background/background_dispatcher.dart';
import 'package:cache/background/background_lock.dart';
import 'package:cache/background/background_tasks.dart';
import 'package:cache/library/add_pdf/watch_background.dart';
import 'package:cache/platform/battery.dart';
import 'package:cache/weather/background.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:workmanager/workmanager.dart';

/// Records what would be scheduled.
class FakeBackgroundScheduler implements BackgroundScheduler {
  final List<(String, String, Duration, Constraints, bool)> calls = [];

  @override
  Future<void> periodic(String task, {required Duration every, required Constraints constraints}) async => calls.add(('periodic', task, every, constraints, false));

  @override
  Future<void> once(String task, {required Constraints constraints, Duration delay = Duration.zero, bool after = false}) async =>
      calls.add(('once', task, delay, constraints, after));

  @override
  Future<void> cancel(String task) async => calls.add(('cancel', task, Duration.zero, Constraints(), false));
}

void main() {
  late FakeBackgroundScheduler sched;

  setUp(() {
    sched = FakeBackgroundScheduler();
    backgroundScheduler = sched;
  });

  tearDown(() => backgroundScheduler = const WorkmanagerScheduler());

  group('the dispatcher', () {
    test('routes each task to its own job, and only that one', () async {
      final ran = <String>[];
      final t = BackgroundTasks(
        jobs: {
          kWeatherTask: (_) async {
            ran.add('weather');
            return 'done';
          },
          kWatchDetectTask: (_) async {
            ran.add('detect');
            return '2 new in 1 of 1 folders';
          },
          kWatchAddTask: (_) async {
            ran.add('add');
            return 'added 1';
          },
        },
        battery: () async => const BatteryReading(percent: 64, charging: true, thermal: Thermal.nominal),
      );
      expect(await t.run(kWatchDetectTask, null), isTrue);
      expect(ran, ['detect']);
      expect(t.lastLine, contains('task watch-folder-detect'));
      expect(t.lastLine, contains('outcome 2 new in 1 of 1 folders'));
      expect(t.lastLine, contains('battery 64%'));
      expect(t.lastLine, contains('charging yes'));
      expect(t.lastLine, contains('thermal nominal'));
      expect(t.lastLine, contains('start '));
      expect(t.lastLine, contains('end '));
      await t.run(kWatchAddTask, null);
      await t.run(kWeatherTask, null);
      expect(ran, ['detect', 'add', 'weather']);
      expect(t.lastLine, contains('task weather'));
    });

    test('a job that throws is logged as failed and the run still reports done; an unknown task is said', () async {
      final t = BackgroundTasks(jobs: {kWatchAddTask: (_) async => throw StateError('no core')}, battery: () async => null);
      expect(await t.run(kWatchAddTask, null), isTrue);
      expect(t.lastLine, contains('outcome failed: Bad state: no core'));
      expect(t.lastLine, contains('battery unknown'));
      expect(await t.run('com.happylittle.cache.sync', null), isTrue);
      expect(t.lastLine, contains('outcome no such task'));
    });

    test('the app dispatcher has the weather, detect and add jobs, and no sync job yet', () {
      expect(backgroundJobs().keys.toSet(), {kWeatherTask, kWatchDetectTask, kWatchAddTask});
      expect(kWeatherTask, 'com.happylittle.cache.live-update', reason: 'the name existing phones have it scheduled under, and the iPhone identifier');
      expect(kBackgroundTask, kWeatherTask);
    });
  });

  group('weather is scheduled as it always was', () {
    test('every 30 minutes, with a network connection, updating what is scheduled', () async {
      expect(await scheduleBackgroundUpdates(anythingOn: true, mobile: true), isTrue);
      final c = sched.calls.single;
      expect(c.$1, 'periodic');
      expect(c.$2, 'com.happylittle.cache.live-update');
      expect(c.$3, const Duration(minutes: 30));
      expect(c.$4.networkType, NetworkType.connected);
      expect(c.$4.requiresCharging, isNull);
      expect(c.$4.requiresBatteryNotLow, isNull);
      expect(c.$4.requiresDeviceIdle, isNull);
    });

    test('nothing switched on: it is cancelled; off a phone nothing is scheduled', () async {
      expect(await scheduleBackgroundUpdates(anythingOn: false, mobile: true), isFalse);
      expect(sched.calls.single.$1, 'cancel');
      expect(sched.calls.single.$2, kWeatherTask);
      sched.calls.clear();
      expect(await scheduleBackgroundUpdates(anythingOn: true, mobile: false), isFalse);
      expect(sched.calls, isEmpty);
    });
  });

  group('the watched folders tasks', () {
    test('detect: every 6 hours, not on a low battery, while folders are watched; cancelled with the add task when none are', () async {
      await scheduleWatchDetect(anyFolders: true, android: true);
      final c = sched.calls.single;
      expect((c.$1, c.$2, c.$3), ('periodic', kWatchDetectTask, const Duration(hours: 6)));
      expect(c.$4.requiresBatteryNotLow, isTrue);
      expect(c.$4.requiresCharging, isNot(isTrue));
      expect(c.$4.networkType, NetworkType.notRequired);
      sched.calls.clear();
      await scheduleWatchDetect(anyFolders: false, android: true);
      expect([for (final x in sched.calls) (x.$1, x.$2)], [('cancel', kWatchDetectTask), ('cancel', kWatchAddTask)]);
      sched.calls.clear();
      await scheduleWatchDetect(anyFolders: true, android: false);
      expect(sched.calls, isEmpty, reason: 'iOS: no background folder work');
    });

    test('add: once, only while charging and not on a low battery; a slice queues the next after itself', () async {
      await scheduleWatchAdd(android: true);
      var c = sched.calls.single;
      expect((c.$1, c.$2, c.$5), ('once', kWatchAddTask, false));
      expect(c.$4.requiresCharging, isTrue);
      expect(c.$4.requiresBatteryNotLow, isTrue);
      expect(c.$4.networkType, NetworkType.notRequired);
      sched.calls.clear();
      await scheduleWatchAdd(next: true, android: true);
      c = sched.calls.single;
      expect(c.$5, isTrue);
      expect(c.$4.requiresCharging, isTrue);
    });
  });

  group('the one lock', () {
    late Directory tmp;
    late DateTime now;
    late BackgroundLock lock;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('bg-lock');
      now = DateTime(2026, 11, 9, 20);
      lock = BackgroundLock(Directory('${tmp.path}/background'), clock: () => now);
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    test('a background run never holds the work while the app is open, nor while another run holds it', () {
      lock.appOpened();
      expect(lock.hold(kAddPdfWork), isFalse);
      lock.appClosed();
      expect(lock.hold(kAddPdfWork), isTrue);
      expect(lock.runs(kAddPdfWork), isTrue);
      expect(lock.generation, 1);
      final other = BackgroundLock(lock.dir, clock: () => now);
      expect(other.hold(kAddPdfWork), isFalse, reason: 'no double work');
      lock.release(kAddPdfWork);
      expect(other.hold(kAddPdfWork), isTrue);
      expect(other.generation, 2);
    });

    test('a run that was killed holds nothing once its time is stale; an app that was killed is no longer open', () {
      expect(lock.hold(kAddPdfWork), isTrue);
      now = now.add(const Duration(minutes: 3));
      expect(lock.runs(kAddPdfWork), isFalse);
      lock.appOpened();
      now = now.add(const Duration(minutes: 3));
      expect(lock.appOpen, isFalse);
      expect(lock.hold(kAddPdfWork), isTrue);
    });

    test('the app takes over: the run is asked to stop, and the app goes on once it let go', () async {
      final real = BackgroundLock(Directory('${tmp.path}/real'));
      expect(real.hold(kAddPdfWork), isTrue);
      expect(real.stopAsked(kAddPdfWork), isFalse);
      final took = real.takeOver(kAddPdfWork, wait: const Duration(seconds: 5), look: const Duration(milliseconds: 20));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(real.stopAsked(kAddPdfWork), isTrue);
      real.release(kAddPdfWork);
      expect(await took, isTrue);
      // no run: at once
      expect(await real.takeOver(kAddPdfWork, wait: Duration.zero), isTrue);
    });

    test('the app open is a stop for a running background run', () {
      expect(lock.hold(kAddPdfWork), isTrue);
      lock.appOpened();
      expect(lock.stopAsked(kAddPdfWork), isTrue);
    });
  });
}
