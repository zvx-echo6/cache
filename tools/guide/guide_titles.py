#!/usr/bin/env python3
"""Print the title of every guide section as JSON, in order: {"titles": [...]}.

A title is "Cache guide: <chapter heading>: <section heading>", for example
"Cache guide: 1. Getting started: Choose a model". Chapters are docs/guide/ch*.md,
read in chapter-number order. Exits 1 (and says which) if two titles are the same.
"""
import json
import pathlib
import re
import sys


def chapter_key(path):
    m = re.match(r'ch(\d+)', path.name)
    return (int(m.group(1)) if m else 10**6, path.name)


def main():
    guide = pathlib.Path(__file__).resolve().parents[2] / 'docs' / 'guide'
    titles, seen, dupes = [], set(), []
    for ch in sorted(guide.glob('ch*.md'), key=chapter_key):
        chapter = None
        in_code = False
        for line in ch.read_text(encoding='utf-8').splitlines():
            if line.startswith('```'):
                in_code = not in_code
                continue
            if in_code:
                continue
            if line.startswith('# '):
                chapter = line[2:].strip()
            elif line.startswith('## '):
                if chapter is None:
                    print(f'{ch.name}: section before the chapter heading', file=sys.stderr)
                    return 1
                title = f'Cache guide: {chapter}: {line[3:].strip()}'
                if title in seen:
                    dupes.append(title)
                seen.add(title)
                titles.append(title)
    print(json.dumps({'titles': titles}, indent=2, ensure_ascii=False))
    for d in dupes:
        print(f'duplicate title: {d}', file=sys.stderr)
    return 1 if dupes else 0


if __name__ == '__main__':
    sys.exit(main())
