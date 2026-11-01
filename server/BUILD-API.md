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

Search inside a library: nothing new. `POST /api/core {"op":"search","args":{...,"sources":["<library_id>"]}}` already takes a
list of source ids; a built library's source id is its `library_id` (the id in `cache-library.json`).

## Libraries

| Call | Body | Result |
|---|---|---|
| `GET /api/build/libraries` | | `[{id,title,books,passages,pages,created_at,published,dirty,waiting,building,publish_error}]` |
| `POST /api/build/libraries` | `{"title"}` | the new library; 409 `name_taken` ("You already have a library called "X". Choose another name, or add to it.") |
| `PATCH /api/build/libraries/{id}` | `{"title"}` | the library; 404, 409 `name_taken` |
| `DELETE /api/build/libraries/{id}` | | `{removed:true,id}`; deletes books, packs, PDF copies and search data. 409 `busy` while a book of it is being built. Confirm in the UI. |
| `GET /api/build/libraries/{id}/books` | query `division=<number>\|unsorted`, `class=<number>`, `sort=title\|call` | `[{id,doc_version,title,pages,passages,ocr_pages,partial,file_name,size,added_at,status, text_pages,year,ppi, class,class_name,division,division_name,call_number,unsorted,suggestions,unsure_reason,placed_by_hand,moved_from,filed_in}]`, by title (default) or, with `sort=call`, Unsorted first and then by call number; `status` is `ready` or `replacing`; `partial` is e.g. `"partial: 2 pages need OCR"` or null |
| `PATCH /api/build/libraries/{id}/books/{doc}` | `{"title"}` | `{id,title}`. Nothing is embedded again. The call number keeps its letters; the filed PDF takes the new title in its name. |
| `POST /api/build/libraries/{id}/books/{doc}/place` | `{"division": "530"}` (`"unsorted"` or null puts it back) | the book (as listed). The device copy and the copy in the drop folder's `complete/` move, the call number takes the new division, `placed_by_hand` is true and `moved_from` names where it was ("Unsorted" or "530 Water treatment"). 400 `invalid` for a division that does not exist or is unassigned; 404. |
| `DELETE /api/build/libraries/{id}/books/{doc}` | | `{removed:true,id}`. The person's own PDF is not touched. |
| `POST /api/build/libraries/{id}/books/{doc}/replace?name=<file name>` | the PDF, streamed, `Content-Length` required | the queue item (`replace` set). The old book stays searchable until the new one is published; `doc_version` + 1. |

`id` of a book is its `doc_id`.

## Adding PDFs

`POST /api/build/upload?library_id=<id>&name=<file name>` with the PDF as the body (streamed to disk, any size, `Content-Length`
required). Result: the queue item. Errors: 404 (no such library), 400 `invalid_name`, 400 `not_pdf`, 411, 507 `no_space`
("Not enough space on this device..."). Upload one request per file. Building starts at once when the search model is there, and
waits (item stays `queued`, the queue says `blocked`) while it is not, so PDFs may be added during the model download.

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
              error, note, replace, doc_id, duplicate_of, drop, position, created_at, started_at, finished_at,
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
| `POST /api/build/queue/{id}/decide` | `{"action": "keep_both"\|"replace_older"}` for a `needs_decision` book (409 `not_waiting` otherwise). `keep_both` queues it to be added as its own book (its call number gets the year, or `2e`, `3e`... after the letters, so two editions in one division read `530 · KEA` and `530 · KEA 2019`). `replace_older` rebuilds the older book from this file (`doc_version` + 1, same call number and place) and puts it at the front of the queue, next after the book being worked on. The queue. |
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
| `PUT /api/build/drop` | any of `{"folder": "/absolute/path", "enabled": bool, "library_id": id or null}` | the same as GET. Turning it on makes the folder and the three subfolders. |
| `POST /api/build/drop/check` | | the same as GET, after looking now |
| `POST /api/build/drop/retry` | `{"name"}` (a file in `failed/`) | the same as GET. The file goes back to `ingest/` and joins the end of the queue. |

Default folder: `<data>/drop`, off, no library chosen. Deleting the chosen library clears the choice.

## Filing by subject

The classes are Cache Decimal Classification (`vault/projects/cache-classification.md`): 10 classes of 9 divisions (060 is unassigned). They are
`<data>/build/classes.json`, written from the built-in default (see `server/docs/classes-default.md`) when missing, and read again when the
file changes. A division has a `number`, a `name` and a `description`; the descriptions are for the embedder only and are never shown to the
assistant. The file also has `unsure_below` and `min_margin`.

How a book is filed: the book's vector is the normalised mean of the vectors of its pieces from its first 15 pages (the first ten pieces
when fewer than three start there); it is compared by cosine with the embedding of each division's name and description (cached in
`build/classes-vectors.json`, made again when the file or the model changes). The top 3 are kept as `suggestions` (`{division,name,class,score}`).
The book goes in the best division unless the best score is under `unsure_below`, or the best beats the second by less than `min_margin`: then it
is unsure and goes to Unsorted (`unsure_reason` is a plain sentence: nothing matched clearly / two matched about equally). There are no keyword rules.

A call number is the division and three letters of the clean title, skipping a leading "The", "A" or "An": `530 · WAT`. In Unsorted it is just
the letters. The clean title is the PDF's metadata title when it names a real title (not "Microsoft Word - notes.doc"), else its first big heading
in the first five pages, else the file name tidied. It can be edited with the book PATCH.

| Call | Result |
|---|---|
| `GET /api/build/classes[?library_id=]` | `{classes:[{number,name,count,divisions:[{number,name,description,assigned,count}]}], unsorted:{name,count}, libraries:[{id,title,books,unsorted,classes:{"500":n},divisions:{"530":n}}], settings:{unsure_below,min_margin}}`; with `library_id` the counts and `libraries` are that library's. |
| `POST /api/build/classes/reclassify` | `{"library_id"?, "scope"?: "all"\|"unsorted"}` looks at the books again (after the file was edited); books placed by hand stay. `{checked,moved,failed}`. 409 `model_missing` without the search model. |

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
