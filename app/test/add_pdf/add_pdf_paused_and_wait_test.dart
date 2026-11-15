import 'dart:async';
import 'dart:io';

import 'package:cache/library/add_pdf/add_pdf_state.dart';
import 'package:cache/platform/app_log.dart';
import 'package:cache/search/index_scheduler.dart';
import 'package:cache/settings/space.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter_test/flutter_test.dart';

import 'add_pdf_fixtures.dart';

/// Pixel round 2, 2026-11-14: a PDF paused by the person resumed itself after an update, and a start that waited for an earlier
/// run of the same PDF was repeated thousands of times (and the app stopped answering). A pause stays; the wait is bounded, said once
/// and never repeated in a loop.
void main() {
  late Directory tmp;
  late Directory lib;
  late File pdf;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('add-pdf-paused-wait');
    lib = Directory('${tmp.path}/libraries/my-books')..createSync(recursive: true);
    pdf = File('${tmp.path}/picked/Water purification manual.pdf')
      ..createSync(recursive: true)
      ..writeAsBytesSync(List<int>.filled(4096, 0x25));
    await appLog.open(Directory('${tmp.path}/log')..createSync());
    await appLog.setLevel(LogLevel.standard);
  });
  tearDown(() async {
    await appLog.close();
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows keeps the log file open a moment longer
    }
  });

  Future<int> logLines(String what) async {
    await appLog.flush();
    final t = [for (final f in appLog.logFiles.reversed) f.readAsStringSync()].join();
    return what.allMatches(t).length;
  }

  AddPdfState stateOver(Directory dir, FakeIngestCalls calls, {int inUseTries = 15, Duration startWait = const Duration(seconds: 45), Future<void> Function(AddPdfJob)? onDone}) => AddPdfState(
    calls: calls,
    dir: () async => dir,
    engines: () async => {'pdfium_version': 'chromium/7811'},
    permit: (_) async {},
    busyWait: const Duration(milliseconds: 1),
    inUseTries: inUseTries,
    startWait: startWait,
    clock: () => DateTime(2026, 11, 15, 12), // frozen: a start's wait is its whole time, however slow the machine
    onDone: onDone,
  );

  Future<AddPdfJob> addOne(AddPdfState s) => s.add(pdfPath: pdf.path, fileName: 'Water purification manual.pdf', bytes: 4096, title: 'Water purification manual', target: AddPdfTarget(title: 'My books', path: lib.path, isDefault: true), ownsFile: true);

  IndexScheduler schedulerOver(AddPdfState s) => IndexScheduler(sources: [s], space: () => const Space(free: 100 << 30, reserve: 1 << 30), battery: () async => null, every: const Duration(hours: 1));

  group('a Pause stays', () {
    test('a paused job read again after a restart is not started: no "resumed"', () async {
      final ingest = Directory('${tmp.path}/ingest');
      final before = FakeIngestCalls();
      final a = stateOver(ingest, before);
      final job = await addOne(a);
      await a.pause(job);

      // the app is updated: a new process reads the jobs from disk
      final calls = FakeIngestCalls({
        'start': (_) async => {'job': 1, 'resumed': true, 'pages': 3},
        'step': (_) async => progress('done', pagesDone: 3, pieces: 10, piecesDone: 10, result: {'copy': 'ab' * 32, 'pieces': 10}),
      });
      final b = stateOver(ingest, calls);
      await b.load();
      expect(b.jobs.single.pausedByPerson, isTrue);
      final sched = schedulerOver(b);
      addTearDown(sched.dispose);
      sched.setOpen(true);
      await sched.kick();
      await turns(200);
      expect(calls.argsOf('start'), isEmpty);
      expect(calls.argsOf('step'), isEmpty);
      expect(b.jobs.single.status, AddPdfStatus.active);
      expect(await logLines('Add PDF: resumed'), 0);
    });

    test('a copy that read the jobs before the Pause does not write it away when it saves', () async {
      final ingest = Directory('${tmp.path}/ingest');
      final a = stateOver(ingest, FakeIngestCalls());
      final job = await addOne(a);
      // a second copy of the jobs (a background run, the foreground service) read them before the Pause
      final stale = stateOver(ingest, FakeIngestCalls());
      await stale.load();
      expect(stale.jobs.single.pausedByPerson, isFalse);
      await a.pause(job);
      await stale.save();

      final fresh = stateOver(ingest, FakeIngestCalls());
      await fresh.load();
      expect(fresh.jobs.single.pausedByPerson, isTrue, reason: 'the later write of a copy that did not decide the Pause keeps it');
      // and the copy that did decide wins: a Resume is written over a Pause
      final other = stateOver(ingest, FakeIngestCalls());
      await other.load();
      await other.resume(other.jobs.single);
      final again = stateOver(ingest, FakeIngestCalls());
      await again.load();
      expect(again.jobs.single.pausedByPerson, isFalse);
    });
  });

  group('the wait for an earlier run', () {
    test('the scheduler, closed and opened while a start waits for the run still in its step: one wait said, the job started once', () async {
      final gate = Completer<void>();
      var n = 0, done = 0;
      final calls = FakeIngestCalls({
        'step': (_) async {
          n++;
          if (n == 1) {
            await gate.future; // the long step, which cannot be interrupted
            return progress('embedding', pagesDone: 3, pieces: 10, piecesDone: 4);
          }
          if (n == 2) return progress('embedding', pagesDone: 3, pieces: 10, piecesDone: 7);
          return progress('done', pagesDone: 3, pieces: 10, piecesDone: 10, result: {'copy': 'ab' * 32, 'pieces': 10});
        },
      });
      final s = stateOver(Directory('${tmp.path}/ingest'), calls, onDone: (_) async => done++);
      await addOne(s);
      final sched = schedulerOver(s);
      addTearDown(sched.dispose);
      sched.setOpen(true);
      await pumpUntil(() => n == 1 && sched.running != null, what: 'the first step');
      sched.setOpen(false); // to the back: the run stops after its step
      await turns(50);
      sched.setOpen(true); // to the front: a start now waits for the run that is still stopping
      await turns(50);
      sched.setOpen(false); // to the back again while that start waits: nothing is running yet that the scheduler could stop
      await turns(50);
      sched.setOpen(true);
      await turns(50);
      gate.complete();
      await pumpUntil(() => done == 1, what: 'the job done');
      await turns(200);
      expect(await logLines('waiting for the earlier run of this PDF'), lessThanOrEqualTo(1), reason: 'said once, not once for every start');
      expect(done, 1);
      expect(calls.argsOf('start'), hasLength(1));
      expect(n, lessThanOrEqualTo(5), reason: 'the steps are not started over and over');
    });

    test('a run that never stops: each start gives up after its time, the wait is said once, nothing spins', () async {
      final gate = Completer<void>();
      final calls = FakeIngestCalls({
        'step': (_) async {
          await gate.future;
          return progress('embedding', pagesDone: 3, pieces: 10, piecesDone: 4);
        },
      });
      final s = stateOver(Directory('${tmp.path}/ingest'), calls, startWait: const Duration(milliseconds: 40));
      addTearDown(() async {
        if (!gate.isCompleted) gate.complete();
      });
      await addOne(s);
      final first = (await s.pending()).single;
      final run = await first.start();
      await pumpUntil(() => calls.argsOf('step').isNotEmpty, what: 'the first step');
      expect(calls.argsOf('step'), hasLength(1), reason: 'the first run is in its step');

      final t0 = DateTime.now();
      var gaveUp = 0;
      for (var i = 0; i < 5; i++) {
        try {
          await (await s.pending()).single.start();
        } on StateError catch (e) {
          expect('$e', contains('did not stop within'));
          gaveUp++;
        }
      }
      final took = DateTime.now().difference(t0);
      expect(gaveUp, 5, reason: 'each start gave up');
      expect(took, greaterThanOrEqualTo(const Duration(milliseconds: 150)), reason: 'each start waited its time (no busy loop)');
      expect(await logLines('waiting for the earlier run of this PDF'), 1, reason: 'said once, not for every start');
      expect(calls.argsOf('step'), hasLength(1));
      expect(calls.argsOf('start'), hasLength(1));
      gate.complete();
      await run.finished;
    });

    test('a run that stops while a start waits: the start goes on', () async {
      final gate = Completer<void>();
      var n = 0;
      final calls = FakeIngestCalls({
        'step': (_) async {
          n++;
          if (n == 1) {
            await gate.future;
            return progress('embedding', pagesDone: 3, pieces: 10, piecesDone: 4);
          }
          return progress('done', pagesDone: 3, pieces: 10, piecesDone: 10, result: {'copy': 'ab' * 32, 'pieces': 10});
        },
      });
      final s = stateOver(Directory('${tmp.path}/ingest'), calls, startWait: const Duration(seconds: 5));
      await addOne(s);
      final run = await (await s.pending()).single.start();
      await pumpUntil(() => n == 1, what: 'the first step');
      final next = (await s.pending()).single.start();
      await turns(50);
      gate.complete();
      final run2 = await next;
      expect(identical(run2, run), isFalse);
      expect(await run2.finished, isTrue);
      expect(s.jobs.single.status, AddPdfStatus.done);
    });

    test('the job folder held for good: a bounded number of tries, one line when waiting, one when left for later, never a failure', () async {
      final calls = FakeIngestCalls({
        'start': (_) async => throw CacheSearchException('io', 'the ingest job already uses this job_dir'),
      });
      final s = stateOver(Directory('${tmp.path}/ingest'), calls, inUseTries: 4);
      await addOne(s);
      final run = await (await s.pending()).single.start();
      expect(await run.finished, isFalse);
      expect(calls.argsOf('start'), hasLength(4));
      expect(await logLines('another run still holds this PDF; waiting for it'), 1);
      expect(await logLines('it is left for later'), 1);
      expect(s.jobs.single.status, AddPdfStatus.active);
    });

    test('the job folder released after a few tries: the job goes on and is added', () async {
      var starts = 0;
      final calls = FakeIngestCalls({
        'start': (_) async {
          starts++;
          if (starts < 3) throw CacheSearchException('io', 'the ingest job already uses this job_dir');
          return {'job': 1, 'resumed': false, 'pages': 3};
        },
        'step': (_) async => progress('done', pagesDone: 3, pieces: 10, piecesDone: 10, result: {'copy': 'ab' * 32, 'pieces': 10}),
      });
      final s = stateOver(Directory('${tmp.path}/ingest'), calls, inUseTries: 6);
      await addOne(s);
      final run = await (await s.pending()).single.start();
      expect(await run.finished, isTrue);
      expect(starts, 3);
      expect(s.jobs.single.status, AddPdfStatus.done);
    });
  });
}
