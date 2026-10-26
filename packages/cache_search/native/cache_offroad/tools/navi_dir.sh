#!/bin/bash
# usage: navi_dir.sh <id>   one POST to navi PROD /api/directions, result to navi_out/<id>.dir.json
cd "$(dirname "$0")"
H=$(date -u +%H%M); if [ "$H" -ge 0630 ] && [ "$H" -le 0830 ]; then echo "blocked window 06:30-08:30 UTC"; exit 2; fi
python3 - "$1" <<'PY'
import sys, json, urllib.request, time
D={x[0]:x for x in json.load(open('dirs.json'))}
r=D[sys.argv[1]]
body={"from":list(r[1]),"to":list(r[2]),"mode":"drive","describe_ends":False}
req=urllib.request.Request("https://navi.echo6.co/api/directions",data=json.dumps(body).encode(),headers={"Content-Type":"application/json","User-Agent":"cache-offroad-parity/1"})
t=time.time()
try:
    resp=urllib.request.urlopen(req,timeout=150); data=resp.read(); code=resp.status
except urllib.error.HTTPError as e:
    data=e.read(); code=e.code
print(sys.argv[1],code,round(time.time()-t,1),"s",len(data),"bytes")
open("navi_out/%s.dir.json"%sys.argv[1],"wb").write(data)
PY
