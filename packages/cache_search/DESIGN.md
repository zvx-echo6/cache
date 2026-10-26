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
  `unpack-library`, `index-library`, `library-manifest`, `update-library`, `search`, `read`, `status`, `tool`, `tool-schemas`, `serve` (HTTP). Built as described under
  Headless parity; it calls the same `cs_*` functions as the C ABI.

The crate never links llama.cpp. Query vectors come from the caller (the app via cache_llama `cl_embed`; the
Linux CLI via the same cache_llama C library built for Linux). A library's vectors are computed off-device by whoever builds it, with the embedding model named in the
library's settings file.

## Sources

A handle is opened with a list of sources, of two kinds:
- `zim`: a ZIM file plus its Tantivy index directory (prebuilt and downloaded, or built on the phone). On builds with
  the `xapian` feature (Windows, Android; below), a ZIM that carries its own Xapian index is searched through that
  index and needs no index directory.
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

Updates. A library is updated from a partial snapshot by an `update_library` job (see Jobs). What the Qdrant
sources at the pinned rev say (read in full, 2026-10-25):
- The server makes one with `POST /collections/{c}/shards/{s}/snapshot/partial/create`; the body is the client's
  snapshot manifest (`SnapshotManifest`, JSON: segment id -> segment version + file versions). It streams a tar
  of the changed files only (format "streamable": `segments/<id>/files/...` plus a `segment_manifest.json`
  per segment, an empty `wal/`, clocks). If the manifest is exactly the server's, it answers with an
  "empty partial snapshot" error instead.
- Qdrant Edge cannot create a snapshot, full or partial. The creation code (`snapshot_all_segments`, `LocalShard::get_snapshot_creator`) is in
  `lib/collection`, which Edge does not use. What Edge has: `EdgeShard::unpack_snapshot`,
  `EdgeShard::snapshot_manifest` and `EdgeShard::recover_partial_snapshot` (`lib/edge/src/edge_shard/snapshots.rs`).
  Tests build a partial snapshot from the lower-level per-segment function (see Tests below).
- `snapshot_manifest` exists only on the read-write `EdgeShard`, not on `ReadOnlyEdgeShard`, and
  `EdgeShard::load` is a write (it saves `edge_config.json`, replays the WAL and may add an appendable
  segment). The core therefore computes the manifest only while the library is closed (`cs library-manifest`, see
  Headless parity); it refuses when the library is open in the same process.
- `recover_partial_snapshot(shard_path, current_manifest, unpacked_dir, snapshot_manifest)` takes the snapshot
  already unpacked, merges it into the shard folder by moving files (it deletes segments and files the server no
  longer has) and ends with a read-write `EdgeShard::load`, which it returns. It is not atomic: a failure
  half-way (disk full, truncated archive) leaves its target half-merged. So the core never runs it on the
  library: it runs it on a real copy (below), and a failed update leaves the library as it was. `current_manifest` is the manifest the snapshot was cut against, which is what the job
  takes from `snapshot_manifest_path`; `snapshot_manifest` is read from the unpacked snapshot itself.
- Hard-link staging was evaluated (2026-10-25) and rejected. The idea: make a sibling folder of hard links to
  every library file, recover the snapshot into it, verify, swap with renames, delete the old folder. It is safe
  only if nothing in the update path writes into an existing inode. At the pinned rev (0f8c4d79) it does:
  - Merge (`lib/edge/src/edge_shard/snapshots.rs:40-61`): `move_file` (`lib/common/common/src/fs/move.rs:38-60`)
    renames (new name, safe) and `remove_file`/`remove_dir_all` only drop names (safe), and the WAL folder is
    replaced by remove + rename (safe). But the segments folder is merged with `move_dir`
    (`snapshots.rs:51-53`, `snapshot_utils.rs:125`): `rename` of a folder onto a non-empty one fails
    (`move.rs:16-18`), so it falls back to `fs_extra::dir::move_dir` (`move.rs:24-26`; fs_extra 1.3.0
    `dir.rs:1119-1148`), which per file calls `file::move_file`, i.e. `std::fs::copy` over the existing
    destination (`file.rs:245-260`, `file.rs:127`): open, truncate, write, into the shared inode. Every file the
    snapshot carries that the library already has is overwritten in place. Measured: 35 of 52 files of the
    original changed content through the links.
  - The read-write `EdgeShard::load` that ends `recover_partial_snapshot` (`snapshots.rs:63`), and the one
    `library_manifest` uses (`edge_shard/mod.rs:130-205`), opens components writable: `DynamicStoredFlags`
    (`flags_a.dat`, `status.dat`: `segment/src/common/flags/dynamic_stored_flags.rs:118-126`, `157-171`, `OpenOptions
    ... write(true)`, `set_len`, mmap `writeable: true`), the Gridstore trackers (`blobstore/src/tracker/mod.rs:44-46`,
    `writeable`), chunked vector storage (`chunked_vectors/chunks.rs:124`, `writeable: true`), then `check_consistency_and_repair`, pending-change recovery and a flush on drop
    (`edge_shard/mod.rs:535`, `547`, `325`). Seen in the measurements though not traced to a line: the mutable id
    tracker files and `vector_storage/deleted.dat` are written too. `segment.json` and `edge_config.json` are written with write-new-then-rename
    (`common/fs/ops.rs:13-36, 45` via `atomicwrites`; `SaveOnDisk` the same), which is safe. Measured on an unchanged optimized library: 21 of 96
    files changed mtime through the links (payload `tracker.dat`, every `flags_a.dat`, `vector_storage/deleted*`,
    `vectors/status.dat`), content equal; after a merge one id-tracker file changed content.
  - So the set to copy instead of link is not small or knowable from file names: it is every file of each
    mutable component across segment types, and it includes the big data files (Gridstore pages, vector chunks)
    of appendable segments, which are opened writable too and would be written if the load had anything to
    repair. The three `hard_link_staging_*` tests record the measurements and fail if a Qdrant bump changes
    them (then re-evaluate).
  - A rename-only merge without the read-write load (execute `SnapshotUtils::partial_snapshot_merge_plan`
    ourselves) would be safe on links, but it gives up what that load does after a merge
    (`check_consistency_and_repair`, an appendable segment, `edge_config.json`); not done.
- Real-copy staging (shipped). `update_library` copies the whole library folder to `<library>.cs-stage` beside it
  (same parent, so the swap is a rename; every file is read and written to a new file, no hard links,
  `libupdate::copy_tree`), runs Qdrant's own `recover_partial_snapshot` (merge + read-write load) on the copy,
  rewrites the copy's `segments_manifest.json`, flushes the copy to disk, and swaps: rename `library` to
  `<library>.cs-old`, rename the copy to `library`, open `library` read-only once (the check, and the shard for
  the handles), delete `.cs-old`. The library is not written to until the first rename, so:
  - Failure before the swap (copy, merge, load, flush, an injected test failure): the copy is deleted, the
    library is as it was byte for byte (tested by content hash and mtime of every file), and the handles open it
    again. There is no half-merged library and no replace-from-a-full-snapshot step.
  - Failure of the last open, after the swap: the swap is undone (the new library renamed to the staging name and
    deleted, `.cs-old` renamed back) and the job fails.
  - Which path the handed-over shard is opened at. The Edge API keeps paths in the opened shard:
    `ReadOnlyEdgeShard` stores the path it was opened with (`read_only/mod.rs:55`, `path()` at `91`, and the
    `LocalSegmentEnumerator`/`ManifestSegmentEnumerator` built from it, `lifecycle.rs:127-130`), and every
    `ReadOnlySegment` stores its `segment_path`, which `live_reload` and `config_reload` reopen files by
    (`segment/src/segment/read_only/config_reload.rs:112-226`, `read_only/live_reload.rs:152-157`). Open files and
    mmaps would survive the rename of their folder, but the stored paths would not, and the API does not say
    which later operations use them. So the shard is opened at the FINAL path after the swap, not at the staging
    path before it: it is correct whatever happens to the staging name. The verify-before-swap this gives up is
    replaced by verify-then-undo, and a crash in that window is handled by the leftover rules below.
  - Cost: the swap needs library + snapshot + staging copy on disk at the same time, plus `.cs-old` for a moment
    (library size twice), hence the space check below; and the copy time (a
    28 GB library is read and written once: not yet measured at that size).
- Free-space check. Before the job closes the library or creates anything it computes needed = library size (sum
  of the file sizes) + partial snapshot file size + margin, where margin = max(5% of the library size,
  256 MiB) (`libupdate::MARGIN_PERCENT`, `MARGIN_MIN_BYTES`: the file system's own overhead, files the load adds,
  other writers on the same disk). Available is `statvfs` (`f_bavail * f_frsize`) on the library's file system
  (the `libc` crate, already in the lockfile). If needed is larger than available the job fails at once with code
  `no_space`; the error JSON is `{"code":"no_space","message":...,"needed":N,"available":N}` (bytes) and the
  disk is unchanged. Tests fake the available bytes with a hook (`fake_available_bytes`) and compare the hash of
  the whole tree before and after.
- Crash leftovers. A crash can leave `<library>.cs-stage` and/or `<library>.cs-old`. They are put right when a
  library is opened (`cs_open`, with the library marked updating meanwhile; a missing library is handled when the
  source is added) and when an `update_library` job starts, and nowhere else:
  - `.cs-stage` is always deleted.
  - `.cs-old` and a complete `library`: the swap finished, `.cs-old` is deleted.
  - `.cs-old` and no `library` (crash between the two renames): `.cs-old` is renamed back to `library`.
  - `.cs-old` and a `library` that is not complete (the swap finished but the new library does not work): the
    `library` is deleted and `.cs-old` renamed back. (This case is an addition to the three rules asked for.)
  - "Complete" is what the code can check: `segments_manifest.json` is a file holding a JSON object that lists at
    least one segment, every listed segment is a folder under `segments/`, and the library opens read-only (the
    cheap scroll profile, not counted as an open, nothing kept) with as many segments as the manifest lists (the open
    drops a segment whose files are gone without an error; found by a test). It does not prove that the contents are the
    intended ones. The open is only done when `.cs-old` exists. The check cannot see other processes: it assumes
    the caller owns the library.
  - An incomplete library with no `.cs-old` is never deleted or repaired, only reported as `damaged`. When a
    library is opened for search (`cs_open`, `cs_set_sources`), and at the start of `update_library` and
    `library_manifest`, an existing `segments_manifest.json` is compared with what is there: a listed segment
    folder that is missing, or an open that finds fewer segments than the manifest lists (the open drops a segment
    whose files are gone), fails with code `damaged` ("opening" false, "id" null, "error" set in `cs_status`; the
    job fails). Nothing is deleted or rewritten (the manifest is not regenerated) and nothing is kept open. A
    library with no manifest (a freshly dropped-in server snapshot) gets one written from its segment folders, as
    before, so it cannot be checked for missing segments. The update jobs make this check with one extra
    read-only open (uncounted, scroll profile) before they close anything.

