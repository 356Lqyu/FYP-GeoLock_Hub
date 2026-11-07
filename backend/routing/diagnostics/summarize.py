"""Index B.3 raw observations without modifying experiments or policy guards."""
import collections
import hashlib
import json
from pathlib import Path
from .reproducibility import canonical,sha,save
ROOT=Path(__file__).resolve().parents[3]

def comparison(folder):
    rows=[]
    for source in sorted(folder.glob('*.input.json')):
        name=source.name[:-11]
        records=[json.loads(p.read_text()) for p in sorted(folder.glob(name+'.[0-9][0-9].json'))]
        variants=collections.defaultdict(set)
        for r in records:
            p=r['candidate']['plan'];v=r['validation'];m=v['metrics']
            projections=dict(stop_order=[(x['vehicle_id'],[s['task_id'] for s in x['stops']]) for x in p['routes']],
                vehicle_assignment=sorted((s['task_id'],x['vehicle_id']) for x in p['routes'] for s in x['stops']),
                objective=m['weighted_secondary_cost'],total_distance=m['total_travel_km'],total_duration=m['total_route_minutes'],
                coverage=m['served_count'],solver_status=p['solver_statuses'],timeout=p['timeout'],
                candidate_bytes=r['candidate_canonical_json'],candidate_digest=r['local_candidate_sha256'],validation=v,
                snapshot=r['snapshot_sha256'],matrix=r['matrix_sha256'],routes=r['routes_sha256'],semantic=r['semantic_sha256'])
            for k,value in projections.items():variants[k].add(canonical(value))
        rows.append(dict(scenario=name,repetitions=len(records),distinct={k:len(v) for k,v in variants.items()},
            metrics=[r['validation']['metrics'] for r in records],
            runtime_seconds=[r['candidate']['plan']['runtime_seconds'] for r in records],
            native_search_seconds=[sum(c['native_elapsed_seconds'] for c in r['calls']) for r in records],
            native_time_limited=[r['native_time_limited'] for r in records],
            timeout=[r['candidate']['plan']['timeout'] for r in records],
            statuses=[r['candidate']['plan']['solver_statuses'] for r in records],
            validation_valid=[r['validation']['valid'] for r in records],feasible=[r['validation']['feasible'] for r in records],
            dispatch_authority=[r['candidate']['plan']['dispatch_authority_issued'] for r in records]))
    return rows

def main():
    root=ROOT/'results/stage-b3';rows=comparison(root/'repeated-30s')
    if len(rows)!=8 or any(r['repetitions']!=3 for r in rows):raise RuntimeError('Expected eight complete three-repetition cases')
    hashes=json.loads((root/'postgres-hashing/candidate-digests.json').read_text())
    for r in rows:
        r['distinct']['postgres_candidate_digest']=len({h['candidate_digest'] for h in hashes if h['record'].startswith(r['scenario']+'.')})
    before=(root/'pre-correction/benchmark.py').read_bytes();after=(ROOT/'backend/routing/phase_b/benchmark.py').read_bytes()
    result=dict(scope='LOCAL_B3_DIAGNOSTIC_NOT_CHAPTER5',scenarios=rows,
        guard_file_byte_identical=before==after,guard_sha256=hashlib.sha256(after).hexdigest(),
        original_warm=comparison(root/'pre-correction/warm-short'),corrected_warm=comparison(root/'corrected-warm'),
        all_inputs_matrices_stable=all(r['distinct']['snapshot']==r['distinct']['matrix']==1 for r in rows),
        all_validation_valid=all(all(r['validation_valid']) for r in rows),
        strict_guard_would_pass_all_eight=all(r['distinct']['semantic']==1 for r in rows),
        source_files={p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in ['backend/routing/phase_b/routing_model.py','backend/routing/phase_b/benchmark.py','backend/routing/integration/worker.py','backend/routing/worker_service/orchestrator.py','docs/stage8/stage-b2/forward-migrations/20261104_spatial_endpoint_validation.sql']})
    save(root/'analysis.json',result)
    for r in rows:print(r['scenario'],r['distinct'],r['runtime_seconds'])

if __name__=='__main__':main()
