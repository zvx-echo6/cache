# cache_search — design draft (for review)

Status: interface draft, 2026-10-25. Header reviewed once; code not written yet.

## What it is

One Rust crate that does all of Cache's search: keyword search over ZIMs and library packs, meaning (vector)
search over library packs, the merge into one ranked list, snippets, `read`, and the tool-result formatting
([n] numbering). The app calls it through a C ABI (FFI); the same crate builds as a Linux library plus a small
CLI/HTTP wrapper for headless use (the baseline test and training-trajectory capture). One codebase, so the
phone and the headless runs return identical results for identical data and query vectors.

Layout (repo `packages/cache_search/`):
- `native/` — Cargo workspace root. Crate `cache_search` (lib: `cdylib` + `staticlib` + `rlib`). Header
  `native/include/cache_search.h`.
- `cli/` — crate `cache_search_cli`: `cs index-zim`, `cs build-pack`, `cs search`, `cs read`, `cs serve`
  (HTTP: `POST /search`, `POST /read`, both calling the same functions as the C ABI).

The crate never links llama.cpp. Query vectors come from the caller (the app via cache_llama `cl_embed`; the
Linux CLI via the same cache_llama C library built for Linux). Concept vectors are computed off-phone by the
pack builder, with the same embedding model and the same cache_llama code.

## Sources

A handle is opened with a list of sources:
- `zim`: a ZIM file plus its Tantivy index directory (prebuilt and downloaded, or built on the phone).
- `pack`: a library pack file (SQLite). Its keyword index is a Tantivy directory beside it, built on first load
  (concepts are short, so this is quick) or shipped prebuilt; it can always be rebuilt from the pack.

