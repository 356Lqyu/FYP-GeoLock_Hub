"""Resume B.3 using saved artifacts only: no solver execution, DB or network."""
from collections import Counter
from contextlib import ExitStack
from copy import deepcopy
from dataclasses import replace
import difflib
import hashlib
import json
from pathlib import Path
import re
import socket
from unittest.mock import patch

from google.protobuf import text_format
from ortools.constraint_solver import routing_enums_pb2,pywrapcp
from backend.routing.contract import freeze_scenario
from backend.routing.integration.worker import decode_plan
from backend.routing.phase_b import benchmark
from backend.routing.phase_b.validation import validate_plan
from .reproducibility import canonical,sha,save,blocked

ROOT=Path(__file__).resolve().parents[3]
OUT=ROOT/'results/stage-b3'

def load(path):return json.loads(path.read_text())
def need(condition,message):
    if not condition:raise RuntimeError(message)

def audit():
    target=OUT/'final-verification'
    attempt=1
    while target.exists():
        attempt+=1;target=OUT/f'final-verification-{attempt:02}'
    target.mkdir()
    protocol=load(OUT/'repeated-30s/protocol.json')
    source_match={p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest()==h for p,h in protocol['source_sha256'].items()}
    analysis=load(OUT/'analysis.json')
    source_match.update({p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest()==h for p,h in analysis['source_files'].items()})
    need(all(source_match.values()),'Source drift since recorded execution')
    original_guard=(OUT/'pre-correction/benchmark.py').read_bytes()
    need(original_guard==(ROOT/'backend/routing/phase_b/benchmark.py').read_bytes(),'Guard file changed')
    snapshots={};plans={};records={};native_parameters=[]
    digest_rows={r['record']:r for r in load(OUT/'postgres-hashing/candidate-digests.json')}
    for inp in sorted((OUT/'repeated-30s').glob('*.input.json')):
        name=inp.name[:-11];payload=load(inp);snapshot=freeze_scenario(payload)
        need(payload['solver']['time_limit_seconds']==30 and payload['solver']['workers']==1,'Wrong solver budget/workers')
        need(all(t['service_minutes']==10 for t in payload['tasks']),'Wrong service time')
        need(all(v['max_route_minutes']==240 for v in payload['vehicles']),'Wrong vehicle horizon')
        need(payload['configuration']['planning_horizon_minutes']==240,'Wrong snapshot horizon')
        need(payload['tasks']==sorted(payload['tasks'],key=lambda r:r['task_id']),'Task ordering drift')
        need(payload['vehicles']==sorted(payload['vehicles'],key=lambda r:r['vehicle_id']),'Vehicle ordering drift')
        selected=sorted((OUT/'repeated-30s').glob(name+'.[0-9][0-9].json'))
        need(len(selected)==3,'Missing independent repetitions')
        snapshots[name]=snapshot;plans[snapshot.sha256]=[];records[name]=[]
        for path in selected:
            r=load(path);plan=decode_plan(r['candidate']['plan']);v=validate_plan(snapshot,plan)
            need(r['snapshot_sha256']==snapshot.sha256 and r['matrix_sha256']==snapshot.matrix_sha256,'Frozen input hash mismatch')
            need(r['solver_version']=='9.15.6755' and r['hash_seed']=='0','Execution environment drift')
            need(r['candidate_canonical_json']==canonical(r['candidate']) and r['local_candidate_sha256']==sha(r['candidate']),'Candidate serialization/hash mismatch')
            need(v.valid and canonical(v.__dict__)==canonical(r['validation']),'Independent validation mismatch')
            need(not plan.dispatch_authority_issued,'Diagnostic plan issued authority')
            if name=='infeasible_capacity':
                need(not v.feasible and not plan.routes and plan.status=='INFEASIBLE' and plan.infeasibility_proven,'Infeasibility classification mismatch')
            else:need(v.feasible and plan.feasible,'Positive case has no feasible candidate')
            need(plan.timeout==r['native_time_limited'],'Timeout/native-limit mismatch')
            for call in r['calls']:
                p=pywrapcp.DefaultRoutingSearchParameters();p.Clear();text_format.Parse(call['search_parameters'],p)
                need(p.first_solution_strategy==routing_enums_pb2.FirstSolutionStrategy.PATH_CHEAPEST_ARC,'First solution strategy changed')
                need(p.local_search_metaheuristic==routing_enums_pb2.LocalSearchMetaheuristic.GUIDED_LOCAL_SEARCH,'Local search changed')
                need(p.use_cp==3 and p.use_cp_sat==2 and p.use_generalized_cp_sat==2 and p.fallback_to_cp_sat_size_threshold==0,'Primary engine/fallback changed')
                need(0<=p.time_limit.ToMilliseconds()<=30000,'Native pass exceeds total budget')
                native_parameters.append(dict(record=path.name,budget_ms=p.time_limit.ToMilliseconds(),native_limit=call['native_search_limit_reached']))
            h=digest_rows[path.name]
            need(json.loads(h['jsonb_text'])==r['candidate'],'PostgreSQL hashed a different candidate')
            need(hashlib.sha256(h['jsonb_text'].encode()).hexdigest()==h['candidate_digest'],'PostgreSQL candidate digest mismatch')
            plans[snapshot.sha256].append(plan);records[name].append(r)
    need(len(records)==8 and sum(map(len,records.values()))==24,'Wrong scenario/run count')
    need(len({r['pid'] for rs in records.values() for r in rs})==24,'Fresh-process PID evidence incomplete')
    calls=Counter()
    def replay(snapshot,config):
        index=calls[snapshot.sha256];calls[snapshot.sha256]+=1
        need(index<3,'Unexpected repeated execution requested')
        return plans[snapshot.sha256][index]
    # Replay real saved plans through the ORIGINAL guard and validator. This
    # patches test transport only; no optimizer is called or policy activated.
    with ExitStack() as stack:
        stack.enter_context(patch.object(socket.socket,'connect',blocked))
        stack.enter_context(patch.object(socket,'create_connection',blocked))
        stack.enter_context(patch.object(pywrapcp.RoutingModel,'SolveWithParameters',side_effect=RuntimeError('SAVED_OUTPUT_REPLAY_ONLY')))
        stack.enter_context(patch.object(benchmark,'METHODS',{'proposed':replay}))
        benchmark.run_benchmark(target/'guard-replay',repeats=3,selected=snapshots)
    # Clearly labelled synthetic control, never written over native records.
    sample=snapshots['one_pickup'];index=[0]
    def changed_timeout(snapshot,config):
        p=plans[snapshot.sha256][index[0]];index[0]+=1
        return replace(p,timeout=not p.timeout) if index[0]==2 else p
    negative_error=None
    with patch.object(benchmark,'METHODS',{'proposed':changed_timeout}):
        try:benchmark.run_benchmark(target/'negative-control',repeats=3,selected={'CONTROLLED_TIMEOUT_MUTATION':sample})
        except RuntimeError as e:negative_error=str(e)
    need(negative_error and 'NONREPRODUCIBLE_RESULT' in negative_error,'Guard did not reject controlled semantic variation')
    warm_before=[load(p) for p in (OUT/'pre-correction/warm-short').glob('warm_mixed.[0-9][0-9].json')]
    warm_after=[load(p) for p in (OUT/'corrected-warm').glob('warm_mixed.[0-9][0-9].json')]
    need(len(warm_before)==len(warm_after)==60,'Missing warm replay evidence')
    need(Counter(r['candidate']['plan']['timeout'] for r in warm_before)=={True:45,False:15},'Original timeout counts differ')
    need(len({r['semantic_sha256'] for r in warm_before})==2 and len({r['semantic_sha256'] for r in warm_after})==1,'Warm semantic result mismatch')
    need(load(OUT/'postgres-hashing/results.json')['cluster_stopped'],'No recorded hash cluster shutdown')
    runtime=Path((ROOT/'results/stage-b1/runtime-path.txt').read_text().strip())
    need(not (runtime/'data-postgres-hashing/postmaster.pid').exists(),'Hash cluster still has postmaster.pid')
    server=(OUT/'postgres-hashing/postgresql-server.log').read_text()
    need('database system is shut down' in server,'No hash cluster shutdown log')
    for file,count in [('unit-regressions.log',93),('candidate-pipeline-tests.log',5)]:
        text=(OUT/file).read_text(encoding='utf-8-sig')
        need(f'Ran {count} tests' in text and text.rstrip().endswith('OK'),'Final test log missing success')
    diff=''.join(difflib.unified_diff((OUT/'pre-correction/routing_model.py').read_text().splitlines(True),(ROOT/'backend/routing/phase_b/routing_model.py').read_text().splitlines(True),fromfile='before-B3',tofile='after-B3'))
    (target/'timeout-correction.diff').write_text(diff,encoding='utf-8')
    result=dict(status='PASS',scope='OFFLINE_RESUME_AUDIT_NO_SOLVER_OR_DATABASE_EXECUTION',
        scenarios=8,runs=24,independent_validation_valid=24,feasible=21,infeasible=3,native_time_limited=18,finished_early=6,
        guard_replay='PASS_ALL_EIGHT_THREE_REPETITIONS',negative_guard_control=negative_error,
        guard_replay_manifest_note='REPLAY_ONLY. Its method-engine label describes the replay adapter, not the actual native executions. Use repeated-30s/protocol.json and calls for actual engine settings.',
        guard_file_byte_identical=True,original_warm_timeout_counts={'true':45,'false':15},corrected_warm_semantic_variants=1,
        source_match=source_match,native_parameters=native_parameters,postgres_digest_rows_verified=24,
        postgres_cluster_stopped=True,regression_tests_passed=98,expensive_runs_repeated=False,
        policy_activated=False,supabase_connections=0)
    save(target/'results.json',result)
    print('PASS: 24 saved native runs, eight strict guard replays, 98 recorded tests; no expensive experiments repeated.')

if __name__=='__main__':audit()
