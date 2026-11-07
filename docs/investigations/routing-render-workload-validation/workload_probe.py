"""Offline modeled workloads. No DB snapshot envelopes, approvals or receipts."""
from time import perf_counter
START=perf_counter()
import argparse
from array import array
import copy
from dataclasses import asdict
import hashlib
import json
import math
from pathlib import Path
import resource
import sys
sys.path.insert(0,'/app')

ARTIFACT_SHA='7958972d08ea412c7515a47521640588528daa206440a198db2ad47507b8bd01'
SIZES=[('small',3,2),('typical-provisional',10,2),('large-provisional',25,5),('source-boundary-stress',100,10)]


def canonical(value):return json.dumps(value,sort_keys=True,separators=(',',':'))
def digest(value):return hashlib.sha256(canonical(value).encode()).hexdigest()
def metrics():
    root=Path('/sys/fs/cgroup');r=resource.getrusage(resource.RUSAGE_SELF)
    return dict(peak_rss_bytes=r.ru_maxrss*1024,cpu_seconds=r.ru_utime+r.ru_stime,
                cgroup={n:(root/n).read_text().strip() for n in ('memory.max','memory.peak','memory.events','cpu.max','cpu.stat')})
def emit(value):
    value.update(wall_seconds=perf_counter()-START,metrics=metrics());print(json.dumps(value),flush=True)
def graph():
    from backend.routing.hosted.compact_graph import CompactGraph
    with Path('/fixtures/graph.jsonl').open() as f:manifest=json.loads(next(f))['graph']
    return CompactGraph.read_artifact('/var/data/approved-graph.csr',ARTIFACT_SHA,manifest)
def wrap(matrix):
    result=copy.deepcopy(matrix);result['source_kind']='SYNTHETIC_BENCHMARK'
    result['provenance']='OFFLINE SYNTHETIC ENTITY WORKLOAD, NO DB AUTHORITY; '+matrix['provenance']
    return result


def component(g,depot):
    """Selection only: mutual reachability, never crops shortest-path searches."""
    n=g.node_count;counts=array('Q',[0])*(n+1)
    for t in g._targets:counts[t+1]+=1
    for i in range(n):counts[i+1]+=counts[i]
    cursor=array('Q',counts[:-1]);reverse=array('I',[0])*g.edge_count
    for src in range(n):
        for pos in range(g._offsets[src],g._offsets[src+1]):
            target=g._targets[pos];reverse[cursor[target]]=src;cursor[target]+=1
    def visit(offsets,targets):
        seen=bytearray(n);seen[depot]=1;stack=[depot]
        while stack:
            node=stack.pop()
            for pos in range(offsets[node],offsets[node+1]):
                other=targets[pos]
                if not seen[other]:seen[other]=1;stack.append(other)
        return seen
    return visit(g._offsets,g._targets),visit(counts,reverse)


