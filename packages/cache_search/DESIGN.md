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
  by the same rule; if libzim gives none, the first sentences of the article. Main-content check (all ZIM hits, both
  engines): libzim picks its passage from the whole page, menus and footers included, and an index built before main-content
  extraction has menu text in its `lead`. So the article is read, and a snippet whose text (letters and digits only, each
  "..."-joined passage on its own) is not in the article's main text is replaced by a snippet cut from the main text,
  starting at the sentence of the first query term (matched after stemming with the source's analyzer; the first
  sentences when no term is found). A snippet that is main text is left as it is.
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

`read(address, max_chars)`: ZIM → the article text (HTML stripped to plain text, headings kept, main content only: see
below); library → the
point's title and mapped text field, plus author, page and source type (null where unmapped) so the app can
render the page.

### Main-content extraction (`html::extract`, used by `read`, by the coverage read, by snippets and by the index's `lead`)

Menus, banners and footers come before the article in a page's text, so the text of a ZIM page is the page's main content.
Structure and measures only (element names, ARIA roles, link density, text length); no word lists.

1. Chrome is left out: `nav`, `aside`, `footer`, `head`, `script`, `style` and the other elements the stripper drops; any element
   with `role` navigation, banner, contentinfo, complementary or search, or `aria-hidden="true"`; and a `header` that is not inside an
   `article`, `aside`, `main`, `nav` or `section` (inside one it is that section's title block and stays).
2. If the page has `main`, `article` or `role="main"` elements, the largest one is the content. (Kiwix/mwoffliner Wikipedia
   pages are `main#content`; MkDocs, Docusaurus, DevDocs, NHS, ready.gov, Sphinx and Appropedia pages carry `main` or
   `article`; Stack Exchange has `role="main"`.)
3. Otherwise the density walk: starting at `body`, enter the container child (`div`, `section`, `table`, `td`, `center`,
   `font`, `form`...) that holds at least 70% of the element's text, with link text not counted (so a menu counts for
   nothing), while it holds at least half of the text `body` held. The element where the walk stops is the content; blocks
   in it of which 80% or more of the text is link text (at least two links) are left out (previous/next rows, related
   lists). The optional end tags of `p`, `li`, `dt`, `dd`, `tr`, `td` and `th` are implied when the tree is built.
4. If the density walk's text is under 200 characters (`MIN_DENSITY_CHARS`), the whole page text is used, as before: a page
   that short has no room for a menu to bury it. A declared `main` that has no text counts as absent.

