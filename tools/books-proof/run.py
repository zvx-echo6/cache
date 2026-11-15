#!/usr/bin/env python3
"""My books two-writer proof: drives real device processes (test/booksproof/device.dart) through cmd/res files.

Usage: run.py <scenario> [...]
  before-fix runs (A and B on new/): apart, midflight, b51 (B on b51/)
  fixed runs (fix/books-own-shard in fix/): fix-apart, fix-midflight, fix-b51 (B on b51/), fix-recover (apart on new/, then
  both devices updated to fix/ one at a time); delete scenarios on fix/: del-apart, del-keep, del-readd, del-rule3
Layout under P=~/proof/booksbug: new/, fix/ and b51/ checkouts, work/<scenario>/<device>/, evidence/<scenario>/, logs/.
"""
import json, os, subprocess, sys, time, shutil, signal

P = os.path.expanduser('~/proof/booksbug')
W = os.path.expanduser('~/cache')
CPUS = os.environ['CPUS']
LIBZIM = open(f'{P}/libzim.env').read().strip().split('=', 1)[1]
LLAMA_DIR = f'{W}/llama-linux'
MODEL = f'{W}/models/bge-m3-Q8_0.gguf'

WATER = [
    'Water purification in the field. Boil water at a rolling boil for one minute to kill bacteria, viruses and protozoa.',
    'At altitudes above two thousand meters boil it for three minutes. Let it cool in a clean covered container.',
    'Chemical treatment with household bleach: add two drops of unscented bleach per liter, stir, and wait thirty minutes.',
    'Filters remove protozoa and bacteria but most do not remove viruses. Combine filtering with chlorine or boiling.',
]
RADIO = [
    'Amateur radio operating procedures. Call CQ on a clear frequency, give your call sign, and listen.',
    'On the two meter band use simplex calling frequency 146.52 megahertz. Keep transmissions short.',
    'Net control stations keep a log of check ins and pass traffic in order. Use phonetics for call signs.',
    'Identify every ten minutes and at the end of each contact, as the rules for amateur stations require.',
]
FIRE = [
    'Building a campfire safely. Clear a circle of ground down to bare soil and keep water and a shovel close by.',
    'Start with tinder such as dry grass, add kindling the width of a pencil, then larger fuel wood once it catches.',
    'Never leave a fire unattended. Drown it with water, stir the ashes, and drown it again until it is cold to touch.',
    'Choose a spot away from overhanging branches and out of the wind, and check the local fire restrictions first.',
]
BOOKS = {'Water purification manual': WATER, 'Field radio handbook': RADIO, 'Campfire safety guide': FIRE}
PHRASES = {
    'Water purification manual': ['how long do I boil water to make it safe', 'bleach'],
    'Field radio handbook': ['simplex calling frequency on the two meter band', 'phonetics'],
    'Campfire safety guide': ['how do I put out a campfire', 'kindling'],
}
ALL_PHRASES = [p for v in PHRASES.values() for p in v]

started = []


def say(s):
    line = f'{time.strftime("%H:%M:%S")} {s}'
    print(line, flush=True)
    with open(f'{P}/logs/run.log', 'a') as f:
        f.write(line + '\n')


def free_gb():
    for l in open('/proc/meminfo'):
        if l.startswith('MemAvailable:'):
            return int(l.split()[1]) / 1048576
    return 0


def disk_gb():
    s = os.statvfs(P)
    return s.f_bavail * s.f_frsize / 1e9


def floors(extra=0.0):
    for _ in range(40):
        if free_gb() >= 2 + extra and disk_gb() >= 10:
            return
        say(f'floor: {free_gb():.1f} GB memory, {disk_gb():.0f} GB disk; waiting')
        time.sleep(15)
    raise SystemExit('floors not met')


FIXED_BUILDS = {'fix'}


