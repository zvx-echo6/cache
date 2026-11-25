#!/bin/sh
# Tests for install.sh, with no root and nothing of the real system touched: every path install.sh uses is under a fresh
# temporary root (through its CACHE_INSTALL_* variables), and the commands that would change the system (systemctl, useradd,
# groupadd, runuser, chown, install, getent, id) are stubs placed first on PATH. The stubs log their calls, and they stop the
# test if they are handed a path outside the temporary root.
#
#   sh server/packaging/test/install_test.sh            (or dash, bash)
#   SH=dash sh server/packaging/test/install_test.sh    runs install.sh with dash
#
# Needs util-linux `script` for the first-install case (install.sh asks for the password on a terminal).

set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
INSTALL_SH=$HERE/../install.sh
NEW_UNIT=$HERE/../cache.service
SH=${SH:-sh}

[ "$(id -u)" -ne 0 ] || { echo "install_test.sh: run this as a normal user, not root" >&2; exit 2; }
command -v script >/dev/null 2>&1 || { echo "install_test.sh: needs util-linux script" >&2; exit 2; }

BASE=$(mktemp -d "${TMPDIR:-/tmp}/cache-install-test.XXXXXX")
BASE=$(cd "$BASE" && pwd -P)
trap 'rm -rf "$BASE"' EXIT INT TERM
ME_UID=$(id -u)
ME_GID=$(id -g)

PASS=0
FAIL=0
FAILED=
CASE=

ok() { PASS=$((PASS + 1)); }
bad() {
    FAIL=$((FAIL + 1))
    FAILED="$FAILED
  case $CASE: $*"
    echo "  FAIL: $*"
}
check() { # check <description> <command...>
    check_what=$1
    shift
    if "$@"; then ok; else bad "$check_what"; fi
}

# ---- the stubs ----------------------------------------------------------------------------------------------------------------

