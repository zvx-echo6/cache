#!/usr/bin/env python3
"""Rebuilds the off-road part of the region list's sizes (sizes.offroad.packs) with the rule the app uses.

The region list (data host, regions/<iso>.json) gives each region the off-road packs it needs and their sizes, worked out when the
list was built. The app now chooses a region's packs by `packsCovering` (app/lib/regions/offroad_catalogue.dart) and `statesIn`
(app/lib/regions/region_catalogue.dart): a region in a state or province gets that state's pack and no neighbour's (a metro area
across a state line gets one for each of its states); a region with no state of its own (a region larger than a state, a state with
no pack) gets, when a pack's box holds all of it, the pack it lies deepest inside, else every pack whose box reaches it. The list
still named, near a state line, the neighbouring state's pack when that box was the smaller one, so its sizes and its Add off-road
parts disagreed with what the app downloads.

Only `sizes.offroad.packs` changes: the same packs as the app picks, each with the bytes of its `offroad.sqlite` in the off-road
catalogue (current.json). Everything else in each record, and every other byte of the file, is as it was. `terrain` depends on the
region's box only, so it stays. A region that had no off-road part still has none; one that had gets at least its own state's pack.

  resize_offroad.py --shards DIR --offroad current.json --out DIR [--old-rule]

DIR holds <iso>.json shards (compact JSON, as published). Nothing is uploaded or published. `--old-rule` applies the earlier rule
(the smallest box that holds the region): the list as published reproduces under it, which is how this reimplementation was checked.
"""
import argparse
import json
import math
import os
import re
import sys


def slug(s):
    return re.sub(r"^-+|-+$", "", re.sub(r"[^a-z0-9]+", "-", (s or "").lower()))


def boxes(b):
    """[west, south, east, north] as one or two boxes (west greater than east crosses the antimeridian, RFC 7946)."""
    w, s, e, n = b
    return [[w, s, 180.0, n], [-180.0, s, e, n]] if w > e else [[w, s, e, n]]


def meets(p, b):
    return any(p["bbox"][0] < x[2] and p["bbox"][2] > x[0] and p["bbox"][1] < x[3] and p["bbox"][3] > x[1] for x in boxes(b))


def holds(p, b):
    return b[0] <= b[2] and p["bbox"][0] <= b[0] and p["bbox"][1] <= b[1] and p["bbox"][2] >= b[2] and p["bbox"][3] >= b[3]


def depth(p, b):
    k = math.cos((b[1] + b[3]) / 2 * math.pi / 180)
    return min((b[0] - p["bbox"][0]) * k, (p["bbox"][2] - b[2]) * k, b[1] - p["bbox"][1], p["bbox"][3] - b[3])


def is_pack_of(p, s):
    pc, sc = p.get("country"), s.get("country")
    if pc and sc and pc.upper() != sc.upper():
        return False
    name = slug(s.get("name"))
    return bool(name) and (name == p["id"] or name == slug(p.get("name")))


def states_in(records, rid):
    """The states or provinces (kind `region`) the list says `rid` is in (app/lib/regions/region_catalogue.dart statesIn)."""
    r = records.get(rid)
    if r is None:
        return []
    is_state = lambda x: x is not None and x.get("kind") == "region"
    if is_state(r):
        return [r]
    above, todo = [], [rid]
    seen = set()
    while todo:
        for p in (records.get(todo.pop(0)) or {}).get("parents", []):
            if p not in seen:
                seen.add(p)
                above.append(p)
                todo.append(p)
    up = [records[p] for p in above if is_state(records.get(p))]
    if up:
        return up
    by_id = records.get("-".join(rid.split("-")[:2]))
    return [by_id] if is_state(by_id) else []


def packs_covering(packs, b, states=()):
    """app/lib/regions/offroad_catalogue.dart packsCovering."""
    near = [p for p in packs if meets(p, b)]
    own = [p for p in near if any(is_pack_of(p, s) for s in states)]
    if own:
        return own
    whole = [p for p in near if holds(p, b)]
    if not whole:
        return near
    best = whole[0]
    for c in whole[1:]:
        if depth(c, b) > depth(best, b):
            best = c
    return [best]


def old_packs_covering(packs, b):
    """The rule before: the smallest box that holds the region, else every pack that reaches it."""
    near = [p for p in packs if meets(p, b)]
    whole = [p for p in near if holds(p, b)]
    if not whole:
        return near
    return [min(whole, key=lambda p: (p["bbox"][2] - p["bbox"][0]) * (p["bbox"][3] - p["bbox"][1]))]


def pack_bytes(p):
    return int(p["files"]["offroad.sqlite"]["bytes"])


def resize(shard, packs, old_rule=False):
    """Returns (new shard, changes): changes are (id, name, old packs, new packs) for each region whose packs changed."""
    records = {r["id"]: r for r in shard["regions"]}
    changes = []
    for r in shard["regions"]:
        off = (r.get("sizes") or {}).get("offroad")
        if off is None or not r.get("bbox"):
            continue
        chosen = old_packs_covering(packs, r["bbox"]) if old_rule else packs_covering(packs, r["bbox"], states_in(records, r["id"]))
        new = {p["id"]: pack_bytes(p) for p in chosen}
        old = off.get("packs", {})
        if new != old:
            changes.append((r["id"], r["name"], dict(old), new))
            off["packs"] = new
    return shard, changes


def load_packs(path):
    d = json.load(open(path, encoding="utf-8"))
    if d.get("component") != "offroad":
        sys.exit("not an off-road catalogue: " + path)
    return [p for p in d["regions"] if p.get("bbox") and p.get("files", {}).get("offroad.sqlite")]


def dump(d):
    return json.dumps(d, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--shards", required=True)
    ap.add_argument("--offroad", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--old-rule", action="store_true")
    a = ap.parse_args(argv)
    packs = load_packs(a.offroad)
    os.makedirs(a.out, exist_ok=True)
    total = 0
    for name in sorted(os.listdir(a.shards)):
        if not name.endswith(".json") or name.endswith(".search.json") or name in ("index.json", "manifest.json", "search-global.json"):
            continue
        raw = open(os.path.join(a.shards, name), "rb").read()
        shard = json.loads(raw)
        if "regions" not in shard:
            continue
        shard, changes = resize(shard, packs, a.old_rule)
        total += len(changes)
        open(os.path.join(a.out, name), "wb").write(dump(shard))
        with open(os.path.join(a.out, name + ".changes.jsonl"), "w", encoding="utf-8") as f:
            for c in changes:
                f.write(json.dumps({"id": c[0], "name": c[1], "old": c[2], "new": c[3]}) + "\n")
        print(f"{name}: {len(changes)} regions changed")
    print(f"{total} regions changed in all")


if __name__ == "__main__":
    main()
