# Document pack format (`.cdoc`), version 1 (revision 4)

**Status: proposed; shared format pending owner/orchestrator approval.** Nothing outside `server/builder` reads or writes
this format yet. Whole-library output (`cache-build library`) is a normal Cache library and does not depend on it.

A pack holds one document version: its verbatim pieces, their vectors and where they came from. It is the unit of change:
immutable, named by content identity, and small enough to travel by the existing file-level sync.

## File

`packs/<doc_id>@<doc_version>.cdoc`

- `doc_id`: letters, digits, `.`, `_`, `-` only (it is also used in point ids). Default: the BLAKE3 hash (hex) of the PDF's
  first version; the caller may supply a stable id.
- `doc_version`: a whole number from 1. A changed document is a new pack with the next number.

The file is gzip-compressed JSON Lines (gzip header with mtime 0, level 6): the same inputs give the same bytes.

Why this and not zstd/CBOR: it can be read with `zcat`, needs no new crate (flate2 is already in `Cargo.lock`, pure Rust),
and the size is dominated by the vectors (1024 f32 per piece), which no codec shrinks much. A binary vector section would
save about a quarter; it can come in format 2 if sync size matters.

## Lines

Line 1, the header (one JSON object):

| Key | Meaning |
|---|---|
| `cdoc` | Format version, 1. Readers reject other values. |
| `doc_id`, `doc_version` | Identity (see above). |
| `title` | The document title: caller's, else the PDF metadata title, else the file name without extension. |
| `source` | `{blake3, size, file_name, https?}`: the PDF's BLAKE3 (hex), size in bytes, file name, and an optional address it can be fetched from. |
| `extractor` | `{name, version, layout_version?}`, e.g. `mupdf` / `0.8.0` / `2`: what read the pages and, when the producer laid them out, the version of the layout step (see "Layout version"). `layout_version` is absent in older packs and when the pages came from something that did its own layout. |
| `chunker` | `{version, target_words, max_words}`. |
| `embedding` | `{embedder, dims}`: what made the vectors (the GGUF name for bge-m3, `fake-hash-v1` for the test stand-in) and their size. |
| `created_at` | Text given by the caller (the builder never reads the clock). |
| `page_count` | Pages in the PDF. |
| `ocr_pages` | 1-based PDF pages skipped because they have no text layer and still need OCR. |
| `text_source_ocr_pages` | Optional. 1-based PDF pages whose text came from OCR; every other page's text came from the PDF's own text layer. Absent (or empty) means all from the text layer, which is what every pack written before OCR'd pages existed means. This is the per-page `text_source` of `pages.json` (`"layer"` or `"ocr"`); a piece's text came from OCR when any page it covers is listed. |
| `pieces` | The number of piece lines that follow. Readers check it. |
| `division` | Revision 3 only; read, never written by revision 4. The division the document was filed in; revision 4 reads it as `book.suggested`. See below. |
| `book` | Optional (revision 4). The facts about the book: its title, arrival hash, compression, OCR and suggested division; see "Revision 4". |
| `samebook` | Optional (revision 3). The same-book fingerprint; see below. |

Every other line is a piece:

| Key | Meaning |
|---|---|
| `i` | Index from 0; the `index` in the point id. |
| `text` | The passage, verbatim (about 200 words, at most 300). |
| `page` | Page label of the piece's first word (the printed number or numeral when the PDF has page labels, else the PDF page number), as text. |
| `pdf_page` | 1-based PDF page of its first word (what a viewer opens). Optional since revision 2: packs written before then always have it, and a pack without it still loads (the library payload then has no `pdf_page`). |
| `page_end` | Label of the last page, only when the piece crosses a page break. |
| `pdf_page_end` | 1-based PDF page of the last word, only when the piece crosses a page break (revision 2; absent in older packs). |
| `heading_path` | The headings above it, outermost first. |
| `vector` | Base64 of the piece's vector as little-endian f32 (4096 bytes for 1024 dimensions). |

## Pieces

Verbatim text only: whitespace is normalised, words hyphenated at a line end are made whole, ligatures are expanded and
leader dots in tables of contents are dropped; nothing is rewritten. Pieces are whole sentences, with the last one or two
sentences (at most 40 words) repeated at the start of the next piece of the same section. A piece never crosses a heading, and
spans a page break only when a sentence does.

## Revision 2 (compatible)

