# Places in regions

How Cache gets the places, towns and addresses it searches: they are part of a region download, next to road routing and
the map. The server publishes places cut on Valhalla's level 1 grid, the way routing tiles are published, and the phone
merges the tiles it has into one database that every search reads. A search in an area with nothing downloaded fetches the
tiles around it first, when the network may be used. The Rust core does all of it (`cache_regions` downloads and merges,
`cache_places` reads); the app passes the region outlines in and shows the progress. See [REGIONS.md](REGIONS.md) for the
routing part, which this extends.

## What the server publishes

The default host is `https://data.cached.info`. `https://cache.echo6.co` serves the same bucket with the same paths, and
keeps working. The address is a config value (`places_base_url`), so moving hosts needs no new code.

Under `https://data.cached.info/places/`:

- `current.json`: the build in use, for example

  ```json
  {"format": 1, "component": "places", "tile_schema": 1, "build": "na-places-2026-11-15", "levels": [1],
   "overture_release": "2026-10-22.0", "osm_source": "Geofabrik north-america-latest.osm.pbf (md5 ...)",
   "sources": "Overture places+addresses <release>; OpenStreetMap; Wikipedia/Wikidata (enwiki <date>)",
   "embed_model": "bge-m3-Q8_0", "embed_dims": 1024,
   "tiles": 6012, "bytes": 0, "gz_bytes": 0,
   "index": "na-places-2026-11-15/index.tsv.gz", "index_sha256": "<hex>",
   "common": "na-places-2026-11-15/common.sqlite.gz", "common_sha256": "<sha256 of the unpacked file>",
   "common_bytes": 0, "common_gz_bytes": 0}
  ```

  `index_sha256` is the SHA-256 of the gzip file as published, as for routing; `common_sha256` is the SHA-256 of the
  common file unpacked, as each tile's is. `tile_schema` is the layout of the tiles and the common file: a phone that does
  not know the number says "update Cache to use this data" without downloading anything. A routing `current.json` has no
  `component`, `tile_schema` or `levels`, and means routing, levels 0 to 2. The build name is `na-places-YYYY-MM-DD` and
  must be safe as a folder name; `index` and `common` must stay under the base address.
- `<build>/index.tsv.gz`: the same four columns as routing's index, one line per tile that has any places, towns or
  addresses, sorted: `<path>\t<bytes>\t<sha256 of the tile>\t<gzip bytes>`, with `path` like `1/047/586` (no extension).
  Level 1 only.
- `<build>/common.sqlite.gz`: everything of the build that is not per tile (below).
- `<build>/<path>.sqlite.gz`: each tile, gzipped.

They are uploaded in this order: tiles, the common file, the index (all cached for a year; a build's files never change),
then `current.json` last (cached for five minutes).

### The grid

Valhalla's level 1: 1 degree tiles over the world from (-180, -90), id = row * 360 + column, path `1/` then the id zero
padded to 6 digits in two groups of 3 (`1/047/586`). Every place, town and house number is a point and is in exactly one
tile, the one whose cell holds it; a point on a cell edge goes to the cell north-east of it. A region takes every level 1
tile its outline touches (the routing rule). `cache_places::schema::tile_id_l1` and `tile_path_l1` compute it, and agree
with `cache_regions::geo` (a test checks).

### The files

The exact layouts are in `cache_places/src/schema.rs`: `COMMON_SQL`, `TILE_SQL` and `TILE_SCHEMA` (1).

- **The common file** has the build's meta (`tile_schema`, `build`, `built_at`, `overture_release`, `osm_source`,
  `sources`, `builder_rules`, `attribution`, `embed_model`, `embed_dims`, `embed_model_sha256`, `levels`), the
  categories, the kinds of place with a one-line description each, every state and province, and one vector per category
  and kind (`"{title}: {description}"`, bge-m3).
- **A tile** has meta (`tile_schema`, `build`, `tile`, `path`, `counts`: a JSON object with the number of `places`,
  `localities`, `localities_ctx`, `addr_streets` and `addresses`), its places and towns, the towns outside it within 25 km
  (`localities_ctx`, used only while their own tile is not on the phone), its streets with house numbers (`addr_streets`),
  the vectors of its notable places and towns (those with a Wikipedia summary, `"{name}. {summary}"`), and how many places
  of each category and kind it holds (`tile_counts`). Row ids are local, 1 to 2^24 - 1. A tile has no full-text or
  R-tree index: the phone builds those as it merges.
