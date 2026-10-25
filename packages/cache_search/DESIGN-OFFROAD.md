# Off-road routing for Cache: `cache_offroad` and `offroad_pack`

Status: phases 1, 2 and 3 done (region pack + builder, the search in Rust, the real Valhalla, directions, the
navigate API). Not done: the C ABI / tool wrapper (the other session's framework adds the tool).

Cache's assistant has a navigate tool whose off-road answers must come from Cache's own code, so the model is
trained on exactly what the phone will produce. navi (a server navigation app) already has a good off-road
router in Python (`backend/services/navi_offroute`). This work is a faithful port of its unified Auto search to
Rust. Fidelity to navi is the goal; where Rust forced a change it is listed under "Deviations".

Workspace members (`packages/cache_search/native`):

* `cache_offroad`: library, no dependency on `cache_search`. `route(pack, elevation, valhalla, request, options) -> RouteResult`,
  `Env::directions` (navi's `/api/directions`), and the plain API `Navigator::navigate` (section 8).
* `offroad_pack`: desktop CLI that builds `offroad.sqlite` and the test elevation file from navi's data and
  inspects/probes/routes/directions against them.
* `packages/valhalla` (branch `valhalla`, cherry-picked here): Valhalla 3.7.0 as a library plus the C shim; this work
  added `valhalla_shim_trace_attributes` and `valhalla_shim_last_error_code` to it.

## 1. Region pack format (`offroad.sqlite`, format_version 2)

One SQLite file per region (format_version 2). The phone opens it read-only. **Elevation is not in the pack** (decision,
2026-10-25): the app downloads elevation for an area from Mapterhorn (Terrarium WebP, 512 px tiles, z12; area extracts
from `planet.pmtiles` by range reads) as a local PMTiles file, the same file that drives hillshade and contours, and the router
reads it through `trait ElevationSource` (`PmtilesElevation`: pure-Rust PMTiles reader + lossless WebP decode, the exact
f32 Terrarium formula of navi, so cells are bit-identical to the previous in-pack copy). For tests the builder writes that
file from navi's copy (`offroad_pack elevation-extract`, same bytes, spec-compliant clustered PMTiles with gzip root/leaf
directories): `E:\cache-data\packs\idaho\elevation.pmtiles`, 2480 MB, 8165 tiles. The pack keeps class, friction, trails,
wilderness, barriers, MVUM, trailheads and parking.

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
| `meta(key, value)` | `format_version`, grid definition, `bbox_*`, `layers`, codec, `zstd_level`, `mode_profile_hash` (sha256 of the mode profiles and transition constants, `cost::mode_profile_hash`), `build_unix_time`, `src_*` (file name, size, mtime of every input), row counts |
| `tiles(layer, tx, ty, data)` | `WITHOUT ROWID`, PK (layer, tx, ty). A missing tile reads 0 |
| `parking`, `parking_idx` | OSM parking points (lat, lon, name, parking_type, access); access private/no/permit dropped at build (navi drops them at load). R*Tree on lon/lat |
| `trailheads`, `trailheads_idx` | navi.db `trail_entry_points` (lat, lon, name, highway_class). R*Tree |
| `mvum`, `mvum_idx` | MVUM roads + trails: symbol, seasonal, the raw status + date-range fields for the three motorized classes navi uses (`e_bike_class1` for 2w, `atv` for 4w, `highclearancevehicle` for vehicle), geometry as f64 lon/lat parts. R*Tree on the bbox. The date logic (`check_access`, `parse_date_range`, `symbol_to_access`) runs at query time, so a seasonal date can be applied on the phone |

### Layers and codecs

| layer | type | meaning |
|---|---|---|
| `friction` | u8 | WorldCover friction x10 (0 and 255 impassable) |
| `class` | u8 | WorldCover class codes (terrain overrides, vehicle flat-field rule) |
| `trails` | u8 | 0 none, 5 road, 15 track, 25 foot trail |
| `barriers` | u8 | PAD-US closed (255) |
| `wilderness` | u8 | designated wilderness (255) |

All layers: zstd of the raw 65536 bytes; all-zero tiles are not stored. Elevation (outside the pack) is read from the
z12 Terrarium PMTiles at the same global pixel grid.

Layers are resampled ONCE at build time with nearest neighbour at the true Web-Mercator centre of each z12 pixel
(source rasters are WGS84 lon/lat GeoTIFFs); the region is the set of z12 tiles present in the coverage PMTiles. The
builder is pure Rust: PMTiles v3 reader/writer, lossless WebP decode (`image-webp`; it refuses lossy tiles), and a small GeoTIFF reader (header via the `tiff` crate; pixel data decoded in
`raster.rs` for DEFLATE/LZW/none with predictor, because the `tiff` crate cannot read the palette-indexed class tiles;
checked byte-for-byte against GDAL on class, trails and friction windows). A mosaic is simply the set of `*.tif` in a
directory (a VRT of non-overlapping tiles reads the same way; uncovered pixels are 0). No GDAL is needed.

### Idaho pack (rebuilt 2026-10-25 without elevation, about 3 minutes, 16 threads)

`E:\cache-data\packs\idaho\offroad.sqlite`, bbox lat 41.5..49.5, lon -118.0..-110.3, **574 MB** (3463 MB while it still held
elevation). The region follows the 8165 z12 tiles of the elevation file (Idaho's rectangle).

| part | rows / tiles | MB |
|---|---:|---:|
| `class` | 32,660 tiles | 91.2 |
| `friction` | 32,660 tiles | 80.9 |
| `trails` | 17,412 tiles | 10.0 |
| `wilderness` | 3,506 tiles | 0.3 |
| `barriers` | 2,815 tiles | 0.2 |
| `mvum` geometry | 27,633 features | 90.4 |
| `trailheads` | 740,430 rows | |
| `parking` | 25,862 rows | |
| file total | | 574 |

Elevation is separate: 2480 MB for Idaho (z12 Terrarium, about 300 KB per 512 px tile), which is what the app downloads
once per area and shares with hillshade and contours. The remainder of the pack file beyond the tile payload (183 MB) is the point tables,
their R*Trees and page overhead; the 740k trailhead points and the MVUM geometry (f64 pairs) are the easy places to shrink it.

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
a cell. **Decision (2026-10-25): keep the aligned pack.** navi's per-query window offset is a navi bug (layers shifted
against elevation, differently per query); Cache does not copy it. The `--navi-layers` diagnostic stays for future parity checks:
with navi's sampling the port reproduces navi to 5 digits (section 5). Effect on routes: section 5.

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
| `elevation.rs`, `pmtiles.rs` | `shared/dem.py` (`terrarium_decode`, the z12 tile stitching), now over a local Mapterhorn-format PMTiles file behind `trait ElevationSource` |
| `valhalla.rs`, `shim.rs` | the Valhalla calls (`_locate_on_network`, `_route_D_network_only`, `/route` for directions, `/trace_attributes`) behind `trait Valhalla`; `ShimValhalla` implements it on the C shim (loaded at run time, cargo feature `shim`); polyline6 codec |
| `surface.rs` | `mvum_surface_change.py` (`classify_surface`, `_collapse_short_runs`, `_edges_to_candidates`, chunked `get_surface_change_candidates`, `get_route_shape`) |
| `offroad_legs.rs` | `directions_offroad.py` (Douglas-Peucker, decision-point legs, short-leg folding, follow legs, `pieces_from_result`) |
| `directions.rs` | `directions.py` (`_build_steps`, `_major_roads`, `_valhalla_failure`, `_assemble_offroad`, `_last_mile`, `_offroad_response`, `api_directions`) |
| `router.rs::path_detail` | `OffrouteRouter._path_detail` (per-cell lat/lon/mode/elevation/class/trail/step time from the kernel's own edge model) |
| `navigate.rs` | new: the plain Rust API (section 8) |

Not ported: HPA (spec only), the PostGIS entry-point flow, scenario A/B/C/D handlers, the explicit-mode scenario
dispatch, the reverse-geocode of the directions ends (`_describe`), the PostGIS `FollowNamer`.

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

1. Layer sampling: see section 2 (one-time global resample, not per-query window sampling). Decided to keep.
2. Elevation comes from a local Mapterhorn-format PMTiles file, not the pack (same bytes, same f32 decode).
3. Valhalla: the real library through the C shim. The shim's `actor_t` exceptions carry Valhalla's `error_code`; the
   directions error mapping (442/443 no_route, 170/171 too_far or out_of_coverage, 154 too_far) reads it through the new
   `valhalla_shim_last_error_code`. Valhalla requests use `"units": "km"` for every route call (navi uses
   `directions_options.units` for the bypass; same result). Logging: the shim reads the config's `logging` section (`ConfigureFromPtree`); `valhalla_config.json` sets `{"type": ""}`, Valhalla's no-op logger, so nothing reaches stdout.
4. MVUM is rasterized from the pack's feature table onto the query grid at query time with navi's Bresenham, using
   the query grid's linear meta (navi uses the requested bbox scaled to the grid; same offset effect as section 2).
   Verified cell-for-cell against navi's `_rasterize_feature` on the same geometry.
5. Explicit single-mode requests (`RequestMode::Single`) seed only that mode and drop transitions to other modes.
   navi routes explicit modes through the A/B/C/D scenario handlers with different results; there is nothing to match.
   For directions this means **walk and bike differ from navi by design**: navi sends walk to its foot scenario handler
   and bike to 2w; Cache runs the unified search seeded with foot / 2w. Drive (the unified Auto search) matches navi.
6. Directions: the `near` reverse-geocode of both ends is not done (`near` is null; navi asks navi-geo over HTTP); follow-leg
   names are null (navi reads PostGIS `entry_points`, which Cache has no table for; `Env.namer` is a hook for one); `route_id`
   hashes the crate version instead of navi's git sha; the land-access mode is a request field (navi's directions hard-code
   pragmatic); optional per-end OSM category hints seed the search (navi's directions send none).
7. Extra request fields for tests: `start_modes`/`end_modes` override the category/spatial seeding.
8. Per-mode layers are built sequentially (navi `LAYER_WORKERS=1`); `rayon` is used only for the blur, the corridor
   mask and tile decoding. The kernel is single-threaded as in navi.
9. `route_too_long` is `RouteError::TooLong { estimated, max }`, raised before any raster is read; the cap is
   `min(max_cells, (2^31-1)/4)`. Error messages are navi's own strings.
10. Parking points with access private/no/permit are dropped at build time (navi drops them when loading the index);
    all point data and MVUM features are clipped to the pack bbox.

Where the Rust code could be bit-exact it is: the Gaussian blur (scipy), the Terrarium decode, the heap order, the
f32/f64 mix of the kernel. These are covered by fixtures recorded from navi's own code (below), not hand-computed.

## 5. Tests and parity

Run: `cargo test -p cache_offroad --release --features shim` (native Windows; 42 tests, 3 of them need the Idaho data and skip
unless the env vars are set: `OFFROAD_IDAHO_PACK`, `OFFROAD_IDAHO_ELEVATION`, `OFFROAD_VALHALLA_LIB`, `OFFROAD_VALHALLA_TILES`).

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
  `shared/dem.py` for five bboxes; pack round trip across tile edges; Terrarium formula.
* `tests/directions_oracle.rs`: navi's `pieces_from_result`, `_path_detail`, `offroad_steps` and `_assemble_offroad`
  (road pieces through a deterministic fake Valhalla, follow legs through a fake namer) on 26 routes of the synthetic
  worlds (two merge/min-leg settings, vehicle road runs, 4w/2w/foot runs, follow legs): per-cell detail (lat/lon/mode/elevation/
  class/trail/step time), pieces, every step field and the shape/length agree. Generator `tools/gen_directions.py`.
* `tests/surface_oracle.rs`: surface classification table, chunked `trace_attributes` joining and boundary extraction vs
  navi's `mvum_surface_change` with a fake trace, and the polyline6 codec. Generator `tools/gen_surface.py`.
* `tests/parity_idaho.rs`, `tests/directions_idaho.rs`: the Idaho runs below (real pack, elevation file and Valhalla shim).

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

### Phase 3: real Valhalla seeding (9 more requests, 2026-10-25, ~18:35 UTC)

The nine routes whose seeds matter were sent to navi PROD without `start_category`/`end_category` (navi seeds itself from
Valhalla `/locate`); the port does the same through the shim on the Idaho tiles (`tiles.tar`, 1104 tiles). Columns: port on the
aligned pack, and port with navi-style layers (`route --navi-layers`).

| route | navi min / km / modes | port (pack) | effort | port, navi layers |
|---|---|---|---:|---:|
| R01 | 269.16 / 21.15 / foot+vehicle | 269.00 / 21.21 / foot+vehicle | -0.06% | 0.00% |
| R02 | 310.72 / 21.28 / foot+vehicle | 310.34 / 21.29 / foot+vehicle | -0.12% | 0.00% |
| R04 | 308.61 / 26.29 / 4w+foot+vehicle | 306.40 / 26.38 / foot+vehicle | -0.72% | 0.00% |
| **R05** | 8.30 / 10.68 / 4w+vehicle | 8.28 / 10.71 / 4w+vehicle | **-0.30%** (was -27.1% with the stub) | 0.00% |
| R06 | 34.14 / 23.61 / 2w+4w+foot+vehicle | 33.26 / 25.47 / foot+vehicle | -2.57% | 0.00% |
| R07 | 821.63 / 40.03 / 4w+foot+vehicle | 818.58 / 40.35 / 4w+foot+vehicle | -0.37% | 0.00% |
| R08 strict | 204.24 / 12.81 / foot | 181.54 / 11.38 / foot+vehicle | -11.1% | 0.00% |
| R09 | 148.08 / 13.84 / foot+vehicle | 146.47 / 13.79 / foot+vehicle | -1.09% | 0.00% |
| R12 | 72.73 / 6.42 / foot+vehicle | 72.64 / 6.10 / foot+vehicle | -0.12% | 0.00% |

With navi's layer sampling all nine match navi to the printed digits (effort and distance), including the Valhalla-seeded modes,
the surface-change swaps of R05/R06 and the walk-then-drive of R04: the logic of the port, the shim and the seeding are
equivalent to navi's. The R05 gap from phase 2 is closed by the real surface-change transitions. What remains against navi on
the aligned pack is the layer-alignment effect only: eight of nine within 3%, R08 (strict, barrier raster shifted by one cell)
at -11%; R06's mode set differs (navi uses 2w/4w legs on the shifted layers) while its effort is within 2.6%.

### Phase 3: directions vs navi PROD's `POST /api/directions` (6 requests, mode drive, `describe_ends` false)

Run with `offroad_pack directions` (Idaho pack + elevation + shim). Step comparison by index.

| route | navi | port | result |
|---|---|---|---|
| D4 Yellow Pine, 65 km | road, 11 steps, 65.11 km, 14911 s | same | **identical**: every step, summary and shape |
| D6 track to track, 11 km | road, 4 steps, 11.23 km, 3915 s | same | **identical** |
| D1 wilderness start to road | offroad, 61 steps, 39.76 km, 23585 s | 67 steps, 39.72 km, 23525 s | -0.1% distance, -0.3% duration |
| D2 road to wilderness | offroad, 62 steps, 39.63 km, 24444 s | 62 steps, 39.51 km, 24324 s | -0.3% / -0.5% |
| D3 walk out, then drive | offroad, 57 steps, 42.52 km, 23589 s | 63 steps, 42.47 km, 23529 s | -0.1% / -0.3% |
| D5 north Idaho road to trail | offroad, 10 steps, 26.46 km, 3189 s | 11 steps, 26.84 km, 3239 s | +1.4% / +1.6% |

D4 and D6 are pure Valhalla routes and confirm the shim, the maneuver typing, rounding and shape encoding exactly. In the four
off-road routes the road part is identical and the off-road lead/tail legs differ in the same two ways: (1) the cells of the path
differ by the layer-alignment effect, so decision points, terrain labels (e.g. the first leg of D1 reads water in navi and tree cover
here, one cell away) and leg lengths shift while totals agree to under 2%; (2) follow-leg names are null here (navi's PostGIS
`entry_points` names, e.g. "Mount Cramer Trail"). The leg-building code itself is covered cell-for-cell by the oracle test
above; no navi request was used to tune anything.

## 6. Tooling (offroad_pack)

```
offroad_pack build --out offroad.sqlite --bbox S,N,W,E --coverage-pmtiles elevation.pmtiles --friction-dir DIR --class-dir DIR \
    --trails trails.tif --barriers padus_barriers.tif --wilderness wilderness.tif --navi-db navi.db --parking-db osm-parking.db \
    [--zstd-level 15] [--limit-tiles N] [--threads N]
offroad_pack elevation-extract --src idaho-dem-z12.pmtiles --bbox S,N,W,E --out elevation.pmtiles   # test elevation file
offroad_pack inspect --pack offroad.sqlite
offroad_pack route --pack P --elevation E [--valhalla-lib shim.dll --valhalla-tiles tiles.tar] --start lat,lon --end lat,lon \
    [--mode auto|foot|2w|4w|vehicle] [--boundary ..] [--start-category C --end-category C | --start-modes a,b --end-modes a,b] \
    [--affinity foot=2,4w=0.5] [--max-cells N] [--navi-layers --friction-dir .. --class-dir .. --trails .. --barriers .. --wilderness ..]
offroad_pack directions --pack P --elevation E [--valhalla-lib .. --valhalla-tiles ..] --from lat,lon --to lat,lon [--mode drive|walk|bike] \
    [--offroad auto|never|always] [--boundary ..] [--json out.json]
offroad_pack probe --pack P --elevation E --at lat,lon [--radius cells] [--map 1]
offroad_pack resample-check --bbox S,N,W,E --friction-dir .. --class-dir .. --trails .. --barriers .. --wilderness ..
offroad_pack raster-info|raster-window ...
```

Android arm64 (cargo-ndk, NDK 28.2): `cargo ndk -t arm64-v8a build --release -p cache_offroad --features shim` builds
(bundled SQLite and zstd compile with the NDK). Together with the shim: `libvalhalla_shim.so` (built by
`packages/valhalla/scripts/build-android.bat`, 8.6 MB stripped) exports all of `valhalla_shim_*` including
`trace_attributes` and `last_error_code`; a throwaway cdylib (`tools/android_link_check`) that depends on
`cache_offroad` (feature `shim`) and links `-lvalhalla_shim` builds for arm64 with `libvalhalla_shim.so` as a `NEEDED` entry
and the five shim symbols it references undefined, to be resolved from that library at load time. `ShimValhalla::load` opens the
library with `dlopen`, so the app only has to ship `libvalhalla_shim.so` next to the native library.

## 7. Navigate API (plain Rust)

```rust
let nav = Navigator::new(&pack, &elevation, &valhalla);        // SqlitePack, PmtilesElevation, ShimValhalla
let d: Directions = nav.navigate(&NavigateRequest::new(
    Waypoint::point(44.03, -114.99),                            // or Waypoint::place(name, lat, lon) / place_with_category
    Waypoint::place("Redfish Lake Lodge", 44.1359, -114.9145),
    TravelMode::Drive,                                          // Drive | Walk | Bike
    Boundary::Pragmatic))?;                                     // land access: Strict | Pragmatic | Emergency
let body = d.to_json();                                         // navi's /api/directions response shape
```

`navigate` returns `Err(NavigateError::BadRequest)` only for malformed input; route failures are
`Ok(Directions { ok: false, errors: [{code, message, valhalla_code}] })` with navi's codes (`no_route`, `too_far`,
`out_of_coverage`, `route_too_long`, `upstream_timeout`, `internal`). `NavigateRequest` also carries `offroad`
(`Auto` default: Valhalla road route first, off-road last mile when an end is more than `offroad_snap_m` = 150 m from the road, whole
trip off-road when Valhalla has no edges; `Never`; `Always`), `merge_bearing_deg` (60), `min_leg_m` (150). `Navigator.options`
carries `RouteOptions` (the cell cap: about 8 M on the phone). The result has steps (`kind` road / offroad / offroad_follow, bearing,
cardinal, distance, duration, elevation gain/loss, grade class, terrain, trail kind), the polyline6 shape, summary and warnings
(`offroad_unavailable` when one end's last-mile leg failed and the road route was kept). A place's OSM category, when known,
seeds the travel modes at that end. No C ABI or tool wrapper yet.

## 8. What is left

1. (The tool wrapper is done: `cache_navigate`, see DESIGN.md "navigate".) Pack and elevation download and versioning
   (`meta.mode_profile_hash` and `src_*` are there for staleness checks), where the shim library and the Valhalla tiles live on the phone.
2. Follow-leg names and end descriptions offline (navi uses PostGIS `entry_points` and navi-geo): `Env.namer` is the hook; the pack
   has no road-name table.
3. Size work on the pack (trailhead points, MVUM geometry) if a phone-sized region needs it. (Valhalla's logging is silenced: done.)
