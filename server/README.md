# Cache Server

Cache Server runs the Cache search core on a machine of your own and serves the browser app and the core's
search and read calls from one port. You sign in with a single password (no username). The first version is a
skeleton: sign-in, keyword search, read, status and the tool list. The browser app and its sign-in page come later.

## Build

From the repository root:

    cd packages/cache_search/native
    cargo build --release -p cache_server

The program is `target/release/cache-server`. It uses the same core as the `cs` command, so it needs what the core
needs on your platform.

## Install (Linux, systemd)

Build a release tarball holding `cache-server`, `web/` (the browser app), `cache-server.service` and a `VERSION`
file, then, as root:

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

    cache-server serve --data <dir> --web <dir> [--listen 0.0.0.0:8443] [--no-tls]

## Files and folders

Under the data folder (`/var/lib/cache-server` when installed):

| Path | What |
|---|---|
| `auth.json` | the password hash (owner only) |
| `sessions.json` | signed-in sessions, as hashes, valid for 30 days (owner only) |
| `tls/cert.pem`, `tls/key.pem` | the certificate and key (the key is owner only) |
| `zims/` | ZIM files to search |
| `libraries/` | one folder per library |
| `index/` | search indexes the core builds |

## TLS

By default the server speaks HTTPS. On first start it makes a self-signed certificate (names: localhost, the
machine's name and 127.0.0.1), so a browser asks you to accept it once. To use your own certificate, replace the two
PEM files in `tls/`. To put the server behind your own reverse proxy, run it with `--no-tls` (plain HTTP; the
session cookie then goes without the Secure flag, so keep that port off the open network).
