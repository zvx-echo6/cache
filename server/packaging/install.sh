#!/bin/sh
# Install or update Cache Server from a release tarball. Run as root:
#   install.sh <path-to-release-tarball>
#
# The tarball holds `cache-server` (the program), `web/` (the browser app) and a `VERSION` file.
# Running this again with a newer tarball is an update: the data folder and the password stay.
# It installs no operating-system packages.
#
# TODO: downloading the tarball from GitHub Releases comes later; for now it is a local file.

set -eu

OPT=/opt/cache-server
DATA=/var/lib/cache-server
UNIT=/etc/systemd/system/cache-server.service
PORT=8443

die() {
    echo "install.sh: $*" >&2
    exit 1
}

[ "$#" -eq 1 ] || die "usage: install.sh <path-to-release-tarball>"
TARBALL=$1
[ -f "$TARBALL" ] || die "$TARBALL is not a file"
[ "$(id -u)" -eq 0 ] || die "run this as root"

case "$(uname -m)" in
    x86_64 | aarch64) ;;
    *) die "unsupported machine type $(uname -m) (x86_64 and aarch64 only)" ;;
esac

command -v systemctl >/dev/null 2>&1 || die "systemd is required"

# the unit file sits next to this script (or inside the tarball, see below)
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# the system user and group
if ! getent group cache >/dev/null 2>&1; then
    groupadd --system cache
fi
if ! getent passwd cache >/dev/null 2>&1; then
    NOLOGIN=$(command -v nologin || echo /usr/sbin/nologin)
    useradd --system --gid cache --no-create-home --home-dir /nonexistent --shell "$NOLOGIN" cache
fi

# unpack beside the final place, read the version, then move it in
mkdir -p "$OPT/releases"
STAGE=$(mktemp -d "$OPT/releases/.unpack.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
tar -xzf "$TARBALL" -C "$STAGE"
[ -f "$STAGE/VERSION" ] || die "the tarball has no VERSION file"
VERSION=$(tr -d ' \r\n' <"$STAGE/VERSION")
case "$VERSION" in
    "" | *[!A-Za-z0-9._-]*) die "the VERSION file holds something that is not a version" ;;
esac
[ -x "$STAGE/cache-server" ] || chmod 755 "$STAGE/cache-server" 2>/dev/null || die "the tarball has no cache-server program"
chown -R root:root "$STAGE"
rm -rf "$OPT/releases/$VERSION"
mv "$STAGE" "$OPT/releases/$VERSION"
chmod 755 "$OPT/releases/$VERSION"

# point current at it; the rename makes the switch atomic
ln -sfn "$OPT/releases/$VERSION" "$OPT/current.new"
mv -T "$OPT/current.new" "$OPT/current"

# the unit
if [ -f "$OPT/current/cache-server.service" ]; then
    install -m 644 "$OPT/current/cache-server.service" "$UNIT"
elif [ -f "$SCRIPT_DIR/cache-server.service" ]; then
    install -m 644 "$SCRIPT_DIR/cache-server.service" "$UNIT"
else
    die "cache-server.service not found next to this script or in the tarball"
fi

# the data folder, and the password on a first install
install -d -o cache -g cache -m 0750 "$DATA"
if [ ! -f "$DATA/auth.json" ]; then
    [ -t 0 ] || die "no password is set yet and there is no terminal to ask on; run this from a terminal"
    restore() { stty echo 2>/dev/null || true; }
    trap 'restore; rm -rf "$STAGE"' EXIT
    while :; do
        printf 'Choose a password: ' >&2
        stty -echo
        read -r PW1
        restore
        echo >&2
        printf 'Password again: ' >&2
        stty -echo
        read -r PW2
        restore
        echo >&2
        if [ -z "$PW1" ]; then
            echo "The password cannot be empty." >&2
        elif [ "$PW1" != "$PW2" ]; then
            echo "The two passwords differ." >&2
        else
            break
        fi
    done
    if command -v runuser >/dev/null 2>&1; then
        printf '%s\n' "$PW1" | runuser -u cache -- "$OPT/current/cache-server" set-password --data "$DATA"
    else
        printf '%s\n' "$PW1" | su -s /bin/sh cache -c "$OPT/current/cache-server set-password --data $DATA"
    fi
    PW1= PW2=
fi

systemctl daemon-reload
systemctl enable cache-server
systemctl restart cache-server

HOST=$(hostname -f 2>/dev/null || hostname)
echo "Cache Server $VERSION is running. Open https://$HOST:$PORT/"
echo "(the certificate is self-signed, so the browser asks you to accept it once)"