Wikipedia pages go through step 2 and give the byte-identical text the earlier code gave (checked on sampled articles of the
maxi and medicine ZIMs, `tests/zim_main_text.rs`). Existing Tantivy indexes are not rebuilt (`INDEX_FORMAT` is unchanged);
their `lead` may still hold menu text, which the snippet check above corrects when a result is shown. New indexes store the
`lead` of the main text.

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
3. Run it with a `ToolCtx` (the handle's location and saved places, `now`, and the places pack's `Geocoder` when one is installed) inside `catch_unwind`; a panic is
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
matches the request AIDA uses in production (Open WebUI kagi.py); live-verified for the invalid-key answer only (below). HTTP 401/403, an error code
401/403, or the code `general.invalid_token` (what Kagi answers to an invalid key, with HTTP 400) is `key_missing` ("web search key rejected"); 402/429, or an error mentioning balance, quota or credit, is
`quota`; a timeout, a refused connection, or any other bad status (500, ...) is `fetch_failed`; JSON that cannot be
used is `bad_response`, including a 200 with an `error` field or without a `data` object; the detail then lists the
top-level key names (and `data`'s) but never a value, and never the key or the query. A `data` object whose `search`
is missing or null is zero results (`No results found.`). Kagi's `meta` object (request id, timing), when present,
goes into the debug timing field as `kagi_meta`, never to the model (the detail never contains the key). **Seen live, once (2026-10-26, one request with a made-up key):** HTTP **400**, `content-type: application/json`, body
`{"meta":{"trace","ms","node"},"data":null,"errors":[{"code":"general.invalid_token","url":"https://kagi.com/api#todo","message":"Token signature failed to verify. Ensure your token has been correctly copied from your dashboard, containing no extra spaces or newlines."}]}`.
So v1 puts failures in `errors` (plural; `error` is read too), the code is a string, and a bad key is a 400, not a 401/403. A
valid-but-revoked key, 401/403 and the quota answers have **not** been seen: the 401/403 mapping and the mapping of a
balance, credit or quota message to `quota` stay a judgement from the previous API's shape. Any other non-2xx answer is
`fetch_failed` "web search failed (HTTP n, <code>)" with the service's code when it gave one.

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
`[page had little readable text]`. This is a length rule on machine output. Compression is not requested (ureq is built
without its gzip feature).

**Budgets.** Search 6 s from the call to the result; read 8 s for connect, download and parse; a page download is
capped at 2 MB (the rest is dropped). Each network call runs on its own thread and the caller waits only until the
deadline, so a stalled name lookup or a slow body cannot hold the handle longer; the abandoned thread ends when its
own request times out. The client is `ureq` 2.12 (blocking, rustls with the compiled-in webpki roots), the same as `cache_live`, `cache_layers`
and `cache_video`; no crate was added. It was reqwest's `rustls` feature until v4, which verifies certificates with
rustls-platform-verifier; on Android that needs the JVM handed to it from Kotlin, which a Dart FFI library never does, so
every HTTPS request failed ("couldn't reach") while the app's own connection worked. `web::tls_roots()` names the choice
(`Bundled`) and a test checks the manifest has no reqwest.

**Failures.** A transport failure's detail carries the layer and a short cause, `could not reach the web search server
(tls: invalid peer certificate: UnknownIssuer)`, `(dns: ...)`, `(connect: ...)`, or `the web search request failed (io: ...)`;
a timeout stays `web search timed out`. The whole error chain goes into the debug timing as `"failure"`. Neither holds the key
(a header) or a query string (the search query is in the POST body; a page URL's query is cut out).

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

What it is used for: keyword search and title suggestions over a ZIM's own indexes, and, since 2026-10-26, every read of the ZIM:
`cs_read`, `cs_zim_get` and `cs_zim_main_page` go through the same open libzim archive (**one archive per ZIM**; see "Memory
budget"). libzim is opened on a background thread once the sources are set (see "Prewarm") or on the first search, suggestion or read.
- Shim: `zimx_open/close`, `zimx_has_fulltext`, `zimx_has_title_index`, `zimx_search(handle, query, offset, k, keep)` (path,
  title, libzim snippet, score, estimated total), `zimx_suggest(handle, prefix, k, keep)` (path, title), `zimx_drop` (release
  the kept searchers; `keep` = 0 on a search or suggestion uses a kept searcher if there is one and otherwise a temporary one; the
  core always passes 1 and lets the archive's lifetime decide, see "Memory budget"), `zimx_open_with` (open with `OpenConfig` and a
  dirent cache cap), `zimx_archive_info`, `zimx_cluster_cache`/`zimx_set_cluster_cache_max`, and the two entry reads:
  `zimx_get(handle, path, iterations, &data, &len)` (the entry's bytes in `*data`, plus `{"found","path","title","mime"}`; follows
  redirects, examining at most `iterations` entries; exact paths only, so libzim's own "strip a leading namespace" fallback is not
  taken, and an old-scheme archive tries namespaces `C`, `A`, `I`, `-` in turn) and `zimx_main_page(handle, iterations)`. Both run on the
  archive the searches use, take no lock (libzim's `Archive` is thread safe) and catch every exception. Results are UTF-8 JSON strings
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
  suggestion 0.3-2.3 s warm (35 s for the very first one, cold). `cs_status` does not open libzim (whether the ZIM has an index
  is read once when the source is opened).
- Prewarm cost, measured (`cs serve`, all 19 sources, debug build, process memory sampled every second from launch to 60 s
  after the port opened, the OS file cache warm from earlier runs so the cold-disk part of the saving is not in these
  figures): the port opens at 35.6 s in every run (the library). Private bytes at open+60 s: 542 MB without prewarm, 1005 MB with
  it; after the first query both are 1019-1021 MB, so prewarm brings forward the same ~470 MB rather than adding
  to it. (Correction, 2026-10-26: those ~470 MB are the opened archives, not the searchers: the "archive open" column of the
  table in "Memory budget" adds up to about 472 MiB for the 18 sources, 292 MiB of it Wikipedia. A searcher itself costs 1-2 MiB.) Peak working set: 17.8 GB without, 18.1 GB with (the library's mapped files dominate). First query: 4.1-5.6 s without
  prewarm, 3.8 s with it, the same whether it comes at once or 60 s after open; the build before this change (lazy opens,
  searchers rebuilt per call, no coverage reading) took 1.9-9.6 s on the same warm cache.
- Coverage: libzim does not report which query terms a hit matched, and the `<b>` marks in its snippets did not appear
  on the real ZIMs tried, so Cache reads the top hits' articles (the first 300 KB, `max(k+offset, 10)` per source) and
  computes coverage and title coverage itself from the words of the title and the text (see "Search and merge"). Reading
  articles costs about a second over a full source set.
- Searchers: the shim builds libzim's full-text and title searchers on a ZIM's first search or suggestion and keeps them for as long
  as the archive is open, which the memory budget decides (see "Memory budget"); one mutex per handle serialises the calls that use them.
- Prewarm: `set_sources` starts up to 4 background threads that open libzim on the ZIMs with a built-in index and build their
  searchers, so the first search does not pay for the opens, but only for as many ZIMs as fit in the memory budget (`zim_budget_mb`),
  cheapest first. The config key `"prewarm": false` turns it off; its default is `false` on Android (`target_os = "android"`)
  and `true` elsewhere. A search that arrives while a source is still being warmed waits for that source only. Prewarm builds
  the `Searcher` objects and opens the archive; the Xapian database itself opens on the ZIM's first search (about 7 ms with a warm
  file cache, 91 ms for Wikipedia), so prewarm does not take that part off the first query.

### Memory budget

Decided by the Cache lead (ref-a5), 2026-10-26; built on `tool-framework`. One budget covers everything libzim holds for a ZIM:
the open archive, its searchers and the caps on its caches. A ZIM has exactly one archive, opened once, and it serves searches, suggestions
and reads alike (`cs_read`, `cs_zim_get`, `cs_zim_main_page`), so nothing else holds the file open and the budget is the whole of a ZIM's memory. Config key `zim_budget_mb`: default 384 on Android, 1024 on every
other target; 0 keeps no archive open. The earlier key `searcher_budget_mb` (searchers only, default 256) is still read as an alias
when `zim_budget_mb` is absent, and `zim_budget_mb` wins when both are given, so an existing config keeps working; but it now
bounds the archives too, which is a different number (the old 256 would keep no Wikipedia). Code: `budget.rs` (policy and cost model,
no libzim in it, unit-tested on every target), `zimsrc.rs` (opens, shares and closes a source's archive), `zimx.rs` (the libzim
binding), `handle.rs` (one budget per handle, the config, the prewarm plan).

**Behaviour.**
- A ZIM source's libzim archive is opened when a search or suggestion first needs it (or by prewarm) and stays open, with its
  searchers, while the budget allows. Opening one that would take the total over the budget first closes the least recently used
  archives of other sources (their searchers go with them); the most recently used archives stay open. A closed archive reopens on
  its next query, transparently.
- An archive whose estimated cost alone is more than what the budget leaves (the limit less the reserved part, below) is never
  kept: the query opens it, uses it and closes it when the query ends. A budget of 0 does that for every source of every query.
- A query that already holds an archive keeps it open until it ends, even if another query's admission closed it meanwhile, so the
  process can briefly hold more than the budget (by the archives in flight).
- Prewarm never closes anything: it opens only the cheapest archives that fit (`prewarm_plan`); the others open on their first query.
- Reads are part of the same bookkeeping: `cs_read`, `cs_zim_get` and `cs_zim_main_page` lease the ZIM's archive exactly as a
  search does (open it if it is closed, admitting it under the budget and closing least recently used ones to make room), so a read
  counts as a use, and the memory of everything that reads a ZIM is inside the budget. A read of a ZIM over the whole budget opens it,
  reads and closes it again, like a search.
- The results of a query never depend on the budget (tests below); only latency does. The bytes, MIME type, title, text and errors
  of a read are the same as the `zim` crate reader's gave (the byte-identity test below).

**What libzim 9.8.2 offers to bound memory** (read from its headers `zim/archive.h` and `zim/zim.h`; there is no `OpenConfig` memory
limit, and no setting for Xapian's own cache):
- `zim::setClusterCacheMaxSize(bytes)`, `getClusterCacheMaxSize()`, `getClusterCacheCurrentSize()`: ONE cache for the whole process,
  shared by every archive; default 16 MiB. libzim counts the compressed size of what it caches; the process holds the decompressed
  clusters, so what it costs is several times the cap (below). Lowering the cap drops entries at once.
- `Archive::setDirentCacheMaxSize(n)`, `getDirentCacheMaxSize()`, `getDirentCacheCurrentSize()`: a cache of `n` dirents PER archive;
  default 512. Its memory is too small to see (32 against 512 changed no measurement by more than noise), so it is only passed through.
- `zim::OpenConfig` (the `Archive(path, OpenConfig)` constructor): `preloadXapianDb(bool)` and `preloadDirentRanges(int)`. Turning the
  Xapian preload off removes most of an archive's open cost, but then libzim cannot create a search at all ("Cannot create Search
  without FT Xapian index", every query fails on all 18 ZIMs), so it stays on. The dirent-range preload changed no memory
  measurement; it stays at libzim's default.
- Nothing exists to cap an archive's own tables or the Xapian database. They are what an archive's cost is made of.

So the caps Cache sets are the cluster cache (config `zim_cluster_cache_mb`, default 4 MiB of compressed data instead of libzim's 16; the
last `cs_open` or `cs_set_sources` in the process sets it) and the dirent cache (config `zim_dirent_cache`, default 512, libzim's own;
applied to each archive when it opens). A change of either closes the open archives, which reopen with it.

**Cost model** (`budget::archive_cost`, `budget::reserved_cost`), all from numbers readable without libzim:

```
archive cost  = 2 MiB                                   (archive base)
              + 11 bytes x entries                       (the header's article count)
              + 1.5 MiB + full-text index bytes / 8192   (if the ZIM has X/fulltext/xapian: the searcher and Xapian state)
              + 1 MiB   + title index bytes / 2048       (if it has X/title/xapian)
              + 256 bytes x dirent cache cap             (zim_dirent_cache; 128 KiB at 512)
reserved      = 9 MiB                                    (first archive in a process: libzim, Xapian, ICU set-up, heap growth)
              + 8 x cluster cache cap                    (zim_cluster_cache_mb; 32 MiB at 4)
available for archives = zim_budget_mb - reserved
```

Calibration (Windows, release build, libzim 9.8.2, process `PrivateUsage`; `tests/archive_cost.rs`, `tests/budget_measure.rs`, ignored by default). Each ZIM
alone in a fresh process, cluster cap 4 MiB, after opening it and running four full-text searches with 10 results and one suggestion
(MiB; "model" is archive cost plus reserved):

| ZIM | entries | measured | model |
|---|---:|---:|---:|
| docs.meshcore.io (0.7 MiB file) | 52 | 11.5 | 45.6 |
| nhs.uk medicines | 2,081 | 40.5 | 45.6 |
| www.ready.gov | 6,738 | 38.6 | 45.7 |
| wikipedia_en_medicine_mini | 340,829 | 43.8 | 49.2 |
| ifixit | 894,836 | 39.6 | 55.0 |
| wikispecies | 1,829,580 | 61.7 | 65.0 |
| wikipedia_en_all_maxi (115 GiB) | 27,199,921 | 323.7 | 333.5 |

(These read tables of different ZIMs against one cluster cache: about 30 MiB of every figure for a ZIM that reads results is the
cluster cache at 4 MiB, 2-3 MiB the searchers' state, about 9 MiB the process set-up, and the rest the archive.) The model is
meant to be at or above the measurement, never below it, for one archive in a fresh process. For many archives in one process it is
above by about a fifth: all 18 sources (the `sources-full.json` ZIMs without the library) measured 368 MiB of private bytes for libzim
after 20 queries (640 MiB in all, of which 272 MiB was the `zim` crate readers opened by `cs_open` at the time; they are no longer held), against a model of 404 + 41 = 445
MiB; the first few archives opened pay about 9 MiB each and the later ones about nothing, because the heap reuses what it has.
What the entries term stands for: libzim keeps about 10 to 12 bytes per entry in memory on Windows (Wikipedia 292 MiB, wikispecies
28.7 for 1.83M entries, ifixit 7 to 16 for 0.89M). The cluster cache is the large moving part: with the default cap of 16 MiB it
cost 143 to 148 MiB after four searches and a suggestion (cap 8: 68 to 71; cap 4: 24 to 33; cap 1: 2 to 4), which is the factor of 8 in the model, and
setting the cap to 4 MiB saves about 118 MiB of private bytes on the full source set at no cost in query time (warm mean 903 ms
against 904 ms with 16 MiB, over the 18 ZIMs, 20 queries).

Android: the model is fitted to Windows private bytes and has not been measured on a device. Where libzim maps a file rather than
reading it, the pages are file-backed and the kernel can drop them, which would make the estimate high for Android; whether that is
so for the per-entry tables was not determined. The default of 384 MiB leaves 343 MiB for archives, which holds
Wikipedia alone (about 293 MiB estimated) or a dozen small ZIMs, and everything else is closed in turn.

**Why these defaults.** Android 384 MiB: the Wikipedia ZIM is the biggest single archive (293 MiB estimated, 292 measured at open) and
should be able to stay open together with a few small ZIMs and the cluster cache; more than that is a large share of a phone app's
memory when the library, the model and the map layers share the process. The desktop default is 1024 MiB: the 18 ZIMs of
`sources-full.json` are estimated at 445 MiB in all (measured 368 for libzim) so everything stays open with room for a larger set, and
the process total stays under about 1 GiB with the recon library. Both are settings; the numbers were not tuned on a device.

**Measured with the budget** (Windows, release build, `sources-full.json`: 18 ZIMs and the recon library, default caps; private
bytes sampled 3 s after the 20 queries; 20 varied queries run twice, warm time is the second pass; "ZIMs only" is the same without the library
and so with the 272 MiB of `zim` crate readers visible; they are no longer held, see "One archive per ZIM"):

| Config | Budget (MiB) | Cluster cap (MiB) | Private bytes (MiB) | Warm mean / median query (ms) | Archive closes per pass |
|---|---:|---:|---:|---:|---:|
| 18 ZIMs + library | 1024 | 4 | 905 | 996 / 1055 | 0 |
| 18 ZIMs + library | 768 | 4 | 904 | 1028 / 957 | 0 |
| 18 ZIMs + library | 384 | 4 | 893 | 1142 / 1176 | 360 |
| 18 ZIMs + library | 1024 | 16 | 1021 | 946 / 1000 | 0 |
| 18 ZIMs + library | 384 | 16 | 739 | 1054 / 1074 | 0 (Wikipedia opened per query) |
| 18 ZIMs only | 1024 | 4 | 640, 638 (two runs) | 903 / 925, 917 / 974 | 0 |
| 18 ZIMs only | 768 | 4 | 640 | 1006 / 1104 | 0 |
| 18 ZIMs only | 384 | 4 | 629 | 1139 / 1165 | 360 |
| 18 ZIMs only | 256 | 4 | 356 | 1095 / 1144 | 0 (Wikipedia opened per query) |
| 18 ZIMs only | 128 | 4 | 358 | 1138 / 1182 | 340 (and Wikipedia per query) |
| 18 ZIMs only | 1024 | 16 | 758 | 904 / 926 | 0 |

The first pass of the very first run (1024 MiB, with the library) took 7936 ms per query on average, 71 s for the slowest: the OS
file cache was cold, not the budget; every other first pass was within 15% of its second. Over the 20 queries the answers were
identical in every run (the integration test checks that; the timing runs only count). With the whole set resident (1024 and 768) nothing
is ever closed, so those two differ only by noise; at 384 MiB (343 available) Wikipedia stays open and the 17 small ZIMs take turns in the
rest: 360 closes and reopens per pass of 20 queries cost about 140 ms of a 1000 ms query (about 8 ms each, with the OS file cache warm).

What the table says: the archives' memory goes back when a closed archive is large (Wikipedia per query: 1021 to 739 MiB at 384 MiB
with a 16 MiB cluster cap, and 640 to 355 MiB without the library at 256 MiB), but closing and reopening many small archives gives
back almost nothing (384 against 1024 MiB: 893 against 905 MiB), because the heap keeps what small archives used. The budget therefore
bounds the large archives well, the small ones poorly; and what is open stays bounded by the cost model, which is conservative. The
recon library's own memory varied from 340 to 538 MiB between runs of the same config (measured 3 s after it finished opening), so
compare rows of the "ZIMs only" half to see the effect of the budget.

**Cold reopen of Wikipedia** (what the least-recently-used close costs when the archive is the biggest one). Windows, release build, the 115 GiB `wikipedia_en_all_maxi_2026-02.zim`, one source in the handle (the `zim` crate reader already open at the time of that measurement; it no longer is), the archive
closed by setting the budget to 0 and then restored. The same sequence is run three times in a process, and the process twice. Open =
`Zimx::open` (the shim, with the Xapian preload); first query = `cs_search` k=10 with the searcher build, the Xapian database open and the
coverage reads; first suggestion = `cs_suggest` k=5.

| Run | Open | First full-text query | First suggestion | Total | Private bytes while open |
|---|---:|---:|---:|---:|---:|
| 1, first open, terms never used before ("pangolin conservation status", "pangol") | 115 ms | 2402 ms | 644 ms | 3162 ms | +322 MiB |
| 1, after eviction (same terms) | 111 ms | 183 ms | 7 ms | 300 ms | +321 MiB |
| 1, after a second eviction | 117 ms | 185 ms | 6 ms | 307 ms | +321 MiB |
| 2 (process repeated), first open, same terms | 114 ms | 194 ms | 6 ms | 314 ms | +322 MiB |
| 2, after eviction | 118 ms | 185 ms | 6 ms | 310 ms | +321 MiB |

Closing it gives all of it back (private bytes 0 to 2 MiB above the start after each close). The two figures that matter are the
first row, 3.2 s, which reads pages of the file that nothing has touched since the machine started using them, and the rest, about
0.3 s, where the OS file cache holds everything that open and those queries read. The first is the closer to the phone: the desktop
has far more RAM than the 115 GiB file's hot pages need and keeps them cached, so a reopen here costs 0.3 s, where the phone's
page cache is a few GB shared with everything else and a reopened Wikipedia reads its pages back from flash. The cache could not be
emptied here (nothing is installed to do it), so the true cold cost on a phone is at least the first row and was not measured. The
open itself (115 ms) is small because libzim maps rather than loads most of the file; what an eviction of Wikipedia mostly costs
is the first query after it.

**One archive per ZIM (the `zim` crate reader is gone from the xapian builds).** Until 2026-10-26 the `zim` crate reader (`ZimSource::zim`),
used by `cs_read`, `cs_zim_get`, `cs_zim_main_page`, the title lookups and the coverage reads, was opened by `set_sources` for every ZIM and held
for the life of the handle, outside the budget. Opening it cost about 2 MiB of private bytes per GiB of ZIM file (the page tables of the
mapping of the whole file: Wikipedia 231 MiB, armypubs 15, ifixit 6.5, wikispecies 6.4, ready.gov 4.3, wikivoyage 1.9; all 18 sources 270 MiB),
which on a phone with Wikipedia is as much as the whole libzim budget. Now, with libzim built in:
- `ZimSource::open` opens the crate reader only to read what the source needs for good (UUID, title, language, entry count, whether the
  ZIM has the full-text and title indexes and their sizes, which the cost model needs) and drops it before it returns. Opens run one at a
  time, so the peak is the largest ZIM's mapping (Wikipedia: about 230 MiB, for the milliseconds that takes) and nothing of it stays.
- Reads (`get`, `main_page_path`) lease libzim's archive, as above. The crate reader is opened again, lazily and kept, only for the
  Tantivy index build of a ZIM without a built-in index (`index.rs`) and as the fallback for a ZIM libzim cannot open.
- Builds without libzim (`--no-default-features`, Linux) keep the crate reader open and read through it, as before.
- The old and the new reader are both in every xapian build, so the byte-identity test can run them side by side
  (`ZimSource::get_crate` / `main_page_crate` against `get` / `main_page_path`).

**Measured, before and after** (Windows, release build, `cs serve` run once per row with `sources-full.json`: the recon library and
the 18 ZIMs, no `index_dir`, prewarm off, default caps; PrivateUsage of the process after the library opened, after 20 varied
queries (`k` 10) and after 20 reads of the first ZIM hit of each query at 6000 characters; the same 20 queries as the budget table above):

| Build | Budget (MiB) | After open | After 20 queries | After 20 reads |
|---|---:|---:|---:|---:|
| before (a042c1c, crate readers) | 1024 | 538 | 904 | 904 |
| after (one archive per ZIM) | 1024 | 267 | 636 | 631 |
| before | 384 | 539 | 892 | 892 |
| after | 384 | 269 | 621 | 608 |

About 270 MiB less at open (the crate readers), and 270 to 285 MiB less after the queries and reads; the reads themselves add nothing
visible because their clusters go through libzim's capped cluster cache. A read takes 2 to 4 ms on both builds (warm file cache).

**Byte-identity test** (`tests/zim_read_identity.rs`, `#[ignore]`d, needs `CS_TEST_ZIM_DIR`; run with
`cargo test -p cache_search --test zim_read_identity -- --ignored --nocapture`): on Wikipedia maxi, the medicine mini ZIM, ready.gov, iFixit, NHS,
Appropedia and armypubs it samples entries spread over the file with the crate reader (10 articles, 2 redirects, 2 images, a CSS or
script file and another type where the ZIM has them) and compares, for each path, the crate reader against the library
(`ZimSource::get`, `Handle::zim_get`: bytes, MIME type, path, title) and `cs_read` (the whole JSON at 300 and 6000 characters). It adds
variants of an article path (with `#fragment`, percent-encoded, with `?query`, with an `A/` namespace prefix), a path that is not there,
`X/fulltext/xapian`, `M/Title`, and the main page. Errors must match too (code and message). 508 comparisons, 0 differences.

**Tests** (`budget.rs` unit tests, no ZIMs; `tests/zim_budget_ffi.rs` on three real ZIMs, needs `CS_TEST_ZIM_DIR`): a budget of 0 opens
and closes per query and answers correctly (nothing is left open after any query, `per_query` counts every one); a tiny budget closes the least
recently used archive and reopens it on demand; the most recently used archives stay open and are never reopened while the
budget fits them; an archive over the whole budget closes after its query; results and the estimated totals are identical for budgets
0, under the smallest archive, one archive, two archives, all three and the default, with the queries and suggestions run twice;
`searcher_budget_mb` works as an alias and loses to `zim_budget_mb`; prewarm opens only what fits and closes nothing.

### Coverage-read cost (Xapian hits)

A Xapian source's top hits (at least 10 per source) are read from the ZIM to compute term coverage (see "Search and merge"). Measured
2026-10-26 on Windows (release build, sources-full.json: 18 ZIMs plus the recon library, warm, mean of 10 queries, two runs each
way, the reads switched off with a temporary test-only switch that is not in the code): 967 and 951 ms per query with the reads, 681
and 681 ms without, so the reads cost about 270-285 ms per query (29%).


### Android build

Built 2026-10-26 (rebuilt the same day for the memory budget, commit 17baa2c, and again for one archive per ZIM, commit f64c7c9, v3: `libzim.so`, `libc++_shared.so` and the ICU data are unchanged, only `libcache_search.so` differs, by 13,040 bytes more than v2) for `aarch64-linux-android` with the `xapian` feature on, the way the Flutter plugin builds the core
(`cargo ndk --platform 28 -t arm64-v8a build --release -p cache_search`, NDK 28.2.13676358), with `LIBZIM_DIR` set to the folder
`fetch-libzim.sh` unpacks (official `libzim_android-arm64-9.8.2-1.tar.gz`, md5 `59a6b769847b77dc0ace69c3b9727445` checked by the
script). `build.rs` compiles `zimx.cpp` with the NDK's clang++ and links `libzim.so` and `libc++_shared.so`. What the app ships (sizes
as built; none of it is committed):