Revision 2 makes `pdf_page` optional when reading and adds the optional piece key `pdf_page_end`. The header's `cdoc` stays
1: a reader that ignores unknown piece keys reads revision 2 packs, and this reader reads packs of either revision.

## Revision 3 (compatible)

Revision 3 adds two optional header keys. The header's `cdoc` stays 1. A pack without them loads (both read as absent), and a
reader that does not know them ignores them, so older and newer packs and readers mix freely.

`division`: the division the document is filed in. **Revision 4 replaces this block with `book.suggested`** (below). A reader still accepts it, and
maps it into `book.suggested` (`sorter` becomes `classifier`; `label` and `user` become `label`; `division` becomes `div`, `second_division`
becomes `second_div`). A revision 3 pack that is written again becomes a revision 4 pack.

| Key | Meaning |
|---|---|
| `division` | The three-digit code, as text, e.g. `"440"`. |
| `label` | The division's name. |
| `score` | The classifier's score, or `null` (a division from a label or a person has none). |
| `classifier_version` | The classifier's version number, or `null`. |
| `source` | `"label"` (a made label), `"sorter"` (the classifier) or `"user"` (a person chose it). Readers refuse other values. |
| `second_division` | The second-best division code, or `null`. |

`samebook`: what is needed to tell whether two files are the same book, and which copy to keep, without the PDF.

| Key | Meaning |
|---|---|
| `minhash` | 128 unsigned 32-bit numbers: the MinHash of the text (`fingerprint.rs`). Empty for a text too short to fingerprint. |
| `mean_vector` | The mean of all the pieces' vectors scaled to length 1, as base64 of little-endian **f16** (IEEE half precision), 1024 values (2048 bytes). Rounded to half precision before it is stored, so a pack reads back exactly as written. |
| `text_pages` | Pages with real text on them. |
| `pages` | Pages in the PDF. |
| `ppi` | Typical resolution of the page images in pixels per inch, or `null` when the PDF has no page images. |
| `source_size` | The source file's size in bytes. |

Both `cache-build pdf` and the build service write `samebook` into every pack they build (`build_pack*` fills it in, so no caller
has to). A pack changed afterwards, such as a rename, keeps it.

### Which copy is better

When two files are the same book, the copy to keep is chosen by this order, the first line that differs deciding. It is exact and
it ends in a tie-break that cannot tie, so every device picks the same copy from the same packs:

1. more pages with real text (`text_pages`);
2. more pages (`pages`);
3. higher ppi (sharper page images); a missing ppi ranks lowest;
4. the smaller source file (`source_size`);
5. the lower `doc_id` (compared as text, byte by byte).

`cache_builder::samebook::{CopyQuality, compare_copies, best_copy}` implement it. A pack without `samebook` (an older pack) cannot
be compared.

## Revision 4 (compatible): the `book` block

Revision 4 adds one optional header key, `book`. The header's `cdoc` stays 1. A pack without it (revision 2 or 3) loads, and a reader that does not
know it ignores it, so older and newer packs and readers mix freely: **readers must still accept revision 2 and 3 packs**. A revision 4 reader
treats a revision 3 `division` as `book.suggested`, a missing `book` as no facts beyond the header's own `title` and `source`, and a pack that has
neither as having no suggestion.

The pack is immutable and written once, by the device that built the book. It holds the book's **facts**. What a person or a device does with
the book afterwards (where it is shelved, its call number, a new title, hiding it) is **not** in the pack: it goes in the per-device log
(LIBRARY-LOG.md). Because nothing that syncs ever has two writers, the pack is never edited to record such a change.

```json
"book": {
  "title": "Wilderness Medicine Handbook, 7th ed",
  "source_title": "wilderness_med_7e.pdf",
  "original_blake3": "b3f1...",
  "compression": {"original_size": 58000000, "stored_size": 41000000, "level": "smaller_scans", "preset": "balanced",
                  "kept_original": false, "kept_reason": null, "psnr_min": 31.2},
  "ocr": {"engine": "doctr", "version": "1.1.0", "pages_ocrd": 412},
  "suggested": {"div": "210", "label": "First aid", "score": 0.91, "classifier_version": 3, "source": "classifier", "second_div": "220"},
  "author": "Eric A. Weiss",
  "edition": "7th edition",
  "year": 2018
}
```

