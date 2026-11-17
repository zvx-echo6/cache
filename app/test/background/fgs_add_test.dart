// The foreground service for adding PDFs in the background (build 52): when leaving starts it, the battery rule (it runs on the
// battery above the low-battery threshold, not only while charging), what the app says on the next open when a background add
// failed or ended, and the one `run-pdf-add` lock it shares with the WorkManager charging run (they never both run).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cache/background/background_lock.dart';
import 'package:cache/background/fgs_add.dart';
import 'package:cache/library/add_pdf/add_pdf_slice.dart';
import 'package:cache/library/add_pdf/add_pdf_state.dart';
import 'package:cache/library/add_pdf/watch_background.dart';
import 'package:cache/platform/battery.dart';
import 'package:cache/search/index_throttle.dart';
import 'package:flutter/services.dart' show MethodCall;
import 'package:flutter_test/flutter_test.dart';

import '../add_pdf/add_pdf_fixtures.dart';

const _charging = BatteryReading(percent: 80, charging: true, thermal: Thermal.nominal);
const _unplugged60 = BatteryReading(percent: 60, charging: false);
const _unplugged40 = BatteryReading(percent: 40, charging: false);
const _low = BatteryReading(percent: 15, charging: false);
const _quick = Duration(milliseconds: 20);

class _Platform implements FgsPlatform {
  final List<bool> armed = [];
  bool allowed = false;
  bool grants = true;
  int requests = 0;

  @override
  Future<void> arm(bool on) async => armed.add(on);

  @override
  Future<bool> notificationsAllowed() async => allowed;

  @override
  Future<bool> requestNotifications() async {
    requests++;
    return grants;
  }
}