| File | Where | Size (bytes) |
|---|---|---:|
| `libcache_search.so` (release, stripped) | `jniLibs/arm64-v8a/` | 50,468,960 |
| `libzim.so` (official prebuilt, `llvm-strip --strip-unneeded`; 16,230,992 unstripped) | `jniLibs/arm64-v8a/` | 8,247,096 |
| `libc++_shared.so` (NDK 28.2, stripped copy) | `jniLibs/arm64-v8a/` | 1,253,544 |
| `icudt73l.dat` (ICU 73.2 data) | a real file in app storage, not in `jniLibs` | 10,955,552 |
| Total | | 70,925,152 (60.0 MB without the ICU data) |

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

"Every API data point works this way": one engine, no per-source code. A source is one JSON file, pure data, so the same file
works on every platform; the app points `"live": {"db_path", "sources_dir"}` at a folder of them. The files that ship are in
`packages/cache_search/sources/` (`weather.json`: Open-Meteo, `alerts.json`: NWS); the app copies them into its sources folder
on install, and a user adds or shares more by dropping files there (the starter catalogue is `cache-packs/connectors/`). An
unreadable file is listed under `errors` by `cs_live_sources` and does not stop the others.

This section is the format reference. The format is **2**; format 1 files read unchanged (format 2 only adds). Unknown keys
are errors, so typos show, and every error names its field (`items[0].fields[2].time.in: ...`). The JSON Schema of the format
is generated from the Rust types and committed as `packages/cache_search/schema/live-source.schema.json` (editors that know JSON Schema
complete and check against it; `UPDATE_SCHEMA=1 cargo test -p cache_live --features schema` rewrites it, and the same test
fails when it is stale). Write and test a definition with `cs live-check` and `cs live-preview` (see "Builder's tools").

