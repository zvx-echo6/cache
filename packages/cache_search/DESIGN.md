# cache_search — design draft (for review)

Status: interface draft, 2026-10-25 (revised the same day: libraries are Qdrant collections opened with Qdrant Edge). Header reviewed once; code not written yet.

## What it is

One Rust crate that does all of Cache's search: keyword search over ZIMs and libraries, meaning (vector)
search over libraries, the merge into one ranked list, snippets, `read`, and the tool-result formatting
([n] numbering). The app calls it through a C ABI (FFI); the same crate builds as a Linux library plus a small
CLI/HTTP wrapper for headless use (the baseline test and training-trajectory capture). One codebase, so the
phone and the headless runs return identical results for identical data and query vectors.

Layout (repo `packages/cache_search/`):
- `native/` — Cargo workspace root. Crate `cache_search` (lib: `cdylib` + `staticlib` + `rlib`). Header
  `native/include/cache_search.h`.
- `cli/` — crate `cache_search_cli`, binary `cs` (a member of the `native/` workspace as `../cli`): `cs index-zim`,
  `unpack-library`, `index-library`, `search`, `read`, `status`, `serve` (HTTP). Built as described under
  Headless parity; it calls the same `cs_*` functions as the C ABI.

The crate never links llama.cpp. Query vectors come from the caller (the app via cache_llama `cl_embed`; the
Linux CLI via the same cache_llama C library built for Linux). A library's vectors are computed off-device by whoever builds it, with the embedding model named in the
library's settings file.

## Sources

A handle is opened with a list of sources, of two kinds:
- `zim`: a ZIM file plus its Tantivy index directory (prebuilt and downloaded, or built on the phone).
- `library`: a Qdrant collection's shard, used as it is: no export, no conversion, no splitting. Its settings
  file (below) says which payload fields mean what. Its keyword index is the library's own scored text index if
  it has one, otherwise a Tantivy directory built on the device (`index_library` job).

