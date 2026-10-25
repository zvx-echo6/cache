# Oracle for the directions port: navi's directions_offroad / directions assembly on routes of the synthetic
# worlds (path detail recorded by navi's own router), with a deterministic fake Valhalla and a fake namer.
import sys, json, gzip, math
sys.path.insert(0, 'navi')
import gen_fixtures as G
import numpy as np
import services.navi_offroute.router as R
import services.navi_offroute.transitions as T
import services.navi_offroute.directions as D
import services.navi_offroute.directions_offroad as O
from services.navi_offroute.router import OffrouteRouter
from services.navi_offroute.mvum_surface_change import encode_polyline6, decode_polyline6

class FakeResp:
    def __init__(s, body): s.b = body
    def json(s): return s.b

def fake_valhalla(frm, to, costing):
    a, b = frm, to
    mid = ((a[0]+b[0])/2 + 0.0004, (a[1]+b[1])/2 - 0.0003)
    shape_in = [a, mid, b]
    enc = encode_polyline6(shape_in)
    shape = decode_polyline6(enc)
    def hav(p, q): return D._haversine_m(p, q)
    d0, d1 = hav(shape[0], shape[1])/1000.0, hav(shape[1], shape[2])/1000.0
    mans = [
        {"type": 1, "instruction": "Drive north.", "street_names": ["Test Rd"], "bearing_after": 10.4, "begin_shape_index": 0, "end_shape_index": 1, "length": d0, "time": d0*60.0+0.4},
        {"type": 15, "instruction": "Turn left onto X St.", "street_names": ["X St", "Alt"], "bearing_before": 11.0, "begin_shape_index": 1, "end_shape_index": 2, "length": d1, "time": d1*60.0+0.6},
        {"type": 4, "instruction": "Your destination is on the right.", "bearing_before": 200.0, "begin_shape_index": 2, "end_shape_index": 2, "length": 0.0, "time": 0.0},
    ]
    return FakeResp({"trip": {"legs": [{"shape": enc, "maneuvers": mans}], "summary": {"length": d0+d1, "time": d0*60.0+d1*60.0+1.0}}}), None

class FakeNamer:
    def __init__(s, *a, **k): s.samples = 0; s.hits = 0
    def __call__(s, points, trail_kind):
        return [("Rd%d" % (int(abs(la)*2000) % 3)) if trail_kind != "trail" else None for la, lo in points]
    def close(s): pass

D._valhalla_route = lambda frm, to, costing: fake_valhalla(frm, to, costing)
D.FollowNamer = FakeNamer