#### Shape

```
{ "format": 2, "id": "weather", "title": "Weather forecast", "provider": "Open-Meteo",
  "description": "one line: what the model and the Home card see of this source",
  "attribution": "credit line shown with the data",
  "request": { ... },                                    see Request
  "api_key": { "alias": "eia", "required": true },       a key; "{api_key}" in url, headers or body
  "basic_auth": { "user_alias": "u", "password_alias": "p" },   HTTP Basic login (instead of api_key)
  "params": [ { "name": "radius", "type": "number", "default": 50 } ],   values the user sets
  "refresh_minutes": 180,                                a fetch inside this time returns the stored copy
  "quota": { "per_minute": 30, "per_day": 2000, "per_month": 30000 },       all optional
  "validity": { "fixed_hours": 6 }                       or { "end_path": "daily.time[-1]", "end_of_day": true,
                                                              "not_covered_after": true }
  "require": ["current", "daily.time"],                  paths that must exist, else bad_response
  "timezone_path": "timezone",                           optional: IANA zone name in the response (best)
  "utc_offset_path": "utc_offset_seconds",               optional: fixed offset; without either, the offline lookup
  "items": [ <item group>, ... ] }
```

#### Request

```
"request": {
  "url": "https://api.example.org/v1/near?lat={lat}&lon={lon}",   https only (http only to 127.0.0.1 and localhost, for tests)
  "method": "GET",                      GET (default) or POST
  "headers": { "Accept": "application/geo+json", "User-Agent": "Cache (https://example.org)" },
  "body": { "q": "{name}", "radius": "{param:radius}" },   POST only; json (default), form or text, see below
  "body_type": "json",
  "timeout_seconds": 30,                default 30, at most 120 (the USGS Idaho bbox query needs about 45)
  "max_bytes": 8388608,                 default 8 MiB, at most 32 MiB; counted after gzip is undone
  "response": "json",                   json (GeoJSON too), xml, csv, tsv, tle or auto
  "table": { ... }, "xml": { ... },     reading of csv/tsv and xml, see Response formats
  "paging": { ... },                    more pages of a long result, see Paging
  "steps": [ ... ] }                    several requests in order, see Steps (then url, body, response and paging go in the steps)
```

