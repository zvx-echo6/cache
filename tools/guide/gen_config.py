#!/usr/bin/env python3
"""Write a search config that holds only the guide library, for checking it with cs.

usage: gen_config.py --base-config BASE.json --library-dir DIR --index-dir DIR --out CONFIG.json

BASE.json is any working cs config (its places, routing, user and live sections are kept; its sources are replaced
by the guide). DIR is the unpacked library (its cache-library.json is read for the settings).
"""
import argparse
import json

ap = argparse.ArgumentParser()
ap.add_argument('--base-config', required=True)
ap.add_argument('--library-dir', required=True)
ap.add_argument('--index-dir', required=True)
ap.add_argument('--out', required=True)
a = ap.parse_args()
lib = json.load(open(a.library_dir.rstrip('\\/') + '/cache-library.json', encoding='utf-8'))
settings = {k: lib[k] for k in ('format', 'library_id', 'version', 'title', 'fields', 'leave_out', 'embedding', 'keyword_index')}
settings['embedding'] = {k: settings['embedding'][k] for k in ('vector', 'model', 'sha256', 'dims')}
c = json.load(open(a.base_config, encoding='utf-8'))
c['sources'] = [{'kind': 'library', 'path': a.library_dir, 'index_dir': a.index_dir, 'settings': settings}]
open(a.out, 'w', encoding='utf-8', newline='\n').write(json.dumps(c, indent=1))
print(a.out)