class Dev:
    def __init__(self, scen, name, build, port):
        self.name, self.build, self.port = name, build, port
        self.scen = scen
        self.dir = f'{P}/work/{scen}/{name}'
        self.seq = 0
        self.proc = None

    def start(self):
        floors(2.5)
        os.makedirs(self.dir, exist_ok=True)
        for sub in ('cmd', 'res'):
            shutil.rmtree(f'{self.dir}/{sub}', ignore_errors=True)
        if os.path.exists(f'{self.dir}/ready.json'):
            os.remove(f'{self.dir}/ready.json')
        src = f'{P}/{self.build}'
        cs = f'{src}/packages/cache_search/native/target/debug'
        libzim = os.path.dirname([os.path.join(r, f) for r, _, fs in os.walk(f'{LIBZIM}/lib') for f in fs if f == 'libzim.so'][0])
        env = dict(os.environ)
        env.update({
            'PROOF_DIR': self.dir, 'PROOF_PORT': str(self.port), 'PROOF_NAME': self.name,
            'PROOF_FIXED': '1' if self.build in FIXED_BUILDS else '0',
            'CACHE_EMBED_LIB': f'{LLAMA_DIR}/libcache_llama.so', 'CACHE_EMBED_MODEL': MODEL,
            'PROOF_CLASSIFIER': f'{src}/app/assets/models/cache-classifier-2.bin',
            'PDFIUM_PATH': f'{src}/app/.dart_tool/hooks_runner/shared/pdfium_dart/build/chromium_7811/linux-x64/libpdfium.so',
            'LD_LIBRARY_PATH': f'{cs}:{LLAMA_DIR}:{libzim}',
        })
        log = open(f'{P}/logs/{self.scen}-{self.name}-{self.build}.log', 'a')
        say(f'start {self.name} ({self.build}) port {self.port}')
        self.proc = subprocess.Popen(['taskset', '-c', CPUS, 'nice', '-n', '10', 'flutter', 'test', '--no-pub', '--timeout', 'none', 'test/booksproof/device.dart'],
                                     cwd=f'{src}/app', env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        started.append(self.proc)
        end = time.time() + 600
        while not os.path.exists(f'{self.dir}/ready.json'):
            if self.proc.poll() is not None:
                raise SystemExit(f'{self.name} exited before ready (see logs)')
            if time.time() > end:
                raise SystemExit(f'{self.name} not ready in 10 min')
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

    def wait(self, n, op, timeout=1500):
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

    def call(self, op, args=None, timeout=1500):
        say(f'{self.name}: {op} {json.dumps(args)[:80] if args else ""}')
        res = self.wait(self.send(op, args), op, timeout)
        say(f'{self.name}: {op} -> {json.dumps(res)[:300]}')
        if op in ('add', 'add_wait') and not res.get('ok'):
            raise SystemExit(f'{self.name} {op} did not add the book: {res}')
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
    a.call('match_all')
    b.call('match_all')


def rounds(ds, n=3):
    for _ in range(n):
        for d in ds:
            d.call('sync', {'rounds': 1})


def save(ev, stage, d, data):
    os.makedirs(f'{ev}/{stage}', exist_ok=True)
    with open(f'{ev}/{stage}/{d.name}.json', 'w') as f:
        json.dump(data, f, indent=1)


def snapshot_files(ev, stage, ds):
    for d in ds:
        dst = f'{ev}/{stage}/{d.name}-libraries'
        shutil.rmtree(dst, ignore_errors=True)
        src = f'{d.dir}/data/libraries'
        if os.path.isdir(src):
            shutil.copytree(src, dst, ignore=shutil.ignore_patterns('*.gguf'))


def checks(ev, stage, ds, expect_titles, added):
    """Every own library on each device counts (an old build may have made My books again)."""
    out = []
    pieces = sum(a.get('pieces') or 0 for a in added.values())
    for d in ds:
        j = d.call('dump', {'phrases': ALL_PHRASES}, timeout=900)
        save(ev, stage, d, j)
        lines = [t for v in (j.get('copies_jsonl_by_library') or {}).values() for t in (v or [])]
        shelf = [b.get('title') for b in (j.get('bookshelves') or [])]
        files = j.get('files') or []
        packs = [f for f in files if '/packs/' in f and '.cdoc' in f and '(conflict' not in f]
        for t in expect_titles:
            vec = PHRASES[t][0]
            kw = PHRASES[t][1]
            s = (j.get('searches') or {})
            copy = added.get(t, {}).get('copy') or '?'
            out.append({'device': d.name, 'build': d.build, 'book': t,
                        'copies_line': any((x or '').startswith(t) for x in lines),
                        'on_bookshelves': any((x or '').startswith(t) for x in shelf),
                        'pdf': any(f'/bookshelf/{copy}.pdf (' in f for f in files),
                        'pack': any(f'/packs/{copy}@' in f and '(conflict' not in f for f in files),
                        'vector_hit': any((x or '').startswith(t) for x in (s.get(vec, {}).get('vector') or [])),
                        'keyword_hit': any((x or '').startswith(t) for x in (s.get(kw, {}).get('keyword') or []))})
        out.append({'device': d.name, 'build': d.build, 'own_libraries': j.get('own_libraries'), 'shard_points': j.get('shard_points'),
                    'shard_points_by_library': j.get('shard_points_by_library'), 'expected_points': pieces,
                    'copies_lines': len(lines), 'packs': len(packs), 'conflict_files': j.get('conflict_files'),
                    'library_error': j.get('library_error'), 'search_error': j.get('search_error')})
    snapshot_files(ev, stage, ds)
    with open(f'{ev}/{stage}/checks.json', 'w') as f:
        json.dump(out, f, indent=1)
    for c in out:
        say(f'CHECK {stage}: {json.dumps(c)}')
    return out


def verdict(ev, stage, c, devices):
    """PASS when every book is listed, has its PDF and is found by meaning on each named device, the points add up, and no
    conflict copies are left."""
    bad = []
    for r in c:
        if r['device'] not in devices:
            continue
        if 'book' in r:
            for k in ('copies_line', 'pdf', 'vector_hit'):
                if not r[k]:
                    bad.append(f"{r['device']} {r['book']}: {k}")
        else:
            if r['shard_points'] != r['expected_points']:
                bad.append(f"{r['device']}: points {r['shard_points']} of {r['expected_points']}")
            if r['conflict_files']:
                bad.append(f"{r['device']}: conflict copies {r['conflict_files']}")
            if r['library_error'] or r['search_error']:
                bad.append(f"{r['device']}: {r['library_error'] or r['search_error']}")
    v = {'stage': stage, 'devices': devices, 'pass': not bad, 'failures': bad}
    with open(f'{ev}/{stage}/verdict.json', 'w') as f:
        json.dump(v, f, indent=1)
    say(f'VERDICT {stage} {devices}: {"PASS" if not bad else "FAIL"} {bad}')
    return v


def expect_verdict(ev, stage, c, want, added):
    """PASS when each device has exactly the books [want] says ({device: {title: present}}): a present one is listed, has its PDF
    and is found by meaning; an absent one is none of these; the points are those of the present books; no conflict copies."""
    bad = []
    for r in c:
        dev = r['device']
        if dev not in want:
            continue
        if 'book' in r:
            if r['book'] not in want[dev]:
                continue
            present = want[dev][r['book']]
            for k in ('copies_line', 'pdf', 'pack', 'vector_hit'):
                if r[k] != present:
                    bad.append(f"{dev} {r['book']}: {k} is {r[k]}, wanted {present}")
        else:
            pts = sum(added[t].get('pieces') or 0 for t, p in want[dev].items() if p and t in added)
            if r['shard_points'] != pts:
                bad.append(f"{dev}: points {r['shard_points']} of {pts}")
            if r['conflict_files']:
                bad.append(f"{dev}: conflict copies {r['conflict_files']}")
            if r['library_error'] or r['search_error']:
                bad.append(f"{dev}: {r['library_error'] or r['search_error']}")
    v = {'stage': stage, 'want': want, 'pass': not bad, 'failures': bad}
    with open(f'{ev}/{stage}/verdict.json', 'w') as f:
        json.dump(v, f, indent=1)
    say(f'VERDICT {stage}: {"PASS" if not bad else "FAIL"} {bad}')
    return v


def calls_of(ev, stage, dev):
    j = json.load(open(f'{ev}/{stage}/{dev}.json'))
    return {b.get('title'): (b.get('call') or {}).get('text') for b in (j.get('bookshelves') or [])}


DELETES = ['del-apart', 'del-keep', 'del-readd', 'del-rule3']


def del_scenario(name):
    """Delete from all your devices (owner decisions, 2026-11-14), both devices on fix/. Campfire stays throughout."""
    ev = f'{P}/evidence/{name}'
    shutil.rmtree(ev, ignore_errors=True)
    shutil.rmtree(f'{P}/work/{name}', ignore_errors=True)
    os.makedirs(ev)
    base = 48100 + 100 * DELETES.index(name)
    a = Dev(name, 'A', 'fix', base + 1)
    b = Dev(name, 'B', 'fix', base + 2)
    W, C = 'Water purification manual', 'Campfire safety guide'
    try:
        a.start()
        b.start()
        link(a, b)
        a.call('make_own')
        a.call('share_library')
        b.call('share_library')
        rounds([a, b])
        added = {C: a.call('add', {'title': C, 'lines': FIRE})}
        rounds([a, b])
        if name == 'del-rule3':
            # B is apart before it ever sees Water: A adds Water and deletes it; B adds the same PDF without having seen the delete
            b.call('pause')
            added[W] = a.call('add', {'title': W, 'lines': WATER})
            deleted_at = time.time()
            a.call('delete', {'title': W})
            # B's add is a new write made after A's delete (its own, later version stamp): a gap makes the stamps differ
            time.sleep(2)
            added_at = time.time()
            added[W] = b.call('add', {'title': W, 'lines': WATER})
            b.call('resume')
            with open(f'{ev}/stamps.json', 'w') as f:
                json.dump({'a_deleted_at': deleted_at, 'b_added_at': added_at, 'b_after_a': added_at > deleted_at}, f, indent=1)
            rounds([a, b], 4)
            time.sleep(10)
            rounds([a, b], 2)
            c = checks(ev, '3-after-sync', [a, b], [W, C], added)
            v = expect_verdict(ev, '3-after-sync', c, {'A': {W: True, C: True}, 'B': {W: True, C: True}}, added)
        else:
            added[W] = a.call('add', {'title': W, 'lines': WATER})
            rounds([a, b])
            c = checks(ev, '1-both-books', [a, b], [W, C], added)
            expect_verdict(ev, '1-both-books', c, {'A': {W: True, C: True}, 'B': {W: True, C: True}}, added)
            before = calls_of(ev, '1-both-books', 'A').get(W)
            if name == 'del-apart':
                b.call('pause')
            a.call('delete', {'title': W})
            if name == 'del-apart':
                b.call('resume')
            rounds([a, b], 4)
            time.sleep(10)
            rounds([a, b], 2)
            c = checks(ev, '2-after-delete', [a, b], [W, C], added)
            v = expect_verdict(ev, '2-after-delete', c, {'A': {W: False, C: True}, 'B': {W: False, C: True}}, added)
            if name == 'del-keep':
                # a second sync later (A's delete offered again): B's delete stands, nothing comes back
                time.sleep(15)
                rounds([a, b], 4)
                c = checks(ev, '2b-second-sync', [a, b], [W, C], added)
                v2 = expect_verdict(ev, '2b-second-sync', c, {'A': {W: False, C: True}, 'B': {W: False, C: True}}, added)
                v = {**v2, 'pass': v['pass'] and v2['pass'], 'first': v}
            if name == 'del-readd':
                added[W] = a.call('add', {'title': W, 'lines': WATER})
                rounds([a, b], 4)
                c = checks(ev, '3-after-readd', [a, b], [W, C], added)
                v = expect_verdict(ev, '3-after-readd', c, {'A': {W: True, C: True}, 'B': {W: True, C: True}}, added)
                after = {d: calls_of(ev, '3-after-readd', d).get(W) for d in ('A', 'B')}
                same = before is not None and all(x == before for x in after.values())
                say(f'CALL NUMBER {W}: before {before}, after {after}: {"SAME" if same else "DIFFERENT"}')
                v['call_number'] = {'before': before, 'after': after, 'same': same}
                v['pass'] = v['pass'] and same
                with open(f'{ev}/3-after-readd/verdict.json', 'w') as f:
                    json.dump(v, f, indent=1)
        a.call('status')
        b.call('status')
        with open(f'{ev}/added.json', 'w') as f:
            json.dump(added, f, indent=1)
        return v
    finally:
        a.stop()
        b.stop()
        for d in (a, b):
            if os.path.exists(f'{d.dir}/log.txt'):
                shutil.copy(f'{d.dir}/log.txt', f'{ev}/{d.name}-log.txt')


SCENARIOS = {
    # name: (A's build, B's build, the adds, the builds both move to afterwards or None, the devices that must pass at the end)
    'apart': ('new', 'new', 'apart', None, ['A', 'B']),
    'midflight': ('new', 'new', 'midflight', None, ['A', 'B']),
    'b51': ('new', 'b51', 'apart', None, ['A', 'B']),
    'fix-apart': ('fix', 'fix', 'apart', None, ['A', 'B']),
    'fix-midflight': ('fix', 'fix', 'midflight', None, ['A', 'B']),
    # the old peer: the fixed device must have every book; build 51 does not get the search of books added on the fixed device
    'fix-b51': ('fix', 'b51', 'apart', None, ['A']),
    'fix-recover': ('new', 'new', 'apart', 'fix', ['A', 'B']),
}


def scenario(name):
    build_a, build_b, adds, then, must = SCENARIOS[name]
    ev = f'{P}/evidence/{name}'
    shutil.rmtree(ev, ignore_errors=True)
    shutil.rmtree(f'{P}/work/{name}', ignore_errors=True)
    os.makedirs(ev)
    base = 47100 + 100 * list(SCENARIOS).index(name)
    a = Dev(name, 'A', build_a, base + 1)
    b = Dev(name, 'B', build_b, base + 2)
    try:
        a.start()
        b.start()
        link(a, b)
        a.call('make_own')
        a.call('share_library')
        b.call('share_library')
        rounds([a, b])
        added = {}
        # a first book on A, synced to B: My books is now on both, with one book (B adds into the arrived library)
        added['Campfire safety guide'] = a.call('add', {'title': 'Campfire safety guide', 'lines': FIRE})
        rounds([a, b])
        checks(ev, '1-one-book-synced', [a, b], ['Campfire safety guide'], added)
        if adds == 'apart':
            # apart: B has no network (nothing goes between them) while both add, at the same time so the gap stays short.
            # With lookup off a device knows the other's address only from a live connection, and after a long time with no
            # network both lost it ("No addressing information available"): A stays online and finds B again when it is back.
            b.call('pause')
            na = a.send('add_start', {'title': 'Water purification manual', 'lines': WATER})
            a.wait(na, 'add_start')
            nb = b.send('add_start', {'title': 'Field radio handbook', 'lines': RADIO})
            b.wait(nb, 'add_start')
            added['Water purification manual'] = a.call('add_wait', {'title': 'Water purification manual'})
            added['Field radio handbook'] = b.call('add_wait', {'title': 'Field radio handbook'})
            b.call('resume')
            checks(ev, '2-apart-before-sync', [a, b], [], added)
        else:
            # both add while rounds run: A starts its add and asks for rounds meanwhile; B adds with a round asked mid-add
            na = a.send('add_start', {'title': 'Water purification manual', 'lines': WATER})
            a.wait(na, 'add_start')
            nb = b.send('add_start', {'title': 'Field radio handbook', 'lines': RADIO})
            b.wait(nb, 'add_start')
            for _ in range(6):
                a.call('sync_start')
                b.call('sync_start')
                time.sleep(5)
            added['Water purification manual'] = a.call('add_wait', {'title': 'Water purification manual'})
            added['Field radio handbook'] = b.call('add_wait', {'title': 'Field radio handbook'})
        rounds([a, b], 4)
        time.sleep(10)
        rounds([a, b], 2)
        with open(f'{ev}/added.json', 'w') as f:
            json.dump(added, f, indent=1)
        c = checks(ev, '3-after-sync', [a, b], list(BOOKS), added)
        stage = '3-after-sync'
        if then:
            # the update, one device at a time (lookup is off: the one that stays up finds the other at its fixed port)
            a.restart(then)
            rounds([a, b], 2)
            b.restart(then)
            rounds([a, b], 3)
            time.sleep(10)
            rounds([a, b], 2)
            stage = '4-after-update'
            c = checks(ev, stage, [a, b], list(BOOKS), added)
        a.call('status')
        b.call('status')
        return verdict(ev, stage, c, must)
    finally:
        a.stop()
        b.stop()
        for d in (a, b):
            for f in ('log.txt',):
                if os.path.exists(f'{d.dir}/{f}'):
                    shutil.copy(f'{d.dir}/{f}', f'{ev}/{d.name}-{f}')


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    os.makedirs(f'{P}/logs', exist_ok=True)
    try:
        for s in sys.argv[1:]:
            say(f'=== scenario {s}')
            del_scenario(s) if s in DELETES else scenario(s)
    finally:
        for p in started:
            if p.poll() is None:
                try:
                    os.killpg(p.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
