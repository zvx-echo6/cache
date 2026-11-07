# Library log and local view (pack revision 4)

**Status: agreed with the app orchestrator (2026-11-02); for 1.1.** Code: `cache_builder::log` (events, append, read, resolve), `cache_builder::view`
(the local view), `cache-build library` (the seed log) and `server/src/libbuild/booklog.rs` (the build service).

## The rule

**Nothing that syncs ever has two writers.** `cache_sync` does not merge files; when two devices both change one it keeps a conflict copy beside it. So:

1. **Facts** about a book live in its pack (PACK-FORMAT.md, revision 4, the `book` block). A pack is immutable and written once by the device that built the book.
2. **Changes** (where a book is shelved, its call number, a new title, hiding it) are events in a **per-device log**, `<library>/log/<device_id>.jsonl`. Only the device
   named in the file writes it. Every device reads all the logs and resolves them the same way.
3. The **view**, `<library>/.local/docs.json`, is what a device shows. It is rebuilt from the packs and the logs, is local, and never syncs.

```
<library>/
  cache-library.json  shard/  documents.tsv  SHA256SUMS
  packs/<doc_id>@<version>.cdoc        facts (synced)
  log/<device_id>.jsonl                changes, one file per device (synced)
  log/builder-<library_id>.jsonl       the seed log of a published library (synced)
  .local/docs.json                     the view (never synced)
```

`cache_sync` never sends a name that starts with a dot, so `.local/` needs no rule of its own; keep it out of every allow-list.

## The device id

The device id is `cache_sync`'s identity (`cache_sync::identity::load_or_create`: the EndpointId's text, lower-case letters and digits), which a reinstall replaces. A new id simply
starts a new log file. It is used in a file name, so it holds letters, digits, `.`, `_` and `-` only (at most 64, not starting with a dot). The seed log's id is
`builder-<library_id>`, kept by the `cache-build` command line. **Cache for Linux** (Cache on Linux) keeps its identity in `<data>/sync` (`identity.key`, the 32 secret-key
bytes), the one folder for this device's sync identity and anything sync keeps later; the library log's `dev` is that id. If the identity cannot be made it logs as
`unsynced`. The random `server-<hex>` id of earlier builds (`<data>/build/device_id`) is no longer read or written; its log file stays and its events still count.

## Events

A log is JSON Lines: one event per line, UTF-8, `\n` after every line, never edited, only appended. Every event has:

| Key | Meaning |
|---|---|
| `v` | `1`. A reader skips an event with another `v`. |
| `at` | UTC milliseconds since 1970. |
| `dev` | The writing device's id (the same as the file name). |
| `ev` | The event name. A reader skips an event it does not know, and unknown extra keys are ignored. |
| `doc` | The `doc_id` the event is about. |

The events:

```json
{"v":1,"at":1793600000000,"dev":"builder-recon","ev":"place","doc":"b3f1","div":"210","by":"auto"}
{"v":1,"at":1793600000001,"dev":"builder-recon","ev":"assign","doc":"b3f1","div":"210","seq":1}
{"v":1,"at":1793600100000,"dev":"phone-7","ev":"place","doc":"b3f1","div":"220","by":"user"}
{"v":1,"at":1793600100001,"dev":"phone-7","ev":"retire","doc":"b3f1","div":"210","seq":1}
{"v":1,"at":1793600100002,"dev":"phone-7","ev":"assign","doc":"b3f1","div":"220","seq":1}
{"v":1,"at":1793600200000,"dev":"phone-7","ev":"unsort","doc":"c9d2","by":"user"}
{"v":1,"at":1793600300000,"dev":"phone-7","ev":"title","doc":"b3f1","title":"Wilderness Medicine Handbook, 7th ed"}
{"v":1,"at":1793600400000,"dev":"phone-7","ev":"remove","doc":"c9d2"}
{"v":1,"at":1793600500000,"dev":"phone-7","ev":"restore","doc":"c9d2"}
```

| Event | Keys | Meaning |
|---|---|---|
| `place` | `doc`, `div`, `by` | The book goes on the shelf of division `div` (three digits). `by` is `auto` (the sorter, or a label) or `user`. |
| `unsort` | `doc`, `by` | The book goes to Unsorted. |
| `assign` | `doc`, `div`, `seq` | The book takes call number `seq` in `div`. |
| `retire` | `doc`, `div`, `seq` | The book gives up number `seq` in `div`. A retired number is never used again. |
| `title` | `doc`, `title` | A new title. |
| `remove` | `doc` | **Only hides the book in the library on every device.** It never deletes files. |
| `restore` | `doc` | Shows a hidden book again. |

Removing a *file* from a device follows the offload rule (only when the person asks, and a live check confirms another device holds a verified copy). It is not a log
event, because which files a device holds is per device.

### Linked-folder events

The linked-folder events are additive `v: 1` events. Older readers skip them as unknown events and keep reading later known events.

