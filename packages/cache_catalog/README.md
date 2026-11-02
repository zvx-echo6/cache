# cache_catalog

Reader for Cache's optional **book catalogue** file, and the Python tool that builds it (`tools/build_catalog.py`).

When a book is added, Cache can look it up in the catalogue. A hit gives the book a clean title, author and year, and the
catalogue's Library of Congress class (converted to a Cache division) is a **tie-breaker** for the on-device sorter. It is
not the decider. The file is optional: Cache works without it.

Book data from Open Library, openlibrary.org. The Internet Archive asserts no new rights over the catalogue, which was built
from library records dedicated to the public domain. The attribution string is stored in the file header
([`Catalog::attribution`]) and is shown wherever catalogue data is shown.

## Reader API (Rust, pure, one dependency: `miniz_oxide`, already in the workspace lockfile)

```rust
let cat = Catalog::open(path)?;                       // reads the header and indexes only; lookups use positioned reads
cat.lookup_isbn("978-0-441-17271-9")                  // -> Option<Entry>; ISBN-13 or ISBN-10, hyphens allowed
cat.lookup_title(&normalise_title(t), &author_surname(a))   // -> Option<Entry>
cat.lookup_book(title, author)                        // the same, normalising for you
Entry { lcc, division, title, author, year }          // lcc "PS3558"; division from the embedded table; year Option<u16>
extract_isbns(text) -> Vec<String>                    // valid ISBNs (check digit verified), as ISBN-13
accept_isbn_match(entry_title, book_title) -> bool    // the safety rule below
```

`try_lookup_isbn` / `try_lookup_title` report a damaged file as `Err` instead of a miss. `set_lcc_table(tsv)` swaps in a newer
conversion table without rebuilding the file.

### The ISBN safety rule

Wikipedia printouts and bibliographies cite other books' ISBNs, so an ISBN found in a book's text proves nothing. Accept an
ISBN match only when `accept_isbn_match(entry.title, book_title)` is true: the normalised titles are split into words, and
the score is the total length of the words they share divided by the total length of the shorter title's words. **Threshold:
0.6** (`MIN_TITLE_OVERLAP`). Weighting by word length means "the" alone does not carry a match ("The Stand" against "The Great
Gatsby" scores 0.375). The shorter title is the denominator because the book's title may carry file-name noise or a subtitle
and the catalogue's title is cut at 100 characters. A title-and-author hit needs no such check (the key already is the title),
but comparing titles on a hit is still cheap insurance.

## File format 1

All integers little-endian. Strings UTF-8. Varints are LEB128 (7 bits per byte, low group first). The file is, in order:

**Header**, `16 + header_len` bytes:

| field | size | |
|---|---|---|
| magic | 8 | `CACHEBKC` |
| format version | u32 | 1 |
| header_len | u32 | bytes after this field up to the end of the header |
| catalogue date | u32 | YYYYMMDD of the Open Library dump |
| build date | u32 | YYYYMMDD |
| hash bits | u8 + 3 pad | 64 in release 1.0.0 |
| attribution | u16 length + bytes | "Book data from Open Library, openlibrary.org" |
| licence note | u16 length + bytes | |
| source | u16 length + bytes | |
| LCC conversion table | u32 length + bytes | the tab-separated `lcc_to_division.tsv`, verbatim |
| 3 section descriptors | 3 x 32 | isbn, title-hash, records: u64 offset (absolute), u64 length, u64 record count, u32 block count, u32 records per block (0 for records) |

**Three sections.** Each starts with its index: one 16-byte entry per block, `u64 first key` (first record id for the records
section) and `u64 block offset` from the section start. A block ends where the next begins (the last at the section end).
Every block is **raw deflate** (RFC 1951, no zlib header) so a lookup binary-searches the index, reads one block with one
positioned read, inflates it, and scans it. Nothing else is read.

1. **ISBN section.** Keys are ISBN-13 as integers, sorted, unique. 8,192 records per block.
2. **Title section.** Keys are the top *hash bits* bits of the 64-bit BLAKE2b digest (`digest_size=8`, read big-endian) of
   `normalised_title + "|" + surname` in UTF-8, sorted, unique. 5,000 records per block.
3. **Records section** (metadata), about 256 KB of uncompressed text per block, ids dense from 0 in block order.

Key block (sections 1 and 2): `u32 n`, then `n` key varints (the delta from the previous key; the first is 0 and the base is
the index's first key), then `n` x `u32` LCC keys, then `n` varints of the record id as a zigzag delta from the previous id in
the block (the first from 0). The LCC key is three subclass letters (5 bits each, A = 1, padded with 0, so "PS" is two) over a
14-bit class number: `(letters << 14) | number`.

Record block: `u32 n`, then per record: varint title length, title, varint *author code* (0 = same author as the record before
it in this block; otherwise author length + 1), the author bytes when given, varint year (0 = unknown). Records are sorted by
author then title, so an author's books sit together and compress well; The first record of a block always names its author. A record id is found by index, then by scanning from the block start.

### Normalisation (must match between the builder and the reader)

* `normalise_title`: Unicode lower-case; keep the maximal runs of alphanumeric characters (`_` is not one), joined by single
  spaces. Builder: Python `str.lower` and `str.isalnum`; reader: `str::to_lowercase` and `char::is_alphanumeric`. They differ
  only on some combining marks in non-Latin scripts, where a title fails to match, never mismatches.
* `author_surname`: the last word of the normalised part of the name before the first comma, or of the whole name.
* ISBN: ISBN-10 converted to ISBN-13; check digits verified; a 13-digit number must start 978 or 979.

### Choices

* **The LCC key is stored per record, not the division.** The division comes from the embedded table at lookup time, so a newer
  table can ship (`set_lcc_table`) or be rebuilt into the header without rebuilding the 700 MB of records. A precomputed
  division per record would only save a table scan of about 226 rows per lookup.
* **Compression is deflate**, decoded by `miniz_oxide` (in `Cargo.lock` as 0.8.9, the backend of the `flate2` that cache_live,
  cache_search and others already use). The builder uses Python's `zlib` at level 9 with raw deflate (`wbits=-15`), so it
  is standard library only. `zstd` would be roughly 10 percent smaller but needs the C `zstd` crate on every target.
* **Title keys are 64 bits** (the whole digest). The hash bits are in the header, so a build can use fewer (48 bits saves about 26 MB
  and still has a collision chance of 5e-8 per lookup, which a title comparison on the hit removes anyway).
* **A new edition of a book already held** (same title key and LCC class) adds its ISBNs to the first edition's record instead
  of a record of its own. Other editions with the same title key but another class keep their own record. When two records share a
  key, the first one in the Open Library dump wins.
* Titles are cut at 100 characters (at a word) and authors at 60.

## Building a catalogue

```
nice python3 tools/build_catalog.py --db catalog.db --lcc tools/lcc_to_division.tsv --out cache-book-catalog-1.0.0.bin
```

`catalog.db` is the SQLite file built from the Open Library edition and author dumps: table `ed` (key, isbn10, isbn13, title,
ntitle, authors, year, lcc; editions that have an LCC class) and `au` (author key, names). The tool needs about 10 GB of memory
for the full catalogue and writes its work files to `/dev/shm`. It writes the file and a `.sha256`.

`tests/fixture.bin` is made by `python3 tools/build_catalog.py --fixture tests/fixture.bin --lcc tools/lcc_to_division.tsv`,
together with `tests/fixture.tsv` (what a reader must find). Rebuild both whenever the format or the normalisation changes.