def prepare():
    import csv
    from backend.routing.contract import freeze_scenario,ContractError
    from backend.routing.hosted.artifact import load_export
    from backend.routing.integration.graph_worker import matrix_from_export
    source=json.loads(Path('/fixtures/frozen.json').read_text());g=graph()
    with Path('/fixtures/road_nodes.csv').open(encoding='utf-8-sig') as f:
        road_rows=list(csv.DictReader(f))
    options=[];selection_evidence=[]
    for case in source['cases']:
        base=case['input'];depot=base['depot']
        try:index=g._index(depot['road_node_id'])
        except ContractError:
            selection_evidence.append(dict(scenario=case['scenario_id'],status='DEPOT_NOT_IN_GRAPH'));continue
        forward,reverse=component(g,index);candidates=[];matched=0
        for row in road_rows:
            node=row['road_node_id'];lat=float(row['latitude']);lon=float(row['longitude'])
            a,b=map(math.radians,(depot['latitude'],lat));dl=math.radians(lon-depot['longitude'])
            km=6371*2*math.asin(min(1,math.sqrt(math.sin((b-a)/2)**2+math.cos(a)*math.cos(b)*math.sin(dl/2)**2)))
            if node==depot['road_node_id'] or km>17:continue
            try:idx=g._index(node)
            except ContractError:continue
            matched+=1
            if forward[idx] and reverse[idx]:candidates.append(dict(node=node,lat=lat,lon=lon,km=km))
        candidates.sort(key=lambda r:(r['km'],r['node']))
        selection_evidence.append(dict(scenario=case['scenario_id'],matching_nodes_in_radius=matched,mutually_reachable=len(candidates)))
        options.append((len(candidates),case['scenario_id'],base,candidates))
    assert options,'No benchmark depot matches full graph'
    _,selected_scenario,base,candidates=max(options,key=lambda item:(item[0],item[1]));depot=base['depot']
    admitted=set(freeze_scenario(base).admitted_task_ids)
    template_tasks=[task for task in base['tasks'] if task['task_id'] in admitted]
    assert template_tasks
    count=min(99,len(candidates));assert count>=3,selection_evidence
    selected=[candidates[round(i*(len(candidates)-1)/(count-1))] for i in range(count)]
    full_order=[depot['road_node_id']]+[x['node'] for x in selected]
    started=perf_counter();raw=g.matrix(full_order);csr_seconds=perf_counter()-started
    # Independent legacy parity at the largest available (up to 100) node set.
    manifest,nodes,edges=load_export('/fixtures/graph.jsonl','a525f79eada8fc65ce0568fd0cdba66237f1e5e6e3009bb4fa0e7482fc70accb')
    started=perf_counter();legacy=matrix_from_export(manifest,nodes,edges,full_order);legacy_seconds=perf_counter()-started
    assert raw==legacy,'Full-graph legacy/CSR matrix parity failed';del nodes,edges,legacy
    out=Path('/out/cases');out.mkdir(exist_ok=False);manifest_cases=[]
    for name,pickups,vehicles in SIZES:
        unique=min(pickups,count);locations=[selected[round(i*(count-1)/(unique-1))] for i in range(unique)]
        indices=[0]+[full_order.index(loc['node']) for loc in locations]
        matrix=copy.deepcopy(raw);matrix['node_order']=[full_order[i] for i in indices]
        for key in ('distance_km','travel_minutes','arc_status'):matrix[key]=[[raw[key][i][j] for j in indices] for i in indices]
        value=copy.deepcopy(base);value['planning_run_id']=value['scenario_id']='OFFLINE-MODELED-'+name
        value['source']=dict(kind='SYNTHETIC_BENCHMARK',project_ref=None,
            provenance='User-authorized provisional offline stress model; derived benchmark entities, complete frozen real graph. NOT observed NGO demand, a DB snapshot or deployment approval.',
            evidence_ref='WORKLOAD_MANIFEST.json')
        value['depot']['network_snapshot_id']=manifest['coverage_snapshot'];value['depot']['state_token']=digest(value['depot'])
        value['matrix']=wrap(matrix);value['tasks']=[];value['vehicles']=[]
        for i in range(pickups):
            task=copy.deepcopy(template_tasks[i%len(template_tasks)]);loc=locations[i%unique]
            assert task['source_type']=='DIRECT_DONATION' and task['batch'] is None
            for key in ('task_id','claim_id','lease_id','listing_id'):task[key]=f'OFFLINE-{name}-{key}-{i:03d}'
            for key in ('pickup','authorized_pickup'):
                task[key]=dict(latitude=loc['lat'],longitude=loc['lon'],road_node_id=loc['node'],
                    network_snapshot_id=manifest['coverage_snapshot'],location_id=f'OFFLINE-LOCATION-{name}-{i:03d}',
                    state_token=digest(loc))
            for j,d in enumerate(task['donations']):d['donation_id']=f'OFFLINE-{name}-DONATION-{i}-{j}';d['state_token']=digest(d)
            for key in ('task_state_token','claim_state_token','lease_state_token'):task[key]=digest(dict(modeled_task=i,case=name,kind=key))
            value['tasks'].append(task)
        for i in range(vehicles):
            v=copy.deepcopy(base['vehicles'][i%len(base['vehicles'])]);v['vehicle_id']=f'OFFLINE-{name}-VEHICLE-{i:03d}';v['state_token']=digest(v)
            value['vehicles'].append(v)
        frozen=freeze_scenario(value);assert len(frozen.admitted_task_ids)==pickups and frozen.readiness=='READY_FOR_PLANNING'
        assert len(frozen.available_vehicle_ids)==vehicles
        entry=dict(name=name,pickups=pickups,vehicles=vehicles,required_nodes=len(matrix['node_order']),
            provisional=True,observed_real_world_demand=False,operational_approval=None,
            input=value,snapshot_sha256=frozen.sha256,matrix_sha256=frozen.matrix_sha256,raw_graph_matrix_sha256=digest(matrix))
        path=out/(name+'.json');path.write_text(json.dumps(entry),encoding='utf-8')
        manifest_cases.append({k:entry[k] for k in entry if k!='input'})
    metadata=dict(scope='MODELED_OFFLINE_CAPACITY_ONLY_NO_DB_ENVELOPES_OR_RECEIPTS',cases=manifest_cases,
        source_frozen_fixture_sha256=hashlib.sha256(Path('/fixtures/frozen.json').read_bytes()).hexdigest(),
        source_road_nodes_sha256=hashlib.sha256(Path('/fixtures/road_nodes.csv').read_bytes()).hexdigest(),
        graph_file_sha256='a525f79eada8fc65ce0568fd0cdba66237f1e5e6e3009bb4fa0e7482fc70accb',artifact_sha256=ARTIFACT_SHA,
        graph_nodes=g.node_count,graph_edges=g.edge_count,mutually_reachable_candidates=len(candidates),
        modeled_radius_km=17,largest_selected_straight_line_km=max(x['km'] for x in selected),
        node_selection=f'{count} distance-quantile public benchmark nodes mutually reachable with selected benchmark depot; full graph retained for every shortest path',
        selected_base_scenario=selected_scenario,depot_selection_evidence=selection_evidence,
        largest_required_nodes=len(full_order),legacy_csr_parity=True,csr_matrix_seconds=csr_seconds,legacy_matrix_seconds=legacy_seconds,
        assumptions=['Provisional 3/10/25/100 pickups and 2/2/5/10 vehicles authorized by current user request, not empirical NGO distributions',
            'Distinct pickup nodes use only known mutually reachable benchmark coordinates, capped at 99 plus depot; co-location is explicit',
            'Direct-only modeled pickups; no new hub batch/inventory facts',
            'Original synthetic E4 cutoff/windows/leases, 10min service, optional pickups, 240min horizon, 100kg/500kg fleet templates retained',
            'Original 30s solver wall budget, one worker, seed42; ExecutionConfig deterministic 0.25s/pass unchanged',
            'Local state tokens and canonical input hashes describe synthetic modeled facts; no DB digests, approvals or receipts minted'])
    Path('/out/WORKLOAD_MANIFEST.json').write_text(json.dumps(metadata,indent=2),encoding='utf-8');emit(metadata)


