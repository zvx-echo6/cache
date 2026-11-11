// Watched folders with Cache closed (Android): watch-folder-detect counts new files by name, size and time (it reads none and
// adds nothing) and queues an add only when there are any; watch-folder-add holds the one lock, follows the indexing rules
// (charging, battery, heat), adds only what the watched folders found, in slices that stop for the time budget or for Cache
// coming to the front, and queues the next slice.

import 'dart:async';
import 'dart:io';

import 'package:cache/background/background_lock.dart';
import 'package:cache/library/add_pdf/add_pdf_slice.dart';
import 'package:cache/library/add_pdf/add_pdf_state.dart';
import 'package:cache/library/add_pdf/watch_background.dart';
import 'package:cache/library/add_pdf/watch_folders.dart';
import 'package:cache/platform/battery.dart';
import 'package:cache/search/index_scheduler.dart';
import 'package:cache/search/index_throttle.dart';
import 'package:cache/settings/space.dart';
import 'package:cache_search/cache_search.dart' show CacheSearchException;
import 'package:flutter_test/flutter_test.dart';

import '../add_pdf/add_pdf_fixtures.dart';

const _lib = AddPdfTarget(title: 'My books', path: '/tmp/my-books');
const _charging = BatteryReading(percent: 80, charging: true, thermal: Thermal.nominal);

