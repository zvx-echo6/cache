#!/usr/bin/env python3
"""Split the guide chapters into a manifest, one entry per `## Section`.

usage: split.py [--chapters DIR] --out MANIFEST.json

DIR defaults to docs/guide in this repo. The manifest is a JSON list, in reading order, of
{file, title, source, section, chapter, body}. `title` is "Cache guide: <chapter heading>: <section heading>" (the
same rule as guide_titles.py); `body` is the section text without its heading. Exits 1 on a duplicate title.
"""
import argparse
import collections
import json
import pathlib
import re
import sys


def chapter_key(path):
    m = re.match(r'ch(\d+)', path.name)
    return (int(m.group(1)) if m else 10**6, path.name)


# An app link in the reader, [words](cache://...): the library keeps only the words, so the assistant never sees an app address.
APP_LINK = re.compile(r'\[([^\]]*)\]\(cache://[^)]*\)')


def strip_app_links(text):
    """[text](cache://...) becomes text; every other link stays as it is."""
    return APP_LINK.sub(lambda m: m.group(1), text)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--chapters', default=str(pathlib.Path(__file__).resolve().parents[2] / 'docs' / 'guide'))
    ap.add_argument('--out', required=True)
    a = ap.parse_args()
    files = sorted(pathlib.Path(a.chapters).glob('ch*.md'), key=chapter_key)
    if not files:
        print('no ch*.md in ' + a.chapters, file=sys.stderr)
        return 1
    man = []
    for f in files:
        chap, cur, infence, secs = None, None, False, []
        for ln in f.read_text(encoding='utf-8').split('\n'):
            if ln.startswith('```'):
                infence = not infence
            if not infence and ln.startswith('# ') and chap is None:
                chap = ln[2:].strip()
                continue
            if not infence and ln.startswith('## '):
                if chap is None:
                    print(f'{f.name}: section before the chapter heading', file=sys.stderr)
                    return 1
                if 'cache://' in ln or 'cache://' in chap:
                    print(f'{f.name}: a heading holds an app link (titles never do): {ln}', file=sys.stderr)
                    return 1
                cur = [ln[3:].strip(), []]
                secs.append(cur)
                continue
            if cur is not None:
                cur[1].append(ln)
        for h, body in secs:
            text = strip_app_links('\n'.join(body)).strip('\n')
            title = 'Cache guide: %s: %s' % (chap, h)
            fn = re.sub(r'[/\\?*"<>|]', '-', 'Cache guide - %s - %s.txt' % (chap, h))
            man.append({'file': fn, 'title': title, 'source': f.name, 'section': h, 'chapter': chap, 'body': text})
    pathlib.Path(a.out).write_text(json.dumps(man, indent=1), encoding='utf-8')
    dupes = [k for k, v in collections.Counter(m['title'] for m in man).items() if v > 1]
    print(len(man), 'sections')
    for d in dupes:
        print('duplicate title: ' + d, file=sys.stderr)
    return 1 if dupes else 0


if __name__ == '__main__':
    sys.exit(main())
