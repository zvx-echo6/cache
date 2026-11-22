#!/usr/bin/env python3
"""Builds the two tile folders the stream_connectivity test needs, from an extracted Idaho tile dir.
Usage: route_islands.py <all-tiles> <out-dir>
  island  = the destination's downloaded region: levels 0, 1, 2 over the destination box widened 0.75 deg.
  fetched = what cache_regions stream() adds for the trip start -> destination, minus what the island already holds:
            level 0 and 1 over the two stops' box widened 0.5 (STREAM_BOX_DEG), level 2 within 0.3 (STREAM_NEAR_DEG) of the START.
Mirrors cache_regions/src/geo.rs (tiles_in_box, tile_path) and cache_regions/src/index.rs (Index::tiles_near); the index there
is the set of tiles present here. Python -I safe: stdlib only."""
import os, shutil, sys

START = (42.57368, -114.60665)  # lat, lon (Twin Falls)
DEST = (43.49270, -112.04080)   # Idaho Falls
SIZE = [4.0, 1.0, 0.25]

def columns(l): return round(360.0 / SIZE[l])
def rows(l): return round(180.0 / SIZE[l])
def col_of(l, lon): return min(max(int((max(-180.0, min(180.0, lon)) + 180.0) // SIZE[l]), 0), columns(l) - 1)
def row_of(l, lat): return min(max(int((max(-90.0, min(90.0, lat)) + 90.0) // SIZE[l]), 0), rows(l) - 1)

def tiles_in_box(l, b):  # geo.rs tiles_in_box: [west, south, east, north]
    if b[0] > b[2] or b[1] > b[3]: return []
    return [r * columns(l) + c for r in range(row_of(l, b[1]), row_of(l, b[3]) + 1) for c in range(col_of(l, b[0]), col_of(l, b[2]) + 1)]

def tile_path(l, i):  # geo.rs tile_path
    mx = columns(l) * rows(l) - 1
    w = -(-len(str(mx)) // 3) * 3
    d = str(i).zfill(w)
    return "/".join([str(l)] + [d[k:k + 3] for k in range(0, len(d), 3)])

def tiles_near(points, box_deg, near_deg):  # index.rs tiles_near, as (level, id) keys
    w = min(p[1] for p in points); e = max(p[1] for p in points)
    s = min(p[0] for p in points); n = max(p[0] for p in points)
    wide = [w - box_deg, s - box_deg, e + box_deg, n + box_deg]
    keys = set()
    for l in range(2):
        keys |= {(l, i) for i in tiles_in_box(l, wide)}
    for lat, lon in points:
        keys |= {(2, i) for i in tiles_in_box(2, [lon - near_deg, lat - near_deg, lon + near_deg, lat + near_deg])}
    return keys

def main():
    allt, out = sys.argv[1], sys.argv[2]
    have = lambda k: os.path.exists(f"{allt}/{tile_path(*k)}.gph")
    d = 0.75
    box = [DEST[1] - d, DEST[0] - d, DEST[1] + d, DEST[0] + d]
    island = {(l, i) for l in range(3) for i in tiles_in_box(l, box)}
    island = {k for k in island if have(k)}
    # stream(): need = tiles_near(points, 0.5, 0.3); the level 2 part near the destination is already in the island.
    start_only = tiles_near([START], 0.5, 0.3)
    wide_both = tiles_near([START, DEST], 0.5, 0.3)
    fetched = {k for k in wide_both if k[0] < 2 or k in start_only} - island
    fetched = {k for k in fetched if have(k)}
    for name, ks in (("island", island), ("fetched", fetched)):
        shutil.rmtree(f"{out}/{name}", ignore_errors=True)
        for k in sorted(ks):
            p = f"{tile_path(*k)}.gph"
            os.makedirs(os.path.dirname(f"{out}/{name}/{p}"), exist_ok=True)
            shutil.copy(f"{allt}/{p}", f"{out}/{name}/{p}")
        print(name, {l: sum(1 for k in ks if k[0] == l) for l in range(3)}, "total", len(ks))
if __name__ == "__main__":
    main()