| Key | Meaning |
|---|---|
| `title` | The book's title as built: the caller's, else the PDF metadata title, else the file name (the same as the header's `title`). |
| `source_title` | The title before a caller's title or a titles file replaced it, `null` when it was not replaced. |
| `original_blake3` | BLAKE3 (hex) of the file **as it arrived**. This is the book's identity, even if the stored file was compressed (`source.blake3` is then the stored file's hash) or the text came from an OCR copy that is never shipped. |
| `compression` | What compression did, as the build record has it (`original_size`, `stored_size`, `level`, `preset`, `kept_original`, `kept_reason`, `psnr_min`), or `null`. |
| `ocr` | `{engine, version, pages_ocrd}`: the text came from OCR (`pages_ocrd` is how many pages it read), or `null`. |
| `suggested` | `{div, label, score, classifier_version, source, second_div}` or `null`. `source` is `classifier` or `label` (readers refuse other values). `score`, `classifier_version` and `second_div` are `null` when unknown (a label has no score). It is a suggestion, not a shelf: the shelf is the latest `place` in the log. |
| `author` | Optional. Who wrote the book: a string of 1 to 200 characters. |
| `edition` | Optional. The edition, for example `"7th edition"`: a string of 1 to 60 characters. |
| `year` | Optional. The year of this edition: a JSON integer from 1400 to 2100. |

`author`, `edition` and `year` are additive and optional (no revision change; a reader that does not know them ignores them). They are
written **only when known**: the key is absent otherwise, never `null` and never an empty string. Bookshelves reads them for the book's
catalogue card and hides each one that is absent.

Every other key of `book` is always written (`null` when unknown). `cache-build pdf` and the build service write the block on every pack:

