# Add PDF: the ingest job (core API)

Status: agreed between the Linux and app sessions (2026-11-08); being built on branch `ask-linux-ingest`. Shapes here are the contract;
the phone OCR engine and the Add PDF screens match them.

One PDF becomes one book in a library: pack, shard points, keyword index, `copies.jsonl` line and (optionally) Bookshelves
events, exactly as the Linux builder makes them. The same job later replaces the Linux build service's ingest, so every
platform has one ingest path.

## How it runs

- **The app drives it.** There are no core threads and no callbacks across FFI. Each `cs_ingest_step` does a bounded amount of
  work and returns. To pause, stop calling; the job is checkpointed in `job_dir` after every page and every embed batch.
- **Resume after a kill:** call `cs_ingest_start` again with the same `job_dir`. If its checkpoint is for the same file (same
  BLAKE3), the job carries on from there; otherwise the old checkpoint is discarded and the job starts fresh.
- **One job per `job_dir`.** Several jobs may exist at once with different `job_dir`s, but only one may be in `writing` for a
  given library at a time (the other gets `busy` and should step again later).
- **Identity** is the original file's BLAKE3 (the copy key, via `cache_shelves::library::copy_key`). The PDF is never modified.
  OCR text goes into the pieces and the indexes only.
- All calls take and return one JSON object (UTF-8, NUL-terminated). Returned strings are freed with `cs_free_string`. On failure a
  call returns NULL and `cs_last_error(NULL)` gives `{code, message}`. Codes: `bad_json`, `io`, `not_found` (no such job),
  `busy`, `cancelled`, `not_pdf`, `locked` (password-protected), `damaged`, `no_space`, `embed` (the embedder failed).

## The four calls

### `cs_ingest_start(params) -> {job}`

```json
{
  "library_dir": ".../libraries/my-books",
  "pdf_path": ".../Inbox/Wilderness Medicine.pdf",
  "job_dir": ".../ingest/7f3a",
  "bookshelves": {"dir": ".../bookshelves", "dev": "<device id>"},
  "opts": {
    "title": "Wilderness Medicine",
    "ocr": "host",
    "ocr_batch": 8,
    "ocr_dpi": 300,
    "embed_batch": 8,
    "embed_threads": 2
  }
}
```

- `bookshelves` is optional; without it no Bookshelves events are written.
- `opts` and each key in it are optional. Defaults:
  - `title`: the PDF's own title metadata, else the file name without `.pdf`.
  - `ocr`: `"host"`. The app does the OCR. With `"off"`, pages without text are skipped and counted.
  - `ocr_batch`: 8 pages per `needs_ocr`.
  - `ocr_dpi`: 300.
  - `embed_batch`: 8 pieces per embed call.
  - `embed_threads`: 2.
  `embed_batch` and `embed_threads` let the app keep the work gentle on battery.
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
    "shelf": {"div": "610", "by": "auto"}
  }
}
```

  - `ocr` is null when no page needed OCR.
  - `same` is the same-book matches written as `same by:auto` events. It is empty when there were none. In that case, `shelf` is
    the `place` written (the classifier's division when confident, else null for Unsorted).
  - Both are absent without `bookshelves`.
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

- It stops the job, deletes `job_dir` and any partial output, and returns `{"cancelled": true}`.
- Nothing is written to the library before `writing`, and `writing` is all or nothing. A cancel after `done` returns `not_found`.

## What the book gets

- **Pack:** the same format and version rules as server/builder/PACK-FORMAT.md, written into `<library_dir>/packs/`.
  - `book.ocr` is `{engine, version, pages_ocrd, confidence?}`.
  - The pack also records its text extractor: `pdfium` on phones, `mupdf` from the Linux builder. That is the only intended
    difference between a phone-built and a Linux-built pack of the same PDF.
- **Pieces:** the shared chunker (`cache_chunk`, as `cs_pdf_chunk`): about 200 words, each with page, PDF page and heading path.
- **Vectors:** bge-m3 through `cache_embed` with the phone's settings (n_ctx 512, CLS, normalized), so they match query vectors.
- **Library:** points added to the library's shard and keyword index, a line appended to `copies.jsonl`, and the library's
  `SHA256SUMS` updated. While `writing`, an open handle treats the library as it does during an `update_library` job: it is
  `updating`, search skips it, and it reopens when the write is done.
- **Bookshelves** (when given): same-book detection against the visible copies.
  - Matches are written as `same by:auto`.
  - A new book gets `place` (classifier when confident, else none) and `assign` the next free number, through `cache_shelves` in
    process.

## OCR engines (host side)

The core renders each page that needs OCR to a grayscale PNG at `ocr_dpi`. The app's engine takes `image_path`, `width`,
`height` and `dpi`, and returns `text` (reading order, lines separated by `\n`) and an optional `confidence`. Engine names are
lowercase, for example `apple-vision` and `mlkit`, and `version` is the engine's own version string.

A page needs OCR when its text layer has fewer than 20 non-space characters.
