# Map layers: the layer engine

Cache's map is a framework. The core knows kinds of layers and the transforms that make them drawable; it never knows any one server. A layer is a **definition file** (data, never code). The Rust crate `cache_layers` (`native/cache_layers`) reads definitions, serves tiles to the map on `127.0.0.1`, downloads areas for offline use into one merged tile store per layer, generates contours and land-cover tiles, and exposes the same through the C ABI (`cs_layers_*`, `layer_download` job), the `cs layers` CLI and `cs serve` (`/layers/...`).

## Layer definition, format 1

One JSON object per file (a file may also hold a JSON list of them, as a catalogue does). Unknown fields are ignored and kept when a user definition is saved.

```json
{
  "format": 1,
  "id": "public-lands",
  "title": "Public lands",
  "description": "one line for the catalogue",
  "kind": "vector",
  "transform": "as_is",
  "derived_from": "<layer id>",
  "source": {"type": "pmtiles", "url": "https://...", "minzoom": 0, "maxzoom": 14,
             "encoding": "terrarium", "tile_format": "mvt", "tile_size": 256, "grid_deg": 3},
  "attribution": "...", "license": "...",
  "coverage": {"bbox": [-180, -85, 180, 85]},
  "offline": {"allowed": true, "max_tiles_per_download": 3000, "max_bytes_per_download": 52428800,
              "max_parallel": 4, "source": {"type": "pmtiles", "url": "https://..."}},
  "update": {"version": "2026-10-25", "check_url": "https://...", "interval_days": 30},
  "style_hints": {},
  "recipe": "https://... (informational)",
  "enabled_by_default": true
}
```

| Field | Rules |
|---|---|
| `format` | Must be `1`. |
| `id` | 1-64 characters of `a-z 0-9 - _`, starting with a letter or digit. Also the folder and URL name. |
| `title`, `description` | Shown in the catalogue. `title` is required. |
| `kind` | `vector`, `raster`, `elevation` or `online-raster`. What the layer *serves*. |
| `transform` | `as_is`, `hillshade`, `contours`, `raster_window`, `online_only` (below). |
| `derived_from` | Required for `hillshade` and `contours` (id of an `as_is` elevation layer), forbidden otherwise. A derived layer has no `source`. |
| `source.type` | `pmtiles` (byte-range reads of a remote archive), `xyz` (URL template with `{z}` `{x}` `{y}`; `{-y}` for TMS rows), `tilejson` (URL of a TileJSON whose first `tiles` address is used; the document is cached for offline), `cog` (cloud-optimised GeoTIFFs, see `raster_window`). |
| `source.minzoom/maxzoom` | Zoom range of the source (default 0 to 22). Outside it the server answers an empty tile. |
| `source.encoding` | Elevation layers: `terrarium` (the only one supported). |
| `source.tile_format` | `mvt`, `png`, `webp` or `jpg`. Decides the MIME type. |
| `source.tile_size` | Pixels of a raster tile (256 if absent). Mapterhorn is 512. |
| `source.grid_deg` | `cog` only: size in degrees of the grid of files (3 for ESA WorldCover). |
| `coverage.bbox` | `[west, south, east, north]`; goes into the TileJSON `bounds`. |
| `offline.allowed` | `false` makes the layer streaming-only. `online_only` layers can never allow it. Default true. |
| `offline.max_tiles_per_download`, `max_bytes_per_download` | Optional. Enforced before a download starts (from the plan) **and** on the bytes actually written. |
| `offline.max_parallel` | Optional (default 4). At most this many simultaneous requests per layer, shared by the tile server and download jobs of the process. |
| `offline.source` | Optional. Where **area downloads** read from when that differs from `source`. See "What this design needed". |
| `update.version` | The version this definition describes. A downloaded area records it; a different current version makes the layer `update_available`. |
| `update.check_url`, `interval_days` | `check_url` returns JSON with a `"version"` string; `cs_layers_refresh` reads it. |
| `style_hints` | Passed through to the app untouched (and into the TileJSON). The app owns styling. |
| `layout` | Optional. The tile schema of a vector layer (`protomaps-v4`, `openmaptiles`, ...). Passed through to the app, which picks the style for it; also in the TileJSON. |
| `recipe` | URL of the recipe that built it. Informational. |
| `enabled_by_default` | `false`: the catalogue lists the layer but the app leaves it off until the user turns it on (default true). |

