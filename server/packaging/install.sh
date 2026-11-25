#!/bin/sh
# Install or update Cache from a release tarball, or go back to the previous release. Run as root, through sudo from your own
# account:
#   sudo sh install.sh <path-to-release-tarball>
#   sudo sh install.sh --user <name> <path-to-release-tarball>    (Cache for another person, or to hand it over)
#   sudo sh install.sh --rollback
#
# The tarball holds `cache` (the program), `helper/cache-core-helper` (the Dart helper that hosts the core),
# `lib/libcache_search.so` (the core library the helper loads), `lib/libzim.so.9` (libzim with Xapian and ICU, which
# the core links and finds next to itself), `lib/libcache_llama.so` (llama.cpp behind cl_embed: the server
# loads it to embed text with the search model, which it downloads into the data folder on first need), `web/` (the browser app)
# and a `VERSION` file.
# Running this again with a newer tarball is an update: the data folder and the password stay.
# The version is `<Cargo version>+<short git sha>`, so two builds of the same Cargo version are different releases. An
# install keeps the release that was running as `previous` (and removes anything older); `--rollback` swaps `current` and
# `previous` and restarts the service. Installing the same build again replaces that release's folder in place.
# It installs no operating-system packages.
#
# Where things are (the same names in the service file): the program and its releases in /opt/cache-app, your library and
# settings in /var/lib/cache-app (the libraries you build in app/docs/libraries, ZIM files in app/docs/zims, the password in
# auth.json). The folder names say cache-app on purpose, and nothing is kept in any system cache folder, so clearing caches never
# touches your library.
#
# Cache runs as the person who installed it (their own account, so it can open the folders they can open), as a system service
# that starts at boot. The person is --user, else the account that ran sudo (SUDO_USER, DOAS_USER, PKEXEC_UID), else, on an
# update, the one recorded in /etc/cache-app/person. It is named in the drop-in cache.service.d/person.conf; the release's own
# cache.service keeps User=cache only as a fallback. An update from a release that ran as the cache user stops the service, hands
# the data folder to the person (same place, only the owner changes) and starts it again. One Cache per computer: an update run
# by another account is refused unless --user hands it over.
#
# The paths can be moved with CACHE_INSTALL_OPT, _DATA, _UNIT, _ETC and _LOGIN_DEFS, for the tests (server/packaging/test) only:
# the service file names the real ones.
#
# TODO: downloading the tarball from GitHub Releases comes later; for now it is a local file.

set -eu

OPT=${CACHE_INSTALL_OPT:-/opt/cache-app}
DATA=${CACHE_INSTALL_DATA:-/var/lib/cache-app}
UNIT=${CACHE_INSTALL_UNIT:-/etc/systemd/system/cache.service}
ETC=${CACHE_INSTALL_ETC:-/etc/cache-app}
LOGIN_DEFS=${CACHE_INSTALL_LOGIN_DEFS:-/etc/login.defs}
DROPIN=$UNIT.d/person.conf
RECORD=$ETC/person
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
    if [ -f "$OPT/current/cache.service" ]; then
        install -m 644 "$OPT/current/cache.service" "$UNIT"
    elif [ -n "${SCRIPT_DIR:-}" ] && [ -f "$SCRIPT_DIR/cache.service" ]; then
        install -m 644 "$SCRIPT_DIR/cache.service" "$UNIT"
    elif [ ! -f "$UNIT" ]; then
        die "cache.service not found next to this script or in the tarball"
    fi
}

# write file $1 with the text $2 so that it is either the old file or the new one, never half of it
write_atomic() {
    printf '%s\n' "$2" >"$1.new"
    chmod 644 "$1.new"
    mv -f "$1.new" "$1"
}

# the drop-in that makes the service run as $PERSON
dropin_text() {
    printf '%s\n%s\n%s\n%s' "# Written by install.sh: Cache runs as the person who installed it. install.sh writes this file again on every install." \
        "[Service]" "User=$PERSON" "Group=$PGROUP"
}

# the person recorded by an earlier install (empty when there is none)
recorded_person() {
    [ -f "$RECORD" ] || return 0
    r=$(head -n 1 "$RECORD" | tr -d ' \t\r\n')
    case "$r" in
        "" | *[!A-Za-z0-9._-]*) die "$RECORD does not hold an account name; pass --user <name>" ;;
    esac
    echo "$r"
}

