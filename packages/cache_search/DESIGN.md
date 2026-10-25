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

## Tools

The model's tools (docs/TOOLS.md) run through the core, so the phone and the headless runs share one dispatch:
`cs_tool_schemas` lists the available tools' function schemas and `cs_tool` runs one call and numbers its result
in the conversation.

**Registry.** The handle holds `Vec<Box<dyn cache_tool::Tool>>`. The host adds tools with
`Handle::register_tool` (a tool registered again under the same name replaces the first), sets the user's saved
places with `set_saved_places` (default `NoSavedPlaces`) and the query embedder of `search` with
`set_query_embedder` (a callback `&str -> Option<(model id, vector)>`; with none, search is keyword-only, as
`cs_search` is without a `query_vector`). The core does not depend on `cache_live` or `cache_user`; `cs_open` will
register their tools from the config's "live" and "user" sections once those crates are on this branch (a comment
marks the place). `cs_tool_schemas` lists tools in the order search, read, navigate, nearby, locate, live_data,
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
error codes. `KagiProvider { base_url }` (default `https://kagi.com/api/v0/search`, overridable for tests) sends
`GET ?q=<query>&limit=<n>` with `Authorization: Bot <key>`, reads `data` (objects with `t: 0` are results with `url`,
`title`, `snippet`; other `t` values are skipped) and the `error` list. HTTP 401/403 or an error code 401/403 is
`key_missing` ("web search key rejected"); 402/429, or an error mentioning balance, quota or credit, is `quota`; a
timeout, a refused connection, or any other bad status (500, ...) is `fetch_failed`; JSON that cannot be used is
`bad_response`. **The Kagi parser is unverified against the live API:** it was written from Kagi's documented v0
response shape and tested only against a local stand-in server, until the owner approves a live test.

**Results.** Up to 5 lines in the form of `search`: `{{addr:web:<url>}} <title> (web, fetched <YYYY-MM-DD HH:MM from
now>) — <snippet>`; the snippet is cut by the library-search rule (`snippet_chars`, a sentence end or a word
boundary with `…`), the title to 150 characters. Repeated URLs are dropped. Text from the web is made safe for the
line: whitespace runs become one space, `{{` becomes `{ {` so a page cannot forge an address marker, and a ` — ` in
a title becomes ` - ` (the numbering reads the title up to the first ` — `). Nothing found: `No results found.`

**Read.** `read` on a `web:` number fetches the URL (GET, up to 5 redirects, `User-Agent: Cache/<version>`), strips
HTML with the same rules as a ZIM article (`html_to_text`: headings kept, script and style removed; plain text is
used as it is), and cuts to 6,000 characters at a paragraph end. Output: `[n] <title> (web, fetched <time>)`, the
text, and `[truncated]` when cut (or when the download hit the cap). When the page cannot be had, the output is the
same first line, the snippet the search showed (the conversation keeps each web hit's title, snippet and fetch time
beside its number), and a last line `[full page did not load in time]` (timeout) or `[full page not available]`
(connection failure, bad status, a content type that is not HTML or text, a page with no text, or the phone being
offline, in which case nothing is fetched). That is a result, not an error. Compression is not requested: the
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