URLs must be `https`; plain `http` is accepted only to this machine (tests, a user's own server). Validation reports every problem at once (`bad_json`). Definitions that fail validation are listed in `invalid` with the file and reason, and never stop the others loading.

### Where definitions come from

Later wins by `id`: read-only folders (`layers.defs_dirs`, the starter definitions shipped with the app), then the downloaded catalogue (`<dir>/catalogue.json`: every address in `layers.catalogue_urls`, fetched and merged by `cs_layers_refresh`; the default list is `["https://cache.echo6.co/catalogue.json"]`, `[]` turns it off, users add their own), then **user definitions** (`<dir>/user-defs/<id>.json`, written by `cs_layers_save`, removed by `cs_layers_remove`). The Advanced section of the app is `save` and `remove`; a user pointing Cache at their own server is a definition with their URL.

### Starter definitions (`packages/cache_search/layers/`)

| File | id | What |
|---|---|---|
| `openfreemap.json` | `openfreemap` | An alternative base map (`layout` `openmaptiles`, `enabled_by_default: false`; the default base map is the `basemap` layer of the Cache catalogue, Protomaps v4 on R2), OpenFreeMap TileJSON `https://tiles.openfreemap.org/planet`, MVT, z0-14. Offline limits from OpenFreeMap's terms: 3,000 tiles or 50 MB per download, 4 parallel. Attribution "OpenFreeMap © OpenMapTiles Data from OpenStreetMap". |
| `mapterhorn.json` | `elevation` | Terrarium WebP, 512 px, z0-12. Streams from `https://tiles.mapterhorn.com/tilejson.json`; area downloads read `https://download.mapterhorn.com/planet.pmtiles`. Attribution "© Mapterhorn". `update.check_url` is Mapterhorn's `download_urls.json`. |
| `hillshade.json` | `hillshade` | `hillshade` derived from `elevation`. |
| `contours.json` | `contours` | `contours` derived from `elevation`. |
| `worldcover.json` | `landcover` | ESA WorldCover 2021 v200, `raster_window` over `https://esa-worldcover.s3.eu-central-1.amazonaws.com/v200/2021/map/ESA_WorldCover_10m_2021_v200_{lat}{lon}_Map.tif` (AWS Open Data registry entry `esa-worldcover-vito`). CC BY 4.0. |
| `usgs-imagery.json` | `usgs-imagery` | USGS The National Map "USGS Imagery Only" (mostly NAIP, about 1 m), xyz `.../tile/{z}/{y}/{x}`, public domain, `max_tiles_per_download` 100000 (the service reports `exportTilesAllowed` true and 100,000 per export). |
| `esri-world-imagery.json` | `esri-world-imagery` | Esri World Imagery, `online_only`, never offline, `enabled_by_default: false`, description "Online only. Esri's terms apply". |

### Source health

`cs_layers_list` reports `health` for every layer: how its source has been answering in the last 10 minutes (`state` `unknown | ok | degraded | unreachable`, `recent_requests`, `recent_failures`, `recent_timeouts`, `last_success_at`, `last_failure`). "unreachable" means the last three requests all failed. It is for error messages ("the base map host is not answering"); the engine does not switch layers by itself.

## The transforms

- **`as_is`**: tiles are used unchanged from the source (vector, raster or elevation).
- **`hillshade`**: the elevation tiles are served unchanged. The TileJSON says `"type":"raster-dem"`, `"encoding":"terrarium"`, `"tileSize"`; MapLibre draws the shading. Downloading a hillshade layer downloads the elevation layer it derives from.
- **`contours`**: vector tiles generated on the fly from the elevation layer's tiles (downloaded, cached or streamed): MVT layer `contours`, extent 4096, properties `ele` (feet) and `level` (0 minor, 1 index). Interval in feet (minor, index) per zoom: z3 5000/25000, z4 2500/10000, z5-6 1000/5000, z7-8 500/2500, z9 250/1000, z10-11 200/1000, z12-13 100/500, z14 50/200, z15 20/100. Below z3 there are none; the TileJSON says `minzoom` 3 and `maxzoom` 15 (MapLibre overzooms past it). Above the elevation layer's `maxzoom` (12) the z12 parent tile is split (overzoom). Generated tiles go into the viewed-tile cache. Offline they need the elevation tiles of the tile and its eight neighbours; a tile whose neighbours are missing is served but not cached, so it is regenerated once the data is there.
- **`raster_window`**: a cloud-optimised GeoTIFF source (`source.type` `cog`). The URL template has `{lat}` and `{lon}`: the south-west corner of the grid cell, like `N42` and `W114` (`grid_deg`, 3 by default). For a tile, the core reads the file header, picks the overview that matches the tile's resolution, and range-reads only the 1024 px blocks the tile touches, then writes an **8-bit indexed PNG** (palette from the GeoTIFF's colour map, index 0 transparent) so the class value of every pixel survives for off-road routing. A tile with no data is empty (204). A missing file (open sea) is no data. Supported TIFFs: classic TIFF, tiled, 8-bit single band, no compression or Deflate (optional horizontal predictor), EPSG:4326 pixel scale and tie point. Area downloads render the tiles and keep them in the tile store like any other.
- **`online_only`**: a pass-through with the viewed-tile cache; never downloadable. Offline, an uncached tile is `503 needs a connection` (`cs_layers_plan` and `layer_download` fail with `offline`).