The job, in order:
0. Space check (above). Fails with `no_space` before anything is closed or created.
1. The library is marked as updating before `cs_job_start` returns. Search skips it, `cs_read` answers `busy` and
   `cs_status` shows `"updating":true` (no old copy is kept for queries). The job waits for background opens of
   the library to finish, then closes it: the shard is taken out of every open handle's cell (a search that is
   using it finishes first).
2. It unpacks the snapshot into a sibling folder (`<library>.cs-update-tmp`, same file system) and checks it is a
   partial snapshot (every segment has a segment manifest, there is a `wal/` folder). Corrupt or full snapshots
   fail here, with the library untouched.
3. Staging: copy the library to `<library>.cs-stage`, apply the snapshot to the copy with
   `recover_partial_snapshot` (a write, so only ever on the copy), rewrite the copy's `segments_manifest.json`
   from the `segments/` folders (the server snapshot does not carry it and `EdgeShard::load` does not write it
   unless a Qdrant feature flag is on), flush the copy.
4. Swap: `library` -> `<library>.cs-old`, copy -> `library`.
5. It opens the shard read-only once, at the final path. That one open is both the check that the library opens
   and the shard the handles use afterwards: the job hands the opened shard (shared, an `Arc`) to the cell of
   every handle that had the library open, and each such handle only refreshes its numbers (point count,
   settings) when it next looks: there is no second open (a test counts the opens). The open is warmed for the
   vectors the handles search with (their load profiles merged); with no handle open it uses the cheap scroll
   profile and the shard is dropped. A handle that had already turned the library into an `updating` source keeps
   its cell, so it gets the shard too. Then `.cs-old` is deleted (best effort; the leftover rules delete it
   otherwise). When the job ends (done, failed or cancelled) the library stops being `updating` and its
   generation goes up. Only a handle with nothing handed back (the job failed or was cancelled after the close)
   opens the library again, on a background thread (`"opening":true` until ready); if that open fails the
   source is listed with its error, like any source that cannot be opened.
Progress is `done`/`total` steps, total 5 (closed, unpacked, staging copy updated, swapped, opened). Cancelling is
honoured before the staging copy starts and ignored after it. On any failure the job ends `failed` with the
error and the library is as it was (reopened from disk).
How the job finds the library: `cs_job_start(kind, params)` has no handle argument and a handle is used from one
thread, so the job and the handles meet in a process-wide registry keyed by the library's canonical path
(`libreg.rs`). Each open library keeps its shard in a mutex cell registered there; the job takes shards out of
the cells and a handle notices the change the next time it is called (every call starts by looking). No ABI
change was needed. The manifest of the library is available through the job kind `library_manifest`
{"library_path","out_path"}, which closes the library in every handle exactly like `update_library` (marked
updating, search skips it), then does what `cs library-manifest` does (the read-write `EdgeShard::load`, the
manifest), writes the JSON to `out_path` (a temporary file next to it, renamed; `out_path` must not be inside the
library folder), rewrites `segments_manifest.json`, and opens the library read-only once and hands that shard
back as above. Progress steps, total 5: closed, loaded and manifest computed, manifest written, `segments_manifest.json`
rewritten, reopened (checked). Cancelling is honoured before the read-write load and ignored after it. It is
`busy` while an update, another manifest job or an index build uses the library. The file is byte for byte what
`cs library-manifest --out` writes for the same library (tested; both use the same function, which writes the
keys sorted because the manifest holds hash maps and the same library should give the same bytes every time).
A cited address whose point id is not in the updated
library returns error code `not_found` (the app shows it as no longer in the library).

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

## Keyword index (Tantivy, and a ZIM's own Xapian index)

Hybrid, per ZIM source. With the Cargo feature `xapian` (default; effective on Windows and Android, see
"ZIM built-in index (libzim)" below):
- a ZIM that has the full-text index `X/fulltext/xapian` is searched through it, with no `index_dir` needed. `cs_status`
  lists it as `"indexed":true,"building":false,"stale":false` with `"keyword_source":"own"` (the ZIM's own index, the same
  word as a library's own scored index; the field appears for these ZIMs only);
- any other ZIM (no built-in index, or a build without the feature) uses its Tantivy index exactly as described next.
An `index_zim` job still builds a Tantivy index for any ZIM; a ZIM with a built-in index simply does not use it.

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
1. Keyword: top 50 (plus offset) from each selected source's keyword index (BM25): a ZIM's own Xapian index
   if it has one (feature `xapian`), else its Tantivy index; a library's own scored index if present, else the
   library's device Tantivy index.
2. Vector: only for libraries whose settings `embedding.model` matches the query vector's model id; other
   libraries are keyword-only, and the response says which sources used vectors.
3. Merge. The keyword lists of all sources (ZIMs and libraries) are scored hit by hit and merged into one list; where a
   vector list exists it joins that list in a reciprocal rank fusion (k=60), one entry per address. A source's best hit
   is not worth the same everywhere (the earlier merge gave every source's best hit 1.0, so with 19 sources the weak
   matches of small ZIMs competed with the strong ones), so each hit gets a score of its own:
   - `rel`: the hit's raw score over the best raw score of its source (Tantivy BM25; for a Xapian source libzim's
     percentage, which is 100 for the source's best hit, so it is relative too). It orders hits inside a source; it
     cannot compare two sources.
   - `coverage`: the fraction of the query's distinct words (compared after the source's own stemming) found in the hit.
     Tantivy hits: found in title, lead or body. Xapian hits: found in the title or the text of the article (read from the
     ZIM; the first 300 KB), because libzim reports no matched terms. `title_cov`: the same fraction counting the title only
     (for a Tantivy hit it equals `coverage`: the title is already boosted x2 in its BM25). Every word counts the same,
     including "how" or "the": a chatty question is not cleaned up here (it is for the vector list, or for the model that
     writes the query).
   - `score = rel * (coverage + title_cov) / 2`. The title is the one signal that crosses sources: a hit whose title lacks
     the query words keeps at most half its source-relative score, so an article that merely mentions the words cannot
     outrank one about them from another source. (Measured on the 15 evaluation queries, top-3 hits for a title share
     of 0 / 0.25 / 0.5 / 0.75 / 1.0: 8 / 11 / 14 / 13 / 12, so 0.5.)
   - A hit is good if `coverage >= min_term_coverage` (default 0.5) and `rel >= min_relevance` (default 0.5; on the
     evaluation queries 0.34-0.67 for the first and 0-0.7 for the second change nothing). Hits that
     are not good are dropped before the merge, unless fewer than k+offset good hits exist; then the best of the dropped
     ones fill up to k+offset after all the good ones.
   - Sorted by score, ties by the higher raw score, then by address. Per Xapian source the merge sees the best
     max(k+offset, 10) hits (their articles are read for coverage).
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
  400 chars. For a ZIM searched through its Xapian index: libzim's own snippet, with its HTML (`<b>` around matched
  words) stripped and entities decoded, whitespace collapsed, a leading or trailing "..." removed, and cut to at most 400 chars at a sentence end
  by the same rule; if libzim gives none, the first sentences of the article.
- Library hit title: the mapped `title` (falling back to `title_fallback`); when the point has a page,
  `<title>, p. <page>`. For a ZIM hit: `<ZIM title>: <article title>`.

### Search quality evaluation

`packages/cache_search/eval/` holds `queries.json` (15 queries with the expected source and/or article title for the top 3)
and `search_eval.py` (standard library only; it talks to a running `cs serve` and prints hit@3 and hit@5 per query). It is
a script, not a cargo test, because it needs the real source set. The expectations were written by reading what the recon
library and the ZIMs contain, each source searched alone, not from any ranking. Two queries come from the 2026-10-26 check
("replace iphone battery", "flood"), the other 13 from heldout-v1 (never used for training). Run 2026-10-26 on Windows with
the recon library (keyword only, no embedder) and the 18 ZIMs, k=5, a debug build:

| | hit@3 | hit@5 |
|---|---|---|
| Tantivy only (every ZIM `"builtin_index": false`; Wikipedia has no finished Tantivy index and is left out, so the 3 queries answered by Wikipedia cannot hit: 6/12 and 8/12 on the others) | 6/15 | 8/15 |
| Hybrid, before the ranking change (adf154e) | 8/15 | 8/15 |
| Hybrid, after | 14/15 | 14/15 |

Before the change the junk came from small ZIMs whose best hit counted as much as anyone's: "replace iphone battery" gave
Hundred Rabbits, Meshtastic Settings and Wikivoyage Electrical systems and no iFixit page; "flood" opened with Hundred Rabbits.
After it iFixit's iPhone battery guides take the first eight places and "flood" opens with Ready.gov. The one miss is
"how do I know if I'm getting dehydrated?": for the whole chatty sentence no source's own top 50 holds a good article (the
common words dominate Xapian and BM25 alike), so the merge has nothing to promote; that is for the vector list or for a model
that rewrites the question. The ranking costs a warm query about 0.6 s more (mean 1.3 s to 1.9 s over the 15 queries, debug
build) because the top hits' articles are read for coverage.

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

### Conversation state (export and import)

A conversation lives only in memory. To continue a chat in a later session or another process, the app saves
`cs_conversation_export(conv)` and restores it with `cs_conversation_import(json)`; the restored conversation numbers and reads
exactly as the original would have (the same later `cs_format` and `cs_tool` calls give byte-identical `content` and `ids`).
The export holds all the state a conversation has: the id map and what `web_search` showed for each web result (the
title and snippet `read` falls back to when the page cannot be fetched). Nothing else is kept per conversation.

Format 1, one JSON object, keys always in this order (the same state always gives the same bytes):

```
{"format":1,
 "next_n":4,
 "ids":[{"n":1,"address":"lib:x/1","title":"..."}, ...],
 "web_hits":{"web:https://a.example/1":{"title":"...","snippet":"...","fetched":"2026-10-25 14:20"}, ...}}
```

- `format`: the version, an integer. An import of any other number is refused with `unsupported`; a missing or non-integer
  one with `bad_json`. A later format that adds keys gets a new number.
