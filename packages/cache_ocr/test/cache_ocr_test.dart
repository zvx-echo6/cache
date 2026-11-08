import 'package:cache_ocr/cache_ocr.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> need(int page) => {'page': page, 'image_path': '/tmp/ocr/$page.png', 'width': 2550, 'height': 3300, 'dpi': 300};

/// Fails a page [times] times with [code], then reads it.
class FlakyEngine extends FakeOcrEngine {
  FlakyEngine(this.code, this.times) : super(pages: {1: 'one'});
  final String code;
  int times;

  @override
  Future<OcrPageText> recognize(OcrPageImage image) async {
    asked.add(image);
    if (times-- > 0) throw OcrException(code, 'flaky');
    return OcrPageText(page: image.page, text: 'one', confidence: 0.8);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('OcrPageImage', () {
    test('reads the core needs_ocr shape', () {
      final i = OcrPageImage.fromJson(need(42));
      expect([i.page, i.imagePath, i.width, i.height, i.dpi], [42, '/tmp/ocr/42.png', 2550, 3300, 300]);
      expect(i.toJson(), need(42));
    });
    test('dpi defaults to 300', () {
      expect(OcrPageImage.fromJson({'page': 1, 'image_path': 'a', 'width': 1, 'height': 1}).dpi, 300);
    });
  });

  group('ocrForIngest', () {
    test('makes the cs_ingest_ocr call, pages in the order asked, one engine and version', () async {
      final e = FakeOcrEngine(engine: 'mlkit', version: '16.0.1', pages: {7: 'Chapter 3\nWater', 3: 'Fire'});
      final b = await ocrForIngest(12, [need(7), need(3), need(9)], e);
      expect(b.ingestParams, {
        'job': 12,
        'engine': 'mlkit',
        'version': '16.0.1',
        'pages': [
          {'page': 7, 'text': 'Chapter 3\nWater', 'confidence': 0.9},
          {'page': 3, 'text': 'Fire', 'confidence': 0.9},
          // a blank page: empty text
          {'page': 9, 'text': '', 'confidence': 0},
        ],
      });
      expect(b.failed, isEmpty);
      expect(e.asked.map((i) => i.page), [7, 3, 9]);
    });

    test('waits between pages, not before the first, and reports each page', () async {
      final events = <String>[];
      await ocrForIngest(1, [need(1), need(2), need(3)], FakeOcrEngine(pages: {1: 'a', 2: 'b', 3: 'c'}),
          betweenPages: () async => events.add('wait'), onPage: (p) => events.add('page ${p.page}'));
      expect(events, ['page 1', 'wait', 'page 2', 'wait', 'page 3']);
    });

    test('a page that fails twice goes back blank and is listed; the others are read', () async {
      final e = FakeOcrEngine(pages: {1: 'one', 2: 'two'}, failing: {2});
      final b = await ocrForIngest(1, [need(1), need(2)], e);
      expect(b.pages.map((p) => p.text), ['one', '']);
      expect(b.failed.keys, [2]);
      expect(b.failed[2]!.code, 'engine');
      expect(e.asked.map((i) => i.page), [1, 2, 2]);
    });

    test('an engine failure is tried once more', () async {
      final e = FlakyEngine('engine', 1);
      final b = await ocrForIngest(1, [need(1)], e);
      expect(b.pages.single.text, 'one');
      expect(b.failed, isEmpty);
      expect(e.asked, hasLength(2));
    });

    test('a missing file is not tried again', () async {
      final e = FlakyEngine('no_file', 5);
      final b = await ocrForIngest(1, [need(1)], e);
      expect(b.failed[1]!.code, 'no_file');
      expect(e.asked, hasLength(1));
    });
  });

  group('page text and confidence', () {
    test('lines joined by newline, trimmed, empties dropped', () {
      expect(joinOcrLines([' Chapter 3 ', '', 'Water  ', '  ']), 'Chapter 3\nWater');
      expect(joinOcrLines([]), '');
    });
    test('confidence weighted by line length, clamped, 0 with no text', () {
      expect(pageConfidence([('abcd', 1.0), ('ab', 0.4)]), closeTo((4 * 1.0 + 2 * 0.4) / 6, 1e-9));
      expect(pageConfidence([('a', 2.0)]), 1.0);
      expect(pageConfidence([('', 0.9), ('  ', 0.9)]), 0);
    });
  });

  group('NativeOcrEngine over the channel', () {
    const channel = MethodChannel('co.cache/cache_ocr');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    setUp(() {
      calls.clear();
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        switch (call.method) {
          case 'info':
            return {'engine': 'apple-vision', 'version': '3', 'languages': ['en-US']};
          case 'memory':
            return {'current_bytes': 100, 'peak_bytes': 200};
          case 'recognize':
            final path = (call.arguments as Map)['path'] as String;
            if (path.endsWith('missing.png')) throw PlatformException(code: 'no_file', message: 'No image');
            return {
              'lines': [
                {'text': 'The quick brown fox', 'confidence': 1.0},
                {'text': 'jumps', 'confidence': 0.5},
              ],
              'stats': {'decode_ms': 12.5, 'recognize_ms': 800.0, 'before_bytes': 1, 'after_bytes': 2, 'peak_bytes': 3},
            };
        }
        return null;
      });
    });
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('info, recognize and memory', () async {
      final e = await NativeOcrEngine.open();
      expect([e.engine, e.version, e.languages], ['apple-vision', '3', ['en-US']]);
      final p = await e.recognize(OcrPageImage.fromJson(need(5)));
      expect(p.page, 5);
      expect(p.text, 'The quick brown fox\njumps');
      expect(p.confidence, closeTo((19 * 1.0 + 5 * 0.5) / 24, 1e-9));
      expect(p.stats!.recognizeMs, 800.0);
      expect(p.stats!.peakBytes, 3);
      expect(calls.last.arguments, {'path': '/tmp/ocr/5.png', 'width': 2550, 'height': 3300, 'dpi': 300});
      final m = await ocrMemory();
      expect([m.currentBytes, m.peakBytes], [100, 200]);
    });

    test('a platform error becomes an OcrException with its code', () async {
      final e = await NativeOcrEngine.open();
      await expectLater(
        e.recognize(const OcrPageImage(page: 1, imagePath: '/x/missing.png', width: 1, height: 1, dpi: 300)),
        throwsA(isA<OcrException>().having((x) => x.code, 'code', 'no_file')),
      );
    });

    test('no plugin: no engine', () async {
      messenger.setMockMethodCallHandler(channel, null);
      expect(await deviceOcrEngine(), isNull);
    });
  });
}
