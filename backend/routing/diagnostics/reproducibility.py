"""Stage B.3: opt-in fresh-process diagnostics; never starts workers or databases."""
import argparse
from copy import deepcopy
from contextlib import nullcontext
from dataclasses import asdict
from datetime import datetime,timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import socket
import subprocess
import sys
import time
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[3]

def canonical(value):return json.dumps(value,sort_keys=True,separators=(',',':'),allow_nan=False)
def sha(value):return hashlib.sha256(canonical(value).encode()).hexdigest()
def save(path,value):path.write_text(json.dumps(value,indent=2,sort_keys=True,allow_nan=False)+'\n',encoding='utf-8')
def blocked(*a,**k):raise RuntimeError('LOCAL_DIAGNOSTIC_NETWORK_FORBIDDEN')

def execute(payload,trace_native=True):
    from ortools.constraint_solver import pywrapcp
    from google.protobuf import text_format
    import ortools
    from backend.routing.contract import freeze_scenario
    from backend.routing.phase_b import proposed,validate_plan
    from backend.routing.phase_b.benchmark import semantic
    snapshot=freeze_scenario(payload);calls=[];native=pywrapcp.RoutingModel.SolveWithParameters
    def trace(model,params):
        start=time.perf_counter();assignment=native(model,params);elapsed=time.perf_counter()-start
        calls.append(dict(search_parameters=text_format.MessageToString(params),budget_ms=params.time_limit.ToMilliseconds(),
            solution_limit=params.solution_limit,native_elapsed_seconds=elapsed,native_status=model.status(),
            native_search_limit_reached=bool(model.CheckLimit()),has_incumbent=assignment is not None,
            native_objective=assignment.ObjectiveValue() if assignment else None))
        return assignment
    with patch.object(socket.socket,'connect',blocked),patch.object(socket,'create_connection',blocked), (patch.object(pywrapcp.RoutingModel,'SolveWithParameters',trace) if trace_native else nullcontext()):
        plan=proposed(snapshot);validation=validate_plan(snapshot,plan)
    raw={'plan':asdict(plan)}
    metrics=validation.metrics
    return dict(snapshot_sha256=snapshot.sha256,matrix_sha256=snapshot.matrix_sha256,
        candidate=raw,candidate_canonical_json=canonical(raw),local_candidate_sha256=sha(raw),
        semantic_sha256=sha(semantic(plan)),routes_sha256=sha(asdict(plan)['routes']),
        metrics_sha256=sha(metrics),validation=asdict(validation),validation_sha256=sha(asdict(validation)),
        calls=calls,solver_version=ortools.__version__,python=sys.version,platform=platform.platform(),
        pid=os.getpid(),hash_seed=os.environ.get('PYTHONHASHSEED'),
        digest_scope='LOCAL_CANONICAL_JSON_NOT_POSTGRES_JSONB_DIGEST',
        native_time_limited=any(c['native_search_limit_reached'] and (i>0 or not c['has_incumbent'] or c['solution_limit']!=1) for i,c in enumerate(calls)),
        captured_at=datetime.now(timezone.utc).isoformat())

def fixtures():
    from backend.routing.generate_examples import build_mixed,task,location,token
    from backend.routing.phase_b.scenarios import edge_payloads
    from backend.routing.phase_c2 import freeze_graph,build_matrix
    import ortools
    cases={}
    p=build_mixed();p['vehicles']=p['vehicles'][:1];p['tasks']=p['tasks'][:1];cases['one_pickup']=p
    p=build_mixed();p['vehicles']=p['vehicles'][:1];p['vehicles'][0]['capacity_kg']=100;cases['multiple_pickups']=p
    cases['multiple_vehicles']=edge_payloads()['cost_tradeoff']
    p=build_mixed();p['vehicles'][1]['capacity_kg']=35;cases['capacity_constrained']=p
    p=build_mixed();p['vehicles']=p['vehicles'][:1];p['vehicles'][0]['capacity_kg']=100
    p['tasks'][0]['time_window']['start']='2026-10-24T00:35:00Z';p['tasks'][1]['time_window']['end']='2026-10-24T00:35:00Z';cases['time_window_constrained']=p
    cases['infeasible_capacity']=edge_payloads()['capacity_infeasible']
    p=build_mixed();p['vehicles']=p['vehicles'][:1];p['vehicles'][0]['capacity_kg']=100
    p['matrix']['distance_km']=[[0,2,5],[9,0,3],[2,7,0]];p['matrix']['travel_minutes']=[[0,4,10],[18,0,6],[4,14,0]]
    p['matrix']['provenance']='SYNTHETIC directed shortest-path fixture from explicit directed complete edge pairs; no measured travel'
    cases['directed_distances']=p
    p=deepcopy(cases['multiple_pickups']);p['matrix']['distance_km']=[[0,1,1],[1,0,1],[1,1,0]];p['matrix']['travel_minutes']=[[0,2,2],[2,0,2],[2,2,0]]
    p['matrix']['provenance']='SYNTHETIC equal directed edge costs; equivalent pickup permutations';cases['tied_costs']=p
    for name,p in cases.items():
        p['scenario_id']='SYNTHETIC-B3-'+name;p['planning_run_id']='LOCAL-B3-'+name
        p['solver']['version']=ortools.__version__;p['solver']['time_limit_seconds']=30
        p['tasks']=sorted(p['tasks'],key=lambda t:t['task_id']);p['vehicles']=sorted(p['vehicles'],key=lambda v:v['vehicle_id'])
        # Freeze matrices from declared directed graph edges through the existing
        # path builder; retain SYNTHETIC_BENCHMARK provenance and fixed node order.
        old=p['matrix'];nodes=old['node_order'];edges=[dict(edge_id=f'B3-{i}-{j}',source_node=a,target_node=b,road_km=old['distance_km'][i][j],travel_minutes=old['travel_minutes'][i][j]) for i,a in enumerate(nodes) for j,b in enumerate(nodes) if i!=j]
        graph=freeze_graph(nodes=nodes,edges=edges,snapshot_id=old['network_snapshot_id'],kind='SYNTHETIC_BENCHMARK',complete=True,speed_profile='FIXED SYNTHETIC DIRECTED EDGES; NOT OBSERVED ROAD DATA')
        p['matrix']=build_matrix(graph,nodes)
        p['source']['provenance']+='; B3 verification case '+name+'; synthetic graph; not a Chapter 5 sample'
    return cases