- `next_n`: the number the next new address gets, always `ids` length + 1 (1 when empty). It is redundant on purpose: an
  export whose `next_n` disagrees with its `ids` is `bad_json`, not repaired.
- `ids`: every number given, ascending, entry `i` being number `i + 1`; `title` is the first title seen for the address. A
  repeated address or a gap in the numbers is `bad_json`.
- `web_hits`: for each `web:<url>` address a `web_search` returned, `title` and `snippet` (as shown to the model, already
  cleaned) and `fetched` (local `YYYY-MM-DD HH:MM`, used in `read`'s header line). Keys are sorted by address. May be `{}`
  (and is read as `{}` when absent).
- Unknown keys are ignored on import. An import that fails changes nothing and returns no conversation.

Errors with no handle follow the rest of the conversation calls: NULL, with the error in `cs_last_error(NULL)`.
`cs serve` has `GET /conversations/{id}/export` (the JSON) and `POST /conversations/import` (the body is an export;
returns `{"id"}` of a new conversation). The CLI has no such command: a conversation does not outlive a `cs` process.
Tests: `conv.rs` (key order, round trip, refusals); `tests/web_ffi.rs` runs one sequence (a `cs_format`, a stand-in
`search` tool, `web_search` against the local stand-in server, a read of a web hit whose page loads, one whose page fails,
a final `cs_format`) uninterrupted and again with an export and import after each step, and requires every reply to be
byte-identical; `cli/tests/cli.rs` covers the two endpoints.

## Tools

The model's tools (docs/TOOLS.md) run through the core, so the phone and the headless runs share one dispatch:
`cs_tool_schemas` lists the available tools' function schemas and `cs_tool` runs one call and numbers its result
in the conversation.

**Registry.** The handle holds `Vec<Box<dyn cache_tool::Tool>>`. The host adds tools with
`Handle::register_tool` (a tool registered again under the same name replaces the first), sets the user's saved
places with `set_saved_places` (default `NoSavedPlaces`) and the query embedder of `search` with
`set_query_embedder` (a callback `&str -> Option<(model id, vector)>`; with none, search is keyword-only, as
`cs_search` is without a `query_vector`). `cs_open` registers the tools of the config's "user", "live" and "routing"
sections (see Wiring and headless, and navigate below). `cs_tool_schemas` lists tools in the order search, read, navigate, nearby, locate, live_data,
web_search (a tool with another name follows, in registration order) and leaves out a tool whose `schema()` is
None.

**search and read are built in.** They are not `Tool` impls: `Tool::run` sees only the location, the saved places
and the clock, while search needs the handle's sources and read needs the conversation's number-to-address map.
They still use TOOLS.md's schemas (copied verbatim into `tools.rs`) and every dispatch step below. `search` runs
`cs_search` with k=5 and the embedder's vector, and writes one line per result,
`{{addr:<address>}} <title> — <snippet>`, with the title and snippet rules of `cs_format` (whitespace runs
become one space; no ` — ` when the snippet is empty); no result is `No results found.`. `read` takes `n`, finds
its address in the conversation (unknown: `not_found`, "no result [n] in this conversation"), calls `cs_read` with
max_chars 6000 and writes `[n] <title>`, the text, and `[truncated]` on its own line when it was cut. It keeps the
number it was given, so it writes `[n]` itself and gives no marker.

**Dispatch** (`Handle::call_tool`):
1. Find the tool. An unknown name is `bad_arguments` "no tool named <name>"; a registered tool whose schema is
   None is `not_set_up`.
2. Validate the arguments against the schema's `parameters` (below). A violation is `bad_arguments`, detail
   `"<field>: <what>"`. Defaults in the schema are not filled in; the tool applies them.
3. Run it with a `ToolCtx` (the handle's location and saved places, and `now`) inside `catch_unwind`; a panic is
   `internal`, "<tool> failed".
4. Number the result in the conversation (the numbering `cs_format` uses, so an address seen before keeps its
   number): in text, each `{{addr:<address>}}` becomes `[n]` and the title is the text after the marker up to ` — `
   or the end of the line; in JSON the value is walked depth first in document order and every object with an
   `"address"` key gets that key replaced, in place, by `"n": <number>` (its title is its `title`, `name`,
   `place_name` or `label`, in that order, else empty). A JSON object without `"ok"` gets `"ok": true` as its first
   key; other key order is untouched. A `ToolError` becomes its `to_json()` unnumbered.
5. The reply is `{"content","ids"}`; `content` is the text as it is, or the JSON serialised compactly; `ids` holds
   only the numbers this call gave, in order.

A tool's failure is its content, never a C error. Only a NULL or invalid handle or conversation, an `args_json` that
is not JSON, or an empty `now` return NULL with `cs_last_error`.

**Validator.** A small built-in subset of JSON Schema over the properties of `parameters`: `type` (string, integer,
number, boolean, object), `enum`, `minLength`, `maxLength` (in characters), `minimum`, `maximum`, `required`, and
`additionalProperties: false`. The arguments must be an object. Nothing else in a schema is checked.

**now and location.** `now` (the local time with offset, from the caller's clock, so captures can pin it) is required
on every call. The phone's GPS fix is set with `cs_set_location(lat, lon, accuracy_m, fixed_at)` (`accuracy_m` < 0
is unknown) and removed with `cs_clear_location`; tools see it as `ctx.location` and answer `no_location` without it.

### Web search

`web_search` and `read` on a web result live in `web.rs`. Settings: `cs_set_web(h, provider, key, online)`
(provider "kagi", or NULL for off; key or NULL; online 0/1; each call replaces all three).

**Availability.** `web_search` is a registered `cache_tool::Tool` (`WebSearchTool`), registered by `Handle::open`
and sharing the handle's `WebState`. Its `schema()` is Some only while a provider, a key and `online` are all set;
otherwise it is left out of `cs_tool_schemas` and a call gives `not_set_up`. It is a registered tool rather than
built in because it needs only `ToolCtx` (the clock) plus its own state; the two things a plain tool cannot do are
done by the dispatch: `call_tool` moves the hits the tool left in `WebState` into the conversation after the call,
and `read` (built in, it has the conversation) handles `web:` addresses. A host that registers its own tool named
`web_search` replaces it.

**Provider interface.** `trait WebSearchProvider: Send + Sync { fn search(&self, query, limit, key, deadline) ->
Result<Vec<WebHit>, ToolError> }`, `WebHit { url, title, snippet }`. The provider maps its own failures to the shared
error codes. `KagiProvider { base_url }` (default `https://kagi.com/api/v1/search`, overridable for tests) sends
`POST` with `Authorization: Bearer <key>` and the JSON body `{"query": "<q>", "limit": <n>}`, and reads the results
from `data.search`, an array of objects with `url`, `title` and an optional `snippet` (extra fields are ignored). This
matches the request AIDA uses in production (Open WebUI kagi.py); live-verified: pending. HTTP 401/403 or an error code
401/403 is `key_missing` ("web search key rejected"); 402/429, or an error mentioning balance, quota or credit, is
`quota`; a timeout, a refused connection, or any other bad status (500, ...) is `fetch_failed`; JSON that cannot be
used is `bad_response`, including a 200 with an `error` field or without a `data` object; the detail then lists the
top-level key names (and `data`'s) but never a value, and never the key or the query. A `data` object whose `search`
is missing or null is zero results (`No results found.`). Kagi's `meta` object (request id, timing), when present,
goes into the debug timing field as `kagi_meta`, never to the model (the detail never contains the key). **Unverified:** the shape of v1's error body. The `error` array-or-object (`code`, `msg` or `message`) and the
mapping of a balance, credit or quota message to `quota` are a judgement from the previous API's shape, not seen from
v1; only the 200 response shape above is known from AIDA's use.

**Results.** Up to 5 lines in the form of `search`: `{{addr:web:<url>}} <title> (web, fetched <YYYY-MM-DD HH:MM from
now>) — <snippet>`; the snippet is cut by the library-search rule (`snippet_chars`, a sentence end or a word
boundary with `…`), the title to 150 characters. Repeated URLs are dropped. Text from the web is made safe for the
line: first the HTML is removed (tags stripped, named, decimal and hex entities decoded, as `html::strip` does for a
page), then whitespace runs become one space, `{{` becomes `{ {` so a page cannot forge an address marker, and a ` — ` in
a title becomes ` - ` (the numbering reads the title up to the first ` — `). Nothing found: `No results found.`

**Read.** `read` on a `web:` number fetches the URL (GET, up to 5 redirects, `User-Agent: Cache/<version>`), strips
HTML with the same rules as a ZIM article (`html_to_text`: headings kept, script and style removed; plain text is
used as it is), and cuts to 6,000 characters at a paragraph end. Output: `[n] <title> (web, fetched <time>)`, the
text, and `[truncated]` when cut (or when the download hit the cap). When the page cannot be had, the output is the
same first line, the snippet the search showed (the conversation keeps each web hit's title, snippet and fetch time
beside its number), and a last line `[full page did not load in time]` (timeout) or `[full page not available]`
(connection failure, bad status, a content type that is not HTML or text, a page with no text, or the phone being
offline, in which case nothing is fetched). That is a result, not an error. A page that loads but whose extracted text is
under 500 characters (`LITTLE_TEXT_CHARS`; a script-rendered shell that gives only navigation or a footer) is not
a full page: the output is the first line, the stored snippet, the extracted text (if not empty), and a last line
`[page had little readable text]`. This is a length rule on machine output. Compression is not requested: the
reqwest already in the lockfile has no gzip support and the decoder crate it would need is not in the lockfile.

**Budgets.** Search 6 s from the call to the result; read 8 s for connect, download and parse; a page download is
capped at 2 MB (the rest is dropped). Each network call runs on its own thread and the caller waits only until the
deadline, so a stalled name lookup or a slow body cannot hold the handle longer; the abandoned thread ends when its
own request times out. The client is `reqwest` 0.13.5 (blocking API, rustls), already in the lockfile through
Qdrant's object store; no crate was added.

**Never stored.** Nothing from the web is written to disk or added to a library. Hits and their snippets live in the
`Conversation` and die with it.

**The key.** `WebState` holds it in memory only. It is sent only as the provider's `Authorization` header (marked
sensitive in the client), never in a URL; it is not written to disk, not logged (the core has no logging), and is
removed from any error detail built from a server's reply (`***`). `WebState` has no `Debug`. The tests search every
output, error and status for the test key.

**Timing.** A `cs_tool` reply for a web search or a web read also has `"timing_ms": {"search": ms}` or
`{"fetch": ms}` after `content` and `ids`: a debug field for speed measurement, never part of what the model sees.
`cs tool` prints it on stderr (and in `--json`).

**CLI.** `cs` turns web search on when both `CACHE_WEB_PROVIDER` and `CACHE_WEB_KEY` are set in the environment (it
then assumes online); `CACHE_WEB_BASE_URL` points Kagi at another address for runs against a stand-in server.
`cs serve` has `POST /web {"provider","key","online"}` and `DELETE /web`; the key is never echoed.

## ZIM built-in index (libzim)

Decided by the Cache lead, 2026-10-26: the official prebuilt libzim 9.8.2 (Kiwix; Xapian inside), a small C ABI shim
`native/zimx/` (`zimx.h`, `zimx.cpp`) built by `cache_search/build.rs` with the `cc` crate, and a Cargo feature `xapian`
(default; effective on Windows and Android only, other targets ignore it). Download URLs, versions and md5s:
`native/zimx/LIBZIM.md`; fetch-and-verify scripts: `fetch-libzim.ps1` (Windows) and `fetch-libzim.sh` (Android), which download
into the build directory, never the repository. `LIBZIM_DIR` names the unpacked folder at build time. On Windows
`build.rs` copies `zim-9.dll` and the ICU 74 DLLs next to the built binaries; they must ship with them
(the Visual C++ runtime is also needed). Android arm64 needs `libzim.so`, the NDK's `libc++_shared.so` and the ICU data
file `icudt73l.dat`; it was built with cargo-ndk on 2026-10-26 (see "Android build" below) and has not yet been run on a device.

What it is used for: keyword search and title suggestions over a ZIM's own indexes. `cs_read`, `cs_zim_get` and
`cs_zim_main_page` stay on the Rust `zim` crate reader: libzim is only opened (on a background thread once the sources are
set, see "Prewarm"; otherwise on first search, suggest or status) for the indexes.
- Shim: `zimx_open/close`, `zimx_has_fulltext`, `zimx_has_title_index`, `zimx_search(handle, query, offset, k, keep)` (path,
  title, libzim snippet, score, estimated total), `zimx_suggest(handle, prefix, k, keep)` (path, title), `zimx_drop` (release
  the kept searchers; `keep` = 0 on a search or suggestion uses a kept searcher if there is one and otherwise a temporary one;
  see "Searcher memory budget"). Results are UTF-8 JSON strings
  freed with `zimx_free`. Every C++ exception is caught in the shim and returned as `{"error":...}` (the Rust side turns it into an
  `internal` error; a failed open into `io`). Nothing crosses the boundary as an exception.
- Search: a Xapian query that libzim rejects (an unmatched quote or bracket) is retried with the query reduced to its
  words; if libzim still fails, the source falls back to its Tantivy index if it has one.
- Suggest: a ZIM with a title index suggests from it in libzim's order (`Floods | Ready.gov`), with no extra filtering. When
  such a source and a Tantivy one both answer, each list is ranked by its rank in its own source (1/(60+rank)) and the
  title length breaks ties; with only Tantivy sources the existing BM25 ranking is unchanged.
- Without the feature (`--no-default-features`) none of this is built and every ZIM uses Tantivy, which is also the
  fallback if the licence decision below goes against GPL code.

Differences from Tantivy that callers can see:
- Ranking: Xapian's own weighting (BM25-based, with libzim's boosts) over the full article text, not Tantivy's title (x2) /
  lead / body fields. libzim's integer score is a percentage that is 100 for the best hit of the query in that ZIM (measured
  on all 18 ZIMs), so inside the cross-source merge it is a within-source figure like Tantivy's normalised BM25 (see "Search
  and merge" for how sources are compared).
