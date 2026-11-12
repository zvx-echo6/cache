import 'dart:async';
import 'dart:io';

import 'package:cache/library/add_pdf/add_pdf_state.dart';
import 'package:cache/platform/app_log.dart';
import 'package:cache/search/index_scheduler.dart';
import 'package:cache/settings/space.dart';
import 'package:flutter_test/flutter_test.dart';

import 'add_pdf_fixtures.dart';

/// The scheduler and the real Add PDF state together: the front run is in a step that cannot be interrupted, the app goes to the
/// back and comes to the front again, and the scheduler is kicked over and over. The run is waited for, never started again and
/// again, and the wait is said once.
void main() {
  late Directory tmp;
  late Directory lib;
  late File pdf;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('add-pdf-flood');
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

  test('back, front and repeated kicks while the front run is in a long step: the wait is said once, the job is started once', () async {
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
    final s = testAddPdfState(Directory('${tmp.path}/ingest'), calls: calls, onDone: (_) async => done++);
    await s.add(pdfPath: pdf.path, fileName: 'Water purification manual.pdf', bytes: 4096, title: 'Water purification manual', target: AddPdfTarget(title: 'My books', path: lib.path, isDefault: true), ownsFile: true);
    final sched = IndexScheduler(sources: [s], space: () => const Space(free: 100 << 30, reserve: 1 << 30), battery: () async => null, every: const Duration(milliseconds: 2));
    addTearDown(sched.dispose);
    sched.setOpen(true);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(sched.running, isNotNull);
    sched.setOpen(false); // to the back: the run stops after its step
    await Future<void>.delayed(const Duration(milliseconds: 20));
    sched.setOpen(true); // to the front again, the step still going
    for (var i = 0; i < 100; i++) {
      unawaited(sched.kick());
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    gate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final said = await logLines('waiting for the earlier run of this PDF');
    expect(said, lessThanOrEqualTo(1), reason: 'the wait is said once');
    expect(done, 1);
    expect(calls.argsOf('start'), hasLength(1));
  });
}
