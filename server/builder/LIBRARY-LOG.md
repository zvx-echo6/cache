# The Bookshelves log, the seed log and the views (pack revision 4)

**Status: agreed with the app orchestrator (2026-11-08); for 1.1.** It replaces the per-library, per-device log of 2026-11-02. Code: the
`cache_shelves` crate (`packages/cache_shelves`: events, writer, resolution, same-book decision, import, view), its core ops
(`cs_shelves_*`, `cache_search.h`), `cache_builder::bookshelves`, `cache-build view --bookshelves` and the Linux build service
(`server/src/libbuild/booklog.rs`, see "The build service" below). The seed log is still written by `cache-build library`
(`cache_builder::log`), and `cache_builder::view` still makes the `.local/docs.json` of a library `cache-build library` writes.

## The rule

**Nothing that syncs ever has two writers.** `cache_sync` does not merge files; when two devices both change one it keeps a conflict copy
beside it. So:

1. **Facts** about a book live in its pack (PACK-FORMAT.md, revision 4, the `book` and `samebook` blocks). A pack is immutable and written once by the device that built the book.
2. **Changes** (which shelf a book is on, its call number, a new title, hiding it, "these two files are one book", where a file sits in a linked folder) are events in a **per-device log of the person's Bookshelves log**. Only the device named in the file writes it. Every device reads all the files and resolves them the same way.
3. The **view** is what a device shows. It is rebuilt from the packs and the logs, is local, and never syncs.

The Bookshelves log is **personal**. It is not inside any library folder, because a library can be given to other people and the shelves are not
given with it. Another person's shelves number on their own.

```
<app support>/bookshelves/
  log/<device_id>.jsonl          events, one file per device of this person (synced among their own devices only)
  .local/view.json               the resolved view (never synced)
  .local/migrated.json           which old library logs were imported (never synced)

<library>/                       a library, as before
  cache-library.json  shard/  documents.tsv  copies.jsonl  SHA256SUMS
  copies.jsonl                   the same facts, one line per book (synced; a library without packs has only this)
  packs/<doc_id>@<version>.cdoc  facts (synced)
  log/builder-<library_id>.jsonl the publisher's seed log (synced, read-only suggestions)
  log/<device_id>.jsonl          old per-device library logs (imported once, then never written)
  .local/docs.json               the local view `cache-build library` writes (never synced; the build service no longer does)
```

`cache_sync` never sends a name that starts with a dot, so `.local/` needs no rule of its own; keep it out of every allow-list. The Bookshelves
log syncs only with linked devices set to **Match** (the same person's device). A newly linked device starts as Off until someone answers the question after linking; links made before that setting existed were moved to Match once.

## The device id

The device id is `cache_sync`'s identity (`cache_sync::identity::load_or_create`: the EndpointId's text, lower-case letters and digits), which
a reinstall replaces. A new id simply starts a new log file. It is used in a file name, so it holds letters, digits, `.`, `_` and `-` only (at
most 64, not starting with a dot). **Cache for Linux** keeps its identity in `<data>/sync`; if the identity cannot be made it logs as
`unsynced`.

## Copies and books

- A **copy** is one PDF, keyed by its content identity: the pack's `book.original_blake3` (64 hex characters), or the pack's `doc_id` for a pack without it (revision 2 and 3). The same file in two libraries is one copy with two locations. The `<library_id>/<doc_id>` of a copy is kept only as a `loc` field (where it is found), never as the key, because library ids are not unique across people or sources.
- A **book** is a group of copies. It has one shelf, one call number, one title and a **reading copy**.
- The **reading copy** is the one the person picked (`prefer`), else the best by the `samebook` order (`cache_shelves::compare_copies`, the order of PACK-FORMAT.md "Which copy is better": text pages, pages, ppi, smaller file, lower key; the copy key stands in for the doc id in the last tie-break; a copy without `samebook` ranks below every copy with it). A `prefer` for a copy that no library holds is ignored.
- Other copies are spares. A spare whose pack title differs shows as "also known as" (`aka`).
- A book's `id` in the view is its smallest copy key. It changes when books merge or split, so an app addresses a book by a copy it holds.

## The copies file

