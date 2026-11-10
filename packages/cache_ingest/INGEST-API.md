# Add PDF: the ingest job (core API)

Status: agreed between the Linux and app sessions (2026-11-08); being built on branch `ask-linux-ingest`. Shapes here are the contract;
the phone OCR engine and the Add PDF screens match them.

One PDF becomes one book in a library: pack, shard points, keyword index, `copies.jsonl` line and (optionally) Bookshelves
events, exactly as the Linux builder makes them. The same job later replaces the Linux build service's ingest, so every
platform has one ingest path.

## How it runs

- **The app drives it.** There are no callbacks across FFI, and the only core thread is the idle timer below. Each `cs_ingest_step` does a bounded amount of
  work and returns. To pause, stop calling; the job is checkpointed in `job_dir` after every page and every embed batch.
- **The embedding model is held only while it is needed.** The core loads its own bge-m3 (from `engines.embed_lib` and `engines.embed_model`) at the
  first embed batch, and frees it when the job reaches `done` or `failed`, when it is cancelled, and when the job has had no call for
  `opts.embed_idle_ms` (unless another live job on the same engines still uses it). A later step, a resumed job or the next job loads it again. Jobs on the same
  engines share one copy. It is not shared with the app's own query embedder (a separate handle the app owns), so while a job embeds, two copies are
  in memory; once the job is done, failed, cancelled or idle, only the app's is.
- **Resume after a kill:** call `cs_ingest_start` again with the same `job_dir`. If its checkpoint is for the same file (same
  BLAKE3), the job carries on from there; otherwise the old checkpoint is discarded and the job starts fresh.
- **`job_dir` is the job's own folder.** The job marks it (`.cache-ingest`) and only ever empties or removes a folder that has the mark; a
  folder that exists, is not empty and has no mark makes `cs_ingest_start` fail with `bad_json`. The check that no two jobs share a `job_dir` is
  made before anything else is done.
- **A checkpoint carries on only if everything it was made with matches:** the file's BLAKE3, the embedder (model file) and the OCR mode.
- **One job per `job_dir`.** Several jobs may exist at once with different `job_dir`s, but only one may be in `writing` for a
  given library at a time (the other gets `busy` and should step again later).
- **Identity** is the original file's BLAKE3 (the copy key, via `cache_shelves::library::copy_key`). The PDF is never modified.
  OCR text goes into the pieces and the indexes only.
