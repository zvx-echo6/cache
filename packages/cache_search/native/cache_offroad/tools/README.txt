Oracle and parity tooling (Python, run on a Linux box; not part of the build or the tests).

gen_fixtures.py   runs navi's own OffrouteRouter._route_auto on synthetic worlds -> tests/fixtures/oracle_cases.json.gz
gen_mvum.py       navi's MVUM rasterisation on random features              -> tests/fixtures/mvum_cases.json.gz
routes.py         the 12 Idaho parity routes (coordinates, seed categories, boundary mode)
navi_call.sh      one POST to navi PROD per call (keep to the agreed request budget; never 06:30-08:30 UTC)
compare.py        navi PROD answers vs `offroad_pack route` output

They expect a read-only copy of navi's backend/ (services/navi_offroute, shared/dem.py) at ./navi and numpy,
scipy, numba, shapely importable (psycopg2/rasterio/pmtiles are stubbed by the scripts).
