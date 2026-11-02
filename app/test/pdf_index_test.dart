import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cache/platform/battery.dart';
import 'package:cache/pdf/index/pdf_index_core.dart';
import 'package:cache/pdf/index/pdf_index_fake.dart';
import 'package:cache/pdf/index/pdf_index_run.dart';
import 'package:cache/pdf/index/pdf_index_state.dart';
import 'package:cache/pdf/index/pdf_index_ui.dart';
import 'package:cache/pdf/index/pdf_pages.dart';
import 'package:cache/pdf/index/pdf_timing.dart';
import 'package:cache/settings/space.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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

/// Reads pages as the fake does, and calls [onRead] with the count of PDFs read so far (to pause or cancel mid-run).
PdfBytesReader _reader(void Function(int n) onRead) {
  var n = 0;
  return (Uint8List bytes, String name, {PdfPermit? betweenPages}) async {
    n++;
    onRead(n);
    return readFakePdfPages(bytes, name, betweenPages: betweenPages);
  };
}

/// Stands in for a native crash inside PDFium (which in the app ends the process).
class _Crash implements Exception {
  const _Crash();
}

void main() {
  late Directory dir;
  late String zimPath;
  late String indexes;
  late PdfIndexPaths paths;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('pdfindex');
    zimPath = '${dir.path}/guide.zim';
    File(zimPath).writeAsStringSync('zim');
    indexes = '${dir.path}/shared-indexes';
    paths = PdfIndexPaths(indexes, 'u1');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<ZimPdfList> list(FakePdfIndexCore core) => core.zimPdfs('u1');

  group('the driver', () {
    test('indexes every PDF with text (text pieces, no vectors), skips locked, damaged and textless ones, and publishes a snapshot', () async {
      final core = FakePdfIndexCore(zims: {'u1': _zim()});
      final run = PdfIndexRun(core: core, paths: paths, zimName: 'guide', list: await list(core), readPages: readFakePdfPages);
      expect(await run.run(), PdfRunEnd.finished);
      expect(core.calls, [
        'open',
        'add:A/one.pdf',
        'skip:A/locked.pdf:locked',
        'skip:A/broken.pdf:damaged',
        'skip:A/scan.pdf:no_text',
        'add:A/two.pdf',
        'commit',
        'close',
        'finish',
      ]);
      expect(run.done, 2);
      expect(run.skipped, 3);
      // Two pieces on page 1 (200 words, then the rest with 40 words of overlap), one on page 2, one for the second PDF.
      expect(run.pieces, 4);
      expect(paths.build.existsSync(), isFalse);
      final snap = paths.current()!;
      expect(snap.id, run.result?['snapshot']);
      expect(snap.pdfs, 2);
      expect(snap.skipped, 3);
      expect(snap.pieces, 4);
      // Only the snapshot is left in the index folder: no build, no temporary folder.
      expect(paths.root.listSync().map((e) => e.path.split(Platform.pathSeparator).last), ['snap']);
    });

    test('a pause keeps the build; the next run starts from the committed done list', () async {
      final core = FakePdfIndexCore(zims: {'u1': _zim()});
      late PdfIndexRun run;
      // Pause while the last PDF is read: the four before it are added or skipped, and close commits them.
      run = PdfIndexRun(core: core, paths: paths, zimName: 'guide', list: await list(core), readPages: _reader((n) {
        if (n == 5) run.stop(PdfRunStop.person);
      }));
      expect(await run.run(), PdfRunEnd.paused);
      expect(paths.build.existsSync(), isTrue);
      expect(core.calls.where((c) => c.startsWith('add:')), ['add:A/one.pdf']);
      expect(core.calls.sublist(core.calls.length - 2), ['commit', 'close']);

      core.calls.clear();
      final again = PdfIndexRun(core: core, paths: paths, zimName: 'guide', list: await list(core), readPages: readFakePdfPages);
      expect(await again.run(), PdfRunEnd.finished);
      expect(core.calls, ['open', 'add:A/two.pdf', 'commit', 'close', 'finish']);
      expect(again.done, 2);
      expect(again.skipped, 3);
    });

    test('a kill loses only the uncommitted batch: the next run redoes those PDFs', () async {
      final core = FakePdfIndexCore(zims: {'u1': _zim()}, batch: 1);
      final s = await core.open(indexesDir: indexes, zimUuid: 'u1', zimName: 'guide');
      final added = await core.add(s.session, path: 'A/one.pdf', title: 'One', pieces: [
        {'i': 0, 'text': 'water', 'page': '1', 'pdf_page': 1, 'heading_path': <String>[]},
      ]);
      expect(added.committed, 1);
      await core.skip(s.session, path: 'A/locked.pdf', reason: PdfSkipReason.locked);
      core.kill(s.session);
      core.calls.clear();
      final run = PdfIndexRun(core: core, paths: paths, zimName: 'guide', list: await list(core), readPages: readFakePdfPages);
      expect(await run.run(), PdfRunEnd.finished);
      // one.pdf was committed; the skip of locked.pdf was not, so it is read again.
      expect(core.calls.where((c) => c.startsWith('add:') || c.startsWith('skip:')), [
        'skip:A/locked.pdf:locked',
        'skip:A/broken.pdf:damaged',
        'skip:A/scan.pdf:no_text',
        'add:A/two.pdf',
      ]);
    });

    test('a native crash while reading a PDF (the app ended): the next run skips that PDF as damaged and goes on', () async {
      final core = FakePdfIndexCore(zims: {'u1': _zim()});
      final note = File('${dir.path}/support/pdf-index-attempt-u1.json');
      // The first run reads one.pdf, then "crashes" inside two.pdf's extraction: the note stays, nothing after it happens.
      final first = PdfIndexRun(core: core, paths: paths, zimName: 'guide', list: await list(core), attemptFile: note, readPages: _reader((n) {
        if (n == 5) {
          expect(note.existsSync(), isTrue, reason: 'written before extraction');
          throw const _Crash();
        }
      }));
      expect(await first.run(), PdfRunEnd.failed);
      // A real crash ends the process before anything runs: the note is put back as it would be left.
      note.writeAsStringSync('{"zim_uuid":"u1","path":"A/two.pdf"}', flush: true);
      core.calls.clear();
      final again = PdfIndexRun(core: core, paths: paths, zimName: 'guide', list: await list(core), attemptFile: note, readPages: readFakePdfPages);
      expect(await again.run(), PdfRunEnd.finished);
      expect(core.calls.where((c) => c.startsWith('add:') || c.startsWith('skip:')), ['skip:A/two.pdf:damaged']);
      expect(again.skipped, 4);
      expect(note.existsSync(), isFalse);
      expect(paths.current()!.skipped, 4, reason: 'it counts as could not be read');
    });

    test('a PDF read normally leaves no note behind (a pause after it is no crash)', () async {
      final core = FakePdfIndexCore(zims: {'u1': _zim()});
      final note = File('${dir.path}/support/pdf-index-attempt-u1.json');
      late PdfIndexRun run;
      run = PdfIndexRun(core: core, paths: paths, zimName: 'guide', list: await list(core), attemptFile: note, readPages: _reader((n) {
        if (n == 2) run.stop(PdfRunStop.person);
      }));
      expect(await run.run(), PdfRunEnd.paused);
      expect(note.existsSync(), isFalse);
    });

    test('the throttle is asked before each PDF and between the pages of one, and a pause during a wait stops at once', () async {
      final core = FakePdfIndexCore(zims: {'u1': _zim()});
      var asks = 0;
      final run = PdfIndexRun(core: core, paths: paths, zimName: 'guide', list: await list(core), readPages: readFakePdfPages, permit: () async => asks++);
      expect(await run.run(), PdfRunEnd.finished);
      // Five PDFs, and one more between the two pages of each two-page PDF read (one.pdf, scan.pdf).
      expect(asks, 7);
      final waiting = Completer<void>();
      late PdfIndexRun held;
      var calls = 0;
      held = PdfIndexRun(core: FakePdfIndexCore(zims: {'u1': _zim()}), paths: PdfIndexPaths(indexes, 'u9'), zimName: 'guide', list: await list(core), readPages: readFakePdfPages, permit: () {
        calls++;
        // Held between one.pdf's pages: the person pauses during the wait.
        if (calls == 2) {
          held.stop(PdfRunStop.person);
          waiting.complete();
        }
        return Future<void>.value();
      });
      expect(await held.run(), PdfRunEnd.paused);
      expect(waiting.isCompleted, isTrue);
    });

    test('cancel discards the build', () async {
      final core = FakePdfIndexCore(zims: {'u1': _zim()});
      late PdfIndexRun run;
      run = PdfIndexRun(core: core, paths: paths, zimName: 'guide', list: await list(core), readPages: _reader((n) {
        if (n == 2) run.stop(PdfRunStop.cancel);
      }));
      expect(await run.run(), PdfRunEnd.cancelled);
      expect(core.calls.last, 'discard');
      expect(paths.build.existsSync(), isFalse);
      expect(paths.snapshots(), isEmpty);
    });

    test('a low battery on battery pauses; plugged in it does not', () async {
      final core = FakePdfIndexCore(zims: {'u1': _zim()});
      final low = PdfIndexRun(
        core: core,
        paths: paths,
        zimName: 'guide',
        list: await list(core),
        readPages: readFakePdfPages,
        battery: () async => const BatteryReading(percent: 15, charging: false),
      );
      expect(await low.run(), PdfRunEnd.paused);
      expect(low.stopped, PdfRunStop.battery);
      final plugged = PdfIndexRun(
        core: core,
        paths: paths,
        zimName: 'guide',
        list: await list(core),
        readPages: readFakePdfPages,
        battery: () async => const BatteryReading(percent: 15, charging: true),
      );
      expect(await plugged.run(), PdfRunEnd.finished);
    });

    test('a full device stops with "this device is full"; the build stays for a resume', () async {
      final core = FakePdfIndexCore(zims: {'u1': _zim()}, failAddWith: const FileSystemException('write', 'x', OSError('No space left on device', 28)));
      final run = PdfIndexRun(core: core, paths: paths, zimName: 'guide', list: await list(core), readPages: readFakePdfPages);
      expect(await run.run(), PdfRunEnd.failed);
      expect(run.failure?.kind, PdfRunFailureKind.full);
      expect(pdfStopWords(run.failure!), 'this device is full');
      expect(paths.build.existsSync(), isTrue);
    });
    test('a new edition reuses the unchanged PDFs of the previous snapshot and reads only the new or changed ones', () async {
      // Edition 1 (u1) is indexed; edition 2 (u2, the same metadata Name) changes two.pdf and adds three.pdf.
      final core = FakePdfIndexCore(zims: {
        'u1': _zim(),
        'u2': FakeZim(uuid: 'u2', name: 'guide', pdfs: [
          FakePdf('A/one.pdf', title: 'One', pages: [_words(250), _words(30, 'fire')]),
          const FakePdf('A/locked.pdf', locked: true),
          FakePdf('A/two.pdf', pages: [_words(140, 'shelter')]),
          FakePdf('A/three.pdf', pages: [_words(20, 'rope')]),
        ]),
      });
      expect(await PdfIndexRun(core: core, paths: paths, zimName: 'guide', list: await list(core), readPages: readFakePdfPages).run(), PdfRunEnd.finished);
      core.calls.clear();
      final next = PdfIndexPaths(indexes, 'u2');
      final run = PdfIndexRun(core: core, paths: next, zimName: 'guide', previousZimUuid: 'u1', list: await core.zimPdfs('u2'), readPages: readFakePdfPages);
      expect(await run.run(), PdfRunEnd.finished);
      expect(core.calls.where((c) => !c.startsWith('commit')), [
        'open',
        'reuse:A/one.pdf',
        'skip:A/locked.pdf:locked',
        // two.pdf has another size: not offered for reuse, read again.
        'add:A/two.pdf',
        'add:A/three.pdf',
        'close',
        'finish',
      ]);
      expect(run.reused, 1);
      expect(next.current()!.pdfs, 3);
    });

    test('low storage stops the run with "this device is full"', () async {
      final core = FakePdfIndexCore(zims: {'u1': _zim()});
      final run = PdfIndexRun(core: core, paths: paths, zimName: 'guide', list: await list(core), readPages: readFakePdfPages, spaceOk: () => false);
      expect(await run.run(), PdfRunEnd.failed);
      expect(run.failure?.kind, PdfRunFailureKind.full);
    });
  });

  group('snapshots', () {
    void snapshot(String id, {required String uuid, required String created, bool whole = true}) {
      final d = Directory('${PdfIndexPaths(indexes, uuid).snaps.path}/$id')..createSync(recursive: true);
      File('${d.path}/seg').writeAsStringSync(whole ? 'abcd' : 'ab');
      File('${d.path}/manifest.json').writeAsStringSync(
        '{"zim_uuid":"$uuid","created":"$created","pdfs":3,"pieces":9,"skipped":1,"files":[{"path":"seg","size":4,"sha256":"x"}]}',
      );
    }

    test('every device picks the same one: the earliest created, then the lowest build id; a half-arrived one does not count', () {
      snapshot('b2', uuid: 'u1', created: '2026-11-02T01:00:00Z');
      snapshot('b1', uuid: 'u1', created: '2026-11-02T01:00:00Z');
      snapshot('a0', uuid: 'u1', created: '2026-11-02T02:00:00Z');
      snapshot('a1', uuid: 'u1', created: '2026-11-01T00:00:00Z', whole: false);
      snapshot('c0', uuid: 'old', created: '2026-10-01T00:00:00Z');
      expect(paths.current()?.id, 'b1');
      expect(PdfIndexPaths(indexes, 'old').current()?.id, 'c0');
      expect(PdfIndexPaths(indexes, 'none').current(), isNull);
      expect(paths.snapshots().map((s) => s.id).toSet(), {'b2', 'b1', 'a0'});
    });

    test("the folders are the ZIM uuid's in the device's indexes folder", () {
      String rel(Directory d) => d.path.substring(indexes.length + 1).replaceAll(Platform.pathSeparator, '/');
      expect([rel(paths.root), rel(paths.build), rel(paths.snaps)], ['zim-pdf/u1', 'zim-pdf/u1/.build', 'zim-pdf/u1/snap']);
    });
  });

  group('the state (always on)', () {
    late FakePdfIndexCore core;
    late PdfIndexState state;
    late List<PdfZimRef> zims;
    BatteryReading? batteryNow;
    var free = 100 << 30;
    final changes = ValueNotifier(0);

    PdfIndexState make({PdfIndexCore? withCore}) => PdfIndexState(
      core: withCore ?? core,
      zims: () => zims,
      changes: changes,
      indexesDir: () async => Directory(indexes),
      recordFile: () async => File('${dir.path}/support/pdf-index.json'),
      readPages: readFakePdfPages,
      battery: () async => batteryNow,
      space: (_) => Space(free: free, reserve: 0),
      watchEvery: const Duration(milliseconds: 200),
    );

    Future<PdfPart?> until(PdfZimRef z, bool Function(PdfPart p) ok) async {
      PdfPart? p;
      for (var i = 0; i < 400; i++) {
        p = state.partOf(z);
        if (p != null && ok(p)) return p;
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      return p;
    }

    Future<void> renew() async {
      final fresh = make();
      await fresh.init();
      state.dispose();
      state = fresh;
    }

    setUp(() {
      core = FakePdfIndexCore(zims: {'u1': _zim()});
      zims = [PdfZimRef(path: zimPath, uuid: 'u1', title: 'Guide')];
      batteryNow = null;
      free = 100 << 30;
    });
    tearDown(() => state.dispose());

    test('nothing shows while the core cannot index PDFs', () async {
      state = make(withCore: const PdfIndexCoreMissing());
      await state.init();
      expect(state.partOf(zims.single), isNull);
      expect(state.pending(), isEmpty);
    });

    test('a ZIM with PDFs is made searchable by itself; the record says this device built it', () async {
      state = make();
      await state.init();
      final z = zims.single;
      final done = (await until(z, (p) => p.phase == PdfPartPhase.done))!;
      expect(done.phase, PdfPartPhase.done);
      expect(done.fromOtherDevice, isFalse);
      expect(pdfPartLine(done), 'PDFs: searching ready');
      expect(done.unreadable, 3);
      expect(state.pending(), isEmpty);
      expect(core.calls, contains('finish'));
      await renew();
      expect((await until(z, (p) => p.phase == PdfPartPhase.done))?.fromOtherDevice, isFalse);
    });

    test('nothing to do when a snapshot for the edition is here (arrived from another device)', () async {
      final elsewhere = PdfIndexPaths('${dir.path}/elsewhere', 'u1');
      final other = FakePdfIndexCore(zims: {'u1': _zim()});
      expect(await PdfIndexRun(core: other, paths: elsewhere, zimName: 'guide', list: await other.zimPdfs('u1'), readPages: readFakePdfPages).run(), PdfRunEnd.finished);
      paths.root.parent.createSync(recursive: true);
      elsewhere.root.renameSync(paths.root.path);
      state = make();
      await state.init();
      final p = (await until(zims.single, (p) => p.phase == PdfPartPhase.done))!;
      expect(p.fromOtherDevice, isTrue);
      expect(core.calls.where((c) => c == 'open'), isEmpty, reason: 'nothing is indexed here');
    });

    test('not enough room: the state says what it needs, with Free space; it starts once there is room', () async {
      free = 0;
      state = make();
      await state.init();
      final z = zims.single;
      final p = (await until(z, (p) => p.phase == PdfPartPhase.needsSpace))!;
      expect(pdfPartLine(p), startsWith('Needs '));
      expect(pdfPartLine(p), endsWith(' free'));
      expect(core.calls.where((c) => c == 'open'), isEmpty);
      free = 100 << 30;
      expect((await until(z, (p) => p.phase == PdfPartPhase.done))?.phase, PdfPartPhase.done);
    });

    test('a low battery on battery pauses it ("Paused, battery low"); charging, it goes on by itself', () async {
      batteryNow = const BatteryReading(percent: 10, charging: false);
      state = make();
      await state.init();
      final z = zims.single;
      final p = (await until(z, (p) => p.phase == PdfPartPhase.paused))!;
      expect(pdfPartLine(p), 'Paused, battery low');
      batteryNow = const BatteryReading(percent: 10, charging: true);
      expect((await until(z, (p) => p.phase == PdfPartPhase.done))?.phase, PdfPartPhase.done);
    });

    test("the person's Pause holds until Resume", () async {
      state = make();
      state.autoStart = null;
      await state.init();
      final z = zims.single;
      await state.listOf(z);
      await state.pause(z);
      state.autoStart = pdfAutoStartAlways;
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(state.partOf(z)?.pause, PdfPause.person);
      expect(core.calls.where((c) => c == 'open'), isEmpty);
      await state.resume(z);
      expect((await until(z, (p) => p.phase == PdfPartPhase.done))?.phase, PdfPartPhase.done);
    });

    test('a new edition is indexed by itself, reusing the old one, whose index then goes', () async {
      state = make();
      await state.init();
      await until(zims.single, (p) => p.phase == PdfPartPhase.done);
      // The update: guide.zim is now edition u2 (same metadata Name), the old file gone.
      core.zims['u2'] = FakeZim(uuid: 'u2', name: 'guide', pdfs: _zim(uuid: 'u2').pdfs);
      zims = [PdfZimRef(path: '${dir.path}/guide-2.zim', uuid: 'u2', title: 'Guide')];
      changes.value++;
      final next = PdfIndexPaths(indexes, 'u2');
      expect((await until(zims.single, (p) => p.phase == PdfPartPhase.done))?.phase, PdfPartPhase.done);
      expect(core.calls.where((c) => c.startsWith('reuse:')), isNotEmpty);
      expect(next.current(), isNotNull);
      // The old edition goes once the new one's publish is recorded, a moment after it shows as ready (bounded wait).
      for (var i = 0; i < 80 && paths.root.existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      expect(paths.root.existsSync(), isFalse, reason: 'the old edition, which no ZIM here uses, is removed');
    });

    test('a ZIM that goes takes its index with it, on this device', () async {
      state = make();
      await state.init();
      await until(zims.single, (p) => p.phase == PdfPartPhase.done);
      expect(paths.current(), isNotNull);
      zims = [];
      changes.value++;
      for (var i = 0; i < 40 && paths.root.existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      expect(paths.root.existsSync(), isFalse);
    });

    test('the line under search results while in progress, and hidden when closed', () async {
      state = make();
      state.autoStart = null;
      await state.init();
      final z = zims.single;
      await state.listOf(z);
      final pending = state.pending();
      expect(pending.single.$1.title, 'Guide');
      expect(pdfStillLine(z, pending.single.$2), "Still making Guide's PDFs searchable (0 of 5)");
      await state.hideNote([z]);
      expect(state.pending(), isEmpty);
    });
  });

  group('words', () {
    test('every state has its line', () {
      expect(pdfPartLine(const PdfPart(phase: PdfPartPhase.done, total: 5768, handled: 5768)), 'PDFs: searching ready');
      expect(pdfPartLine(const PdfPart(phase: PdfPartPhase.running, total: 5768, handled: 340)), 'Making PDFs searchable: 340 of 5,768');
      expect(pdfPartLine(const PdfPart(phase: PdfPartPhase.paused, total: 5768, handled: 340, pause: PdfPause.battery)), 'Paused, battery low');
      expect(pdfPartLine(const PdfPart(phase: PdfPartPhase.paused, total: 5768, handled: 340, pause: PdfPause.person)), 'Paused · 340 of 5,768');
      expect(pdfPartLine(const PdfPart(phase: PdfPartPhase.needsSpace, total: 5768, needBytes: 1288490189)), 'Needs 1.2 GB free');
      expect(pdfPartLine(const PdfPart(phase: PdfPartPhase.waiting, total: 5768)), 'Waiting to make PDFs searchable');
      // A new edition reusing its older one: the PDFs it does not hold.
      expect(pdfPartLine(const PdfPart(phase: PdfPartPhase.running, total: 5790, handled: 5768, newCount: 22)), 'Making PDFs searchable: 5,768 of 5,790 · 22 new PDFs');
      expect(pdfPartLine(const PdfPart(phase: PdfPartPhase.waiting, total: 5790, newCount: 1)), 'Waiting to make PDFs searchable · 1 new PDF');
      expect(pdfRowNote(const PdfPart(phase: PdfPartPhase.running, total: 5768)), 'Making PDFs searchable');
      expect(pdfRowNote(const PdfPart(phase: PdfPartPhase.done, total: 5768)), isNull);
      expect(pdfRowNote(null), isNull);
    });
  });

  test('the timing run logs pages/s and ms a PDF for extract, chunk and add, in a build it then discards', () async {
    final core = FakePdfIndexCore(zims: {'u1': _zim()});
    final r = await runPdfTiming(core: core, paths: paths, zimName: 'guide', list: await core.zimPdfs('u1'), logDir: Directory('${dir.path}/logs'), readPages: readFakePdfPages, count: 3);
    expect(r.rows, hasLength(3));
    expect(r.staged, isTrue);
    expect(core.calls, ['open', 'add:A/one.pdf', 'skip:A/locked.pdf:locked', 'skip:A/broken.pdf:damaged', 'commit', 'close', 'discard']);
    final text = r.log.readAsStringSync();
    expect(text, contains('# pages_per_s'));
    expect(text, contains('# ms_per_pdf\tread\t'));
    expect(text, contains('\tadd\t'));
    expect(text, contains('# whole_zim_extrapolated_hours'));
    expect(paths.build.existsSync(), isFalse);
    expect(paths.snapshots(), isEmpty);
    // A build in progress is left alone: nothing staged, add not timed.
    paths.build.createSync(recursive: true);
    core.calls.clear();
    final r2 = await runPdfTiming(core: core, paths: paths, zimName: 'guide', list: await core.zimPdfs('u1'), logDir: Directory('${dir.path}/logs'), readPages: readFakePdfPages, count: 2);
    expect(r2.staged, isFalse);
    expect(core.calls, isEmpty);
    expect(paths.build.existsSync(), isTrue);
  });

  group('the part and the note', () {
    Widget host(Widget child) => MaterialApp(theme: buildTheme(CacheThemeId.light), home: Scaffold(body: child));

    testWidgets('a status, not an action: Pause while running, Resume when paused, Free space when there is no room, none when ready', (tester) async {
      var paused = 0, resumed = 0, freed = 0;
      Future<void> pump(PdfPart p) => tester.pumpWidget(host(PdfPartView(part: p, onPause: () => paused++, onResume: () => resumed++, onFreeSpace: () => freed++)));
      await pump(const PdfPart(phase: PdfPartPhase.running, total: 5768, handled: 340));
      expect(find.text('Making PDFs searchable: 340 of 5,768'), findsOneWidget);
      await tester.tap(find.text('Pause'));
      expect(paused, 1);
      await pump(const PdfPart(phase: PdfPartPhase.paused, total: 5768, handled: 340, pause: PdfPause.battery));
      expect(find.text('Paused, battery low'), findsOneWidget);
      await tester.tap(find.text('Resume'));
      expect(resumed, 1);
      await pump(const PdfPart(phase: PdfPartPhase.needsSpace, total: 5768, needBytes: 1288490189));
      expect(find.text('Needs 1.2 GB free'), findsOneWidget);
      await tester.tap(find.text('Free space'));
      expect(freed, 1);
      await pump(const PdfPart(phase: PdfPartPhase.done, total: 5768, handled: 5768, unreadable: 12));
      expect(find.text('PDFs: searching ready'), findsOneWidget);
      expect(find.text('12 could not be read'), findsOneWidget);
      expect(find.byType(TextButton), findsNothing);
      await pump(const PdfPart(phase: PdfPartPhase.waiting, total: 5768));
      expect(find.byType(TextButton), findsNothing);
      expect(find.text('Make searchable'), findsNothing);
    });

    testWidgets('the line under search results: one per library in progress, with its close mark', (tester) async {
      const a = PdfZimRef(path: '/z/a.zim', uuid: 'a', title: 'Where There Is No Doctor');
      const b = PdfZimRef(path: '/z/b.zim', uuid: 'b', title: 'Survival');
      PdfZimRef? opened;
      List<PdfZimRef>? hidden;
      Future<void> pump(List<(PdfZimRef, PdfPart)> pending) =>
          tester.pumpWidget(host(PdfSearchNoteView(pending: pending, open: (z) => opened = z, hide: (l) => hidden = l)));
      await pump([(a, const PdfPart(phase: PdfPartPhase.running, total: 5768, handled: 340)), (b, const PdfPart(phase: PdfPartPhase.waiting, total: 9))]);
      expect(find.text("Still making Where There Is No Doctor's PDFs searchable (340 of 5,768)"), findsOneWidget);
      expect(find.text("Still making Survival's PDFs searchable (0 of 9)"), findsOneWidget);
      await tester.tap(find.text("Still making Survival's PDFs searchable (0 of 9)"));
      expect(opened, b);
      await tester.tap(find.byKey(const ValueKey('pdfindex-note-close-a.zim')));
      expect(hidden, [a]);
      await pump(const []);
      expect(find.byKey(const ValueKey('pdfindex-note')), findsNothing);
    });
  });
}