# check that $PERSON is an account Cache may run as, and set PUID, PGROUP and PHOME
check_person() {
    ENT=$(getent passwd "$PERSON") || die "there is no account called $PERSON"
    PERSON=$(echo "$ENT" | cut -d: -f1)
    PUID=$(echo "$ENT" | cut -d: -f3)
    PGID=$(echo "$ENT" | cut -d: -f4)
    PHOME=$(echo "$ENT" | cut -d: -f6)
    if [ "$PERSON" = root ] || [ "$PUID" -eq 0 ]; then
        die "Cache does not run as root. Run this with sudo from your own account, or pass --user <name>."
    fi
    [ "$PERSON" != cache ] || die "Cache runs as a person's own account, not as the cache account. Pass --user <name>."
    UID_MIN=$(awk '$1 == "UID_MIN" { print $2 }' "$LOGIN_DEFS" 2>/dev/null | tail -n 1)
    case "$UID_MIN" in "" | *[!0-9]*) UID_MIN=1000 ;; esac
    UID_MAX=$(awk '$1 == "UID_MAX" { print $2 }' "$LOGIN_DEFS" 2>/dev/null | tail -n 1)
    case "$UID_MAX" in "" | *[!0-9]*) UID_MAX=60000 ;; esac
    [ "$PUID" -ge "$UID_MIN" ] && [ "$PUID" -le "$UID_MAX" ] || die "$PERSON is a system account, not a person's. Pass --user <name> with your own account."
    [ -n "$PHOME" ] && [ -d "$PHOME" ] || die "$PERSON has no home folder ($PHOME). Cache starts the folder picker there."
    PGROUP=$(getent group "$PGID" | cut -d: -f1) || true
    [ -n "$PGROUP" ] || PGROUP=$PGID
}

# whether the data folder holds anything not owned by uid $1
data_not_owned_by() {
    [ -d "$DATA" ] || return 1
    [ -n "$(find "$DATA" ! -user "$1" -print 2>/dev/null | head -n 1)" ]
}

# wait up to 30 s for the service to be active
wait_active() {
    i=0
    while ! systemctl is-active --quiet cache; do
        i=$((i + 1))
        [ "$i" -lt 30 ] || die "Cache did not start. See: journalctl -u cache"
        sleep 1
    done
}

# a check after the start failed: stop Cache and say which check
check_failed() {
    systemctl stop cache || true
    die "check failed: $*. Cache is stopped. To go back to the previous release, run: install.sh --rollback"
}

# the cache system user and group, made exactly as releases from before Cache ran as the person made them; only a rollback to
# such a release needs them
ensure_cache_user() {
    if ! getent group cache >/dev/null 2>&1; then
        groupadd --system cache
    fi
    if ! getent passwd cache >/dev/null 2>&1; then
        NOLOGIN=$(command -v nologin || echo /usr/sbin/nologin)
        useradd --system --gid cache --no-create-home --home-dir /nonexistent --shell "$NOLOGIN" cache
    fi
}

# whether the release folder $1 runs as the person (its cache.service carries the marker)
runs_as_person() {
    grep -q '^X-Cache-RunsAs=person$' "$1/cache.service" 2>/dev/null
}

# The identity guard. This computer's device key (sync/identity.key: what every linked phone knows it by), the password file and
# the certificate must come through a hand-over between accounts unchanged. Their SHA-256 is kept before (in variables, never
# printed) and compared after the start; a missing key would be replaced by a new one, and every link lost.
sum_of() {
    if [ -f "$1" ]; then sha256sum "$1" | cut -d ' ' -f 1; else echo absent; fi
}
guard_before() {
    G_KEY=$(sum_of "$DATA/sync/identity.key")
    G_AUTH=$(sum_of "$DATA/auth.json")
    G_CERT=$(sum_of "$DATA/tls/cert.pem")
    G_SYNC=absent
    [ ! -f "$DATA/sync/sync.json" ] || G_SYNC=present
}
guard_after() {
    if [ "$G_KEY" != absent ] && [ "$(sum_of "$DATA/sync/identity.key")" != "$G_KEY" ]; then
        check_failed "sync/identity.key (this computer's identity for its linked devices) changed while Cache started"
    fi
    if [ "$G_AUTH" != absent ] && [ "$(sum_of "$DATA/auth.json")" != "$G_AUTH" ]; then
        check_failed "auth.json (the password) changed while Cache started"
    fi
    if [ "$G_CERT" != absent ] && [ "$(sum_of "$DATA/tls/cert.pem")" != "$G_CERT" ]; then
        check_failed "tls/cert.pem (the certificate) changed while Cache started"
    fi
    if [ "$G_SYNC" = present ] && [ ! -f "$DATA/sync/sync.json" ]; then
        check_failed "sync/sync.json (the links and shares) is gone"
    fi
}