```json
{"v":1,"at":1793600600000,"dev":"linux-a","ev":"folder","folder_id":"books","label":"Books","mode":"keep"}
{"v":1,"at":1793600600001,"dev":"linux-a","ev":"locate","doc":"b3f1","folder_id":"books","relpath":"Firearms/Gunsmithing.pdf","version":2,"source_blake3":"<64 hex characters>"}
{"v":1,"at":1793600600002,"dev":"linux-a","ev":"unlocate","doc":"b3f1","folder_id":"books","relpath":"Old Name.pdf"}
```

- `folder` has no `doc`; it carries `folder_id`, display `label`, and `mode` (`keep`, `cds`, `both`). Folder state is keyed by `(dev, folder_id)` and the latest event by the normal event stamp wins.
- `locate` and `unlocate` require a nonempty normalized relative `relpath` using `/`. Absolute roots, drive/ADS syntax, backslashes, empty path components, `.` and `..` components are rejected on read and append. The absolute folder path, URI, or bookmark stays in that device's `.local/` and is never serialized.
- `version` (the numeric document version) and `source_blake3` are optional on `locate`; the hash, when supplied, is 64 hexadecimal characters. They anchor a source version without changing document identity.
- A location is keyed by `(dev, folder_id, doc, relpath)`. The latest locate/unlocate stamp for that key wins; a move is unlocate-old plus locate-new. Locations from two folders remain two locations for one document. Results are deterministic by device, folder id, and relative path.
- The resolved location reports the device and relative path. Availability is always device-local and is not synchronized or inferred from these events. Linked-folder events do not rebuild `.local/docs.json`: some imported libraries do not have local packs, so calling `rebuild_view` from this log alone is unsafe.

### Writing

- **Atomic lines.** An append builds all its lines first and writes them in one `write` to a file opened for append, then flushes to disk (`fsync`).
- **One writer per file.** A writer refuses an event whose `dev` is not its own.
- **Order.** A device never writes an event with an `at` earlier than its own last one (a clock set back is held at the last `at`). Two events of one device with the same `at` count in file order.
- **A torn last line.** A crash can leave the last line cut off. A reader skips any line that is not an event (and counts it). The next append starts with a line break when
  the file does not end in one, so the new event is never glued to the torn one.
- **A move** is three events in this order: `place` (new division), `retire` (old number), `assign` (new number). Going to Unsorted is `unsort` then `retire`.

## Resolution

The same on every device, a pure function of all the events (`cache_builder::log::resolve`). Events are ordered by (`at`, `dev`), then by position, so the answer
does not depend on the order the files are read in.

- **Shelf:** the latest `place` or `unsort`. A book no event has placed is not shelved (it shows in Unsorted).
- **Title:** the latest `title`, else the pack's `book.title`.
- **Removed:** the latest of `remove` and `restore` is `remove`.
- **Call number:** `CDS ` + the division + `-` + the sequence in **3 digits, wider past 999**, plus `.k` when k is above 0. Examples: `CDS 210-001`, `CDS 210-999`,
  `CDS 210-1000`, `CDS 210-002.1`.
  - A number is assigned at first shelving and never changes. A move retires the old number (never reused) and assigns a new one. A book in Unsorted has none.
  - A book holds its latest `assign` that no `retire` (same book, division and number) cancels, if that division is its shelf's.
  - **Next free** number in a division: 1 + the highest number ever assigned or retired there, counting every device's log.
  - **Clashes.** Two devices can assign the same number before they have seen each other's log. All assigns ever made for a (division, number), **retired ones included**,
    are ranked by (`at`, `doc`). Rank 0 shows the plain number, rank k shows it with `.k`. Ranks are fixed: if rank 0 moves away (and retires the number), rank 1 still
    shows `.1`. A tie on `at` is settled by `doc`.
  - **Nothing is renumbered and nobody writes anything to resolve a clash.** Resolution is the same pure function everywhere.
  - Caveat: if a device that was offline later syncs an *earlier* assign for a number that is already in use, the ranks shift once when it arrives. That cannot be avoided
    without coordination between devices.
  - Future sub-topics go before the dash (`210.4-001`).
- **Training corrections:** the user `place` events whose `div` differs from the book's `book.suggested.div` (`cache_builder::log::corrections`).
- **Who shelves.** A device appends `place` and `assign` right after it builds a book (`by: auto`; or `unsort` when the classifier is unsure), or at first open of a book that
  arrived unshelved. The build service also shelves, when it publishes, any book its log has never seen.

Example: the phone and the server each built a book while apart, and each took 210-002:

```json
{"v":1,"at":100,"dev":"phone","ev":"place","doc":"p","div":"210","by":"auto"}
{"v":1,"at":101,"dev":"phone","ev":"assign","doc":"p","div":"210","seq":2}
{"v":1,"at":200,"dev":"server","ev":"place","doc":"s","div":"210","by":"auto"}
{"v":1,"at":201,"dev":"server","ev":"assign","doc":"s","div":"210","seq":2}
```