make_stubs() { # make_stubs <root>
    R=$1
    mkdir -p "$R/bin" "$R/fake"
    # every stub: log the call, and refuse any absolute path outside the root
    cat >"$R/bin/_guard" <<EOF
R='$R'
log() { printf '%s\n' "\$*" >>"\$R/calls.log"; }
inside() {
    for a in "\$@"; do
        case "\$a" in
            /dev/null) ;;
            /*)
                p=\$(realpath -m -- "\$a")
                case "\$p" in "\$R" | "\$R"/*) ;; *) echo "STUB GUARD: \$p is outside the test root" >&2; echo "GUARD \$p" >>"\$R/calls.log"; exit 99 ;; esac
                ;;
        esac
    done
}
EOF
    stub() { # stub <name> <body>
        {
            echo '#!/bin/sh'
            echo ". '$R/bin/_guard'"
            printf '%s\n' "$2"
        } >"$R/bin/$1"
        chmod 755 "$R/bin/$1"
    }
    stub id 'if [ "$1" = -u ]; then echo 0; else exec /usr/bin/id "$@"; fi'
    stub systemctl '
d=absent; [ -f "$CACHE_INSTALL_UNIT.d/person.conf" ] && d=$(grep "^User=" "$CACHE_INSTALL_UNIT.d/person.conf")
log "systemctl $* [dropin $d]"
case "$1" in
    start | restart)
        if [ -n "${STUB_FLIP_IDENTITY:-}" ] && [ -f "$CACHE_INSTALL_DATA/sync/identity.key" ]; then
            printf "a new key" >"$CACHE_INSTALL_DATA/sync/identity.key"
        fi ;;
    is-active) [ -z "${STUB_INACTIVE:-}" ] || exit 3 ;;
esac
exit 0'
    stub chown 'inside "$@"; log "chown $*"'
    stub runuser 'inside "$@"; log "runuser $*"; while [ "$1" != -- ]; do shift; done; shift; exec "$@"'
    stub groupadd 'log "groupadd $*"; for n; do :; done; echo "$n:x:'"$ME_GID"':" >>"$R/fake/group"'
    stub useradd 'log "useradd $*"; for n; do :; done; echo "$n:x:'"$ME_UID"':'"$ME_GID"'::/nonexistent:/usr/sbin/nologin" >>"$R/fake/passwd"'
    # install: the real one, without -o/-g (which need root)
    stub install '
inside "$@"; log "install $*"
set -- "$@" --end; skip=
for a; do
    if [ "$a" = --end ]; then break; fi
    if [ -n "$skip" ]; then skip=; continue; fi
    case "$a" in -o | -g) skip=1; continue ;; esac
    set -- "$@" "$a"
done
while [ "$1" != --end ]; do shift; done; shift
exec /usr/bin/install "$@"'
    # getent passwd|group <name or id>, from the fake files
    stub getent '
f=$R/fake/$1; [ -f "$f" ] || exit 2
awk -F: -v k="$2" "\$1 == k || \$3 == k { print; found = 1; exit } END { exit found ? 0 : 2 }" "$f"'
}

# ---- a test root --------------------------------------------------------------------------------------------------------------

# new_root <name>: a fresh root with the stubs, a fake passwd (alice and bob are people, root, and the system account cache) and
# a login.defs; sets R and the CACHE_INSTALL_* paths
new_root() {
    R=$BASE/$1
    mkdir -p "$R"
    make_stubs "$R"
    mkdir -p "$R/home/alice" "$R/home/bob"
    cat >"$R/fake/passwd" <<EOF
root:x:0:0:root:/root:/bin/sh
cache:x:$ME_UID:$ME_GID::/nonexistent:/usr/sbin/nologin
alice:x:$ME_UID:$ME_GID::$R/home/alice:/bin/sh
bob:x:$ME_UID:$ME_GID::$R/home/bob:/bin/sh
nobody:x:65534:65534::/nonexistent:/usr/sbin/nologin
EOF
    cat >"$R/fake/group" <<EOF
root:x:0:
alice:x:$ME_GID:
EOF
    mindef=1000
    [ "$ME_UID" -ge 1000 ] || mindef=$ME_UID
    printf 'UID_MIN\t\t\t%s\n' "$mindef" >"$R/fake/login.defs"
    CACHE_INSTALL_OPT=$R/opt/cache-app
    CACHE_INSTALL_DATA=$R/var/lib/cache-app
    CACHE_INSTALL_UNIT=$R/etc/systemd/system/cache.service
    CACHE_INSTALL_ETC=$R/etc/cache-app
    CACHE_INSTALL_LOGIN_DEFS=$R/fake/login.defs
    export CACHE_INSTALL_OPT CACHE_INSTALL_DATA CACHE_INSTALL_UNIT CACHE_INSTALL_ETC CACHE_INSTALL_LOGIN_DEFS
    for p in "$CACHE_INSTALL_OPT" "$CACHE_INSTALL_DATA" "$CACHE_INSTALL_UNIT" "$CACHE_INSTALL_ETC" "$CACHE_INSTALL_LOGIN_DEFS"; do
        case $(realpath -m -- "$p") in "$R"/*) ;; *) echo "install_test.sh: $p is outside the test root" >&2; exit 2 ;; esac
    done
    mkdir -p "$(dirname "$CACHE_INSTALL_UNIT")"
    : >"$R/calls.log"
}

# a release tarball <file> of version <version> whose cache.service is <unit file>
make_tarball() {
    t=$R/build/$2
    mkdir -p "$t/helper" "$t/lib" "$t/web"
    cat >"$t/cache" <<'EOF'
#!/bin/sh
# a stand-in for the program: set-password writes auth.json
[ "$1" = set-password ] || exit 0
read -r pw
printf '{"hash":"%s"}\n' "$(printf %s "$pw" | sha256sum | cut -c1-16)" >"$3/auth.json"
EOF
    chmod 755 "$t/cache"
    : >"$t/helper/cache-core-helper"
    for l in libcache_search.so libcache_llama.so libzim.so.9 libvalhalla_shim.so; do : >"$t/lib/$l"; done
    echo '<html></html>' >"$t/web/index.html"
    echo "$2" >"$t/VERSION"
    cp "$3" "$t/cache.service"
    cp "$INSTALL_SH" "$t/install.sh"
    tar -czf "$1" -C "$t" .
}

# the unit of a release from before this change: runs as the cache user, no marker
old_unit() {
    cat >"$1" <<'EOF'
[Unit]
Description=Cache for Linux

[Service]
User=cache
Group=cache
ExecStart=/opt/cache-app/current/cache serve --data /var/lib/cache-app
StateDirectory=cache-app
StateDirectoryMode=0750
ProtectSystem=strict
ProtectHome=yes

[Install]
WantedBy=multi-user.target
EOF
}

# an install from before this change: release 0.1.0+old current, its unit installed, data owned by cache, a linked device
old_layout() {
    old_unit "$R/old.service"
    rel=$CACHE_INSTALL_OPT/releases/0.1.0+old
    mkdir -p "$rel"
    cp "$R/old.service" "$rel/cache.service"
    cp "$INSTALL_SH" "$rel/install.sh"
    ln -s "$rel" "$CACHE_INSTALL_OPT/current"
    cp "$R/old.service" "$CACHE_INSTALL_UNIT"
    mkdir -p "$CACHE_INSTALL_DATA/sync" "$CACHE_INSTALL_DATA/tls"
    echo '{"hash":"old"}' >"$CACHE_INSTALL_DATA/auth.json"
    printf 'the device key' >"$CACHE_INSTALL_DATA/sync/identity.key"
    echo '{"peers":[],"shares":[]}' >"$CACHE_INSTALL_DATA/sync/sync.json"
    echo 'cert' >"$CACHE_INSTALL_DATA/tls/cert.pem"
}

with_sudo() { # with_sudo <account> <command...>: as if run through sudo by <account>
    SUDO_USER=$1
    export SUDO_USER
    shift
    "$@"
    unset SUDO_USER
}
# An install.sh that does not take its paths from CACHE_INSTALL_* would work on the real /opt, /var/lib and /etc: never run it.
takes_test_paths() {
    for v in OPT DATA UNIT ETC LOGIN_DEFS; do grep -q "\${CACHE_INSTALL_$v:-" "$INSTALL_SH" || return 1; done
}
refuse_unsafe() {
    takes_test_paths && return 1
    RC=97
    OUT="(not run: install.sh does not take its paths from CACHE_INSTALL_*, so it would change the real system)"
}
# run install.sh; OUT holds stdout and stderr, RC the exit status
run() {
    refuse_unsafe && return 0
    : >"$R/out"
    set +e
    PATH="$R/bin:$PATH" "$SH" "$INSTALL_SH" "$@" >"$R/out" 2>&1
    RC=$?
    set -e
    OUT=$(cat "$R/out")
}
# the same on a terminal, typing the password twice (a first install asks for it)
run_tty() {
    refuse_unsafe && return 0
    : >"$R/out"
    q=
    for a; do q="$q '$a'"; done
    set +e
    printf 'pw1\npw1\n' | PATH="$R/bin:$PATH" script -qec "$SH '$INSTALL_SH' $q" /dev/null >"$R/out" 2>&1
    RC=$?
    set -e
    OUT=$(cat "$R/out")
}

has() { printf '%s\n' "$OUT" | grep -q -- "$1"; }
logged() { grep -q -- "$1" "$R/calls.log"; }
not_logged() { ! grep -q -- "$1" "$R/calls.log"; }
# line number of the first log line matching <pattern> (0 when none)
at() { n=$(grep -n -- "$1" "$R/calls.log" | head -n 1 | cut -d: -f1); echo "${n:-0}"; }
before() { a=$(at "$1"); b=$(at "$2"); [ "$a" -gt 0 ] && [ "$b" -gt 0 ] && [ "$a" -lt "$b" ]; }
dropin() { cat "$CACHE_INSTALL_UNIT.d/person.conf" 2>/dev/null || true; }
dropin_names() { d=$(dropin); printf '%s\n' "$d" | grep -qx "User=$1" && printf '%s\n' "$d" | grep -qx "Group=$2"; }
record() { cat "$CACHE_INSTALL_ETC/person" 2>/dev/null || true; }
rc_ok() { [ "$RC" -eq 0 ]; }
rc_fail() { [ "$RC" -ne 0 ]; }
no_server_word() { ! printf '%s\n' "$OUT" | grep -qi server; }
no_guard_hit() { not_logged '^GUARD'; }
nothing_changed() { [ ! -e "$CACHE_INSTALL_OPT" ] && [ ! -e "$CACHE_INSTALL_DATA" ] && not_logged '^systemctl'; }
show() { printf '%s\n' "$OUT" | sed 's/^/    | /'; }

start_case() {
    CASE=$1
    echo "case $1: $2"
    new_root "case$1"
    unset SUDO_USER DOAS_USER PKEXEC_UID STUB_FLIP_IDENTITY STUB_INACTIVE 2>/dev/null || true
}
end_case() {
    check "no stub was handed a path outside the test root" no_guard_hit
    check "the person never reads the word server" no_server_word
    [ "$FAIL" -eq "$1" ] || show
}

# ---- the cases ----------------------------------------------------------------------------------------------------------------

f0=$FAIL
start_case 1 "a first install run with sudo by alice"
make_tarball "$R/new.tgz" 0.1.0+new "$NEW_UNIT"
with_sudo alice run_tty "$R/new.tgz"
check "it succeeds (exit $RC)" rc_ok
check "the drop-in names alice" dropin_names alice alice
check "/etc/cache-app/person names alice" [ "$(record)" = alice ]
check "no system user is made" not_logged '^useradd'
check "no system group is made" not_logged '^groupadd'
check "the data folder is made for alice" logged "^install -d -o alice -g alice -m 0750 $CACHE_INSTALL_DATA"
check "the password is set as alice" logged "^runuser -u alice -- $CACHE_INSTALL_OPT/current/cache set-password --data $CACHE_INSTALL_DATA"
check "the password was written" [ -f "$CACHE_INSTALL_DATA/auth.json" ]
check "the unit is installed from the release" cmp -s "$NEW_UNIT" "$CACHE_INSTALL_UNIT"
check "the service is enabled and started with the drop-in in place" logged '^systemctl \(start\|restart\) cache \[dropin User=alice\]'
check "it says whose account Cache runs as" has 'Cache runs as alice'
end_case "$f0"

f0=$FAIL
start_case 2 "no sudo account and no --user"
make_tarball "$R/new.tgz" 0.1.0+new "$NEW_UNIT"
run "$R/new.tgz"
check "it is refused" rc_fail
check "it says how to run it" has 'Run this with sudo from your own account, or pass --user <name>.'
check "nothing is installed and no service command runs" nothing_changed
end_case "$f0"

f0=$FAIL
start_case 3 "--user root"
make_tarball "$R/new.tgz" 0.1.0+new "$NEW_UNIT"
with_sudo alice run --user root "$R/new.tgz"
check "it is refused" rc_fail
check "it says Cache does not run as root" has 'root'
check "nothing is installed and no service command runs" nothing_changed
# and the other accounts it refuses: the system account cache, a system uid, one with no home folder, one that does not exist
for who in cache nobody nosuch; do
    run --user "$who" "$R/new.tgz"
    check "--user $who is refused" rc_fail
    check "--user $who installs nothing" nothing_changed
done
rmdir "$R/home/bob"
run --user bob "$R/new.tgz"
check "an account with no home folder is refused" rc_fail
check "it says the home folder is missing" has 'home folder'
end_case "$f0"

f0=$FAIL
start_case 4 "an upgrade from an install that runs as the cache user"
old_layout
make_tarball "$R/new.tgz" 0.1.0+new "$NEW_UNIT"
with_sudo alice run "$R/new.tgz"
check "it succeeds (exit $RC)" rc_ok
check "the drop-in names alice" dropin_names alice alice
check "/etc/cache-app/person names alice" [ "$(record)" = alice ]
check "the service is stopped before the drop-in is written" logged '^systemctl stop cache \[dropin absent\]'
check "then the data is given to alice" before '^systemctl stop cache' "^chown -R alice:alice $CACHE_INSTALL_DATA\$"
check "then the service starts, with the drop-in" before "^chown -R alice:alice $CACHE_INSTALL_DATA\$" '^systemctl start cache \[dropin User=alice\]'
check "no system user is made" not_logged '^useradd'
check "no password is asked" not_logged '^runuser'
check "the old release is kept as previous" [ "$(readlink "$CACHE_INSTALL_OPT/previous")" = "$CACHE_INSTALL_OPT/releases/0.1.0+old" ]
check "the new unit is installed" cmp -s "$NEW_UNIT" "$CACHE_INSTALL_UNIT"
check "the linked device's key is untouched" [ "$(cat "$CACHE_INSTALL_DATA/sync/identity.key")" = 'the device key' ]
check "it says whose account Cache runs as" has 'Cache runs as alice'
end_case "$f0"

f0=$FAIL
start_case 5 "the same install run again"
old_layout
make_tarball "$R/new.tgz" 0.1.0+new "$NEW_UNIT"
with_sudo alice run "$R/new.tgz"
cp "$CACHE_INSTALL_UNIT.d/person.conf" "$R/dropin.before" 2>/dev/null || : >"$R/dropin.before"
: >"$R/calls.log"
with_sudo alice run "$R/new.tgz"
check "it succeeds (exit $RC)" rc_ok
check "the service is restarted" logged '^systemctl restart cache \[dropin User=alice\]'
check "it is not stopped" not_logged '^systemctl stop'
check "the data is not handed over again" not_logged "^chown -R alice:alice $CACHE_INSTALL_DATA"
check "the drop-in is the same" cmp -s "$R/dropin.before" "$CACHE_INSTALL_UNIT.d/person.conf"
# an upgrade run as root with no sudo (su -) finds the person in the record
: >"$R/calls.log"
run "$R/new.tgz"
check "with no sudo account the record names the person" rc_ok
check "and the drop-in still names alice" dropin_names alice alice
end_case "$f0"

f0=$FAIL
start_case 8 "an upgrade run by a second account"
old_layout
make_tarball "$R/new.tgz" 0.1.0+new "$NEW_UNIT"
with_sudo alice run "$R/new.tgz"
cp "$CACHE_INSTALL_UNIT.d/person.conf" "$R/dropin.before" 2>/dev/null || : >"$R/dropin.before"
: >"$R/calls.log"
with_sudo bob run "$R/new.tgz"
check "it is refused" rc_fail
check "it names the owner" has 'alice'
check "it offers --user to hand it over" has '--user bob'
check "the record still names alice" [ "$(record)" = alice ]
check "the drop-in is unchanged" cmp -s "$R/dropin.before" "$CACHE_INSTALL_UNIT.d/person.conf"
check "no service command runs" not_logged '^systemctl'
# handing it over with --user is allowed
with_sudo bob run --user bob "$R/new.tgz"
check "--user bob hands it over" rc_ok
check "the record then names bob" [ "$(record)" = bob ]
check "the drop-in then names bob" dropin_names bob alice
end_case "$f0"

f0=$FAIL
start_case 6 "--rollback to a release that runs as the cache user"
old_layout
make_tarball "$R/new.tgz" 0.1.0+new "$NEW_UNIT"
with_sudo alice run "$R/new.tgz"
# a computer that never had the cache account (or lost it): the rollback makes it again
grep -v '^cache:' "$R/fake/passwd" >"$R/fake/p" && mv "$R/fake/p" "$R/fake/passwd"
: >"$R/calls.log"
run --rollback
check "it succeeds (exit $RC)" rc_ok
check "the old release is current" [ "$(readlink "$CACHE_INSTALL_OPT/current")" = "$CACHE_INSTALL_OPT/releases/0.1.0+old" ]
check "the drop-in is removed" [ ! -e "$CACHE_INSTALL_UNIT.d/person.conf" ]
check "the record is kept" [ "$(record)" = alice ]
check "the old unit is installed" cmp -s "$R/old.service" "$CACHE_INSTALL_UNIT"
check "the cache group is made" logged '^groupadd --system cache'
check "the cache user is made, as before" logged '^useradd --system --gid cache --no-create-home --home-dir /nonexistent --shell .* cache$'
check "the service is stopped first" before '^systemctl stop cache' "^chown -R cache:cache $CACHE_INSTALL_DATA\$"
check "the data goes back to cache, then the service starts without the drop-in" \
    before "^chown -R cache:cache $CACHE_INSTALL_DATA\$" '^systemctl \(start\|restart\) cache \[dropin absent\]'
check "the user is made before the data is given to it" before '^useradd' "^chown -R cache:cache $CACHE_INSTALL_DATA\$"
check "the linked device's key is untouched" [ "$(cat "$CACHE_INSTALL_DATA/sync/identity.key")" = 'the device key' ]
end_case "$f0"

f0=$FAIL
start_case 7 "--rollback again, forward to the release that runs as the person"
old_layout
make_tarball "$R/new.tgz" 0.1.0+new "$NEW_UNIT"
with_sudo alice run "$R/new.tgz"
run --rollback
: >"$R/calls.log"
run --rollback
check "it succeeds (exit $RC)" rc_ok
check "the new release is current" [ "$(readlink "$CACHE_INSTALL_OPT/current")" = "$CACHE_INSTALL_OPT/releases/0.1.0+new" ]
check "the drop-in is back, from /etc/cache-app/person" dropin_names alice alice
check "the new unit is installed" cmp -s "$NEW_UNIT" "$CACHE_INSTALL_UNIT"
check "the service is stopped before the drop-in comes back" logged '^systemctl stop cache \[dropin absent\]'
check "the data goes to alice, then the service starts with the drop-in" \
    before "^chown -R alice:alice $CACHE_INSTALL_DATA\$" '^systemctl \(start\|restart\) cache \[dropin User=alice\]'
check "no account is made" not_logged '^useradd'
# with no record, a rollback to a release that runs as the person has no one to run as: refused, nothing switched
rm -f "$CACHE_INSTALL_ETC/person"
run --rollback
run --rollback
check "with no record it is refused" rc_fail
check "and nothing is switched" [ "$(readlink "$CACHE_INSTALL_OPT/current")" = "$CACHE_INSTALL_OPT/releases/0.1.0+old" ]
end_case "$f0"

f0=$FAIL
start_case 9 "the identity guard: the device key changes while Cache starts"
old_layout
make_tarball "$R/new.tgz" 0.1.0+new "$NEW_UNIT"
STUB_FLIP_IDENTITY=1
export STUB_FLIP_IDENTITY
with_sudo alice run "$R/new.tgz"
check "the update fails" rc_fail
check "it names the check that failed" has 'check failed: sync/identity.key'
check "it says how to go back" has 'install.sh --rollback'
check "Cache is stopped after the start" before '^systemctl start cache' '^systemctl stop cache \[dropin User=alice\]'
check "the key itself is never printed" eval '! has "a new key" && ! has "the device key"'
# the same guard on a rollback
printf 'the device key' >"$CACHE_INSTALL_DATA/sync/identity.key"
: >"$R/calls.log"
run --rollback
check "a rollback fails the same way" rc_fail
check "and names the check" has 'check failed: sync/identity.key'
check "and stops Cache" before '^systemctl start cache' '^systemctl stop cache \[dropin absent\]'
# with the key left alone the guard is quiet
unset STUB_FLIP_IDENTITY
printf 'the device key' >"$CACHE_INSTALL_DATA/sync/identity.key"
run --rollback
check "with the key unchanged a rollback succeeds (exit $RC)" rc_ok
end_case "$f0"

echo
echo "install_test.sh: $PASS passed, $FAIL failed (install.sh run with $SH)"
if [ "$FAIL" -ne 0 ]; then
    echo "failed:$FAILED"
    exit 1
fi