- Stemming and stop words follow the language libzim chose when the ZIM was built, not Cache's tokenizers.
- Snippets: libzim's snippet is built from the whole article, so it shows the matched passage, where Tantivy's is
  cut from the first ~1,500 chars (`lead`). The same HTML-free, at-most-400-chars, sentence-end rule applies.
- Titles are the ZIM's own entry titles (some ZIMs carry a site suffix, for example `Floods | Ready.gov`).
- Speed (Windows, 18 ZIMs plus the recon library, measured 2026-10-26): no build step. Without prewarm libzim opens each
  file on its first search, which on a cold disk took 39-52 s for the first query after a start (the 27M-entry Wikipedia
  included); after that a search over every source takes about 1-2 s, Wikipedia alone 0.2-1.8 s, and a Wikipedia title
  suggestion 0.3-2.3 s warm (35 s for the very first one, cold). `cs_status` does not open libzim (it looks the index entry
  up with the `zim` crate).
- Prewarm cost, measured (`cs serve`, all 19 sources, debug build, process memory sampled every second from launch to 60 s
  after the port opened, the OS file cache warm from earlier runs so the cold-disk part of the saving is not in these
  figures): the port opens at 35.6 s in every run (the library). Private bytes at open+60 s: 542 MB without prewarm, 1005 MB with
  it; after the first query both are 1019-1021 MB, so prewarm brings forward the same ~470 MB rather than adding
  to it. (Correction, 2026-10-26: those ~470 MB are the opened archives, not the searchers: the "archive open" column of the
  table in "Searcher memory budget" adds up to about 472 MiB for the 18 sources, 292 MiB of it Wikipedia. A searcher itself costs 1-2 MiB.) Peak working set: 17.8 GB without, 18.1 GB with (the library's mapped files dominate). First query: 4.1-5.6 s without
  prewarm, 3.8 s with it, the same whether it comes at once or 60 s after open; the build before this change (lazy opens,
  searchers rebuilt per call, no coverage reading) took 1.9-9.6 s on the same warm cache.
- Coverage: libzim does not report which query terms a hit matched, and the `<b>` marks in its snippets did not appear
  on the real ZIMs tried, so Cache reads the top hits' articles (the first 300 KB, `max(k+offset, 10)` per source) and
  computes coverage and title coverage itself from the words of the title and the text (see "Search and merge"). Reading
  articles costs about a second over a full source set.
- Searchers: the shim builds libzim's full-text and title searchers on a ZIM's first search or suggestion and keeps them while
  the memory budget allows (see "Searcher memory budget"); one mutex per handle serialises the calls that use them.
- Prewarm: `set_sources` starts up to 4 background threads that open libzim on the ZIMs with a built-in index and build their
  searchers, so the first search does not pay for the opens, but only for as many ZIMs as fit in the searcher memory budget,
  cheapest first. The config key `"prewarm": false` turns it off; its default is `false` on Android (`target_os = "android"`)
  and `true` elsewhere. A search that arrives while a source is still being warmed waits for that source only. Prewarm builds
  the `Searcher` objects and opens the archive; the Xapian database itself opens on the ZIM's first search (about 7 ms with a warm
  file cache, 91 ms for Wikipedia), so prewarm does not take that part off the first query.

### Searcher memory budget

Decided by the Cache lead, 2026-10-26; built on `tool-framework`. Config key `searcher_budget_mb` (default 256 on every
target; 0 keeps no searcher). Code: `budget.rs` (policy, no libzim in it, unit-tested everywhere), `zimx.rs` (binds an open
archive to the budget), `handle.rs` (one budget per handle, prewarm plan).

- Every kept libzim searcher (full-text, title) is tracked with an estimated cost (below). When a query needs a searcher that is not
  kept, it is admitted if it fits; to make room the least recently used kept searchers of other ZIMs are dropped (`zimx_drop`: the
  archive stays open, the next query on that ZIM builds the searcher again).
- A searcher whose cost alone is more than the whole budget is never kept: each query builds a temporary searcher and drops it when the
  query ends. So a budget of 0 builds one per query per source.
- Searches are correct whatever the budget; only latency changes (tests: results identical for budgets 0, one searcher, two, 3 MiB and
  256 MiB, with queries and suggestions run twice over so kept, dropped and rebuilt searchers all answer).
- Prewarm never drops anything. It takes the ZIMs in order of estimated cost, cheapest first, as long as the running total fits the
  budget (`prewarm_plan`); the others build their searchers on their first search. Default `prewarm` is `false` on Android.