Everywhere, `p` shows `CDS 210-002` and `s` shows `CDS 210-002.1`; the next free number is 3. If `p` then moves to division 320 (`place`, `retire` 210/2,
`assign` 320/1), `s` still shows `CDS 210-002.1`.

## The view

`<library>/.local/docs.json`, format 2. Written atomically (a temporary file in the same folder, flushed, renamed over the name). The same packs and logs always give the
same bytes (no clock, keys in a fixed order, books in `doc_id` order).

```json
{
  "format": 2,
  "built_from": {"packs": 2, "logs": {"builder-r3.jsonl": 388}},
  "docs": {
    "b3f1...": {
      "title": "The Well Water Handbook",
      "source_title": null,
      "shelf": "210",
      "call": {"div": "210", "seq": 1, "suffix": 0, "text": "CDS 210-001"},
      "suggested": {"div": "210", "label": "Water", "score": 0.875, "classifier_version": 3, "source": "classifier", "second_div": "220"},
      "removed": false,
      "compression": {"original_size": 9000, "stored_size": 4000, "level": "smaller_scans", "preset": "balanced",
                      "kept_original": false, "kept_reason": null, "psnr_min": 41.5},
      "ocr": {"engine": "doctr", "version": "1.1.0", "pages_ocrd": 12}
    },
    "c9d2...": {"title": "Stone", "source_title": null, "shelf": null, "call": null, "suggested": null, "removed": false, "compression": null, "ocr": null}
  },
  "retired": {"210": [5]}
}
```

- `built_from.packs` is the number of books (live packs); `built_from.logs` maps each log file read to its size in bytes, so a reader can tell the view is stale.
- `docs` has one entry for each live pack (a book with log events but no pack here is not listed). Every key is always present, `null` when unknown. `shelf` is the division, or `null` for Unsorted.
- `call` is `{div, seq, suffix, text}` or `null`. There is no state field: a clash is a suffix.
- `retired` maps a division to the numbers that were retired in it.
- The view is **never part of a search payload** and never synced. It is made after any change and by `cache-build view --library <dir> [--packs <packs dir>]`.

## Published read-only libraries (the seed log)

`cache-build library` writes the **seed log**, `log/builder-<library_id>.jsonl`, and `.local/docs.json`:

- `place` (by `auto`) then `assign` for every book that has a suggested division (from the pack's `book.suggested`, or `--labels`).
- Numbers go in order of **(title, doc_id)** within each division (plain string order of the title as the library uses it, then of the `doc_id`), starting at 1, so a rebuild gives the same numbers.
- Books with no division (Unsorted) get no `place` or `assign`.
- With `--classifier`, a book no label and no pack placed is sorted from its vectors: a confident one is placed and numbered like the rest; an unsure one gets no event (it stays in Unsorted) and the view keeps the sorter's best guess as `suggested`.
- A title that a `--titles` file replaced is written as a `title` event, after the placements, so the view can be made again from the packs and the log.
- Every event has `at` = `--built-at` (UTC milliseconds or `YYYY-MM-DDTHH:MM:SSZ`; default now). The recon build passes a fixed value, so **the same inputs give byte-identical seed logs and views**.
- Divisions are written in number order; within a division, books in number order, each as `place` then `assign`.

```json
{"v":1,"at":1793491200000,"dev":"builder-recon-library","ev":"place","doc":"b3f1","div":"210","by":"auto"}
{"v":1,"at":1793491200000,"dev":"builder-recon-library","ev":"assign","doc":"b3f1","div":"210","seq":1}
```

## The build service

- After it builds a book: `place` and `assign` (by `auto`), or `unsort` when the classifier was unsure. The pack's `book.suggested` holds the classifier's best guess either way.
- "Place it" and every move (`POST .../books/{doc}/place`): `place` (by `user`), `retire` of the old number, `assign` of the next free one; to Unsorted: `unsort` and `retire`.
- A rename (`PATCH .../books/{doc}`): `title`.
- The view is made again after a placement, a rename and a delete, and at every publish (which also shelves any book the log has never seen and refreshes the call
  numbers the book list shows from all the logs). A filed PDF is named when it is filed or moved (`CDS 210-001  <title>.pdf`), so a number that later gains a `.k` suffix does not rename it.

## Later: compaction

Log growth is fine for 1.1. A later compaction fits this format without breaking it: a sealed snapshot of the resolved state (shelves, titles, removed, the numbers that are
held and the numbers that are retired) written as a new log by one device, with the older logs set aside once every device has seen the snapshot. Readers that
only know `v: 1` events would keep working, because a snapshot is expressed as ordinary `place`, `assign`, `retire`, `title` and `remove` events. Clash suffixes depend on the
whole history of a number, so a snapshot must keep the claims on any number that is still shared (it can drop the claims of numbers nobody shares).
