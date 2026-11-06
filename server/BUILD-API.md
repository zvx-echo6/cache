# Build API (library builder service)

For the browser UI task. Everything needs a signed-in session. Replies are `{"ok":true,"result":...}` or
`{"ok":false,"error":{"code","message"}}` (the same envelope as `/api/library/...`). Nothing here is visible to the model: the
payload fields of built libraries are exactly the ones in `server/builder/PACK-FORMAT.md` (title, text, page, source, link, doc_id,
doc_version, plus the unmapped extras).

Wording: the replies never say "server" or "job". Error messages are plain sentences meant for people.

## What it does

A built library is a normal library under `<data>/app/docs/libraries/<library_id>/` (`shard/`, `cache-library.json`, and
`packs/` with one `.cdoc` per book), so the core and the keyword-index job open it like any other. The original PDF of every book
is kept in `<data>/app/docs/sources/<library_id>/<class number and name>/<division number and name>/<call number>  <clean title>.pdf`
(`Unsorted/` for a book not placed); see "Filing by subject" below. Books built before filing existed had their PDF flat at
`sources/<library_id>/<doc_id>.pdf`; at start-up those files move into the tree (to `Unsorted/`) and are classified when the queue is idle.

Books are built one at a time. A new library's books become searchable when the library is *published* (its search data is swapped
into the folder the core reads and the core is told). That happens when the library has no more books waiting, when the queue is
paused, or at most every 5 minutes while books keep coming. `dirty` in the library list means "built books not yet searchable".
The keyword index is rebuilt by the helper after each publish; until it ends, search works by meaning only (the core's source
status says it is being indexed).

Each PDF is read (MuPDF) in a child process: the server runs itself as the hidden `cache extract-pdf`, with a time limit
(2 minutes plus 15 seconds per MB, at most an hour) and, on Linux, an address-space limit (2 GiB plus 64 times the file size, at
most 8 GiB). A damaged PDF that crashes MuPDF, runs out of time or memory fails its own book with "Cache couldn't read this PDF; it
may be damaged." (a drop-folder file goes to `failed/` with that in its `.why.txt`) and the service carries on. Before a book is
started, `attempts` in `queue.json` is raised and saved; a book still marked mid-attempt when the service starts means the service
died on it, and one that did so twice is failed ("Cache stopped unexpectedly twice...") rather than tried again. Retry clears the count.
`cache-build pdf` reads each PDF the same way (`--in-process` to read in the same process, for debugging).

Search inside a library: nothing new. `POST /api/core {"op":"search","args":{...,"sources":["<library_id>"]}}` already takes a
list of source ids; a built library's source id is its `library_id` (the id in `cache-library.json`).

## Libraries

