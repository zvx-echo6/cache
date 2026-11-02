import 'dart:io';

import 'package:cache/pdf/index/battery.dart';
import 'package:cache/pdf/index/pdf_index_core.dart';
import 'package:cache/pdf/index/pdf_index_fake.dart';
import 'package:cache/pdf/index/pdf_index_run.dart';
import 'package:cache/pdf/index/pdf_index_state.dart';
import 'package:cache/pdf/index/pdf_index_ui.dart';
import 'package:cache/pdf/index/pdf_timing.dart';
import 'package:cache/settings/space.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _model = 'bge-m3-Q8_0.gguf';

String _words(int n, [String w = 'water']) => List.filled(n, w).join(' ');

FakeZim _zim({String uuid = 'u1'}) => FakeZim(
  uuid: uuid,
  name: 'guide',
  pdfs: [
    FakePdf('A/one.pdf', title: 'One', pages: [_words(250), _words(30, 'fire')]),
    const FakePdf('A/locked.pdf', locked: true),
    const FakePdf('A/broken.pdf', damaged: true),
    const FakePdf('A/scan.pdf', pages: ['', '  ']),
    FakePdf('A/two.pdf', pages: [_words(120, 'shelter')]),
  ],
);

/// The search model's stand-in: a 1024-float vector per piece, counting calls.
class _Embed {
  int calls = 0;
  void Function(int calls)? onCall;
  Future<(String, List<double>)?> call(String text) async {
    calls++;
    onCall?.call(calls);
    return (_model, List<double>.filled(1024, 0.5));
  }
}

