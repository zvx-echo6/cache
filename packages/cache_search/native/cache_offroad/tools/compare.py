import json, math, re, sys, importlib.util
spec=importlib.util.spec_from_file_location('routes','routes.py'); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
def hav(a,b):
    R=6371000; la1,lo1,la2,lo2=map(math.radians,(a[1],a[0],b[1],b[0]))
    h=math.sin((la2-la1)/2)**2+math.cos(la1)*math.cos(la2)*math.sin((lo2-lo1)/2)**2
    return 2*R*math.atan2(math.sqrt(h),math.sqrt(1-h))
mine={}
cur=None
for line in open('t10.out'):
    line=line.rstrip()
    if line.startswith('## '): cur=line[3:].strip(); mine[cur]={'segs':[], 'trans':[]}; continue
    mm=re.match(r'ok effort_min=([\d.]+) distance_km=([\d.]+) modes=(\S+) cells=(\d+) grid=(\d+)x(\d+)',line)
    if mm and cur: mine[cur].update(effort=float(mm[1]),dist=float(mm[2]),modes=mm[3].split('+'),grid=(int(mm[5]),int(mm[6])))
    if line.startswith('error') and cur: mine[cur]['err']=line
    mm=re.match(r'\s+segment (\S+) (\d+) m',line)
    if mm and cur: mine[cur]['segs'].append((mm[1],int(mm[2])))
rows=[]
for (rid,s,e,sc,ec,b) in m.ROUTES:
    n=json.load(open(f'navi_out/{rid}.json'))
    mi=mine.get(rid,{})
    if n.get('status')!='ok': print(rid,'NAVI',n); continue
    feats=n['route']['features']
    segs=[(f['properties']['network_mode'], round(sum(hav(a,b2) for a,b2 in zip(f['geometry']['coordinates'],f['geometry']['coordinates'][1:])))) for f in feats if f['properties']['segment_type']=='unified']
    nt=n['summary']['total_effort_minutes']; nd=n['summary']['total_distance_km']
    rows.append((rid,nt,nd,sorted(n['selected_mode_set']),segs,mi))
    if 'effort' in mi:
        print(f"{rid:26s} navi {nt:9.3f} min {nd:8.3f} km {'+'.join(sorted(n['selected_mode_set'])):18s} | port {mi['effort']:9.3f} min {mi['dist']:8.3f} km {'+'.join(mi['modes']):18s} | d_effort {100*(mi['effort']-nt)/nt:+6.2f}% d_dist {100*(mi['dist']-nd)/nd:+6.2f}%  grid {mi['grid']}")
        print('      navi segs', segs); print('      port segs', mi['segs'])
    else:
        print(rid, 'port:', mi.get('err'), 'navi', nt, nd)
