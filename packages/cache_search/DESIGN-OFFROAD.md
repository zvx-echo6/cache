# Off-road routing for Cache: `cache_offroad` and `offroad_pack`

Status: phases 1 and 2 of 3 (region pack + builder, and the search in Rust). Phase 3 (Valhalla shim, directions
formatting, surface-change transitions, FFI) is not started.

Cache's assistant has a navigate tool whose off-road answers must come from Cache's own code, so the model is
trained on exactly what the phone will produce. navi (a server navigation app) already has a good off-road
router in Python (`backend/services/navi_offroute`). This work is a faithful port of its unified Auto search to
Rust. Fidelity to navi is the goal; where Rust forced a change it is listed under "Deviations".

Workspace members (`packages/cache_search/native`):

* `cache_offroad`: library, no dependency on `cache_search`. `route(pack, valhalla, request, options) -> RouteResult`.
* `offroad_pack`: desktop CLI that builds `offroad.sqlite` from navi's data and inspects/probes/routes against it.

## 1. Region pack format (`offroad.sqlite`, format_version 1)

One SQLite file per region. The phone opens it read-only and reads nothing else.

### Grid

All raster layers live on the global Web-Mercator z12 pixel grid that navi's `DEMReader` stitches from
(`shared/dem.py`): 512-px tiles, 2^21 pixels around the world, origin top-left. Global pixel (row, col) of a z12
tile (tx, ty) pixel (r, c) is (ty*512 + r, tx*512 + c). The pack cuts the grid into 256x256-cell tiles
(`ptx = col / 256`, `pty = row / 256`), so one DEM tile is four pack tiles.

