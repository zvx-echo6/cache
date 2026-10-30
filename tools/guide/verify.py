#!/usr/bin/env python3
"""Check a built guide library through cs.

usage: verify.py --cs cs.exe --config CONFIG.json --manifest MANIFEST.json --embed-lib cache_llama.dll
                 --embed-model bge-m3-Q8_0.gguf --embed-sha256 SHA [--library-id cache-guide]

Checks: the entry count equals the number of sections; every section reads back byte-identical with its exact title;
and a set of questions return the expected section in the top 3 (rank printed). Exits 1 if any check fails.
"""
import argparse
import json
import re
import subprocess
import sys
import uuid

ap = argparse.ArgumentParser()
for k in ('cs', 'config', 'manifest', 'embed-lib', 'embed-model', 'embed-sha256'):
    ap.add_argument('--' + k, required=True)
ap.add_argument('--library-id', default='cache-guide')
a = ap.parse_args()
man = json.load(open(a.manifest, encoding='utf-8'))
emb = ['--embed-lib', a.embed_lib, '--embed-model', a.embed_model, '--embed-sha256', a.embed_sha256]
NS = uuid.UUID('c4b95b91-e641-5c16-91a0-13ba2f6f7970')
G = 'Cache guide: '


def cs(*args):
    r = subprocess.run([a.cs, *args], capture_output=True, text=True, encoding='utf-8')
    assert r.returncode == 0, (args, r.stderr[-500:])
    return r.stdout


def slug(s):
    return re.sub(r'[^a-z0-9]+', '-', s.lower().replace("'", '')).strip('-')


fail = 0
st = json.loads(cs('status', '--config', a.config))
docs = sum(s['docs'] for s in st['sources'])
print('entries', docs, 'sections', len(man), 'PASS' if docs == len(man) else 'FAIL')
fail += docs != len(man)

ok = tbad = 0
for m in man:
    doc = '%s--%s' % (slug(re.sub(r'^\d+\.\s*', '', m['chapter'])), slug(m['section']))
    r = json.loads(cs('read', '--config', a.config, '--address', 'lib:%s/%s' % (a.library_id, uuid.uuid5(NS, doc + ':1:0')), '--max-chars', '6000'))
    same = r['text'].replace('\r\n', '\n') == m['body'].replace('\r\n', '\n') and not r['truncated']
    ok += same
    if not same:
        print('TEXT DIFF', m['title'])
    if r['title'] != m['title']:
        tbad += 1
        print('TITLE DIFF', repr(r['title']), repr(m['title']))
print('read identical %d/%d, title mismatches %d' % (ok, len(man), tbad))
fail += (ok != len(man)) + tbad

Q = [
    ('mobile data downloads', G + '1. Getting started: Downloads, Wi-Fi and mobile data'),
    ('download a region', G + '1. Getting started: Download a region'),
    ('add to library', G + '1. Getting started: Add to your Library'),
    ('turn on weather', G + '1. Getting started: Turn on weather and alerts'),
    ('kagi key', G + '4. Services and keys: Web search with Kagi'),
    ('places notebook', G + '5. Notebooks: The Places notebook'),
    ('choose a model', G + '1. Getting started: Choose a model'),
    ('use my location', G + '1. Getting started: Let Cache use your location'),
    ('how do I change the app to dark mode', G + '3. Settings, page by page: Appearance'),
    ("my phone is full and a download stopped", G + "6. When something doesn't work: Storage full"),
    ('obsidian vault', G + '5. Notebooks: Write notebooks to Obsidian or Logseq'),
    ('region download stopped', G + '1. Getting started: Region download progress and off-road data', G + '1. Getting started: Download a region'),
    ('off-road data already on this phone', G + '1. Getting started: Region download progress and off-road data'),
    ('how do I follow a route while driving', G + '2. Using Cache: Follow a route'),
]
for q, *exps in Q:
    out = json.loads(cs('search', '--config', a.config, '--query', q, '--k', '5', '--json', *emb))
    t = [x['title'] for x in out['results'] if x['source_id'] == a.library_id]
    ranks = [t.index(e) + 1 for e in exps if e in t]
    rank = min(ranks) if ranks else None
    good = rank is not None and rank <= 3
    fail += not good
    print('%-45s rank %s %s' % (q, rank, 'PASS' if good else 'FAIL'))
    for i, x in enumerate(t[:3], 1):
        print('   %d. %s' % (i, x))
sys.exit(1 if fail else 0)