void main() {
  late Directory tmp;
  late String support;
  late Directory manuals;
  late BackgroundLock lock;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('watch-bg');
    support = '${tmp.path}/support';
    manuals = Directory('${tmp.path}/Manuals')..createSync(recursive: true);
    lock = BackgroundLock(Directory(backgroundDir(support)));
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  File put(String rel, String content) {
    final f = File('${manuals.path}/$rel');
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
    return f;
  }

  /// Watches Manuals the way Cache does (its first check noting what is there) and lets go of the state, as Cache in the
  /// background has.
  Future<void> watched({bool add = false}) async {
    final pdf = testAddPdfState(Directory('$support/ingest'));
    final w = WatchFoldersState(addPdf: pdf, dir: () async => Directory('$support/ingest'));
    final f = await w.watch(root: manuals.path, name: 'Manuals', target: _lib, addExisting: add);
    await w.check(f);
    await w.save();
    await pdf.save();
    w.dispose();
    pdf.dispose();
  }

  group("the core's job number kept on disk", () {
    late String token;
    setUp(() => token = addPdfProcessToken);
    tearDown(() => addPdfProcessToken = token);

    test('is kept with the process token and read back only in the same process', () {
      final j = sampleJob('a')..coreJob = 7;
      final kept = j.toJson();
      expect(kept['core_proc'], addPdfProcessToken);
      expect(AddPdfJob.fromJson(kept).coreJob, 7);
      expect(AddPdfJob.fromJson(kept).coreFromDisk, isTrue);
      expect(AddPdfJob.fromJson({...kept, 'core_pid': pid}..remove('core_proc')).coreJob, isNull);
      // a new process that got the same pid has another token
      addPdfProcessToken = '$pid:another-start';
      expect(AddPdfJob.fromJson(kept).coreJob, isNull);
      expect(AddPdfJob.fromJson(sampleJob('b').toJson()).coreJob, isNull);
    });

    Future<(AddPdfState, AddPdfJob, FakeIngestCalls)> kept(Directory dir, FakeIngestCalls calls) async {
      dir.createSync(recursive: true);
      final first = testAddPdfState(dir);
      final f = File('${dir.path}/x.pdf')..writeAsStringSync('pdf');
      final j = await first.add(pdfPath: f.path, fileName: 'x.pdf', bytes: 3, title: 'x', target: _lib);
      j.coreJob = 7;
      Directory(j.jobDir).createSync(recursive: true);
      await first.save();
      first.dispose();
      final again = testAddPdfState(dir, calls: calls);
      await again.load();
      return (again, again.byId(j.id)!, calls);
    }

    test('a stale number (the core has no live job for the folder) is never stepped: the job starts again from its folder', () async {
      final calls = FakeIngestCalls({
        'start': (_) => {'job': 9, 'resumed': true, 'pages': 3},
        'step': steps([progress('done', result: {'copy': 'c' * 64})]),
      });
      final (s, j, c) = await kept(Directory('${tmp.path}/stale'), calls);
      expect(j.coreJob, 7);
      final run = await (await s.pending()).single.start();
      expect(await run.finished, isTrue);
      expect([for (final a in c.argsOf('step')) a['job']], everyElement(9));
      expect(c.argsOf('start'), hasLength(1));
      s.dispose();
    });

    test('a live job of this process holding the folder carries on under its number', () async {
      final calls = FakeIngestCalls({
        'start': (_) => throw CacheSearchException('io', 'a job already uses this job_dir'),
        'step': steps([progress('done', result: {'copy': 'c' * 64})]),
      });
      final (s, _, c) = await kept(Directory('${tmp.path}/live'), calls);
      final run = await (await s.pending()).single.start();
      expect(await run.finished, isTrue);
      expect([for (final a in c.argsOf('step')) a['job']], everyElement(7));
      s.dispose();
    });

    test('a stale number that the core no longer knows when stepped: started again from the folder', () async {
      var first = true;
      final calls = FakeIngestCalls({
        'start': (_) => first ? throw CacheSearchException('io', 'a job already uses this job_dir') : {'job': 11, 'resumed': true, 'pages': 3},
        'step': (a) {
          if (a['job'] == 7) {
            first = false;
            throw CacheSearchException('not_found', 'no such job');
          }
          return progress('done', result: {'copy': 'c' * 64});
        },
      });
      final (s, _, c) = await kept(Directory('${tmp.path}/gone'), calls);
      final run = await (await s.pending()).single.start();
      expect(await run.finished, isTrue);
      expect([for (final a in c.argsOf('step')) a['job']].last, 11);
      s.dispose();
    });
  });

  group('watch-folder-detect', () {
    test('counts new and changed PDFs by name, size and time; what was seen is not counted; it queues one add', () async {
      put('a.pdf', 'one');
      await watched();
      var queued = 0;
      expect(await watchDetectJob(support: support, lock: lock, queueAdd: () async => queued++), '0 new in 1 of 1 folders');
      expect(queued, 0);
      put('b.pdf', 'two');
      put('notes.txt', 'not a pdf');
      put('a.pdf', 'one, changed');
      expect(await watchDetectJob(support: support, lock: lock, queueAdd: () async => queued++), '2 new in 1 of 1 folders');
      expect(queued, 1);
      expect(watchDetectFile(support).readAsStringSync(), contains('"new":2'));
      // nothing was read or added: no job, and the folder's record is unchanged
      final jobs = File('$support/ingest/jobs.json');
      expect(jobs.existsSync() ? jobs.readAsStringSync() : '', isNot(contains('b.pdf')));
      expect((await readWatchedFolders(support)).single.files.keys, ['a.pdf']);
    });

    test('not while Cache is open; a folder that cannot be reached is left out', () async {
      put('a.pdf', 'one');
      await watched();
      lock.appOpened();
      expect(await watchDetectJob(support: support, lock: lock, queueAdd: () async {}), 'skipped: Cache is open');
      lock.appClosed();
      manuals.deleteSync(recursive: true);
      expect(await watchDetectJob(support: support, lock: lock, queueAdd: () async {}), '0 new in 0 of 1 folders');
    });
  });

  group('watch-folder-add', () {
    late AddPdfState pdf;
    late WatchFoldersState w;
    late List<(bool, Duration)> queued;

    Future<void> queue({bool next = false, Duration delay = Duration.zero}) async => queued.add((next, delay));

    setUp(() {
      queued = [];
    });

    Future<void> make({FakeIngestCalls? calls}) async {
      pdf = testAddPdfState(Directory('$support/ingest'), calls: calls);
      w = WatchFoldersState(addPdf: pdf, dir: () async => Directory('$support/ingest'));
    }

    tearDown(() {
      w.dispose();
      pdf.dispose();
    });

    test('checks the folders and adds what they found, under the lock, and lets go of it', () async {
      put('a.pdf', 'one');
      await watched();
      put('b.pdf', 'two');
      await make(calls: FakeIngestCalls({'step': steps([progress('done', result: {'copy': 'c' * 64, 'pieces': 3})])}));
      final out = await watchAddJob(support: support, lock: lock, battery: () async => _charging, state: pdf, watch: w, queue: queue);
      expect(out, 'added 1');
      expect(pdf.jobs.single.sourcePath, 'b.pdf');
      expect(pdf.jobs.single.status, AddPdfStatus.done);
      expect(w.folders.single.added, 1);
      expect(queued, isEmpty);
      expect(lock.runs(kAddPdfWork), isFalse);
      expect(lock.generation, 1);
    });

    test('never while Cache is open or while another run adds (no double work)', () async {
      await make();
      lock.appOpened();
      expect(await watchAddJob(support: support, lock: lock, battery: () async => _charging, state: pdf, watch: w, queue: queue), 'skipped: Cache is open');
      lock.appClosed();
      expect(lock.hold(kAddPdfWork), isTrue);
      expect(await watchAddJob(support: support, lock: lock, battery: () async => _charging, state: pdf, watch: w, queue: queue), 'skipped: another run is adding');
    });

    test('heat, a low battery or no charger: it does not start, and tries again later', () async {
      await make();
      for (final (b, why) in [
        // the app's throttle: a severe thermal status pauses index work (moderate and the headroom forecast only slow it)
        (const BatteryReading(percent: 80, charging: true, thermal: Thermal.severe), 'heat'),
        (const BatteryReading(percent: 15, charging: false), 'unplugged'),
        (const BatteryReading(percent: 60, charging: false), 'unplugged'),
      ]) {
        queued.clear();
        expect(await watchAddJob(support: support, lock: lock, battery: () async => b, state: pdf, watch: w, queue: queue), 'held: $why');
        expect(queued.single, (false, kWatchAddRetry));
      }
      expect(lock.runs(kAddPdfWork), isFalse);
    });

    test('a PDF added by hand is left for Cache; only what the folders found is added in the background', () async {
      put('a.pdf', 'one');
      await watched(add: true);
      await make(calls: FakeIngestCalls({'step': steps([progress('done', result: {'copy': 'c' * 64})])}));
      await pdf.load();
      final hand = File('${tmp.path}/hand.pdf')..writeAsStringSync('by hand');
      await pdf.add(pdfPath: hand.path, fileName: 'hand.pdf', bytes: 7, title: 'hand', target: _lib);
      await watchAddJob(support: support, lock: lock, battery: () async => _charging, state: pdf, watch: w, queue: queue);
      expect(pdf.jobs.firstWhere((j) => j.fileName == 'hand.pdf').status, AddPdfStatus.active);
      expect(pdf.jobs.firstWhere((j) => j.fileName == 'a.pdf').status, AddPdfStatus.done);
    });

    test('the time budget ends a slice mid-PDF: the job is paused, not lost, and the next slice is queued after it', () async {
      put('a.pdf', 'one');
      await watched(add: true);
      // the core keeps reading: the slice stops for its budget
      await make(calls: FakeIngestCalls({'step': (_) async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return progress('reading', pages: 100, pagesDone: 1);
      }}));
      await pdf.load();
      final slice = AddPdfSlice(pdf, budget: const Duration(milliseconds: 150), lookEvery: const Duration(milliseconds: 20), only: (j) => j.watchId != null);
      final r = await slice.run();
      expect(r.more, isTrue);
      expect(r.why, 'time');
      expect(pdf.jobs.single.status, AddPdfStatus.active);
      expect(pdf.jobs.single.pausedByPerson, isFalse, reason: 'paused for the slice, not by the person');
      // and through the job: the next slice is queued after this one
      final out = await watchAddJob(support: support, lock: lock, battery: () async => _charging, state: pdf, watch: w, budget: const Duration(milliseconds: 150), queue: queue);
      expect(out, contains('more to do (time)'));
      expect(queued.single, (true, Duration.zero));
    });

    test('Cache coming to the front stops the slice at once, and it queues nothing (Cache carries on)', () async {
      put('a.pdf', 'one');
      await watched(add: true);
      await make(calls: FakeIngestCalls({'step': (_) async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return progress('reading', pages: 100, pagesDone: 1);
      }}));
      final slice = AddPdfSlice(pdf, stopAsked: () => lock.stopAsked(kAddPdfWork), lookEvery: const Duration(milliseconds: 20));
      expect(lock.hold(kAddPdfWork), isTrue);
      final running = slice.run();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      final took = lock.takeOver(kAddPdfWork, wait: const Duration(seconds: 5), look: const Duration(milliseconds: 20));
      final r = await running;
      lock.release(kAddPdfWork);
      expect(r.why, 'app');
      expect(await took, isTrue);
      expect(pdf.jobs.single.status, AddPdfStatus.active);
    });

    test('heat during a slice pauses it', () async {
      put('a.pdf', 'one');
      await watched(add: true);
      await make(calls: FakeIngestCalls({'step': (_) async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return progress('embedding', pages: 1, pagesDone: 1, pieces: 100, piecesDone: 1);
      }}));
      var b = _charging;
      final th = IndexThrottle(read: () async => b, mobile: true);
      addTearDown(th.dispose);
      final slice = AddPdfSlice(pdf, held: () => addPdfHeldNow(th), lookEvery: const Duration(milliseconds: 20));
      final running = slice.run();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      b = const BatteryReading(percent: 80, charging: true, thermal: Thermal.severe);
      final r = await running;
      expect(r.why, 'heat');
      expect(r.more, isTrue);
    });
  });

  group('the same rules as the app', () {
    test("the slice follows the app's throttle: one embed thread on a phone, and it rests by the throttle's duty", () async {
      var t = DateTime(2026, 11, 10, 20);
      final slept = <Duration>[];
      // charging, but the headroom forecast is warm: the throttle slows the work (a share under one) and rests between bursts
      final th = IndexThrottle(
        read: () async => const BatteryReading(percent: 80, charging: true, thermal: Thermal.nominal, headroom: 0.85),
        mobile: true,
        clock: () => t = t.add(const Duration(seconds: 1)),
        sleep: (d) async => slept.add(d),
      );
      addTearDown(th.dispose);
      final before = indexThrottleShared;
      indexThrottleShared = th;
      addTearDown(() => indexThrottleShared = before);
      final calls = FakeIngestCalls({
        'step': steps([
          progress('reading', pagesDone: 1),
          progress('reading', pagesDone: 2),
          progress('embedding', pagesDone: 3, pieces: 4, piecesDone: 1),
          progress('embedding', pagesDone: 3, pieces: 4, piecesDone: 3),
          progress('done', result: {'copy': 'c' * 64}),
        ]),
      });
      // no permit of its own: the job follows indexThrottleShared, as in the app and in the background add
      final s = AddPdfState(calls: calls, dir: () async => Directory('$support/ingest'), engines: () async => const {}, busyWait: const Duration(milliseconds: 1));
      addTearDown(s.dispose);
      final f = File('${tmp.path}/p.pdf')..writeAsStringSync('pdf');
      await s.add(pdfPath: f.path, fileName: 'p.pdf', bytes: 3, title: 'p', target: _lib);
      final r = await AddPdfSlice(s, throttle: th, lookEvery: const Duration(milliseconds: 10)).run();
      expect(r.added, 1);
      expect(((calls.argsOf('start').single['opts'] as Map)['embed_threads']), 1, reason: "the throttle's thread count on a phone");
      expect(th.duty.share, lessThan(1));
      expect(th.duty.hold, IndexHold.heat);
      expect(slept.where((d) => d > Duration.zero), isNotEmpty, reason: 'it rests between bursts, by the duty');
    });

    test("a job folder another run of this process still holds is a hold: the job waits, then is left active for later, never failed", () async {
      var held = true;
      final calls = FakeIngestCalls({
        'start': (_) => held ? throw CacheSearchException('io', 'a job already uses this job_dir') : {'job': 3, 'resumed': true, 'pages': 3},
        'step': steps([progress('done', result: {'copy': 'c' * 64})]),
      });
      final s = AddPdfState(calls: calls, dir: () async => Directory('$support/ingest'), engines: () async => const {}, permit: (_) async {}, busyWait: const Duration(milliseconds: 1), inUseTries: 3);
      addTearDown(s.dispose);
      final f = File('${tmp.path}/q.pdf')..writeAsStringSync('pdf');
      final job = await s.add(pdfPath: f.path, fileName: 'q.pdf', bytes: 3, title: 'q', target: _lib);
      var run = await (await s.pending()).single.start();
      expect(await run.finished, isFalse);
      expect(job.status, AddPdfStatus.active, reason: 'not "could not be added"');
      expect(job.errorCode, isNull);
      expect(calls.argsOf('start'), hasLength(3), reason: 'it waited and tried again');
      // the other run let go: the next run carries on
      held = false;
      run = await (await s.pending()).single.start();
      expect(await run.finished, isTrue);
      expect(job.status, AddPdfStatus.done);
    });

    test("the core's job number is on disk as soon as the core gives it", () async {
      final calls = FakeIngestCalls({
        'step': (_) async {
          await Future<void>.delayed(const Duration(milliseconds: 30));
          return progress('reading', pages: 100, pagesDone: 1);
        },
      });
      final s = AddPdfState(calls: calls, dir: () async => Directory('$support/ingest'), engines: () async => const {}, permit: (_) async {}, busyWait: const Duration(milliseconds: 1));
      addTearDown(s.dispose);
      final f = File('${tmp.path}/r.pdf')..writeAsStringSync('pdf');
      await s.add(pdfPath: f.path, fileName: 'r.pdf', bytes: 3, title: 'r', target: _lib);
      final run = await (await s.pending()).single.start();
      // while it is still reading (before any state change wrote the list)
      for (var i = 0; i < 50 && !File('$support/ingest/jobs.json').readAsStringSync().contains('"core_job"'); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(File('$support/ingest/jobs.json').readAsStringSync(), contains('"core_job":1'));
      await (run as AddPdfRun).stop();
    });
  });

  group('going to the back (the Pixel run of 2026-11-10)', () {
    /// A PDF step that cannot be cut short (PDFium reading big pages took minutes on the phone): it ends only when the test
    /// lets it.
    ({FakeIngestCalls calls, Completer<void> release, List<int> inFlight}) longStep() {
      final release = Completer<void>();
      final inFlight = <int>[0, 0];
      return (
        calls: FakeIngestCalls({
          'step': (_) async {
            inFlight[0]++;
            if (inFlight[0] > inFlight[1]) inFlight[1] = inFlight[0];
            await release.future;
            inFlight[0]--;
            return progress('reading', pages: 194, pagesDone: 1);
          },
        }),
        release: release,
        inFlight: inFlight,
      );
    }

    Future<void> until(bool Function() ok) async {
      for (var i = 0; i < 200 && !ok(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }

    test('a step still running when Cache goes to the back: the add is queued within the wait anyway, and the lock let go', () async {
      final l = longStep();
      final s = AddPdfState(calls: l.calls, dir: () async => Directory('$support/ingest'), engines: () async => const {}, permit: (_) async {}, busyWait: const Duration(milliseconds: 1));
      final f = File('${tmp.path}/w.pdf')..writeAsStringSync('pdf');
      final job = await s.add(pdfPath: f.path, fileName: 'w.pdf', bytes: 3, title: 'w', target: _lib, watchId: 'f1', watchName: 'Manuals', checkId: 'c1', watchHash: 'h');
      final sched = IndexScheduler(sources: [s], space: () => const Space(free: 100 << 30, reserve: 1 << 30), battery: () async => const BatteryReading(percent: 90, charging: true));
      sched.setOpen(true);
      await sched.kick();
      await until(() => l.inFlight[0] == 1);
      expect(l.inFlight[0], 1, reason: 'the step is in flight');
      lock.appOpened();
      sched.setOpen(false);
      var queued = 0;
      final sw = Stopwatch()..start();
      final out = await backgroundHandOff(
        closed: sched.closed,
        save: s.save,
        atFront: () => false,
        release: lock.appClosed,
        hasWork: () => s.active.any((j) => j.watchId != null && !j.pausedByPerson),
        queueAdd: () async => queued++,
        wait: const Duration(milliseconds: 300),
      ).timeout(const Duration(seconds: 5));
      expect(out, 'queued after wait');
      expect(queued, 1);
      expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
      expect(lock.appOpen, isFalse);
      expect(job.status, AddPdfStatus.active);
      l.release.complete();
      await sched.closed;
      sched.dispose();
      s.dispose();
    });

    test("a run waiting on the throttle's permit stops at once when asked (the permit loop ends on stop)", () async {
      // a severe thermal status holds work: the permit waits
      final th = IndexThrottle(read: () async => const BatteryReading(percent: 90, charging: true, thermal: Thermal.severe), mobile: true, every: const Duration(milliseconds: 20));
      addTearDown(th.dispose);
      var stop = false;
      final waiting = th.permit(stop: () => stop);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      stop = true;
      await waiting.timeout(const Duration(seconds: 2));
      // and a run held at its permit stops when paused
      final before = indexThrottleShared;
      indexThrottleShared = th;
      addTearDown(() => indexThrottleShared = before);
      final s = AddPdfState(calls: FakeIngestCalls(), dir: () async => Directory('$support/ingest'), engines: () async => const {}, busyWait: const Duration(milliseconds: 1));
      addTearDown(s.dispose);
      final f = File('${tmp.path}/t.pdf')..writeAsStringSync('pdf');
      await s.add(pdfPath: f.path, fileName: 't.pdf', bytes: 3, title: 't', target: _lib);
      final run = await (await s.pending()).single.start();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await run.pause().timeout(const Duration(seconds: 2));
      expect(await run.finished, isFalse);
    });

    test('to the back and straight back to the front: never two runs of the same PDF at once', () async {
      final l = longStep();
      final s = AddPdfState(calls: l.calls, dir: () async => Directory('$support/ingest'), engines: () async => const {}, permit: (_) async {}, busyWait: const Duration(milliseconds: 1));
      final f = File('${tmp.path}/d.pdf')..writeAsStringSync('pdf');
      await s.add(pdfPath: f.path, fileName: 'd.pdf', bytes: 3, title: 'd', target: _lib);
      final first = await (await s.pending()).single.start();
      await until(() => l.inFlight[0] == 1);
      // to the back: asked to stop, its step still running
      final stopping = first.pause();
      // back to the front: the scheduler starts the job again
      final second = (await s.pending()).single.start();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(l.calls.argsOf('start'), hasLength(1), reason: 'the second run has not started while the first is still stopping');
      l.release.complete();
      await stopping;
      final run2 = await second.timeout(const Duration(seconds: 2));
      await until(() => l.calls.argsOf('step').length >= 2);
      expect(l.inFlight[1], 1, reason: 'never two steps of the same PDF at once');
      await run2.pause();
      s.dispose();
    });
  });
}
