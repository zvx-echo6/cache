# library-rest: the Library leftovers of L6

Branch `ask-linux-library-rest`, based on `ask-linux-indexing` (the driver change needs it). Audit rows: Library, "Delete a book",
"Cache Documentation", "Catalog ... Pause", "ZIM download: pause and resume".

## 1. Delete a book: NOT BUILT, owner decision needed
The task asked for the server to do what the phone does when a book is deleted. The phone does nothing: `BookFilesUnavailable`
(`app/lib/library/shelf_source.dart`) says "Not available on this device yet." and `DeleteBookSheet` greys both choices
(`book_pages.dart`). The guide (`docs/guide/ch2.md`, "Delete a book") says the same. There is no file removal, no catalogue change
and no Bookshelves log event for a deleted book. The only log events that touch a book's presence are `remove` and `restore`, which
HIDE a book and say "no file is deleted". There is no phone behavior to copy, so any server delete is a new feature:
- what "Delete from all your devices" writes to the Bookshelves log (a new event kind that phones must understand, or a hide),
- what "Remove from this device" means on a server (it has no other device to ask),
- whether the call number is retired (`Retire`) and whether the PDF goes to Removed (30 days) or is erased.
The server already has `DELETE /api/build/libraries/{id}/books/{doc}` (points, pack, PDF copy; used by "Remove" in the built-library
page). It writes no Bookshelves event. Left as it is. Web keeps the phone's greyed "not available yet" choices.

## 2. Guide search: install the guide on the server, headless
The phone copies `assets/guide/cache-guide.cache-library` out of the app and installs it like any library file
(`LibrariesState.ensureGuide` -> `_install`: `unpack_library`, `index_library` when the settings want it, files to
`libraries/cache-guide`, replaced when its `version` differs). A browser skips this (`bundledGuide` returns null on web).
- The server gives the helper the guide package the web build already carries: `<web>/assets/assets/guide/cache-guide.cache-library`
  (`CACHE_GUIDE_LIBRARY`; unset when the file is not there). Same file, same version as the phone gets.
- The helper (`server/helper/bin/guide_install.dart`) does the phone's `_install` steps with the same core jobs, after `open`:
  stage under `<docs>/libraries/.add-guide`, unpack, keep `documents.tsv`, `source-identities.json`, `copies.jsonl`, index when
  wanted, write `cache-library.json`, swap in (old copy closed first), then `setSources` and the driver's `useSources`.
  A marker `<support>/guide-installed.json` (package size and time) skips the work at later starts; a package with the same
  `version` as the installed one is left alone (the phone's rule).
- No new screen: the guide appears where any installed library does, and Library search finds it.

## 3. Index pause
`IndexDriver.pause()` / `resume()` (small, separate commit). Pause cancels the running core job (it keeps what it did, as
`CoreIndexRun.pause`) or PDF run and starts nothing until Resume; kept in memory like the phone's `pauseAll`. Helper op `index.pause`
`{paused?}` -> `{paused, busy}` (browser-callable through `/api/core`). Web: `SourcesState` reads it, the Catalog's existing
"Pause all" / "Resume" buttons (same keys and words) show on web while the server has index work. Not done: a per-row Pause in Catalog.

## 4. Download pause and resume
`POST /api/library/jobs/{id}/pause` and `/resume`. A paused job keeps its part file (the phone's `.part` resume); state `paused`;
a running job stops at its next read and keeps the part; Resume queues it again and it continues with a Range request.
`device_api.dart` gets `pauseJob` / `resumeJob` and the existing download row's Pause and Resume buttons use them on web.