Every fetch sends the User-Agent `Cache/<version>` unless a header sets another (NWS asks for a contact; use the project, never a
person). Gzip is asked for and undone whether or not the server says so. Keys, passwords and the Basic header are used for the
call only, never stored, and removed from every error message and from the preview's request list.

**Placeholders** in the url, header values, the body and step urls (values are percent-encoded in a url or form; add `|raw` to
insert as is, `{point:properties.forecast|raw}`; headers and JSON strings never encode):

| Placeholder | Value |
|---|---|
| `{lat}` `{lon}` | the place's degrees, 4 decimals; `{lat:2}` for another count |
| `{latlon}` `{lonlat}` | `lat,lon` or `lon,lat` (`{latlon:2}`) |
| `{lat_abs}` `{lat_hem}` `{lon_abs}` `{lon_hem}` | magnitude and `N`/`S`, `E`/`W` for APIs that want `43.6N 116.2W` |
| `{name}` `{place_key}` | the place's name and key |
| `{bbox:50km}` `{bbox:30mi}` `{bbox:$radius:mi}` | `west,south,east,north` of a box that far (half-width) around the place; `$radius` reads a parameter, the last part is its unit (default km) |
| `{west:50km}` `{south:50km}` `{east:50km}` `{north:50km}` | one edge of that box, for APIs with a parameter per edge |
| `{state}` `{state_name}` `{county}` `{county_fips}` `{country}` `{country_name}` | the place's detail, from optional members of the place the caller gives (`{"lat","lon","state":"ID","county":"Cassia","county_fips":"16031","country":"US",...}`; the app fills them from its geocoder; `cs_live_fetch` also does it for a `place` that is a name no saved place has: the installed places pack resolves it, keys it `at:<lat>,<lon>` and adds `state`, `state_name`, `county` and `country` where the pack has them, `county_fips` and `country_name` it does not). A place without the detail fails with a message that says which |
| `{api_key}` | the key (declared in `api_key`); in the query, a header (`"Authorization": "Bearer {api_key}"`, any header name and prefix), the body or the path (`/csv/{api_key}/VIIRS/`) |
| `{secret:alias}` | any other secret the caller gives under that alias |
| `{param:name}` | a user parameter (see Parameters) |
| `{now}` `{now-24h}` `{now+3d}` | the fetch time in UTC, `%Y-%m-%dT%H:%M:%SZ` by default; `{now-24h:unix}`, `{now:unix_ms}` or `{now:%Y-%m-%d}` for another form |
| `{step:path}` `{item:path}` | a value from an earlier step's response, or the current element of a repeated step (see Steps) |