- All calls take and return one JSON object (UTF-8, NUL-terminated). Returned strings are freed with `cs_free_string`. On failure a
  call returns NULL and `cs_last_error(NULL)` gives `{code, message}`. Codes: `bad_json`, `io`, `not_found` (no such job),
  `busy`, `cancelled`, `not_pdf`, `locked` (password-protected), `damaged`, `no_space`, `embed` (the embedder failed or is not configured), `no_text` (no page has any text: OCR off, or every OCR'd page empty; a `failed` status).

## The four calls

### `cs_ingest_start(params) -> {job}`

```json
{
  "library_dir": ".../libraries/my-books",
  "pdf_path": ".../Inbox/Wilderness Medicine.pdf",
  "job_dir": ".../ingest/7f3a",
  "bookshelves": {"dir": ".../bookshelves", "dev": "<device id>", "libraries": [{"library_id": "...", "dir": "...", "packs_dir": "..."}]},
  "engines": {"pdfium_lib": "...", "pdfium_version": "...", "embed_lib": "...", "embed_model": "...", "embed_sha256": "...", "classifier": ".../cache-classifier-1.bin"},
  "opts": {
    "title": "Wilderness Medicine",
    "ocr": "host",
    "ocr_batch": 8,
    "ocr_dpi": 300,
    "embed_batch": 8,
    "embed_threads": 2,
    "embed_idle_ms": 60000
  }
}
```

- `bookshelves` is optional; without it no Bookshelves events are written. `bookshelves.libraries` (optional; the shape `cs_shelves_resolve` takes)
  names the libraries whose copies the new book is compared with, besides the target library. Without it only the target library is compared.
- `engines` is optional and says where the host's engines are. All keys are optional; what fails without them:
  - `pdfium_lib`: path of the app's own `libpdfium` (the copy pdfrx ships). PDFium is loaded at run time: by this path; if that does not load, by the
    usual library name; if that does not, from the process itself (iOS links it into the app). If none works, `cs_ingest_start` fails with `damaged`.
  - `pdfium_version`: recorded in the pack's `extractor.version` (`unknown` without it).
  - `embed_lib`, `embed_model` (both needed): the built `libcache_llama` and the bge-m3 GGUF. Without them reading works, but embedding
    fails with `embed`.
  - `embed_sha256`: the model's expected SHA-256; a different file fails with `embed`.
  - `classifier`: path of a `cache-classifier-N.bin`, the division classifier the Linux builder uses. It is refused if it was trained on another
    embedding model than `embed_sha256` (else the model Cache decided on, bge-m3 Q8_0). Without a usable classifier no book is placed (see Bookshelves).
- `opts` and each key in it are optional. Defaults:
  - `title`: the PDF's own title metadata, else the file name without `.pdf`.
  - `ocr`: `"host"`. The app does the OCR. With `"off"`, pages without text are skipped and counted.
  - `ocr_batch`: 8 pages per `needs_ocr`.
  - `ocr_dpi`: 300.
  - `embed_batch`: 8 pieces per embed call.
  - `embed_threads`: 2.
  - `embed_idle_ms`: 60000 (1 to 86400000). The job's embedding model is freed after this long without a call to the job (see How it runs).
  `embed_batch` and `embed_threads` let the app keep the work gentle on battery, and `embed_idle_ms` on memory.
- Returns `{"job": 12, "resumed": false, "copy": "<blake3>", "pages": 310}`.

### `cs_ingest_step(params) -> status`

```json
{"job": 12, "budget_ms": 500}
```

- It does work for about `budget_ms`. The smallest unit is one page or one embed batch, so a step can run over the budget by one
  unit. It checkpoints, then returns:

```json
{
  "state": "needs_ocr",
  "progress": {"pages": 310, "pages_done": 41, "pieces": 0, "pieces_done": 0},
  "needs_ocr": [
    {"page": 42, "image_path": ".../ingest/7f3a/ocr/42.png", "width": 2550, "height": 3300, "dpi": 300}
  ]
}
```

- `state`:
  - `reading`: text being taken from the pages;
  - `needs_ocr`: waiting for `cs_ingest_ocr`; stepping again returns the same list;
  - `embedding`;
  - `writing`: pack, shard, keyword index, `copies.jsonl`, Bookshelves;
  - `done`;
  - `failed`.
- `progress.pieces` is known once reading is finished (0 before).
- On `done`:

```json
{
  "state": "done",
  "progress": {"pages": 310, "pages_done": 310, "pieces": 254, "pieces_done": 254},
  "result": {
    "doc_id": "<doc id>",
    "copy": "<blake3>",
    "title": "Wilderness Medicine",
    "pieces": 254,
    "pages_without_text": 0,
    "ocr": {"engine": "apple-vision", "version": "4", "pages_ocrd": 12},
    "same": [{"with": "<copy key>", "how": "blake3", "score": 1.0}],
    "shelf": {"div": "610", "by": "auto"},
    "suggested": {"div": "610", "score": 0.91, "second_div": "620", "classifier_version": 3}
  }
}
```

  - `ocr` is null when no page needed OCR.
  - `same` is the same-book matches written as `same by:auto` events. It is empty when there were none. In that case, `shelf` is
    the `place` written (the classifier's division when confident, else null for Unsorted).
  - `suggested` is the sorter's best guess, null without a usable classifier, and also given when the book stays in Unsorted. It is not tied to
    `bookshelves`. A same-book match is not scored: `suggested` is null.
  - `same` and `shelf` are absent without `bookshelves`.
  - After `done` the job's `job_dir` is removed, and further calls return `not_found`.
- On `failed`: `{"state":"failed","error":{"code","message"}}`. The `job_dir` is kept so the app can show the reason, and
  `cs_ingest_cancel` removes it.

### `cs_ingest_ocr(params) -> {accepted}`

```json
{
  "job": 12,
  "engine": "apple-vision",
  "version": "4",
  "pages": [{"page": 42, "text": "Chapter 3 ...", "confidence": 0.93}]
}
```

- `text` may be empty, which means the page is blank.
- `confidence` (0 to 1) is optional. It is kept in the checkpoint and averaged into the pack's `book.ocr.confidence`.
- Each page's PNG is deleted once its text is accepted.
- A page that was not asked for gets `bad_json`.
- One engine and version per job. A different pair on a later call gets `bad_json`.
- Returns `{"accepted": 1, "remaining": 0}`, where `remaining` is the pages of the current `needs_ocr` batch still to come.

### `cs_ingest_cancel(params) -> {cancelled}`

```json
{"job": 12}
```

- It stops the job, deletes `job_dir` and any partial output, and returns `{"cancelled": true}`. `cancelled: true` is only ever returned when
  nothing was added to the library.
- A cancel that arrives while the book is being written and loses the race to `done` returns `{"cancelled": false, "done": true}` (or `not_found`
  once the job is gone). A job whose book is already in the library but that then failed (the Bookshelves events could not be written) is kept
  and returns `{"cancelled": false, "done": false, "committed": true}`: step it again, or start again with the same `job_dir`, and the missing
  events are written without writing the library a second time.
- Nothing is written to the library before `writing`, and `writing` is all or nothing. A cancel after `done` returns `not_found`.

## What the book gets

- **Pack:** the same format and version rules as server/builder/PACK-FORMAT.md, written into `<library_dir>/packs/`.
  - `book.ocr` is `{engine, version, pages_ocrd, confidence?}`.
  - The pack also records its text extractor: `pdfium` on phones, `mupdf` from the Linux builder. That is the only intended
    difference between a phone-built and a Linux-built pack of the same PDF.
- **Pieces:** the shared chunker (`cache_chunk`, as `cs_pdf_chunk`): about 200 words, each with page, PDF page and heading path.
- **Vectors:** bge-m3 through `cache_embed` with the phone's settings (n_ctx 512, CLS, normalized), so they match query vectors.
- **Library:** points added to the library's shard and keyword index, a line appended to `copies.jsonl`,
  a row added to (or replaced in) `documents.tsv` as the builder writes it, and `SHA256SUMS` updated (`source-identities.json` is not touched). While `writing`, an open handle treats the library as it does during an `update_library` job: it is
  `updating`, search skips it, and it reopens when the write is done.
- **Bookshelves** (when given): same-book detection against the visible copies.
  - Matches are written as `same by:auto`.
  - A new book gets `place` (classifier when confident, else none) and `assign` the next free number, through `cache_shelves` in
    process. The shared-Bookshelves number race (two devices that assign the same next number) is left to the resolver, whose clash suffix handles it by design.
    **A new book is filed as on Linux.** When no same-book match exists, the book is scored by the same sorter the Linux build uses
    (`cache_pack::sorter`, one implementation), from the vectors the job already made (no second embedding pass). If the sorter is confident, `place` (by auto)
    is written in that division with `assign` of the next free number. If it is not, the book is in Unsorted with no `place`. Either way the guess
    (`div`, `label`, `score`, `second_div`, `classifier_version`, source `classifier`) is in the pack's `book.suggested` and the `copies.jsonl` line.
    Without a usable classifier no guess is made, nothing is placed, and `shelf` and `suggested` are null. The events are owed to the log unless this device's log already holds
    some for the copy; what the log holds is what `same` and `shelf` report.
    When `same` is not empty the book is not placed either and `shelf` is null.

## OCR engines (host side)

The core renders each page that needs OCR to a grayscale PNG at `ocr_dpi`. The app's engine takes `image_path`, `width`,
`height` and `dpi`, and returns `text` (reading order, lines separated by `\n`) and an optional `confidence`. Engine names are
lowercase, for example `apple-vision` and `mlkit`, and `version` is the engine's own version string.

A page needs OCR when its text layer has fewer than 20 non-space characters. A page too big to draw at `ocr_dpi` within about 40 million pixels is
drawn at a lower resolution, and the `dpi` of its `needs_ocr` entry says the resolution it was really drawn at.

## `cs_ingest_probe(params) -> report`

Checks the engines without starting a job. `params` is `{"engines": {...as in cs_ingest_start...}, "hash_model": true}`. It writes nothing and
keeps nothing loaded (the model is loaded to prove it loads, then released). A missing engine is reported, never an error; only malformed JSON
returns NULL with `bad_json`.

```json
{"pdfium": {"ok": true, "version": "chromium/7811", "from": "path"},
 "embedder": {"ok": true},
 "model": {"ok": true, "sha256": "<actual>", "expected": "<engines.embed_sha256>", "matches": true},
 "classifier": {"ok": true, "version": 3}}
```

- `pdfium.from` is `path`, `name` or `process`; `version` is `engines.pdfium_version` (null when not given); on failure `ok` is false, `from` is
  null and `error` says why.
- `model.sha256` is the SHA-256 of the file, read in full and reported even when no `embed_sha256` was given (`expected` and `matches` are then
  null). `ok` is false when the file is missing or `matches` is false.
- `classifier.ok` is false (with `error`) when none is given, the file does not load, or it was trained on another embedding model.
- Hashing a model of about 600 MB takes seconds on a phone, so do not do it at every app start: pass `"hash_model": false` to skip it
  (`sha256` and `matches` are then null; `ok` only says the file exists).