- Cost estimate (`estimate_cost`): libzim does not report a searcher's memory, and the process's private bytes cannot be attributed to
  one searcher while other threads allocate, so the cost is estimated: full-text 1.5 MiB + index size / 8192, title 1 MiB + index
  size / 2048 (the sizes of the ZIM's `X/fulltext/xapian` and `X/title/xapian` entries, read with the `zim` crate). It is fitted to
  the measurements below, not derived from them exactly.

Measured 2026-10-26 on Windows (release build, libzim 9.8.2, one process per ZIM, private bytes = `PrivateUsage`, sampled after
about 2.5 s of settling; `tests/searcher_cost.rs`, ignored by default). MiB. "Archive open": `Zimx::open`. "Full-text searcher": the
searcher built and one count-only search run (k = 0), which opens the Xapian database. "After 10 results read": the same archive after
a search that returns 10 results with snippets.

| ZIM | file | full-text index | title index | archive open | full-text searcher (count-only search) | after 10 results read | title searcher |
|---|---:|---:|---:|---:|---:|---:|---:|
| wikipedia_en_all_maxi_2026-02 | 115.5 GiB | 7.7 GiB | 3.2 GiB | 291.8 | 0.7 | 95.9 | 1.9 |
| armypubs_en_all_2024-12 | 7.7 GiB | 27.0 MiB | 9.8 MiB | 9.1 | 1.9 | 76.2 | 0.3 |
| ifixit_en_all_2025-12 | 3.3 GiB | 75.1 MiB | 28.1 MiB | 16.0 | 1.2 | 94.8 | 1.1 |
| wikispecies_en_all_maxi_2026-07 | 3.2 GiB | 445.4 MiB | 261.4 MiB | 29.4 | 0.6 | 96.5 | 2.0 |
| www.ready.gov_en_2024-12 | 2.3 GiB | 3.6 MiB | 0.6 MiB | 9.1 | 0.8 | 88.1 | 0.0 |
| wikivoyage_en_all_maxi_2026-09 | 1021.5 MiB | 55.4 MiB | 9.1 MiB | 10.4 | 1.0 | 94.9 | 0.5 |
| appropedia_en_all_maxi_2026-02 | 554.7 MiB | 44.5 MiB | 7.6 MiB | 9.6 | 2.1 | 90.1 | 0.5 |
| cd3wdproject.org_en_all_2025-11 | 554.2 MiB | 22.3 MiB | 2.4 MiB | 9.1 | 1.5 | 86.8 | 0.0 |
| 100r.co_en_all_2026-08 | 169.0 MiB | 0.5 MiB | 0.1 MiB | 9.6 | 0.7 | 21.7 | 0.0 |
| wikipedia_en_medicine_mini_2026-10 | 166.3 MiB | 30.0 MiB | 54.6 MiB | 12.3 | 1.3 | 94.9 | 0.7 |
| meshoskey.com_eng_2026-10_24 | 116.8 MiB | 0.8 MiB | 0.1 MiB | 8.4 | 1.4 | 2.1 | 0.0 |
| meshtastic.org_eng_2026-10_25 | 104.8 MiB | 0.8 MiB | 0.3 MiB | 9.1 | 1.0 | 56.7 | 0.3 |
| fas-military-medicine_en_2025-06 | 77.7 MiB | 0.0 MiB | 0.0 MiB | 7.9 | 1.6 | 1.6 | 0.0 |
| wiktionary_af_all_nopic_2026-07 | 25.4 MiB | 9.0 MiB | 3.0 MiB | 9.6 | 1.1 | 88.9 | 0.3 |
| nhs.uk_en_medicines_2025-12 | 16.2 MiB | 1.3 MiB | 0.8 MiB | 9.1 | 0.8 | 78.0 | 0.3 |
| freq51.net_eng_2026-05_21 | 12.0 MiB | 0.1 MiB | 0.0 MiB | 8.4 | 1.2 | 2.8 | 0.0 |
| reticulum.network_eng_2026-10_22 | 4.8 MiB | 0.1 MiB | 0.0 MiB | 8.4 | 1.1 | 1.1 | 0.0 |
| wikiquote_af_all_maxi_2026-07 | 1.8 MiB | 0.2 MiB | 0.1 MiB | 8.4 | 1.6 | 2.8 | 0.1 |
| docs.meshcore.io_eng_2026-10_23 | 0.7 MiB | 0.1 MiB | 0.0 MiB | 8.9 | 1.2 | 1.2 | 0.0 |

What the numbers say:
- A kept searcher is small: 0.6-2.1 MiB (full-text) and 0-2.0 MiB (title), whatever the index size (Wikipedia's 7.7 GiB full-text index
  costs 0.7 MiB: the Xapian database is memory-mapped). Dropping a searcher gives back at most that. Rebuilding one takes about 7 ms
  (Wikipedia 91 ms) with a warm file cache.
- The memory is in the open archive, not in the searcher: 8-29 MiB at open (Wikipedia 292 MiB), and, after a search that reads results,
  another 50-97 MiB on the typical ZIM (about 1-3 MiB on a few small ones). That stays when the searcher is dropped and goes only when the archive is
  closed (private bytes fell back to within 1-3 MiB of the starting value). Emptying libzim's cluster cache (shared by all archives,
  16 MiB limit by default) gave back about 7 MiB of it, so the rest is held elsewhere in the archive.
- With all 18 sources and the library open, process private bytes stay at about 1020 MiB for a budget of 256, 8 or 0 MiB, and the mean warm
  query time over 10 queries is 880, 884 and 888 ms (second pass; `searcher_budget_mb` 256 keeps all 36 searchers, an estimated 30 MiB). At 256 MiB nothing is ever
  dropped on these sources; the desktop default stays 256.
- So the budget bounds what it tracks, the searchers, and on the current sources that is a small part of libzim's footprint.
  Bounding the footprint (about 1 GiB with these sources) would need a budget over the open archives (close the least recently
  used archive, reopen it on its next query) and/or a lower limit on what an archive keeps after reading results. That changes
  when archives open and close and is not part of this budget. Proposed, not approved.

### Coverage-read cost (Xapian hits)

A Xapian source's top hits (at least 10 per source) are read from the ZIM to compute term coverage (see "Search and merge"). Measured
2026-10-26 on Windows (release build, sources-full.json: 18 ZIMs plus the recon library, warm, mean of 10 queries, two runs each
way, the reads switched off with a temporary test-only switch that is not in the code): 967 and 951 ms per query with the reads, 681
and 681 ms without, so the reads cost about 270-285 ms per query (29%).


### Android build

Built 2026-10-26 for `aarch64-linux-android` with the `xapian` feature on, the way the Flutter plugin builds the core
(`cargo ndk --platform 28 -t arm64-v8a build --release -p cache_search`, NDK 28.2.13676358), with `LIBZIM_DIR` set to the folder
`fetch-libzim.sh` unpacks (official `libzim_android-arm64-9.8.2-1.tar.gz`, md5 `59a6b769847b77dc0ace69c3b9727445` checked by the
script). `build.rs` compiles `zimx.cpp` with the NDK's clang++ and links `libzim.so` and `libc++_shared.so`. What the app ships (sizes
as built; none of it is committed):

| File | Where | Size (bytes) |
|---|---|---:|
| `libcache_search.so` (release, stripped) | `jniLibs/arm64-v8a/` | 50,457,568 |
| `libzim.so` (official prebuilt, `llvm-strip --strip-unneeded`; 16,230,992 unstripped) | `jniLibs/arm64-v8a/` | 8,247,096 |
| `libc++_shared.so` (NDK 28.2, stripped copy) | `jniLibs/arm64-v8a/` | 1,253,544 |
| `icudt73l.dat` (ICU 73.2 data) | a real file in app storage, not in `jniLibs` | 10,955,552 |
| Total | | 70,913,760 (60.0 MB without the ICU data) |

`libcache_search.so` needs `libzim.so` and `libc++_shared.so` (DT_NEEDED) and exports only the `cs_*` functions; every libzim symbol it
uses is defined in `libzim.so`. All four files' LOAD segments are 16 KB aligned. `cargo ndk` also copies a stray
`libcrc_fast-<hash>.so` (a dependency that is also a cdylib); nothing needs it and it is not shipped.

ICU data: the official Android libzim is built with ICU linked in but without its data; libzim reads it from the directory named by
the environment variable `ICU_DATA` (the string is in `libzim.so`) or from `zim::setICUDataDirectory(path)`, a C++ call that the
core does not expose. So the app copies `icudt73l.dat` (the file name must stay exactly that) out of its assets to a real directory
once, and sets `ICU_DATA` to that directory (not the file) in the process before the first `cs_open`, for example
`android.system.Os.setenv("ICU_DATA", dir, true)` in the plugin or `setenv` through `dart:ffi`. Nothing else is needed to initialise
libzim. The Android build has not been run on a device yet: whether libzim works with that data placement is unconfirmed.

### Licences

- libzim: GPL-2.0-or-later. Xapian (statically inside libzim): GPL-2.0-or-later. ICU (the ICU DLLs, or the ICU data file on
  Android): the Unicode/ICU licence (permissive; copyright notice and licence text to be carried). zstd and liblzma inside
  libzim: BSD/GPL-2.0 dual and public domain.
- Effect on Cache: the crates are `AGPL-3.0-or-later`. GPL-2.0-or-later code may be combined with AGPL-3.0-or-later code
  (GPLv3 section 13), and the combined binaries stay under AGPL-3.0-or-later; because they would then carry GPL code,
  anyone who receives them must be offered the corresponding source of the shim, Cache and the libzim and Xapian versions
  used (LIBZIM.md names them; the sources are at https://github.com/openzim/libzim and https://xapian.org). A build
  with `--no-default-features` links no libzim, Xapian or ICU and has none of these obligations.
- The app's credits need lines for libzim and Xapian (GPL-2.0-or-later) and ICU. This repository keeps no third-party
  credits file (the existing notes, such as the ODbL line for the timezone data, say "the app's credits need a line"), so
  there is nothing to add here beyond this section.
- Not legal advice: whether to ship the feature is the licence decision; turning the `xapian` feature off is the way back.

## ZIM reading

Options to evaluate first (report before committing):
1. libzim (C++) built WITHOUT Xapian and ICU, linked statically. Needs a C++ toolchain per ABI; size to measure.
2. A Rust ZIM reader (e.g. the `zim` crate) if it handles current ZIMs (zstd clusters, new namespace scheme);
   simplest to cross-build. To verify against our ZIMs (wikipedia maxi 2026-02, ready.gov, nhs medicines).

## Jobs

`index_zim`, `index_library`, `update_library` and `library_manifest` run as jobs: start, poll progress, cancel; checkpoints every N articles
(Tantivy commit + last article or point index) so a cancelled or killed job resumes (`update_library` does not
checkpoint: it restarts from the snapshot file, and leaves the library as it was if it fails). `index_library` takes `library_path`, `index_dir` and `heap_mb` (default 200) and builds the device Tantivy
index from the mapped text field; it is resumable via checkpoints like `index_zim`. `update_library` takes `library_path`,
`snapshot_path` (the partial snapshot file) and `snapshot_manifest_path` (the manifest the snapshot was made
against: the library's snapshot manifest as it was sent to the server; it must list exactly the segments on
disk); it runs the update steps under Libraries / Updates (including the free-space check: error code `no_space`). `library_manifest` takes `library_path` and `out_path` and
writes the library's snapshot manifest (the body to send to the server's partial snapshot endpoint) to `out_path`. An update and an `index_library` job on the same
library refuse each other with `busy`. Memory cap via Tantivy
writer heap size (default 200 MB on phones). "Only while charging" is the app's policy, not the core's.

## Threads

A handle is used from one thread at a time. A source whose index a job is building is not searched until the
job is done. Jobs run on their own threads inside the core and are polled.

Opening a library can take tens of seconds (13-37 s measured on the 28 GB recon library), so `cs_open` and
`cs_set_sources` never wait for it. Each library opens on a background thread inside the core; `cs_status` lists
it with `"opening":true` until it is ready (`"updating":true` while an `update_library` job owns it) (`"opening":false` for every other source, ZIMs included), and search
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
identical query vectors its output is the phone's output. The two things it calls that have no C ABI function are the
core's `library::unpack_library` helper (`cs unpack-library`) and `libupdate::library_manifest` (`cs library-manifest`).