OAuth is not in the format (no token exchange, no redirects to a login page). A key, a header, Basic and a key in the path
cover the public APIs that do not need it.

**Bodies.** `"body_type": "json"` (default): the body is a JSON value, every string in it takes placeholders, and a string that is
exactly `"{param:radius}"` keeps the parameter's type (`25`, `true`), so `{"radius": 25}` is sent. `"form"`: an object of strings,
sent as `application/x-www-form-urlencoded`. `"text"`: a string. Example (a POST search):

```
"request": { "method": "POST", "url": "https://api.example.org/search",
             "body": { "near": { "lat": "{lat}", "lon": "{lon}" }, "radius_km": "{param:radius}", "kinds": ["fire", "{param:kind}"] } }
```

**Authentication examples.**

```
key in the query     "url": "https://api.example.org/data?lat={lat}&key={api_key}"         + "api_key": {"alias": "example"}
key in a header      "headers": { "X-Api-Token": "{api_key}" }                          Authorization: "Bearer {api_key}" works the same
key in the path      "url": "https://api.example.org/area/csv/{api_key}/VIIRS_SNPP_NRT/{bbox:100km|raw}/1"
HTTP Basic           "basic_auth": { "user_alias": "svc_user", "password_alias": "svc_pass" }   sent as Authorization: Basic ...
```

The caller gives the values in the fetch request (`"api_key": "..."` or `"secrets": {"svc_user": "...", "svc_pass": "..."}`); the app
keeps them in secure storage under the aliases and `cs_live_sources` lists which a source needs. A response that points at
another host is not followed with a key attached (see Steps).

#### Parameters

Values the user sets when adding the source (a gauge number, a radius, a fuel type). `{"name": "site", "label": "Gauge number",
"type": "text"|"number"|"integer"|"bool"|"choice", "default": "13206000", "choices": [...], "min": 1, "max": 300, "required": true,
"help": "..."}`. Use them as `{param:site}` in the request and `{"param": "site"}` as a value in the mapping (for example
`"near": {"max": {"param": "radius"}, "unit": "mi"}`). A fetch or get request gives `"params": {"site": "13172500"}`; a missing
one takes its default; a value outside its type or limits is `bad_json`. The row is stored under the place key when every
parameter has its default, otherwise under `<place key>~<8 hex>`, so two gauges of one source for one place do not overwrite
each other (`cs_live_get` reports the place with that key and the `params`; deleting a saved place deletes all of its rows).

#### Response formats

`"response"`: **json** (default; GeoJSON is JSON) and **auto** (decided by the first character).

**xml**: converted to a tree before mapping. An element is an object; attributes are keys that start with `@` (`link.@href`); text
next to attributes or children is `#text`; an element with only text is that text (empty: `null`); a repeated element is an
array, and names listed in `"xml": {"always_array": ["info", "area"]}` are arrays even when they occur once (so
`alert.info[0].event` works for one language or two); namespace prefixes are dropped; the root element is the single member of
the tree (`feed.entry`). DOCTYPE entities are never expanded.

```
<feed><entry><id>a1</id><link href="https://x/a1"/></entry><entry>...</entry></feed>
  ->  {"feed": {"entry": [ {"id": "a1", "link": {"@href": "https://x/a1"}}, ... ]}}
```

**csv** and **tsv**: an array of objects keyed by the header row, values as text. `"table": {"delimiter": ";", "header": false,
"comment": "#", "skip_after_header": 1}`: another delimiter, no header row (columns `c0`, `c1`, ...), comment lines to skip, rows to
drop after the header. The USGS RDB format is `"response": "tsv", "table": {"comment": "#", "skip_after_header": 1}`. Map the
rows with `"each": "^"`.

**tle**: two-line element sets (a name line is optional) as an array of `{name, norad_id, classification, intl_designator, epoch,
inclination_deg, raan_deg, eccentricity, arg_perigee_deg, mean_anomaly_deg, mean_motion_rev_per_day, rev_number, line1, line2}`.
Orbit and pass calculation is not a mapping and is not in the format.

#### Steps: a later request using an earlier response

```
"request": { "headers": { "Accept": "application/geo+json" },       shared by every step
  "steps": [
    { "id": "point", "url": "https://api.weather.gov/points/{lat},{lon}" },
    { "id": "fc",    "url": "{point:properties.forecast|raw}" },
    { "id": "st",    "url": "{point:properties.observationStations|raw}" },
    { "id": "obs",   "url": "https://api.weather.gov/stations/{s:properties.stationIdentifier}/observations/latest",
      "for_each": { "from": "st", "path": "features", "as": "s", "limit": 3 } } ] }
```

Each step is a request of its own (own `url`, `method`, `body`, `response`, `paging`); `{id:path}` reads a path of an earlier step's
response, `{id}` its text if it is one value. `for_each` repeats the step for the first `limit` elements (default 10, at most 50) of
a list in an earlier, non-repeated step; the current element is `{as:path}`; the step's result is the list of responses. A
repeated request that fails (404, a timeout) is left out and counted (`missing_requests` in `cs_live_get`); all failing is an error.
At most 6 steps. The mapping reads one object with a member per step id: `"each": "fc.properties.periods"`,
`"each": "obs"`, `"timezone_path": "point.properties.timeZone"`. A url taken from a response is only sent to hosts the definition
names itself when the source has a key or login (a key is never sent to a host a response points at). Every request of every
step counts once against the quota.

#### Paging

`"paging"` on a request or step fetches more pages and joins the list found at `list_path` across pages into the first page's
tree; the mapping sees one list. It stops when a page has no items, when `more_path` says there is no more, or when the next
page cannot be known; `max_pages` (default 5, at most 50) is a hard cap, and reaching it with more data left sets
`"truncated": true` in `cs_live_get` and the preview. Every page counts against the quota.

```
offset     {"type": "offset", "param": "resultOffset", "size_param": "resultRecordCount", "page_size": 1000,
            "list_path": "features", "more_path": "properties.exceededTransferLimit", "max_pages": 5}      ArcGIS
page       {"type": "page", "param": "page", "size_param": "per_page", "page_size": 100, "start": 1, "list_path": "data"}
cursor     {"type": "cursor", "param": "cursor", "next_path": "meta.next_cursor", "list_path": "data"}
next_link  {"type": "next_link", "next_path": "links.next", "list_path": "data"}      absolute or /relative; same host only
```

Without `more_path`, an offset or page request continues while a page is full (`page_size` items). `param` and `size_param` are
set in the url's query (replaced if already there). `list_path` empty or `"^"`: the response itself is the list.

#### Rate limits, errors and size

