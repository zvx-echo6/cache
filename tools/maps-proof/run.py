#!/usr/bin/env python3
"""Maps two-writer proof: drives real device processes (test/mapsproof/device.dart) through cmd/res files.

Usage: run.py <scenario> [...]
  before-collide   A and B on new/ (rel-1.1 before the fix): each downloads a different region, Maps shared both ways. The bug:
                   conflict copies of the live stores, one device's region gone. (Expected to fail a good run: it must show the bug.)
  fix-union        A and B on fix/: both list and read both regions, no conflict file, each device's own tiles served from its own store.
  fix-delete       fix-union, then A deletes its region (B loses it, tiles and area), then A downloads it again (both have it again).
  fix-recover      A and B on new/ collide as in before-collide, then are updated to fix/ one data folder at a time: the conflict copies
                   are taken back in (each device keeps its own region and area), and the union forms.
  fix-mixed        A on fix/ and C on new/ (an old build): nothing of C's live databases is fetched by A, none of A's is sent to C.
Layout under P=~/proof/mapsproof: new/ and fix/ checkouts (app/test/mapsproof/device.dart copied in), lib-new/ and lib-fix/ (the built
libcache_search.so of each), work/<scenario>/<device>/, evidence/<scenario>/, logs/.
"""
import json, math, os, shutil, signal, subprocess, sys, time

P = os.path.expanduser('~/proof/mapsproof')
CPUS = os.environ.get('CPUS', '0-3')
LIBZIM = os.path.expanduser('~/.cache/cache-ci-libzim/libzim/linux-x86_64-9.8.2-1')

IDAHO = {'id': 'idaho-box', 'name': 'Idaho box', 'bbox': [-114.50, 42.50, -114.40, 42.60]}
ANGUILLA = {'id': 'anguilla-box', 'name': 'Anguilla box', 'bbox': [-63.20, 18.15, -63.00, 18.28]}
Z = 6


def tile_of(lon, lat, z=Z):
    n = 2 ** z
    x = int((lon + 180.0) / 360.0 * n)
    r = math.radians(lat)
    y = int((1.0 - math.asinh(math.tan(r)) / math.pi) / 2.0 * n)
    return f'{z}/{x}/{y}'


def tile_for(region):
    b = region['bbox']
    return tile_of((b[0] + b[2]) / 2, (b[1] + b[3]) / 2)


started = []
failures = []


def say(s):
    line = f'{time.strftime("%H:%M:%S")} {s}'
    print(line, flush=True)
    os.makedirs(f'{P}/logs', exist_ok=True)
    with open(f'{P}/logs/run.log', 'a') as f:
        f.write(line + '\n')


def check(cond, what):
    say(('ok   ' if cond else 'FAIL ') + what)
    if not cond:
        failures.append(what)
    return cond


def free_gb():
    for l in open('/proc/meminfo'):
        if l.startswith('MemAvailable:'):
            return int(l.split()[1]) / 1048576
    return 0


def disk_gb():
    s = os.statvfs(P)
    return s.f_bavail * s.f_frsize / 1e9


def floors():
    for _ in range(40):
        if free_gb() >= 2 and disk_gb() >= 5:
            return
        say(f'floor: {free_gb():.1f} GB memory, {disk_gb():.0f} GB disk; waiting')
        time.sleep(15)
    raise SystemExit('floors not met')


