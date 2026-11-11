#!/usr/bin/env python3
"""Fails when a recommended-models file would not be read by app 1.0.30 (build 46) from data.cached.info/models/recommended.json.

Mirrors, from `git show v1.0.30:app/lib/models/recommendations.dart`:
  parseRecommendations      lines 186-197: the text must be a JSON object whose `format` is 2 (kRecommendationsFormat) or 1, with
                            `models` a list; anything else makes the app drop the file and keep its built-in list.
  ModelRecommendation.fromJson  lines 143-171: an entry is silently left out unless: name is a string; file is a string ending
                            .gguf; a direct https `url` (with a host) or else a repo string containing "/"; `url`, when present,
                            is a direct https address; size is an int > 0; kind is tuned_for_cache or works_not_tuned; a direct
                            url entry also has a 64-hex lowercase sha256.
Here an entry the app would leave out is an error, and so is an empty list. Usage: check-models-compat-1.0.30.py FILE...
"""
import json, re, sys, urllib.parse

APP_FORMATS = (1, 2)
KINDS = ('tuned_for_cache', 'works_not_tuned')


def check(path):
    errs = []
    try:
        d = json.load(open(path, 'rb'))
    except ValueError as e:
        return [f"{path}: does not parse: {e}"]
    fmt = d.get('format') if isinstance(d, dict) else None
    if not isinstance(d, dict) or isinstance(fmt, bool) or fmt not in APP_FORMATS:
        return [f"{path}: format {fmt!r} is not one app 1.0.30 reads {APP_FORMATS}"]
    models = d.get('models')
    if not isinstance(models, list) or not models:
        return [f"{path}: models is not a non-empty list"]
    for i, e in enumerate(models):
        w = f"{path}: models[{i}]"
        if not isinstance(e, dict):
            errs.append(f"{w} is not an object"); continue
        w += f" ({e.get('name')!r})"
        url = e.get('url')
        direct = False
        if isinstance(url, str):
            u = urllib.parse.urlparse(url)
            direct = u.scheme == 'https' and bool(u.hostname)
        if not isinstance(e.get('name'), str):
            errs.append(f"{w}: name is not a string")
        f = e.get('file')
        if not isinstance(f, str) or not f.lower().endswith('.gguf'):
            errs.append(f"{w}: file is not a .gguf name")
        repo = e.get('repo')
        if not direct and (not isinstance(repo, str) or '/' not in repo):
            errs.append(f"{w}: neither an https url nor an owner/name repo")
        if url is not None and not direct:
            errs.append(f"{w}: url is not an https address")
        s = e.get('size')
        if not isinstance(s, int) or isinstance(s, bool) or s <= 0:
            errs.append(f"{w}: size is not a positive integer")
        if e.get('kind') not in KINDS:
            errs.append(f"{w}: kind {e.get('kind')!r} is not one of {KINDS}")
        sha = e.get('sha256')
        if direct and not (isinstance(sha, str) and re.fullmatch(r'[0-9a-f]{64}', sha)):
            errs.append(f"{w}: a direct-address entry needs a 64-hex sha256")
    return errs


bad = [m for p in sys.argv[1:] for m in check(p)]
for m in bad:
    print(f"::error::{m}")
if bad:
    sys.exit(1)
print(f"OK: {', '.join(sys.argv[1:])} readable by app 1.0.30")