A `429` (or a `503` with `Retry-After`) is waited for as the provider asks (`Retry-After` seconds or a date; without it 2 s, 4 s),
at most three tries, and each try counts against the quota. A provider that asks for more than 60 s is not waited for: the
fetch fails at once with the wait in the message. Any other 4xx or 5xx fails with `fetch_failed` and a message such as
`HTTP 404: No such site: 99` (the reason is taken from the response's `message`, `error`, `detail` or `reason` when it has one) plus
`(the key or login was refused)` for 401/403. A failed fetch keeps the last good copy, and the message is recorded for the source
and place (`last_error` in `cs_live_get`). A response over `max_bytes` is `bad_response`, never cut. A quota is checked before every
request; `quota` ends the fetch.

#### Item groups and values

Item group: `{ "each": "<path>", "key": V, "label": V, "time": V?, "ends": V?, "fields": [ V+label ], "where": [..]?, "near": {..}?,
"sort": [..]?, "limit": n?, "point": {"lat": V, "lon": V}?, "area": "<path to a GeoJSON geometry>"? }`. One item per element of
`each`, an array, or an **object** (one item per member; `@key` is the member name, so `{"0": {...}, "1": {...}}` maps with
`"each": "scales", "key": {"path": "@key"}`); without `each`, one item from the response root. `key` is the item's stable id (it ends
up in its address); `ends` is when the item stops being true (ended items are left out); `fields` are the labelled values, in order,
a field with no value is left out; `point` and `area` are for map layers and Home cards (not given to the model). Order of
processing: map, `where`, `near`, `sort`, `limit`.

A value `V` is found by exactly one of `path`, `const`, `template` (`"{a} mph {b}"` with `vars`), `first_of` (first that has a
value), `distance`, `param` (a user parameter) or `calc`, then formatted by these steps, in this order: `after_last` (keep the text after the last `"/"`, for the last part of a URL); `time` or `scale`,
`offset`, `round` (decimals), `compass` (degrees to N/NE/...); `lookup` (a fixed table from a code to text, `"*"` is the fallback;
replaces the result); `omit_if` (values to treat as missing); `min_value`, `max_value` (a number outside them is missing: providers write -999 for "no reading"); `case`; `max_chars`; `prefix`, `suffix`. A `time` step may also have `not_before` (a date; earlier times, such as year 1 for "no time", are missing). No scripting.

Paths are dot-separated keys with `[n]` indexes (`[-1]` last). A path starts at the current element (the `each` element), `^`
starts at the response root, `@` is the element itself, `@key` (the whole path) the member name of an object, and `[#]` the index,
so a response with one array per column reads as `"each": "daily.time"` plus `"path": "^daily.temperature_2m_max[#]"`. XML
attributes are `@name` keys (`link.@href`).

**calc**: arithmetic on other values, `{"calc": {"op": "add"|"sub"|"mul"|"div"|"min"|"max", "args": [V, V, ...]}}` (the signs
`+ - * /` also work; left to right; division by zero or any missing argument gives no value; the number at the start of a text
counts, so `"20 mph"` is 20). The result then takes `round`, `suffix` and the rest: wind speed ratio
`{"calc": {"op": "div", "args": [{"path": "gust"}, {"path": "speed"}]}, "round": 1}`; a `first_of` argument gives a fallback.

**Times.** `"time": {"in": ..., "out": ..., "zone": "place"?}`:

| `in` | the response writes |
|---|---|
| `local` | no offset, the place's local time: `2026-10-25T14:00` (a space, seconds and a `Z` are also read), or a date |
| `utc` | no offset, UTC: `2026-10-26 05:17:56.783`, `2026-10-26T12:00:00`; written in the place's offset |
| `rfc3339` | with an offset (kept as the provider wrote it, or converted with `"zone": "place"`) |
| `rfc2822` | `Sun, 25 Oct 2026 19:40:00 +0000` |
| `unix` `unix_ms` | seconds or milliseconds since 1970 (USGS and ArcGIS dates); written in the place's offset |
| `pattern` | `"pattern": "%d/%m/%Y %H:%M"` (strftime); with `%z` it has an offset, without it `"assume": "place"` (default) or `"utc"` |

`out` is `datetime` (default `2026-10-25T14:00-06:00`), `datetime_s`, `date` or a strftime pattern. A sort key or `ends` reads the
same `time` step; without one they read RFC 3339.

**Distance.** `{"distance": {"geometry": "<path>" | "point": {"lat": V, "lon": V}, "unit": "mi"|"km", "number": false}}` is the distance
from the place to the nearest point of a GeoJSON Point, LineString, Polygon, their Multi forms, a Feature, a collection, or of a coordinate
pair, with the compass direction of that point (`6.2 mi S`), `inside the area` when the place is within an area (holes count) and
`at the place` within 50 m; `"number": true` gives only the number, for `calc`, `where` and `round`. An item with no geometry has no such field;
nothing is estimated from a name.

**near.** `"near": {"max": 50, "unit": "mi"}` on a group drops items farther than that from the place, measured to the item's `point`
(else its `area`), or to `"point": {...}` or `"geometry": "<path>"` named in `near`. `max` may be a value (`{"param": "radius"}`).
An item with nothing to measure is dropped.

**where.** `"where": [ {...}, ... ]` keeps items that pass every condition. A condition names what it tests with exactly one of `value`
(a value `V` of the response), `field` (the label of one of the item's own `fields`; the number at the start of the text is used for
comparisons) or `or` (a list of conditions, any of which may pass), and has one or more tests: `equals`, `not_equals`, `in`, `not_in`
(text compares ignoring case, numbers numerically), `gt`, `ge`, `lt`, `le` (a number or a value such as `{"param": "min_size"}`),
`contains`, `starts_with`, `exists`, and `max_age_hours` (the value is a time, read with its `time` step, no more than that many hours before the fetch: it leaves out gauges that stopped reporting). A missing value fails every test except `not_equals`, `not_in` and `exists: false`.
No expressions: comparisons only.

```
"where": [ { "value": { "path": "properties.IncidentTypeCategory" }, "equals": "WF" },
           { "or": [ { "value": { "path": "properties.POOState" }, "equals": "ID" }, { "value": { "path": "properties.POOState" }, "equals": "OR" } ] },
           { "field": "Size", "ge": { "param": "min_acres" } } ]
```

**Sorting and limit.** `"sort": [{"by": V, "rank": [..] | "time": true | "number": true | "distance": true, "desc": false}, ...]` (first key first;
missing values last; `rank` orders by a list, `number` by the number at the start of the value, `distance` by distance from the
place to the item and needs no `by`); `"limit": 20` keeps the first items of the group after sorting. The alerts definition sorts by
NWS severity then onset.

#### Time zones, validity, rows

Every time the core writes (`fetched_at`, `valid_until`, `age` bases, item times, `last_error.at`) is in the place's local offset, as
TOOLS.md says. The place's time zone is, in this order: the IANA name at `timezone_path` in the response (Open-Meteo `timezone`), a
fixed offset at `utc_offset_path`, the offline lookup of the place's position, UTC. A named zone knows daylight saving, so a
forecast that crosses the change shows -06:00 before it and -07:00 after, and its `valid_until` (local midnight at the end of the last
day) is exact. The zone is stored with the row, so a stored response is re-read in the same zone.