| Call | Body | Result |
|---|---|---|
| `GET /api/build/libraries` | | `[{id,title,books,passages,pages,created_at,published,dirty,waiting,building,publish_error}]` |
| `POST /api/build/libraries` | `{"title"}` | the new library; 409 `name_taken` ("You already have a library called "X". Choose another name, or add to it.") |
| `PATCH /api/build/libraries/{id}` | `{"title"}` | the library; 404, 409 `name_taken` |
| `DELETE /api/build/libraries/{id}` | | `{removed:true,id}`; deletes books, packs, PDF copies and search data. 409 `busy` while a book of it is being built. Confirm in the UI. |
| `GET /api/build/libraries/{id}/books` | query `division=<number>\|unsorted`, `class=<number>`, `sort=title\|call` | `[{id,doc_version,title,pages,passages,ocr_pages,partial,file_name,size,added_at,status, text_pages,year,ppi, class,class_name,division,division_name,call_number,unsorted,suggestions,classifier_version,unsure_reason,placed_by_hand,moved_from,filed_in,compression}]`, by title (default) or, with `sort=call`, Unsorted first and then by call number; `status` is `ready` or `replacing`; `partial` is e.g. `"partial: 2 pages need OCR"` or null |
| `PATCH /api/build/libraries/{id}/books/{doc}` | `{"title"}` | `{id,title}`. Nothing is embedded again. The call number does not change; the filed PDF takes the new title in its name. |
| `GET /api/build/libraries/{id}/books/{doc}/suggestions` | | "Place it": `{id,unsorted,classifier_version,suggestions:[{division,name,class,score}],unsure_reason}`: the sorter's top 3 divisions for the book as stored when it was sorted, best first (`score` is the probability; the list is empty for a book that has not been sorted, e.g. with no model file). 404. |
| `POST /api/build/libraries/{id}/books/{doc}/place` | `{"division": "530"}` (`"unsorted"` or null puts it back) | the book (as listed). The placement is added to this device's library log (see "Filing by subject"). The device copy and the copy in the drop folder's `complete/` move, the call number takes the new division, `placed_by_hand` is true and `moved_from` names where it was ("Unsorted" or "530 Water treatment"). 400 `invalid` for a division that does not exist or is unassigned; 404. |
| `DELETE /api/build/libraries/{id}/books/{doc}` | | `{removed:true,id}`. The person's own PDF is not touched. |
| `POST /api/build/libraries/{id}/books/{doc}/replace?name=<file name>` | the PDF, streamed, `Content-Length` required | the queue item (`replace` set). The old book stays searchable until the new one is published; `doc_version` + 1. |

`id` of a book is its `doc_id`.

## Adding PDFs

`POST /api/build/upload?library_id=<id>&name=<file name>` with the PDF as the body (streamed to disk, any size, `Content-Length`
required). Result: the queue item. Errors: 404 (no such library), 400 `invalid_name`, 400 `not_pdf`, 411, 507 `no_space`
("Not enough space on this device..."). Optional: `&compression=off|lossless|smaller_scans` and `&preset=high|balanced|smallest`
(see "Compression" below; 400 `invalid` for anything else). Upload one request per file. Building starts at once when the search model is there, and
waits (item stays `queued`, the queue says `blocked`) while it is not, so PDFs may be added during the model download.

## Compression

Optional, per book, chosen before the book is stored. The app keeps its own default (a device setting, not synced) and sends the choice
with each upload; a drop-folder file has nobody to ask, so the drop folder has its own setting (`PUT /api/build/drop`, `compression`).
A file with no choice is stored as it arrived (`off`).

| level | what it does |
|---|---|
| `off` | the file is stored as it is |
| `lossless` | MuPDF rewrites the file: unused and duplicate objects removed, every stream deflated (at the best level), objects packed into object streams. Pages must render pixel-identical. |
| `smaller_scans` + `preset` | `lossless`, after the page pictures are recompressed (JPEG) and downsampled. Text, fonts, vector drawings, one-bit pictures and pictures with masks are not touched. `preset` is `high`, `balanced` (the default) or `smallest`. |

Presets: `high` JPEG quality 85, pictures drawn finer than 360 pixels per inch go down to 300; `balanced` quality 70, above 240 down to 200;
`smallest` quality 50, above 180 down to 150. The resolution is measured from where the page really draws the picture.

Safety, for every file: five pages spread through the book are drawn before and after at 100 dpi and the lowest PSNR is kept
(`psnr_min`; 100 means pixel-identical). `lossless` must be identical. A `smaller_scans` result must stay at or above its floor
(`high` 30 dB, `balanced` 26 dB, `smallest` 24 dB); if a page falls below it, or the pictures did not get smaller, the book is stored
with the `lossless` result instead (pictures untouched) and `kept_reason` says why. If the result is not at least 2% smaller than the
original, or the file is encrypted, signed or damaged, the original is kept. The result is never larger.

