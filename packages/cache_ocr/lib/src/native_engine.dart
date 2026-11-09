import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'engine.dart';
import 'ingest.dart';

const MethodChannel _channel = MethodChannel('co.cache/cache_ocr');

/// The phone's own recogniser over the platform channel: Apple Vision on iOS, ML Kit on Android.
///
/// The native side answers `recognize` with the page's lines in reading order (`[{text, confidence}]`) and what it took
/// (`stats`); the text and the page's confidence are made from the lines here ([joinOcrLines], [pageConfidence]).
class NativeOcrEngine implements OcrEngine {
  NativeOcrEngine._(this.engine, this.version, this.languages);

  @override
  final String engine;
  @override
  final String version;

  /// The languages (BCP 47) or script the engine reads: `[en-US]` on iOS, `[latin]` on Android.
  final List<String> languages;

  /// Asks the native side which engine it has.
  static Future<NativeOcrEngine> open() async {
    final info = (await _channel.invokeMapMethod<String, Object?>('info'))!;
    return NativeOcrEngine._(info['engine'] as String, info['version'] as String, [for (final l in (info['languages'] as List? ?? const [])) l as String]);
  }

  @override
  Future<OcrPageText> recognize(OcrPageImage image) async {
    final Map<Object?, Object?> r;
    try {
      r = (await _channel.invokeMapMethod<Object?, Object?>('recognize', {'path': image.imagePath, 'width': image.width, 'height': image.height, 'dpi': image.dpi}))!;
    } on PlatformException catch (e) {
      throw OcrException(e.code, e.message ?? '');
    }
    final lines = [for (final l in (r['lines'] as List? ?? const [])) ((l as Map)['text'] as String? ?? '', (l['confidence'] as num?)?.toDouble() ?? 0.0)];
    final stats = r['stats'] is Map ? OcrPageStats.fromJson(r['stats'] as Map) : null;
    return OcrPageText(page: image.page, text: joinOcrLines(lines.map((l) => l.$1)), confidence: pageConfidence(lines), stats: stats);
  }
}

/// The phone's recogniser, or null where there is none (web, desktop, tests without the plugin).
Future<OcrEngine?> deviceOcrEngine() async {
  if (kIsWeb) return null;
  try {
    return await NativeOcrEngine.open();
  } on MissingPluginException {
    return null;
  }
}

/// The process's memory now, in bytes (see [OcrPageStats] for what is measured on each platform).
class OcrMemory {
  const OcrMemory(this.currentBytes, this.peakBytes);
  final int currentBytes;
  final int peakBytes;
}

/// The process's memory now (for measuring; the engines report their own per page in [OcrPageStats]).
Future<OcrMemory> ocrMemory() async {
  final m = (await _channel.invokeMapMethod<String, Object?>('memory'))!;
  return OcrMemory((m['current_bytes'] as num).toInt(), (m['peak_bytes'] as num).toInt());
}