Addresses (what a citation opens):
- `zim:<zim-uuid>/<article path>` (the ZIM's own UUID, so renamed files still resolve)
- `pack:<pack-id>/<ext_id>` (the producer's stable id for the concept; the internal integer `concept_id` never appears in an address)

## Library pack format (one SQLite file)

```
meta(key TEXT PRIMARY KEY, value TEXT)
  format_version   "1"
  pack_id          stable id (uuid); the same across versions of one library
  pack_version     set by the producer (e.g. the export date); shown and compared by the app
  title, description, created, builder_version
  embedding_model  e.g. "bge-m3-q8_0" with the GGUF's sha256
  embedding_dims   e.g. 1024 (or a Matryoshka cut)
  vector_encoding  "int8" | "binary+int8"
documents(doc_id INTEGER PRIMARY KEY, doc_hash TEXT UNIQUE, title TEXT, author TEXT,
          published_year INTEGER NULL, pages INTEGER NULL)
concepts(concept_id INTEGER PRIMARY KEY, ext_id TEXT NOT NULL UNIQUE, doc_id INTEGER, page TEXT, title TEXT, summary TEXT,
         key_facts TEXT /* JSON array */, keywords TEXT /* JSON array */, domain TEXT, subdomain TEXT /* JSON */)
vectors(concept_id INTEGER PRIMARY KEY, scale REAL, v_int8 BLOB, v_bin BLOB NULL)
```
- From recon: concepts without `content`; book title and author from recon `documents`; published year from the
  book-date map (`currentness.json`) where known.
- Vector search: brute force. Binary (1 bit per dim) scan of all concepts, re-score the top 200 with int8, keep
  the top 50. No ANN index in v1; add one only if timing on the phone says so.
- Scale: the full recon library is about 3.52 million concepts (Qdrant `recon_knowledge_hybrid`, 2026-10-25),
  so vector size decides the embedding model choice. Vectors only, whole library:

  | dims | int8 | binary |
  |---|---|---|
  | 1024 | 3.6 GB | 450 MB |
  | 768 | 2.7 GB | 338 MB |
  | 384 | 1.35 GB | 169 MB |
  | 256 | 0.9 GB | 113 MB |
  | 128 | 0.45 GB | 56 MB |

  Binary is scanned in full per query (mmapped, streamed); int8 is read only for the ~200 re-scored rows, so
  int8 costs storage, not RAM. Any split of a library (by domain, or e.g. a video pack) is the producer's choice and each split is its own pack file.
- Stable ids: `ext_id` is a producer-supplied stable string id for each concept (for recon, the Qdrant point id).
  `concept_id` is internal (the `vectors` table joins on it). `cs_search` returns, and `cs_read` accepts, `ext_id`
  addresses only.
- Versions and updates: an update replaces the whole file. `pack_id` stays the same across versions of one
  library; `meta.pack_version` (set by the producer) lets the app show and compare versions. There are no delta
  or update files. A cited address whose `ext_id` is not in the new file returns error code `not_found` (the app
  shows it as no longer in the library).
- Separate packs: a separate pack, such as a video pack, is a separate file in the same format with its own
  `pack_id`. The producer makes any split (for recon, its exporter, e.g. filtering `source_type=transcript`). The
  core treats every pack the same.
- Text compression (zstd dictionary) is deferred until sizes are measured.

## Keyword index (Tantivy)

- One index per source. Each index_dir records the index format version and the tokenizer (from the ZIM or
  pack language; English stemmer by default). An index from an older format is reported as stale. ZIM: fields `title` (positions, stored), `lead` (first ~1,500 chars of article text,
  stored, for snippets), `body` (indexed, no positions, not stored), `path` (stored). Pack: `title`, `summary`,
  `key_facts`, `keywords` (stored), `concept_id`.
- Body text is read from the ZIM at index time and never duplicated in the index.
- Phrase search only on `title`.

## Search and merge

`search(query, options)`; options carry `k`, `offset` (paging), a source filter and an optional query vector
tagged with its embedding model id:
1. Keyword: top 50 (plus offset) from each selected source's Tantivy index (BM25).
2. Vector: only for packs built with the vector's embedding model; other packs are keyword-only, and the
   response says which sources used vectors.
3. Merge with reciprocal rank fusion (k=60) across all lists; one entry per address.
4. Return results `offset..offset+k` with address, title, snippet, source id/kind/title and page.
- Snippet: pack concept → summary plus key facts, cut to ≤400 chars at a sentence end. ZIM article → Tantivy
  snippet over `lead`, falling back to its first sentences, ≤400 chars.
- Title for a pack hit: `<book title>, p. <page>: <concept title>`, book title cut to ~60 chars and `, p. <page>`
  left out when there is no page. For a ZIM hit: `<ZIM title>: <article title>`.

## read

`read(address, max_chars)`: ZIM → the article text (HTML stripped to plain text, headings kept); pack → the
concept's title, summary and key facts, plus book title, author, page and published year so the app can
render the concept page.

## Browse

Browse renders ZIMs as websites, so the core also serves raw entries: `cs_zim_get` (bytes + mime type,
following redirects: HTML, CSS, images), `cs_zim_main_page`, and `cs_suggest` (title suggestions for the
address bar). The ZIM reader must therefore handle every entry type in current ZIMs, not only article text. Cut to `max_chars` at a paragraph end. The app sizes
`max_chars` (~6,000 ≈ 1,500 tokens) because the core has no tokenizer.

## Formatting ([n] numbering)

A conversation object owns the numbering. `format(conv, results)` assigns the next numbers (first call [1]..[5],
next [6].., an address seen before keeps its old number) and returns the exact tool message
(`[n] <title> — <snippet>` lines) plus the id map `[{n, address, title}]` the citation check uses.
Weather and other live-source tools can pass their results through the same formatter so all numbering stays in
one place.

## ZIM reading

Options to evaluate first (report before committing):
1. libzim (C++) built WITHOUT Xapian and ICU, linked statically. Needs a C++ toolchain per ABI; size to measure.
2. A Rust ZIM reader (e.g. the `zim` crate) if it handles current ZIMs (zstd clusters, new namespace scheme);
   simplest to cross-build. To verify against our ZIMs (wikipedia maxi 2026-02, ready.gov, nhs medicines).

## Jobs

`index_zim` and `build_pack_index` run as jobs: start, poll progress, cancel; checkpoints every N articles
(Tantivy commit + last article index) so a cancelled or killed job resumes. Memory cap via Tantivy writer heap
size (default 200 MB on phones). "Only while charging" is the app's policy, not the core's.

## Threads

A handle is used from one thread at a time. A source whose index a job is building is not searched until the
job is done. Jobs run on their own threads inside the core and are polled.
Strings returned by the core are freed with `cs_free_string`.

## Headless parity

`cs serve` exposes the same search/read/format. The test and capture harness call it with query vectors from
cache_llama built for Linux. Until `cl_embed` exists, the interim is llama.cpp's own embedding code at the same
commit cache_llama pins (v0.7.0, 620d2225c) and the same GGUF; to be replaced by cache_llama before any training capture.

## Open (needs decisions)

- Embedding model (issue #10): decided by the owner from benchmark numbers (bge-m3, EmbeddingGemma-300M,
  nomic-embed v1.5, bge-small / e5-small): recall on real recon questions at each candidate dims
  (1024/768/384/256/128) and encoding (int8, binary + int8 re-score), whole-library vector size, and query
  embed time on the emulator.
- ZIM reader choice (above).
