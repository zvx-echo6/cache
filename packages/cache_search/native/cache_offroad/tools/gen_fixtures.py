# Generates oracle fixtures by running navi's own code (read-only copy in ./navi) on synthetic worlds.
import sys, json, math, os
sys.path.insert(0, 'navi')
import types
def stub(name, **attrs):
    m = types.ModuleType(name); m.__dict__.update(attrs); sys.modules[name] = m; return m
for n in ['psycopg2', 'psycopg2.extras', 'rasterio', 'rasterio.windows', 'rasterio.enums', 'pmtiles', 'pmtiles.reader']:
    try: __import__(n)
    except Exception:
        stub(n, from_bounds=None, Resampling=types.SimpleNamespace(nearest=0), MmapSource=object, Reader=object, extras=None, connection=object, RealDictCursor=object)
sys.modules['psycopg2'].extensions = types.SimpleNamespace(connection=object)
sys.modules['psycopg2'].extras = sys.modules['psycopg2.extras']
import numpy as np
import services.navi_offroute.router as R
import services.navi_offroute.transitions as T
from services.navi_offroute.router import OffrouteRouter
from services.navi_offroute.astar import inflate_cost_multiplier
import logging; logging.disable(logging.CRITICAL)

def bits(a): return np.ascontiguousarray(a, dtype=np.float32).view(np.uint32).reshape(-1).tolist()

def make_world(seed, rows=64, cols=96):
    rng = np.random.default_rng(seed)
    yy, xx = np.mgrid[0:rows, 0:cols].astype(np.float64)
    elev = 1200 + 60*np.sin(xx/9.0+seed) + 45*np.cos(yy/7.0) + 30*np.sin((xx+yy)/13.0)
    elev += rng.normal(0, 1.5, elev.shape)
    elev[24:27, 40:70] += 220     # steep ridge band (grades beyond foot/vehicle limits)
    elev = elev.astype(np.float32)
    elev[5:8, 70:73] = np.nan
    noise = np.sin(xx/5.0+seed*2)+np.cos(yy/4.0)+rng.normal(0,0.4,elev.shape)
    cls = np.full(elev.shape, 30, np.uint8)
    cls[noise < -0.8] = 20; cls[noise < -1.4] = 10; cls[noise > 1.0] = 60; cls[noise > 1.6] = 40
    cls[(yy > 36) & (yy < 44) & (xx > 50) & (xx < 62)] = 90
    cls[(yy > 8) & (yy < 14) & (xx > 55) & (xx < 66)] = 80
    cls[0:12, 0:20] = 10
    fmap = {10: 20, 20: 15, 30: 10, 40: 10, 60: 12, 90: 30, 80: 255}
    fr = np.vectorize(fmap.get)(cls).astype(np.uint8)
    trails = np.zeros(elev.shape, np.uint8)
    trails[30, 20:96] = 5
    trails[30:46, 60] = 15
    trails[10, 5:50] = 25
    trails[50, 10:30] = 15
    bar = np.zeros(elev.shape, np.uint8); bar[20:28, 30:50] = 255
    wild = np.zeros(elev.shape, np.uint8); wild[40:60, 0:25] = 255
    return elev, fr, cls, trails, bar, wild

def meta_for(rows, cols, cell_m=13.4, south=44.0, west=-115.0):
    dlat = cell_m/111000.0
    dlon = cell_m/(111000.0*math.cos(math.radians(40.0)))
    return {"south": south, "north": south+rows*dlat, "west": west, "east": west+cols*dlon,
            "pixel_size_lat": -dlat, "pixel_size_lon": dlon,
            "origin_lat": south+rows*dlat-0.5*dlat, "origin_lon": west+0.5*dlon,
            "cell_size_m": cell_m, "rows": rows, "cols": cols}

class Grid:
    def __init__(s, a): s.a = a
    def get_friction_grid(s, **k): return s.a
    def try_get_class_grid(s, **k): return s.a
    def get_barrier_grid(s, **k): return s.a
    def get_trails_grid(s, **k): return s.a
    def get_wilderness_grid(s, **k): return s.a
