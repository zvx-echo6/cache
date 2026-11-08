# cache_ocr

On-device text recognition for PDF pages that have no text layer. Offline on both platforms:

| Platform | Engine (`engine`) | `version` | Languages |
|---|---|---|---|
| iPhone, iPad | Apple Vision, `VNRecognizeTextRequest`, accurate, language correction on | the request revision, pinned: `3` (iOS 16 and later) | `en-US` |
| Android | Google ML Kit text recognition, bundled Latin model (`com.google.mlkit:text-recognition:16.0.1`) | `16.0.1` | Latin script |

ML Kit is an Android Gradle dependency of this plugin only, so iOS builds pull nothing of it. The model is inside the APK; nothing
is downloaded at run time.

## How it fits the ingest job

The core's ingest job (`packages/cache_ingest/INGEST-API.md`) chooses the pages (fewer than 20 non-space characters in the text
layer), renders each to a grayscale PNG at `ocr_dpi` (300 by default) and lists them in `needs_ocr` as
`{page, image_path, width, height, dpi}`. This package reads them and answers in the shape of `cs_ingest_ocr`:

```dart
final engine = await deviceOcrEngine();            // null on web and desktop
final batch = await ocrForIngest(job, status['needs_ocr'], engine!, betweenPages: throttle, onPage: progress);
cs_ingest_ocr(jsonEncode(batch.ingestParams));     // {job, engine, version, pages: [{page, text, confidence}]}
```

- `text` is in reading order, lines joined by `\n`; empty for a blank page.
- `confidence` (0 to 1) is the engine's line confidence averaged over the page, weighted by line length.
- One engine and version per job (the core refuses a different pair). The pair is stable, and the core writes it into
  `book.ocr {engine, version, pages_ocrd}`, with the OCR'd pages listed, so a later, better engine can find those pages and read
  them again.
- Pages are read one at a time. A page that fails is tried once more; if it still fails it goes back blank and is listed in
  `batch.failed` (the core asks for the same batch until every page is answered).

The lower-level call is `OcrEngine.recognize(OcrPageImage)`, which returns one `OcrPageText` with its `OcrPageStats` (decode and
recognition time, memory before, after and peak).

## Resolution

300 dpi (the core's default): a US Letter page is 2550 x 3300 pixels, about 34 MB once decoded for the engine (4 bytes a pixel).
Reading one page at a time keeps that the only large allocation. The CI test also reads a 9-point page at 200 dpi so the cost of a
lower `ocr_dpi` can be compared; its numbers are in each OCR engines run's summary.

## Adding other scripts

- **Android:** ML Kit has one bundled model per script: `text-recognition-chinese`, `-devanagari`, `-japanese`, `-korean` (each an
  extra Gradle dependency of several MB per ABI). Each has its own options class (`ChineseTextRecognizerOptions`, ...). Add the
  dependency, pick the recognizer by the book's script, and give each its own engine id (`mlkit-devanagari` and so on) so a book
  records which model read it. Latin covers English and the other Latin-script languages.
- **iOS:** Vision reads the languages in `VNRecognizeTextRequest.supportedRecognitionLanguages()` (revision 3: English, French,
  Italian, German, Spanish, Portuguese, Chinese, Cantonese, Korean, Japanese, Russian, Ukrainian, Thai, Vietnamese, Arabic
  and more by iOS version). Set `recognitionLanguages` to the book's languages, most likely first, and put them into the version
  (`3+fr-FR`) so the record says what was read with what. `automaticallyDetectsLanguage` (iOS 16) is the other route.
- The language or script of a book would come from the core (the PDF's metadata or the text layer of its other pages), passed
  with the job; it is not guessed here.

## Tests

- `test/`: the Dart side with a fake engine and a mocked platform channel (`flutter test`; run in CI by tests.yml).
- `example/integration_test/ocr_test.dart`: real OCR on an Android emulator and an iOS simulator (`.github/workflows/ocr.yml`).
  Its fixtures are grayscale 300 dpi page images of known text made to look scanned (`example/tool/make_fixtures.py`, run in
  CI); it reads them with the device's engine, checks the phrases come back and prints each page's time and memory.

Emulator and simulator numbers are not a phone's: the emulator is x86_64 on a CI machine, and the simulator runs Vision on the
Mac's CPU and GPU. What needs a real-device check: time per page and memory on a mid-range Android phone and an older iPhone,
reading order on multi-column pages (Vision's observations are kept in the order it gives them), photographed rather than
rendered pages, and heat over a long book.