def planner(name,label):
    from backend.routing.contract import freeze_scenario
    from backend.routing.phase_b import METHODS,validate_plan
    from backend.routing.phase_b.models import ExecutionConfig
    entry=json.loads(Path('/fixtures/cases/'+name+'.json').read_text());p=entry['input'];began=perf_counter();g=graph();load=perf_counter()-began
    began=perf_counter();actual=wrap(g.matrix(p['matrix']['node_order']));matrix_seconds=perf_counter()-began
    assert actual==p['matrix'];frozen=freeze_scenario(p);assert frozen.sha256==entry['snapshot_sha256']
    results=[];plans=[]
    for method,solve in METHODS.items():
        began=perf_counter();plan=solve(frozen,ExecutionConfig());elapsed=perf_counter()-began
        began=perf_counter();check=validate_plan(frozen,plan);validation=perf_counter()-began
        assert check.valid and not plan.dispatch_authority_issued
        results.append(dict(method=method,wall_seconds=elapsed,validation_seconds=validation,
            valid=check.valid,feasible=check.feasible,usable=bool(plan.routes) and check.feasible,
            served=sum(len(route.stops) for route in plan.routes),unserved=len(plan.unserved_tasks),status=plan.status,
            timeout=plan.timeout,coverage_optimal=plan.coverage_optimal,secondary_optimal=plan.secondary_optimal,
            solver_statuses=plan.solver_statuses,solver_runtime_seconds=plan.solver_runtime_seconds))
        plans.append(asdict(plan))
    result=dict(case=name,pickups=entry['pickups'],vehicles=entry['vehicles'],nodes=entry['required_nodes'],
        artifact_load_seconds=load,matrix_seconds=matrix_seconds,methods=results,
        proposed_usable=next(r for r in results if r['method']=='proposed')['usable'],
        all_plans_valid=all(r['valid'] for r in results),any_solver_timeout=any(r['timeout'] for r in results))
    with Path('/out/'+label+'-plans.json').open('x') as f:json.dump(dict(input=p,plans=plans,input_sha256=frozen.sha256),f)
    emit(result)


def validate(path):
    from backend.routing.contract import freeze_scenario
    from backend.routing.integration.worker import decode_plan
    from backend.routing.phase_b.validation import validate_plan
    data=json.loads(Path(path).read_text());frozen=freeze_scenario(data['input']);assert frozen.sha256==data['input_sha256'];items=[]
    for raw in data['plans']:
        began=perf_counter();plan=decode_plan(raw);check=validate_plan(frozen,plan)
        assert check.valid and not plan.dispatch_authority_issued
        items.append(dict(method=plan.method,seconds=perf_counter()-began,valid=check.valid,feasible=check.feasible,
                          usable=bool(plan.routes) and check.feasible,timeout=plan.timeout))
    emit(dict(scope='SEPARATE_INDEPENDENT_RAW_PLAN_VALIDATION_NOT_DB_WORK_ITEM_ATTESTATION',methods=items,
              input_sha256=frozen.sha256,all_valid=True))


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('mode',choices=('prepare','planner','validator'))
    parser.add_argument('--case');parser.add_argument('--label');parser.add_argument('--plans');a=parser.parse_args()
    if a.mode=='prepare':prepare()
    elif a.mode=='planner':planner(a.case,a.label)
    else:validate(a.plans)
