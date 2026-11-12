import 'dart:io';
import 'dart:typed_data';

import 'package:cache/pdf/pdf_source.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('pdf-source'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('a PDF in a ZIM is copied to a temporary file, removed when the reader closes', () async {
    final src = PdfZimSource(address: 'zim:x/a.pdf#page=4', title: 'a', read: (a) async => List.filled(10 << 20, 7), tempDir: () async => dir);
    expect(src.address, 'zim:x/a.pdf');
    final progress = <double?>[];
    final (path, copy) = await preparePdf(src, onCopying: progress.add);
    expect(File(path).lengthSync(), 10 << 20);
    expect(progress.first, isNull);
    expect(progress.last, 1.0);
    await copy!.dispose();
    expect(File(path).existsSync(), isFalse);
  });

  test('a file that is gone, an entry that is gone, a full device', () async {
    await expectLater(preparePdf(PdfFileSource('${dir.path}/none.pdf', title: 'none')), throwsA(isA<PdfGone>()));
    final gone = PdfZimSource(address: 'zim:x/a.pdf', title: 'a', read: (a) async => throw const PdfGone(), tempDir: () async => dir);
    await expectLater(preparePdf(gone), throwsA(isA<PdfGone>()));
    final full = FileSystemException('write failed', 'x', const OSError('No space left on device', 28));
    if (!Platform.isWindows) expect(isNoSpace(full), isTrue);
    expect(isNoSpace(const FileSystemException('write failed', 'x', OSError('Permission denied', 13))), isFalse);
    expect(isNoSpace(const FileSystemException('write failed')), isFalse);
  });

  test('a copy stopped half way leaves nothing behind', () async {
    final src = PdfZimSource(address: 'zim:x/a.pdf', title: 'a', read: (a) async => List.filled(12 << 20, 1), tempDir: () async => dir);
    var calls = 0;
    await expectLater(preparePdf(src, cancelled: () => ++calls > 2), throwsA(isA<PdfCancelled>()));
    expect(Directory('${dir.path}/pdf-reader').listSync(), isEmpty);
  });

  group('for a browser: the bytes, with no temporary file', () {
    test('a ZIM entry and a server book come as bytes; nothing is written', () async {
      var temp = false;
      final zim = PdfZimSource(address: 'zim:x/a.pdf#page=4', title: 'a', read: (a) async => [1, 2, 3], tempDir: () async {
        temp = true;
        return dir;
      });
      expect(await loadPdfBytes(zim), [1, 2, 3]);
      expect(await loadPdfBytes(PdfServerSource(id: 'lib/doc', title: 'b', fetch: () async => Uint8List.fromList([4, 5]))), [4, 5]);
      expect(temp, isFalse);
      expect(dir.listSync(), isEmpty);
    });

    test('an entry that is gone, a file (a browser has none), and a cancel', () async {
      await expectLater(loadPdfBytes(PdfZimSource(address: 'zim:x/a.pdf', title: 'a', read: (a) async => throw const PdfGone())), throwsA(isA<PdfGone>()));
      await expectLater(loadPdfBytes(PdfFileSource('${dir.path}/a.pdf', title: 'a')), throwsA(isA<PdfGone>()));
      await expectLater(
        loadPdfBytes(PdfServerSource(id: 'l/d', title: 'a', fetch: () async => [1]), cancelled: () => true),
        throwsA(isA<PdfCancelled>()),
      );
    });

    test('the viewer gets a name that is unique per PDF', () {
      expect(pdfSourceName(PdfServerSource(id: 'lib/doc', title: 'b', fetch: () async => [])), 'server:lib/doc');
      expect(pdfSourceName(PdfZimSource(address: 'zim:x/a.pdf#page=2', title: 'a', read: (a) async => [])), 'zim:x/a.pdf');
    });
  });
}