A library does not have to carry its packs. A **downloaded `.cache-library` has none**: it holds `shard/`, `cache-library.json`, `documents.tsv`,
`source-identities.json` and the copies file. `cache-build library` writes `copies.jsonl` at the library root (it is in `SHA256SUMS`, and in the
`.cache-library` archive at its root, beside `documents.tsv`; unpacking leaves it in `shard/`, and the app moves it to the library root as it does `documents.tsv`, though the core also finds it in `shard/`). It has
one line per document, **sorted by `doc_id`**, compact JSON in a fixed key order, so the same inputs give the same bytes. Each line holds everything
`cache_shelves` reads from a pack:

| Key | Meaning |
|---|---|
| `doc_id`, `doc_version` | the document |
| `copy` | the copy key: `original_blake3`, else `doc_id` |
| `original_blake3`? | `book.original_blake3`, when the pack has it |
| `source_blake3`? | the source's BLAKE3 (`source.blake3`) |
| `title` | the pack's title (`book.title`, else the header's); a replaced title is the seed log's `title` event, as before |
| `suggested`? | `{"div","label"}`: the library's suggested division (the pack's `book.suggested`, or the label or sorter result of this build) |
| `author`?, `edition`?, `year`? | the book facts, checked on read as for `facts` events |
| `samebook`? | `{"minhash","mean_vector","text_pages","pages","ppi"?,"source_size","words"?}`; `minhash` is base64 of little-endian u32, `mean_vector` base64 of little-endian f16 (the pack's own encodings); absent for a document with no fingerprint (a ZIM's, an old pack's) |

```json
{"doc_id":"wm","doc_version":2,"copy":"b3f1...","original_blake3":"b3f1...","source_blake3":"9a07...","title":"Wilderness Medicine","suggested":{"div":"610","label":"Medicine"},"author":"A. Writer","year":2018,"samebook":{"minhash":"AQAAAAIAAAA=","mean_vector":"ADwAOA==","text_pages":300,"pages":310,"ppi":150,"source_size":4123456}}
```

- The **copy key** and the **content hash** (`original_blake3`, else `source_blake3`) are computed by one function each in `cache_shelves::library` (`copy_key`,
  `content_hash`). The builder calls them to write the file and the resolver calls them on a pack header or a copies line (it works the key out again from
  `original_blake3` and `doc_id`; the line's `copy` is for readers that do not link the crate), so a library reads the **same keys either way**. A test builds
  a library, reads it through its packs and through its copies file, and compares every field.
- **Reading.** `resolve`, `import` and detection read `<library>/copies.jsonl` when it exists (also `<library>/shard/copies.jsonl`, where unpacking an archive
  leaves it before the app moves it), and open no pack. Without it they read the packs, as before. A line that is not readable is skipped and counted as
  `unreadable`; of several lines for one `doc_id` the highest `doc_version` is used.
- A library whose documents were not built with a fingerprint has lines without `samebook`: it can still match by content hash, and its copies rank below
  those with a fingerprint when the reading copy is chosen.
- The Linux build service keeps the copies file of each library it builds up to date itself (see "The build service"). A library changed by other means
  (documents added by a linked folder) has a stale or missing copies file until it is rebuilt; with no copies file and no packs it resolves to nothing.

## Events

A log is JSON Lines: one event per line, UTF-8, `\n` after every line, never edited, only appended. Every event has:

| Key | Meaning |
|---|---|
| `v` | `1`. A reader skips an event with another `v`. |
| `at` | UTC milliseconds since 1970. |
| `dev` | The writing device's id (the same as the file name). |
| `ev` | The event name. A reader skips an event it does not know; unknown extra keys are ignored. |
| `copy` | The copy key the event is about (every event except `folder`). |
| `loc` | Optional: `<library_id>/<doc_id>`, where the copy was found. For reading and lookup; never the key. |

| Event | Keys | Meaning |
|---|---|---|
| `place` | `copy`, `div`, `by` | The book that holds `copy` goes on the shelf of division `div` (three digits). `by` is `auto` or `user`. |
| `unsort` | `copy`, `by` | The book goes to Unsorted. |
| `assign` | `copy`, `div`, `seq` | `copy` takes call number `seq` in `div`. |
| `retire` | `copy`, `div`, `seq` | `copy` gives up number `seq` in `div`. A retired number is never used again. |
| `title` | `copy`, `title` | A new title for the book. |
| `remove` | `copy` | **Only hides the book** on every device of the person. It never deletes files. |
| `restore` | `copy` | Shows a hidden book again. |
| `same` | `copy`, `with`, `by`, `how`, `score`? | The two copies are one book. `by` is `auto` (detection) or `user`; `how` is `blake3`, `text` or `user`; `score` is the detector's number, recorded for checking. |
| `notsame` | `copy`, `with`, `by` | The two copies are different books ("Not the same book"). |
| `prefer` | `copy` | Use this copy for reading its book. |
| `facts` | `copy`, `author`?, `edition`?, `year`? | Author, edition and year for the book that holds `copy`. Every field is optional; an absent field means "no value from this source". See "Book facts". |
| `folder`, `locate`, `unlocate` | as below | Linked-folder locations. |

```json
{"v":1,"at":1793600000000,"dev":"phone-7","ev":"place","copy":"<blake3 A>","div":"210","by":"auto","loc":"recon/b3f1"}
{"v":1,"at":1793600000001,"dev":"phone-7","ev":"assign","copy":"<blake3 A>","div":"210","seq":1}
{"v":1,"at":1793600000002,"dev":"phone-7","ev":"same","copy":"<blake3 B>","with":"<blake3 A>","by":"auto","how":"text","score":0.921875}
{"v":1,"at":1793600100000,"dev":"phone-7","ev":"notsame","copy":"<blake3 B>","with":"<blake3 A>","by":"user"}
{"v":1,"at":1793600200000,"dev":"phone-7","ev":"prefer","copy":"<blake3 B>"}
{"v":1,"at":1793600300000,"dev":"phone-7","ev":"title","copy":"<blake3 A>","title":"Wilderness Medicine Handbook, 7th ed"}
{"v":1,"at":1793600400000,"dev":"phone-7","ev":"remove","copy":"<blake3 A>"}
```

A `same` or `notsame` whose `copy` equals its `with` is not an event and is skipped. A move is three events in this order: `place` (new
division), `retire` (old number), `assign` (new number), all against the book's numbered copy. Going to Unsorted is `unsort` then `retire`.

### Book facts (`facts`)

```json
{"v":1,"at":1793600000000,"dev":"phone-7","ev":"facts","copy":"<blake3 A>","loc":"recon/b3f1","author":"A. Writer","edition":"7th edition","year":2018}
```

- Checks (the same as the titles file): `author` is 1 to 200 characters after trimming, `edition` 1 to 60 after trimming, `year` a JSON integer from 1400 to 2100. A field that fails its check is **dropped on its own** (a reader keeps the valid fields); an event left with no valid field is skipped, and the writer refuses it. Values are stored trimmed.
- Three sources, per field: the person's own `facts` events in the Bookshelves log, then the publisher's `facts` in the library's seed log, then the pack's `book.author`, `book.edition`, `book.year`. Within the person's events the latest event that has the field wins, over all copies of the book; within the seed log the same, per field. The seed and pack values are the reading copy's.
- The same event is written to the seed log by `cache-build library` (below), with `doc` as the seed log's other events have.

### Linked-folder events

The linked-folder events are `v: 1` events with `copy` where the old library log had `doc`. Older readers skip them as unknown events.

```json
{"v":1,"at":1793600600000,"dev":"linux-a","ev":"folder","folder_id":"books","label":"Books","mode":"keep"}
{"v":1,"at":1793600600001,"dev":"linux-a","ev":"locate","copy":"<blake3 A>","folder_id":"books","relpath":"Firearms/Gunsmithing.pdf","version":2,"source_blake3":"<64 hex characters>"}
{"v":1,"at":1793600600002,"dev":"linux-a","ev":"unlocate","copy":"<blake3 A>","folder_id":"books","relpath":"Old Name.pdf"}
```

- `folder` has no `copy`; it carries `folder_id`, display `label`, and `mode` (`keep`, `cds`, `both`). Folder state is keyed by `(dev, folder_id)` and the latest event by (`at`, `dev`, position) wins.
- `locate` and `unlocate` require a nonempty normalized relative `relpath` using `/`. Absolute roots, drive/ADS syntax, backslashes, empty path components, `.` and `..` components are rejected on read and on append. The absolute folder path, URI or bookmark stays in that device's `.local/` and is never serialized.
- `version` and `source_blake3` are optional on `locate`; the hash, when supplied, is 64 hexadecimal characters. They anchor a source version without changing a copy's identity.
- A location is keyed by `(dev, folder_id, copy, relpath)`. The latest locate/unlocate for that key wins; a move is unlocate-old plus locate-new. Two folders give two locations for one copy. Results are ordered by device, folder id and relative path.
- Availability is device-local and is not synchronized or inferred from these events. Because the log is shared only with the person's own devices, locations carry no privacy notice.

### Writing

- **Atomic lines.** An append builds all its lines first and writes them in one `write` to a file opened for append, then flushes to disk (`fsync`). An event the log does not take (a bad linked-folder path, a copy linked with itself, an empty division) fails the whole append and writes nothing.
- **One writer per file.** A writer refuses an event whose `dev` is not its own.
- **Order.** A device never writes an event with an `at` earlier than its own last one: a clock set back is held at the last `at` (the writer does this, from the file). Two events of one device with the same `at` count in file order.
- **A torn last line.** A crash can leave the last line cut off. A reader skips any line that is not an event (and counts it). The next append starts with a line break when the file does not end in one, so the new event is never glued to the torn one.

## Detection is logged, not recomputed

When a device first sees a new copy (built here, arrived in a library, or found in a linked folder) it runs same-book detection **once**
against the copies it can see and writes `same ... by:auto` for each match. Resolution reads only events, so two devices never disagree
because of float rounding, different model builds, or one of them not holding a library.

The decision is `cache_shelves::same::detect` (core op `shelvesDetect`; one pair is `same::compare`). It is the Linux build service's rule, moved into the shared crate
(`server/src/libbuild/same.rs` now re-exports it), applied to the facts the builder already writes in the pack header:

| Fact | From the pack | Use |
|---|---|---|
| content hash | `book.original_blake3`, else `source.blake3` | the same hash under another key: a match, `how: blake3`, `score: 1.0` |
| text fingerprint | `samebook.minhash` (128 numbers) | estimated Jaccard of the 5-word shingles (`fingerprint.rs`) |
| meaning | `samebook.mean_vector` (unit length, f16) | cosine |
| length | `words` (not in the pack header, so usually absent) | the shorter text must be at least `min_length_ratio` of the longer's; skipped when either count is unknown (the Jaccard already bounds it) |

The facts come from the pack header or, for a library with no packs, from the copies file (above); they are the same either way.

A text match is Jaccard >= 0.85 **and** cosine >= 0.95 (`same_jaccard`, `same_cosine`; `min_length_ratio` 0.8; `edition_jaccard` 0.5). It is
logged as `how: text`, `score` = the Jaccard. A new edition (Jaccard between 0.5 and 0.85 with the same meaning) is **not** a match: the
person decides, and a person's choice is a `same` with `by: user`. A copy too short to fingerprint matches nothing by text.

### Detecting a whole library at once (the batch form)

A library arriving can hold thousands of copies, so `shelvesDetect` has a batch form (the request has `libraries`) that reads the features itself:

```json
{"libraries":[{"library_id":"recon","dir":"/data/recon"}],"copies":["<key>"],"known":["<key>"],"tuning":{}}
```

- `libraries`: where the copies are (each library's `copies.jsonl`, else its packs). All their copies are the **visible** copies; a copy in two libraries is one.
- `copies` (optional, default all): the copy keys to check. `known` (optional): copy keys already detected; a pair with both copies in `known` is skipped.
- The answer is `[{"copy","with","how","score"}]`: every match between a checked copy and any other visible copy, checked copies included. Each unordered
  pair appears **once**, `copy` the greater key and `with` the lesser, sorted by (`copy`, `with`). It is exactly the union of the single-copy calls (same
  rule: `same::compare`), as one list. Copies with the same content hash are matched first (`how: blake3`, no comparison); the text rule then compares
  the fingerprinted copies pairwise (about 10,000 copies is fine: a pair under `edition_jaccard` is dropped before the 1024-number cosine).
- The caller writes `same ... by:auto` for each pair (`shelvesAppend`). The single-copy form is unchanged.

## Resolution

The same on every device, a pure function of all the events and the libraries' facts (`cache_shelves::resolve`). Events are ordered by
(`at`, `dev`), then by position, so the answer does not depend on the order the files are read in. A book appears in the view only if one of its
copies is in a library given to the resolver; events about other copies still count for numbers.

1. **Groups.** For each pair of copies, the latest of its `same` and `notsame` events wins (the pair is unordered). A `by: user` event for a pair always outranks a `by: auto` one for the same pair, however late the auto event is. Books are the connected groups of live `same` links. A `notsame` between two copies that are still linked through a third copy cuts the **weakest link on the path** (lowest `score`, a missing score counting as 1.0, then `auto` before `user`, then pair order) and repeats until the two are apart, so "Not the same book" always separates the two copies the person named. Cuts are made in pair order, so every device cuts the same links.
2. **Call number.** Each copy keeps the `assign` events written for it, as before: it holds its latest `assign` that no `retire` of the same copy, division and number cancels. The **book's number is the earliest held assign among its copies** (by `at`, then copy key) **in the book's shelf division**. The other copies' numbers are not retired: they are held quietly, so after a split each copy gets its old number back and no number is ever reused. A call number is `CDS ` + the division + `-` + the sequence in **3 digits, wider past 999**, plus `.k` when k is above 0 (`CDS 210-001`, `CDS 210-1000`, `CDS 210-002.1`).
   - **Next free** number in a division: 1 + the highest number ever assigned or retired there, counting every device's log and every copy, whether or not any library holds it.
   - **Clashes.** Two devices can assign the same number before they have seen each other's log. All assigns ever made for a (division, number), **retired ones included**, are ranked by (`at`, `copy`) of each copy's first claim; a copy that claimed the same number twice is one claim. Rank 0 shows the plain number, rank k shows it with `.k`. Ranks are fixed: if rank 0 moves away (and retires the number), rank 1 still shows `.1`. Nothing is renumbered and nobody writes anything to resolve a clash.
   - Caveat: if a device that was offline later syncs an *earlier* assign for a number already in use, the ranks shift once when it arrives. That cannot be avoided without coordination.
3. **Shelf.** The latest `place` or `unsort` over all copies of the book. A book no event has placed is not shelved (`shelved: false`; it shows in Unsorted).
4. **Title.** The latest `title` over the book's copies, else the publisher's seed-log `title` for the reading copy, else the reading copy's pack title. Other copies' pack titles that differ from the shown title are listed as `aka`.
5. **Removed.** The latest `remove` or `restore` over the book's copies. Hiding is per person; a publisher removes a book by publishing a new library version without it.
6. **Facts.** Per field (`author`, `edition`, `year`): the person's own latest `facts` over the book's copies, else the seed log's `facts` for the reading copy, else the reading copy's pack `book` block, else `null`.
7. **Suggestion.** For the reading copy (then the others): the seed log's `place` division, else the pack's `book.suggested` (revision 3's `division` is mapped). Shown until the person shelves the book.

### Worked example: a clash

The phone and the server each shelved a copy while apart, and each took 210-002:

```json
{"v":1,"at":100,"dev":"phone","ev":"place","copy":"p","div":"210","by":"auto"}
{"v":1,"at":101,"dev":"phone","ev":"assign","copy":"p","div":"210","seq":2}
{"v":1,"at":200,"dev":"server","ev":"place","copy":"s","div":"210","by":"auto"}
{"v":1,"at":201,"dev":"server","ev":"assign","copy":"s","div":"210","seq":2}
```

Everywhere, `p` shows `CDS 210-002` and `s` shows `CDS 210-002.1`; the next free number is 3. If `p` then moves to division 320 (`place`, `retire` 210/2,
`assign` 320/1), `s` still shows `CDS 210-002.1`. On a tie on `at` the copy key decides, whatever the devices are called.

### Worked example: a merge

Copy `A` is shelved at 210-001 and copy `B` at 210-002 (they were two files of one book). Detection finds them:

```json
{"v":1,"at":1,"dev":"d","ev":"place","copy":"A","div":"210","by":"auto"}
{"v":1,"at":2,"dev":"d","ev":"assign","copy":"A","div":"210","seq":1}
{"v":1,"at":3,"dev":"d","ev":"place","copy":"B","div":"210","by":"auto"}
{"v":1,"at":4,"dev":"d","ev":"assign","copy":"B","div":"210","seq":2}
{"v":1,"at":5,"dev":"d","ev":"same","copy":"B","with":"A","by":"auto","how":"text","score":0.92}
```

One book, id `A`, call `CDS 210-001` (the earliest of the two). `B`'s `210-002` is held: it is not shown, it is not retired, and the next free number is
still 3. The reading copy is the better of the two files by the `samebook` order; `B`'s pack title, if it differs, is in `aka`.

### Worked example: a split

The person says "Not the same book":

```json
{"v":1,"at":6,"dev":"d","ev":"notsame","copy":"B","with":"A","by":"user"}
```

The user's `notsame` outranks the detector's `same` for this pair, now and if the detector ever writes `same` again. Two books: `A` is `CDS 210-001` and `B` is `CDS 210-002`
again. No number was written or lost. If the person changes their mind, `{"ev":"same","copy":"A","with":"B","by":"user","how":"user"}` joins them (a later user event for the pair wins).

If `A`, `B` and `C` are linked `A-B` (0.90) and `B-C` (0.95), a user `notsame` between `A` and `C` cuts `A-B`, the weakest link: `A` goes alone, `B` and `C` stay together.

## Arriving libraries and existing logs

- **A library arrives** (downloaded, given, or built): for each copy, run detection and write `same` where it matches. Copies matching nothing are new books: `place` in the suggested division (the seed log's `place`, else `book.suggested`, else Unsorted) and `assign` the next free number, in (title, copy) order, so two devices that shelve the same library offline make the same choices except for clashes.
- **Existing per-device library logs** (only test devices and the build service have any; 1.1 has not shipped): on first run each device imports its OWN events from every library's `log/<own id>.jsonl` into its Bookshelves log (`cache_shelves::import`, core op `shelvesImport`). Each `doc` is mapped to the copy key through that library's copies file, else its live packs; the event keeps its `at` and gets `loc` = `<library_id>/<doc_id>`; an `assign` or `retire` about a `doc` with no pack in that library (a deleted book) is written as a `retire` of that division and number, with `copy` = the `doc_id` (the copy key of a pack with no `original_blake3`), the `loc` and the original `at`, and is counted as `reserved`: no book appears for it, but the number counts toward next free and is never given out again; any other event about such a `doc` is not imported and is counted as `unmapped`. Events are appended oldest first **with their original `at`** (the import does not raise them to the device's last `at`, so an old `place` never overrides a newer move), and an event already present in the device's Bookshelves log is not written again, so a crash between the append and the record cannot duplicate events. A file with no `unmapped` events is recorded in `.local/migrated.json`; a file with unmapped events is not recorded, so a later import maps them once their pack is here:

  ```json
  {"format":1,"files":{"recon/phone-7.jsonl":{"size":4120,"events":31,"unmapped":0,"reserved":2}}}
  ```

  A file recorded there is not imported again; one that is not recorded can be imported again safely. Other devices' library logs are ignored (they import their own), and so is the seed log. After the import, library logs are not written again.

## The Bookshelves view

`<app support>/bookshelves/.local/view.json`, format 1 (core op `shelvesResolve`, which writes the file and also returns the view; `cache-build view --bookshelves`). Written atomically (a temporary
file in the same folder, flushed, renamed over the name). The same events and libraries always give the same bytes: no clock, keys in a fixed order,
books in `id` order, and the same bytes whatever order the log files, or the libraries, are given in.

```json
{
  "format": 1,
  "built_from": {"libraries": {"recon": {"packs": 2, "unreadable": 0}}, "logs": {"phone-7.jsonl": 812}},
  "books": {
    "A": {
      "title": "Wilderness Medicine Handbook",
      "title_from": "seed",
      "aka": ["Wilderness Medicine"],
      "reading": "B",
      "copies": [
        {"copy": "A", "locs": ["recon/wm"], "available": true, "title": "Wilderness Medicine",
         "own_call": {"div": "210", "seq": 1, "suffix": 0, "text": "CDS 210-001"}, "locations": []},
        {"copy": "B", "locs": ["recon/wm2"], "available": true, "title": "Wilderness Medicine, 7th ed",
         "own_call": {"div": "210", "seq": 2, "suffix": 0, "text": "CDS 210-002"},
         "locations": [{"dev": "linux-a", "folder_id": "books", "relpath": "Medicine/wm.pdf", "version": null, "source_blake3": null}]}
      ],
      "shelf": "210", "shelved": true, "by": "auto",
      "call": {"div": "210", "seq": 1, "suffix": 0, "text": "CDS 210-001"},
      "removed": false,
      "author": "A. Writer", "edition": "7th edition", "year": 2018,
      "suggested": {"div": "610", "label": "Medicine", "from": "pack"}
    }
  },
  "retired": {"210": [5]},
  "next": {"210": 6},
  "folders": [{"dev": "linux-a", "folder_id": "books", "label": "Books", "mode": "keep"}]
}
```

- `built_from.libraries` has the number of live packs read and the number of unreadable ones; `built_from.logs` maps each log file read to its size in bytes, so a reader can tell the view is stale.
- `books` has one entry for each book with a copy in a library given to the resolver. Every key is always present, `null` when unknown.
- `id` is the book's smallest copy key. `reading` is the copy to read. `copies` is every copy of the book in key order, including ones no library holds (`available: false`, `locs: []`, `title: null`), with the copy's own held number (`own_call`) and its linked-folder locations.
- `title_from` is `log`, `seed` or `pack`. `shelf` is the division, or `null` for Unsorted; `shelved` says an event placed or unsorted the book; `by` is who made the latest placement.
- `author`, `edition` and `year` are resolved per field as in "Facts" above, `null` when unknown.
- `call` is `{div, seq, suffix, text}` or `null`. There is no state field: a clash is a suffix.
- `suggested` is `{div, label, from}` with `from` `seed` or `pack` (`label` is `null` from a seed), or `null`.
- `retired` maps a division to the numbers retired in it; `next` maps a division to the next free number; `folders` is the latest state of each device's linked folders.
- The view is **never part of a search payload** and never synced.

## Published read-only libraries (the seed log)

`cache-build library` writes the **seed log**, `log/builder-<library_id>.jsonl`, and `.local/docs.json`. The seed log keeps its format (`doc`, the
old events) and is unchanged by the Bookshelves log, so published libraries need no rebuild. A reader uses it only as **suggestions and defaults**:
its `place` gives the suggested division, its `title` gives the publisher's title (the default the receiver starts from, below their own `title`
events), and its `assign` numbers are **never** call numbers and never count towards the next free number.

- `place` (by `auto`) then `assign` for every book that has a suggested division (from the pack's `book.suggested`, or `--labels`).
- Numbers go in order of **(title, doc_id)** within each division (plain string order of the title as the library uses it, then of the `doc_id`), starting at 1, so a rebuild gives the same numbers.
- Books with no division (Unsorted) get no `place` or `assign`.
- With `--classifier`, a book no label and no pack placed is sorted from its vectors: a confident one is placed and numbered like the rest; an unsure one gets no event (it stays in Unsorted) and the view keeps the sorter's best guess as `suggested`.
- A title that a `--titles` file replaced is written as a `title` event, after the placements, so the view can be made again from the packs and the log.
- When `--titles` lines carry `author`, `edition` or `year` (checked as above, invalid fields dropped), a `facts` event follows for each such book, after all the title events, in `doc_id` order. This is the one addition to the seed log; older readers skip the unknown event. The event has `doc`, the book's `copy` (its `original_blake3`) and `loc` (`<library_id>/<doc_id>`) for readability, and only the fields the titles file gave:

  ```json
  {"v":1,"at":1793491200000,"dev":"builder-recon-library","ev":"facts","doc":"b3f1","copy":"b3f1","loc":"recon-library/b3f1","author":"A. Writer","edition":"7th edition","year":2018}
  ```
- Every event has `at` = `--built-at` (UTC milliseconds or `YYYY-MM-DDTHH:MM:SSZ`; default now). The recon build passes a fixed value, so **the same inputs give byte-identical seed logs and views**.
- Divisions are written in number order; within a division, books in number order, each as `place` then `assign`.

```json
{"v":1,"at":1793491200000,"dev":"builder-recon-library","ev":"place","doc":"b3f1","div":"210","by":"auto"}
{"v":1,"at":1793491200000,"dev":"builder-recon-library","ev":"assign","doc":"b3f1","div":"210","seq":1}
```

### The library's local view (`.local/docs.json`, format 2)

`<library>/.local/docs.json` is the per-library view `cache-build library` writes, made from the packs and the library's own logs
(`cache_builder::view`, `cache-build view --library <dir> [--packs <packs dir>]`). It is not part of the Bookshelves log: it keeps the old `doc`
keys. The Linux build service no longer writes it (an old one in a built library is left alone and goes stale); its view is the Bookshelves view.

## The build service

The Linux build service (`server/src/libbuild`, `booklog.rs`) is one device of the person, with its `cache_sync` identity in `<data>/sync`. Its
Bookshelves folder is `<data>/bookshelves/` (`log/<device_id>.jsonl`, `.local/view.json`, `.local/migrated.json`). It resolves against every
library folder in `<data>/app/docs/libraries`: the ones it builds and the ones that were installed, whose seed logs count only as suggestions.

- **Start-up.** It makes each built library's `copies.jsonl` again from its live packs (the format above; the root of the library), then runs the
  import above once for its own `log/<device_id>.jsonl` of every library. It never writes a library log after that.
- **A new book.** The pack's line goes into `copies.jsonl` (other versions of the same `doc_id` go). Same-book detection runs once for the new copy,
  in the batch form, against every copy the service can see, with the service's tuning (`build/tuning.json`); each match whose pair has no `same` or
  `notsame` yet is written as `same` by `auto` with its `how` and `score`. A copy that then belongs to a book already on a shelf (also the same file in
  another library, which is the same copy) takes that book's shelf and number and is not shelved again. Any other copy is shelved: `place` (by `auto`)
  in the classifier's division and `assign` of the next free number, or `unsort` (by `auto`) when the classifier was unsure.
- **The service's own same-book handling.** A better file that replaces a book (the next `doc_version`) writes `same` from the new copy to the copy it
  replaces (by `auto`, `how` `text`; by `user`, `how` `user` when the person chose "Replace the older one"), so the book keeps its shelf and number. A
  possible new edition the person chose to keep beside the other writes `notsame` by `user`. A worse file or an exact copy is not kept and writes
  nothing.
- **Changes.** "Place it" and every move write `place` (by `user`), `retire` of the old number and `assign` of the next free one, the last two against
  the copy that holds the book's number; Unsorted writes `unsort` and `retire`. A rename writes `title` and the new line of `copies.jsonl`; a delete
  takes the book's line out of `copies.jsonl` (its events stay: the shelves are the person's).
- **Publishing** makes `copies.jsonl` again from the packs, shelves books no event has shelved, refreshes the call numbers it keeps with each book
  (`call_text` in `build/libs/<id>.json`, which file names and lists use), and writes the view. The view is also written after a placement, a rename
  and a delete.
- The service writes no `SHA256SUMS` and no `.cache-library` archive for the libraries it builds, so `copies.jsonl` is in neither there.
- Call numbers count across the whole Bookshelves, so two built libraries that each had `210-001` in their own logs show the later claim as
  `210-001.1` after the import.

## Later: compaction

Log growth is fine for 1.1. A later compaction fits this format without breaking it: a sealed snapshot of the resolved state (shelves, titles,
removed, the groups as `same` events, the numbers that are held and the numbers that are retired) written as a new log by one device, with the older logs
set aside once every device has seen the snapshot. Readers that only know `v: 1` events keep working, because a snapshot is expressed as ordinary
events. Clash suffixes depend on the whole history of a number, so a snapshot must keep the claims on any number that is still shared.