USAGE="usage: install.sh [--user <name>] <path-to-release-tarball> | install.sh --rollback"
ROLLBACK=0
WANT_USER=
TARBALL=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --rollback) ROLLBACK=1 ;;
        --user)
            [ "$#" -ge 2 ] && [ -n "$2" ] || die "$USAGE"
            WANT_USER=$2
            shift
            ;;
        --user=*) WANT_USER=${1#--user=} ;;
        -*) die "$USAGE" ;;
        *)
            [ -z "$TARBALL" ] || die "$USAGE"
            TARBALL=$1
            ;;
    esac
    shift
done
if [ "$ROLLBACK" -eq 1 ]; then
    [ -z "$TARBALL" ] && [ -z "$WANT_USER" ] || die "$USAGE"
else
    [ -n "$TARBALL" ] || die "$USAGE"
    [ -f "$TARBALL" ] || die "$TARBALL is not a file"
fi
[ "$(id -u)" -eq 0 ] || die "run this as root (with sudo from your own account)"

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
    guard_before
    if runs_as_person "$PREV"; then
        # a release that runs as the person: the drop-in comes back from the record
        PERSON=$(recorded_person)
        [ -n "$PERSON" ] || die "$RECORD names no one, so there is no one to run $(basename "$PREV") as; install its tarball with --user <name> instead"
        check_person
        MIGRATE=0
        if [ "$(cat "$DROPIN" 2>/dev/null || true)" != "$(dropin_text)" ] || data_not_owned_by "$PUID"; then
            MIGRATE=1
        fi
        [ "$MIGRATE" -eq 0 ] || systemctl stop cache || true
        # current takes the previous release first, so it always points at a real folder; then previous takes the old current
        point "$OPT/current" "$PREV"
        point "$OPT/previous" "$CUR"
        mkdir -p "$UNIT.d"
        write_atomic "$DROPIN" "$(dropin_text)"
        install_unit
        [ "$MIGRATE" -eq 0 ] || chown -R "$PERSON:$PGROUP" "$DATA"
        RUNS_AS=$PERSON
        OWNER_UID=$PUID
    else
        # a release from before Cache ran as the person: back to the cache user exactly as it was (the record stays, for the next
        # update or a rollback forward)
        systemctl stop cache || true
        point "$OPT/current" "$PREV"
        point "$OPT/previous" "$CUR"
        rm -f "$DROPIN"
        rmdir "$UNIT.d" 2>/dev/null || true
        install_unit
        ensure_cache_user
        chown -R cache:cache "$DATA"
        MIGRATE=1
        RUNS_AS=cache
        OWNER_UID=$(getent passwd cache | cut -d: -f3)
    fi
    systemctl daemon-reload
    if [ "$MIGRATE" -eq 1 ]; then
        systemctl start cache
    else
        systemctl restart cache
    fi
    wait_active
    if data_not_owned_by "$OWNER_UID"; then
        check_failed "some files in $DATA do not belong to $RUNS_AS"
    fi
    guard_after
    if [ "$RUNS_AS" = cache ]; then
        echo "Rolled back: Cache $(basename "$PREV") is running, as the cache account (as that release did)."
    else
        echo "Rolled back: Cache $(basename "$PREV") is running as $RUNS_AS."
    fi
    echo "$(basename "$CUR") is now the previous release. (run install.sh --rollback again to go forward)"
    exit 0
fi

# the unit file sits next to this script (or inside the tarball, see below)
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# who Cache runs as: --user, else the account that ran sudo (doas, pkexec), else the one an earlier install recorded
RECORDED=$(recorded_person)
if [ -n "$WANT_USER" ]; then
    PERSON=$WANT_USER
elif [ -n "${SUDO_USER:-}" ]; then
    PERSON=$SUDO_USER
elif [ -n "${DOAS_USER:-}" ]; then
    PERSON=$DOAS_USER
elif [ -n "${PKEXEC_UID:-}" ]; then
    PERSON=$(getent passwd "$PKEXEC_UID" | cut -d: -f1) || true
    [ -n "$PERSON" ] || die "there is no account with the id $PKEXEC_UID"
elif [ -n "$RECORDED" ]; then
    PERSON=$RECORDED
else
    die "Run this with sudo from your own account, or pass --user <name>."