- **A street row** is one street within one tile, grouped by the street as the source writes it, the postcode and the
  postal city or town. `street` is the source's form ("MAIN ST") and `street_expanded` the same with its USPS Publication
  28 street suffix and directional abbreviations written out ("MAIN STREET"), or null when that changes nothing; both are
  searched. The expansion is applied to the data when it is built, never to what a person types. `uid` is stable across
  builds of the same data. `numbers` holds every house number of the row with its point (`cache_places::addr`):

  ```
  numbers := ver:u8 (=1) count:varint entry*count
  entry   := dnum:varint            numeric part minus the previous entry's (first: minus 0); sorted by (num, suffix)
             suf_len:u8 suf:utf8    the rest of the number after its leading digits ("A", "-1/2", "" = none)
             dlat:zigzag-varint     latitude  in 1e-6 degrees minus the previous entry's (first: minus the row's lat)
             dlon:zigzag-varint     longitude in 1e-6 degrees minus the previous entry's (first: minus the row's lon)
  ```

  The numeric part is the leading digits when they are a plain number (no leading zero) that fits 32 bits; any other
  number ("0", "007", "A12") has numeric part 0 and the whole number as its suffix, so every number reads back exactly as
  written. Units are dropped, and a number that appears twice in a row is kept once, with its first point.

## On the device

In the regions folder (`dir`):

- `places/CURRENT`: the places build in use (`na-places-2026-11-15`), written whole and renamed into place.
- `places/<build>.sqlite`: the merged database, the one file every search reads (`MERGED_SCHEMA`, pack format 3, WAL).
  Its `tiles` table says which tiles the phone has; it changes in the same transaction as the data.
- `places/<build>/common.sqlite`: the build's common file, kept (it is small) to create the database again.
- `places/index/<build>.tsv`: the build's index.
- `places/.incoming/<build>/<path>.sqlite`: a tile between its download and its merge (by build, as an update fetches the
  new build's tiles while searches still stream the old one's); deleted after, and any left over is deleted when the engine
  opens.

In the merged database every place, town, context town and street id is `(tile << 24) | local id`, so a tile is one id
range and removing it is a range delete; full-text rowids, R-tree ids and vector refs use the same ids. Category and kind
place counts are the sums of the tiles' counts, so they always match what is on the phone. A tile is fetched, unpacked,
checked against the size and SHA-256 in the index, and merged in one transaction; merging a tile that is already there
replaces it. The engine is the one writer and merges one tile at a time; searches read through their own connections and
are never blocked by a merge.

Places and routing each have their own build, `current.json`, index, update and stream cache: Overture is released
monthly and routing quarterly, and neither waits for the other. Builds of places are never mixed: an update builds the new
database from the new common file and every region's tiles of the new build, keeps searching on the old one until it is
complete, then switches `CURRENT`, deletes the old database and empties the places stream cache.

## Methods

These are additions to `cs_regions_call` ([REGIONS.md](REGIONS.md)); everything there keeps working, and an answer keeps
routing's fields where it had them. The places component is on when the regions config has `places_base_url`:

```json
{"dir": ".../regions", "base_url": "https://data.cached.info/routing/",
 "places_base_url": "https://data.cached.info/places/", "places_stream_cap_bytes": 536870912}
```

`places_stream_cap_bytes` is 512 MiB by default. Without `places_base_url` there is no places part, as before.

**plan** `{"id", "name", "geometry", "parts"?: ["routing", "places"]}`: `parts` is every enabled part when left out.

```json
{"tiles": 412, "bytes": 301234567, "download_bytes": 98765432, "shared_tiles": 37,
 "parts": {"routing": {"tiles": 412, "bytes": 301234567, "download_bytes": 98765432, "shared_tiles": 37},
           "places":  {"tiles": 4, "bytes": 61000000, "download_bytes": 23100000, "shared_tiles": 0}}}
```

The top-level fields are routing's. Places `download_bytes` is the gzip bytes of its tiles not on the phone, plus
`common_gz_bytes` when the phone has no places build yet. A part that cannot be planned has `{"error": "...", "code":
"offline"}` as its entry; the other part is still planned.

**add** `{"id", "name", "geometry", "parts"?}`: records the region with its parts and starts each part's download (places
first, as it is small). Adding the region again with more parts adds those parts. The answer has the same `parts` shape.

**remove** `{"id"}`: removes the region from every part. A places tile goes when no other region and no stream cache entry
needs it. `{"ok": true, "deleted_tiles": 375, "parts": {"routing": {"deleted_tiles": 371}, "places": {"deleted_tiles": 4}}}`.

