"""All 100 frozen v3.3 scenarios, original baselines, actual worker optimizer."""
import argparse, copy, hashlib, json, sys, time
from pathlib import Path
from types import SimpleNamespace
from dataclasses import asdict
sys.path.insert(0,str(Path(__file__).resolve().parents[2]))
from experiments.repro_benchmark import ROOT,DATA,sha,write,rows,csv_write,module,integrity,environment,clear_remote_env
from backend.routing.benchmark_v32.adapter import Adapter as ExistingAdapter
from backend.routing.benchmark_v32.runner import baseline_plan
from backend.routing.contract import freeze_scenario
from backend.routing.phase_b import METHODS,proposed,validate_plan
from backend.routing.phase_b.models import ExecutionConfig
from backend.routing.phase_b.benchmark import semantic

SETTINGS=dict(approved=True,geofence_km=20,lease_minutes=360,route_minutes=240,service_minutes=10,
 safety_margin_minutes=0,mandatory=False,availability_policy='BASELINE_ROUTING_WINDOW',
 listing_expiry_policy='COMMON_STAGE8_ADMISSION',currency='BENCHMARK_COST_UNIT',fixed_cost=5,
 distance_cost_per_km=1,solver_wall_seconds=30,deterministic_seconds_per_pass=0.25,seed=42)

class Adapter(ExistingAdapter):
    def __init__(self):
        self.settings=dict(SETTINGS);self.root=ROOT;self.modules={n:module(n) for n in ('fcfs','nearest_next')}
        self.base=self.modules['nearest_next'];self.args=SimpleNamespace(**SETTINGS)
        self.data=self.base.setup_route_data(DATA)
        self.nodes={r['road_node_id']:r for r in rows(DATA/'road_nodes.csv')}
        self.scenarios=self.base.select_scenarios(self.data,('ROUTE_PLANNING',),None)
        assert len(self.scenarios)==100
    def convert(self,scenario):
        shared,frozen=super().convert(scenario)
        # Version labels only; never regenerate/rewrite source data or costs.
        payload=frozen.to_dict()['input']
        def version(v):
            if isinstance(v,dict):return {k:version(x) for k,x in v.items()}
            if isinstance(v,list):return [version(x) for x in v]
            return 'OSM-DIRECTED-v3.3' if v=='OSM-DIRECTED-v3.2' else v
        payload=version(payload);payload['configuration']['version']='E4-V33-ACTUAL-WORKER'
        return shared,freeze_scenario(payload)

