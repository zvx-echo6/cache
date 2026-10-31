# Cache Server

Cache Server runs the Cache core on a machine of your own and serves the browser app from one port. You sign in
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

The program is `target/release/cache-server`. It also needs the helper and the core library (see the release tarball
below), whose paths are the `--helper` and `--core-lib` options; by default they are `helper/cache-core-helper` and
`lib/libcache_search.so` beside the program.

## Install (Linux, systemd)

The release tarball (built by `.github/workflows/server-release.yml`) holds `cache-server`, `helper/cache-core-helper`,
`lib/libcache_search.so`, `web/` (the Flutter web build), `cache-server.service` and a `VERSION` file. As root:

    packaging/install.sh <path-to-release-tarball>

It creates the `cache` user, unpacks to `/opt/cache-server/releases/<version>`, points `/opt/cache-server/current`
at it, installs and starts the service, and on a first install asks for the password twice. Running it again with a
newer tarball is an update; the data and the password stay. It installs no packages.

The version is `<Cargo version>+<short git sha>`, for example `0.1.0+d5145e6`, so two builds of the same Cargo version
are two releases. `cache-server --version` and the first line of the service log (`journalctl -u cache-server`) show it.

### Rollback

An install keeps exactly one earlier release: the one that was running becomes `/opt/cache-server/previous`, and anything
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

    sudo -u cache /opt/cache-server/current/cache-server keys --data /var/lib/cache-server --list
    sudo -u cache /opt/cache-server/current/cache-server keys --data /var/lib/cache-server --remove <id>

(removing the last key while the setting needs one puts sign-in back to password only).

## Set or reset the password

    sudo -u cache /opt/cache-server/current/cache-server set-password --data /var/lib/cache-server [--sign-out-all]

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
unit sets no log level and there is none to set. `journalctl -u cache-server` shows, among others: `cache-server <version>
starting`, `helper started (pid N)`, `helper ready`, `core opened (N sources)`, `restarting the helper in Ns (reason: ...)`
and `helper stopped`.

## Running by hand

    cache-server serve --data <dir> --web <dir> [--listen 0.0.0.0:8443] [--no-tls] [--public-origin https://host[:port]] [--helper <exe>] [--core-lib <lib>]

## Files and folders

Under the data folder (`/var/lib/cache-server` when installed):

| Path | What |
|---|---|
| `auth.json` | the password hash, the sign-in setting, the registered security keys and the key files' ids and hashes (owner only, written atomically; a change is picked up by the running server) |
| `config.json` | optional: `{"public_origin": "https://your-host-name"}`, the same as `--public-origin` |
| `sessions.json` | signed-in sessions, as hashes, valid for 30 days (owner only) |
| `tls/cert.pem`, `tls/key.pem` | the certificate and key (the key is owner only) |
| `sources.json` | optional: the sources the core opens, a JSON array as the app's `SearchCore.open` sends them, e.g. `[{"kind":"zim","path":"/var/lib/cache-server/app/docs/zims/wiki.zim","index_dir":"/var/lib/cache-server/app/support/indexes/wiki.zim.idx"}]`. Missing means the helper finds them: every `*.zim` in `app/docs/zims` and every folder with a `shard` folder in `app/docs/libraries` |
| `app/support/` | the app's support folder (`getApplicationSupportDirectory` on a phone): the core's databases (`user.sqlite`, `live.sqlite`, `notebook/`), `regions/`, `layers/`, `indexes/` |
| `app/docs/` | the app's documents folder: `zims/`, `libraries/` (one folder per library), `live-defs/` |
| `zims/`, `libraries/`, `index/` | the older folders, no longer read |

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