- `title` and `source_title`: from `--title` or the PDF metadata, as before (a `--titles` file replaces the title, keeping the old one as `source_title`).
- `original_blake3`: the hash of the file as it came (before `--compress`). `--original-blake3 HEX` names it when the PDF given is an OCR copy.
- `compression`: the outcome of `--compress`, else `null`.
- `ocr`: `--ocr-engine E --ocr-version V [--ocr-pages N]`, or `--ocr-json FILE`. With an OCR record every page of the PDF is marked as OCR text
  (`text_source_ocr_pages` lists all pages: an OCR'd copy has its whole text layer replaced); `--ocr-text-pages 1-5,9` lists only the pages that are (partial OCR). The JSON is either `{"engine", "version", "pages_ocrd", "original_blake3"?}`
  (applies to every PDF in the call) or an object of those keyed by input file name (a file with no entry has no OCR record). The recon OCR'd
  copies use this.
- `suggested`: from `--labels` (source `label`, see below) or, in the build service, the classifier (source `classifier`).

## Pages in, pack out (`pages.json`)

There is one pack writer (`cache_builder::pagewriter::build_pack_from_pages`). It takes the text of a document page by page and
makes the pack with the shared chunker (`cache_chunk`); it reads no PDF and has no MuPDF dependency, so the core can call it
later. **Any OCR engine's output, a phone's text extractor and `cache-build pdf` all enter here**, so the same pages give the
same passages wherever they were made. `cache-build pdf` reads the PDF with MuPDF, lays it out, converts what the layout step
made into these pages and calls the same writer.

`pages.json` is a JSON array, one object per page:

```json
[
  {"pdf_page": 1, "label": "i", "text_source": "layer",
   "blocks": [
     {"text": "Wells", "kind": "heading", "level": 1},
     {"text": "A well is a hole dug to reach water. Dig below the dry season level.", "kind": "body"},
     {"text": "Hand-dug wells are slow work.", "kind": "aside"}
   ]},
  {"pdf_page": 2, "label": "2", "text_source": "ocr", "blocks": [{"text": "The text of the page, as one paragraph.", "kind": "body"}]}
]
```

| Key | Meaning |
|---|---|
| `pdf_page` | The 1-based page of the PDF (what a viewer opens). Required, at least 1, once each. |
| `label` | The printed page label (a numeral or number). Empty or absent: the PDF page number. |
| `text_source` | `"layer"` (the PDF's text layer; the default when absent) or `"ocr"`. Anything else is refused. |
| `blocks` | The page's blocks **in reading order**. A page with none has no text (the writer lists it in `ocr_pages` unless the caller says otherwise). |
| `blocks[].text` | The text of one paragraph or heading, whitespace normalised. (`cache-build pack` normalises it: runs of whitespace, no-break and zero-width spaces become one space, soft hyphens and control characters go.) |
| `blocks[].kind` | `"body"` (running text), `"heading"`, or `"aside"` (a pull-quote, epigraph, caption or note: the chunker keeps it from interrupting a sentence that runs on to the next page). |
| `blocks[].level` | Heading level from 1 (outermost); 1 when a heading has none; 0 is refused. |
| `blocks[].bullet` | Optional, `true` for a list item. |

The simplest input, a phone with no layout of its own, is one `body` block per page. Passages never cross a heading, are cut at
sentences, and are about 200 words, as for every pack (the chunker rule is `CHUNKER_VERSION`).

`cache-build pack --pages pages.json --out <packs dir> --doc-id ID (--fake-embedder | --embed-url URL)` writes the pack. It also
needs the file the pages came from (`--source FILE`, or `--source-blake3 HEX --source-size N --file-name NAME`) and takes the
same fact flags as `pdf` (`--doc-version`, `--title`, `--https`, `--created-at`, `--original-blake3`, `--labels`, `--titles`,
`--classes`, `--ocr-engine E --ocr-version V [--ocr-pages N]`, `--ocr-json FILE` with one object) plus `--meta-title T`, `--ppi N`,
`--year N`, `--page-count N`, `--extractor-name NAME` and `--extractor-version V` (default `pages` / `1`; the producer's name),
and `--layout-version N` (only when the producer laid the pages out with a layout version of its own). A page marked
`"text_source": "ocr"` needs the OCR record (`book.ocr`); `pages_ocrd` defaults to the number of such pages.
`cache-build pages <in.pdf> --out pages.json` writes the pages the layout step makes of a PDF (for debugging and the equality test).

## Layout version

`layout::LAYOUT_VERSION` (2 now; 1 was the layout before the column fix) is written to every pack `cache-build pdf` makes, as
`extractor.layout_version`, beside the extractor version (`EXTRACTOR_VERSION`) and the chunker version (`CHUNKER_VERSION`). The
three together say how a pack's passages were made. **Bump it when the layout step could give different headings, paragraphs
or reading order for the same extracted pages** (a change to `layout()` or what it calls that changes its output); do not bump it
for a refactor, a comment or speed, or for a change to extraction or chunking, which have their own versions. A pack with a lower
version than the code is older, not wrong.

## The library folder and the local view

A built library is the normal library (`shard/`, `cache-library.json`, `documents.tsv`, `SHA256SUMS`) plus:

- `log/builder-<library_id>.jsonl`: the **seed log** (synced; in `SHA256SUMS`). `cache-build library` writes `place` then `assign` for every book that has a suggested
  division. Numbers run from 1 in order of (title, doc_id) within a division, so a rebuild gives the same numbers. Books with no division get nothing (they are in
  Unsorted). A title a `--titles` file replaced is recorded as a `title` event. Every event's `at` is `--built-at` (UTC milliseconds or `YYYY-MM-DDTHH:MM:SSZ`; default
  now), so the same packs and the same `--built-at` give a byte-identical log.
- `.local/docs.json`: the **view**, format 2, rebuilt from the packs and every log (never synced, not in `SHA256SUMS`, not in any search payload). `cache-build view
  --library <dir> [--packs <packs dir>]` makes it again (the packs default to `<dir>/packs`). See LIBRARY-LOG.md for its shape.

`cache-build library --classifier cache-classifier-N.bin` files the books that no label and no pack has placed. Each is scored from its
vectors by the same sorter the build service uses (`cache_builder::sorter`); the model must have been trained on the embedding model
Cache uses (it is refused otherwise). A confident book gets a `place` (by `auto`) and an `assign` in the seed log, as a labelled one does,
and its view entry has `suggested` with source `classifier`, the score, the second choice (`second_div`) and the classifier version.
A book the sorter is not sure of is left in Unsorted: **no `place` event**, and the view still shows the best guess in `suggested` (so a
person's "Place it" can offer it), with no shelf. Packs are not changed. `--sorter-report FILE.tsv` writes one line per book the sorter
looked at: `doc_id, file_name, title, classifier_version, division, score, decision (Filed or Unsorted), top3 (division=score ...), reason (low or no_text)`.
The guess of an unsure book is in the view `library` writes, not in the packs, so `cache-build view` (packs and logs only) shows such a book
with no suggestion.

The format 1 `docs.json` at the library root and `overrides.json` were never released and are gone. `cache-library.json` no longer has a `docs` key, and the
`.cache-library` archive holds the shard and the settings file only (the seed log travels beside it, in the library folder).

### `--labels` and `--titles`

`cache-build library ... --labels labels.json --titles titles.jsonl [--classes classes.json]` (and `cache-build pdf`) fill the suggested
division and the titles for a rebuild:

- `--labels`: a JSON array of `{id, path, final, second_division}` (what `final_labels_v2.json` holds; other keys are ignored).
  `final` is the division (a record whose `final` is not three digits, such as `"unsure"`, is skipped). The book's `suggested` is
  set with source `"label"`, no score and no classifier version (in `cache-build pdf` it goes into the pack; in `cache-build library` it
  decides the seed log's `place`). The label (name) comes from the record's optional `label`, else
  from `--classes` (default: the server's `classes-default.json`), else the code itself.
- `--titles`: JSON Lines `{id, path, title, source_title, method, ok, author?, edition?, year?}`. A line that is not `ok`, or has an
  empty title, gives no title. Otherwise the document's title is the line's, and its old title is kept as `source_title`.
  `author` (1 to 200 characters after trimming), `edition` (1 to 60 characters) and `year` (an integer, 1400 to 2100) are optional.
  A value that fails its check is dropped on its own (the rest of the line stands) and counted in the report. A line may carry them
  with no usable title, and they are taken whenever the line matches a pack, even if `ok` is false. They are written into the pack's
  `book` block only by `cache-build pdf` (and `cache-build pack`), which write a pack. `cache-build library` never rewrites packs:
  it counts the lines that matched but its output (seed log, view, index) has no place for these three, so an existing library gets
  them by rebuilding its packs with `cache-build pdf --titles` (a new pack version), not by re-running `library`.
- How a pack finds its record. A pack records its `doc_id`, its source's BLAKE3, and the source's file name (the last part of the
  path, not the folder). A record is matched by, in order: (1) `doc_id` equal to the record's `id`; (2) the source BLAKE3 equal to
  the record's optional `blake3`; (3) the file name equal to the last part of the record's `path`, **only when exactly one record
  has that name**. Records that share a file name are matched only by (1) or (2). The command prints how many documents matched,
  were ambiguous and were not found. For a rebuild that must match every document, give the records a `blake3` (or build with
  `--doc-id` set to the record's `id`).

## From packs to a library

`--vector-datatype f32|f16` (default `f32`) chooses how the written shard stores its vectors: Qdrant's `float32` or `float16`. Packs
stay f32, and queries are f32 either way. The choice is recorded only in the shard's own config; `cache-library.json` has no field
for it, so it is not repeated there.

`cache-build library <packs dir> --out <dir> --id ID --title TITLE` takes, for each `doc_id`, the pack with the highest
`doc_version`, and writes `<dir>/shard/` (a Qdrant Edge shard: one unnamed 1024-dimension Cosine vector) and
`<dir>/cache-library.json` (format 1), `<dir>/log/builder-<id>.jsonl` and `<dir>/.local/docs.json` (see above), plus `<dir>/documents.tsv` (a header row, then `doc_id`, `version`, `title`, source
BLAKE3, pieces, pages for each document) and `<dir>/SHA256SUMS` (the SHA-256 of every other file in the folder, `sha256sum -c`
format). `--packs <dir>` names the packs folder (a first argument works too). No `index/` is written: the keyword index is built
on the device when the library is added (`keyword_index` "auto"). Packs go through the general writer
(`cache_builder::library::write_library`, one `LibDoc` per document; `LibDoc::from_pack` is the adapter), which any other source of
pieces with vectors can feed. Each piece becomes a point:

- id: `UUIDv5(c4b95b91-e641-5c16-91a0-13ba2f6f7970, "<doc_id>:<doc_version>:<i>")` (docs/LIBRARY-FORMAT.md);
- payload fields mapped in `cache-library.json`, named exactly as today's libraries: `title`, `text`, `page`, `source`
  (always `book`), `link` (the `https` address, else empty), `doc_id`, `doc_version`;
- extra payload fields that are not mapped, so the assistant never sees them: `heading_path` (array of strings, always),
  `source_blake3`, `pdf_page` (when known), `page_end` (a page label, only when the piece crosses a page) and `pdf_page_end`
  (1-based PDF page, same condition); and, when the writer is given them, `author`, and `zim_id` (the ZIM header UUID in lowercase
  8-4-4-4-12 form, as in the core's `zim:<uuid>/<path>` addresses, checked by the writer) with `zim_path`.

All packs of one library must share the same `embedding.embedder` and 1024 dimensions.
