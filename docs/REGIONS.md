# Road routing by region

How Cache gets the road tiles it routes on: a person downloads the regions they want (a state, a park, a corridor), and a
route planned online first fetches the tiles near its points. The Rust core does all of it (`cache_regions`); the app
passes the region outlines in and shows the progress. The C ABI is `cs_regions_*` in `cache_search.h`.

## What the server publishes

Under `https://data.cached.info/routing/` (the default; `https://cache.echo6.co/routing/` serves the same files):

- `current.json`: the build in use, for example
  `{"format": 1, "build": "na-2026-10-18", "valhalla": "3.7.0", "source": "...", "tiles": 30720, "bytes": ..., "gz_bytes": ..., "index": "na-2026-10-18/index.tsv.gz", "index_sha256": "<hex>"}`.
  `index_sha256` is the SHA-256 of the gzip file as published.
- `<build>/index.tsv.gz`: one line per tile that has roads, sorted:
  `<path>\t<bytes>\t<sha256 of the tile>\t<gzip bytes>`, with `path` like `2/000/818/660` (no extension).
  A tile that is not in the index has no roads.
- `<build>/<path>.gph.gz`: each tile, gzipped.

Valhalla's tiling is fixed: level 0 is 4 degree tiles, level 1 is 1 degree, level 2 is 0.25 degree, over the world from
(-180, -90). A tile's id is row times columns plus column, and its path is the level, then the id zero padded to the digits
of the level's largest id (rounded up to a multiple of 3) in groups of 3. So the phone works out which tiles a region needs
from the region's outline alone: every tile, at every level, whose cell the outline overlaps (holes left out) and that the
index lists. Nothing is cut on the server per region.

Tiles of one build fit together, so the tiles of any regions together make one map. Tiles of different builds are never
mixed.

Region outlines come from the region catalogue (`https://cache.echo6.co/regions/polygons/<id>.geojson`, a GeoJSON Feature
with a Polygon or MultiPolygon, longitude and latitude). The app fetches them; the core takes the geometry as given.

## On the device

In the folder given as `dir`:

- `regions.sqlite`: the device's build, the regions (id, name, outline, error), each region's tile list, and the stream
  cache (tiles fetched for routes, with when each was last used).
- `tiles/<build>/<path>.gph`: the tiles. This folder is what Valhalla routes on (`mjolnir.tile_dir`).
- `index/<build>.tsv`: the build's index, kept once it was checked against `index_sha256`.

A tile is fetched, unpacked, checked against the size and SHA-256 in the index, written under a hidden name in its folder,
flushed and renamed into place. So a tile in the folder is always whole, and a download that was stopped carries on from
the tiles already there (hidden files left by a stopped write are deleted when the engine opens). A tile that fails its
check is tried 4 times in all; then every region that needs it is `failed`, with the reason.

Regions share tiles: a tile two regions need is stored and fetched once, and removing a region deletes only the tiles no
other region and no stream cache entry uses (and the folders that leaves empty).

The stream cache holds the tiles fetched for routes that belong to no region, up to `stream_cap_bytes` (2 GiB by default).
Above that, the least recently used go first. A region's tiles are never evicted, and neither are the tiles of the route
just prepared.

When a newer build is published, `update` fetches every region's tiles of the new build into `tiles/<new build>/`. Until
all of them are there the device keeps routing on the old build; then it switches, deletes the old build's folder and
index, and empties the stream cache.

Downloads respect the network policy exactly as sync does: with `"network": false` no request is made at all, and status
says `"Paused: no network it may use"`. Before a region starts, the free space is checked against what it needs plus a
reserve (`reserve_bytes`, 1 GiB by default); if it is short the download pauses with the reason.

## Methods

`cs_regions_call(handle, method, args)`, answers in JSON; a failure is `{"error": "...", "code": "..."}`.

**status** `{}`

```json
{"build": "na-2026-10-18", "tile_dir": ".../tiles/na-2026-10-18",
 "regions": [{"id": "idaho-south", "name": "Southern Idaho", "state": "downloading", "tiles": 412, "bytes": 301234567,
              "done_tiles": 120, "done_bytes": 88001234, "error": null}],
 "stream": {"tiles": 14, "bytes": 9123456, "cap": 2147483648},
 "update": null,
 "paused": null}
```

`state` is `downloading`, `ready`, `paused` or `failed`. `update`, after `check_update` found a newer build, is
`{"build", "download_bytes", "downloading"}` (`downloading` once `update` has started it). `build` and `tile_dir` are
null until the device has a build.

**plan** `{"id", "name", "geometry"}`: what adding the region would take, without adding it.
`{"tiles": 412, "bytes": 301234567, "download_bytes": 98765432, "shared_tiles": 37}`: `bytes` is the tiles' size on the
device, `download_bytes` the gzip bytes still to fetch (tiles not already here), `shared_tiles` those already here.
Fetches `current.json` and the index first if needed; `offline` when it cannot.

**add** `{"id", "name", "geometry"}`: records the region and its tile list and starts the download in the background.
`{"ok": true, "tiles": 412, "bytes": 301234567, "download_bytes": 98765432}`. Adding an id again replaces its outline (and
tries a failed region again).

**remove** `{"id"}`: `{"ok": true, "deleted_tiles": 375}`.

**stream** `{"points": [[lat, lon], ...], "timeout_ms": 20000}`: for a route about to be computed online, fetches the
tiles it is likely to need that are not here: the level 0 and 1 tiles over the box around the points widened by 0.5
degrees, and the level 2 tiles within 0.3 degrees of each point. `{"fetched": 6, "missing": 0, "ok": true}`. Never an
error: offline, or with the network off, it returns at once with `"ok": false`, and the route uses the tiles there are.
The navigate tool calls this itself (with the trip's start, end and via points) when the core's config has a `regions`
section.

**set_policy** `{"network": bool, "reserve_bytes": n}` (either may be left out): `{"ok": true}`.

**check_update** `{}`: `{"build": "na-2026-11-15", "update": {"build": "na-2026-11-15", "download_bytes": 101234567}}`,
or `"update": null` when the device has the server's build (a device with no regions just moves to it).

**update** `{}`: `{"ok": true, "build": "na-2026-11-15", "download_bytes": 101234567}`; the download runs in the
background and the device switches when it is complete (status shows it).

## With the search core

A `regions` section in the `cs_open` config (`{"dir", "base_url"}`) opens the same engine (one per folder in the process),
so the app opens it once and the navigate tool shares it. Then `routing.valhalla.tiles` may be left out: the tool routes
on the engine's `tile_dir`, names the region from `routing.valhalla.region` (for example "Southern Idaho, Utah"), and gives
its age from the newest tile. A `tiles.tar` that exists is still used as before, and nothing is streamed for it.
