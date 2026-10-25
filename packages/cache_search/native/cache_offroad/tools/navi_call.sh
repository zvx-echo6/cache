#!/bin/bash
# usage: navi_call.sh <route-id>   one POST to navi PROD, result to navi_out/<id>.json
cd "$(dirname "$0")"
mkdir -p navi_out
H=$(date -u +%H%M); if [ "$H" -ge 0630 ] && [ "$H" -le 0830 ]; then echo "blocked window 06:30-08:30 UTC"; exit 2; fi
python3 - "$1" <<'PY'
import sys, json, importlib.util, urllib.request, time
spec=importlib.util.spec_from_file_location('routes','routes.py'); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
r=[x for x in m.ROUTES if x[0]==sys.argv[1]][0]
body={"start":list(r[1]),"end":list(r[2]),"mode":"auto","boundary_mode":r[5],"start_category":r[3],"end_category":r[4]}
req=urllib.request.Request("https://navi.echo6.co/api/offroute",data=json.dumps(body).encode(),headers={"Content-Type":"application/json","User-Agent":"cache-offroad-parity/1"})
t=time.time()
try:
    resp=urllib.request.urlopen(req,timeout=150); data=resp.read(); code=resp.status
except urllib.error.HTTPError as e:
    data=e.read(); code=e.code
print(sys.argv[1],code,round(time.time()-t,1),"s",len(data),"bytes")
open("navi_out/%s.json"%sys.argv[1],"wb").write(data)
PY
