import 'dart:io';

import 'package:cache/library/add_pdf/add_pdf_state.dart';
import 'package:cache/platform/app_log.dart';
import 'package:cache_ocr/cache_ocr.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter_test/flutter_test.dart';

import 'add_pdf_fixtures.dart';

void main() {
  late Directory tmp;
  late Directory lib;
  late File pdf;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('add-pdf-state');
    lib = Directory('${tmp.path}/libraries/my-books')..createSync(recursive: true);
    pdf = File('${tmp.path}/picked/Water purification manual.pdf')
      ..createSync(recursive: true)
      ..writeAsBytesSync(List<int>.filled(4096, 0x25));
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  const target = AddPdfTarget(title: 'My books');
  AddPdfTarget at(Directory d) => AddPdfTarget(title: 'My books', path: d.path, isDefault: true);
  final copy = 'ab' * 32;

  Future<AddPdfJob> addOne(AddPdfState s, {bool owns = true}) =>
      s.add(pdfPath: pdf.path, fileName: 'Water purification manual.pdf', bytes: 4096, title: 'Water purification manual', target: at(lib), ownsFile: owns);

  Future<bool> runOnce(AddPdfState s) async {
    final tasks = await s.pending();
    final run = await tasks.single.start();
    return run.finished;
  }

  test('a text PDF: start, steps through reading, embedding and writing, done; the PDF goes beside its book', () async {
    final calls = FakeIngestCalls({
      'step': steps([
        progress('reading', pagesDone: 1),
        progress('embedding', pagesDone: 3, pieces: 10, piecesDone: 4),
        progress('writing', pagesDone: 3, pieces: 10, piecesDone: 10),
        progress('done', pagesDone: 3, pieces: 10, piecesDone: 10, result: {'copy': copy, 'pieces': 10, 'same': const [], 'shelf': {'div': '530', 'by': 'auto'}, 'suggested': {'div': '530', 'score': 0.91}}),
      ]),
    });
    final done = <String>[];
    final s = testAddPdfState(Directory('${tmp.path}/ingest'), calls: calls, onDone: (j) async => done.add(j.id));
    final job = await addOne(s);
    expect(await runOnce(s), isTrue);
    expect(job.status, AddPdfStatus.done);
    expect(job.result?['shelf'], {'div': '530', 'by': 'auto'});
    expect(done, [job.id]);
    final start = calls.argsOf('start').single;
    expect(start['library_dir'], lib.path);
    expect(start['job_dir'], job.jobDir);
    expect((start['opts'] as Map)['title'], 'Water purification manual');
    expect(start['engines'], {'pdfium_version': 'chromium/7811'});
    expect(File('${lib.path}/bookshelf/$copy.pdf').existsSync(), isTrue, reason: 'the picked copy is moved beside its book');
    expect(pdf.existsSync(), isFalse);
    expect(await s.pending(), isEmpty, reason: 'a finished job is not work any more');
  });

  test('needs_ocr: the batch is read with the phone engine and handed back through cs_ingest_ocr', () async {
    final img = File('${tmp.path}/p2.png')..writeAsBytesSync([1, 2, 3]);
    final calls = FakeIngestCalls({
      'step': steps([
        progress('needs_ocr', pagesDone: 1, needsOcr: [
          {'page': 2, 'image_path': img.path, 'width': 2550, 'height': 3300, 'dpi': 300},
        ]),
        progress('embedding', pagesDone: 3, pieces: 4, piecesDone: 1),
        progress('done', pagesDone: 3, pieces: 4, piecesDone: 4, result: {'copy': copy, 'pieces': 4, 'same': const [], 'shelf': null, 'suggested': {'div': '720', 'score': 0.3}}),
      ]),
    });
    final engine = FakeOcrEngine(engine: 'mlkit', version: '16.0.1', pages: {2: 'Boil water for one minute'});
    final s = AddPdfState(calls: calls, dir: () async => Directory('${tmp.path}/ingest'), engines: () async => {}, ocrEngine: () async => engine, permit: (_) async {});
    final job = await addOne(s);
    expect(job.ocr, 'host');
    expect(await runOnce(s), isTrue);
    final ocr = calls.argsOf('ocr').single;
    expect(ocr['engine'], 'mlkit');
    expect(ocr['version'], '16.0.1');
    expect(ocr['pages'], [
      {'page': 2, 'text': 'Boil water for one minute', 'confidence': 0.9},
    ]);
    expect(job.scans, 1);
    expect(job.scansDone, 1);
    expect(job.sawOcr, isTrue);
  });

  test('a page the engine cannot read is logged with its page, code and message, and the job goes on', () async {
    final img = File('${tmp.path}/p2.png')..writeAsBytesSync([1, 2, 3]);
    final calls = FakeIngestCalls({
      'step': steps([
        progress('needs_ocr', pagesDone: 1, needsOcr: [
          {'page': 2, 'image_path': img.path, 'width': 2550, 'height': 3300, 'dpi': 300},
        ]),
        progress('done', pagesDone: 3, pieces: 4, piecesDone: 4, result: {'copy': copy, 'pieces': 4, 'same': const [], 'shelf': null, 'suggested': {'div': '720', 'score': 0.3}}),
      ]),
    });
    final s = AddPdfState(calls: calls, dir: () async => Directory('${tmp.path}/ingest'), engines: () async => {}, ocrEngine: () async => _ThrowingOcrEngine(const OcrException('engine', 'X')), permit: (_) async {});
    final job = await addOne(s);
    expect(await runOnce(s), isTrue);
    final lines = appLog.jobLines(job.key).join('\n');
    expect(lines, contains('1 scanned pages could not be read'));
    expect(lines, contains('scanned page 2 could not be read (engine): X'));
  });

  test('no OCR engine on the device: the job runs with OCR off', () async {
    final calls = FakeIngestCalls({'step': steps([progress('failed', error: {'code': 'no_text', 'message': 'no page has any text'})])});
    final s = testAddPdfState(Directory('${tmp.path}/ingest'), calls: calls);
    final job = await addOne(s);
    expect(job.ocr, 'off');
    expect(await runOnce(s), isFalse);
    expect(job.status, AddPdfStatus.failed);
    expect(addPdfErrorWords(job).title, 'No readable text');
    expect(addPdfErrorWords(job).body, 'This PDF is scans, and reading scanned pages is off.');
    expect((calls.argsOf('start').single['opts'] as Map)['ocr'], 'off');
  });

  test('busy: another PDF is being saved; it waits and tries again by itself', () async {
    final calls = FakeIngestCalls({
      'step': steps([
        const CacheSearchException('busy', 'another job is writing'),
        const CacheSearchException('busy', 'another job is writing'),
        progress('done', result: {'copy': copy, 'pieces': 1, 'same': const [], 'shelf': null}),
      ]),
    });
    final s = testAddPdfState(Directory('${tmp.path}/ingest'), calls: calls);
    final job = await addOne(s);
    expect(await runOnce(s), isTrue);
    expect(job.status, AddPdfStatus.done);
    expect(calls.argsOf('step'), hasLength(3));
  });

  test('a kill: the jobs list is read again and the core is started with the same job_dir (it resumes)', () async {
    final dir = Directory('${tmp.path}/ingest');
    final first = testAddPdfState(dir, calls: FakeIngestCalls());
    final job = await addOne(first);
    await first.save();
    // Cache is killed here; a new start reads the list
    final calls = FakeIngestCalls({
      'start': (_) => {'job': 7, 'resumed': true, 'copy': copy, 'pages': 3},
      'step': steps([progress('done', result: {'copy': copy, 'pieces': 2, 'same': const [], 'shelf': null})]),
    });
    final again = testAddPdfState(dir, calls: calls);
    await again.load();
    expect(again.active.single.id, job.id);
    expect(await runOnce(again), isTrue);
    expect(calls.argsOf('start').single['job_dir'], job.jobDir);
    expect(calls.argsOf('step').first['job'], 7);
  });

  test('a job the core forgot (not_found) is started again from its folder', () async {
    var started = 0;
    final calls = FakeIngestCalls({
      'start': (_) => {'job': ++started, 'resumed': started > 1, 'copy': copy, 'pages': 3},
      'step': steps([const CacheSearchException('not_found', 'no such job'), progress('done', result: {'copy': copy, 'pieces': 2, 'same': const [], 'shelf': null})]),
    });
    final s = testAddPdfState(Directory('${tmp.path}/ingest'), calls: calls);
    await addOne(s);
    expect(await runOnce(s), isTrue);
    expect(started, 2);
  });

  test('errors in plain words: not a PDF, locked, no space with what it needs', () async {
    for (final (code, title) in [('not_pdf', "This file can't be read"), ('damaged', "This file can't be read"), ('locked', 'This PDF has a password')]) {
      final calls = FakeIngestCalls({'start': (_) => throw CacheSearchException(code, code)});
      final s = testAddPdfState(Directory('${tmp.path}/ingest-$code'), calls: calls);
      final job = await addOne(s, owns: false);
      expect(await runOnce(s), isFalse);
      expect(job.errorCode, code);
      expect(addPdfErrorWords(job).title, title);
    }
    final calls = FakeIngestCalls({'step': (_) => throw const CacheSearchException('no_space', 'not enough', needed: 380 << 20, available: 10)});
    final s = testAddPdfState(Directory('${tmp.path}/ingest-space'), calls: calls);
    final job = await addOne(s, owns: false);
    expect(await runOnce(s), isFalse);
    expect(addPdfErrorWords(job).title, 'Needs 380 MB free');
    expect(addPdfErrorWords(job).body, 'Nothing was added. Your PDF was not changed.');
  });

  test('Pause stops after the step it is on and takes it off the work list; Resume puts it back', () async {
    final calls = FakeIngestCalls({'step': steps([progress('reading', pagesDone: 1)])});
    final s = testAddPdfState(Directory('${tmp.path}/ingest'), calls: calls);
    final job = await addOne(s);
    final run = await (await s.pending()).single.start();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await s.pause(job);
    expect(await run.finished, isFalse);
    expect(await s.pending(), isEmpty);
    await s.resume(job);
    expect(await s.pending(), hasLength(1));
  });

  test('Cancel removes the job and its folder through the core, and the picked copy', () async {
    final calls = FakeIngestCalls({'step': steps([progress('reading', pagesDone: 1)])});
    final s = testAddPdfState(Directory('${tmp.path}/ingest'), calls: calls);
    final job = await addOne(s);
    final run = await (await s.pending()).single.start();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await s.cancel(job);
    expect(await run.finished, isFalse);
    expect(calls.argsOf('cancel').single['job'], 1);
    expect(s.jobs, isEmpty);
    expect(pdf.existsSync(), isFalse);
  });

  test('a waiting PDF is long work; Start now and Resume anyway lift the wait', () async {
    final s = testAddPdfState(Directory('${tmp.path}/ingest'));
    final job = await addOne(s);
    expect((await s.pending()).single.long, isTrue);
    await s.startNow(job);
    expect((await s.pending()).single.long, isFalse);
    expect((await s.pending()).single.anyway, isFalse);
    await s.resumeAnyway(job);
    expect((await s.pending()).single.anyway, isTrue);
  });

  test('the estimate is one number from the size', () {
    expect(aboutMinutes(addPdfEstimate(41 << 20)), 'About 4 min');
    expect(aboutMinutes(addPdfEstimate(1 << 20)), 'About 1 min');
    expect(target.isNew, isTrue);
  });

  test('a folder PDF is copied in when its turn comes (not when it is queued); several get their own ids', () async {
    final calls = FakeIngestCalls({'step': steps([progress('done', result: {'copy': copy, 'pieces': 1, 'same': const [], 'shelf': null})])});
    final copied = <String>[];
    final s = AddPdfState(
      calls: calls,
      dir: () async => Directory('${tmp.path}/ingest'),
      engines: () async => {},
      permit: (_) async {},
      copyIn: (j) async {
        copied.add(j.sourcePath!);
        await File(j.pdfPath).writeAsBytes([1, 2, 3]);
      },
    );
    final a = await s.add(pdfPath: 'Water/a.pdf', fileName: 'a.pdf', bytes: 3, title: 'a', target: at(lib), ownsFile: true, folderRoot: '/folder');
    final b = await s.add(pdfPath: 'Radio/b.pdf', fileName: 'b.pdf', bytes: 3, title: 'b', target: at(lib), ownsFile: true, folderRoot: '/folder');
    expect(a.id, isNot(b.id));
    expect(copied, isEmpty, reason: 'nothing is copied while it waits');
    expect(a.pdfPath, startsWith('${tmp.path}/ingest'));
    final run = await (await s.pending()).firstWhere((t) => t.key == a.key).start();
    expect(await run.finished, isTrue);
    expect(copied, ['Water/a.pdf']);
    expect(calls.argsOf('start').single['pdf_path'], a.pdfPath);
  });
}

/// An engine that fails every page with [error].
class _ThrowingOcrEngine extends FakeOcrEngine {
  _ThrowingOcrEngine(this.error);
  final OcrException error;
  @override
  Future<OcrPageText> recognize(OcrPageImage image) async => throw error;
}