fi
check_person
# one Cache per computer: another account does not take it over without saying so
if [ -n "$RECORDED" ] && [ "$RECORDED" != "$PERSON" ] && [ -z "$WANT_USER" ]; then
    die "This Cache belongs to $RECORDED. To hand it over to $PERSON, run this again with --user $PERSON."
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
[ -x "$STAGE/cache" ] || chmod 755 "$STAGE/cache" 2>/dev/null || die "the tarball has no cache program"
[ -f "$STAGE/helper/cache-core-helper" ] || die "the tarball has no helper/cache-core-helper"
[ -f "$STAGE/lib/libcache_search.so" ] || die "the tarball has no lib/libcache_search.so"
[ -f "$STAGE/lib/libcache_llama.so" ] || die "the tarball has no lib/libcache_llama.so"
# libzim (with Xapian and ICU) sits next to the core, which finds it through its run path $ORIGIN
[ -f "$STAGE/lib/libzim.so.9" ] || die "the tarball has no lib/libzim.so.9"
# the road router (Valhalla and its C shim); the server hands the core its full path
[ -f "$STAGE/lib/libvalhalla_shim.so" ] || die "the tarball has no lib/libvalhalla_shim.so"
chown -R root:root "$STAGE"
# the service runs as the person (or, for an older release, the cache user): it must execute the program and the helper and read
# the library and the web files
chmod 755 "$STAGE/cache" "$STAGE/helper/cache-core-helper"
chmod 644 "$STAGE/lib/libcache_search.so" "$STAGE/lib/libcache_llama.so" "$STAGE/lib/libzim.so.9" "$STAGE/lib/libvalhalla_shim.so"
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

# Run as the person. When the drop-in changes (an update from a release that ran as the cache user, a hand-over) or any file in
# the data folder belongs to someone else (an interrupted run), the service is stopped first and started again after the whole
# folder is the person's: started as the person on files the cache user still owns, Cache could not read its own device key.
MIGRATE=0
if [ "$(cat "$DROPIN" 2>/dev/null || true)" != "$(dropin_text)" ] || data_not_owned_by "$PUID"; then
    MIGRATE=1
fi
guard_before
if [ "$MIGRATE" -eq 1 ] && [ -f "$UNIT" ]; then
    systemctl stop cache || true
fi
mkdir -p "$ETC" "$UNIT.d"
write_atomic "$RECORD" "$PERSON"
write_atomic "$DROPIN" "$(dropin_text)"
install_unit

# the data folder (the same place as before, now the person's), and the password on a first install
if [ -d "$DATA" ]; then
    # systemd re-owns it too, but only when the top folder's owner differs; this also covers a run cut short half way
    [ "$MIGRATE" -eq 0 ] || chown -R "$PERSON:$PGROUP" "$DATA"
else
    install -d -o "$PERSON" -g "$PGROUP" -m 0750 "$DATA"
fi
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
        printf '%s\n' "$PW1" | runuser -u "$PERSON" -- "$OPT/current/cache" set-password --data "$DATA"
    else
        printf '%s\n' "$PW1" | su -s /bin/sh "$PERSON" -c "$OPT/current/cache set-password --data $DATA"
    fi
    PW1= PW2=
fi

systemctl daemon-reload
systemctl enable cache
if [ "$MIGRATE" -eq 1 ]; then
    systemctl start cache
else
    systemctl restart cache
fi
wait_active
if data_not_owned_by "$PUID"; then
    check_failed "some files in $DATA do not belong to $PERSON"
fi
guard_after

HOST=$(hostname -f 2>/dev/null || hostname)
echo "Cache $VERSION is running. Open https://$HOST:$PORT/"
echo "Cache runs as $PERSON. It can open the folders you can open."
if [ -L "$OPT/previous" ]; then
    echo "The previous release is $(basename "$(link_of "$OPT/previous")"); to go back, run: install.sh --rollback"
fi
echo "Your library and settings are in $DATA (books you build: $DATA/app/docs/libraries, ZIM files: $DATA/app/docs/zims)."
echo "The program is in $OPT. Clearing caches never touches your library."
echo "(the certificate is self-signed, so the browser asks you to accept it once)"
echo "Sign-in is the password you chose. Security keys and key files are set up after you sign in, at https://$HOST:$PORT/settings/keys"
echo "(security keys also need a host name and a trusted certificate: see the README, --public-origin)"
echo "If you ever lose a key, reset the password by running this as yourself: $OPT/current/cache set-password --data $DATA"
