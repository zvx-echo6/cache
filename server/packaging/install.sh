#!/bin/sh
# Install or update Cache Server from a release tarball, or go back to the previous release. Run as root:
#   install.sh <path-to-release-tarball>
#   install.sh --rollback
#
# The tarball holds `cache-server` (the program), `helper/cache-core-helper` (the Dart helper that hosts the core),
# `lib/libcache_search.so` (the core library the helper loads), `web/` (the browser app) and a `VERSION` file.
# Running this again with a newer tarball is an update: the data folder and the password stay.
# The version is `<Cargo version>+<short git sha>`, so two builds of the same Cargo version are different releases. An
# install keeps the release that was running as `previous` (and removes anything older); `--rollback` swaps `current` and
# `previous` and restarts the service. Installing the same build again replaces that release's folder in place.
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

# the value of a symbolic link (empty when it is not one or does not exist)
link_of() {
    readlink "$1" 2>/dev/null || true
}

# point the link $1 at $2; the rename makes the switch atomic, so the link never dangles
point() {
    ln -sfn "$2" "$1.new"
    mv -T "$1.new" "$1"
}

# install the unit file that belongs to the current release
install_unit() {
    if [ -f "$OPT/current/cache-server.service" ]; then
        install -m 644 "$OPT/current/cache-server.service" "$UNIT"
    elif [ -n "${SCRIPT_DIR:-}" ] && [ -f "$SCRIPT_DIR/cache-server.service" ]; then
        install -m 644 "$SCRIPT_DIR/cache-server.service" "$UNIT"
    elif [ ! -f "$UNIT" ]; then
        die "cache-server.service not found next to this script or in the tarball"
    fi
}

USAGE="usage: install.sh <path-to-release-tarball> | install.sh --rollback"
[ "$#" -eq 1 ] || die "$USAGE"
ROLLBACK=0
if [ "$1" = "--rollback" ]; then
    ROLLBACK=1
else
    TARBALL=$1
    [ -f "$TARBALL" ] || die "$TARBALL is not a file"
fi
[ "$(id -u)" -eq 0 ] || die "run this as root"

case "$(uname -m)" in
    x86_64 | aarch64) ;;
    *) die "unsupported machine type $(uname -m) (x86_64 and aarch64 only)" ;;
esac

command -v systemctl >/dev/null 2>&1 || die "systemd is required"

if [ "$ROLLBACK" -eq 1 ]; then
    CUR=$(link_of "$OPT/current")
    PREV=$(link_of "$OPT/previous")
    [ -n "$PREV" ] && [ -d "$PREV" ] || die "there is no previous release to go back to"
    [ -n "$CUR" ] && [ -d "$CUR" ] || die "there is no current release"
    # current takes the previous release first, so it always points at a real folder; then previous takes the old current
    point "$OPT/current" "$PREV"
    point "$OPT/previous" "$CUR"
    install_unit
    systemctl daemon-reload
    systemctl restart cache-server
    echo "Rolled back: Cache Server $(basename "$PREV") is running; $(basename "$CUR") is now the previous release."
    echo "(run install.sh --rollback again to go forward)"
    exit 0
fi

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
    "" | . | .. | *[!A-Za-z0-9._+-]*) die "the VERSION file holds something that is not a version" ;;
esac
[ -x "$STAGE/cache-server" ] || chmod 755 "$STAGE/cache-server" 2>/dev/null || die "the tarball has no cache-server program"
[ -f "$STAGE/helper/cache-core-helper" ] || die "the tarball has no helper/cache-core-helper"
[ -f "$STAGE/lib/libcache_search.so" ] || die "the tarball has no lib/libcache_search.so"
chown -R root:root "$STAGE"
# the service runs as the cache user: it must execute the program and the helper and read the library and the web files
chmod 755 "$STAGE/cache-server" "$STAGE/helper/cache-core-helper"
chmod 644 "$STAGE/lib/libcache_search.so"
chmod -R u=rwX,go=rX "$STAGE/web" "$STAGE/helper" "$STAGE/lib"
chmod 755 "$STAGE"

REL=$OPT/releases/$VERSION
OLD_CUR=$(link_of "$OPT/current")
OLD_PREV=$(link_of "$OPT/previous")

# The same build installed twice: keep a hard-linked copy of the old folder, aim any link at the copy, replace the folder,
# then remove the copy at the end. Whatever the links point at exists at every step.
ASIDE=$OPT/releases/.replaced.$$
if [ -e "$REL" ]; then
    cp -al "$REL" "$ASIDE"
    [ "$OLD_CUR" != "$REL" ] || point "$OPT/current" "$ASIDE"
    [ "$OLD_PREV" != "$REL" ] || point "$OPT/previous" "$ASIDE"
    rm -rf "$REL"
fi
mv "$STAGE" "$REL"

# point current at it, and keep the release that was running as previous
point "$OPT/current" "$REL"
if [ "$OLD_CUR" = "$REL" ]; then
    # a reinstall of the running build: previous stays what it was (and is not the same build)
    if [ "$OLD_PREV" = "$REL" ]; then
        rm -f "$OPT/previous"
    fi
elif [ -n "$OLD_CUR" ] && [ -d "$OLD_CUR" ]; then
    point "$OPT/previous" "$OLD_CUR"
elif [ "$OLD_PREV" = "$REL" ]; then
    rm -f "$OPT/previous"
fi
rm -rf "$ASIDE"

# remove every release that is neither current nor previous (and leftovers of an interrupted run)
KEEP_CUR=$(link_of "$OPT/current")
KEEP_PREV=$(link_of "$OPT/previous")
for d in "$OPT"/releases/* "$OPT"/releases/.[!.]*; do
    [ -e "$d" ] || continue
    [ "$d" != "$KEEP_CUR" ] && [ "$d" != "$KEEP_PREV" ] || continue
    rm -rf "$d"
done

# the unit
install_unit

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
if [ -L "$OPT/previous" ]; then
    echo "The previous release is $(basename "$(link_of "$OPT/previous")"); to go back, run: install.sh --rollback"
fi
echo "(the certificate is self-signed, so the browser asks you to accept it once)"
echo "Sign-in is the password you chose. Security keys and key files are set up after you sign in, at https://$HOST:$PORT/settings/keys"
echo "(security keys also need a host name and a trusted certificate: see the README, --public-origin)"
echo "If you ever lose a key, reset with: $OPT/current/cache-server set-password --data $DATA   (as the cache user)"
