import sys, json, gzip
sys.path.insert(0, 'navi')
import types
for n in ['psycopg2','rasterio','pmtiles','pmtiles.reader']:
    pass
import numpy as np
from shapely.geometry import LineString, MultiLineString
import services.navi_offroute.mvum as M
rng = np.random.default_rng(5)
rows, cols = 40, 50
south, west = 44.0, -115.0
import math
dlat = 13.4/111000.0; dlon = 13.4/(111000.0*math.cos(math.radians(40)))
north = south + rows*dlat; east = west + cols*dlon
statuses = [None, "", "open", "Open", "closed", "no", "restricted"]
dates = [None, "", "05/01-11/30", "12/01-03/31,06/15-10/15", "garbage", "6/1-9/30"]
feats = []
for k in range(60):
    pts = [(west + rng.random()*cols*dlon*1.2 - 0.1*cols*dlon, south + rng.random()*rows*dlat*1.2 - 0.1*rows*dlat) for _ in range(rng.integers(2, 6))]
    geom = LineString(pts) if k % 5 else MultiLineString([pts[:2], pts[1:]]) if len(pts) > 2 else LineString(pts)
    row = {"symbol": str(rng.choice(["1","2","3","4","11","12","7",""])) or None,
           "seasonal": str(rng.choice(["yearlong","seasonal","", "x"])),
           "operationalmaintlevel": "2 - HIGH CLEARANCE"}
    for f in ["atv","highclearancevehicle","e_bike_class1"]:
        row[f] = statuses[rng.integers(0, len(statuses))]
    for f in ["atv_datesopen","highclearancevehicle_datesopen","e_bike_class1_dur"]:
        row[f] = dates[rng.integers(0, len(dates))]
    row["id"] = k
    feats.append((geom, row))
class Row(dict):
    pass
out = []
for check in [None, (7, 15), (1, 15)]:
    grids = {m: np.zeros((rows, cols), np.uint8) for m in ["mtb","atv","vehicle"]}
    for geom, row in feats:
        r = Row(row)
        for m in grids:
            a = M._row_access(r, "mvum_roads", m, check)
            if a is None: continue
            M._rasterize_feature(grids[m], geom, 1 if a else 255, west, north, dlon, dlat)
    out.append({"check": check, "grids": {m: g.reshape(-1).tolist() for m, g in grids.items()}})
json.dump({"rows": rows, "cols": cols, "south": south, "west": west, "dlat": dlat, "dlon": dlon,
           "features": [{"lines": [list(map(list, l.coords)) for l in (g.geoms if g.geom_type=="MultiLineString" else [g])], "row": r} for g, r in feats],
           "out": out}, gzip.open('fix/mvum_cases.json.gz','wt'))
print("ok", [int((np.array(o['grids']['atv'])>0).sum()) for o in out])