def child(payload_path,out):
    save(out,execute(json.loads(payload_path.read_text())))

def run(out,short=False):
    if out.exists() or not out.resolve().is_relative_to(ROOT):raise ValueError('New workspace output directory required')
    out.mkdir(parents=True);cases=fixtures()
    if short:
        from backend.routing.generate_examples import build_mixed
        p=build_mixed();p['solver']['time_limit_seconds']=.2;cases={'historical_mixed_short':p}
    repetitions=20 if short else 3
    save(out/'protocol.json',dict(scope='B3_DIAGNOSTIC_NOT_CHAPTER5',repetitions=repetitions,
        rationale='Three fresh processes per each of eight cases detect repeat variation without more than 12 minutes of nominal search; not a precision/stability estimate.' if not short else 'Twenty original short-budget attempts to reproduce the preserved failure with raw plans.',
        sequential=True,hash_seed='0',supabase_connections=0,
        source_sha256={p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in ['backend/routing/phase_b/routing_model.py','backend/routing/phase_b/benchmark.py',str(Path(__file__).relative_to(ROOT)).replace('\\','/')]}))
    for name,payload in cases.items():
        path=out/(name+'.input.json');save(path,payload)
        for repetition in range(repetitions):
            target=out/f'{name}.{repetition:02}.json'
            env={k:v for k,v in os.environ.items() if not k.upper().startswith(('PG','GEOLOCK','SUPABASE')) and k.upper()!='DATABASE_URL'};env['PYTHONHASHSEED']='0'
            proc=subprocess.run([sys.executable,'-B','-m','backend.routing.diagnostics.reproducibility','--child',str(path),'--output',str(target)],cwd=ROOT,env=env,capture_output=True,text=True,timeout=85)
            (out/f'{name}.{repetition:02}.log').write_text(proc.stdout+proc.stderr,encoding='utf-8')
            if proc.returncode:raise RuntimeError(f'{name} repetition {repetition} failed: '+proc.stderr)
            record=json.loads(target.read_text());print(name,repetition,record['candidate']['plan']['status'],record['candidate']['plan']['runtime_seconds'],record['semantic_sha256'][:12],flush=True)
    compare(out)

def compare(out):
    rows=[]
    for inp in sorted(out.glob('*.input.json')):
        name=inp.name[:-11];records=[json.loads(p.read_text()) for p in sorted(out.glob(name+'.[0-9][0-9].json'))]
        if not records:raise RuntimeError('Missing repetitions '+name)
        fields=['snapshot_sha256','matrix_sha256','local_candidate_sha256','semantic_sha256','routes_sha256','metrics_sha256','validation_sha256']
        row=dict(scenario=name,runs=len(records),unique={k:len({r[k] for r in records}) for k in fields},
            runtime_seconds=[r['candidate']['plan']['runtime_seconds'] for r in records],
            timeout=[r['candidate']['plan']['timeout'] for r in records],native_time_limited=[r['native_time_limited'] for r in records],
            statuses=[r['candidate']['plan']['solver_statuses'] for r in records],
            all_validation_valid=all(r['validation']['valid'] for r in records),
            feasible=[r['validation']['feasible'] for r in records],metrics=[r['validation']['metrics'] for r in records],
            strict_guard_would_pass=len({r['semantic_sha256'] for r in records})==1,
            semantic_changed_fields=[k for k in records[0]['candidate']['plan'] if k not in ('runtime_seconds','solver_runtime_seconds') and len({canonical(r['candidate']['plan'][k]) for r in records})>1])
        rows.append(row)
    save(out/'comparison.json',rows);print('COMPARISON',canonical([{k:r[k] for k in ('scenario','runs','strict_guard_would_pass','semantic_changed_fields','unique')} for r in rows]),flush=True)

def warm_short(out):
    if out.exists():raise ValueError('New output required')
    out.mkdir(parents=True)
    from backend.routing.generate_examples import build_mixed
    payload=build_mixed();payload['solver']['time_limit_seconds']=.2
    save(out/'warm_mixed.input.json',payload)
    for i in range(60):
        record=execute(payload,trace_native=False);save(out/f'warm_mixed.{i:02}.json',record)
    compare(out)

def main():
    p=argparse.ArgumentParser();p.add_argument('--child',type=Path);p.add_argument('--output',required=True,type=Path);p.add_argument('--short',action='store_true');p.add_argument('--warm-short',action='store_true');p.add_argument('--compare',action='store_true');a=p.parse_args()
    if a.child:child(a.child,a.output)
    elif a.compare:compare(a.output)
    elif a.warm_short:warm_short(a.output)
    else:run(a.output,a.short)

if __name__=='__main__':main()