### Contour algorithm (credit)

The contour generator is a port of the approach of **maplibre-contour** (https://github.com/onthegomap/maplibre-contour, BSD 3-Clause, Copyright (c) 2023 Michael Barry and contributors), whose marching squares is adapted from **d3-contour** (ISC, Copyright 2012-2023 Mike Bostock), the same library navi uses in the browser. Note: the licence is BSD-3-Clause, not MIT. The steps are the same: the tile and its eight neighbours form one grid, so lines join across tile edges; overzoom splits the parent tile; tiles narrower than 100 px are upsampled bilinearly; pixel-centre values are averaged onto grid corners (four neighbours) and scaled to feet; one pass of marching squares builds the lines of every threshold at once, joining fragments as they meet; a 1-pixel buffer is generated around the tile (this port starts the buffer one column further left than the library, which has a degenerate first cell there). Added here: Douglas-Peucker simplification of every line (tolerance 2 units of 4096, closed rings are split at their farthest point), one feature per elevation, and a feet-per-zoom interval table. Elevations outside -12000..9000 m are no data (NaN) and break lines.

## The tile server

`cs_layers_server` starts it once per handle: `127.0.0.1`, a random port, 8 worker threads. It is the single place the map reads tiles from.

```
GET /layers/{id}/{z}/{x}/{y}[.ext]   a tile
GET /layers/{id}/tilejson.json       TileJSON 3.0 (also /layers/{id}.json)
GET /health                          {"ok":true}
```

For each tile request, in order:
1. **The layer's tile store** of downloaded areas (one lookup by z/x/y; a tile is served whichever area downloaded it, including tiles of an unfinished download).
2. **The viewed-tile cache** (`<dir>/tiles.sqlite`): size-capped (`cache_max_bytes`, default 256 MiB), least recently used evicted down to 90%. A tile the source said does not exist is remembered as empty for a day.
3. **The source**, only when the engine is online and the definition allows: `xyz` and `tilejson` by plain GET; `pmtiles` by byte-range reads (header and root directory once, leaf directories on demand, the tile itself); `cog` by range reads of blocks. The result is stored in the cache.

Answers: `200` with the tile and `X-Cache-Status: downloaded | cache | network | generated`; `204` empty tile (the source has none, or the zoom is outside the layer); `404` + `X-Cache-Status: miss` when the tile is not on the device and there is no connection; `503` + `needs-connection` for an online-only layer; `400/404/502` JSON `{"code","message"}` for real errors. Vector tiles are always sent uncompressed (gzip from sources and PMTiles is removed), with `Access-Control-Allow-Origin: *`. The app must allow cleartext traffic to `127.0.0.1` (Android network security config).

HTTP to sources: `User-Agent: Cache/<version>`, 4 attempts with exponential backoff (0.4 s doubling; `Retry-After` honoured, capped at 10 s) on timeouts, 429 and 5xx; 404/403/410/204 are "no tile", not errors. After two failed connections the engine treats the network as down for 15 seconds so a phone that is really offline answers misses at once instead of waiting on timeouts. The `max_parallel` gate is per layer and process-wide.

`cs_layers_server {"online": false}` (or `"layers": {"online": false}` in the config) makes the engine offline: nothing touches the network.

## Area downloads: one merged tile store per layer

Regions overlap heavily (a city inside a county inside a state), so downloads never duplicate tiles. Each layer has **one local tile store**, a SQLite file `<dir>/store/<layer>.sqlite`, with:

- `tiles(z, x, y, data, ver)`: every tile downloaded for the layer, once. `ver` is the layer version the tile was fetched at; empty `data` means "the source has no tile here" (so it is not asked again). Vector tiles are kept as the source sent them (gzip), other tiles as sent.
- `areas(id, state, meta)`: what was asked for: id, name, box or polygon, zoom range, layer version, tiles requested and present, bytes, date, and a state, `complete` or `partial`. The tiles an area needs are **computed from its shape** (polygon or box, at every zoom of its range: a tile counts if it touches the shape), never stored per area, so there is no reference table to drift out of step.
- `staging(z, x, y, data, ver)`: tiles of an update that has not been swapped in yet.

The tile server reads this store first (see "The tile server"). hillshade and contours share the elevation layer's store.

### Calls

`cs_layers_plan` (dry run), then `cs_job_start("layer_download", ...)`; see `cache_search.h`. A request is a `bbox` or a `polygon` (`[[lon, lat], ...]`, at least 3 points) plus a zoom range; the area id is given (`area`) or derived from the shape and zooms. **Polygons are first-class**: region definitions are county unions and city outlines. The cover of a polygon is computed per zoom (the tiles of its bounding box that intersect the polygon: a vertex inside the tile, a tile corner inside the polygon, or crossing edges).

- **Dry run** (`cs_layers_plan`): `tiles` (the cover), `tiles_to_download` (those not on the device yet), `tiles_already` and `already_bytes` ("adds 120 MB; 340 MB already downloaded"), `estimated_bytes` (of the tiles to download only), per-zoom counts, the layer's limits, free disk space, `mode`, and `problems` (`limit_exceeded`, `no_space`); `ok_to_start` is false if there are any. For `pmtiles` sources the size is **exact**, summed from the archive's directories (`estimate_method: "directory"`); for `xyz`, `tilejson` and `cog` it is an average over 6 evenly spaced missing tiles times their count (`"sample of 6 tiles"`). It needs a connection when there is something to fetch.
- **`mode`**: `new` (no such area), `extend` (the area exists, complete, same shape: fetches only tiles that are missing), `resume` (the area is `partial`), `update` (see below). Reusing an area id with a different shape or zoom range is refused (`bad_json`); delete it first or pick another id.
- **Limits** (`max_tiles_per_download`, `max_bytes_per_download`) apply to what is **fetched** by this download, not to tiles already on the device; the bytes limit is also enforced on what is written, and a download that exceeds it is undone (the tiles it added are removed). Free space is checked against the bytes to fetch before anything is fetched.
- **Download**: the area is recorded as `partial`, the missing tiles are fetched in batches (`max_parallel`, app User-Agent, retries) and committed to the store after each batch, then the area becomes `complete` with its tile and byte counts. Progress is `done/total` over the tiles to fetch, with `detail.bytes` written so far. A second area that is covered by tiles already stored fetches nothing.
- **Resume**: cancel (`cs_job_cancel`) or a crash leaves the area `partial` and its tiles in the store (they are served at once). The same request again fetches only what is still missing.
- **Update** (`"update": true` with the area id; shape and zooms come from the stored area): fetches every tile of the area whose `ver` is not the layer's current version into `staging`, and when all are there swaps them into `tiles` and records the area's new version in **one transaction**. Until then the old tiles keep serving, including after a cancel, and a restarted update keeps the staged tiles of the same version. A tile that another overlapping area already updated is not fetched again. `update_available` in `cs_layers_list` is true when a complete area's recorded version differs from the layer's current one (`update.version`, or what `cs_layers_refresh` read from `check_url`).
- **Delete** (`cs_layers_delete {"layer","area"}`): removes the area record and then only the tiles of its cover that **no remaining area covers** (partial areas count as covering what they asked for). The result has `tiles_removed`, `tiles_kept` (still needed by other areas), `freed_bytes`, and the store file's size before and after (deleted pages are returned to the file system with an incremental vacuum). `{"layer"}` alone deletes every area and tile of the layer.
- Errors have the core's stable codes, with `no_space` carrying `needed` and `available`.

## For the off-road router

`cache_layers::offroad::TerrainSource` is the trait `cache_offroad` should depend on:

```rust
pub trait TerrainSource {
    fn elevation_m(&self, bbox: [f64; 4], cell_m: f64) -> Result<CellGrid<f32>>;   // metres, NaN = no data
    fn land_cover(&self, bbox: [f64; 4], cell_m: f64) -> Result<CellGrid<u8>>;     // class value, 0 = no data
    fn coverage(&self) -> Coverage;                                                // boxes of downloaded areas
}
```

`DownloadedTerrain::new(inner, elevation_layer, land_cover_layer)` implements it over the downloaded tile stores only (never the network). Grids are row-major, north row first, `cell_m` metres per cell (by degrees: `cols = ceil(width_m / cell_m)`, `rows = ceil(height_m / cell_m)`); each cell is sampled at its centre. Elevation is bilinear between DEM pixel centres at the lowest zoom whose pixel size is no bigger than `cell_m` (limited to the highest zoom downloaded); land cover is the nearest pixel of the downloaded indexed-PNG tiles, so class values are the source's own (ESA WorldCover: 10 tree cover, 20 shrubland, 30 grassland, 40 cropland, 50 built-up, 60 bare, 70 snow and ice, 80 water, 90 wetland, 95 mangroves, 100 moss and lichen). `CellGrid::at(lon, lat)` reads a value back. It fails with `not_found` if nothing is downloaded for the box. Downloading the layers for an area thus equips routing there too.

## What this design needed that format 1 as first written did not have

- `offline.source`: Mapterhorn streams from a tile endpoint (`tiles.mapterhorn.com/{z}/{x}/{y}.webp`) but its documented offline route is the PMTiles archives at `download.mapterhorn.com`. Without a separate download source the definition could not describe both.
- A `{lat}`/`{lon}` template for `cog` sources (and `source.grid_deg`), since WorldCover is one file per 3-degree cell.
- `source.tile_size`, because the TileJSON for MapLibre's raster-dem needs it (Mapterhorn is 512 px).
- Mapterhorn's `planet.pmtiles` holds z0-12 only; z13-17 (10 m data in the USA) is in separate regional archives listed in `download_urls.json`. Format 1 cannot yet name several archives for one layer, so elevation is z0-12 (30 m class; contours above z12 are overzoomed).
- `update.version` for layers whose source has no version (OpenFreeMap's tile path changes every few days) is left empty; those layers never report `update_available`.

## Limits and notes

- PMTiles internal/tile compression: none and gzip. Brotli and zstd archives are refused (`unsupported`).
- Only the Terrarium elevation encoding is implemented; the TileJSON says so.
- Reading the C ABI from several threads on one handle is as unsafe as for the rest of the ABI; the tile server uses the engine from its own threads and is safe alongside calls on the handle.
- Cleanup of a layer's viewed-tile cache: `cs_layers_clear_cache`.
