import 'dart:io';

import 'package:cache/browse/zim_download.dart';
import 'package:flutter_test/flutter_test.dart';

import 'zim_download_test.dart' show FakeKiwix, data;

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('storage-test-'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<DownloadResult> download(
    FakeKiwix server,
    File part,
    FreeSpace space,
  ) => ZimDownloader(freeSpace: space).download(url: server.url, part: part);

  test(
    'zero available bytes blocks body transfer and preserves partial data',
    () async {
      final server = FakeKiwix(data(100000));
      await server.start();
      addTearDown(server.stop);
      final part = File('${tmp.path}/f.part')
        ..writeAsBytesSync(server.bytes.sublist(0, 90000));
      final before = part.readAsBytesSync();
      String? checkedPath;

      await expectLater(
        download(server, part, (path) {
          checkedPath = path;
          return 0;
        }),
        throwsA(
          isA<NoSpaceException>()
              .having((e) => e.code, 'code', 'no_space')
              .having((e) => e.available, 'available', 0)
              .having(
                (e) => e.needed,
                'needed',
                10000 + downloadMargin(100000),
              ),
        ),
      );
      expect(checkedPath, part.parent.path);
      expect(server.bodyRequests, 0);
      expect(part.readAsBytesSync(), before);
    },
  );

  test(
    'exactly the remaining bytes and margin allows a resumed download',
    () async {
      final server = FakeKiwix(data(100000));
      await server.start();
      addTearDown(server.stop);
      final part = File('${tmp.path}/f.part')
        ..writeAsBytesSync(server.bytes.sublist(0, 90000));
      final result = await download(
        server,
        part,
        (_) => 10000 + downloadMargin(100000),
      );
      expect(result.bytes, 100000);
      expect(server.rangeHeaders, ['bytes=90000-']);
      expect(part.readAsBytesSync(), server.bytes);
    },
  );

  test('unknown free space still downloads successfully', () async {
    final server = FakeKiwix(data(1000));
    await server.start();
    addTearDown(server.stop);
    final part = File('${tmp.path}/f.part');
    final result = await download(server, part, (_) => null);
    expect(result.bytes, 1000);
    expect(server.bodyRequests, 1);
    expect(part.readAsBytesSync(), server.bytes);
  });

  test(
    'ENOSPC after the preflight remains a no-space download error',
    () async {
      final server = FakeKiwix(data(1000));
      await server.start();
      addTearDown(server.stop);
      final part = File('${tmp.path}/f.part');
      // Simulate a concurrent writer filling the disk after the space check,
      // without filling the real desktop disk.
      await expectLater(
        ZimDownloader(freeSpace: (_) => 1 << 40).download(
          url: server.url,
          part: part,
          onProgress: (_, _) => throw const FileSystemException(
            'No space left on device',
            '',
            OSError('No space left on device', 28),
          ),
        ),
        throwsA(
          isA<DownloadException>()
              .having((e) => e.code, 'code', 'no_space')
              .having((e) => e.message, 'message', contains('out of space')),
        ),
      );
    },
  );

  test('unwritable destination reports failure rather than no space', () async {
    final server = FakeKiwix(data(1000));
    await server.start();
    addTearDown(server.stop);
    final part = File('${tmp.path}/missing/f.part');
    await expectLater(
      download(server, part, (_) => null),
      throwsA(
        isA<DownloadException>()
            .having((e) => e.code, 'code', 'failed')
            .having((e) => e.message, 'message', contains('Could not write')),
      ),
    );
    expect(part.existsSync(), isFalse);
  });

  test('unsupported desktop platforms return unknown free space', () {
    if (Platform.isWindows || Platform.isMacOS) {
      expect(freeBytesOnDisk(tmp.path), isNull);
    }
  });

  test('missing path returns unknown rather than zero available bytes', () {
    expect(freeBytesOnDisk('${tmp.path}/does-not-exist'), isNull);
  });
}
