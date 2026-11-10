/// On-device text recognition for pages that have no text layer.
///
/// The core's ingest job (packages/cache_ingest/INGEST-API.md) renders each page that needs OCR to a grayscale PNG at the
/// job's `ocr_dpi` (300 by default) and lists it in `needs_ocr` as `{page, image_path, width, height, dpi}`. The app reads
/// each image with [OcrEngine.recognize] and hands the text back through `cs_ingest_ocr` as
/// `{job, engine, version, pages: [{page, text, confidence}]}`. [ocrForIngest] does that whole round for one batch.
///
/// Engines: Apple Vision (`apple-vision`) on iPhone and iPad, Google ML Kit's bundled Latin model (`mlkit`) on Android. Both
/// run on the device, offline. [deviceOcrEngine] gives the phone's own engine, or null where there is none (web, desktop).
library;

export 'src/engine.dart';
export 'src/ingest.dart';
export 'src/native_engine.dart' show NativeOcrEngine, deviceOcrEngine, ocrMemory, OcrMemory;
