import 'dart:io';

import 'package:cache/pdf/index/pdf_index_fake.dart';
import 'package:cache/pdf/index/pdf_index_state.dart';
import 'package:cache/pdf/index/pdf_index_ui.dart';
import 'package:cache/platform/battery.dart';
import 'package:cache/search/index_scheduler.dart';
import 'package:cache/search/index_throttle.dart';
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

  test("the PDF status gives the scheduler's reason, in the Settings line's words; low battery only when it is the battery", () async {
    // Many PDFs, slowly, so the run is still going when it is held.
    pdf.dispose();
    pdf = PdfIndexState(
      core: FakePdfIndexCore(zims: {
        'u1': FakeZim(uuid: 'u1', name: 'guide', pdfs: [for (var i = 0; i < 40; i++) FakePdf('A/$i.pdf', pages: [_words(200)])]),
      }, stepDelay: const Duration(milliseconds: 20)),
      zims: () => zims,
      changes: ValueNotifier(0),
      indexesDir: () async => Directory('${dir.path}/shared-indexes'),
      recordFile: () async => File('${dir.path}/pdf-index.json'),
      readPages: (bytes, name, {betweenPages}) async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        return readFakePdfPages(bytes, name, betweenPages: betweenPages);
      },
      battery: () async => battery,
      space: (_) => const Space(free: 100 << 30, reserve: 0),
      watchEvery: const Duration(hours: 1),
    )..autoStart = null;
    await pdf.init();
    final z = zims.single;
    for (var i = 0; i < 200 && pdf.needsIndex(z) == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    final task = (await PdfIndexWork(pdf, () => zims).pending()).single;
    final run = await task.start();
    for (var i = 0; i < 200 && pdf.partOf(z)?.phase != PdfPartPhase.running; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    // Slowed by heat while it runs.
    run.setDuty(IndexDuty.share(0.3, hold: IndexHold.heat));
    expect(pdfPartLine(pdf.partOf(z)!), startsWith('Slowed down · device is warm · '));
    run.setDuty(IndexDuty.share(2 / 3));
    expect(pdfPartLine(pdf.partOf(z)!), startsWith('Making PDFs searchable · '));
    // Held because it waits for charging: not "low battery".
    await run.pause(IndexWait.charging);
    expect(await run.finished.timeout(const Duration(seconds: 10)), isFalse);
    for (var i = 0; i < 200 && pdf.partOf(z)?.phase != PdfPartPhase.paused; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final held = pdf.partOf(z)!;
    expect(held.pause, PdfPause.held);
    expect(pdfPartLine(held), startsWith('Waits for charging (long job) · '));
    expect(File('${dir.path}/pdf-index.json').readAsStringSync(), contains('"pause":"held"'));
    expect(pdf.needsIndex(z), isTrue, reason: 'the scheduler starts it again');
    // The app went to the back: just waiting.
    await pdf.hold(z, pdfHoldOf(IndexWait.closed));
    expect(pdfPartLine(pdf.partOf(z)!), startsWith('Paused · Cache is in the background · '));
    // Started again: the reason goes.
    await pdf.start(z);
    expect(pdf.partOf(z)!.pause, isNot(PdfPause.held));
    await pdf.hold(z);
  });

  test('the words for each reason', () {
    expect(pdfHoldWords(PdfHold.waiting), 'Waiting to make PDFs searchable');
    expect(pdfHoldWords(PdfHold.charging), 'Waits for charging (long job)');
    expect(pdfHoldWords(PdfHold.warm), 'Slowed down · device is warm');
    expect(pdfHoldWords(PdfHold.battery), 'Paused · battery low · plug in to continue');
    expect(pdfHoldWords(PdfHold.storage), 'Needs more free space · Free space');
    expect(pdfHoldWords(PdfHold.closed), 'Paused · Cache is in the background');
    expect(pdfHoldWords(PdfHold.model), 'Paused · while Ask answers');
    expect(pdfHoldWords(PdfHold.person), 'Paused by you · Resume');
    expect(pdfHoldOf(IndexWait.storage), PdfHold.storage);
    expect(pdfHoldOf(IndexWait.heat), PdfHold.warm);
    expect(pdfHoldOf(IndexWait.battery), PdfHold.battery);
    expect(pdfHoldOf(IndexWait.closed), PdfHold.closed);
    expect(pdfHoldOf(IndexWait.model), PdfHold.model);
    expect(pdfHoldOf(IndexWait.person), PdfHold.person);
    expect(pdfHoldOf(IndexWait.none), PdfHold.waiting);
    expect(pdfPartLine(const PdfPart(phase: PdfPartPhase.paused, total: 10, handled: 3, pause: PdfPause.battery)), 'Paused · battery low · plug in to continue · 3 of 10');
  });
}