Subcommands (results on stdout as the core's JSON, errors on stderr as `{"code","message"}`, exit status 1):
- `cs index-zim --zim <path> --index-dir <dir> [--heap-mb 200]`: runs an `index_zim` job, prints `state done/total`
  to stderr as it changes and the final progress JSON to stdout. Resumes from the checkpoint in `index_dir`.
- `cs unpack-library --snapshot <file> --dir <dir>`: unpacks a Qdrant shard snapshot and writes
  `segments_manifest.json`; prints `{"dir","segments"}`.
- `cs library-manifest --library <dir> [--out <file>]`: the library's snapshot manifest, the body to POST to the
  server's partial snapshot endpoint; prints it (or writes `--out` and prints `{"out","segments"}`). A core helper
  (`libupdate::library_manifest`), not an ABI call. It loads the shard read-write: run it only while the library
  is closed.
- `cs update-library --library <dir> --snapshot <file> --manifest <file>`: an `update_library` job, progress as
  for `index-zim`.
- `cs index-library --library <dir> --index-dir <dir> [--settings <cache-library.json>] [--heap-mb 200]`: an
  `index_library` job; `--settings` is passed as the job's `settings` object.
- `cs search --config <sources.json> --query <text> [--k 5] [--offset 0] [--format] [--json] [embedder flags]`:
  prints the `cs_search` JSON. With `--format` it prints the `tool_message` that `cs_format` gives a fresh
  conversation (with `--format --json`, the whole `cs_format` JSON). Plain `--json` is accepted and is the default.
- `cs read --config <sources.json> --address <addr> [--max-chars 6000]`: the `cs_read` JSON.
- `cs status --config <sources.json>`: the `cs_status` JSON.
- `cs tool <name> --config <sources.json> [--args '<json>'] [--now <iso>] [--lat <deg> --lon <deg> [--accuracy <m>]] [--json] [embedder flags]`:
  one `cs_tool` call in a fresh conversation (so `read` has nothing to open; use `serve` for a conversation across calls).
  Prints the content, then a line `ids <json>`; `--json` prints the core's `{"content","ids"}`. `--now` defaults to the
  local time with offset. The embedder, if configured, is also the query embedder of the built-in `search`.
- `cs tool-schemas [--config <sources.json>]`: the `cs_tool_schemas` array.
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
| `GET /conversations/{id}/export` | | `cs_conversation_export` (format 1, see "Conversation state") |
| `POST /conversations/import` | an export | `cs_conversation_import`; returns `{"id"}` of the new conversation |
| `DELETE /conversations/{id}` | | `cs_conversation_free`; returns `{"deleted":"<id>"}` |
| `GET /tools` | | `cs_tool_schemas` |
| `POST /location` | `{lat, lon, accuracy_m, fixed_at}` (`accuracy_m` optional) | `cs_set_location`; returns `{"ok":true}` |
| `DELETE /location` | | `cs_clear_location`; returns `{"ok":true}` |
| `POST /conversations/{id}/tool` | `{name, args, now}` | `cs_tool` on that conversation |

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

## Saved places and live data (crates `cache_user` and `cache_live`)

Two small crates in the `native/` workspace, compiled into the library; their C functions are exported by
`cache_search` (`ffi.rs`, glue in `ext.rs`). The tool contract (`cache_tool`) comes from the tool framework; these
crates implement `SavedPlaces` (`cache_user`) and the `live_data` `Tool` (`cache_live`).

### Saved places (`cache_user`, user.sqlite)

`cs_open` config `"user": {"db_path": ".../user.sqlite"}`. `cs_places_list`, `cs_place_save`, `cs_place_delete` (header
has the shapes). A place is `{key, name, lat, lon, label?}`; the key is stable across renames, is part of every live-data
address, and is letters, digits and `_ - . : , +`. A name given to a tool or to live data is matched against saved places
first (key, then name ignoring case); map-pack place search comes later and plugs in after it. Deleting a place deletes
the live data stored for it.

### Live sources (`cache_live`)

"Every API data point works this way": one engine, no per-source code. A source is one JSON file; the app points
`"live": {"db_path", "sources_dir"}` at a folder of them. The files that ship are in `packages/cache_search/sources/`
(`weather.json`: Open-Meteo, `alerts.json`: NWS); the app copies them into its sources folder on install, and a user adds
or shares more by dropping files there. An unreadable file is listed under `errors` by `cs_live_sources` and does not stop
the others.

Definition (format 1; unknown keys are errors, so typos show):

```
{ "format": 1, "id": "weather", "title": "Weather forecast", "provider": "Open-Meteo",
  "description": "one line: what the model and the Home card see of this source",
  "attribution": "optional credit line",
  "request": { "url": "https://...?lat={lat}&lon={lon}", "headers": {"Accept": "..."} },
  "api_key": { "alias": "eia", "required": true },      optional; "{api_key}" in url/headers
  "refresh_minutes": 180,                                a fetch inside this time returns the stored copy
  "quota": { "per_minute": 30, "per_day": 2000, "per_month": 30000 },       all optional
  "validity": { "fixed_hours": 6 }                       or { "end_path": "daily.time[-1]", "end_of_day": true,
                                                              "not_covered_after": true }
  "require": ["current", "daily.time"],                  paths that must exist, else bad_response
  "timezone_path": "timezone",                           optional: IANA zone name in the response (best)
  "utc_offset_path": "utc_offset_seconds",               optional: fixed offset; without either, the offline lookup
  "items": [ <item group>, ... ] }
```

URL placeholders: `{lat}` `{lon}` (4 decimals; `{lat:2}` for another count), `{name}`, `{place_key}`, `{api_key}`; values
are percent-encoded. https only (plain http only to 127.0.0.1/localhost, for tests). Every fetch sends the User-Agent
`Cache/<version>` and nothing personal. The key value arrives in the fetch request, is used for that call and is never stored
or written to an error message (the alias is what the app keeps in secure storage).

Item group: `{ "each": "<path to an array>", "key": V, "label": V, "time": V?, "ends": V?, "fields": [ V+label ],
"sort": [..]?, "point": {"lat": V, "lon": V}?, "area": "<path to a GeoJSON geometry>"? }`. One item per element of `each` (without `each`,
one item from the response root). `key` is the item's stable id (it ends up in its address); `ends` is when the item stops
being true (an alert's end; ended items are left out); `fields` are the labelled values, in order, a field with no value
is left out; `point` and `area` are for map layers and Home cards (not given to the model).

A value `V` is found by exactly one of `path`, `const`, `template` (`"{a} mph {b}"` with `vars`), `first_of` (first that
has a value) or `distance`, then formatted by these steps, in this order: `time` (`{"in": "local"|"rfc3339"|"unix", "out":
"datetime"|"datetime_s"|"date"|"<strftime>", "zone": "place"?}`) or `scale`, `offset`, `round` (decimals), `compass`
(degrees to N/NE/...); `lookup` (a fixed table from a code to text, `"*"` is the fallback; replaces the result);
`omit_if`; `case`; `max_chars`; `prefix`, `suffix`. No scripting.

Paths are dot-separated keys with `[n]` indexes (`[-1]` last). A path starts at the current element (the `each` element),
`^` starts at the response root, `@` is the element itself and `[#]` is its index, so a response with one array per column
reads as `"each": "daily.time"` plus `"path": "^daily.temperature_2m_max[#]"`.

Times: every time the core writes (`fetched_at`, `valid_until`, `age` bases, item times, `last_error.at`) is in the place's
local offset, as TOOLS.md says. The place's time zone is, in this order: the IANA name at `timezone_path` in the response
(Open-Meteo `timezone`), a fixed offset at `utc_offset_path`, the offline lookup of the place's position, UTC. A named zone
knows daylight saving, so a forecast that crosses the change (1 Nov) shows -06:00 before it and -07:00 after, and its
`valid_until` (local midnight at the end of the last day) is exact. A time the provider wrote with its own offset is
converted with `"zone": "place"` in its `time` step (the NWS definition does), otherwise it keeps the provider's offset.
The zone is stored with the row, so a stored response is re-read in the same zone.

Offline zone lookup: `tzf-rs` 2.1 (MIT) with its lite embedded boundary file, queried in place (`EmbeddedFinder`, no
expansion into memory), and `chrono-tz` 0.10 (MIT OR Apache-2.0) for the offsets. The boundary data is from
timezone-boundary-builder (ODbL-1.0): the app's credits need a line for it. Both add to the library size, reported with the
release build.

Distance: a field value `{"distance": {"geometry": "<path to a GeoJSON geometry>", "unit": "mi"|"km"}}` is the distance from
the place to the nearest point of the area and the compass direction of that point (`6.2 mi S`), or `inside the area` when
the place is within it (holes count). An item with no geometry has no such field; nothing is estimated from the area name.

Sorting: an item group may have `"sort": [{"by": <value>, "rank": [..] | "time": true, "desc": false}, ...]` (first key
first; missing values last). The alerts definition sorts by NWS severity (Extreme, Severe, Moderate, Minor, Unknown), then by
onset.

Rows for the phone's position (`at:` keys) are pruned: after a fetch for one, the other `at:` rows of that source are deleted
unless they are still within their validity, so only the newest fetch plus any still-valid row is kept. Saved places are
never pruned.

Validity: `fixed_hours` after the fetch, or the end of the day found at `end_path` (a forecast is valid until its last day
ends; `not_covered_after` then reports that date). After `valid_until` the data is expired.

### Store and calls

live.sqlite: one row per (source id, place key): `fetched_at`, `valid_until`, the mapped items, the raw response and a hash
of the definition file. A changed definition re-maps the stored response on the next read without a download. A failed
download (network, HTTP status, a response that is not JSON or lacks a `require` path, a quota) changes nothing and is
recorded as the row's `last_error`. Quota caps count every attempt in a log table and refuse with `quota`.

`cs_live_fetch` is called by the app's scheduler (or `cs live-fetch`); it skips the network when the stored copy is younger
than `refresh_minutes`. `cs_live_get` gives the screens everything stored, expired or not. The `live_data` tool gives the
model the same items through the same code, at most 12, with `more` for the rest, and refuses expired data with the
`expired` error. All of them take "now" from the caller (`now` in the request, `ctx.now` in the tool), so captures
reproduce; only a missing `now` falls back to the system clock.

The phone's own position as a place: the key `at:<lat>,<lon>` with both rounded to 2 decimals (about 1 km) and the name
`current location`. The `live_data` tool uses it when no place is given and a location is known, so the app fetches
for the current position with a place object carrying that key.

HTTP is `ureq` (blocking, rustls with bundled root certificates, no async runtime): the app's scheduler or the CLI calls
fetch from a worker thread, so a blocking client is enough and it adds far fewer crates than reqwest (tokio, hyper).
SQLite is `rusqlite` with the `bundled` feature (compiled in, nothing linked from the system).

### Addresses of live items

`live:<source-id>/<place-key>/<item-key>`, for example `live:weather/home/now`, `live:weather/home/2026-10-26`,
`live:alerts/home/urn:oid:2.49.0.1.840.0.example1`. Every item that `cs_live_get` and the `live_data` tool return carries
its address (the tool framework swaps it for `n`). An address stays valid across refreshes as long as the item key is
stable; a citation whose item is gone says so. Other address schemes in the core: `zim:<uuid>/<path>` and
`lib:<library-id>/<point-id>`.

### Wiring and headless

`cs_open` with a `"user"` section sets the handle's saved places to `cache_user`'s store (what every tool resolves a
place name against); with a `"live"` section it registers `cache_live::LiveDataTool` as the `live_data` tool. The tool
leaves itself out of `cs_tool_schemas` while `sources_dir` holds no valid definition, and a call then gives `not_set_up`.
Through `cs_tool` its items carry `"n"` (numbered with the conversation's other sources, so numbers continue after a
`search` and a known address keeps its number); the `ids` of the result map each `n` to its `live:` address.

`cs places list|save|delete`, `cs live-sources`, `cs live-fetch --request`, `cs live-get --request`; `cs serve` has
`GET/POST /places`, `DELETE /places/{key}`, `GET /live/sources`, `POST /live/fetch`, `POST /live/get`. The tool itself is
reached like any other, with `cs tool live_data`, `POST /conversations/{id}/tool` and `cs tool-schemas`. The test
`cli/tests/features.rs` runs one sequence through the CLI, serve and the C ABI on three separate states and requires
byte-identical output at every step, and runs `search` then `live_data` in one conversation through serve and the C ABI.

## Places, geocoder, nearby and locate (crates `cache_places` and `places_pack`)

**Pack (`places.sqlite`, one per region).** Tables: `places` (id, name, category, kind, lat, lon, street, locality, county, state, country, phone, hours, website, source, source_id, confidence), `places_rt` (R*Tree), `places_fts` (FTS5 over name and alternative names), `localities` (+ `_rt`, `_fts`: city, town, village, hamlet with OSM population), `categories` (id, title, one-line description for the model, rules JSON, place_count), `states`, `meta` (region, build time, bounding box). `category` is NULL for named places that are only there for the geocoder (`kind` says what they are). The schema is `cache_places/src/schema.rs`; the builder and the reader both use it.

**Builder (`places_pack`).** Inputs are `PlaceSource`s (Overture CSV and an OSM PBF today; Overture GeoParquet and Geofabrik on GitHub Actions later, see `places_pack/RECIPE.md`). The category rules are data (`categories.json`, stored in the pack): hospital, urgent_care, water and shelter come from OSM tags only; emergency_room from Overture `emergency_department`, and only where an OSM hospital (amenity=hospital or healthcare=hospital) is within 250 m: the row takes that hospital's name, address, phone and wiki ids and remembers it (`matched_source_id`); emergency-department records with no hospital there (air ambulances, ambulance services, clinics) are dropped; the rest merge Overture and OSM (same place: within 40 m, or within 200 m with similar names). State and country come from navi's admins.sqlite.

**Geocoder (`Geocoder` trait, in cache_places until it moves to cache_tool).** `forward(query, near, limit)`: the query is split at commas ("Walgreens, Burley, ID": a state qualifier filters, a town qualifier biases); FTS5 over towns and places; a name that equals the query wins, a town match gets a boost, so a bare "Burley" is the town and not a school named after it; `near` pulls ties toward a point; when the words do not all match, any-word matching is tried. `reverse(lat, lon)`: nearest town (a hamlet only when it is within 3 km and clearly closer).

**Emergency rooms: confirmed and likely (decided 2026-10-26; navi's approach).** The `emergency_room` category rule in `categories.json` has a second rule, `{"source":"category","category":"hospital","primary_tier":"confirmed","tier":"likely","note":"hospital, likely has an emergency room","beats_primary_only_if_nearer_by_mi":10}`, which the tools read from the pack. A search for `emergency_room` returns the confirmed rows (`er_tier` "confirmed") and then the OSM hospitals that no confirmed row stands for (`er_tier` "likely", with the note). They rank by distance, but a likely hospital goes ahead of a confirmed one only when it is nearer by more than 10 miles (the margin stands in for "15 minutes' drive" until Valhalla ranks by drive time). For navigate's `PlaceSource` the tiers are 1 (confirmed) and 3 (likely), navi's numbers. The rule is data and ids only: no name matching.

**Tools.** `nearby` (schema None until a pack with places is installed; the category enum and descriptions come from the packs' category tables) and `locate` (always offered; a GPS fix needs no pack; nearest town and place names need one). Registered by the `places` section of the `cs_open` config, `{"packs": [paths]}`. Packs are opened on demand and reopened when the file changes. `nearby` ranks by straight-line distance (`ranked_by: "distance"`) out to 300 km; drive-time ranking comes with Valhalla. Citable addresses are `place:<source id>`, `town:<source id>` and `loc:<lat>,<lon>`. `locate` also returns `usng` and `plus_code` (computed offline in `cache_places::coord`).

### navigate

`cs_open` with a `"routing"` section registers `cache_navigate::NavigateTool` (docs/TOOLS.md, "navigate"):
`{"valhalla": {"tiles": ".../tiles.tar", "shim": ".../valhalla_shim.dll", "region": "Idaho"}, "offroad": {"pack": ".../offroad.sqlite", "elevation": ".../elevation.pmtiles", "max_cells": 8000000}}`
(`region`, `offroad` and `max_cells` optional; `region` defaults to the tiles' folder name, "Idaho" for `packs/idaho/valhalla/tiles.tar`).

- **Offered when** the tiles file and the shim library exist; otherwise `schema()` is None and a call is `not_set_up`. Valhalla starts on the first call
  (not at `cs_open`) and its own logging is switched off (the shim reads the config's `logging` section; `{"type": ""}`).
- **Arguments.** AIDA's `from`, `to`, `to_type`, `mode` (drive, walk, bike), `near`, plus `land_access` (strict, pragmatic = default, emergency), last.
  Off-road legs come back inside the route, as in AIDA: when the off-road pack and elevation exist, an end more than 150 m from the road network gets an
  off-road lead-in or tail (drive uses the vehicle-class modes, walk foot, bike a two-wheeler), and a trip with no road gets a whole off-road route. Without the
  off-road files the road route is returned with an `offroad_unavailable` warning.
- **Names.** `to`, `from` and `near` resolve in this order: "lat,lon" text, the user's saved places (`ctx.places`), then the places pack through
  `cache_tool::places::PlaceSource` (`Handle::set_place_source`). With no pack, other names are `geocode_empty` and `to_type` is `not_set_up`; the `to_type`
  enum is TOOLS.md's list until a pack supplies its categories. The nearest place of a type is chosen by routing to the pack's 5 nearest by straight line.
- **Result = AIDA's navigate contract** (`nav_runtime.py navigate()`), in its build order: `ok`, `n` (from `address` = `nav:<route_id>`), `mode`, `location_bias`
  (`sender_node_position` for the phone's fix, `near:<name>`, `from_place`, null), `route_id`, `from_matched`, `to_matched` (place_name, kind, street, locality,
  county, state, distance_km, [er_tier], near, snap_distance_m), `other_destination_candidates` (always, at most 2; `drive_min` on a nearest search),
  `nearest_search` {to_type, ranked_by, warnings}, `distance_mi`, `distance_km`, `duration_minutes`, `major_roads` [{name, distance_km}], `step_count`, `steps`
  (at most 12; every off-road step is kept, the first road steps fill the rest), `steps_truncated`, `road_steps_omitted` / `offroad_steps_omitted`,
  `offroad_mi` + `offroad_note` (AIDA's text), `warnings` [{code, end, road_point, gap_m}]; then Cache's `map_region`, `map_region_age`. A step is index, kind,
  type, street_names, distance_mi, cardinal, instruction; off-road steps add travel, grade_class, elev_gain_m, elev_loss_m, terrain (only when known, underscores
  to spaces), follow {name, trail_kind}. Off-road instruction text is generated from the fields exactly as AIDA's `_step_text` does. Not filled (null): county and
  distance_km (the geocoder's), `near` (navi's reverse geocode of the end), kind/street/locality/state of a place given as coordinates, er_tier. Not present: `pins`, `bridge`.
- **Errors** (`ok:false`, `error`, then top-level `from_matched` / `to_matched` where AIDA attaches them): `geocode_empty` {which, query, searched_within_km, hint}
  (no detail), `origin_unknown` (no from and no fix), `bad_arguments`, `nearby_empty` {to_type, warnings (a list, `[]` when none, never null)} + from_matched, `same_place` + both places, the router's own
  code as the type (no_route, too_far, out_of_coverage, route_too_long, upstream_timeout, internal) with its message + both places, and `not_set_up`.
- **Tests.** `cache_navigate/tests/tool.rs` (a fake Valhalla); `cli/tests/navigate.rs` runs the Idaho routes through the CLI, serve and the C ABI and
  requires byte-identical output, and compares four requests with AIDA's recorded results in `cli/tests/fixtures/aida_navigate` (skipped unless `OFFROAD_VALHALLA_TILES`, `OFFROAD_VALHALLA_LIB`, `OFFROAD_IDAHO_PACK`, `OFFROAD_IDAHO_ELEVATION` are set).

## The map: search, route and guidance (`cs_map_search`, `cs_map_route`, `cs_map_progress`)

The Maps tab calls these directly; the `navigate` tool is for the model and stays as it is. The JSON of each call is documented in `cache_search.h`.
They need the `places` and `routing` sections of the `cs_open` config (`not_configured` otherwise); the CLI has `cs map-search`, `cs map-route` and `cs map-progress`
(`--request <json>`, or `--query` / `--to` / `--from` shorthands) and `cs serve` has `POST /map/search`, `/map/route` and `/map/progress`. All three print the
core's JSON as it came, so the doors agree byte for byte (`cli/tests/map.rs`).

**Search (`cache_places::map`).** A query is read in this order. (1) *Coordinates*: decimal, degrees-minutes-seconds (also degrees and decimal minutes, hemisphere
letters before or after), USNG / MGRS (zone, band, 100 km square, 2 to 10 digits; the inverse of the Kruger series that writes them), Plus Codes (full, padded, with
grid digits; a short code is completed from `near`, or from a town named after it). The answer is one `coordinates` result with the point in every format and the
nearest town. (2) *Text*: a run of words that is exactly the name of a city, town or village in the pack ("pharmacy near Burley") is the **anchor**; ranking is from
there, not from the map centre. Nothing in this step is a list of words: the data says what is a town. (3) *Names*: the geocoder (FTS5, town boost) on the whole text
and on what is left after the anchor. (4) *Categories*: the words (plurals folded) are matched against the pack's category ids, titles and descriptions; a word that
many categories use weighs little ("station" is in fuel, police and fire), title words count twice a description word. A matching category gives a `category` row and
its nearest places from the anchor or the centre. (5) *Meaning*, when the pack has vectors and the host has an embedder: the query vector is compared with the
vectors of the category texts and of the name-and-summary texts of places and towns. A category counts at cosine 0.40 within 0.08 of the best, a place at 0.50. The
host's embedder is the handle's query embedder (`set_query_embedder`, the one built-in `search` uses), or the request carries `query_vector`; its `model` must
equal the pack's `embed_model`, else the answer's `meaning` says `model_mismatch` and keywords answer alone. Without an embedder or vectors the answer says
`no_embedder` / `no_vectors`; the keyword steps (1 to 4) never need either.
Ranking: `score = 0.7 * relevance + 0.3 * closeness`; closeness is `exp(-km / 25)` from the anchor, else the centre (0.5 if neither is known); relevance is the name
match (0..1), the category match, or the cosine mapped from 0.30..0.70 onto 0..1. Every result carries `distance_m` and `direction` from `near` (the map centre or the GPS
fix), the details a card shows (phone, hours, website, Wikipedia summary and title) and an `id` that the route call takes.

**Vectors in the pack (`places_pack embed`).** The builder embeds each category as `title: description` and each place and town that has a summary as
`name. summary`, with `cache_embed` (cache_llama's `cl_embed`, the same code and settings the `cs` query embedder uses), and writes them to the `vectors` table
(`kind`, `ref`, `vec`): one byte per dimension plus a float scale, so Idaho's costs about 1 KB per embedded text. `meta` gets `embed_model` (the id a query vector
must carry; the GGUF file name unless `--embed-model-id`), `embed_dims`, `embed_model_sha256` and `embed_count`. A pack without the table is a keyword-only pack.
Places with no summary are found by name and category; the vectors are for the notable ones (peaks, lakes, towns, hot springs, landmarks).

**Route (`cache_navigate::map`).** `NavCore` is the routing engine (Valhalla shim, off-road pack and elevation, opened on first use); the `navigate` tool and the map
both route through `NavCore::navigate`, so a route has the same id, distance and time in both (a test compares them). The tool shortens the answer; the map keeps all of
it: the geometry as a polyline6 string, the `segments` (road, off-road or trail, each with its way of travel and its range of points), every maneuver with its position,
instruction, length and time and its range of points, the totals (road and off-road metres, climb and descent), the warnings, and Valhalla's alternatives
(`alternates`, for a plain road route; an off-road route has none). Stops (`via`) are routed leg by leg and joined; each stop is a `via` maneuver. A route that cannot be made is
`{"ok": false, "errors": [{code, message}]}`, not an error of the call.

**Guidance (`cs_map_progress`).** Each route (and each alternative) is kept in the handle, newest eight, so a fix is matched by `route_id`; the app sends the route
object again after a restart. A fix is matched to the nearest point of the route within 300 m behind and 3 km ahead of the last match, and only on the whole route
when that finds nothing on it, so a route that passes itself (an out-and-back) is not mistaken for its other pass. `off_route` is true when the fix has been farther
than `off_route_m` (50) from the route, or than the GPS accuracy if that is larger, for `off_route_fixes` (3) fixes in a row; an off-road leg is a straight line
between turn points over a 30 m grid, so its tolerance is twice as wide. The app then calls `cs_map_route` from the fix. The answer has the matched point, the distance
along the route, the next maneuver and the distance to it, the one after, the time and distance left, the ETA (if `now` is given) and, on an off-road leg, the bearing,
distance and climb to the next point. `arrived` is true within `arrive_m` (25) of the end.

## Videos (crate `cache_video`, PeerTube)

A generic PeerTube connector through PeerTube's official REST API only (no scraping): any instance, added by address; browse and
search; stream; download for offline use; link resolution for citations. The crate has no dependency on the rest of the core;
`cs_video_*` (ABI, `cache_search.h`), `cs video-*`, `POST /video/*` on `cs serve` and the `video_download` job are thin wrappers.

- **State on disk** (the `video` section of the `cs_open` config, `{"dir"}`): `instances.json` and `downloads/<instance>/<uuid>/`
  holding `video.<ext>`, `thumb.<ext>`, `captions-<lang>.vtt` and `manifest.json` (written last; a folder without it is not a
  download, and a half-finished file is `video.part` with `video.part.json` saying which file it is).
- **Tokens** are never stored by the core. Login (`GET /api/v1/oauth-clients/local`, then `POST /api/v1/users/token`, password
  grant, `x-peertube-otp` header when the account has two-factor login) and refresh (`grant_type=refresh_token`) return the tokens;
  the app keeps them in its secure storage and passes `"token"` per call.
- **Endpoints used:** `/api/v1/config`, `/oauth-clients/local`, `/users/token`, `/users/me`, `/video-channels`,
  `/search/video-channels`, `/videos`, `/video-channels/{handle}/videos`, `/search/videos`, `/videos/{id}`, `/videos/{id}/captions`,
  `POST /videos/{id}/token` (private videos), `/download/videos/generate/{id}` (HLS audio+video join), and the file, thumbnail and
  caption addresses the API itself returns. Search uses `searchTarget=local`.
- **File choice** (`model::options`): per resolution, a web-video MP4 first; else the HLS playlist's fragmented MP4 when it has sound;
  else (instances with separate audio, PeerTube >= 6.2 `hasAudio:false`) the video-only HLS file joined with the audio-only file by the
  instance's `/download/videos/generate` endpoint (not resumable, size approximate). Audio only: the audio-only web file, else the
  audio-only HLS file; no such file, no option. Choosing a resolution a video lacks gives the nearest below, else above.
- **Respect the instance:** `downloadEnabled:false` is refused (`unsupported`) before any file is requested; live streams are refused;
  at most 2 downloads per instance and 4 in all run at once (others wait); User-Agent `Cache/<version>`; http only to this machine.
- **Download job** (`video_download`): free space (file + 16 MiB) before anything; `Range` resume from the partial file, 3 retries
  with 1/2/4 s waits; size must equal the API's; sha256 is always computed into the manifest and checked against the HLS playlist's
  `segments-sha256` list when that names the file (the API gives no checksum for web-video files); thumbnail and captions saved
  best-effort (`warnings` in the manifest); a new download replaces the old one.
- **Link resolution:** `cs_video_resolve` takes a PeerTube link, uuid or short uuid (decoded locally: base-58 of the uuid, flickr
  alphabet) and a time; downloaded -> local file, no network; else an HLS master playlist or MP4 URL from the instance.
- **Tests:** unit tests (file choice, ranges, URL rules, short uuids, times), `cache_video/tests/video.rs` against a stand-in PeerTube
  serving recorded responses (`tests/fixtures`, hostname example.org; the HLS-with-separate-audio video is synthetic, built from the API
  reference), including a connection cut mid-file, cancel and resume, and `no_space`; `cli/tests/video.rs` runs one sequence through the
  CLI, `cs serve` and the C ABI and compares the output (state folder and clock times normalised).

## Open (needs decisions)

- Multi-shard collections (v1 is single-shard only).
- On-phone latency and build time (open, dense search, `index_library`): to measure on the emulator and a phone.
- Whether 28 GB-class libraries need quantized vectors on the device later.

## Tests of the update flow

`native/cache_search/tests/update_ffi.rs`, no server. A real partial snapshot is built locally: shard v1 is built
with the read-write `EdgeShard`, its manifest taken with `library_manifest`, the folder copied and changed (points
added, deleted, one rewritten; a variant with the optimizer run so whole segments are added and removed), and
the partial snapshot written with Qdrant's own per-segment `take_snapshot` (streamable format, against v1's
manifest, which is what the server passes) plus a `wal/` folder. The test builder is test code, not the server's
code path. Covered: searches skip the library during the update and find the new points after; deleted points
are `not_found`; segments_manifest.json lists exactly the segments on disk; cancel before apply; corrupt,
truncated and full (non-partial) snapshots fail with the library intact; a library that cannot reopen is reported
as a failed source; busy rules; manifest refusal on an open library; the library opened exactly once per
update, with every handle (also one that was not looked at during the update) getting the shared shard; the
`library_manifest` job (state while it runs, busy and cancel rules, parameter errors, a file equal byte for byte
to the one `cs library-manifest` writes); real-copy staging (the library hashed after the merge and load ran on the
copy and before the swap is identical in content and mtime and the copy shares no inode with it; the swap gives the
expected 310 points; an injected failure after the copy, before the swap and after the swap leaves the library
unchanged and no stage or old folder, and the update works afterwards); the space check (`no_space` with the numbers
and the whole tree hashed before and after, exactly `needed` bytes is enough, `needed - 1` is not); each crash
leftover case (stage only, old plus complete library, old only, old plus incomplete library, at open and at update
start) and the completeness check; and the hard-link staging measurements above.

## To verify

- A real server's partial snapshot. Not done: it needs a Qdrant 1.19.1 server (or the pinned rev built as a
  server) holding a collection, which was not available. Steps and sizes are in the test plan below.
- Whether the server's real partial snapshot differs in layout from the locally built one (the test builder uses
  the same per-segment function and format, but not the proxying and flushing the server does on a live shard, nor
  the clocks files).
- `segments_manifest.json` after a real `recover_partial_snapshot`: the core rewrites it from the segment folders
  in every case (the check passes for the local snapshot, including segments added and removed); the open
  question is only whether a server snapshot ever carries its own `segments_manifest.json` (the server code
  archives one when its feature flag is on) and whether unpacking it could clash with the rewrite. The merge plan
  ignores it.
- The double open at the end of the job (step 5 checks the library opens, then the handle opens it again): on a
  28 GB library that is a second 13-37 s open (the second is warm). Handing the opened shard to the handle would
  avoid it; not done.

### Real-server test plan

1. Take a Qdrant 1.19.1 server with a collection (single shard) and a full shard snapshot of it
   (`GET /collections/{c}/shards/0/snapshot`, 29.9 GB for the recon library; any small collection is enough for a
   first run, a few MB).
2. `cs unpack-library` the full snapshot, then `cs library-manifest --library <dir> --out m.json` (closed library).
3. Change the collection on the server (upserts, deletes, a payload change; run the optimizer so segments are
   replaced).
4. `POST /collections/{c}/shards/0/snapshot/partial/create` with `m.json` as the body, save the response
   (the changed files only; for a small collection a few MB, for recon expected far below 29.9 GB).
5. `cs update-library --library <dir> --snapshot <file> --manifest m.json`; then compare points with the server
   (ids and payloads of the changed and deleted points) and check segments_manifest.json against the folders.
