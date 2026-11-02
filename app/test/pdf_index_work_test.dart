import 'dart:io';

import 'package:cache/pdf/index/pdf_index_fake.dart';
import 'package:cache/pdf/index/pdf_index_state.dart';
import 'package:cache/platform/battery.dart';
import 'package:cache/search/index_scheduler.dart';
import 'package:cache/search/pdf_index_work.dart';
import 'package:cache/settings/space.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

String _words(int n, [String w = 'water']) => List.filled(n, w).join(' ');

FakeZim _zim() => FakeZim(
      uuid: 'u1',
      name: 'guide',
      pdfs: [
        FakePdf('A/one.pdf', title: 'One', pages: [_words(250)]),
        FakePdf('A/two.pdf', pages: [_words(120, 'shelter')]),
      ],
    );

/// The ZIMs' PDFs as the scheduler runs them: it decides when, the PDF state queues nothing by itself.
void main() {
  late Directory dir;
  late PdfIndexState pdf;
  late IndexScheduler s;
  late List<PdfZimRef> zims;
  BatteryReading? battery;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('pdfwork');
    File('${dir.path}/guide.zim').writeAsStringSync('zim');
    zims = [PdfZimRef(path: '${dir.path}/guide.zim', uuid: 'u1', title: 'Guide')];
    battery = const BatteryReading(percent: 80, charging: false);
    pdf = PdfIndexState(
      core: FakePdfIndexCore(zims: {'u1': _zim()}),
      zims: () => zims,
      changes: ValueNotifier(0),
      indexesDir: () async => Directory('${dir.path}/shared-indexes'),
      recordFile: () async => File('${dir.path}/pdf-index.json'),
      readPages: readFakePdfPages,
      battery: () async => battery,
      space: (_) => const Space(free: 100 << 30, reserve: 0),
      watchEvery: const Duration(hours: 1),
    )..autoStart = null;
    await pdf.init();
    s = IndexScheduler(
      sources: [PdfIndexWork(pdf, () => zims)],
      space: () => const Space(free: 100 << 30, reserve: 0),
      battery: () async => battery,
      every: const Duration(hours: 1),
    );
  });
  tearDown(() {
    s.dispose();
    pdf.dispose();
    dir.deleteSync(recursive: true);
  });

  Future<PdfPartPhase?> until(bool Function(PdfPartPhase? p) ok) async {
    PdfPartPhase? p;
    for (var i = 0; i < 400; i++) {
      await s.kick();
      p = pdf.partOf(zims.single)?.phase;
      if (ok(p)) return p;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    return p;
  }

  test('nothing starts by itself: the scheduler starts it while the app is open, and it is listed until done', () async {
    expect(await until((p) => p != null), PdfPartPhase.waiting);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(pdf.run, isNull, reason: 'autoStart is null: the PDF state queues nothing by itself');
    s.setOpen(true);
    expect(await until((p) => p == PdfPartPhase.done), PdfPartPhase.done);
    await s.kick();
    expect(s.line, isNull, reason: 'done: the work is no longer listed');
    expect(await PdfIndexWork(pdf, () => zims).pending(), isEmpty);
  });

  test('long work waits for charging; the work is keyed by its folder in the indexes share', () async {
    battery = const BatteryReading(percent: 40, charging: false);
    expect(await until((p) => p != null), PdfPartPhase.waiting);
    final tasks = await PdfIndexWork(pdf, () => zims).pending();
    expect(tasks.single.key, 'zim-pdf/u1');
    expect(tasks.single.long, isTrue, reason: 'long until measured');
    s.setOpen(true);
    await s.kick();
    expect(s.wait, IndexWait.charging);
    expect(pdf.run, isNull);
    battery = const BatteryReading(percent: 40, charging: true);
    expect(await until((p) => p == PdfPartPhase.done), PdfPartPhase.done);
  });

  test("the scheduler's pause is not the person's: the run stops, keeps its build, and starts again later", () async {
    expect(await until((p) => p != null), PdfPartPhase.waiting);
    final task = (await PdfIndexWork(pdf, () => zims).pending()).single;
    final run = await task.start();
    await run.pause();
    expect(await run.finished.timeout(const Duration(seconds: 10)), anyOf(isFalse, isTrue));
    if (pdf.partOf(zims.single)?.phase != PdfPartPhase.done) {
      expect(pdf.needsIndex(zims.single), isTrue, reason: 'held, not paused by the person: it is still to do');
      s.setOpen(true);
      expect(await until((p) => p == PdfPartPhase.done), PdfPartPhase.done);
    }
  });
}