class Dev:
    def __init__(self, scen, name, build, port):
        self.name, self.build, self.port, self.scen = name, build, port, scen
        self.dir = f'{P}/work/{scen}/{name}'
        self.seq = 0
        self.proc = None

    def start(self):
        floors()
        os.makedirs(self.dir, exist_ok=True)
        for sub in ('cmd', 'res'):
            shutil.rmtree(f'{self.dir}/{sub}', ignore_errors=True)
        if os.path.exists(f'{self.dir}/ready.json'):
            os.remove(f'{self.dir}/ready.json')
        src = f'{P}/{self.build}'
        lib = f'{P}/lib-{self.build}'
        zim = os.path.dirname([os.path.join(r, f) for r, _, fs in os.walk(f'{LIBZIM}/lib') for f in fs if f == 'libzim.so'][0])
        env = dict(os.environ)
        env.update({
            'PROOF_DIR': self.dir, 'PROOF_PORT': str(self.port), 'PROOF_NAME': self.name,
            'PROOF_FIXED': '1' if self.build == 'fix' else '0',
            'LD_LIBRARY_PATH': f'{lib}:{zim}',
        })
        log = open(f'{P}/logs/{self.scen}-{self.name}-{self.build}.log', 'a')
        say(f'start {self.name} ({self.build}) port {self.port}')
        self.proc = subprocess.Popen(['taskset', '-c', CPUS, 'nice', '-n', '10', os.path.expanduser('~/flutter/bin/flutter'), 'test', '--no-pub', '--timeout', 'none', 'test/mapsproof/device.dart'],
                                     cwd=f'{src}/app', env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        started.append(self.proc)
        end = time.time() + 900
        while not os.path.exists(f'{self.dir}/ready.json'):
            if self.proc.poll() is not None:
                raise SystemExit(f'{self.name} exited before ready (see logs)')
            if time.time() > end:
                raise SystemExit(f'{self.name} not ready in 15 min')
            time.sleep(1)
        say(f'{self.name} ready')

    def send(self, op, args=None):
        self.seq += 1
        n = f'{self.seq:04d}.json'
        os.makedirs(f'{self.dir}/cmd', exist_ok=True)
        with open(f'{self.dir}/cmd/{n}.tmp', 'w') as f:
            json.dump({'op': op, 'args': args or {}}, f)
        os.rename(f'{self.dir}/cmd/{n}.tmp', f'{self.dir}/cmd/{n}')
        return n

    def wait(self, n, op, timeout=900):
        end = time.time() + timeout
        r = f'{self.dir}/res/{n}'
        while not os.path.exists(r):
            if self.proc and self.proc.poll() is not None:
                raise SystemExit(f'{self.name} died during {op}')
            if time.time() > end:
                raise SystemExit(f'{self.name} {op} timed out')
            time.sleep(0.25)
        j = json.load(open(r))
        if not j.get('ok'):
            raise SystemExit(f'{self.name} {op} failed: {j.get("error")}')
        return j['result']

    def call(self, op, args=None, timeout=900):
        say(f'{self.name}: {op} {json.dumps(args)[:80] if args else ""}')
        res = self.wait(self.send(op, args), op, timeout)
        say(f'{self.name}: {op} -> {json.dumps(res)[:240]}')
        return res

    def restart(self, build):
        """The app updated: a clean stop, then the same data folder on another build."""
        self.stop()
        self.build = build
        self.seq = 0
        self.start()

    def stop(self):
        if self.proc and self.proc.poll() is None:
            try:
                self.call('quit', timeout=60)
            except SystemExit as e:
                say(f'{self.name} quit: {e}')
            try:
                self.proc.wait(60)
            except subprocess.TimeoutExpired:
                os.killpg(self.proc.pid, signal.SIGKILL)


def link(a, b):
    a.call('sharing_setup')
    b.call('sharing_setup')
    code = a.call('link_code')['code']
    b.call('link', {'code': code})
    time.sleep(3)
    a.call('share_maps')
    b.call('share_maps')


def rounds(ds, n=3):
    for _ in range(n):
        for d in ds:
            d.call('sync', {'rounds': 1})


def save(ev, stage, d, data):
    os.makedirs(f'{ev}/{stage}', exist_ok=True)
    with open(f'{ev}/{stage}/{d.name}.json', 'w') as f:
        json.dump(data, f, indent=1)


def snapshots(dump):
    return [f for f in dump['layers_files'] if f.startswith('store-share/basemap/') and f.split(' ')[0].endswith('.sqlite')]


def settle(ds, tiles, want=2, tries=15):
    """Sync rounds until every device holds the snapshots of every device (a snapshot is written 20 s after a store goes quiet)."""
    for _ in range(tries):
        rounds(ds, 1)
        time.sleep(12)
        dumps = [d.call('dump', {'tiles': tiles}) for d in ds]
        if all(len(snapshots(x)) >= want for x in dumps):
            return
    say('settle: the snapshots did not all arrive')
    for d in ds:
        d.call('status')


def regions_of(dump):
    return {r['id']: r for r in dump['regions']}


def new_devices(scen, builds):
    base = 41000 + (sum(map(ord, scen)) % 500) * 2
    shutil.rmtree(f'{P}/work/{scen}', ignore_errors=True)
    return [Dev(scen, n, b, base + i) for i, (n, b) in enumerate(builds)]


def stop_all(ds):
    for d in ds:
        d.stop()


# ---- scenarios ----

def collide(scen, builds):
    ev = f'{P}/evidence/{scen}'
    shutil.rmtree(ev, ignore_errors=True)
    a, b = new_devices(scen, builds)
    try:
        a.start()
        b.start()
        a.call('add_region', IDAHO)
        b.call('add_region', ANGUILLA)
        link(a, b)
        rounds([a, b], 4)
        tiles = [tile_for(IDAHO), tile_for(ANGUILLA)]
        if builds[0][1] == 'fix':
            settle([a, b], tiles)
        da, db = a.call('dump', {'tiles': tiles}), b.call('dump', {'tiles': tiles})
        save(ev, 'after-sync', a, da)
        save(ev, 'after-sync', b, db)
        return a, b, da, db
    except BaseException:
        stop_all([a, b])
        raise


def own_and_peer_ok(d, dump, own, peer, who, peer_who):
    ids = regions_of(dump)
    check(own['id'] in ids and peer['id'] in ids, f'{who} lists both regions: {sorted(ids)}')
    for rid, r in ids.items():
        check(r['phase'] == 'ready' and not r['error'], f'{who}: region {rid} is ready ({r["phase"]}, error {r["error"]})')
    t = dump['tiles']
    mine, theirs = t[tile_for(own)], t[tile_for(peer)]
    check(mine.get('status') == 200 and mine.get('from') == 'downloaded' and (mine.get('body') or '').startswith(who), f'{who} draws its own region from its own store: {mine}')
    check(theirs.get('status') == 200 and theirs.get('from') == 'downloaded' and (theirs.get('body') or '').startswith(peer_who), f'{who} draws {peer_who}\'s region from the copy {peer_who} shared: {theirs}')
    check(not dump['conflict_files'], f'{who}: no conflict file: {dump["conflict_files"]}')


def before_collide():
    a, b, da, db = collide('before-collide', [('A', 'new'), ('B', 'new')])
    try:
        bug = bool(da['conflict_files'] or db['conflict_files'])
        check(bug, f'THE BUG shows on the build before the fix: conflict copies A {da["conflict_files"]} B {db["conflict_files"]}')
        say(f'regions each lists (before the fix): A {sorted(regions_of(da))} B {sorted(regions_of(db))}')
    finally:
        stop_all([a, b])


def fix_union():
    a, b, da, db = collide('fix-union', [('A', 'fix'), ('B', 'fix')])
    try:
        own_and_peer_ok(a, da, IDAHO, ANGUILLA, 'A', 'B')
        own_and_peer_ok(b, db, ANGUILLA, IDAHO, 'B', 'A')
        for who, d in (('A', da), ('B', db)):
            snaps = [f for f in d['layers_files'] if f.startswith('store-share/basemap/') and f.split(' ')[0].endswith('.sqlite')]
            check(len(snaps) == 2, f'{who}: its own snapshot and the other device\'s are in store-share/basemap: {snaps}')
            check(any(f.startswith('store/basemap.sqlite') for f in d['layers_files']), f'{who} keeps its own live store')
            check(any(f.startswith('regions-share/') for f in d['regions_files']), f'{who}: regions-share has the lists: {d["regions_files"]}')
    finally:
        stop_all([a, b])


def fix_delete():
    ev = f'{P}/evidence/fix-delete'
    a, b, da, db = collide('fix-delete', [('A', 'fix'), ('B', 'fix')])
    try:
        own_and_peer_ok(a, da, IDAHO, ANGUILLA, 'A', 'B')
        own_and_peer_ok(b, db, ANGUILLA, IDAHO, 'B', 'A')
        tiles = [tile_for(IDAHO), tile_for(ANGUILLA)]
        say('A deletes its region: it is deleted on every linked device that shares Maps')
        a.call('delete_region', {'id': IDAHO['id']})
        # the list and the area go at once; the tiles of A's old snapshot are read until A's new snapshot (written once its store has been
        # quiet 20 s) arrives
        for _ in range(12):
            rounds([a, b], 1)
            time.sleep(10)
            da, db = a.call('dump', {'tiles': tiles}), b.call('dump', {'tiles': tiles})
            if db['tiles'][tile_for(IDAHO)].get('from') != 'downloaded' and da['tiles'][tile_for(IDAHO)].get('from') != 'downloaded':
                break
        save(ev, 'after-delete', a, da)
        save(ev, 'after-delete', b, db)
        for who, d in (('A', da), ('B', db)):
            check(IDAHO['id'] not in regions_of(d), f'{who}: the deleted region is gone from the list: {sorted(regions_of(d))}')
            check(ANGUILLA['id'] in regions_of(d), f'{who}: the other region stays')
            check(all(IDAHO['name'] != x['label'] for x in d['areas']), f'{who}: its map area is gone: {d["areas"]}')
            t = d['tiles'][tile_for(IDAHO)]
            check(t.get('from') != 'downloaded', f'{who}: its tile is no longer served from a download: {t}')
        say('A downloads it again: newer than the delete, it comes back on both')
        a.call('add_region', IDAHO)
        for _ in range(12):
            rounds([a, b], 1)
            time.sleep(10)
            da, db = a.call('dump', {'tiles': tiles}), b.call('dump', {'tiles': tiles})
            if db['tiles'][tile_for(IDAHO)].get('from') == 'downloaded' and IDAHO['id'] in regions_of(db):
                break
        save(ev, 'after-redownload', a, da)
        save(ev, 'after-redownload', b, db)
        own_and_peer_ok(a, da, IDAHO, ANGUILLA, 'A', 'B')
        own_and_peer_ok(b, db, ANGUILLA, IDAHO, 'B', 'A')
    finally:
        stop_all([a, b])


def fix_recover():
    ev = f'{P}/evidence/fix-recover'
    a, b, da, db = collide('fix-recover', [('A', 'new'), ('B', 'new')])
    try:
        check(bool(da['conflict_files'] or db['conflict_files']), f'the old build collided as before: A {da["conflict_files"]} B {db["conflict_files"]}')
        say('the app updates: both devices restart on the fix, one at a time, on the same data')
        a.restart('fix')
        b.restart('fix')
        a.call('sharing_setup')
        b.call('sharing_setup')
        time.sleep(15)
        tiles = [tile_for(IDAHO), tile_for(ANGUILLA)]
        rounds([a, b], 4)
        settle([a, b], tiles)
        da, db = a.call('dump', {'tiles': tiles}), b.call('dump', {'tiles': tiles})
        save(ev, 'after-update', a, da)
        save(ev, 'after-update', b, db)
        for who, d, own in (('A', da, IDAHO), ('B', db, ANGUILLA)):
            check(not d['conflict_files'], f'{who}: the conflict copies are taken back in and deleted: {d["conflict_files"]}')
            ids = regions_of(d)
            check(own['id'] in ids and ids[own['id']]['phase'] == 'ready', f'{who} still has its own region, ready (the old build\'s collision can also cost an area record; the tiles stay): {ids.get(own["id"])}')
            t = d['tiles'][tile_for(own)]
            check(t.get('from') == 'downloaded' and (t.get('body') or '').startswith(who), f'{who} draws its own region from its own tiles: {t}')
        own_and_peer_ok(a, da, IDAHO, ANGUILLA, 'A', 'B')
        own_and_peer_ok(b, db, ANGUILLA, IDAHO, 'B', 'A')
    finally:
        stop_all([a, b])


def fix_mixed():
    ev = f'{P}/evidence/fix-mixed'
    shutil.rmtree(ev, ignore_errors=True)
    a, c = new_devices('fix-mixed', [('A', 'fix'), ('C', 'new')])
    try:
        a.start()
        c.start()
        a.call('add_region', IDAHO)
        c.call('add_region', ANGUILLA)
        link(a, c)
        rounds([a, c], 4)
        tiles = [tile_for(IDAHO), tile_for(ANGUILLA)]
        da, dc = a.call('dump', {'tiles': tiles}), c.call('dump', {'tiles': tiles})
        save(ev, 'after-sync', a, da)
        save(ev, 'after-sync', c, dc)
        check(not da['conflict_files'], f'A (the fix) has no conflict copy: {da["conflict_files"]}')
        check(IDAHO['id'] in regions_of(da) and regions_of(da)[IDAHO['id']]['phase'] == 'ready', 'A keeps and draws its own region')
        check(da['tiles'][tile_for(IDAHO)].get('body', '').startswith('A'), f'A draws its own region from its own store: {da["tiles"][tile_for(IDAHO)]}')
        check(not any(f.startswith('store/') and 'conflict' in f for f in da['layers_files']), 'A has no conflict copy of its live store')
        check(ANGUILLA['id'] not in regions_of(da), 'A does not take the old build\'s live database as its own (the old build\'s region is not listed: accepted)')
        check(not dc['conflict_files'], f'C (the old build) got nothing of A\'s live files, so no conflict copy: {dc["conflict_files"]}')
        check(ANGUILLA['id'] in regions_of(dc) and regions_of(dc)[ANGUILLA['id']]['phase'] == 'ready', 'C keeps its own region')
    finally:
        stop_all([a, c])


SCENARIOS = {'before-collide': before_collide, 'fix-union': fix_union, 'fix-delete': fix_delete, 'fix-recover': fix_recover, 'fix-mixed': fix_mixed}

if __name__ == '__main__':
    names = sys.argv[1:] or list(SCENARIOS)
    for n in names:
        say(f'=== {n}')
        failures.clear()
        try:
            SCENARIOS[n]()
        finally:
            for p in started:
                if p.poll() is None:
                    try:
                        os.killpg(p.pid, signal.SIGKILL)
                    except Exception:
                        pass
        say(f'=== {n}: {"PASS" if not failures else "FAIL (" + str(len(failures)) + ")"}')
        for f in failures:
            say(f'    - {f}')
        if failures and n != 'before-collide':
            sys.exit(1)