def one(case_seed, sc, merge, minleg, flat=False):
    rows, cols = 64, 96
    elev, fr, cls, trails, bar, wild = G.make_world(case_seed, rows, cols)
    if flat:
        elev = (1200 + 0.12 * (elev.astype(np.float64) - 1200)).astype(np.float32)
    m = G.meta_for(rows, cols)
    meta = {"bounds": (m["south"], m["north"], m["west"], m["east"]), "pixel_size_lat": m["pixel_size_lat"], "pixel_size_lon": m["pixel_size_lon"],
            "origin_lat": m["origin_lat"], "origin_lon": m["origin_lon"], "cell_size_m": m["cell_size_m"], "shape": (rows, cols)}
    def cell_ll(r, c): return (meta["origin_lat"]+(r+0.3)*meta["pixel_size_lat"], meta["origin_lon"]+(c+0.3)*meta["pixel_size_lon"])
    rng = np.random.default_rng(case_seed+99)
    park = []
    for k in range(24):
        r, c = int(rng.integers(2, rows-2)), int(rng.integers(2, cols-2)); la, lo = cell_ll(r, c)
        park.append({"lat": la, "lon": lo, "name": f"P{k}", "access": ["yes", "private", "permit", "customers"][k % 4]})
    park.append({"lat": cell_ll(30, 25)[0], "lon": cell_ll(30, 25)[1], "name": "road-lot", "access": "yes"})
    park.append({"lat": cell_ll(46, 60)[0], "lon": cell_ll(46, 60)[1], "name": "track-lot", "access": "yes"})
    ths = []
    for k in range(20):
        r, c = int(rng.integers(2, rows-2)), int(rng.integers(2, cols-2)); la, lo = cell_ll(r, c)
        ths.append({"lat": la, "lon": lo, "name": f"T{k}", "road_class": "track"})
    ths.append({"lat": cell_ll(10, 6)[0], "lon": cell_ll(10, 6)[1], "name": "th", "road_class": "path"})
    s_ll = cell_ll(*sc["start"]); e_ll = cell_ll(*sc["end"])
    r = OffrouteRouter()
    r.collect_path_detail = True
    r.dem_reader = G.Dem(elev, meta)
    r.friction_reader = G.Grid(fr); r.landcover_reader = G.Grid(cls); r.barrier_reader = G.Grid(bar)
    r.trail_reader = G.Grid(trails); r.wilderness_reader = G.Grid(wild)
    R.get_mvum_access_grids_all_modes = lambda *a, **k: (_ for _ in ()).throw(RuntimeError("no mvum"))
    T.load_parking_index = lambda *a, **k: G.Idx(park)
    T.load_trailheads = lambda *a, **k: G.Idx(ths)
    T.get_route_shape = lambda *a, **k: []
    T.get_surface_change_candidates = lambda *a, **k: []
    r._route_D_network_only = lambda *a, **k: {"status": "error"}
    ss = frozenset(sc["start_modes"]); es = frozenset(sc["end_modes"])
    r._spatial_eligible_modes = lambda lat, lon, cache: (ss if abs(lat-s_ll[0]) < 1e-12 and abs(lon-s_ll[1]) < 1e-12 else es)
    out = r._route_auto(s_ll[0], s_ll[1], e_ll[0], e_ll[1], sc["boundary"], None, None, sc.get("affinity"))
    pieces = O.pieces_from_result(out, r.path_detail)
    steps, shape, mans, km, err = D._assemble_offroad(pieces, {"merge_bearing_deg": merge, "min_leg_m": minleg})
    d = r.path_detail["unified"]
    return {"flat_elev": G.bits(elev) if flat else None, "sc": sc, "start_ll": s_ll, "end_ll": e_ll, "merge": merge, "min_leg": minleg,
            "detail": {k: d[k] for k in ("lat", "lon", "mode", "elev", "terrain", "trail", "step_s")},
            "pieces": [{"type": p["type"], "mode": p["mode"], "extra_s": p["extra_s"], "after_switch": p.get("after_switch")} for p in pieces],
            "steps": steps, "shape": [list(p) for p in shape], "km": km, "err": err,
            "road_steps_input": None}

cases = json.load(gzip.open('fix/oracle_cases.json.gz', 'rt'))
out = []
for ci, case in enumerate(cases):
    seed = {"A": 1, "B": 7}[case["name"]]
    for si, s in enumerate(case["scenarios"]):
        for (merge, minleg) in [(60.0, 150.0), (35.0, 60.0)]:
            if (merge, minleg) != (60.0, 150.0) and si % 2: continue
            res = one(seed, s["sc"], merge, minleg)
            res.update({"case": case["name"], "sc_index": si})
            out.append(res)
            print(case["name"], si, merge, minleg, len(res["steps"]), [p["type"]+":"+p["mode"] for p in res["pieces"]], res["km"])
extra = [
  ("A", 1, dict(start=(30, 22), end=(30, 92), boundary="pragmatic", start_modes=["vehicle"], end_modes=["vehicle"])),
  ("A", 1, dict(start=(50, 10), end=(30, 90), boundary="pragmatic", start_modes=["foot"], end_modes=["vehicle"])),
  ("B", 7, dict(start=(30, 25), end=(46, 60), boundary="strict", start_modes=["vehicle"], end_modes=["foot", "2w", "4w"])),
]
for name, seed, sc in extra:
    for (merge, minleg) in [(60.0, 150.0), (35.0, 60.0)]:
        res = one(seed, sc, merge, minleg, flat=True)
        res.update({"case": name, "sc_index": -1})
        out.append(res)
        print(name, 'extra', merge, minleg, len(res["steps"]), [p["type"]+":"+p["mode"] for p in res["pieces"]], res["km"], res["err"])
json.dump(out, gzip.open('fix/directions_cases.json.gz', 'wt', compresslevel=9))
