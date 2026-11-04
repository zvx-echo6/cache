import 'dart:async';
import 'dart:io';

import 'package:cache/pdf/index/pdf_diagnostics.dart';
import 'package:cache/pdf/index/pdf_index_core.dart';
import 'package:cache/pdf/index/pdf_index_fake.dart';
import 'package:cache/pdf/index/pdf_index_state.dart';
import 'package:cache/platform/app_log.dart';
import 'package:cache/platform/memory.dart';
import 'package:cache_search/cache_search.dart' show CacheSearchException;
import 'package:flutter_test/flutter_test.dart';

class _BlockedListing extends FakePdfIndexCore {
  final listed = Completer<ZimPdfList>();

  @override
  Future<ZimPdfList> zimPdfs(String zimId) => listed.future;
}

void main() {
  test('a wait before the first PDF is visible in Details, and its timer stops when the call completes', () async {
    const job = 'zim-pdf/diagnostic-wait';
    final done = Completer<int>();
    final result = tracePdfOperation(
      'Listing PDFs',
      () => done.future,
      job: job,
      memory: () async => 'footprint 200 MB',
      pendingEvery: const Duration(milliseconds: 5),
    );
    expect(appLog.jobLines(job).join(), contains('Listing PDFs starts'));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(appLog.jobLines(job).join(), contains('still waiting'));
    done.complete(37);
    expect(await result, 37);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final lines = appLog.jobLines(job);
    expect(lines.join(), contains('Listing PDFs done'));
    await Future<void>.delayed(const Duration(milliseconds: 15));
    expect(appLog.jobLines(job), lines, reason: 'a completed call leaves no diagnostic timer running');
  });

  test('a core failure keeps its original exception and its machine code in job Details', () async {
    const failure = CacheSearchException('io', 'private/path.zim could not be read');
    const job = 'zim-pdf/diagnostic-error';
    await expectLater(tracePdfOperation<void>('Listing PDFs', () async => throw failure, memory: () async => 'memory', job: job), throwsA(same(failure)));
    final lines = appLog.jobLines(job).join();
    expect(lines, contains('Listing PDFs failed (io)'));
    expect(lines, isNot(contains('private/path.zim')), reason: 'Standard does not disclose file paths');
  });

  test('background discovery exposes its early step and logs the error that used to be swallowed', () async {
    final root = Directory.systemTemp.createTempSync('pdf-diagnostics');
    final core = _BlockedListing();
    final zim = PdfZimRef(path: '${root.path}/wiki.zim', uuid: 'diagnostic-list', title: 'Wikipedia');
    final state = PdfIndexState(
      core: core,
      zims: () => [zim],
      indexesDir: () async => Directory('${root.path}/indexes'),
      recordFile: () async => File('${root.path}/pdf-index.json'),
      autoStart: null,
      watchEvery: const Duration(hours: 1),
    );
    try {
      await state.init();
      expect(state.stepOf(zim), 'Listing PDFs');
      final progress = state.stepsOf(zim);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(state.stepsOf(zim), progress, reason: 'waiting is not real progress for the watchdog');
      core.listed.completeError(const CacheSearchException('damaged', 'archive error'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(appLog.jobLines('zim-pdf/diagnostic-list').join(), contains('The PDF list could not be read'));
    } finally {
      state.dispose();
      root.deleteSync(recursive: true);
    }
  });

  test('iOS diagnostics distinguish app memory headroom from physical device capacity', () {
    const reading = MemoryReading(avail: 2048 << 20, total: 8192 << 20, appScoped: true, footprint: 200 << 20, resident: 120 << 20, compressed: 40 << 20);
    expect(reading.toString(), contains('footprint 200 MB'));
    expect(reading.toString(), contains('RSS 120 MB'));
    expect(reading.toString(), contains('app room 2048 MB'));
    expect(reading.toString(), contains('device 8192 MB'));
    expect(reading.toString(), isNot(contains('free 2048 MB')));
    expect(reading.room, 2048 << 20);
  });
}