void main() {
  late Directory dir;
  late String zimPath;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('pdfindex');
    zimPath = '${dir.path}/guide.zim';
    File(zimPath).writeAsStringSync('zim');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<ZimPdfList> list(FakePdfIndexCore core) => core.zimPdfs('u1');

  group('the driver', () {
    test('indexes every PDF with text, skips locked, damaged and textless ones, and publishes', () async {
      final core = FakePdfIndexCore(zims: {'u1': _zim()});
      final embed = _Embed();
      final run = PdfIndexRun(core: core, embed: embed.call, model: _model, zimPath: zimPath, list: await list(core), readPages: readFakePdfPages);
      expect(await run.run(), PdfRunEnd.finished);
      expect(core.calls, [
        'open',
        'add:A/one.pdf',
        'skip:A/locked.pdf:locked',
        'skip:A/broken.pdf:damaged',
        'skip:A/scan.pdf:no_text',
        'add:A/two.pdf',
        'close',
        'finish',
      ]);
      expect(run.done, 2);
      expect(run.skipped, 3);
      // One piece of 200 words and one of the rest (40 words of overlap) on page 1, one on page 2, one for the second PDF.
      expect(embed.calls, 4);
      final paths = PdfIndexPaths(zimPath);
      expect(paths.partial.existsSync(), isFalse);
      expect(paths.tmp.existsSync(), isFalse);
      final m = PdfIndexManifest.read(paths.index)!;
      expect(m.zimUuid, 'u1');
      expect(m.pdfs, 2);
      expect(m.skipped, 3);
      expect(run.result?['pieces'], 4);
    });

    test('a pause keeps the partial; the next run starts from its done list and redoes only the PDF in hand', () async {
      final core = FakePdfIndexCore(zims: {'u1': _zim()});
      final embed = _Embed();
      late PdfIndexRun run;
      // Pause while the second PDF with text is being embedded: the first is done, that one is dropped.
      embed.onCall = (n) {
        if (n == 4) run.stop(PdfRunStop.person);
      };
      run = PdfIndexRun(core: core, embed: embed.call, model: _model, zimPath: zimPath, list: await list(core), readPages: readFakePdfPages);
      expect(await run.run(), PdfRunEnd.paused);
      expect(PdfIndexPaths(zimPath).partial.existsSync(), isTrue);
      expect(core.calls.where((c) => c.startsWith('add:')), ['add:A/one.pdf']);
      expect(core.calls.last, 'close');

      core.calls.clear();
      embed.onCall = null;
      final again = PdfIndexRun(core: core, embed: embed.call, model: _model, zimPath: zimPath, list: await list(core), readPages: readFakePdfPages);
      expect(await again.run(), PdfRunEnd.finished);
      expect(core.calls, ['open', 'add:A/two.pdf', 'close', 'finish']);
      expect(again.done, 2);
      expect(again.skipped, 3);
    });

    test('cancel discards the partial', () async {
      final core = FakePdfIndexCore(zims: {'u1': _zim()});
      final embed = _Embed();
      late PdfIndexRun run;
      embed.onCall = (n) {
        if (n == 2) run.stop(PdfRunStop.cancel);
      };
      run = PdfIndexRun(core: core, embed: embed.call, model: _model, zimPath: zimPath, list: await list(core), readPages: readFakePdfPages);
      expect(await run.run(), PdfRunEnd.cancelled);
      expect(core.calls.last, 'discard');
      expect(PdfIndexPaths(zimPath).partial.existsSync(), isFalse);
      expect(PdfIndexPaths(zimPath).index.existsSync(), isFalse);
    });

    test('a low battery on battery pauses; plugged in it does not', () async {
      final core = FakePdfIndexCore(zims: {'u1': _zim()});
      final low = PdfIndexRun(
        core: core,
        embed: _Embed().call,
        model: _model,
        zimPath: zimPath,
        list: await list(core),
        readPages: readFakePdfPages,
        battery: () async => const BatteryReading(percent: 15, charging: false),
      );
      expect(await low.run(), PdfRunEnd.paused);
      expect(low.stopped, PdfRunStop.battery);
      final plugged = PdfIndexRun(
        core: core,
        embed: _Embed().call,
        model: _model,
        zimPath: zimPath,
        list: await list(core),
        readPages: readFakePdfPages,
        battery: () async => const BatteryReading(percent: 15, charging: true),
      );
      expect(await plugged.run(), PdfRunEnd.finished);
    });

    test('a full device stops with "this device is full"; the partial stays for a resume', () async {
      final core = FakePdfIndexCore(zims: {'u1': _zim()}, failAddWith: const FileSystemException('write', 'x', OSError('No space left on device', 28)));
      final run = PdfIndexRun(core: core, embed: _Embed().call, model: _model, zimPath: zimPath, list: await list(core), readPages: readFakePdfPages);
      expect(await run.run(), PdfRunEnd.failed);
      expect(run.failure?.kind, PdfRunFailureKind.full);
      expect(pdfStopWords(run.failure!), 'this device is full');
      expect(PdfIndexPaths(zimPath).partial.existsSync(), isTrue);
    });

    test('no search model: it stops and says so', () async {
      final core = FakePdfIndexCore(zims: {'u1': _zim()});
      final run = PdfIndexRun(core: core, embed: (_) async => null, model: _model, zimPath: zimPath, list: await list(core), readPages: readFakePdfPages);
      expect(await run.run(), PdfRunEnd.failed);
      expect(run.failure?.kind, PdfRunFailureKind.needsModel);
    });

    test('with no embed stage it builds a keyword-only index (no model, no vectors)', () async {
      final core = FakePdfIndexCore(zims: {'u1': _zim()}, vectors: false);
      final run = PdfIndexRun(core: core, embed: null, model: _model, zimPath: zimPath, list: await list(core), readPages: readFakePdfPages);
      expect(await run.run(), PdfRunEnd.finished);
      expect(run.done, 2);
      expect(run.pieces, 4);
    });
  });

  group('the state', () {
    late FakePdfIndexCore core;
    late PdfIndexState state;
    late List<PdfZimRef> zims;

    PdfIndexState make({PdfIndexCore? withCore}) => PdfIndexState(
      core: withCore ?? core,
      zims: () => zims,
      embed: _Embed().call,
      model: _model,
      hasModel: () => true,
      recordFile: () async => File('${dir.path}/support/pdf-index.json'),
      readPages: readFakePdfPages,
      battery: null,
      space: (_) => const Space(free: 100 << 30, reserve: 5 << 30),
    );

    Future<PdfPart?> settled(PdfZimRef z) async {
      await state.listOf(z);
      for (var i = 0; i < 100; i++) {
        final p = state.partOf(z);
        if (p != null) return p;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      return null;
    }

    Future<void> until(PdfZimRef z, PdfPartPhase phase) async {
      for (var i = 0; i < 400 && state.partOf(z)?.phase != phase; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    }

    setUp(() async {
      core = FakePdfIndexCore(zims: {'u1': _zim()});
      zims = [PdfZimRef(path: zimPath, uuid: 'u1', title: 'Guide')];
      state = make();
      await state.init();
    });
    tearDown(() => state.dispose());

    test('nothing shows while the core cannot index PDFs', () async {
      final none = make(withCore: const PdfIndexCoreMissing());
      await none.init();
      expect(none.partOf(zims.single), isNull);
      expect(none.pending(), isEmpty);
      none.dispose();
    });

    test('not searchable yet, then running, then done; the record says this device built it', () async {
      final z = zims.single;
      final p = await settled(z);
      expect(p?.phase, PdfPartPhase.idle);
      expect(p?.total, 5);
      expect(pdfPartLine(p!), '5 PDFs · not searchable yet');
      expect(state.pending().single.$1.title, 'Guide');
      await state.start(z);
      await until(z, PdfPartPhase.done);
      final done = state.partOf(z)!;
      expect(done.phase, PdfPartPhase.done);
      expect(done.fromOtherDevice, isFalse);
      expect(pdfPartLine(done), 'Searchable · 2 of 5 PDFs');
      expect(done.unreadable, 3);
      expect(state.pending(), isEmpty);
      // A new start of the app reads the same from its record.
      final later = make();
      await later.init();
      state.dispose();
      state = later;
      expect((await settled(z))?.fromOtherDevice, isFalse);
    });

    test('an index that arrived from another device is used at once', () async {
      final z = zims.single;
      await settled(z);
      // Another device built it (the same fake publish, then the folder arrives here by sync).
      final elsewhere = Directory('${dir.path}/elsewhere')..createSync();
      final otherZim = '${elsewhere.path}/guide.zim';
      final other = FakePdfIndexCore(zims: {'u1': _zim()});
      final run = PdfIndexRun(core: other, embed: _Embed().call, model: _model, zimPath: otherZim, list: await other.zimPdfs('u1'), readPages: readFakePdfPages);
      expect(await run.run(), PdfRunEnd.finished);
      PdfIndexPaths(otherZim).index.renameSync(PdfIndexPaths(zimPath).index.path);
      final fresh = make();
      await fresh.init();
      state.dispose();
      state = fresh;
      final p = (await settled(z))!;
      expect(p.phase, PdfPartPhase.done);
      expect(p.fromOtherDevice, isTrue);
      expect(pdfPartLine(p), 'Searchable · came from another device');
    });

    test('a partial with no pause recorded was cut off: "Paused: Cache was closed"; Remove deletes it', () async {
      final z = zims.single;
      await settled(z);
      PdfIndexPaths(zimPath).partial.createSync();
      final p = state.partOf(z)!;
      expect(p.phase, PdfPartPhase.paused);
      expect(p.pause, PdfPause.closed);
      expect(pdfPartLine(p), startsWith('Paused: Cache was closed'));
      await state.remove(z);
      expect(PdfIndexPaths(zimPath).partial.existsSync(), isFalse);
      expect(state.partOf(z)!.phase, PdfPartPhase.idle);
    });

    test('an index for another ZIM version shows the new version and its new PDFs', () async {
      final z = zims.single;
      await settled(z);
      final idx = PdfIndexPaths(zimPath).index..createSync();
      File('${idx.path}/cache-library.json').writeAsStringSync('{"zim_uuid":"old","pdfs":2,"skipped":0}');
      File('${idx.path}/documents.tsv').writeAsStringSync('A/one.pdf\t3\nA/two.pdf\t1\n');
      File('${idx.path}/SHA256SUMS').writeAsStringSync('x\n');
      final fresh = make();
      await fresh.init();
      state.dispose();
      state = fresh;
      final p = (await settled(z))!;
      expect(p.phase, PdfPartPhase.newVersion);
      expect(p.newCount, 3);
      expect(pdfPartLine(p), '5 PDFs · 3 new, not searchable yet');
    });

    test('the estimate is timed on this device and checked against the space and the reserve', () async {
      final z = zims.single;
      await settled(z);
      final e = (await state.measure(z))!;
      expect(e.pdfs, 5);
      expect(e.needsModel, isFalse);
      expect(e.high >= e.low, isTrue);
      expect(e.needBytes, e.indexBytes * 2);
      expect(e.fits, isTrue);
      final tight = PdfEstimate(pdfs: 5, low: Duration.zero, high: Duration.zero, indexBytes: 600 << 20, needBytes: 1200 << 20, usable: 400 << 20);
      expect(tight.fits, isFalse);
    });

    test('the hidden note stays hidden', () async {
      final z = zims.single;
      await settled(z);
      expect(state.pending(), hasLength(1));
      await state.hideNote([z]);
      expect(state.pending(), isEmpty);
      expect(state.partOf(z)!.phase, PdfPartPhase.idle);
    });

    test('auto-start is off unless the hook says so', () async {
      expect(state.autoStart, isNull);
    });
  });

  group('words', () {
    test('ranges round the way downloads do', () {
      expect(pdfRange(const Duration(hours: 5), const Duration(hours: 8)), 'about 5 to 8 hr');
      expect(pdfRange(const Duration(minutes: 3), const Duration(minutes: 3)), 'about 3 min');
      expect(pdfRange(const Duration(minutes: 40), const Duration(hours: 2)), 'about 40 min to 2 hr');
      expect(pdfRange(const Duration(seconds: 20), const Duration(seconds: 40)), 'less than a minute');
    });

    test('every state has its line', () {
      expect(pdfPartLine(const PdfPart(phase: PdfPartPhase.running, total: 5768, handled: 1204, timeLeft: Duration(hours: 5))), '1,204 of 5,768 PDFs · about 5 hr left');
      expect(pdfPartLine(const PdfPart(phase: PdfPartPhase.running, total: 5768, handled: 1204)), '1,204 of 5,768 PDFs');
      expect(pdfPartLine(const PdfPart(phase: PdfPartPhase.paused, total: 5768, handled: 1204, pause: PdfPause.person)), 'Paused · 1,204 of 5,768 PDFs');
      expect(pdfPartLine(const PdfPart(phase: PdfPartPhase.paused, total: 5768, handled: 1204, pause: PdfPause.battery)), 'Paused: battery low · 1,204 of 5,768');
      expect(
        pdfPartLine(const PdfPart(phase: PdfPartPhase.failed, total: 5768, handled: 1204, failure: PdfRunFailure(PdfRunFailureKind.full))),
        'Stopped: this device is full · 1,204 of 5,768',
      );
      expect(pdfPartLine(const PdfPart(phase: PdfPartPhase.done, total: 5768, handled: 5768)), 'Searchable · 5,768 PDFs');
      expect(pdfPartLine(const PdfPart(phase: PdfPartPhase.newVersion, total: 5790, newCount: 22)), '5,790 PDFs · 22 new, not searchable yet');
      expect(pdfRowNote(const PdfPart(phase: PdfPartPhase.idle, total: 5768)), 'PDFs not searchable yet');
      expect(pdfRowNote(null), isNull);
    });
  });

  test('the timing run logs pages/s, pieces/s and embed ms per piece, and stages nothing', () async {
    final core = FakePdfIndexCore(zims: {'u1': _zim()});
    final r = await runPdfTiming(
      core: core,
      embed: _Embed().call,
      model: _model,
      zimPath: zimPath,
      list: await core.zimPdfs('u1'),
      logDir: Directory('${dir.path}/logs'),
      readPages: readFakePdfPages,
      count: 3,
    );
    expect(r.rows, hasLength(3));
    expect(core.calls.where((c) => c == 'open' || c.startsWith('add:') || c == 'finish'), isEmpty);
    final text = r.log.readAsStringSync();
    expect(text, contains('# pages_per_s'));
    expect(text, contains('# pieces_per_s'));
    expect(text, contains('# embed_ms_per_piece'));
    expect(text, contains('# whole_zim_extrapolated_hours'));
    expect(PdfIndexPaths(zimPath).partial.existsSync(), isFalse);
  });

  group('the part and the pop-up', () {
    Widget host(Widget child) => MaterialApp(theme: buildTheme(CacheThemeId.light), home: Scaffold(body: child));

    testWidgets('one control a state: Make searchable, Pause, Resume with Remove, Free space, none when done', (tester) async {
      var started = 0, paused = 0;
      Future<void> pump(PdfPart p) => tester.pumpWidget(host(PdfPartView(part: p, onStart: () => started++, onPause: () => paused++, onResume: () {}, onRemove: () async {}, onFreeSpace: () {})));
      await pump(const PdfPart(phase: PdfPartPhase.idle, total: 5768));
      await tester.tap(find.text('Make searchable'));
      expect(started, 1);
      await pump(const PdfPart(phase: PdfPartPhase.running, total: 5768, handled: 10));
      await tester.tap(find.text('Pause'));
      expect(paused, 1);
      await pump(const PdfPart(phase: PdfPartPhase.paused, total: 5768, handled: 10, pause: PdfPause.person));
      expect(find.text('Resume'), findsOneWidget);
      expect(find.byKey(const ValueKey('pdfindex-remove')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('pdfindex-remove')));
      await tester.pumpAndSettle();
      expect(find.text('Remove the 10 PDFs already done?'), findsOneWidget);
      await tester.tap(find.text('Keep'));
      await tester.pumpAndSettle();
      await pump(const PdfPart(phase: PdfPartPhase.failed, total: 5768, handled: 10, failure: PdfRunFailure(PdfRunFailureKind.full)));
      expect(find.text('Free space'), findsOneWidget);
      await pump(const PdfPart(phase: PdfPartPhase.done, total: 5768, handled: 5768, unreadable: 12));
      expect(find.text('12 could not be read'), findsOneWidget);
      expect(find.byType(TextButton), findsNothing);
      await pump(const PdfPart(phase: PdfPartPhase.newVersion, total: 5790, newCount: 22));
      expect(find.text('Update search'), findsOneWidget);
    });

    testWidgets('the pop-up: range, space, charging advice; not enough room makes Start "Free space"', (tester) async {
      const ok = PdfEstimate(pdfs: 5768, low: Duration(hours: 5), high: Duration(hours: 8), indexBytes: 1288490189, needBytes: 2576980378, usable: 40 << 30);
      await tester.pumpWidget(host(const PdfIndexConfirm(estimate: ok)));
      expect(find.text('Make 5,768 PDFs searchable?'), findsOneWidget);
      expect(find.text('About 5 to 8 hr. Uses about 1.2 GB.'), findsOneWidget);
      expect(find.text('Plug in to go faster and save battery.'), findsOneWidget);
      expect(find.text('This is a guess until it has run a few minutes.'), findsOneWidget);
      expect(find.text('Start'), findsOneWidget);
      const short = PdfEstimate(pdfs: 5768, low: Duration(hours: 5), high: Duration(hours: 8), indexBytes: 1288490189, needBytes: 2576980378, usable: 429496730);
      await tester.pumpWidget(host(const PdfIndexConfirm(estimate: short)));
      expect(find.text('Free space'), findsOneWidget);
      expect(find.text('Needs 2.4 GB. 410 MB free.'), findsOneWidget);
      expect(find.byKey(const ValueKey('pdfindex-short')), findsOneWidget);
    });

    testWidgets('the line under search results: one library, several, and while running', (tester) async {
      const a = PdfZimRef(path: '/z/a.zim', uuid: 'a', title: 'Where There Is No Doctor');
      const b = PdfZimRef(path: '/z/b.zim', uuid: 'b', title: 'Survival');
      PdfZimRef? opened;
      List<PdfZimRef>? hidden;
      Future<void> pump(List<(PdfZimRef, PdfPart)> pending) =>
          tester.pumpWidget(host(PdfSearchNoteView(pending: pending, open: (z) => opened = z, hide: (l) => hidden = l)));
      await pump([(a, const PdfPart(phase: PdfPartPhase.idle, total: 10))]);
      expect(find.textContaining('PDFs in Where There Is No Doctor are not searchable yet.'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('pdfindex-note-link')));
      expect(opened, a);
      await tester.tap(find.byKey(const ValueKey('pdfindex-note-close')));
      expect(hidden, [a]);
      await pump([(a, const PdfPart(phase: PdfPartPhase.idle, total: 10)), (b, const PdfPart(phase: PdfPartPhase.idle, total: 3)), (const PdfZimRef(path: '/z/c.zim', uuid: 'c', title: 'C'), const PdfPart(phase: PdfPartPhase.newVersion, total: 3))]);
      expect(find.textContaining('PDFs in 3 libraries are not searchable yet.'), findsOneWidget);
      await pump([(a, const PdfPart(phase: PdfPartPhase.running, total: 10, handled: 4))]);
      expect(find.text('PDFs in Where There Is No Doctor: 40% searchable'), findsOneWidget);
      expect(find.byKey(const ValueKey('pdfindex-note-link')), findsNothing);
      await pump(const []);
      expect(find.byKey(const ValueKey('pdfindex-note')), findsNothing);
    });
  });
}
