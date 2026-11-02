# Document pack format (`.cdoc`), version 1 (revision 3)

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
| `extractor` | `{name, version}`, e.g. `mupdf` / `0.8.0`. |
| `chunker` | `{version, target_words, max_words}`. |
| `embedding` | `{embedder, dims}`: what made the vectors (the GGUF name for bge-m3, `fake-hash-v1` for the test stand-in) and their size. |
| `created_at` | Text given by the caller (the builder never reads the clock). |
| `page_count` | Pages in the PDF. |
| `ocr_pages` | 1-based PDF pages skipped because they have no text layer (OCR comes later). |
| `pieces` | The number of piece lines that follow. Readers check it. |
| `division` | Optional (revision 3). The division the document is filed in; see below. |
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

`division`: the division the document is filed in.

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

## docs.json

`docs.json` sits at the library root, beside `cache-library.json`, which lists it as `"docs": "docs.json"` (the only key added to
the settings file; the rest is unchanged). It is never part of search payloads: the shard, the keyword index and the assistant do
not see it. It is also inside the `.cache-library` archive, at its root. `cache-build library` writes it every time.

```json
{
  "format": 1,
  "docs": {
    "b3f1...": {
      "division": "440",
      "label": "Canning",
      "score": null,
      "classifier_version": null,
      "source": "label",
      "second_division": "450",
      "title": "How Water Moves",
      "source_title": "Water cycle"
    }
  }
}
```

- `docs` maps each `doc_id` (in doc_id order) to its entry. Every key is always present: `null` when unknown. A document with no
  division has `division`, `label`, `score`, `classifier_version`, `source` and `second_division` all `null`.
- `title` is the title the library uses (also in the search payloads and `documents.tsv`); `source_title` is the title before a
  titles file replaced it, `null` when it was not replaced.
- The writer builds it from the packs' `division` headers and titles. `--labels` and `--titles` (below) override them.
- It is written atomically: a temporary file in the same folder is written and flushed, then renamed over `docs.json`, so a reader
  sees the old file or the new one. `SHA256SUMS` covers it.
- Readers apply the app's `overrides.json` on top of it (a person's own division or title for a document wins over `docs.json`).
  Writing `overrides.json` is the app's job; the builder never writes or reads it.

### `--labels` and `--titles`

`cache-build library ... --labels labels.json --titles titles.jsonl [--classes classes.json]` fill `docs.json` (and the titles)
for a rebuild:

- `--labels`: a JSON array of `{id, path, final, second_division}` (what `final_labels_v2.json` holds; other keys are ignored).
  `final` is the division (a record whose `final` is not three digits, such as `"unsure"`, is skipped). The document's division is
  set with source `"label"`, no score and no classifier version. The label (name) comes from the record's optional `label`, else
  from `--classes` (default: the server's `classes-default.json`), else the code itself.
- `--titles`: JSON Lines `{id, path, title, source_title, method, ok}`. A line that is not `ok`, or has an empty title, is
  skipped. Otherwise the document's title is the line's, and its old title is kept as `source_title`.
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
`<dir>/cache-library.json` (format 1), `<dir>/docs.json` (see below), plus `<dir>/documents.tsv` (a header row, then `doc_id`, `version`, `title`, source
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
