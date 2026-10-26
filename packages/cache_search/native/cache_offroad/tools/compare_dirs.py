import json, sys
D=json.load(open('dirs.json'))
for (rid,_,_) in D:
    n=json.load(open(f'navi_out/{rid}.dir.json')); p=json.load(open(f'dir_out_port_{rid}.json'))
    print('==',rid,'navi ok',n.get('ok'),n.get('routing'),'| port ok',p.get('ok'),p.get('routing'), n.get('errors') or '', p.get('errors') or '')
    if not (n.get('ok') and p.get('ok')): continue
    ns,ps=n['summary'],p['summary']
    print('  summary navi', ns['distance_km'], ns['duration_s'], ns['step_count'], '| port', ps['distance_km'], ps['duration_s'], ps['step_count'], '| shape equal', n['shape']==p['shape'], len(n['shape']), len(p['shape']))
    print('  warnings navi', [w['code']+':'+w['end'] for w in n.get('warnings',[])], 'port', [w['code']+':'+w['end'] for w in p.get('warnings',[])])
    def sig(s): return (s['kind'], s.get('mode'), s['type'])
    nk=[sig(s) for s in n['steps']]; pk=[sig(s) for s in p['steps']]
    print('  step kinds equal:', nk==pk)
    same=0; diffs=[]
    for i,(a,b) in enumerate(zip(n['steps'],p['steps'])):
        keys=set(a)|set(b)
        bad=[k for k in keys if a.get(k)!=b.get(k)]
        if not bad: same+=1
        else: diffs.append((i,bad))
    print(f'  identical steps {same} of navi {len(n["steps"])} / port {len(p["steps"])}')
    for i,bad in diffs[:6]:
        a=n['steps'][i]; b=p['steps'][i]
        print('   step',i,a['kind'],a['type'],'differs in',sorted(bad), {k:(a.get(k),b.get(k)) for k in sorted(bad) if k in('distance_m','distance_km','duration_s','bearing_deg','follow','terrain','grade_class','instruction')})