class Dem:
    def __init__(s, e, m): s.e, s.m = e, m
    def get_elevation_grid(s, **k): return s.e.astype(np.float64), s.m
    def estimate_grid_shape(s, **k): return s.m["shape"]
    def latlon_to_pixel(s, lat, lon, meta):
        return (int((meta["origin_lat"]-lat)/abs(meta["pixel_size_lat"])), int((lon-meta["origin_lon"])/meta["pixel_size_lon"]))
    def pixel_to_latlon(s, r, c, meta):
        return (meta["origin_lat"]+r*meta["pixel_size_lat"], meta["origin_lon"]+c*meta["pixel_size_lon"])
class Idx:
    def __init__(s, recs): s.r = recs
    def query_parking_near_line(s, coords, buffer_m=2000): return s.r
    def query_trailheads_near_line(s, coords, buffer_m=2000): return s.r

MODE = ["foot", "2w", "4w", "vehicle"]

def run_case(name, seed, scenarios, rows=64, cols=96):
    elev, fr, cls, trails, bar, wild = make_world(seed, rows, cols)
    m = meta_for(rows, cols)
    meta = {"bounds": (m["south"], m["north"], m["west"], m["east"]), "pixel_size_lat": m["pixel_size_lat"],
            "pixel_size_lon": m["pixel_size_lon"], "origin_lat": m["origin_lat"], "origin_lon": m["origin_lon"],
            "cell_size_m": m["cell_size_m"], "shape": (rows, cols)}
    def cell_ll(r, c):
        return (meta["origin_lat"]+(r+0.3)*meta["pixel_size_lat"], meta["origin_lon"]+(c+0.3)*meta["pixel_size_lon"])
    rng = np.random.default_rng(seed+99)
    park = []
    for k in range(24):
        r, c = int(rng.integers(2, rows-2)), int(rng.integers(2, cols-2))
        la, lo = cell_ll(r, c)
        park.append({"lat": la, "lon": lo, "name": f"P{k}", "access": ["yes", "private", "permit", "customers"][k % 4]})
    park.append({"lat": cell_ll(30, 25)[0], "lon": cell_ll(30, 25)[1], "name": "road-lot", "access": "yes"})
    park.append({"lat": cell_ll(46, 60)[0], "lon": cell_ll(46, 60)[1], "name": "track-lot", "access": "yes"})
    ths = []
    for k in range(20):
        r, c = int(rng.integers(2, rows-2)), int(rng.integers(2, cols-2))
        la, lo = cell_ll(r, c)
        ths.append({"lat": la, "lon": lo, "name": f"T{k}", "road_class": "track"})
    ths.append({"lat": cell_ll(10, 6)[0], "lon": cell_ll(10, 6)[1], "name": "th", "road_class": "path"})

    out_sc = []
    for sc in scenarios:
        s_ll = cell_ll(*sc["start"]); e_ll = cell_ll(*sc["end"])
        cap = {}
        r = OffrouteRouter()
        r.dem_reader = Dem(elev, meta)
        r.friction_reader = Grid(fr); r.landcover_reader = Grid(cls); r.barrier_reader = Grid(bar)
        r.trail_reader = Grid(trails); r.wilderness_reader = Grid(wild)
        R.get_mvum_access_grids_all_modes = lambda *a, **k: (_ for _ in ()).throw(RuntimeError("no mvum"))
        T.load_parking_index = lambda *a, **k: Idx([p for p in park if p["access"] not in ("private", "no", "permit") or True])
        T.load_trailheads = lambda *a, **k: Idx(ths)
        T.get_route_shape = lambda *a, **k: []
        T.get_surface_change_candidates = lambda *a, **k: []
        r._route_D_network_only = lambda *a, **k: {"status": "error", "message": "no valhalla"}
        ss = frozenset(sc["start_modes"]); es = frozenset(sc["end_modes"])
        r._spatial_eligible_modes = lambda lat, lon, cache, ss=ss, es=es, s_ll=s_ll: (ss if abs(lat-s_ll[0]) < 1e-12 and abs(lon-s_ll[1]) < 1e-12 else es)
        real_k = R.astar_multigoal_multimode; real_c = R.compute_unified_cost_layers
        def wk(*a, **k):
            res = real_k(*a, **k)
            cap["path"] = res[1].tolist(); cap["cost"] = float(res[2]); cap["idx"] = int(res[0])
            return res
        def wc(*a, **k):
            res = real_c(*a, **k)
            cap["stack"] = bits(res["cost_mult_stack"]); cap["trans"] = [list(map(float, t)) for t in res["transition_cells"]]
            return res
        R.astar_multigoal_multimode = wk; R.compute_unified_cost_layers = wc
        try:
            out = r._route_auto(s_ll[0], s_ll[1], e_ll[0], e_ll[1], sc["boundary"], None, None, sc.get("affinity"))
        finally:
            R.astar_multigoal_multimode = real_k; R.compute_unified_cost_layers = real_c
        feats = out.get("route", {}).get("features", []) if out.get("status") == "ok" else []
        comb = [f for f in feats if f["properties"]["segment_type"] == "combined"]
        res = {"status": out["status"], "message": out.get("message"),
               "selected_mode_set": out.get("selected_mode_set"),
               "total_distance_km": out.get("summary", {}).get("total_distance_km"),
               "total_effort_minutes": out.get("summary", {}).get("total_effort_minutes"),
               "combined": comb[0]["geometry"]["coordinates"] if comb else [],
               "segments": [[f["properties"]["network_mode"], len(f["geometry"]["coordinates"])] for f in feats if f["properties"]["segment_type"] == "unified"],
               "transitions": [[f["properties"]["lat"], f["properties"]["lon"], f["properties"]["from_mode"], f["properties"]["to_mode"]] for f in feats if f["properties"]["segment_type"] == "transition"]}
        out_sc.append({"sc": sc, "start_ll": s_ll, "end_ll": e_ll, "cap": cap, "res": res})
    return {"name": name, "rows": rows, "cols": cols, "meta": m,
            "elev": bits(elev), "friction": fr.reshape(-1).tolist(), "class": cls.reshape(-1).tolist(),
            "trails": trails.reshape(-1).tolist(), "barriers": bar.reshape(-1).tolist(), "wilderness": wild.reshape(-1).tolist(),
            "parking": park, "trailheads": ths, "scenarios": out_sc}

