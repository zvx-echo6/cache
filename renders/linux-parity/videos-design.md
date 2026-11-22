# Videos in the browser (audit MISSING item 13)

Goal: Videos in Cache on Linux work as on the phone: list, library, player, transcript, sign-in, saving a video, ZIM videos, prefs.
Phone code paths are not changed; web paths sit beside them (`plat.isWeb`, `*_web.dart`).

## Where things live
- **Saved videos folder**: `<docs root>/videos` on the server (`<data>/app/docs/videos`). It is the phone's `appFilesPath()/videos`, so a video
  that arrives by sync lands there and shows in the list. `VideoState.dirPath` carries that path (a browser cannot build a `Directory`).
- **Instances, manifests, captions, thumbnails**: the core's own files in that folder, as on the phone.
- **Login tokens**: `flutter_secure_storage_web` in the browser (as `token_store.dart` already does). They go to the server one call at a time,
  as on the phone, and the server keeps none. (A server-side keystore is another agent's item.)
- **Player position, captions choice, quality**: `video-prefs.json` in the support root through AppFs (same file name as the phone).

## Engine: VideoCore through the helper
- `VideoCore` (cache_search) becomes `video_core_io.dart` (unchanged) and `video_core_web.dart`; `video_core.dart` picks one.
  The web one sends ops through `HttpTransport` to `/api/core`, like SearchCore.
- Helper ops (new `server/helper/bin/video_ops.dart`, `VideoOps`, registered in `cache_core_helper.dart`): the helper opens one more
  core handle with `{"sources":[],"video":{"dir":"<docs>/videos"},"indexes_dir":"<support>/indexes"}` (what the phone's VideoCore does).
  - `video.info {}` -> `{dir}`
  - `video.call {op, request}` -> the cs_video_* JSON string (instances, login, list, get, downloads, delete, resolve, ...)
  - `video.jobStart {instance, video, choice, token, title, label}` -> `{job}`; the download runs in the core's thread, so it goes on with
    no tab open. Starting the same video again while it runs returns the running job.
  - `video.jobProgress|jobCancel|jobFree {job}`; `video.jobs {}` -> every job the helper holds with its title/choice/label and progress.
  - Pause = cancel (the partial file stays), Resume = start again (the core continues the partial file). Same as the phone.
- `VideoState` on web: no Directory; opens the core, reads `video.info`, then `jobs()` so a reloaded tab shows downloads that are
  running or finished. A server restart ends running downloads (the phone's app being killed is the same); the partial file stays.

## Playing
- Same-origin `<video>` sends the session cookie, so no token is needed (`/zim/` needs one only because its frame has no origin).
- `GET /api/video/media/<path under videos folder>` (new `server/src/video.rs`): saved video, audio, caption and thumbnail files, with
  Range (206), HEAD, content types by extension. Segments are checked (no `..`, no hidden names) and the real path must stay in the folder.
- `GET /api/video/zim/<zim id>/<entry>`: a ZIM's video or caption entry with Range. The entry is read through the helper (`zimGet`) and the last
  one is kept in memory so seeking does not read it again.
- `GET /api/video/stream?u=<url>`: stream proxy for a PeerTube file, caption or thumbnail (a `<video>` cannot send the token header,
  and a browser may not read other sites). http/https only, only addresses that resolve to public hosts (a resolver filter inside the
  client, so a redirect or DNS rebind cannot reach the LAN or this machine), Range forwarded, at most 4 redirects.
  An HLS playlist is rewritten so its parts come back through the proxy (and keep a private video's file token).
- Captions on web are read with a same-origin GET of those URLs (the audit's "captions blocked" fetch policy is not used).

## Not changed / left
- HLS-only videos need hls.js in `web/index.html` for Chrome and Firefox (Safari plays HLS itself); not added (shared file, new asset). Videos with
  an mp4 file play.
- Sign in with a site's external plugin opens that site in a new tab and asks to paste back the address it ends on (the phone uses an in-app browser).
- The helper runs one request at a time, so a slow video-site call holds up other ops until it answers (the phone has a separate isolate).
