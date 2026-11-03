#!/usr/bin/env python3
"""Release preflight: every data source the guide or What's new names is in the live connector catalogue.

usage: sources_check.py [--catalogue URL] [--root CHECKOUT]

Reads the reviewed list tools/guide/sources_expected.txt (one catalogue title per line, # comments) and checks:
1. each title is quoted ("...") somewhere in docs/guide/ch*.md or app/assets/whats_new.md (the list is kept honest: a
   title nobody names any more is reported, as a warning);
2. each title is a connector title in the live catalogue (fails when one is missing: a source the guide promises whose
   data was never published, as FEMA IPAWS "Emergency alerts" once was).
The catalogue is fetched now; when that fails (no network, the site down) it warns and passes. Exits 1 on a missing title.
"""
import argparse
import json
import pathlib
import sys
import urllib.request

HERE = pathlib.Path(__file__).resolve().parent
DEFAULT = 'https://data.cached.info/connectors/catalogue.json'


def expected(path):
    return [l.strip() for l in path.read_text(encoding='utf-8').splitlines() if l.strip() and not l.lstrip().startswith('#')]


def named_texts(root):
    files = sorted((root / 'docs' / 'guide').glob('ch*.md')) + [root / 'app' / 'assets' / 'whats_new.md']
    return {f: f.read_text(encoding='utf-8') for f in files if f.exists()}


def catalogue_titles(url):
    req = urllib.request.Request(url, headers={'User-Agent': 'cache-guide-check'})
    with urllib.request.urlopen(req, timeout=30) as r:
        data = json.loads(r.read().decode('utf-8'))
    return {c.get('title', '') for c in data.get('connectors', [])}


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--catalogue', default=DEFAULT)
    ap.add_argument('--root', default=str(HERE.parents[1]))
    a = ap.parse_args(argv)
    root = pathlib.Path(a.root)
    names = expected(HERE / 'sources_expected.txt')
    texts = named_texts(root)
    for n in names:
        if not any(f'"{n}"' in t for t in texts.values()):
            print(f'::warning::sources_expected.txt lists "{n}", but no chapter or What\'s new quotes it; remove the line if it is no longer named')
    try:
        titles = catalogue_titles(a.catalogue)
    except Exception as e:  # noqa: BLE001 - any fetch or parse failure only warns
        print(f'::warning::could not read the connector catalogue ({a.catalogue}): {e}; the sources were not checked')
        return 0
    missing = [n for n in names if n not in titles]
    for n in missing:
        where = [f.relative_to(root).as_posix() for f, t in texts.items() if f'"{n}"' in t]
        print(f'"{n}" is named by {", ".join(where) or "sources_expected.txt"} but is not in the live catalogue {a.catalogue}')
    if missing:
        print(f'{len(missing)} named sources are not published')
        return 1
    print(f'sources check: all {len(names)} named sources are in the live catalogue ({len(titles)} connectors)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