Offline zone lookup: `tzf-rs` 2.1 (MIT) with its lite embedded boundary file, queried in place (`EmbeddedFinder`, no expansion into
memory), and `chrono-tz` 0.10 (MIT OR Apache-2.0) for the offsets. The boundary data is from timezone-boundary-builder (ODbL-1.0):
the app's credits need a line for it.

Validity: `fixed_hours` after the fetch, or the end of the day found at `end_path` (a forecast is valid until its last day ends;
`not_covered_after` then reports that date). After `valid_until` the data is expired. Rows for the phone's position (`at:` keys) are
pruned: after a fetch for one, the other `at:` rows of that source are deleted unless they are still within their validity. Saved
places are never pruned. The stored response is the converted tree (JSON as received, XML and CSV as their JSON form, steps as the
object of step responses), so a changed definition re-maps it without a download, with the parameters it was fetched with.

#### Builder's tools

* `cs live-check <def.json>`: parses and validates a definition, prints every problem with its field
  (`items[0].where[1]: needs a test`, `request.steps[1].for_each.from: no earlier step called "zzz"`) and warnings (no `require`, no
  `quota`, no `attribution`). Needs no network and no config.
* `cs live-preview <def.json> --place 42.536,-113.792 [--name ..] [--state ID --county Cassia --country US] [--param k=v]... [--key V | $CACHE_LIVE_KEY]
  [--secret alias=v]...`: fetches once (every step and page, with the definition's timeout and size limit) and prints, as JSON, the
  requests made (status, bytes, ms), the **raw response tree** cut down so it can be read (long lists keep their first elements and say how many
  more; `--raw-chars` sets the size), the **paths** in it in the mapping's own syntax (`features[0].properties.name = "Fire"`), and the
  **mapped items**. If the mapping fails the raw tree is still shown, with the reason. It stores nothing and counts against no quota.
* `cs_live_preview(request_json)`: the same as one C call, without a handle, for an in-app connector builder: the definition as text plus
  place, params and keys; see `include/cache_search.h`.
* The JSON Schema above.

Workflow: write the `request`, run `cs live-preview` with a throwaway `items`, read the paths, write the mapping, run `cs live-preview` again,
then `cs live-check`.

#### Not in the format, on purpose

No OAuth or login flows, no scripting or free-form expressions, no per-source code, no cookies or sessions, no HTML scraping (a source is a
documented API), no orbit or pass prediction, no unbounded loops (fan-out, steps and paging all have hard caps).

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

### `live_data` and the places pack

Decided by the Cache lead (ref-a5), 2026-10-26. The `place` the model gives is not matched against saved place names only. The
tool resolves it, in this order:

1. a saved place (key or name, ignoring case): its own stored data is used whatever the distance;
2. `lat,lon` text (the form `navigate` takes: `"44.4238,-111.3714"`): the point as written, shown as written;
3. a name the places pack resolves, through `ToolCtx::geocoder` (`cache_tool::places::Geocoder`,
   `resolve(text, near) -> Option<(name, lat, lon)>`; `near` is the phone's position when it is known, to choose between towns of
   one name). `cache_places::PackPlaceSource` implements it over the same `PackGeocoder` that `navigate` and `locate` use:
   `forward` search (name, alternative names, prefix, state or county after a comma) when its first match fits the name
   (`name_score` 40 or more), else the town whose name is the text with a typing slip in it (`fuzzy_town`: optimal string
   alignment distance, nothing to do with the language: no edits allowed under 4 letters, 1 up to 9, 2 from 10; ties go to the
   town nearer the phone, then to the larger one). A match that only has one of the words in its name is not a match;
4. no place text: the phone's position (`here_key`).

With no places pack installed `geocoder` is `None` and only 1 and 2 apply: any other text is `geocode_empty` (as before).
A text the pack cannot resolve is `geocode_empty` too.

The data is then looked up by distance, not by key: every place the source has stored data for (saved places, and the positions
the phone fetched at) is a candidate, and the nearest one within `live_radius_km` (the `live` config key, default 30) is used;
the nearest whose data has not expired when there is a choice. The result's `place` is that place, and when it is not the one
asked about and is at least 1 km from it, `asked_place` (the name that was resolved, or the text for coordinates and
`current location` for the fix) and `distance_from_asked_km` (whole km, at least 1) follow it, so the assistant can say "I
only have Ashton, 40 km from Island Park". The item addresses are those of the place the data is for.

Nothing within the radius is `no_data` with the nearest stored place and its distance in the detail (`no weather data within 30 km
of Island Park, ID; the nearest place with data is Ashton, ID, 40 km away`), never `geocode_empty`; when nothing at all has
been downloaded for the source the older wording stays (`no weather data has been downloaded for X`).

HTTP is `ureq` (blocking, rustls with bundled root certificates, no async runtime): the app's scheduler or the CLI calls
fetch from a worker thread, so a blocking client is enough and it adds far fewer crates than reqwest (tokio, hyper).
SQLite is `rusqlite` with the `bundled` feature (compiled in, nothing linked from the system).

### Live fetch policy and keys

Decided by the Cache lead (ref-a5), 2026-10-26. The host grants network fetches and holds the API keys; the core fetches. The
core has no callbacks into the host, so the host pushes its state in:

- `cache_tool::LiveFetcher` (`can_fetch(source_id) -> bool`, `key_for(source_id) -> Option<String>`) is what a tool asks.
  `ToolCtx.live_fetcher: Option<&dyn LiveFetcher>` carries it; it is `None` unless the host has set a policy.
- The handle holds the built-in implementation, `cache_tool::fetcher::PolicyFetcher` (`Handle.fetcher`).
  `cs_live_set_fetch_policy(h, json)` takes `{"online","allow_metered","metered","enabled_sources":[ids]}` and
  `can_fetch = online && source in enabled_sources && (!metered || allow_metered)`. A null json clears the policy; with no
  policy `can_fetch` is false for everything, so captures and tests never fetch, and `ToolCtx.live_fetcher` is `None`.
  A bad document is `bad_json` and the old policy stays.
- `cs_live_set_key(h, source_id, key_or_null)` keeps one source's key in memory only. `PolicyFetcher` has no `Debug`, no
  serialisation and no accessor except `key_for`; the key is in no error, status, log or result (tests search every string
  the core returns for a sentinel key). A null (or empty) key clears it; `cs_close` clears the policy and every key, and the
  key strings are overwritten before they are freed.
- The fetch itself (the on-demand fetch in `live_data`, the row keys and pruning) is built on top of this plumbing and is not
  part of it: `live_data`'s behaviour is unchanged.
- CLI: `--live-policy <json>` (`cs tool`, `cs tool-schemas`, `cs serve`) and `CACHE_LIVE_KEY_<SOURCE>` environment variables
  (source id in capitals, any other character `_`: `nws-alerts` is `CACHE_LIVE_KEY_NWS_ALERTS`; read at start for each
  installed source). `cs serve`: `POST /live/policy` (the body is the policy), `DELETE /live/policy`,
  `POST /live/key {"source_id","key"}` (a null key clears it), `DELETE /live/key/{source_id}`; each answers `{"ok":true}` and
  never echoes a key.

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