Order: the file is compressed first, then hashed (BLAKE3) and stored, so the book's `blake3`, the pack's source hash and the device
copy in `sources/` all refer to the stored file. The text is read from the same stored file, so passages and page numbers are those of what
is kept. The hash of the file as it arrived is kept too (`original_blake3`), so the same upload again is still found as an exact copy.
(A drop-folder file in `complete/` stays the person's own file, not the compressed one.) The compression runs in the same crash-proof
child as reading, with the same time and memory limits; a PDF that crashes it fails only its own book.

What happened is on the book (`compression` in the book list, and on the queue item as the choice asked for):
`{"original_size", "stored_size", "level", "preset", "kept_original", "kept_reason", "psnr_min"}`. `level` and `preset` are what was asked
for; `kept_original` is true when the stored file is the original; `kept_reason` says why (also set when `smaller_scans` fell back to
`lossless`); `psnr_min` is null when no check ran. `cache-build pdf <in.pdf> --out <dir> --compress off|lossless|smaller_scans[:preset]`
does the same from the command line and prints the result.

## Queue

`GET /api/build/queue`:

```
{ "paused": false,
  "blocked": null | "waiting for the search model",
  "counts": {total, waiting, working, done, skipped, failed, ocr_needed},
  "eta": {"low_seconds": 32400, "high_seconds": 46800},   // both null when unknown or paused
  "pieces_per_second": 1.4 | null,
  "items": [ {id, library_id, file_name, title, state, size,
              progress: {pages, pieces, pieces_total, ocr_pages},
              error, note, replace, compression, doc_id, duplicate_of, drop, position, created_at, started_at, finished_at,
              result, division, call_number, decision} ] }
```

`counts` also has `needs_decision`. `result` is the sentence the drop folder table shows: "Filed in 530 Water treatment" / "Filed in Unsorted",
"Exact copy of X", "Already have a better copy", "Replaced: the new copy has 312 text pages vs 298" (or the other deciding reason).
`division` and `call_number` say where a built book was filed.

`state`: `queued` (Waiting), `reading` (Reading the PDF), `building` (Building passages · `pieces` of `pieces_total`),
`done`, `skipped_duplicate` (same content already in this library; `duplicate_of` is that book's title), `failed` (`error` is the
sentence to show), `needs_decision` (possibly a new edition of a book already in the library; see below), `ocr_needed` (no text layer at all; `error` says so; Retry works once OCR exists). `note` on a done book is
`"partial: N pages need OCR"`. `position` is the place among the waiting books. `drop` is true for files from the drop folder.
The ETA is a range from the pieces per second seen since the service started; show it as an estimate. Items are in queue order;
finished ones stay (up to 1000) so "x of 214 books done" can be counted: `counts.done + skipped + failed + ocr_needed` over
`counts.total`.

| Call | Result |
|---|---|
| `POST /api/build/queue/pause` | the queue. The book being built is finished, then building holds. Remembered across restarts. |
| `POST /api/build/queue/resume` | the queue |
| `POST /api/build/queue/stop` | the queue plus `removed` (the waiting books taken off the list). The book being built finishes. Files in the drop folder's `ingest/` would be queued again at the next check, so the Stop dialog's "Also turn off the drop folder" matters. |
| `POST /api/build/queue/{id}/decide` | `{"action": "keep_both"\|"replace_older"}` for a `needs_decision` book (409 `not_waiting` otherwise). `keep_both` queues it to be added as its own book (it takes the next call number in its division). `replace_older` rebuilds the older book from this file (`doc_version` + 1, same call number and place) and puts it at the front of the queue, next after the book being worked on. The queue. |
| `POST /api/build/queue/{id}/retry` | the queue. For `failed` / `ocr_needed` only (409 `not_failed` otherwise). The book goes to the end; a drop-folder file goes back to `ingest/`. |
| `DELETE /api/build/queue/{id}` | the queue. Dismiss a finished item, or cancel a waiting one; 409 `busy` while it is being built. |

A restart: a book that was being built starts again from scratch; the rest of the queue and the paused flag are kept.

## Drop folder

One device-wide folder, three subfolders made by Cache: `ingest/` (the queue), `complete/`, `failed/`. A file in `ingest/` is
taken once its size and time have not changed for 30 seconds. The folder is looked at every 2 minutes (and again 31 seconds after
a new file shows up), and on Check now. (No file-watching crate is in the lockfile, so there is no inotify.)

- PDF: queued for the chosen library. A built book (or a better copy that replaced a book) is filed in `complete/<class number and name>/<division number and name>/<call number>  <clean title>.pdf`, or in `complete/Unsorted/`; a copy Cache does not keep (an exact copy of a book, or a worse copy of one it has) goes to Removed with its result; `failed/` + `<name>.why.txt` when it fails or has no text layer. A possible new edition stays in `ingest/` (state `needs_decision`) until the person chooses.
- `.zim`: installed like a download, then `complete/ZIM files/`.
- `.cache-library`, or a `.gz` that starts with the gzip magic: lands in `incoming/` like an uploaded library package (the browser's install flow installs it), then `complete/Library files/`.
- Anything else: `failed/` with the note "Not a file Cache can use" (no Retry).
- Names that exist in the folder they go to get " (2)", " (3)", ... (in `complete/` that is per division folder).
- Moving a file out of `ingest/` by hand takes it out of the queue.
- Hidden files (names starting with ".") and subfolders are ignored.

`GET /api/build/drop`:

```
{ "settings": {folder, enabled, library_id, library_title},
  "status": { "state": "off"|"ok"|"error", "last_check": rfc3339|null, "found": n (taken at the last check),
              "counts": {all, queue, complete, failed, removed},
              "error": null | {"code": "missing"|"denied"|"error"|"no_library", "message"},
              "stale": true when the table shows the last known state because of an error },
  "files": [ {name, folder: "ingest"|"complete"|"failed", state, position, size, progress, item_id, reason, can_retry, note} ] }
```

File `state`: in `ingest`: `new` (not taken yet), `queued` (with `position`), `working` (with `progress`), `needs_decision` (`reason` says which book it may be an edition of; decide with the queue call, `item_id`), `failed`; in `complete`:
`done` (rows carry `path` below `complete/`, `where` (the folder), `class`, `division`, `call_number`, `title`, `moved_from` and `reason` = the result: "Filed in 530 Water treatment", "Filed in Unsorted", "Replaced: ..."), or `duplicate` for a file left there by an older version; `folder: "removed"` rows (state `duplicate`, `reason` "Exact copy of X" or "Already have a better copy") are results for files Cache did not keep (they are in Removed); in `failed`: `failed` (`reason` from the note
file, `can_retry` true) or `unsupported` (`reason` "Not a file Cache can use", no Retry). `complete` and `failed` list the 200
newest files each; `counts` are the full numbers. Error messages: "The drop folder is missing", "Cache can not read the drop
folder". `no_library` ("Choose the library the PDFs go into") means PDFs are waiting in `ingest/` because no library is chosen;
`state` stays `ok` for that one.

| Call | Body | Result |
|---|---|---|
| `PUT /api/build/drop` | any of `{"folder": "/absolute/path", "enabled": bool, "library_id": id or null, "compression": {"level": "off\|lossless\|smaller_scans", "preset"?: "high\|balanced\|smallest"}}` | the same as GET. Turning it on makes the folder and the three subfolders. |
| `POST /api/build/drop/check` | | the same as GET, after looking now |
| `POST /api/build/drop/retry` | `{"name"}` (a file in `failed/`) | the same as GET. The file goes back to `ingest/` and joins the end of the queue. |

Default folder: `<data>/drop`, off, no library chosen, compression off. `settings.compression` is the drop folder's compression (below). Deleting the chosen library clears the choice.

## Filing by subject

The classes are Cache Decimal System, CDS (`vault/projects/cache-classification.md`): 10 classes of 9 divisions (060 is unassigned). They are
`<data>/build/classes.json`, written from the built-in default (see `server/docs/classes-default.md`) when missing, and read again when the
file changes. A division has a `number`, a `name` and a `description`; the file names the folders and says which divisions are in use (an empty
description means not in use). The descriptions are not used to sort books, and are never shown to the assistant.

How a book is filed: a trained classifier (the shared `cache_classify` crate, a softmax scorer over the search model's vectors) decides. Its
weights are a versioned data file, never part of the app: `<data>/models/cache-classifier-<version>.bin` (the highest version that loads, and
that was trained on the search model the server uses, is used; a new file takes effect without a restart). The book's vector is the mean of
the vectors of up to 24 of its pieces (the first 8 pieces of real text, then 16 spread evenly over the rest), made unit length. The scorer gives
a probability for each division. When the best probability is at least the model's threshold the book is filed in that division; otherwise it
is unsure and goes to Unsorted (`unsure_reason` is a plain sentence). Either way the top 3 divisions with their probabilities are kept as
`suggestions` (`{division,name,class,score}`, `score` is the probability) with `classifier_version` in the book's record (`GET .../books` shows
both). Nothing of this is in the pack or the search payloads. With no usable model file every new book is left in Unsorted with no suggestions
and no `classifier_version` (`unsure_reason`: "This book has not been looked at yet."), and is sorted when a model file appears and the queue is idle.
There are no keyword rules.

Every shelving change is appended to this device's library log, `<data>/app/docs/libraries/<library_id>/log/<device_id>.jsonl` (the library's
root, beside `packs/` and `shard/`, so no search payload carries it): a book built gets `place` and `assign` (by `auto`, or `unsort` when the sorter was
unsure); a placement by hand (`place`, below) gets `place` (by `user`), `retire` of the old number and `assign` of a new one; a rename gets `title`.
The device id is the server's cache_sync identity, kept in `<data>/sync` (`identity.key`; the one folder for this device's sync identity, also for any later sync), shown as the EndpointId's text. The random id of earlier builds in `<data>/build/device_id` is no longer used; its log file stays. The format, the resolution
rules and the local view `.local/docs.json` are in server/builder/LIBRARY-LOG.md. This log replaces the corrections log: a user `place` whose division
differs from the pack's `book.suggested` is a training correction. The `"device"` name in a placement body is no longer used.