def run(output,only=None):
    clear_remote_env();verified=integrity();adapter=Adapter()
    output=Path(output).resolve();assert output.is_relative_to(ROOT/'experiments/e4_post_claim_routing/results')
    output.mkdir(parents=True,exist_ok=False);(output/'raw').mkdir()
    assert METHODS['proposed'] is proposed and proposed.__module__=='backend.routing.phase_b.optimizers'
    sources={str(p.relative_to(ROOT)):sha(p) for folder in ['backend/routing/phase_b','backend/routing/phase_c2','backend/routing/integration','backend/routing/worker_service'] for p in (ROOT/folder).glob('*.py')}
    for p in [Path(__file__),ROOT/'experiments/repro_benchmark.py',ROOT/'backend/routing/contract.py',ROOT/'backend/routing/benchmark_v32/adapter.py',ROOT/'backend/routing/benchmark_v32/runner.py']:sources[str(p.relative_to(ROOT))]=sha(p)
    manifest=dict(status='RUNNING',integrity=verified,environment=environment(),configuration=SETTINGS,source_sha256=sources,
      actual_proposed='backend.routing.phase_b.optimizers.proposed: same callable used by integration solve_bundle/METHODS',
      runs_per_method_per_scenario=1,formal_supervisor_approval_not_inferred=True)
    write(output/'manifest.json',manifest)
    # Reproduce the original full-500-task baseline outputs separately. The
    # common-admission lane below must not be confused with those original runs.
    if not only:
        for name in ('nearest_next','fcfs'):
            original=adapter.modules[name]
            argv=[name,'--dataset-dir',str(DATA),'--output-dir',str(output/('original_'+name))]
            if name=='fcfs':argv+=['--snapshot-file',str(output/'original_nearest_next/details/planning_snapshots.json')]
            saved=sys.argv;sys.argv=argv
            try:original.main()
            finally:sys.argv=saved
    records=[];snapshots={};errors=[]
    for number,scenario in enumerate(adapter.scenarios,1):
        if only and scenario['scenario_id']!=only:continue
        sid=scenario['scenario_id'];shared,frozen=adapter.convert(scenario);snapshots[sid]=shared
        write(output/'raw'/f'{sid}-input.json',dict(shared=shared,worker_input=frozen.to_dict(),frozen_sha256=frozen.sha256,exclusions=frozen.excluded_tasks))
        for method in ('nearest_next','fcfs','proposed'):
            began=time.perf_counter()
            try:
                plan=proposed(frozen,ExecutionConfig()) if method=='proposed' else baseline_plan(adapter,shared,frozen,method,ExecutionConfig())
                planning_ms=(time.perf_counter()-began)*1000
                checked=validate_plan(frozen,plan)
                raw=dict(plan=asdict(plan),independent_validation=asdict(checked))
                write(output/'raw'/f'{sid}-{method}.json',raw)
                served=sum(len(r.stops) for r in plan.routes);valid=len(frozen.admitted_task_ids)
                metrics=checked.metrics
                row=dict(scenario_id=sid,method=method,valid_tasks=valid,served_tasks=served,coverage_percent=100*served/valid if valid else None,
                  total_distance_km=metrics.get('total_travel_km'),travel_duration_min=metrics.get('driving_minutes'),route_duration_min=metrics.get('total_route_minutes'),
                  capacity_violations=sum('CAPACITY' in x[0] for x in checked.violations),time_window_violations=sum('WINDOW' in x[0] for x in checked.violations),
                  route_duration_violations=sum('DURATION' in x[0] for x in checked.violations),feasibility_pass=checked.valid and checked.feasible,
                  validation_valid=checked.valid,plan_status=plan.status,timeout=plan.timeout,planner_execution_ms=plan.runtime_seconds*1000,adapter_call_ms=planning_ms,
                  frozen_sha256=frozen.sha256,shared_snapshot_sha256=shared['snapshot_id'],error='')
                # Validator metric names are authoritative; also derive exact
                # distances/times from independently validated route accounting.
                row['metrics']=json.dumps(metrics,sort_keys=True)
                row['semantic_sha256']=hashlib.sha256(json.dumps(semantic(plan),sort_keys=True,default=str).encode()).hexdigest()
            except Exception as e:
                row=dict(scenario_id=sid,method=method,valid_tasks=len(frozen.admitted_task_ids),served_tasks=None,coverage_percent=None,feasibility_pass=False,validation_valid=False,error=type(e).__name__+':'+str(e))
                errors.append(row);write(output/'raw'/f'{sid}-{method}-failure.json',row)
            records.append(row)
        csv_write(output/'results_per_scenario.csv',records)
        print(f'E4 {number}/100 {sid}',flush=True)
    comparisons=[]
    for sid in snapshots:
        group={r['method']:r for r in records if r['scenario_id']==sid};p=group['proposed']
        for name in ('nearest_next','fcfs'):
            b=group[name];equal=b.get('served_tasks') is not None and b.get('served_tasks')==p.get('served_tasks')
            comparable=equal and b['feasibility_pass'] and p['feasibility_pass']
            comparisons.append(dict(scenario_id=sid,baseline=name,baseline_served=b.get('served_tasks'),proposed_served=p.get('served_tasks'),equal_coverage=equal,
              distance_comparable=comparable,baseline_km=b.get('total_distance_km'),proposed_km=p.get('total_distance_km'),
              proposed_minus_baseline_km=p['total_distance_km']-b['total_distance_km'] if comparable and p.get('total_distance_km') is not None and b.get('total_distance_km') is not None else None))
    csv_write(output/'comparison.csv',comparisons)
    summary=[]
    for method in ('nearest_next','fcfs','proposed'):
        rr=[r for r in records if r['method']==method]
        summary.append(dict(method=method,scenarios=len(rr),valid_tasks=sum(r['valid_tasks'] for r in rr),served_tasks=sum(r.get('served_tasks') or 0 for r in rr),
         feasibility_passes=sum(r['feasibility_pass'] for r in rr),errors=sum(bool(r.get('error')) for r in rr),
         total_distance_km=sum(r.get('total_distance_km') or 0 for r in rr),total_planner_execution_ms=sum(r.get('planner_execution_ms') or 0 for r in rr)))
    csv_write(output/'summary.csv',summary)
    write(output/'completion.json',dict(executed=True,scenarios=len(snapshots),evaluations=len(records),errors=len(errors),all_100_completed=len(snapshots)==100,source_unchanged=all(sha(ROOT/k)==v for k,v in sources.items())))
    print(json.dumps(summary),flush=True)

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--output',required=True);p.add_argument('--scenario');a=p.parse_args();run(a.output,a.scenario)
