import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:cache/library/add_pdf/add_pdf_state.dart';
import 'package:cache/platform/app_log.dart';
import 'package:cache/search/index_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

import 'add_pdf_fixtures.dart';

/// One run per PDF: starts that arrive while the earlier run of the job is still stopping (Cache went to the back and came back,
/// the scheduler asked again) all get the same run, a finished job is never started again, and the wait is said once.
void main() {
  late Directory tmp;
  late Directory lib;
  late File pdf;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('add-pdf-one-run');
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

  Future<AddPdfJob> addOne(AddPdfState s) =>
      s.add(pdfPath: pdf.path, fileName: 'Water purification manual.pdf', bytes: 4096, title: 'Water purification manual', target: AddPdfTarget(title: 'My books', path: lib.path, isDefault: true), ownsFile: true);

  Future<int> logLines(String what) async {
    await appLog.flush();
    final t = [for (final f in appLog.logFiles.reversed) f.readAsStringSync()].join();
    return what.allMatches(t).length;
  }

  test('three starts at once while a run is mid-step give one run and one core start', () async {
    var inStep = 0, mostInStep = 0, n = 0;
    final gate = Completer<void>();
    final calls = FakeIngestCalls({
      'step': (_) async {
        n++;
        inStep++;
        mostInStep = max(mostInStep, inStep);
        if (n == 1) {
          await gate.future;
        } else {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        inStep--;
        return progress('embedding', pagesDone: 3, pieces: 10, piecesDone: 4);
      },
    });
    final s = testAddPdfState(Directory('${tmp.path}/ingest'), calls: calls);
    final job = await addOne(s);
    final task = (await s.pending()).single;
    final first = await task.start();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final starts = [task.start(), task.start(), task.start()];
    await Future<void>.delayed(const Duration(milliseconds: 10));
    gate.complete();
    final runs = await Future.wait(starts);
    expect(await first.finished, isFalse, reason: 'the earlier run stopped');
    expect(identical(runs[0], runs[1]) && identical(runs[1], runs[2]), isTrue, reason: 'one run for all three');
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(mostInStep, 1, reason: 'one run steps the job, never two at once');
    expect(calls.argsOf('start'), hasLength(1));
    await s.pause(job);
  });

  test('a job already done and a stale queued start give no core start', () async {
    final calls = FakeIngestCalls({
      'step': steps([progress('done', pagesDone: 3, pieces: 10, piecesDone: 10, result: {'copy': 'ab' * 32, 'pieces': 10})]),
    });
    final s = testAddPdfState(Directory('${tmp.path}/ingest'), calls: calls);
    final job = await addOne(s);
    final task = (await s.pending()).single;
    expect(await (await task.start()).finished, isTrue);
    expect(job.status, AddPdfStatus.done);
    expect(calls.argsOf('start'), hasLength(1));
    final stale = await task.start();
    expect(await stale.finished, isFalse);
    expect(calls.argsOf('start'), hasLength(1), reason: 'a finished job is never started again, so never embedded again');
    expect(await s.pending(), isEmpty);
  });

  test('to the back and to the front again with a long step: one embed, and the wait is said once', () async {
    final gate = Completer<void>();
    var n = 0, done = 0;
    final calls = FakeIngestCalls({
      'step': (_) async {
        n++;
        if (n == 1) {
          // the 10 s step the earlier run is in when Cache comes back
          await gate.future;
          return progress('embedding', pagesDone: 3, pieces: 10, piecesDone: 4);
        }
        if (n == 2) return progress('embedding', pagesDone: 3, pieces: 10, piecesDone: 7);
        return progress('done', pagesDone: 3, pieces: 10, piecesDone: 10, result: {'copy': 'ab' * 32, 'pieces': 10});
      },
    });
    final s = testAddPdfState(Directory('${tmp.path}/ingest'), calls: calls, onDone: (_) async => done++);
    await addOne(s);
    final task = (await s.pending()).single;
    final first = await task.start();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    unawaited(first.pause(IndexWait.closed)); // to the back: it stops after its step
    // to the front: the scheduler asks again, tick after tick, while the step is still going
    final again = <Future<IndexRun>>[];
    for (var i = 0; i < 5; i++) {
      again.add(task.start());
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    gate.complete();
    final runs = await Future.wait(again);
    expect(await runs.first.finished, isTrue);
    expect(done, 1, reason: 'one embed, one finish');
    expect(calls.argsOf('start'), hasLength(1));
    expect(await logLines('waiting for the earlier run of this PDF'), 1);
  });
}
