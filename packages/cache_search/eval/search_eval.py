#!/usr/bin/env python3
"""Search-quality evaluation for cache_search (standard library only). Not part of the normal test run: it needs a real
source set (the recon library plus ZIMs) and a running `cs serve`, so it is a script, not a cargo test.

  cs serve --config sources.json --listen 127.0.0.1:18490
  search_eval.py --url http://127.0.0.1:18490 --queries queries.json [--label hybrid] [--out result.json]
  search_eval.py --url ... --probe "replace iphone battery" [--source ifixit] [--k 8]   (list the top hits)
  search_eval.py ... --opts '{"k": 8}'     (extra search options, merged into every request)

Three runs make the comparison (the sources are the same, only the ZIMs' engine differs):
  Tantivy only   every ZIM with "builtin_index": false, a ZIM without a finished Tantivy index left out of the config;
  hybrid         the same config without that key (a ZIM with a built-in index uses libzim's Xapian);
  and any build of the core can be tried by pointing `cs serve` at it.

queries.json: {"queries": [{"id","query","expect":[{"source":"<substring of the source title>","title":"<regex on the article
title>"}], "note"}]}. Expectations were written by reading what the recon library and the ZIMs contain, each source
searched alone, never from a ranking. A result matches an expectation when its source title contains `source`
(case-insensitive; empty matches any) and its article title (the text after "<source title>: ") matches the regex `title`
(case-insensitive search; absent matches any). A query scores hit@k when any of the top k results matches any of its
expectations. One line per query is printed, then the totals.
"""
import argparse
import json
import re
import sys
import time
import urllib.request


def post(url, path, body, timeout=900):
    req = urllib.request.Request(url + path, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def get(url, path, timeout=900):
    with urllib.request.urlopen(url + path, timeout=timeout) as r:
        return json.load(r)


def article_title(r):
    t = r.get("title", "")
    s = r.get("source_title", "")
    return t[len(s) + 2:] if s and t.startswith(s + ": ") else t


def matches(r, exp):
    if exp.get("source", "").lower() not in r.get("source_title", "").lower():
        return False
    pat = exp.get("title")
    return pat is None or re.search(pat, article_title(r), re.I) is not None


EXTRA = {}


def search(url, q, k, sources=None):
    opts = {"k": k, **EXTRA}
    if sources:
        opts["sources"] = sources
    t = time.time()
    out = post(url, "/search", {"query": q, "options": opts})
    return out.get("results", []), time.time() - t


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://127.0.0.1:8433")
    ap.add_argument("--queries")
    ap.add_argument("--label", default="run")
    ap.add_argument("--out")
    ap.add_argument("--k", type=int, default=5)
    ap.add_argument("--probe")
    ap.add_argument("--opts", help="extra search options as JSON, e.g. '{\"min_term_coverage\": 0.4}'")
    ap.add_argument("--source", help="with --probe: only sources whose title or id contains this text")
    a = ap.parse_args()
    if a.opts:
        EXTRA.update(json.loads(a.opts))

    if a.probe:
        sources = None
        if a.source:
            st = get(a.url, "/status")
            sources = [s["id"] for s in st["sources"] if a.source.lower() in (s["id"] + " " + s["title"]).lower()]
            if not sources:
                sys.exit("no source matches " + a.source)
        res, secs = search(a.url, a.probe, a.k, sources)
        print(f"{secs:.2f}s")
        for i, r in enumerate(res, 1):
            print(f"{i}. [{r['source_title']}] {article_title(r)}  | {r['snippet'][:110]}")
        return

    qs = json.load(open(a.queries))["queries"]
    rows, h3, h5 = [], 0, 0
    for q in qs:
        res, secs = search(a.url, q["query"], max(a.k, 5))
        pos = None
        for i, r in enumerate(res):
            if any(matches(r, e) for e in q["expect"]):
                pos = i + 1
                break
        in3, in5 = pos is not None and pos <= 3, pos is not None and pos <= 5
        h3 += in3
        h5 += in5
        rows.append({"id": q["id"], "query": q["query"], "first_match_rank": pos, "hit3": in3, "hit5": in5, "secs": round(secs, 2),
                     "top": [f"[{r['source_title']}] {article_title(r)}" for r in res[:5]]})
        print(f"{q['id']:<16} hit@3={int(in3)} hit@5={int(in5)} rank={pos} {secs:5.1f}s  " + " | ".join(x[:46] for x in rows[-1]["top"][:3]))
    print(f"{a.label}: hit@3 {h3}/{len(qs)}  hit@5 {h5}/{len(qs)}")
    if a.out:
        json.dump({"label": a.label, "hit3": h3, "hit5": h5, "n": len(qs), "rows": rows}, open(a.out, "w"), indent=1)


if __name__ == "__main__":
    main()
