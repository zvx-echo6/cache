#!/usr/bin/env python3
"""Turn a shard snapshot into the guide's .cache-library package.

usage: package.py --snapshot SNAPSHOT --version YYYY-MM-DD --out-dir DIR [--template-settings cache-library.json]

Writes into DIR:
  cache-library.json                       the settings (format 1, library_id cache-guide, this version)
  cache-guide-<version>.cache-library.tar  the snapshot with cache-library.json added at its root (uncompressed)
  cache-guide-<version>.cache-library      the same, gzip-compressed (what is published and shipped)
and prints the size and sha256 of both. The embedding block is fixed: bge-m3 Q8_0, 1024 dimensions, one unnamed vector.
"""
import argparse
import gzip
import hashlib
import json
import pathlib
import shutil
import tarfile

ap = argparse.ArgumentParser()
ap.add_argument('--snapshot', required=True)
ap.add_argument('--version', required=True)
ap.add_argument('--out-dir', required=True)
a = ap.parse_args()

settings = {
    'format': 1, 'library_id': 'cache-guide', 'version': a.version, 'title': 'Cache guide',
    'fields': {'title': 'title', 'text': 'text', 'page': 'page', 'source_type': 'source', 'link': 'link', 'document': 'doc_id'},
    'leave_out': [],
    'embedding': {'vector': '', 'model': 'bge-m3-Q8_0.gguf',
                  'sha256': 'c98c7c907bb3ab8c3be4c8ad827cc934c7c1a7e014d1c999e0c45c8027c158bb', 'dims': 1024,
                  'repo': 'lm-kit/bge-m3-gguf', 'revision': '9379ce497e8814b200f2dc0d18eb4045426dcb8c',
                  'path': 'bge-m3-Q8_0.gguf', 'size': 634553856},
    'keyword_index': 'auto',
}
out = pathlib.Path(a.out_dir)
out.mkdir(parents=True, exist_ok=True)
js = out / 'cache-library.json'
js.write_text(json.dumps(settings, indent=2) + '\n', encoding='utf-8', newline='\n')
tar_path = out / f'cache-guide-{a.version}.cache-library.tar'
gz_path = out / f'cache-guide-{a.version}.cache-library'
for p in (tar_path, gz_path):
    if p.exists():
        raise SystemExit(f'{p} exists; not overwriting')
shutil.copyfile(a.snapshot, tar_path)
with tarfile.open(tar_path, 'a') as t:  # same as: tar -rf SNAPSHOT cache-library.json
    t.add(js, arcname='cache-library.json')
with open(tar_path, 'rb') as src, open(gz_path, 'wb') as raw:
    with gzip.GzipFile(filename='', mode='wb', fileobj=raw, compresslevel=9, mtime=0) as g:  # gzip -9 -n
        shutil.copyfileobj(src, g)


def sha(p):
    h = hashlib.sha256()
    with open(p, 'rb') as f:
        for b in iter(lambda: f.read(1 << 20), b''):
            h.update(b)
    return h.hexdigest()


for p in (tar_path, gz_path):
    print(f'{p.name}  {p.stat().st_size} bytes  sha256 {sha(p)}')
