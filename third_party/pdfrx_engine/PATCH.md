# pdfrx_engine 0.4.7, patched

Upstream: `pdfrx_engine` 0.4.7 (MIT, Copyright (c) 2018 @espresso3389 (Takashi Kawasaki)), as published on pub.dev. It is the PDFium
engine under `pdfrx` 2.4.8. The app uses this copy through `dependency_overrides` in `app/pubspec.yaml`. `LICENSE` is unchanged.

## What is changed (two edits)

1. `lib/src/native/pdfrx_pdfium.dart`: `_installFontMapper()` is an empty function. Upstream makes a `_PdfFontMapper` (five
   `NativeCallable.isolateLocal` callbacks), installs it with `FPDF_SetSystemFontInfo`, and does so once per isolate that starts pdfrx.
   PDFium keeps that pointer for the whole process. With two Flutter engines in one process (the UI's and the background run's) the
   second replaces the first's, and a font lookup from the wrong isolate, or after the engine that installed it has ended, aborts the
   process ("Cannot invoke native callback from a different isolate"). Nothing else in the file changes: `_init`, `_deinit`, the font
   file reloads and the missing-font query still exist and still work on a mapper that is never made (`_fontMapper` stays null).
2. `pubspec.yaml`: the line `resolution: workspace` is removed (this copy is a path dependency, not a member of pdfrx's workspace).

## What replaces it

The app's core (`packages/cache_ingest/src/pdfium.rs`) installs ONE native font mapper for the process behind a `Once`: `extern "C"`
callbacks in Rust that live as long as the process. `MapFont` returns nothing, which is what the upstream mapper returned for every
font in this app (it is given no font files), so PDFium uses its built-in substitutes as before. The app calls it (the `probe` ingest
call with `"fonts": true`) wherever it starts pdfrx (`app/lib/pdf/pdfium_init.dart`) and at the start of a background run. The text
the core reads from the fixtures in `app/test/fixtures/pdf_fonts/` and the pictures it draws are compared byte for byte with goldens
made before the change (`app/test/pdf/pdfium_font_mapper_test.dart`); a child-process test with two isolates fails on the unpatched
package with the abort.

## When pdfrx or pdfrx_engine is updated

- Take the new `pdfrx_engine`, and apply edit 1 again: find where it installs a font mapper (`FPDF_SetSystemFontInfo`) and make that
  not happen. Remove `resolution: workspace` again if it is there.
- Check whether upstream has made the mapper safe on its own (a mapper installed once per process, callbacks that do not depend on one
  isolate). If so, drop this copy and the `dependency_overrides` entry, and keep the core's mapper only if it is still needed.
- Run `app/test/pdf/pdfium_font_mapper_test.dart` with `CACHE_PDF_FONTS=1` (the add-pdf-core CI job does): the goldens must still match
  and the two-isolate child must exit 0.
- Check that pdfrx still gets the PDFium path from `Pdfrx.pdfiumModulePath` and that `FPDF_InitLibrary` is still called once by it
  (the core also calls it, which PDFium allows).