Addresses (what a citation opens):
- `zim:<zim-uuid>/<article path>` (the ZIM's own UUID, so renamed files still resolve)
- `lib:<library-id>/<point-id>` (`library_id` from the settings file; the point id as Qdrant gives it: an integer or a UUID string)

## Libraries (Qdrant Edge)

A library is one Qdrant collection's shard, opened on the device with Qdrant Edge. This replaces the earlier
own-file library design (a SQLite file with int8/binary vectors) entirely.

Linking. The core links Qdrant Edge from git: package `edge` (path `lib/edge`) at qdrant rev
`0f8c4d791a37a4946347d80486d08c168c2229f1`, with feature `serverless`. The crates.io `qdrant-edge` does not
expose the read-only open. Requires Rust 1.98 or newer. Call `common::flags::init_feature_flags` once at
startup with the defaults.

Getting a library. From a Qdrant server (download `GET /collections/{c}/shards/0/snapshot`), from a link, or
from a file. The app downloads; the core unpacks (`EdgeShard::unpack_snapshot`) and then writes
`segments_manifest.json` at the shard root, listing every `segments/<uuid>` as "active". Server snapshots do
not contain that file and the read-only open requires it. Single-shard collections only in v1.

Opening. Always read-only: `ReadOnlyEdgeShard` with `MmapFs` and a cold `LoadProfile` for search. Opening never
modifies the library files (measured: identical file listings before and after).

Updates. A library is updated from a partial snapshot (`POST .../shards/0/snapshot/partial/create` with the
shard's snapshot manifest) by an `update_library` job (see Jobs):
1. The job closes the library (its read-only shard is dropped).
2. It applies the partial snapshot to the shard directory with `recover_partial_snapshot`. This is a write,
   so it happens only while the library is closed; searching never writes.
3. It rewrites `segments_manifest.json`.
4. It reopens the library read-only.
While the job runs, queries on that library are answered from the old copy if one is kept; otherwise the
source reports `building` and is skipped by search (as for an index build). The full replace from a new
snapshot stays as the fallback (for example when the partial snapshot cannot be applied). A cited address
whose point id is not in the updated library returns error code `not_found` (the app shows it as no longer in
the library).

Risks.
- The `segments_manifest.json` format is internal to Qdrant. The core writes it by hand, so a Qdrant change to
  that format can break opening. Mitigation: the Qdrant rev is pinned. Moving the rev means re-checking the
  manifest format and the read-only open.
- The pinned rev is a git revision, not a crates.io release, so it gets no automatic fixes; the core is built
  against that one revision.

### Library settings file

A small plain-JSON file written by whoever builds the library. App convention: it is named `cache-library.json`
and ships beside the snapshot or download. The app reads it and passes its contents to the core in the
`settings` object of the library's source entry (`cs_open`, `cs_set_sources`) and in the `index_library` job
parameters; the core does no file discovery and never looks for the file itself. Cache asks nothing when the
library is added. The app's Advanced section can override each value (the app edits the object it passes).
Without the file (no `settings` object), the core guesses from the payload field names and the vector size.
v1 format:

```
{
  "format": 1,
  "library_id": "stable id chosen by the builder",
  "title": "Library title",
  "fields": {
    "title": "title", "title_fallback": "book_title",
    "text": "content", "summary": "summary",
    "page": "_start_page", "source_type": "source_type",
    "author": "book_author", "link": null,
    "document": "doc_hash"
  },
  "leave_out": [ {"field": "junk", "equals": true}, {"field": "replaced_by_rebuild", "is_set": true} ],
  "embedding": { "vector": "", "model": "bge-m3 GGUF file name", "sha256": "...", "dims": 1024 },
  "keyword_index": "auto"
}
```
- `format`: settings format version; 1 for this layout.
- `library_id`: stable id chosen by the builder; the same across versions of one library; used in addresses.
- `title`: the library's name shown in the app.
- `fields`: which payload field holds what. All entries are optional except `text`; null or missing = not mapped.
  - `title`: the hit's title.
  - `title_fallback`: used when `title` is empty or missing on a point.
  - `text`: the main text (required). Searched by the keyword index and returned by `read`.
  - `summary`: a short summary; used for snippets when mapped.
  - `page`: the page number in the source book.
  - `source_type`: what kind of source the point came from (e.g. book, transcript).
  - `author`: the author, shown by `read`.
  - `link`: a field holding a URL for the point, if the library has one.
  - `document`: the field identifying the source document; used to collapse duplicates.
- `leave_out`: rules for points that are never shown or indexed. Each rule names a `field` and either
  `equals` (a value) or `is_set` (true = the field exists and is not null). A point matching any rule is left out.
- `embedding`: how queries must be embedded. `vector` is the dense vector's name ("" = the default vector);
  `model` is the embedding model's GGUF file name; `sha256` is that file's hash; `dims` is the vector size.
  The `query_vector` model id from the caller must match `model`.
- `keyword_index`: `"auto"` = use the library's own BM25-scored text index if the collection has one on the
  text field, otherwise build a Tantivy index on the device; `"on"` / `"off"` force the device index on or off.
  This is the setting. What a library actually uses is reported by `cs_status` as `keyword_source`:
  `"own"`, `"device"` or `"none"` (null for ZIMs).

## Keyword index (Tantivy)

- One index per source. Each index_dir records the index format version and the tokenizer (from the ZIM or
  library language; English stemmer by default). An index from an older format is reported as stale.

ZIM: fields `title` (positions, stored), `lead` (first ~1,500 chars of article text,
  stored, for snippets), `body` (indexed, no positions, not stored), `path` (stored). Library (device index only): `point_id` (raw, stored),
`title` (text, stored, with positions), `body` (text from the mapped text field, frequencies only, not stored),
`source_type` (string, stored, fast). English stemmer as for ZIMs. Points matching a `leave_out` rule are skipped
at index time. If the library has its own scored text index (`keyword_source` "own"), no device index is built.
- Body text is read from the ZIM (or the library's text field) at index time and never duplicated in the index.
- Phrase search only on `title`.

## Search and merge

`search(query, options)`; options carry `k`, `offset` (paging), a source filter and an optional query vector
tagged with its embedding model id:
1. Keyword: top 50 (plus offset) from each selected source's keyword index (BM25): a ZIM's Tantivy index, a
   library's own scored index if present, else the library's device Tantivy index.
2. Vector: only for libraries whose settings `embedding.model` matches the query vector's model id; other
   libraries are keyword-only, and the response says which sources used vectors.
3. Merge: the keyword lists across all sources are merged with reciprocal rank fusion (k=60); where a
   vector list exists it joins that fusion as another list (RRF k=60 between the keyword and vector lists);
   one entry per address.
4. Collapse duplicates after the merge and before [n] numbering: library hits with the same `document` field
   value and the same title collapse to the best-ranked one; with no `document` field mapped, hits with
   identical title plus identical snippet collapse. Then fill back up to k from the next-ranked hits.
5. Return results `offset..offset+k` with address, title, snippet, source id/kind/title and page.

Vector search over a library:
- Dense search with the caller's query vector (embedding model per the settings file). `hnsw_ef` is 64, set in
  the core and not exposed in the app. Fetch 50 candidates.
- `leave_out` rules are applied as a post-filter on those candidates, using their payload. They are not sent as
  a Qdrant filter (measured about 8x slower, identical results). If fewer than k candidates survive, the
  candidate count is widened and the search repeated.

Snippets and titles:
- Library hit snippet: the `summary` field if mapped, else the start of the `text` field; at most 400 chars,
  cut at a sentence end. ZIM article: Tantivy snippet over `lead`, falling back to its first sentences, at most
  400 chars.
- Library hit title: the mapped `title` (falling back to `title_fallback`); when the point has a page,
  `<title>, p. <page>`. For a ZIM hit: `<ZIM title>: <article title>`.

## read

`read(address, max_chars)`: ZIM → the article text (HTML stripped to plain text, headings kept); library → the
point's title and mapped text field, plus author, page and source type (null where unmapped) so the app can
render the page.

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

`index_zim`, `index_library` and `update_library` run as jobs: start, poll progress, cancel; checkpoints every N articles
(Tantivy commit + last article or point index) so a cancelled or killed job resumes. `index_library` takes `library_path`, `index_dir` and `heap_mb` (default 200) and builds the device Tantivy
index from the mapped text field; it is resumable via checkpoints like `index_zim`. `update_library` takes `library_path`,
`snapshot_path` (the partial snapshot file) and `snapshot_manifest_path` (the manifest the snapshot was made
against); it runs the update steps under Libraries / Updates. Memory cap via Tantivy
writer heap size (default 200 MB on phones). "Only while charging" is the app's policy, not the core's.

## Threads

A handle is used from one thread at a time. A source whose index a job is building is not searched until the
job is done. Jobs run on their own threads inside the core and are polled.

Opening a library can take tens of seconds (13-37 s measured on the 28 GB recon library), so `cs_open` and
`cs_set_sources` never wait for it. Each library opens on a background thread inside the core; `cs_status` lists
it with `"opening":true` until it is ready (`"opening":false` for every other source, ZIMs included), and search
skips it meanwhile, the same as a source whose index is being built. An open failure is recorded on that source
like other source errors (`id` null, `error` set; retried on the next `cs_set_sources`). A library already open
at the same path is kept by `cs_set_sources`. Closing a handle while a library is still opening is safe: the
thread finishes on its own and drops the result.

Strings returned by the core are freed with `cs_free_string`.

## Headless parity

`cs` (crate `cache_search_cli`, `packages/cache_search/cli/`) is the Linux command line and HTTP wrapper for headless
test runs and training capture. It is a thin layer over the same C ABI functions the app calls: it links the
`cache_search` crate and calls the `cs_*` functions themselves (`cs_open`, `cs_status`, `cs_search`, `cs_read`,
`cs_suggest`, `cs_format`, `cs_conversation_*`, `cs_job_*`), passing JSON in and printing the JSON that comes
out, untouched. It does no ranking, snippeting, numbering or filtering of its own, so for identical data and
identical query vectors its output is the phone's output. The one thing it calls that has no C ABI function is the
core's `library::unpack_library` helper (`cs unpack-library`).

Subcommands (results on stdout as the core's JSON, errors on stderr as `{"code","message"}`, exit status 1):
- `cs index-zim --zim <path> --index-dir <dir> [--heap-mb 200]`: runs an `index_zim` job, prints `state done/total`
  to stderr as it changes and the final progress JSON to stdout. Resumes from the checkpoint in `index_dir`.
- `cs unpack-library --snapshot <file> --dir <dir>`: unpacks a Qdrant shard snapshot and writes
  `segments_manifest.json`; prints `{"dir","segments"}`.
- `cs index-library --library <dir> --index-dir <dir> [--settings <cache-library.json>] [--heap-mb 200]`: an
  `index_library` job; `--settings` is passed as the job's `settings` object.
- `cs search --config <sources.json> --query <text> [--k 5] [--offset 0] [--format] [--json] [embedder flags]`:
  prints the `cs_search` JSON. With `--format` it prints the `tool_message` that `cs_format` gives a fresh
  conversation (with `--format --json`, the whole `cs_format` JSON). Plain `--json` is accepted and is the default.
- `cs read --config <sources.json> --address <addr> [--max-chars 6000]`: the `cs_read` JSON.
- `cs status --config <sources.json>`: the `cs_status` JSON.
- `cs serve --config <sources.json> [--listen 127.0.0.1:8433] [--allow-non-loopback] [embedder flags]`: HTTP, below.
- All commands that open sources take `--open-timeout <seconds>` (default 600). `cs_open` returns at once and
  libraries open on background threads, so the wrapper polls `cs_status` until no source is `"opening"` before it
  searches or serves, and stops with a `busy` error on timeout.
- `sources.json` is exactly the `cs_open` config JSON. One convenience: a library entry may carry
  `"settings_file": "cache-library.json"` (path relative to `sources.json`) instead of `"settings"`; the wrapper
  reads the file and passes its contents as `settings`, the same thing the app does. The core still never looks
  for the file itself.

HTTP (`cs serve`, tiny_http; binds 127.0.0.1 by default and refuses any non-loopback address unless
`--allow-non-loopback` is given; prints `listening <addr>` on stdout when ready; one request at a time, which is
what a handle requires). JSON in, the core's JSON out byte for byte:

| Endpoint | Body | Calls |
|---|---|---|
| `POST /search` | `{query, options}` | `cs_search` |
| `POST /read` | `{address, max_chars}` (default 6000) | `cs_read` |
| `POST /suggest` | `{prefix, options}` | `cs_suggest` |
| `GET /status` | | `cs_status` |
| `POST /conversations` | | `cs_conversation_new`; returns `{"id"}` |
| `POST /conversations/{id}/format` | `{results}` | `cs_format` on that conversation |
| `GET /conversations/{id}/ids` | | `cs_conversation_ids` |
| `DELETE /conversations/{id}` | | `cs_conversation_free`; returns `{"deleted":"<id>"}` |

Errors are the core's `{"code","message"}` with HTTP 400 (`bad_json`), 404 (`not_found`, also unknown
endpoint or conversation), 409 (`busy`, `index_missing`, `index_stale`, `cancelled`), 422 (`unsupported`), 500 (anything else).

Query embedding. Embedder flags: `--embed-lib <libcache_llama.so> --embed-model <model.gguf> [--embed-sha256 <hex>]
[--embed-model-id <id>] [--embed-threads 4]`. The core never links llama.cpp, and cache_llama's `cl_embed`
lives on another branch, so the wrapper loads the built `libcache_llama.so` at run time with the `libloading`
crate from the given path and looks up `cl_embed_load`, `cl_embed_info`, `cl_embed` and `cl_embed_free`. No
llama.cpp code is compiled into `cs`, and the same C functions the app calls produce the vector. When an
embedder is configured and the request has no `options.query_vector`, `cs search` and `POST /search` embed the
query and add `query_vector: {"model": <id>, "vector": [...]}`; a `query_vector` given by the caller is passed
through unchanged. The model id is `--embed-model-id`, default the GGUF file name, and must equal the library's
settings `embedding.model` for vectors to be used (otherwise the library is keyword-only and the response says
so). `--embed-sha256` makes the wrapper hash the GGUF and stop on a mismatch. The settings that define the
vector are constants in one place (`cli/src/embed.rs`, marked as having to match the app): `n_ctx` 512,
`normalize` on, no query prefix, pooling read from the model's metadata and required to be `cls`, and the decided
model bge-m3 Q8_0 (`bge-m3-Q8_0.gguf`, sha256 `c98c7c90...c158bb`). Threads only affect speed.

Tests (`cli/tests/cli.rs`) spawn the binary: status, search, `--format`, read over the small NHS ZIM (index built
with `cs index-zim`); `cs serve` answers `/search`, `/read` and `/status` byte for byte like the CLI, and [n]
numbering continues across two `/format` calls; and, with the embedding library and model mounted, a generated
bge-m3 library found by a paraphrased query through both the CLI and the server.

## Measured on the recon library (2026-10-25)

recon-vm, a 4-core VM, Linux. Device numbers will differ: phone flash and CPUs are slower, and the VM's host
may have cached reads.

- Shard: 3,519,279 points, 11 segments, 28 GB on disk (dense 1024 float32 cosine, no quantization, sparse
  bge-m3-sparse, full-text indexes not scored). Snapshot stream 274-281 s (29.9 GB); unpack 183-272 s.
- Read-only open: 13.5-37 s. Process anonymous memory about 165 MB at every memory cap; the rest is page cache.
- Dense top 10 with post-filter, `hnsw_ef` 64, 20 queries, median / p90:

  | memory cap | median | p90 |
  |---|---|---|
  | 4 GiB | 1.1-1.3 s | 1.4-1.7 s |
  | 1.5 GiB | 1.35 s | 1.9 s |
  | 1 GiB | 2.0 s | 3.1 s |
  | 768 MiB | 1.27 s | 1.87 s |

  `hnsw_ef` 32 and 64 matched the default (ef 100) top 10 on 198-200 of 200 results.
- Qdrant-side `must_not` filter instead of the post-filter: median 11-12 s at 4 GiB, same results as the
  post-filter (200/200).
- BM25 on recon's existing text index: refused ("The text index on content does not score: set scoring on it
  to query it").
- Device Tantivy index over the text field: 3,309,214 docs (210,065 left out), 1.69 GB of text, 229.6 s at
  2 CPUs and 1 GiB cap (about 14,400 docs/s), 594 MB index in 6 segments, peak anonymous memory 394 MB.
  Keyword query top 10: median 25 ms first pass, 3 ms warm.
- Binary size: test binary with Edge 37.5 MB stripped (Linux x86_64).

## Open (needs decisions)

- Multi-shard collections (v1 is single-shard only).
- On-phone latency and build time (open, dense search, `index_library`): to measure on the emulator and a phone.
- Whether 28 GB-class libraries need quantized vectors on the device later.

## To verify

- The contents of `segments_manifest.json` after `recover_partial_snapshot`: whether the core must rewrite it,
  and whether segments added or removed by the partial snapshot are listed correctly.
- A test of the `update_library` flow against a live Qdrant 1.19.1 server's partial snapshot.
