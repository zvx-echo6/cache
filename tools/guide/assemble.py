#!/usr/bin/env python3
"""Build the library points from the manifest and the embeddings.

usage: assemble.py MANIFEST.json VECTORS.json VARIANT POINTS.json

VARIANT is text_vec or title_text_vec (the library uses title_text_vec). Writes a list of
{id, vector, payload}; payload = title, text, page, source ("guide"), link, doc_id, doc_version.

doc_id  = slug(chapter heading without its number) + "--" + slug(section heading)
id      = UUIDv5(c4b95b91-e641-5c16-91a0-13ba2f6f7970, "<doc_id>:1:0")   (LIBRARY-FORMAT.md)
so an id stays the same when only a section's text changes; it changes only if a heading is renamed.
"""
import json
import re
import sys
import uuid

man = json.load(open(sys.argv[1], encoding='utf-8'))
vec = json.load(open(sys.argv[2]))
variant, out = sys.argv[3], sys.argv[4]
NS = uuid.UUID('c4b95b91-e641-5c16-91a0-13ba2f6f7970')


def slug(s):
    s = s.lower().replace("'", '')
    return re.sub(r'[^a-z0-9]+', '-', s).strip('-')


assert len(man) == len(vec)
pts, seen = [], set()
for m, v in zip(man, vec):
    assert v['title'] == m['title']
    chap = re.sub(r'^\d+\.\s*', '', m['chapter'])
    doc_id = slug(chap) + '--' + slug(m['section'])
    assert doc_id not in seen, doc_id
    seen.add(doc_id)
    pid = str(uuid.uuid5(NS, '%s:1:0' % doc_id))
    pts.append({'id': pid, 'vector': v[variant],
                'payload': {'title': m['title'], 'text': m['body'], 'page': None, 'source': 'guide', 'link': None,
                            'doc_id': doc_id, 'doc_version': 1}})
json.dump(pts, open(out, 'w', encoding='utf-8'), ensure_ascii=False)
print(len(pts), len({p['id'] for p in pts}))