A call number is `CDS ` + the division + `-` + a sequence number of at least three digits: `CDS 530-001`. The numbers of a division run 1, 2, 3
in the order books are shelved there, are never reused when a book moves away, and a book in Unsorted has none (`call_number` is null). When two
devices claim the same number the earlier claim keeps it and the others show a suffix, `CDS 530-001.1`, `CDS 530-001.2`. The clean title is
still how a book is named: the PDF's metadata title when it names a real title (not "Microsoft Word - notes.doc"), else its first big heading in
the first five pages, else the file name tidied. It can be edited with the book PATCH.

| Call | Result |
|---|---|
| `GET /api/build/classes[?library_id=]` | `{classes:[{number,name,count,divisions:[{number,name,description,assigned,count}]}], unsorted:{name,count}, libraries:[{id,title,books,unsorted,classes:{"500":n},divisions:{"530":n}}], settings:{classifier_version,threshold}}`; with `library_id` the counts and `libraries` are that library's. |
| `POST /api/build/classes/reclassify` | `{"library_id"?, "scope"?: "all"\|"unsorted"}` looks at the books again (after a new classifier model file was installed); books placed by hand stay. `{checked,moved,failed}`. 409 `classifier_missing` without a classifier model file. |

## Same book, different file

After a book is read, its text is fingerprinted (MinHash, 128 hashes over 5-word shingles of lowercase letters and digits) and compared with the
other books of the same library: the estimated Jaccard similarity, the cosine of the books' mean vectors, and the shorter book's share of the longer's words. The numbers
are `<data>/build/tuning.json` (`same_jaccard` 0.85, `same_cosine` 0.95, `edition_jaccard` 0.5, `min_length_ratio` 0.8; these are the defaults).