A query grid is a window of this global grid. Its geometry (rows, cols, `pixel_size_lat/lon`, `origin_lat/lon`,
`cell_size_m`) is computed from the requested bbox by a line-by-line port of `grid_window` and the metadata of
`get_elevation_grid` (`grid.rs`, tested against values produced by navi's own `shared/dem.py`). Like navi, the
window gets a *linear* lat/lon georeference (`pixel_size_lat` = tile-range span / pixel count) although z12 rows are
Mercator; every pixel<->lat/lon conversion (endpoint snapping, output coordinates, corridor mask, transition cells)
uses that same linear meta, so output coordinates and snapping behave as in navi.

### Tables

| table | content |
|---|---|
| `meta(key, value)` | `format_version`, grid definition, `bbox_*`, `layers`, codecs, `zstd_level`, `mode_profile_hash` (sha256 of the mode profiles and transition constants, `cost::mode_profile_hash`), `build_unix_time`, `src_*` (file name, size, mtime of every input), row counts |
| `tiles(layer, tx, ty, data)` | `WITHOUT ROWID`, PK (layer, tx, ty). A missing tile means no data: elevation NaN (impassable), every other layer 0 |
| `parking`, `parking_idx` | OSM parking points (lat, lon, name, parking_type, access); access private/no/permit dropped at build (navi drops them at load). R*Tree on lon/lat |
| `trailheads`, `trailheads_idx` | navi.db `trail_entry_points` (lat, lon, name, highway_class). R*Tree |
| `mvum`, `mvum_idx` | MVUM roads + trails: symbol, seasonal, the raw status + date-range fields for the three motorized classes navi uses (`e_bike_class1` for 2w, `atv` for 4w, `highclearancevehicle` for vehicle), geometry as f64 lon/lat parts. R*Tree on the bbox. The date logic (`check_access`, `parse_date_range`, `symbol_to_access`) runs at query time, so a seasonal date can be applied on the phone |

### Layers and codecs

| layer | type | meaning |
|---|---|---|
| `elev` | Terrarium bytes | lossless: the 24-bit `R<<16 | G<<8 | B` value, horizontally delta-coded (mod 2^24), split into three byte planes, zstd. Decodes to exactly navi's float32 (`(R*256 + G + B/256) - 32768` in f32; this is exact because it is a 24-bit integer scaled by 2^-8) |
| `friction` | u8 | WorldCover friction x10 (0 and 255 impassable) |
| `class` | u8 | WorldCover class codes (terrain overrides, vehicle flat-field rule) |
| `trails` | u8 | 0 none, 5 road, 15 track, 25 foot trail |
| `barriers` | u8 | PAD-US closed (255) |
| `wilderness` | u8 | designated wilderness (255) |

u8 layers: zstd of the raw 65536 bytes; all-zero tiles are not stored.

Layers are resampled ONCE at build time with nearest neighbour at the true Web-Mercator centre of each z12 pixel
(source rasters are WGS84 lon/lat GeoTIFFs). The builder is pure Rust: PMTiles v3 reader, lossless WebP decode
(`image-webp`; it refuses lossy tiles), and a small GeoTIFF reader (header via the `tiff` crate; pixel data decoded in
`raster.rs` for DEFLATE/LZW/none with predictor, because the `tiff` crate cannot read the palette-indexed class tiles;
checked byte-for-byte against GDAL on class, trails and friction windows). A mosaic is simply the set of `*.tif` in a
directory (a VRT of non-overlapping tiles reads the same way; uncovered pixels are 0). No GDAL is needed.

### Idaho pack (built 2026-10-25, about 4 minutes, 16 threads)

`E:\cache-data\packs\idaho\offroad.sqlite`, bbox lat 41.5..49.5, lon -118.0..-110.3 (the DEM covers 8165 z12 tiles,
Idaho's rectangle; outside it elevation is NaN, so the rest of the requested bbox holds no tiles).

| part | rows / tiles | bytes | MB |
|---|---:|---:|---:|
| `elev` | 32,660 tiles | 2,658,771,238 | 2658.8 (81 KB/tile) |
| `class` | 32,660 | 91,194,339 | 91.2 |
| `friction` | 32,660 | 80,940,876 | 80.9 |
| `trails` | 17,412 | 10,045,500 | 10.0 |
| `wilderness` | 3,506 | 295,033 | 0.3 |
| `barriers` | 2,815 | 189,598 | 0.2 |
| `mvum` geometry | 27,633 features | ~90 | 90.4 |
| `trailheads` | 740,430 | | |
| `parking` | 25,862 | | |
| file total | | | 3463 MB |

Elevation dominates: Idaho at z12 (about 13.5 m cells) is 2.1 G cells. Phone packs will want a smaller region
or coarser elevation; the codec costs ~10-25% more than the source lossless WebP (83 KB vs 75 KB per 256x256 tile
at zstd 15). The file is ~600 MB larger than the tile payload because rows are mostly overflow pages and the 740k
trailhead points carry an R*Tree; both are easy to shrink (vacuum, `trailheads` thinning, zstd for the MVUM
geometry) if size matters.

## 2. Is a one-time global resample identical to navi's per-query resample? No.

navi reads each layer with `rasterio` `from_bounds(west, south, east, north)` of the *requested bbox*, with
`out_shape` = the DEM-shaped grid (the DEM grid is the bbox rounded outward to whole z12 pixels and then cropped with
`int()`). So navi's layer cell (i, j) samples the source at the bbox-scaled position
`north - (i + 0.5) * (north - south) / rows` (likewise lon), while its elevation cell (i, j) is the true z12 pixel.
The two agree only up to the crop rounding and the linear-georeference error: a sub-pixel to ~1.3 cell offset for a
0.2 x 0.4 degree query, growing with query size, and different for every query. A one-time global resample cannot
reproduce a position that depends on the query. Measured with `offroad_pack resample-check` (navi's rule emulated:
GDAL nearest at a fractional window; the pack rule = pack cell centres), Idaho data:

| query bbox | cells | friction differs | class differs | trails differs | barriers differs | max offset |
|---|---:|---:|---:|---:|---:|---:|
| 43.5..43.7 N, -114.9..-114.5 | 3.7 M | 10.1% | 12.3% | 1.9% of cells (52% of road cells) | 0 | 1.28 cells |
| 43.55..43.95 N, -114.9..-114.4 | 9.4 M | 18.4% | 21.4% | 3.2% (75% of road cells) | 0.03% | 3.6 cells |
| 44.0..44.8 N, -115.5..-114.2 | 49 M | 30% | 35% | 3.5% | 0.12% | 14 cells |

The differences are a spatial shift (roads 2-3 cells wide move by one cell), not noise. The pack grid is the
internally consistent one (layers and elevation aligned); navi's own layers are offset from its elevation by up to
a cell. Effect on routes: section 5. If exact navi results are required, the alternative is storing the layers at
source resolution and applying navi's per-query window rule at query time; the `--navi-layers` diagnostic below shows
that this reproduces navi to 4-5 digits.

## 3. What was ported, from where

| Rust (`cache_offroad/src`) | navi source |
|---|---|
| `grid.rs`: `grid_window`, `GridMeta` (meta, `latlon_to_pixel` with truncating `int()`, the `+1e-6` variant), `global_pixel` | `shared/dem.py` |
| `cost.rs`: `MODE_PROFILES`, `compute_cost_multiplier_grid` (float32; terrain overrides, vehicle flat-field rule with the float32 slope classification, wilderness), `_per_cell_grade`, `friction_to_multiplier`, `inflate_cost_multiplier`, `_corridor_mask`, transition cost constants | `cost.py`, `friction.py`, `astar.py::inflate_cost_multiplier` |
| `gaussian_filter_f32` | `scipy.ndimage.gaussian_filter(mode="nearest")`, sigma 1.8, truncate 4.0: radius `int(4.0*1.8+0.5)` = 7, kernel `exp(-0.5 x^2/sigma^2)` normalised to sum 1, axis 0 then axis 1, double accumulation in scipy's symmetric order, float32 storage between passes. Bit-identical to scipy on the test grid (<= 1 ulp allowed, checked) |
| `astar.rs`: `astar_multigoal_multimode`, `movement_edge_time`, `speed_kmh`; single-mode `astar_multigoal` | `astar.py` (signed Tobler/Herzog/linear, smooth slope penalty exp(10*overshoot) capped at 1e6, trail-takes-both with min friction, barrier rule 255 / x5 / ignore, `min_factor` admissible heuristic, f32 `g_score` + i32 `parent` + bool `closed` planes, doubling heap with the same capacity rules, transition index by sorted cell key) |
| `mvum.rs` | `mvum.py` (`parse_date_range`, `is_date_in_range`, `check_access`, `symbol_to_access`, Bresenham `_draw_line`, `_rasterize_feature`, all-modes grids) |
| `transitions.rs` | `transitions.py` (parking foot<->vehicle/4w/2w 60 s; trailheads foot<->4w/2w 30 s; road termini foot<->vehicle 60 s from the trail raster via a 3x3 off-network test with border = on-network; surface change vehicle<->4w, 4w<->2w 0 s; per-type "closest 15 within 5 km of the endpoint line" by great-circle cross-track distance; lat/lon -> cell with the `+1e-6` mapping; de-dupe per (row, col, from, to)) and `mvum_parking.py` / `mvum_transitions.py` (`near line` queries: bbox prefilter + degree-distance test with `_buffer_degrees_for_meters`) |
| `router.rs`: `route`, `search_on_grid` | `router.py::_route_auto`, `_auto_eligible_modes`, `_spatial_eligible_modes` (+ `_is_terrain_flat`), `_eligible_modes_from_category` (the category table), `_auto_bbox` (pad 0.02, span clamp 2.0), `_check_cell_budget`, `_fetch_auto_rasters`, `_build_mvum_by_mode`, `_render_unified_path`, network_affinity (applied to on-network cells after inflation and to the kernel's trail friction), the road-to-road bypass, the corridor (10 km, 5 km past the endpoints) |
| `pack.rs` | replaces `friction.py`, `landcover.py`, `barriers.py`, `trails.py`, the DB loaders |
| `valhalla.rs` | the Valhalla calls (`/locate`, the bypass `/route`, the route shape + trace for surface change) behind the `Valhalla` trait |

Not ported: HPA (spec only), the PostGIS entry-point flow, scenario A/B/C/D handlers, the explicit-mode scenario
dispatch, `directions.py` / `directions_offroad.py` (phase 3), `collect_path_detail`.

Request: start, end, mode (`Auto` or `Single(mode)`), boundary (strict/pragmatic/emergency), optional
network_affinity, optional start/end OSM category (seeds, same table as navi), optional explicit seed modes
(`start_modes`/`end_modes`, used by tests), optional MVUM date. Result: the cell path with modes, cost (s),
distance, `selected_mode_set`, per-mode segments, transition markers, the combined line and `to_json()` in navi's
`/api/offroute` shape. `RouteOptions.max_cells` is the cell cap (navi 20 M; the phone about 8 M).

Memory: the same planes as navi (f32 cost stack x4 modes, f32 g, i32 parent, bool closed, u8 trails/barriers,
f32 elevation). Measured peak working set for a 12.3 M-cell route: 725 MB, 59 B/cell (navi measures ~60); an 8 M
cap is about 470 MB. Timing, 107 km route (12.3 M cells), release build on the desktop: rasters 0.15 s, layers
1.2 s, transitions 0.1 s, search 1.1 s. Typical 10-40 km routes: 0.2-1 s.

## 4. Deviations from navi

1. Layer sampling: see section 2 (one-time global resample, not per-query window sampling).
2. Valhalla: behind a trait; phase 2 uses `StubValhalla` (clearly marked), which finds nothing. Consequences: untagged
   endpoints seed foot only; the road-to-road bypass cannot run (a tagged road-to-road request falls through to the
   unified search); **surface-change transitions are absent**, which matters for routes that swap 4w<->vehicle<->2w
   along a road (R05 below). navi's cap on road-terminus cells (closest 15 to the infinite endpoint line) is also
   sensitive to one-cell raster shifts, which changes which termini exist.
3. MVUM is rasterized from the pack's feature table onto the query grid at query time with navi's Bresenham, using
   the query grid's linear meta (navi uses the requested bbox scaled to the grid; same offset effect as section 2).
   Verified cell-for-cell against navi's `_rasterize_feature` on the same geometry.
4. Explicit single-mode requests (`RequestMode::Single`) seed only that mode and drop transitions to other modes.
   navi routes explicit modes through the A/B/C/D scenario handlers with different results; there is no such thing
   to match.
5. Extra request fields for tests: `start_modes`/`end_modes` override the category/spatial seeding.
6. Per-mode layers are built sequentially (navi `LAYER_WORKERS=1`); `rayon` is used only for the blur, the corridor
   mask and tile decoding. The kernel is single-threaded as in navi.
7. `cell_size_m` and the kernel use the same values as navi (computed from the query bbox centre).
8. `route_too_long` is `RouteError::TooLong { estimated, max }`, raised before any raster is read; the cap is
   `min(max_cells, (2^31-1)/4)`.
9. Parking points with access private/no/permit are dropped at build time (navi drops them when loading the index);
   all point data and MVUM features are clipped to the pack bbox.

Where the Rust code could be bit-exact it is: the Gaussian blur (scipy), the Terrarium decode, the heap order, the
f32/f64 mix of the kernel. These are covered by fixtures recorded from navi's own code (below), not hand-computed.

## 5. Tests and parity

Run: `cargo test -p cache_offroad --release` (native Windows; 37 tests plus the Idaho parity test).

* `tests/oracle.rs`: **navi's own `OffrouteRouter._route_auto`** (numba kernel, scipy blur, real `compute_unified_cost_layers`
  and transition gathering, with stubbed readers exactly like navi's Phase-4 tests) was run on two synthetic 64x96
  worlds (forest/shrub/grass/bare/wetland/water, hills, a ridge band, NaN cells, roads with a dead end, tracks, a foot
  trail, barriers, wilderness, 26 parking points, 21 trailheads) for 9 scenarios (strict/pragmatic/emergency, several
  seed sets, network_affinity). The Rust port reproduces path (every cell and mode), cost, distance, mode set, segments,
  transition markers and the transition-cell count. Fixture: `tests/fixtures/oracle_cases.json.gz`, generator
  `cache_offroad/tools/gen_fixtures.py` (it imports a read-only copy of navi's code).
* `tests/kernel.rs`: ports of navi's kernel and cost tests with the same fixtures and assertions (signed Tobler
  asymmetry, inflation, single-mode A*, multigoal, `compute_cost_multiplier_grid` math, smooth max-grade penalty
  incl. the 300 m cliff, threshold grade, multimode foot-only parity, parking switch, no-transitions independence,
  heuristic admissibility vs Dijkstra, road-case admissibility, transition cap closest 15 and its scalar oracle,
  road-terminus raster tests incl. the no-wrap test), plus the scipy bit-comparison of `inflate_cost_multiplier`.
* `tests/route.rs`: ports of navi's `_route_auto` integration tests (walk-then-drive, foot to off-path, road to road,
  network_affinity, 50 km performance), the category table, the spatial-eligibility cases, and the bypass tests
  (fires for tagged roads and skips the raster pipeline, untagged tight/relaxed snap, falls through on error).
* `tests/mvum_oracle.rs`, `tests/grid_oracle.rs`, `tests/pack.rs`: MVUM grids vs navi for three dates; grid metadata vs
  `shared/dem.py` for five bboxes; pack round trip across tile edges, lossless elevation codec.
* `tests/parity_idaho.rs`: the 12 routes below, run when `OFFROAD_IDAHO_PACK` points at the pack.

### Idaho parity vs navi PROD (12 requests, 2026-10-25, ~18:00 UTC)

Seeds are given as the OSM categories sent to navi: foot = `natural:peak`; 2w/foot = `highway:path`;
4w/2w/foot = `highway:track`; all = `highway:residential`. Boundary pragmatic unless noted. Effort in minutes.

| route | seeds start -> end | navi min / km / modes | port (pack) min / km / modes | effort | port with navi-style layers |
|---|---|---|---|---:|---:|
| R01 wilderness -> road | foot -> all | 269.16 / 21.15 / foot+vehicle | 269.00 / 21.21 / foot+vehicle | -0.06% | 0.00% |
| R02 road -> wilderness | all -> foot | 310.72 / 21.28 / foot+vehicle | 310.34 / 21.29 / foot+vehicle | -0.12% | 0.00% |
| R03 wilderness -> wilderness | foot -> foot | 304.56 / 21.38 / foot | 300.93 / 21.33 / foot | -1.19% | 0.00% |
| R04 walk out, then drive | foot -> all | 305.72 / 26.27 / foot+vehicle | 304.79 / 26.30 / foot+vehicle | -0.31% | 0.00% |
| R05 track to track | track -> track | 14.32 / 11.76 / 4w+vehicle | 10.44 / 10.69 / foot+vehicle | **-27.1%** | +25.5% (4w only) |
| R06 foothills trails | path -> path | 34.14 / 23.61 / 2w+4w+foot+vehicle | 33.26 / 25.47 / foot+vehicle | -2.57% | 0.00% |
| R07 long, Yellow Pine | track -> all | 821.60 / 39.94 / 4w+foot+vehicle | 820.14 / 41.09 / 4w+foot+vehicle | -0.18% | +0.01% |
| R08 barriers, strict | foot -> foot | 204.24 / 12.81 / foot | 181.54 / 11.38 / foot+vehicle | **-11.1%** | 0.00% |
| R09 barriers, pragmatic | foot -> foot | 148.08 / 13.84 / foot+vehicle | 146.47 / 13.79 / foot+vehicle | -1.09% | 0.00% |
| R10 barriers, emergency | foot -> foot | 112.48 / 13.60 / foot+vehicle | 111.72 / 13.55 / foot+vehicle | -0.67% | 0.00% |
| R11 foot, mountain | foot -> foot | 324.19 / 17.79 / foot | 319.81 / 17.86 / foot | -1.35% | 0.00% |
| R12 north Idaho | all -> path | 72.73 / 6.42 / foot+vehicle | 72.64 / 6.10 / foot+vehicle | -0.12% | 0.00% |

Endpoints: Sawtooth/Stanley area (R01-R05, R08-R11), Boise foothills (R06), Yellow Pine (R07), Coeur d'Alene
forest (R12); exact coordinates are in `tests/parity_idaho.rs`.

Result: 10 of 12 are within 3% of navi (the largest of those -2.6%, route distance up to 8%/5% apart on R06/R12
because the optimum is flat and the path shifts a cell). Two are not:

* **R05 (-27%): surface-change transitions.** The last column (same router, but the u8 layers re-sampled the way
  navi does per query, `offroad_pack route --navi-layers`) matches navi to 4-5 digits on 10 routes, which proves
  the port's logic; on R05 it still differs. navi's answer is 4w for 1.6 km, then vehicle, then 4w: a free 4w<->vehicle
  swap at a Valhalla surface-change point, which the stub cannot provide. Phase 3 should close this.
* **R08 (-11%, strict): one-cell barrier shift.** In strict mode a barrier cell is a wall; the pack's barrier raster
  sits up to ~1 cell away from navi's per-query sampling, which opens a passage navi does not have (the route then
  uses a vehicle leg). Same inputs on navi's sampling give 0.00%.

The remaining 0.1-1.4% differences are the layer-alignment effect of section 2 and shrink to 0.00% with navi-style
sampling. Nothing was tuned to hide a difference; no constant differs from navi.

## 6. Tooling (offroad_pack)

```
offroad_pack build --out offroad.sqlite --bbox S,N,W,E --dem idaho-dem-z12.pmtiles --friction-dir DIR --class-dir DIR \
    --trails trails.tif --barriers padus_barriers.tif --wilderness wilderness.tif --navi-db navi.db --parking-db osm-parking.db \
    [--zstd-level 15] [--limit-tiles N] [--threads N]
offroad_pack inspect --pack offroad.sqlite            # per-layer sizes
offroad_pack route --pack P --start lat,lon --end lat,lon [--mode auto|foot|2w|4w|vehicle] [--boundary ..] \
    [--start-category C --end-category C | --start-modes a,b --end-modes a,b] [--affinity foot=2,4w=0.5] [--max-cells N] \
    [--navi-layers --friction-dir .. --class-dir .. --trails .. --barriers .. --wilderness ..]   # diagnostic
offroad_pack probe --pack P --at lat,lon [--radius cells] [--map 1]
offroad_pack resample-check --bbox S,N,W,E --friction-dir .. --class-dir .. --trails .. --barriers .. --wilderness ..
offroad_pack raster-info|raster-window|codec-bench ...
```

Android: `cargo ndk -t arm64-v8a build --release -p cache_offroad` builds (bundled SQLite and zstd compile with the NDK).

## 7. What phase 3 needs

1. **The real Valhalla shim** (packages/valhalla) behind `trait Valhalla`: `/locate` for auto/pedestrian/bicycle with the
   edge classification (`classification.classification` and `.use`) and snap distance; the vehicle `/route` for the
   road-to-road bypass (shape, maneuvers, time, length); the route shape plus `trace_attributes` for surface-change
   candidates (`mvum_surface_change.py`: `get_route_shape`, `get_surface_change_candidates`). Surface-change
   transitions are what explains R05.
2. **Directions formatting** from `directions.py` and `directions_offroad.py`: needs the per-cell path detail
   (`collect_path_detail` / `_path_detail`: lat/lon, elevation, land-cover class, trail value and per-step time from the
   kernel's edge model). `RouteResult.cells` has row/col/mode/lat/lon; elevation/class/trail/step time still have to be
   emitted from the search's arrays. `movement_edge_time` is public for that.
3. **Decision for the owner: layer alignment.** Keep the aligned pack (10/12 routes within 3%, simpler phone work) or
   store the layers at source resolution and resample per query with navi's window rule (exact parity, a few hundred MB more
   in Idaho, ~O(cells) extra work per query).
4. FFI/JNI surface for `route()`, pack download/versioning (`mode_profile_hash` and `src_*` in `meta` are there for
   staleness checks), and a phone-sized pack (region size vs elevation size, MVUM geometry compression).
