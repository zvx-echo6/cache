/// One page image to read: an entry of the core's `needs_ocr` list.
class OcrPageImage {
  const OcrPageImage({required this.page, required this.imagePath, required this.width, required this.height, required this.dpi});

  /// `{page, image_path, width, height, dpi}`, as the core lists it.
  factory OcrPageImage.fromJson(Map<String, dynamic> j) => OcrPageImage(
    page: (j['page'] as num).toInt(),
    imagePath: j['image_path'] as String,
    width: (j['width'] as num).toInt(),
    height: (j['height'] as num).toInt(),
    dpi: (j['dpi'] as num?)?.toInt() ?? 300,
  );

  /// The 1-based PDF page.
  final int page;

  /// The page rendered as a PNG (grayscale from the core; any PNG or JPEG is read).
  final String imagePath;
  final int width;
  final int height;

  /// The resolution the page was rendered at.
  final int dpi;

  Map<String, dynamic> toJson() => {'page': page, 'image_path': imagePath, 'width': width, 'height': height, 'dpi': dpi};
}

/// What reading one page took on the device (measured by the native side). Memory is the process's footprint in bytes:
/// physical footprint on iOS, resident set (VmRSS) on Android; [peakBytes] is the process's peak so far (iOS
/// ledger_phys_footprint_peak, Android VmHWM), so it only ever grows.
class OcrPageStats {
  const OcrPageStats({required this.decodeMs, required this.recognizeMs, required this.beforeBytes, required this.afterBytes, required this.peakBytes});

  factory OcrPageStats.fromJson(Map<Object?, Object?> j) => OcrPageStats(
    decodeMs: (j['decode_ms'] as num?)?.toDouble() ?? 0,
    recognizeMs: (j['recognize_ms'] as num?)?.toDouble() ?? 0,
    beforeBytes: (j['before_bytes'] as num?)?.toInt() ?? 0,
    afterBytes: (j['after_bytes'] as num?)?.toInt() ?? 0,
    peakBytes: (j['peak_bytes'] as num?)?.toInt() ?? 0,
  );

  /// Loading the image file into memory.
  final double decodeMs;

  /// The recognition itself.
  final double recognizeMs;
  final int beforeBytes;
  final int afterBytes;
  final int peakBytes;

  Map<String, dynamic> toJson() => {'decode_ms': decodeMs, 'recognize_ms': recognizeMs, 'before_bytes': beforeBytes, 'after_bytes': afterBytes, 'peak_bytes': peakBytes};
}

/// One page's recognised text.
class OcrPageText {
  const OcrPageText({required this.page, required this.text, required this.confidence, this.stats});

  final int page;

  /// In reading order, lines joined by `\n`; empty for a blank page.
  final String text;

  /// 0 to 1: the engine's own confidence, averaged over the page's lines weighted by their length; 0 for a blank page.
  final double confidence;

  /// Time and memory, when the engine measured them (the native engines do; a fake does not).
  final OcrPageStats? stats;

  /// A page of `cs_ingest_ocr`'s `pages`.
  Map<String, dynamic> toIngestJson() => {'page': page, 'text': text, 'confidence': confidence};
}

/// Why a page could not be read (the image is missing or not an image, or the engine failed).
class OcrException implements Exception {
  const OcrException(this.code, this.message);

  /// `no_file`, `bad_image`, `engine` or `unsupported`.
  final String code;
  final String message;

  @override
  String toString() => 'OcrException($code): $message';
}

/// A text recogniser. [engine] and [version] are stable strings: they go into the book's record (`book.ocr {engine, version,
/// pages_ocrd}`) so a later, better engine can find the pages this one read and read them again.
abstract class OcrEngine {
  /// Lowercase: `apple-vision`, `mlkit`.
  String get engine;

  /// The engine's own version: the Vision request revision on iOS (`3`), the ML Kit library version on Android (`16.0.1`).
  String get version;

  /// Reads one page. Throws [OcrException] when the page cannot be read.
  Future<OcrPageText> recognize(OcrPageImage image);
}

/// A recogniser for tests: answers each page from [pages] (by page number), empty for any other page, and can be told to
/// fail pages. Records what it was asked.
class FakeOcrEngine implements OcrEngine {
  FakeOcrEngine({this.engine = 'fake', this.version = '1', Map<int, String>? pages, Set<int>? failing, this.confidence = 0.9})
    : pages = pages ?? {},
      failing = failing ?? {};

  @override
  final String engine;
  @override
  final String version;
  final Map<int, String> pages;
  final Set<int> failing;
  final double confidence;
  final List<OcrPageImage> asked = [];

  @override
  Future<OcrPageText> recognize(OcrPageImage image) async {
    asked.add(image);
    if (failing.contains(image.page)) throw const OcrException('engine', 'fake failure');
    final text = pages[image.page] ?? '';
    return OcrPageText(page: image.page, text: text, confidence: text.isEmpty ? 0 : confidence);
  }
}