- Jaccard >= `same_jaccard`, cosine >= `same_cosine`, shorter >= 80% of the longer: the same book. The better copy is kept: more pages with real text, then more
  pages, then sharper page images (pixels per inch), then the smaller file. A better new copy rebuilds the book as `doc_version` + 1 (same `doc_id`, title, call number
  and place); the old device copy and the old copy in `complete/` go to Removed. A worse or equal one goes to Removed ("Already have a better copy").
- Jaccard from `edition_jaccard` up to `same_jaccard` with the same cosine and length: a possible new edition, state `needs_decision` with `decision`
  `{other_doc_id, old_title, new_title, new:{pages,text_pages,year,size,ppi}, old:{...}, summary:{pages,text_pages,year}, jaccard, cosine, actions}`.
- Shorter than 80%: an excerpt, never the same book.
- Books built before fingerprints have none and are only caught by the exact hash. A scanned book with no text is caught by the exact hash only.
- An exact copy (same BLAKE3) goes to Removed ("Exact copy of X").

## Removed

`<data>/build/removed/` holds files Cache did not keep, with a manifest (file, original path, reason, date). They are deleted after 30 days
(checked at start-up and once a day).

| Call | Result |
|---|---|
| `GET /api/build/removed` | `{keep_days:30, count, items:[{id,file,original_path,reason,date,size,library_id,kind,delete_after}]}` newest first; `kind` is `drop`, `upload` or `source` |
| `POST /api/build/removed/{id}/restore` | the file goes back to the drop folder's `ingest/` (made if needed) and is compared again like any new file, so restoring a worse copy ends as "Already have a better copy" again. `{restored,file,folder}` |
| `DELETE /api/build/removed/{id}` | deletes it for good; `DELETE /api/build/removed` empties Removed. `{deleted}` |

