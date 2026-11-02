# Document pack format (`.cdoc`), version 1 (revision 2)

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

## From packs to a library

`cache-build library <packs dir> --out <dir> --id ID --title TITLE` takes, for each `doc_id`, the pack with the highest
`doc_version`, and writes `<dir>/shard/` (a Qdrant Edge shard: one unnamed 1024-dimension Cosine vector) and
`<dir>/cache-library.json` (format 1), plus `<dir>/documents.tsv` (a header row, then `doc_id`, `version`, `title`, source
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
