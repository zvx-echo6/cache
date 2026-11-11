# Cache for Linux

Cache for Linux (it also runs on Raspberry Pi) is the same Cache as on a phone, running on a machine of your own and serving the browser app from one port. You sign in
with a single password (no username), a security key, a key file, or a mix (see "Signing in" below). The core runs in a helper process (`server/helper`, a Dart program that hosts the
app's own core dispatcher); the server starts it, restarts it if it dies (waits of 1, 2, 5, then 10 seconds, logging each
restart) and forwards the browser's `POST /api/core {"op","args"}` calls to it, one at a time. The server owns the one
shared engine, so a browser's `open`, `close` and `setSources` are answered without being forwarded (the browser never
replaces the server's source list). While the helper is down, calls
get HTTP 503 with `{"ok":false,"error":{"code":"core_unavailable",...}}`.

## Build

From the repository root:

    cd packages/cache_search/native
    cargo build --release -p cache_server

The program is `target/release/cache`. It also needs the helper and the core library (see the release tarball
below), whose paths are the `--helper` and `--core-lib` options; by default they are `helper/cache-core-helper` and
`lib/libcache_search.so` beside the program.

### Road routing and places

The core routes on roads with Valhalla through `lib/libvalhalla_shim.so` (built and tested by `.github/workflows/valhalla.yml`,
shipped in the tarball). The server hands the helper the shim's full path as `CACHE_VALHALLA_SHIM` (default: next to the core
library; `--valhalla-shim` overrides it), and the helper opens the core with the phone's own config sections
(`buildCoreExtras`): `routing.valhalla` (empty `tiles`, the region engine's folder `<data>/app/support/regions/tiles`),
`places` (`merged_dir` `<data>/app/support/regions/places`) and `regions` (`<data>/app/support/regions`). `/api/core` with
op `server.features` says what is there:

    {"routing": {"available": <the shim is a file>, "shim": "<path>"},
     "places":  {"available": <the merged places database is there>, "merged_dir": "<path>"},
     "extras":  {<the config sections the core was opened with; "routing" only when routing is available>}}

### Regions

The browser downloads regions the way the phone does, and the server runs the download, so it goes on with no tab open. The helper
answers three ops through `/api/core` (`server/helper/bin/regions_ops.dart`): `regions.open` (the engine is open; `unavailable` when the
core has none), `regions.call {method, args}` and `regions.close` (nothing: the engine is the server's). The methods are the region
engine's (`status`, `plan`, `add`, `remove`, `stream`, `set_policy`, `check_update`, `update`; docs/REGIONS.md) on the same engine the
search core opened (one per folder, `<data>/app/support/regions`), plus the off-road packs, which the phone downloads in Dart and the
helper downloads here (`offroad_packs.dart`): `offroad_fetch {path,url,bytes,sha256}`, `offroad_status {paths}`, `offroad_cancel {path}`
and `offroad_remove {path}`. A pack is `<build>/<id>/offroad.sqlite` under `regions/offroad`, fetched only from the data host
(`data.cached.info`, `cache.echo6.co`), resumed from its `.part` file and checked against its SHA-256. When the core opens, the helper
reads `<support>/regions-app.json` (written by the app), gives the engine the person's Pause (the engine does not keep it) and
carries on the packs the kept regions still miss. The region and off-road catalogues are fetched through `/api/fetch` and kept in
`<support>/region-catalogue`.

### Map tiles

The core's layer engine serves map tiles from a tile server inside the helper process, on 127.0.0.1 and a random port, which a browser cannot
reach. The server forwards to it:

    GET /api/tiles/layers/<id>/<z>/<x>/<y>[.ext]     -> the tile, as the tile server answers it
    GET /api/tiles/layers/<id>/tilejson.json         -> the layer's TileJSON

The answer is passed through unchanged: 200 with the tile (`Content-Type`, `X-Cache-Status`), 204 where the source has no tile, 503 with
`Retry-After` for a tile that may come later (the map asks again). It needs the same signed-in session cookie as every `/api/` call; MapLibre's
requests are same-origin, so they carry it and there is no separate token. The port is found by the helper's `layers` op with `server`
(the call the browser makes to start the tile server; no `online` option is sent), kept, and asked for again once when a connection fails
(after a helper restart); 503 `core_unavailable` while the helper is down, 502 `tile_server_unreachable` when the port does not answer.
Only `layers/...` paths of letters, digits, `.`, `_`, `-` are forwarded (404 otherwise), only GET and HEAD, and the query is dropped.
The map fonts are not here: they are Flutter assets under `/assets/assets/map/fonts/`.

### Videos

The browser's Videos run on the same engine as the phone's. The helper opens a video core handle on `<data>/app/docs/videos` (the phone's folder
under the files root, so a video that arrives by sync lands there too) and answers the `video.*` ops through `/api/core`: `video.info`,
`video.call {op, request}` (any `cs_video_*` call), `video.jobStart|jobProgress|jobCancel|jobFree` and `video.jobs`. A download is a core job
in the helper, so it goes on with no tab open; pausing cancels it and keeps the partial file, resuming starts it again (the core continues the
file), and a tab opened later lists the running and finished downloads with `video.jobs`. A server restart ends running downloads; their partial
files stay. The helper handles one request at a time, so a slow video-site call holds up other ops until it answers.

Playing goes through three GET routes. A same-origin `<video>` sends the session cookie, so none needs a token:

    GET|HEAD /api/video/media/<path under the videos folder>   a saved video, sound, caption or picture, with Range (206, 416)
    GET|HEAD /api/video/zim/<zim id>/<entry path>              a video or caption entry of a ZIM, with Range (the last entry read is kept in memory)
    GET      /api/video/stream?u=<address>                     a video site's file, caption or picture, read by the server, with Range

`media` takes plain file names only (no `..`, hidden or empty names, backslashes) and the real file must be inside the videos folder (404
otherwise). `stream` reaches `http`/`https` hosts whose every address is public: the client's name lookup refuses loopback, private,
link-local, shared (100.64/10), multicast and reserved addresses, so a redirect or a DNS answer cannot reach this machine or the home
network (502); up to four redirects; `Range` is passed on; an upstream error status is passed on with no body. What it sends back has a
media, caption or picture type only (anything else is `application/octet-stream`) and `Content-Security-Policy: sandbox`, so a page from a
video site cannot run on this origin. An HLS playlist (`.m3u8`) is rewritten so its parts, keys and sub-playlists come back through this
route; a private video's `videoFileToken` is kept on addresses of the site it came with. 401 without a session; only GET and HEAD.

### The text embedder

The server embeds text with the same model the phone uses (bge-m3 Q8_0, the pinned `lm-kit/bge-m3-gguf` revision in
`app/lib/models/search_model.dart`), for the library builder and for the browser's search by meaning. `src/embed.rs` loads
`lib/libcache_llama.so` (llama.cpp behind `cl_embed`, built from `packages/cache_llama`; `--embed-lib` overrides the path)
through the `cache_embed` crate, so a vector is the phone's vector. The model (634,553,856 bytes, sha256 checked) is not in
the tarball: it is downloaded into `<data>/models/` on first need, resuming a `.part` file after an interruption.

    GET  /api/models/embedder             -> {state: missing | downloading {bytes,total} | ready | error {error}, file, size, library_found}
    POST /api/models/embedder/download    -> the same; starts or continues the download
    POST /api/embed {texts:[...]}         -> {vectors, model, dims}; 1 to 64 texts; 503 model_missing until the model is there

Both need a signed-in session. The loaded model takes about 700 MB and is let go after two minutes without a call. On x86_64
the library uses AVX2, FMA and F16C; a CPU without them gets `embed_unavailable`. In Rust, the builder calls
`EmbedService::embed_batch(&[String])`.

### The chat model (Ask in the browser)

The browser build of Ask runs the whole loop (prompt, tools, citations) in the page; only the model runs on the server, through the
same `libcache_llama.so` (`cl_load`, `cl_start`, `cl_next`, ...). The routes are `GET /api/llm/models`, `POST /api/llm/load`,
`POST /api/llm/generate` (an NDJSON stream) and `POST /api/llm/stop`, protocol version 1, all behind the sign-in. Chat models are
the `.gguf` files in `<data>/models/` other than the embedder; they are loaded by file name only. One model is loaded for the
whole server and one answer is generated at a time (others wait and are told their place). The protocol mirrors the app's own
session, `packages/cache_llama/lib/llama_session_io.dart`. Every route, field and event: [docs/llm-protocol.md](docs/llm-protocol.md).

Security keys use OpenSSL (through webauthn-rs). On Linux it is built from source and linked statically, so the installed
server needs no libssl; the build needs `perl` and `make`. On Windows the build links a static OpenSSL from vcpkg instead:
`vcpkg install openssl:x64-windows-static-md`, then set `OPENSSL_DIR` to `<vcpkg>\installed\x64-windows-static-md`,
`OPENSSL_STATIC=1` and `OPENSSL_NO_VENDOR=1` before `cargo build`.

## Supported systems

The release binaries are built on Ubuntu 22.04 and need glibc 2.35 or newer: Ubuntu 22.04+, Debian 12+ and Raspberry Pi OS
bookworm (64-bit)+, on x86_64 and aarch64. Older systems are not supported. The build fails if a binary needs a newer glibc.

## Install (Linux, systemd)

The release tarball (built by `.github/workflows/server-release.yml`) holds `cache`, `helper/cache-core-helper`,
`lib/libcache_search.so`, `web/` (the Flutter web build), `cache.service` and a `VERSION` file. As root:

    packaging/install.sh <path-to-release-tarball>

Where things are: the program and its releases are in `/opt/cache-app`; your library and settings are in `/var/lib/cache-app`
(the libraries you build in `app/docs/libraries`, ZIM files in `app/docs/zims`, the password and sign-in settings in `auth.json`);
there is no configuration folder, the few settings are files in the data folder. The names say `cache-app` on purpose: a folder
simply called `cache` reads as safe to delete, and nothing is ever written under any system cache folder (a test fails if a
default path does).

Nothing has been released yet, so there is no migration from earlier paths: a test machine gets a fresh install.

It creates the `cache` user, unpacks to `/opt/cache-app/releases/<version>`, points `/opt/cache-app/current`
at it, installs and starts the service, and on a first install asks for the password twice. Running it again with a
newer tarball is an update; the data and the password stay. It installs no packages.

The version is `<Cargo version>+<short git sha>`, for example `0.1.0+d5145e6`, so two builds of the same Cargo version
are two releases. `cache --version` and the first line of the service log (`journalctl -u cache`) show it.

### Rollback

An install keeps exactly one earlier release: the one that was running becomes `/opt/cache-app/previous`, and anything
older is removed. The release in use is never removed. Installing the same build again replaces that release's folder
(the old copy stays reachable until the new one is in place, so `current` never points at nothing). To go back:

    sudo packaging/install.sh --rollback

It swaps `current` and `previous`, installs that release's unit file and restarts the service. Running it again goes
forward again. The data folder is shared by both releases and is not touched.

## Signing in

Anyone without a session gets the sign-in page for every page request (`/`, `/index.html`, any path without a file
extension) and HTTP 401 for every other file; `/api/*` answers `401` JSON as before. The page has its CSS, script and logo
inline, so it needs nothing else before you sign in. After a sign-in it reloads and the app is served.

The server has one sign-in setting, kept in `auth.json` and changed at `https://<host>:8443/settings/keys` (sign in
first; it applies at once, no restart):

| Setting | Meaning |
|---|---|
| Password only | the password (the default, and what a fresh install uses) |
| Password or key | the password, or a key |
| Password and key | the password, then a key (the password step gives a 5 minute, HttpOnly half cookie that only the key endpoints accept) |
| Key only | a key; the password endpoint answers 403 |

"Start with the password box" (only for Password or key) makes the page show the password box at once instead of asking
the security key first.

A key is either of two kinds:

- **Security key** (WebAuthn, a USB/NFC key). Needs `--public-origin https://your-host-name[:port]` (or
  `{"public_origin": "https://your-host-name"}` in `<data>/config.json`): WebAuthn is tied to a fixed host name, so the
  server must be told the address people use. Without it, or with an IP address, security keys are off: the sign-in page
  hides the security-key button and the settings page shows "Needs a hostname with a trusted certificate". **Browsers
  refuse WebAuthn on sites with certificate errors**, so the default self-signed certificate does not work for security
  keys: use your own certificate (see TLS) or put the server behind a reverse proxy that has one. Registering a key asks
  for a touch only (no PIN is demanded), and signing in is one touch.
- **Key file**. "Make a key file" downloads `cache-<name>.key`, a small text file holding a random 32-byte secret. The
  server keeps only the file's id and a SHA-256 of the secret, never the secret, so a lost file cannot be recovered, only
  replaced. Signing in with it posts the file's bytes (at most 4 KB) and needs the browser's file picker each time.

The settings page will not let you lock yourself out: Key only and Password and key are disabled while no key is
registered, and the last key cannot be removed while the setting needs one. Wrong passwords, keys and files are slowed
down together (see below). Registered keys are listed and can be removed on the server too:

    sudo -u cache /opt/cache-app/current/cache keys --data /var/lib/cache-app --list
    sudo -u cache /opt/cache-app/current/cache keys --data /var/lib/cache-app --remove <id>

(removing the last key while the setting needs one puts sign-in back to password only).

## Set or reset the password

    sudo -u cache /opt/cache-app/current/cache set-password --data /var/lib/cache-app [--sign-out-all]

No restart is needed. The running server re-reads `auth.json` at the next sign-in after it changed, so the old password
stops working and the new one works at once. Browsers that are already signed in stay signed in, unless you add
`--sign-out-all`: it empties `sessions.json`, and the running server drops its sessions on its next request, so every
browser has to sign in again.

`set-password` also puts the sign-in setting back to Password only (and "Start with the password box" off) and keeps the
registered keys, so it is the way back in if a key is lost.

The password is read from standard input (one line; hidden when typed on a terminal). It is stored as a salted
PBKDF2-HMAC-SHA256 hash. Wrong passwords, keys and key files are slowed down together: from the second failure in a row
the answer is held back 2, 4, 8, 16 and then 30 seconds.

## Logs

The server writes plain lines to standard error, which systemd sends to the journal at its default priority (info); the
unit sets no log level and there is none to set. `journalctl -u cache` shows, among others: `cache <version>
starting`, `helper started (pid N)`, `helper ready`, `core opened (N sources)`, `restarting the helper in Ns (reason: ...)`
and `helper stopped`.

## Running by hand

    cache serve --data <dir> --web <dir> [--listen 0.0.0.0:8443] [--no-tls] [--public-origin https://host[:port]] [--helper <exe>] [--core-lib <lib>]

## Files and folders

Under the data folder (`/var/lib/cache-app` when installed):

| Path | What |
|---|---|
| `auth.json` | the password hash, the sign-in setting, the registered security keys and the key files' ids and hashes (owner only, written atomically; a change is picked up by the running server) |
| `config.json` | optional: `{"public_origin": "https://your-host-name"}`, the same as `--public-origin` |
| `sessions.json` | signed-in sessions, as hashes, valid for 30 days (owner only) |
| `tls/cert.pem`, `tls/key.pem` | the certificate and key (the key is owner only) |
| `sources.json` | optional: the sources the core opens, a JSON array as the app's `SearchCore.open` sends them, e.g. `[{"kind":"zim","path":"/var/lib/cache-app/app/docs/zims/wiki.zim","index_dir":"/var/lib/cache-app/app/support/indexes/wiki.zim.idx"}]`. Missing means the helper finds them: every `*.zim` in `app/docs/zims` and every folder with a `shard` folder in `app/docs/libraries` |
| `app/support/` | the app's support folder (`getApplicationSupportDirectory` on a phone): the core's databases (`user.sqlite`, `live.sqlite`, `notebook/`), `regions/`, `layers/`, `indexes/` |
| `app/docs/` | the app's documents folder: `zims/`, `libraries/` (one folder per library), `live-defs/` |
| `zims/`, `libraries/`, `index/` | the older folders, no longer read |

## Indexing

With no browser open, the helper indexes what the phone indexes (`server/helper/bin/index_driver.dart`): the keyword index of each
ZIM and library, seals of older indexes, the EPUBs and caption files inside ZIMs (`index_source`), and the PDFs inside ZIMs. The
PDF text comes from MuPDF, through the hidden `cache pdf-text` command that the helper runs for each PDF (`CACHE_PDF_TEXT_EXE`,
which the server sets to itself); the chunks and records are the core's own, so the indexes are the phone's format. Work yields to
the host's heat (thermal zones) and memory (`/proc/meminfo`). Design: `renders/linux-parity/indexing-design.md`.

Pause and Resume (the Catalog's "Pause all" and "Resume", helper op `index.pause`) stop what runs, keeping what it did, and start
nothing until Resume; like the phone's they are kept in memory, so a restart resumes. Design: `renders/linux-parity/library-rest-design.md`.

## The guide library

The setup guide the app bundles is installed on the server with no browser open, so guide search works in a browser as on a phone.
The server gives the helper the package from its web build (`<web>/assets/assets/guide/cache-guide.cache-library`, as
`CACHE_GUIDE_LIBRARY`); after the core opens, `server/helper/bin/guide_install.dart` unpacks it to `app/docs/libraries/cache-guide`
(the steps of the phone's `LibrariesState.ensureGuide`) and replaces it when the app carries another `version`. Not done when
`sources.json` gives the sources (that list is the operator's own).

## The helper

The server starts `cache-core-helper` with `CACHE_CORE_LIB` (the core library), `CACHE_APP_SUPPORT` and `CACHE_APP_DOCS`
(the two `app/` folders above). It answers three kinds of op over the line protocol:

- **`open`** (sent by the server only): the helper builds the core's config with the app's own `buildCoreExtras`
  (`app/lib/search/core_config.dart`) on the server paths, as `SourcesState._defaultExtras` does on desktop Linux, and opens the
  core with it. The server logs `core opened (N sources; config sections: ...)`; the helper's own lines (`[helper] ...`) say
  where the sources came from and which extras it sent (`layers, live, notebook, places, regions, routing, user`). Not done on
  the server yet: the ICU data install (`installIcuData`) and the starter map layers (`installStarterLayers`).
- **`fs.*`**, the browser's only way to the app's files, confined to two roots, `support` and `docs`: `fs.read`, `fs.readString`,
  `fs.write` (atomic: temp file, then rename; makes parent folders), `fs.list`, `fs.stat`, `fs.exists`, `fs.delete`
  (`recursive?`), `fs.mkdir`. Paths are relative, use `/`, and may not contain `..` or leave the root even through a symlink
  (`bad_path`); missing files give `not_found`, other failures `io_error`. Bytes travel as `{"$bytes": "<base64>"}`.
- every other op goes to the core's dispatcher.

Not done yet: **`history.*`**. The browser's chat history is not saved on the server; it waits for the shared Flutter-free
package split (step 4), because `ConversationStore` imports Flutter-dependent code.

## TLS

By default the server speaks HTTPS. On first start it makes a self-signed certificate (names: localhost, the
machine's name and 127.0.0.1), so a browser asks you to accept it once. To use your own certificate, replace the two
PEM files in `tls/`. To put the server behind your own reverse proxy, run it with `--no-tls` (plain HTTP; the
session cookie then goes without the Secure flag, so keep that port off the open network).
