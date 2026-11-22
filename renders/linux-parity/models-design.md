# models: Models screens in the browser (audit MISSING item 9, the Models rows)

## Decision
The server owns the files and the downloads; the browser is a remote control. Nothing about a screen changes: the same Models,
Search Hugging Face and file-list screens run on web through `plat.isWeb` branches inside `ModelDownloads` and `AppState`.
Phone (dart:io) paths are untouched.

## Server (server/src/models.rs, new; routes in http.rs, all behind the session)
- `GET /api/models/downloads` -> `{"downloads":[{name,state,done,total,error?}]}`. state: queued, running, verifying, paused,
  failed, done. The embedder's own download (bge-m3, `/api/models/embedder/download`) is listed as one more entry, so the
  search-model row works; it is owned by the embed code and is not duplicated here.
  Part files left in `<data>/models/.partial/` (a restart, a stop) are listed as paused with their bytes, so nothing is lost on a
  reboot and Resume continues them. The job list itself lives in memory (queued jobs do not survive a restart; the files do).
- `POST /api/models/downloads` `{name, repo, revision, path, size, sha256?}` for Hugging Face, or `{name, url, size, sha256?}` for a
  file Cache publishes. The server builds the address itself from repo/revision/path. `search:true` asks for the search model to
  follow when it is missing; the server starts it (`/api/models/embedder` code) when this file is done, with no tab open.
- `POST /api/models/downloads/<name>/pause`, `.../resume`; `DELETE /api/models/downloads/<name>` (stops, discards the part file).
- `DELETE /api/models/files/<name>` deletes a `.gguf` (409 `in_use` for the loaded model); `POST /api/models/upload?name=x.gguf`
  streams the body to `.partial/<name>.upload.part` and renames it into `<data>/models` (same streaming as the library upload).
- `GET /api/system/memory` -> `{total, avail, threshold:0, low:false}` in bytes, from `/proc/meminfo` (same keys as the phone's
  MemoryReading, so the fit check is the one the phone uses).
- One download runs at a time (FIFO queue, as on the phone). Resumable (HTTP Range), SHA-256 checked when one is given, size checked
  against the declared length, free space checked first, redirects followed by hand and re-checked at each hop.
- Not touched: tool definitions, results, system prompt, act definitions, parity fixtures, `/api/llm/*` (the list the chat reads),
  `/api/models/embedder*`, `/api/embed`.

## Network
Downloads go through this server code, not `/api/fetch`. It allows only https to: huggingface.co, `*.huggingface.co`, `*.hf.co`
(Hugging Face's file store), data.cached.info, cache.echo6.co. A redirect to any other host stops the download. It does not use
the fetch branch's scope policy, so it works before that branch merges.
DEPENDS on ask-linux-fetch (separate branch, not merged here) for Hugging Face search and the file list in the browser (`FetchScope.models` in hf_hub.dart);
this branch does not edit hf_hub.dart. Until it merges, Search Hugging Face fails on web; recommended downloads work.

## App (web only unless noted)
- `models/server_models.dart` (new, shared, no dart:io): the client of the routes above; injected in tests.
- `ModelDownloads`: when it has a server client (web), start/pause/resume/remove/stateOf/isInstalled use the jobs list, polled every
  second while anything is active and once on open. A finished download refreshes the model list and sets `finished`
  ("Use it"). The search model follows a chat model through `search:true`; the queue runs on the server, so a closed tab changes nothing.
- `AppState.refreshModels` (web) reads `/api/llm/models`; `deleteModel` (web) calls the delete route; `pickAndCopy` (web) uses the
  existing `pickLocalFile` and `createRawUploader` and shows the same "Copying ..." progress.
- `models_screen.dart` and `model_search_screen.dart` (shared): `modelsDir == null` no longer ends the flow on web; the memory
  figures come from `/api/system/memory` (`device_memory_web.dart`, `readMemory` on web).
- Chat model choice: Use and Unload already work (`/api/llm/load`); the search model is the server's bge-m3 (embed branch).

## Left, and why
- Pausing the search model (bge-m3) is not offered: its download belongs to the embed code, which can start and report but not pause. It
  shows progress and resumes after a failure (Download again continues the part file).
- Queued jobs are not kept over a server restart (partial files are). Proposed, not approved: persist the queue.
- The "Mobile data" check cannot tell on web, so it never blocks; the data policy is the phone's.
- Free-space line in the download pop-up is blank on web (the server checks it and fails the job with "Not enough free space").
- No visual change. Web-only wording needs: none.