void main() {
  group('the start-on-leave decision', () {
    final one = [sampleJob('a')];

    test('starts when the person leaves with an add pending: charging, or on the battery above the low threshold', () {
      for (final b in [_charging, _unplugged60, null]) {
        expect(fgsStartOnLeave(android: true, jobs: one, battery: b), FgsStart.start, reason: '$b');
      }
    });

    test('never off Android (iOS and desktops have no foreground service)', () {
      expect(fgsStartOnLeave(android: false, jobs: one, battery: _charging), FgsStart.notAndroid);
    });

    test('nothing pending, or everything paused by the person: nothing to start', () {
      expect(fgsStartOnLeave(android: true, jobs: const [], battery: _charging), FgsStart.nothingToAdd);
      expect(fgsStartOnLeave(android: true, jobs: [sampleJob('a', paused: true)], battery: _charging), FgsStart.nothingToAdd);
      expect(fgsStartOnLeave(android: true, jobs: [sampleJob('a', status: AddPdfStatus.done), sampleJob('b', status: AddPdfStatus.failed)], battery: _charging), FgsStart.nothingToAdd);
    });

    test('a long PDF waiting for charging does not start it (nothing runs, so there is nothing to show); Start now does', () {
      expect(fgsStartOnLeave(android: true, jobs: one, battery: _unplugged40), FgsStart.waitsForCharging);
      expect(fgsStartOnLeave(android: true, jobs: [sampleJob('a')..startNow = true], battery: _unplugged40), FgsStart.start);
    });

    test('a low battery holds it; Resume anyway does not', () {
      expect(fgsStartOnLeave(android: true, jobs: one, battery: _low), FgsStart.batteryLow);
      expect(fgsStartOnLeave(android: true, jobs: [sampleJob('a')..anyway = true], battery: _low), FgsStart.start);
    });

    test('one runnable PDF among others that wait is enough; it is not started twice', () {
      expect(fgsStartOnLeave(android: true, jobs: [sampleJob('a', paused: true), sampleJob('b')], battery: _unplugged60), FgsStart.start);
      expect(fgsStartOnLeave(android: true, jobs: one, battery: _charging, running: true), FgsStart.alreadyRunning);
    });
  });

  group('the coordinator tells Android, and asks about notifications once', () {
    late Directory tmp;
    late _Platform platform;
    late List<AddPdfJob> jobs;
    var asked = 0;
    var refused = 0;
    var answer = true;

    FgsAddCoordinator make({int? sdk = 34, BatteryReading? battery = _charging}) => FgsAddCoordinator(
      platform: platform,
      jobs: () => jobs,
      battery: () async => battery,
      askedFile: () => File('${tmp.path}/asked'),
      sdk: sdk,
      ask: () async {
        asked++;
        return answer;
      },
      onRefused: () => refused++,
    );

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('fgs-coord');
      platform = _Platform();
      jobs = [sampleJob('a')];
      asked = 0;
      refused = 0;
      answer = true;
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    test('Android is told only when the answer changes', () async {
      final c = make();
      await c.update();
      await c.update();
      expect(platform.armed, [true]);
      jobs = [];
      await c.update();
      expect(platform.armed, [true, false]);
    });

    test('the first background add asks once, then Android answers; Allow granted shows no message', () async {
      final c = make();
      await c.update();
      await c.update();
      expect(asked, 1);
      expect(platform.requests, 1);
      expect(refused, 0);
      expect(File('${tmp.path}/asked').existsSync(), isTrue);
    });

    test('Not now: Android is not asked, and the person is told what it means; never asked again', () async {
      answer = false;
      final c = make();
      await c.update();
      expect(platform.requests, 0);
      expect(refused, 1);
      await make().update();
      expect(asked, 1);
    });

    test('Android refuses: the person is told the service still runs but shows nothing', () async {
      platform.grants = false;
      await make().update();
      expect(refused, 1);
      expect(FgsWords.refused, startsWith('Cache still adds PDFs, but shows nothing.'));
    });

    test('already allowed (weather alerts asked): nothing is asked; before Android 13 nothing is asked', () async {
      platform.allowed = true;
      await make().update();
      expect(asked, 0);
      tmp.deleteSync(recursive: true);
      tmp.createSync();
      platform.allowed = false;
      await make(sdk: 31).update();
      expect(asked, 0);
    });

    test('with nothing pending nothing is asked (the question comes with the first background add)', () async {
      jobs = [];
      await make().update();
      expect(asked, 0);
    });
  });

  group('the battery rule', () {
    Future<IndexThrottle> throttle(BatteryReading b) async {
      final t = IndexThrottle(read: () async => b, mobile: true);
      addTearDown(t.dispose);
      await t.read(fresh: true);
      return t;
    }

    test('the charging run holds when unplugged; the service does not', () async {
      final t = await throttle(_unplugged60);
      expect(addPdfHeld(t), 'unplugged');
      expect(addPdfHeld(t, unplugged: true), isNull);
    });

    test('both hold under the low-battery threshold, and for heat', () async {
      final low = await throttle(_low);
      expect(addPdfHeld(low), 'unplugged');
      expect(addPdfHeld(low, unplugged: true), 'battery');
      final hot = await throttle(const BatteryReading(percent: 80, charging: true, thermal: Thermal.severe));
      expect(addPdfHeld(hot, unplugged: true), 'heat');
    });
  });

  group('the service add job over the one lock', () {
    late Directory tmp;
    late String support;
    late BackgroundLock lock;
    late List<(bool, Duration)> queued;

    Future<void> queue({bool next = false, Duration delay = Duration.zero}) async => queued.add((next, delay));

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('fgs-job');
      support = '${tmp.path}/support';
      lock = BackgroundLock(Directory(backgroundDir(support)));
      queued = [];
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    Future<(AddPdfState, List<AddPdfJob>)> pending(FakeIngestCalls calls, {int n = 1}) async {
      final s = testAddPdfState(Directory('$support/ingest'), calls: calls);
      addTearDown(s.dispose);
      final made = <AddPdfJob>[];
      for (var i = 0; i < n; i++) {
        final f = File('${tmp.path}/p$i.pdf')..writeAsStringSync('pdf$i');
        made.add(await s.add(pdfPath: f.path, fileName: 'p$i.pdf', bytes: 4, title: 'Manual $i', target: const AddPdfTarget(title: 'My books', path: '/tmp/my-books', isDefault: true)));
      }
      return (s, made);
    }

    final done = FakeIngestCalls({'step': steps([progress('done', result: {'copy': 'c' * 64})])});

    test('it adds on the battery (the charging run would be held), and lets go of the lock', () async {
      final (s, jobs) = await pending(done);
      final c = FgsAddControl();
      final out = await fgsAddJob(support: support, control: c, lock: lock, battery: () async => _unplugged60, state: s, queue: queue, waitForBack: Duration.zero, lookEvery: _quick);
      expect(out.words, 'added 1');
      expect(jobs.single.status, AddPdfStatus.done);
      expect(lock.runs(kAddPdfWork), isFalse);
      expect(queued, isEmpty);
      // the charging run is held for the same reading
      expect(await watchAddJob(support: support, lock: lock, battery: () async => _unplugged60, state: s, queue: queue), 'held: unplugged');
    });

    test('a low battery holds it, and nothing is started', () async {
      final (s, jobs) = await pending(done);
      final c = FgsAddControl();
      final out = await fgsAddJob(support: support, control: c, lock: lock, battery: () async => _low, state: s, queue: queue, waitForBack: Duration.zero, lookEvery: _quick);
      expect(out.words, 'held: battery');
      expect(c.result?.why, 'battery');
      expect(jobs.single.status, AddPdfStatus.active);
      expect(lock.runs(kAddPdfWork), isFalse);
    });

    test('the lock is shared: with the charging run adding, the service does not run (and the other way round)', () async {
      final (s, jobs) = await pending(done);
      // the charging run holds it
      expect(lock.hold(kAddPdfWork), isTrue);
      final out = await fgsAddJob(support: support, control: FgsAddControl(), lock: lock, battery: () async => _charging, state: s, queue: queue, waitForBack: const Duration(seconds: 5), takeOverWait: const Duration(milliseconds: 150), look: const Duration(milliseconds: 10));
      expect(out.words, 'skipped: another run is adding');
      expect(jobs.single.status, AddPdfStatus.active);
      lock.release(kAddPdfWork);
      // the service holds it, so the charging run does not run
      final slow = FakeIngestCalls({'step': (_) async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return progress('reading', pages: 100, pagesDone: 1);
      }});
      final (s2, _) = await pending(slow);
      final c = FgsAddControl();
      final running = fgsAddJob(support: support, control: c, lock: lock, battery: () async => _charging, state: s2, queue: queue, waitForBack: Duration.zero, lookEvery: _quick, progressEvery: _quick);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(lock.runs(kAddPdfWork), isTrue);
      expect(await watchAddJob(support: support, lock: lock, battery: () async => _charging, state: s2, queue: queue), 'skipped: another run is adding');
      c.stop('person');
      await running;
      expect(lock.runs(kAddPdfWork), isFalse);
    });

    test('it waits for Cache to finish going to the back, then runs; if Cache stays in front it gives up', () async {
      final (s, jobs) = await pending(done);
      lock.appOpened();
      Timer(const Duration(milliseconds: 120), lock.appClosed);
      final out = await fgsAddJob(support: support, control: FgsAddControl(), lock: lock, battery: () async => _charging, state: s, queue: queue, waitForBack: const Duration(seconds: 5), look: const Duration(milliseconds: 10));
      expect(out.words, 'added 1');
      expect(jobs.single.status, AddPdfStatus.done);

      final (s2, jobs2) = await pending(done);
      lock.appOpened();
      final gave = await fgsAddJob(support: support, control: FgsAddControl(), lock: lock, battery: () async => _charging, state: s2, queue: queue, waitForBack: const Duration(milliseconds: 100), look: const Duration(milliseconds: 10));
      expect(gave.words, 'skipped: Cache is open');
      expect(jobs2.single.status, AddPdfStatus.active);
    });

    test('Cache coming to the front stops it, keeping what is done; nothing is queued (Cache carries on)', () async {
      final slow = FakeIngestCalls({'step': (_) async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return progress('reading', pages: 100, pagesDone: 1);
      }});
      final (s, jobs) = await pending(slow);
      final running = fgsAddJob(support: support, control: FgsAddControl(), lock: lock, battery: () async => _charging, state: s, queue: queue, waitForBack: Duration.zero, lookEvery: _quick);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      final took = lock.takeOver(kAddPdfWork, wait: const Duration(seconds: 5), look: const Duration(milliseconds: 20));
      await running;
      expect(await took, isTrue);
      expect(jobs.single.status, AddPdfStatus.active);
      expect(queued, isEmpty);
    });

    test('Pause: stops after its step, marks the PDF paused by the person, and the charging run is not queued', () async {
      final slow = FakeIngestCalls({'step': (_) async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return progress('reading', pages: 100, pagesDone: 1);
      }});
      final (s, jobs) = await pending(slow);
      final c = FgsAddControl();
      final running = fgsAddJob(support: support, control: c, lock: lock, battery: () async => _charging, state: s, queue: queue, waitForBack: Duration.zero, lookEvery: _quick);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      c.stop('person');
      await running;
      expect(jobs.single.pausedByPerson, isTrue);
      expect(c.result?.why, 'person');
      expect(queued, isEmpty);
    });

    test("the notification's Resume resumes only what its Pause paused: a PDF paused in the app stays paused", () async {
      final slow = FakeIngestCalls({'step': (_) async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return progress('reading', pages: 100, pagesDone: 1);
      }});
      final (s, jobs) = await pending(slow, n: 2);
      final own = jobs[0]; // the person's own paused book
      final other = jobs[1];
      await s.pause(own);
      final c = FgsAddControl();
      final running = fgsAddJob(support: support, control: c, lock: lock, battery: () async => _charging, state: s, queue: queue, waitForBack: Duration.zero, lookEvery: _quick);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      c.stop('person'); // the notification's Pause
      await running;
      expect(other.pausedByPerson, isTrue);
      expect(own.pausedByPerson, isTrue);

      // the notification's Resume
      final c2 = FgsAddControl();
      final again = fgsAddJob(support: support, control: c2, lock: lock, battery: () async => _charging, state: s, queue: queue, waitForBack: Duration.zero, lookEvery: _quick, resume: true);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      c2.stop('timeout');
      final out = await again;
      expect(own.pausedByPerson, isTrue, reason: 'paused in the app: the notification does not resume it');
      expect(own.status, AddPdfStatus.active);
      expect(other.pausedByPerson, isFalse, reason: 'the one the notification paused is resumed');
      expect(out.words, isNot('nothing to add'));
    });

    test("the app's own Pause always wins: notification Pause, Resume, app Pause, notification Pause and Resume: it stays paused", () async {
      final slow = FakeIngestCalls({'step': (_) async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return progress('reading', pages: 100, pagesDone: 1);
      }});
      final s = AddPdfState(
        calls: slow,
        dir: () async => Directory('$support/ingest'),
        engines: () async => {'pdfium_version': 'chromium/7811'},
        permit: (_) async {},
        busyWait: const Duration(milliseconds: 1),
        onPauseDecided: (j) => forgetFgsPausedId(backgroundDir(support), j.id),
      );
      addTearDown(s.dispose);
      final f = File('${tmp.path}/p.pdf')..writeAsStringSync('pdf');
      final job = await s.add(pdfPath: f.path, fileName: 'p.pdf', bytes: 3, title: 'Manual', target: const AddPdfTarget(title: 'My books', path: '/tmp/my-books', isDefault: true));

      Future<void> run({bool resume = false}) async {
        final c = FgsAddControl();
        final r = fgsAddJob(support: support, control: c, lock: lock, battery: () async => _charging, state: s, queue: queue, waitForBack: Duration.zero, lookEvery: _quick, resume: resume);
        await Future<void>.delayed(const Duration(milliseconds: 150));
        c.stop(resume ? 'timeout' : 'person');
        await r;
      }

      await run(); // the notification's Pause
      expect(job.pausedByPerson, isTrue);
      await run(resume: true); // the notification's Resume
      expect(job.pausedByPerson, isFalse);
      await s.pause(job); // the person's own Pause, in the app
      expect(job.pausedByPerson, isTrue);
      await run(); // nothing runs: nothing for the notification to pause
      final out = await fgsAddJob(support: support, control: FgsAddControl(), lock: lock, battery: () async => _charging, state: s, queue: queue, waitForBack: Duration.zero, lookEvery: _quick, resume: true);
      expect(job.pausedByPerson, isTrue);
      expect(out.words, 'nothing to add');
    });

    test("a Pause the notification made and the person then took over in the app is not lifted by the notification's Resume", () async {
      final slow = FakeIngestCalls({'step': (_) async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return progress('reading', pages: 100, pagesDone: 1);
      }});
      final s = AddPdfState(
        calls: slow,
        dir: () async => Directory('$support/ingest'),
        engines: () async => {'pdfium_version': 'chromium/7811'},
        permit: (_) async {},
        busyWait: const Duration(milliseconds: 1),
        onPauseDecided: (j) => forgetFgsPausedId(backgroundDir(support), j.id),
      );
      addTearDown(s.dispose);
      final f = File('${tmp.path}/q.pdf')..writeAsStringSync('pdf');
      final job = await s.add(pdfPath: f.path, fileName: 'q.pdf', bytes: 3, title: 'Manual', target: const AddPdfTarget(title: 'My books', path: '/tmp/my-books', isDefault: true));
      final c = FgsAddControl();
      final r = fgsAddJob(support: support, control: c, lock: lock, battery: () async => _charging, state: s, queue: queue, waitForBack: Duration.zero, lookEvery: _quick);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      c.stop('person'); // the notification's Pause
      await r;
      await s.resume(job); // the person resumes in the app...
      await s.pause(job); // ...and pauses it again
      final out = await fgsAddJob(support: support, control: FgsAddControl(), lock: lock, battery: () async => _charging, state: s, queue: queue, waitForBack: Duration.zero, lookEvery: _quick, resume: true);
      expect(job.pausedByPerson, isTrue);
      expect(out.words, 'nothing to add');
    });

    test("Resume with nothing paused by the notification resumes nothing", () async {
      final (s, jobs) = await pending(done);
      await s.pause(jobs.single);
      final out = await fgsAddJob(support: support, control: FgsAddControl(), lock: lock, battery: () async => _charging, state: s, queue: queue, waitForBack: Duration.zero, lookEvery: _quick, resume: true);
      expect(jobs.single.pausedByPerson, isTrue);
      expect(out.words, 'nothing to add');
    });

    test("Android's time limit: it stops, the result says so, and the charging run is queued to pick up", () async {
      final slow = FakeIngestCalls({'step': (_) async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return progress('reading', pages: 100, pagesDone: 1);
      }});
      final (s, jobs) = await pending(slow);
      final c = FgsAddControl();
      final running = fgsAddJob(support: support, control: c, lock: lock, battery: () async => _charging, state: s, queue: queue, waitForBack: Duration.zero, lookEvery: _quick);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      c.stop('timeout');
      await running;
      expect(jobs.single.status, AddPdfStatus.active);
      expect(jobs.single.pausedByPerson, isFalse, reason: 'it carries on, not paused by the person');
      expect(c.result?.why, 'timeout');
      expect(queued.single, (false, kWatchAddRetry));
      expect(lock.runs(kAddPdfWork), isFalse);
    });

    test('progress: "2 of 5 PDFs", the current file, one share of the bar, and the ones waiting', () {
      final jobs = [for (var i = 4; i >= 0; i--) sampleJob('j$i', title: ['Radio field manual', 'Garden notes', 'Water', 'Solar', 'Maps'][i])];
      jobs[4].status = AddPdfStatus.done; // j0 (oldest) done
      jobs[3].status = AddPdfStatus.done; // j1 done
      jobs[2].pagesDone = 155; // j2 current, half way
      final p = FgsProgress.of({for (final j in jobs) j.id}, jobs, isDefault: (path) => path == '/tmp/my-books')!;
      expect((p.done, p.total, p.current), (2, 5, 'Water'));
      expect(p.library, 'Bookshelves');
      expect(p.more, 'Solar and 1 more waiting');
      expect(p.left, endsWith(' left'));
      expect(p.bar, closeTo((2 + p.fraction) / 5, 1e-9));
      // no estimate yet: indeterminate
      final fresh = [sampleJob('x')];
      expect(FgsProgress.of({'x'}, fresh, isDefault: (_) => false)!.bar, isNull);
      // a named library keeps its name
      expect(FgsProgress.of({'y'}, [sampleJob('y', libraryTitle: 'Field', libraryPath: '/tmp/field')], isDefault: (path) => path == '/tmp/my-books')!.library, 'Field');
    });
  });

  group('the default library is found by its identity, not its title', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('fgs-lib'));
    tearDown(() => tmp.deleteSync(recursive: true));

    Directory lib(String name, Map<String, dynamic> settings) {
      final d = Directory('${tmp.path}/$name')..createSync();
      File('${d.path}/cache-library.json').writeAsStringSync(jsonEncode(settings));
      return d;
    }

    test('a renamed default library is still Bookshelves; a library the person made keeps its name', () {
      final renamed = lib('a', {'title': 'Our shelf', 'own': true, 'own_default': true});
      final other = lib('b', {'title': 'My books', 'own': true});
      final job = sampleJob('a', libraryTitle: 'Our shelf', libraryPath: renamed.path);
      expect(fgsLibraryWords(job), 'Bookshelves');
      // the old title is not the test: a library called "My books" that is not the default keeps its name
      expect(fgsLibraryWords(sampleJob('b', libraryTitle: 'My books', libraryPath: other.path)), 'My books');
      expect(FgsProgress.of({'a'}, [job])!.library, 'Bookshelves');
    });

    test('two libraries that both say own_default (an old device made My books again): the same one is Bookshelves everywhere', () {
      final second = lib('my-books-2', {'library_id': 'my-books-b', 'own': true, 'own_default': true});
      final first = lib('my-books', {'library_id': 'my-books-z', 'own': true, 'own_default': true});
      expect(libraryIsDefaultOnDisk(first.path), isTrue, reason: 'the folder named exactly my-books');
      expect(libraryIsDefaultOnDisk(second.path), isFalse);
    });

    test('no settings file, or one that cannot be read: the title', () {
      expect(libraryIsDefaultOnDisk('${tmp.path}/none'), isFalse);
      final bad = Directory('${tmp.path}/bad')..createSync();
      File('${bad.path}/cache-library.json').writeAsStringSync('not json');
      expect(libraryIsDefaultOnDisk(bad.path), isFalse);
    });
  });

  group('the service takes the add over from the app and from a charging run (Pixel, 2026-11-14: it used to skip and stall)', () {
    late Directory tmp;
    late String support;
    late BackgroundLock lock;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('fgs-take');
      support = '${tmp.path}/support';
      lock = BackgroundLock(Directory(backgroundDir(support)));
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    /// A WorkManager charging run that holds the lock and, as the real one does at its next look, stops when asked.
    Timer chargingRunHolding({Duration lookEvery = const Duration(milliseconds: 20)}) {
      expect(lock.hold(kAddPdfWork), isTrue);
      return Timer.periodic(lookEvery, (t) {
        if (lock.stopAsked(kAddPdfWork)) {
          t.cancel();
          lock.release(kAddPdfWork);
        }
      });
    }

    Future<AddPdfState> pendingOne(FakeIngestCalls calls) async {
      final s = testAddPdfState(Directory('$support/ingest'), calls: calls);
      addTearDown(s.dispose);
      final f = File('${tmp.path}/p.pdf')..writeAsStringSync('pdf');
      await s.add(pdfPath: f.path, fileName: 'p.pdf', bytes: 4, title: 'Manual', target: const AddPdfTarget(title: 'My books', path: '/tmp/my-books'));
      return s;
    }

    FakeIngestCalls stepping() => FakeIngestCalls({'step': steps([
      for (var i = 1; i <= 4; i++) progress('reading', pages: 5, pagesDone: i),
      progress('done', result: {'copy': 'c' * 64}),
    ])});

    test('a charging run holds the lock: the service asks it to stop, waits, takes over, and the add carries on', () async {
      final s = await pendingOne(stepping());
      final run = chargingRunHolding();
      addTearDown(run.cancel);
      final sent = <FgsProgress>[];
      final out = await fgsAddJob(
        support: support,
        control: FgsAddControl(onProgress: sent.add),
        lock: lock,
        battery: () async => _charging,
        state: s,
        queue: ({bool next = false, Duration delay = Duration.zero}) async {},
        waitForBack: Duration.zero,
        takeOverWait: const Duration(seconds: 5),
        look: const Duration(milliseconds: 10),
        lookEvery: _quick,
        progressEvery: const Duration(milliseconds: 5),
      );
      expect(out.words, 'added 1');
      expect(s.jobs.single.status, AddPdfStatus.done);
      expect(lock.runs(kAddPdfWork), isFalse);
      expect(sent, isNotEmpty);
    });

    test('progress continues under the service after the hand-off: the bar only goes forward, to the end', () async {
      final inner = stepping();
      final slow = FakeIngestCalls({'step': (a) async {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        return inner.on['step']!(a);
      }});
      final s = await pendingOne(slow);
      final sent = <FgsProgress>[];
      // Cache is still in front as the service starts; the hand-off lets go a moment later and a charging run grabs the lock first
      lock.appOpened();
      Timer(const Duration(milliseconds: 60), () {
        lock.appClosed();
        chargingRunHolding();
      });
      final out = await fgsAddJob(
        support: support,
        control: FgsAddControl(onProgress: sent.add),
        lock: lock,
        battery: () async => _charging,
        state: s,
        queue: ({bool next = false, Duration delay = Duration.zero}) async {},
        waitForBack: const Duration(seconds: 5),
        takeOverWait: const Duration(seconds: 5),
        look: const Duration(milliseconds: 10),
        lookEvery: _quick,
        progressEvery: const Duration(milliseconds: 5),
      );
      expect(out.words, 'added 1');
      final bars = [for (final p in sent) if (p.bar != null) p.bar!];
      expect(bars.length, greaterThan(2), reason: 'progress was reported while it ran');
      for (var i = 1; i < bars.length; i++) {
        expect(bars[i], greaterThanOrEqualTo(bars[i - 1]));
      }
      expect(sent.last.done, 1);
    });

    test('the last progress said is the end state, however slowly the timer runs (no tick between the last step and the end)', () async {
      final s = await pendingOne(stepping());
      final sent = <FgsProgress>[];
      final out = await fgsAddJob(
        support: support,
        control: FgsAddControl(onProgress: sent.add),
        lock: lock,
        battery: () async => _charging,
        state: s,
        queue: ({bool next = false, Duration delay = Duration.zero}) async {},
        waitForBack: Duration.zero,
        takeOverWait: const Duration(seconds: 5),
        look: const Duration(milliseconds: 10),
        lookEvery: _quick,
        // no tick ever comes: only the first look and the last one are said
        progressEvery: const Duration(hours: 1),
      );
      expect(out.words, 'added 1');
      expect(sent.last.done, 1, reason: 'the end state is said once, at the end, not left to a timer');
    });

    test('a charging run that never lets go: the service gives up after its bounded wait, and says so', () async {
      final s = await pendingOne(stepping());
      expect(lock.hold(kAddPdfWork), isTrue);
      final out = await fgsAddJob(support: support, control: FgsAddControl(), lock: lock, battery: () async => _charging, state: s, waitForBack: Duration.zero, takeOverWait: const Duration(milliseconds: 100), look: const Duration(milliseconds: 10), lookEvery: _quick);
      expect(out.words, 'skipped: another run is adding');
      expect(s.jobs.single.status, AddPdfStatus.active);
    });

    test('while the service starts, the hand-off does not queue the unprotected charging run at once', () async {
      final q = <(bool, Duration)>[];
      Future<void> queue({bool next = false, Duration delay = Duration.zero}) async => q.add((next, delay));
      await queueAddAfterHandOff(serviceStarting: true, queue: queue);
      expect(q.single.$2, kFgsHandOffRetry);
      expect(kFgsHandOffRetry, greaterThanOrEqualTo(const Duration(minutes: 5)));
      q.clear();
      await queueAddAfterHandOff(serviceStarting: false, queue: queue);
      expect(q.single, (false, Duration.zero));
    });

    test('Android says the person left (Recents, a Home the app did not see): the app hands off', () async {
      var left = 0;
      final c = FgsAddCoordinator(platform: _Platform(), jobs: () => const [], battery: () async => null, askedFile: () => File('${tmp.path}/asked'), onLeft: () => left++);
      expect(await c.handleCall(const MethodCall('left')), isNull);
      expect(left, 1);
      expect(await c.handleCall(const MethodCall('something else')), isNull);
      expect(left, 1);
    });
  });

  group('the in-app notice on the next open', () {
    late Directory tmp;
    late String bg;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('fgs-notice');
      bg = '${tmp.path}/background';
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    FgsAddResult result({String why = 'done', int total = 5, int added = 5, List<String> failed = const [], List<String> left = const [], int? battery, bool warm = false}) =>
        FgsAddResult(at: DateTime(2026, 11, 13, 20), why: why, total: total, added: added, failedIds: failed, leftIds: left, batteryPercent: battery, warm: warm);

    test('a result is kept on disk and read back', () async {
      final r = result(why: 'battery', battery: 12, left: ['a', 'b']);
      await writeFgsResult(bg, r);
      final back = readFgsResult(bg)!;
      expect(back.why, 'battery');
      expect(back.batteryPercent, 12);
      expect(back.leftIds, ['a', 'b']);
      clearFgsResult(bg);
      expect(readFgsResult(bg), isNull);
    });

    test('one PDF failed: the Add PDF page\'s own words, with the file name', () {
      final j = sampleJob('a', title: 'Radio field manual', status: AddPdfStatus.failed, error: 'embed');
      final n = FgsAddNotice.of(result(total: 1, added: 0, failed: ['a']), [j])!;
      expect(n.failed, isTrue);
      expect(n.title, addPdfErrorWords(j).title);
      expect(n.text, 'Radio field manual · ${addPdfErrorWords(j).body}');
    });

    test('several failed: counted; with some added, the default library is said as Bookshelves', () {
      final jobs = [sampleJob('a', status: AddPdfStatus.failed), sampleJob('b', status: AddPdfStatus.failed)];
      final n = FgsAddNotice.of(result(total: 2, added: 0, failed: ['a', 'b']), jobs)!;
      expect(n.title, '2 PDFs could not be added');
      final several = FgsAddNotice.of(FgsAddResult(at: DateTime(2026), why: 'done', total: 5, added: 3, failedIds: const ['a', 'z'], leftIds: const []), [sampleJob('a', status: AddPdfStatus.failed), sampleJob('z', status: AddPdfStatus.failed)])!;
      expect(several.title, 'Added 3 of 5 PDFs to Bookshelves');
      expect(several.text, '2 could not be added');
    });

    test('it ended before it was done: paused, with the reason in the existing words', () {
      final left = [sampleJob('a'), sampleJob('b'), sampleJob('c')];
      FgsAddNotice? n(String why, {int? battery, bool warm = false}) => FgsAddNotice.of(result(why: why, left: ['a', 'b', 'c'], battery: battery, warm: warm), left);
      expect(n('battery', battery: 12)!.title, 'Paused · 2 of 5 PDFs');
      expect(n('battery', battery: 12)!.text, 'Battery low (12%) · plug in to continue');
      expect(n('person')!.text, 'Paused by you');
      expect(n('heat', warm: true)!.text, 'Device is warm');
      expect(n('heat')!.text, 'Keeping the device cool');
      expect(n('timeout')!.text, 'Android limits background work. It carries on while charging, or open Cache.');
      expect(n('battery', battery: 12)!.failed, isFalse);
    });

    test('nothing to say: all added, Cache took over (it carries on itself), or the stopped PDFs were dealt with since', () {
      expect(FgsAddNotice.of(result(), const []), isNull);
      expect(FgsAddNotice.of(result(why: 'app', left: ['a']), [sampleJob('a')]), isNull);
      expect(FgsAddNotice.of(result(why: 'battery', left: ['a']), const []), isNull, reason: 'the PDF was cancelled meanwhile');
      expect(FgsAddNotice.of(result(failed: ['a'], total: 1, added: 0), [sampleJob('a', status: AddPdfStatus.done)]), isNull);
    });

    test('it ended early and one failed: both are said', () {
      final jobs = [sampleJob('f', status: AddPdfStatus.failed), sampleJob('a')];
      final n = FgsAddNotice.of(result(why: 'battery', failed: ['f'], left: ['a'], battery: 9, total: 2, added: 0), jobs)!;
      expect(n.failed, isTrue);
      expect(n.alsoTitle, 'Paused · 1 of 2 PDFs');
      expect(n.alsoText, contains('Battery low (9%)'));
    });

    test('shown on the next open, once: load reads it, Dismiss puts it away, a result with nothing to say is deleted', () async {
      var jobs = <AddPdfJob>[sampleJob('a', status: AddPdfStatus.failed, error: 'locked', title: 'Tax form')];
      final st = FgsAddNoticeState(backgroundDir: () => bg, jobs: () => jobs);
      addTearDown(st.dispose);
      st.load();
      expect(st.notice, isNull);
      await writeFgsResult(bg, result(total: 1, added: 0, failed: ['a']));
      var seen = 0;
      st.addListener(() => seen++);
      st.load();
      expect(st.notice!.title, 'This PDF has a password');
      expect(seen, 1);
      st.load();
      expect(seen, 1, reason: 'the same notice is not announced twice');
      st.dismiss();
      expect(st.notice, isNull);
      expect(readFgsResult(bg), isNull);
      // a result whose PDFs were dealt with meanwhile is deleted at the next look
      await writeFgsResult(bg, result(total: 1, added: 0, failed: ['a']));
      jobs = [];
      st.load();
      expect(st.notice, isNull);
      expect(readFgsResult(bg), isNull);
    });

    test('end to end: a background add where one PDF cannot be added writes the result the next open shows', () async {
      final tmpDir = Directory.systemTemp.createTempSync('fgs-e2e');
      addTearDown(() => tmpDir.deleteSync(recursive: true));
      final support = '${tmpDir.path}/support';
      final calls = FakeIngestCalls({'step': steps([progress('failed', error: {'code': 'locked', 'message': 'password'})])});
      final s = testAddPdfState(Directory('$support/ingest'), calls: calls);
      addTearDown(s.dispose);
      final f = File('${tmpDir.path}/x.pdf')..writeAsStringSync('pdf');
      await s.add(pdfPath: f.path, fileName: 'x.pdf', bytes: 3, title: 'Tax form', target: const AddPdfTarget(title: 'My books', path: '/tmp/my-books'));
      final c = FgsAddControl();
      await fgsAddJob(support: support, control: c, lock: BackgroundLock(Directory(backgroundDir(support))), battery: () async => _charging, state: s, queue: ({bool next = false, Duration delay = Duration.zero}) async {}, waitForBack: Duration.zero, lookEvery: _quick);
      expect(c.failedWords?.$2, 'This PDF has a password');
      final st = FgsAddNoticeState(backgroundDir: () => backgroundDir(support), jobs: () => s.jobs);
      addTearDown(st.dispose);
      st.load();
      expect(st.notice?.title, 'This PDF has a password');
      expect(st.notice?.text, startsWith('Tax form · '));
    });
  });
}