S = lambda **k: k
cases = [
 run_case("A", 1, [
   S(start=(50, 10), end=(30, 90), boundary="pragmatic", start_modes=["foot"], end_modes=["foot", "2w", "4w", "vehicle"]),
   S(start=(50, 10), end=(30, 90), boundary="strict", start_modes=["foot"], end_modes=["foot", "2w", "4w", "vehicle"]),
   S(start=(50, 10), end=(30, 90), boundary="emergency", start_modes=["foot", "2w"], end_modes=["foot", "2w", "4w", "vehicle"]),
   S(start=(12, 8), end=(55, 80), boundary="pragmatic", start_modes=["foot"], end_modes=["foot"]),
   S(start=(30, 22), end=(30, 92), boundary="pragmatic", start_modes=["foot", "2w", "4w", "vehicle"], end_modes=["foot", "2w", "4w", "vehicle"]),
   S(start=(12, 8), end=(44, 61), boundary="pragmatic", start_modes=["foot", "2w"], end_modes=["foot", "2w", "4w"], affinity={"foot": 3.0, "2w": 0.5, "4w": 2.0}),
 ]),
 run_case("B", 7, [
   S(start=(58, 5), end=(8, 90), boundary="pragmatic", start_modes=["foot"], end_modes=["foot", "4w", "2w"]),
   S(start=(30, 25), end=(46, 60), boundary="strict", start_modes=["foot", "2w", "4w", "vehicle"], end_modes=["foot", "2w", "4w"]),
   S(start=(3, 3), end=(60, 90), boundary="pragmatic", start_modes=["foot"], end_modes=["foot", "2w", "4w", "vehicle"]),
   S(start=(14, 40), end=(36, 40), boundary="strict", start_modes=["foot"], end_modes=["foot"]),
   S(start=(14, 40), end=(36, 40), boundary="pragmatic", start_modes=["foot"], end_modes=["foot"]),
   S(start=(14, 40), end=(36, 40), boundary="emergency", start_modes=["foot"], end_modes=["foot"]),
 ], rows=64, cols=96),
]
import gzip
json.dump(cases, gzip.open('fix/oracle_cases.json.gz', 'wt', compresslevel=9))
for c in cases:
    for s in c["scenarios"]:
        r = s["res"]; print(c["name"], s["sc"]["start"], s["sc"]["end"], s["sc"]["boundary"], r["status"], r["selected_mode_set"], r["total_effort_minutes"], len(r["combined"]), len(s["cap"].get("trans", [])), r["message"])
