import sys, json, gzip, math
sys.path.insert(0, 'navi')
import types
import numpy as np
import services.navi_offroute.mvum_surface_change as S

def cat_for(lat):
    k = int(abs(lat) * 1e5) % 4
    return [("road", "residential", "paved_smooth"), ("road", "tertiary", "gravel"), ("track", "service_other", "dirt"), ("footway", "path", "path")][k]

def fake_trace(coords, url):
    n = len(coords)
    edges, i = [], 0
    while i < n - 1:
        j = min(n - 1, i + 7)
        use, rc, surf = cat_for(coords[i][0])
        edges.append({"use": use, "road_class": rc, "surface": surf, "begin_shape_index": i, "end_shape_index": j})
        i = j
    return edges, [tuple(c) for c in coords]

S._trace_chunk = fake_trace
S.MAX_TRACE_POINTS = 40
S.MAX_TRACE_PATH_M = 2000.0
out = {"classify": [], "cases": []}
for use in ["road", "track", "footway", "path", "cycleway", "", "service"]:
    for rc in ["", "residential", "service_other"]:
        for surf in ["", "paved", "paved_smooth", "gravel", "dirt", "compacted", "asphalt", "path", "sand", "weird"]:
            e = {"use": use, "road_class": rc, "surface": surf}
            out["classify"].append({"use": use, "road_class": rc, "surface": surf, "cat": S.classify_surface(e)})
rng = np.random.default_rng(3)
for k in range(5):
    n = [30, 120, 210, 90, 400][k]
    lat, lon = 44.0 + rng.random()*0.1, -115.0 + rng.random()*0.1
    coords = []
    for _ in range(n):
        lat += 0.0004 + rng.normal(0, 0.00005); lon += 0.0003 + rng.normal(0, 0.00005)
        coords.append((round(lat, 6), round(lon, 6)))
    cands = S.get_surface_change_candidates(coords, "http://x")
    out["cases"].append({"coords": coords, "cands": [[c["lat"], c["lon"], c["name"]] for c in cands]})
    print(k, n, len(S._chunk_bounds(coords)), len(cands))
enc = S.encode_polyline6([(44.123456, -115.654321), (44.1235, -115.6542), (43.99, -115.7)])
out["poly"] = {"enc": enc, "dec": S.decode_polyline6(enc)}
json.dump(out, open('fix/surface_cases.json', 'w'))
