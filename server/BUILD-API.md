# Build API (library builder service)

For the browser UI task. Everything needs a signed-in session. Replies are `{"ok":true,"result":...}` or
`{"ok":false,"error":{"code","message"}}` (the same envelope as `/api/library/...`). Nothing here is visible to the model: the
payload fields of built libraries are exactly the ones in `server/builder/PACK-FORMAT.md` (title, text, page, source, link, doc_id,
doc_version, plus the unmapped extras).

Wording: the replies never say "server" or "job". Error messages are plain sentences meant for people.

## What it does

A built library is a normal library under `<data>/app/docs/libraries/<library_id>/` (`shard/`, `cache-library.json`, and
`packs/` with one `.cdoc` per book), so the core and the keyword-index job open it like any other. The original PDF of every book
is kept in `<data>/app/docs/sources/<library_id>/<doc_id>.pdf`.

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
| `GET /api/build/libraries/{id}/books` | | `[{id,doc_version,title,pages,passages,ocr_pages,partial,file_name,size,added_at,status}]` sorted by title; `status` is `ready` or `replacing`; `partial` is e.g. `"partial: 2 pages need OCR"` or null |
| `PATCH /api/build/libraries/{id}/books/{doc}` | `{"title"}` | `{id,title}`. Nothing is embedded again. |
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
              error, note, replace, doc_id, duplicate_of, drop, position, created_at, started_at, finished_at} ] }
```

`state`: `queued` (Waiting), `reading` (Reading the PDF), `building` (Building passages · `pieces` of `pieces_total`),
`done`, `skipped_duplicate` (same content already in this library; `duplicate_of` is that book's title), `failed` (`error` is the
sentence to show), `ocr_needed` (no text layer at all; `error` says so; Retry works once OCR exists). `note` on a done book is
`"partial: N pages need OCR"`. `position` is the place among the waiting books. `drop` is true for files from the drop folder.
The ETA is a range from the pieces per second seen since the service started; show it as an estimate. Items are in queue order;
finished ones stay (up to 1000) so "x of 214 books done" can be counted: `counts.done + skipped + failed + ocr_needed` over
`counts.total`.

| Call | Result |
|---|---|
| `POST /api/build/queue/pause` | the queue. The book being built is finished, then building holds. Remembered across restarts. |
| `POST /api/build/queue/resume` | the queue |
| `POST /api/build/queue/stop` | the queue plus `removed` (the waiting books taken off the list). The book being built finishes. Files in the drop folder's `ingest/` would be queued again at the next check, so the Stop dialog's "Also turn off the drop folder" matters. |
| `POST /api/build/queue/{id}/retry` | the queue. For `failed` / `ocr_needed` only (409 `not_failed` otherwise). The book goes to the end; a drop-folder file goes back to `ingest/`. |
| `DELETE /api/build/queue/{id}` | the queue. Dismiss a finished item, or cancel a waiting one; 409 `busy` while it is being built. |

A restart: a book that was being built starts again from scratch; the rest of the queue and the paused flag are kept.

## Drop folder

One device-wide folder, three subfolders made by Cache: `ingest/` (the queue), `complete/`, `failed/`. A file in `ingest/` is
taken once its size and time have not changed for 30 seconds. The folder is looked at every 2 minutes (and again 31 seconds after
a new file shows up), and on Check now. (No file-watching crate is in the lockfile, so there is no inotify.)

- PDF: queued for the chosen library; `complete/` when built or skipped as a duplicate; `failed/` + `<name>.why.txt` when it fails or has no text layer.
- `.zim`: installed like a download, then `complete/`.
- `.cache-library`, or a `.gz` that starts with the gzip magic: lands in `incoming/` like an uploaded library package (the browser's install flow installs it), then `complete/`.
- Anything else: `failed/` with the note "Not a file Cache can use" (no Retry).
- Names that exist in `complete/` or `failed/` get " (2)", " (3)", ...
- Moving a file out of `ingest/` by hand takes it out of the queue.
- Hidden files (names starting with ".") and subfolders are ignored.

`GET /api/build/drop`:

```
{ "settings": {folder, enabled, library_id, library_title},
  "status": { "state": "off"|"ok"|"error", "last_check": rfc3339|null, "found": n (taken at the last check),
              "counts": {all, queue, complete, failed},
              "error": null | {"code": "missing"|"denied"|"error"|"no_library", "message"},
              "stale": true when the table shows the last known state because of an error },
  "files": [ {name, folder: "ingest"|"complete"|"failed", state, position, size, progress, item_id, reason, can_retry, note} ] }
```

File `state`: in `ingest`: `new` (not taken yet), `queued` (with `position`), `working` (with `progress`), `failed`; in `complete`:
`done` or `duplicate` (`reason` = "Duplicate: the same content is already in X"); in `failed`: `failed` (`reason` from the note
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

## Errors

`400 invalid | invalid_name | not_pdf | bad_json`, `404 not_found`, `409 name_taken | busy | not_failed | cannot_retry`, `411
length_required`, `507 no_space`, `500 server_error`. All with a plain-sentence `message`.
