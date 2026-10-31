# Cache Server

Cache Server runs the Cache core on a machine of your own and serves the browser app from one port. You sign in
with a single password (no username). The core runs in a helper process (`server/helper`, a Dart program that hosts the
app's own core dispatcher); the server starts it, restarts it if it dies (waits of 1, 2, 5, then 10 seconds, logging each
restart) and forwards the browser's `POST /api/core {"op","args"}` calls to it, one at a time. The server owns the one
shared engine, so a browser's `open` and `close` are answered without being forwarded. While the helper is down, calls
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

## Set or reset the password

    sudo -u cache /opt/cache-server/current/cache-server set-password --data /var/lib/cache-server
    sudo systemctl restart cache-server

The password is read from standard input (one line; hidden when typed on a terminal). It is stored as a salted
PBKDF2-HMAC-SHA256 hash. Wrong passwords are slowed down: from the second failure in a row the answer is held back
2, 4, 8, 16 and then 30 seconds.

## Running by hand

    cache-server serve --data <dir> --web <dir> [--listen 0.0.0.0:8443] [--no-tls] [--helper <exe>] [--core-lib <lib>]

## Files and folders

Under the data folder (`/var/lib/cache-server` when installed):

| Path | What |
|---|---|
| `auth.json` | the password hash (owner only) |
| `sessions.json` | signed-in sessions, as hashes, valid for 30 days (owner only) |
| `tls/cert.pem`, `tls/key.pem` | the certificate and key (the key is owner only) |
| `sources.json` | optional: the sources the core opens, a JSON array as the app's `SearchCore.open` sends them, e.g. `[{"kind":"zim","path":"/var/lib/cache-server/zims/wiki.zim","index_dir":"/var/lib/cache-server/index/wiki"}]` (missing means none) |
| `zims/` | ZIM files |
| `libraries/` | one folder per library |
| `index/` | search indexes the core builds |

## TLS

By default the server speaks HTTPS. On first start it makes a self-signed certificate (names: localhost, the
machine's name and 127.0.0.1), so a browser asks you to accept it once. To use your own certificate, replace the two
PEM files in `tls/`. To put the server behind your own reverse proxy, run it with `--no-tls` (plain HTTP; the
session cookie then goes without the Secure flag, so keep that port off the open network).
