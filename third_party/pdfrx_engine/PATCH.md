# pdfrx_engine 0.4.7, patched

Upstream: `pdfrx_engine` 0.4.7 (MIT, Copyright (c) 2018 @espresso3389 (Takashi Kawasaki)), as published on pub.dev. It is the PDFium
engine under `pdfrx` 2.4.8. The app uses this copy through `dependency_overrides` in `app/pubspec.yaml`. `LICENSE` is unchanged.

## What is changed (three edits)

1. `lib/src/native/pdfrx_pdfium.dart`: `_installFontMapper()` is an empty function. Upstream makes a `_PdfFontMapper` (five
   `NativeCallable.isolateLocal` callbacks), installs it with `FPDF_SetSystemFontInfo`, and does so once per isolate that starts pdfrx.
   PDFium keeps that pointer for the whole process. With two Flutter engines in one process (the UI's and the background run's) the
   second replaces the first's, and a font lookup from the wrong isolate, or after the engine that installed it has ended, aborts the
   process ("Cannot invoke native callback from a different isolate"). Nothing else in the file changes: `_init`, `_deinit`, the font
   file reloads and the missing-font query still exist and still work on a mapper that is never made (`_fontMapper` stays null).
2. The process's one PDFium lock (`lib/src/native/pdfium_lock.dart`, `lib/src/pdfium_lock_stub.dart`, exported by `lib/pdfrx_engine.dart`;
   `lib/src/native/worker.dart`; `lib/src/native/pdfrx_pdfium.dart`). PDFium is not thread-safe and the app's core, a native library in
   the same process, calls it from other threads than pdfrx's worker. The core exports the lock's C functions; the app hands their
   addresses to `PdfiumLock.functions` BEFORE pdfrx starts, the worker isolate is told them when it starts, and `BackgroundWorker.compute`
   holds the lock around each callback (its synchronous part: never across an `await`). The app's own callbacks
   (`PdfrxEntryFunctions.compute`) pass `lockPdfium: false` and take the lock themselves around each PDFium call (`PdfiumLock.hold`, used
   by `app/lib/pdf/index/pdf_meta_io.dart` and, in Rust, by every call in `cache_ingest/src/pdfium.rs`).
   Ownership is per ACQUISITION (a token the core hands back), not per OS thread, and each acquisition names its OWNER (a number per
   isolate; the worker's is made by `BackgroundWorker` and passed to it). A killed isolate never runs its `finally` (the kill lands when
   its native call returns to Dart; checked by `app/test/pdf/pdfium_lock_death_test.dart`), so the core is told the owner is gone: by
   the exit listener of the worker's spawner (`Isolate.spawn(..., onExit:)` in `worker.dart`), and by a `NativeFinalizer` attached to an
   object of the owner (`PdfiumLock.become`), which the VM runs when the owner's isolate (group) shuts down, as a destroyed Flutter
   engine's does. The core also takes a hold away after five minutes, loudly (`lock_status` in the probe reply, which the app logs).
3. `pubspec.yaml`: the line `resolution: workspace` is removed (this copy is a path dependency, not a member of pdfrx's workspace).

## What this copy leaves out and how it differs from the published package

- The folders `example/`, `test/` and the file `analysis_options.yaml` of the published package are not copied (not part of the library).
- Line endings: the files here are LF. (The published archive's text files come out with CRLF when unpacked on Windows by `pub get`; a copy
  made there must be converted to LF before it is committed, or every file shows as changed.)

## Warning: native opens must stay `openFile`

The independent review of the lock found that opening a document with `openData` or `openCustom` for a LARGE file would deadlock with the
lock: PDFium reads such a document through a read callback answered on a Dart isolate's event loop, while the worker's thread is inside
PDFium holding the lock; if the isolate that must answer is itself waiting for the lock, nothing can move. The app opens every document
with `PdfDocument.openFile` (`pdf_pages.dart`, `pdf_reader_screen.dart`, `pdf_meta_io.dart`), whose reads are answered by an isolate that
never takes the lock. This was not reproduced here, only reasoned from the review: keep to `openFile`, and test any new use of
`openData` or `openCustom` with a large file (a new pdfrx version, or new app code) before it ships.
