import 'dart:io';
import 'dart:typed_data';

import 'package:cache/pdf/index/battery.dart';
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
  return (Uint8List bytes, String name) async {
    n++;
    onRead(n);
    return readFakePdfPages(bytes, name);
  };
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
      expect(zimPdfFetchOnly(['u1', 'u2']), ['zim-pdf/u1', 'zim-pdf/u2']);
    });
  });

  group('the state', () {
    late FakePdfIndexCore core;
    late PdfIndexState state;
    late List<PdfZimRef> zims;
    final changes = ValueNotifier(0);

    PdfIndexState make({PdfIndexCore? withCore}) => PdfIndexState(
      core: withCore ?? core,
      zims: () => zims,
      changes: changes,
      indexesDir: () async => Directory(indexes),
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

    Future<void> renew() async {
      final fresh = make();
      await fresh.init();
      state.dispose();
      state = fresh;
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
      await renew();
      expect((await settled(z))?.fromOtherDevice, isFalse);
    });

    test('a snapshot that arrived from another device is used at once', () async {
      final z = zims.single;
      await settled(z);
      // Another device built it (the same fake publish), then its snap/<id>/ arrives here by sync.
      final elsewhere = PdfIndexPaths('${dir.path}/elsewhere', 'u1');
      final other = FakePdfIndexCore(zims: {'u1': _zim()});
      final run = PdfIndexRun(core: other, paths: elsewhere, zimName: 'guide', list: await other.zimPdfs('u1'), readPages: readFakePdfPages);
      expect(await run.run(), PdfRunEnd.finished);
      paths.root.parent.createSync(recursive: true);
      elsewhere.root.renameSync(paths.root.path);
      await renew();
      final p = (await settled(z))!;
      expect(p.phase, PdfPartPhase.done);
      expect(p.fromOtherDevice, isTrue);
      expect(pdfPartLine(p), 'Searchable · came from another device');
    });

    test('a build with no pause recorded was cut off: "Paused: Cache was closed"; Remove deletes it', () async {
      final z = zims.single;
      await settled(z);
      paths.build.createSync(recursive: true);
      final p = state.partOf(z)!;
      expect(p.phase, PdfPartPhase.paused);
      expect(p.pause, PdfPause.closed);
      expect(pdfPartLine(p), startsWith('Paused: Cache was closed'));
      await state.remove(z);
      expect(paths.build.existsSync(), isFalse);
      expect(state.partOf(z)!.phase, PdfPartPhase.idle);
    });

    test('a snapshot for another ZIM version only: the new version shows', () async {
      final z = zims.single;
      await settled(z);
      // This file held ZIM version "old", which had an index; it is now version u1.
      final d = Directory('${PdfIndexPaths(indexes, 'old').snaps.path}/old1')..createSync(recursive: true);
      File('${d.path}/manifest.json').writeAsStringSync('{"zim_uuid":"old","created":"2026-10-01T00:00:00Z","pdfs":2,"skipped":0,"files":[]}');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      File('${dir.path}/support/pdf-index.json').writeAsStringSync('{"guide.zim":{"index_uuid":"old","count":5,"count_uuid":"u1"}}');
      await renew();
      final p = (await settled(z))!;
      expect(p.phase, PdfPartPhase.newVersion);
      expect(pdfPartLine(p), '5 PDFs · new version, not searchable yet');
    });

    test('the estimate is timed on this device and checked against the space and the reserve', () async {
      final z = zims.single;
      await settled(z);
      final e = (await state.measure(z))!;
      expect(e.pdfs, 5);
      expect(e.high >= e.low, isTrue);
      expect(e.needBytes, e.indexBytes * 2);
      expect(e.fits, isTrue);
      // Timing stages nothing.
      expect(core.calls.where((c) => c == 'open' || c.startsWith('add:')), isEmpty);
      const tight = PdfEstimate(pdfs: 5, low: Duration.zero, high: Duration.zero, indexBytes: 600 << 20, needBytes: 1200 << 20, usable: 400 << 20);
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

    test('a ZIM that goes takes its index with it, on this device', () async {
      final z = zims.single;
      await settled(z);
      await state.start(z);
      await until(z, PdfPartPhase.done);
      expect(paths.current(), isNotNull);
      zims = [];
      changes.value++;
      for (var i = 0; i < 40 && paths.root.existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      expect(paths.root.existsSync(), isFalse);
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