**status** `{}`: each region gains `parts`, and its `state` combines them (`failed`, else `paused`, else `downloading`, else
`ready`). A failing places tile fails only that region's places part, with the reason. Two top-level objects are added:

```json
"regions": [{"id": "us-ut-wasatch-front", "name": "Wasatch Front", "state": "downloading", "tiles": 30, "...": "...",
             "parts": {"routing": {"state": "ready", "tiles": 30, "bytes": 0, "done_tiles": 30, "done_bytes": 0, "error": null},
                       "places":  {"state": "downloading", "tiles": 4, "bytes": 0, "done_tiles": 2, "done_bytes": 0, "error": null}}}],
"places": {"build": "na-places-2026-11-15", "db": ".../regions/places/na-places-2026-11-15.sqlite", "tiles": 4,
           "generation": 17, "stream": {"tiles": 2, "bytes": 9123456, "cap": 536870912}, "update": null},
"updates": {"routing": null, "places": {"build": "na-places-2026-12-15", "download_bytes": 23100000, "downloading": false}}
```

`places.generation` goes up by one on every merge, removal and build switch; the app watches it and runs the open search
again. `places.build` and `places.db` are null until the phone has a places build.

**stream** `{"component": "places", "points": [[lat, lon], ...], "timeout_ms": 3000}`: fetches and merges the level 1
tiles within 0.5 degrees of each point that are not on the phone. The fetches run in the background and the call waits at
most `timeout_ms`; a tile already being fetched is waited for, never fetched twice. `{"fetched": 1, "pending": 1,
"missing": 0, "ok": true}`. With no places build yet it first fetches `current.json`, the index and the common file and
creates the database. Never an error: offline, or with the network off, it returns at once with `"ok": false`. Streamed
tiles go in the places stream cache; above `places_stream_cap_bytes` the least recently used are removed. A region's tiles
are never removed. Without `component` it is routing's stream, as before.

**check_update** / **update** `{"component"?: "routing" | "places"}`: one part, or both when left out. Routing's answer is
as before; places' is the same shape under `updates.places` in status.

## With the search core

`cs_open`'s `places` section gains `merged_dir`, the folder that holds `CURRENT`:

```json
{"packs": [".../packs/idaho/places.sqlite"], "merged_dir": ".../regions/places"}
```

`packs` are single-region packs (format 1 or 2, copied in by hand); they are still read, after the merged database. When
the config also has a `regions` section and no `merged_dir`, the core uses the regions engine's folder, so the merged
database is found with no path from the app. A tile merged while the core is open is searched by the next call, with no
restart and no reopen.

**cs_map_search** gains two fields in its answer, next to `warning` (which stays, for older apps):

```json
"places": {"installed": true, "covers": false, "pending": 1},
"warning_code": "fetching"
```

`installed`: any places data is on the phone. `covers`: a tile (or pack) on the phone holds the search centre. `pending`:
tiles for this search still on their way. `warning_code` is left out when there is nothing to say, else:

| Code | When |
|---|---|
| `no_places` | Nothing is installed, and nothing could be fetched (offline, network off, or a failure). |
| `not_here` | Something is installed, but nothing covers the search centre, and fetching was not possible. |
| `fetching` | A tile for this area is still arriving. |

Before it searches, `cs_map_search` fetches the tiles around the search centre (waiting up to 3 seconds) when the network
may be used; `nearby` and the navigate tool's `to_type` wait up to 20 seconds. Results can also be addresses:
`"type": "address"`, `"kind": "Address"`, `"kind_id": "address"`, `"name": "350 N State St"`, `"address": "350 N State St,
Salt Lake City, UT"`, `"id": "addr:<uid>/<number>"` (a route end for `cs_map_route`), and `"approximate": true` when the
number was placed between its neighbours rather than found. A kind of place matched by meaning is a row
`{"id": "kind:<kind id>", "type": "category", "name": <label>, "category": <its category or null>, "matched": "meaning"}`,
followed by its nearest places; `kind:` ids are route ends too (the nearest place of that kind).

**cs_places_refresh**

```c
char *cs_places_refresh(cs_handle *h, const char *args_json);
```

`{"packs"?: ["..."]}`: replaces the list of single-region packs when given, and makes the next search check everything
again (the merged database's `CURRENT` and its data, and every pack file). Answers `{"ok": true, "packs": 2, "merged": true}`
(`packs`: the single-region packs found; `merged`: a merged database is open). Cheap, and safe to call often; the app
calls it when `places.generation` changes and when its sources are refreshed.