## Errors

`400 invalid | invalid_name | not_pdf | bad_json`, `404 not_found`, `409 name_taken | busy | not_failed | cannot_retry`, `411
length_required`, `507 no_space`, `500 server_error`. All with a plain-sentence `message`.

## Pages in, pack out

Any text source can make a pack through one writer: `cache-build pack --pages pages.json ...`, with `pages.json` an array of
`{pdf_page, label, text_source: "layer"|"ocr", blocks: [{text, kind: "body"|"heading"|"aside", level?, bullet?}]}`, the blocks in
reading order. The build service's own PDF path (`cache-build pdf`, and the service's builds) goes through the same writer after
its layout step, so the same pages give the same passages. A phone, or any OCR engine, hands its text in the same way (one `body`
block per page is enough). The shape of `pages.json`, the pack fields it sets (`text_source_ocr_pages`, `book.ocr`,
`extractor.layout_version`) and the `LAYOUT_VERSION` rule are in builder/PACK-FORMAT.md ("Pages in, pack out", "Layout version").

## Linked-folder adoption foundation

These authenticated /api/linked-folders/ endpoints are separate from builder uploads and the drop folder. They read linked PDFs in place and write only device-local registry state under the target library's .local/. They never invoke builder publication, rewrite existing text/vectors/indexes, compress originals, or move/delete source files.

- GET /api/linked-folders/libraries: installed targets, including imported libraries.
- GET /api/linked-folders/<library>: local configuration, locations and capability flags. Contains local absolute paths; do not sync or publish this response.
- POST /api/linked-folders/<library> with {id,label,mode,root,exclusions}: register a readable server folder. Mode is keep (default), cds, or both. Exclusions are relative subfolder paths.
- POST /api/linked-folders/<library>/check: match stable PDF hashes to existing identities. New or changed files must remain unchanged for two seconds before a later check hashes them.
- POST /api/linked-folders/<library>/<folder>/pause or /resume: persist whether checks include that root.
- DELETE /api/linked-folders/<library>/<folder>: unlink, retain indexed books, mark its locations unavailable.

This is a backend foundation, not the complete feature. Capability flags explicitly report that indexing unmatched PDFs, automatic checks, synced locations, and original-PDF opening are not enabled. Browse mode is retained as configuration; the folder/subject browsing interface is not supplied yet. Unknown or ambiguous hashes are not counted as reused books. Unavailable roots retain records and search data; availability is local and must be rechecked before source opening.
