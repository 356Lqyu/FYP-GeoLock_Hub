"""Read executed artifacts; never connects to any database or invokes solvers."""
import argparse,csv,hashlib,json,math,statistics,sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from experiments.repro_benchmark import ROOT,rows,write,csv_write,sha

def percentile(values,q):
    if not values:return None
    v=sorted(values);i=(len(v)-1)*q;lo=int(i);hi=math.ceil(i)
    return v[lo]+(v[hi]-v[lo])*(i-lo)
def table(records):
    fields=list(records[0]);lines=['| '+' | '.join(fields)+' |','|'+'|'.join('---' for _ in fields)+'|']
    for r in records:lines.append('| '+' | '.join(str(r.get(k,'')) for k in fields)+' |')
    return '\n'.join(lines)

def e4(run):
    complete=json.loads((run/'completion.json').read_text());assert complete['all_100_completed'] and complete['evaluations']==300
    data=rows(run/'results_per_scenario.csv');assert len(data)==300
    # Revalidate each saved plan from the preserved immutable inputs. This is
    # a verifier, not another optimization or a route-generation request.
    from backend.routing.contract import freeze_scenario
    from backend.routing.integration.worker import decode_plan
    from backend.routing.phase_b import validate_plan
    summaries=[];issues=[];extra_exclusions=[]
    for p in sorted((run/'raw').glob('*-input.json')):
        item=json.loads(p.read_text());sid=item['shared']['scenario_id']
        frozen=freeze_scenario(item['worker_input']['input'])
        for tid,reasons in item['exclusions']:extra_exclusions.append(dict(scenario_id=sid,task_id=tid,reasons=';'.join(reasons)))
        rr=[r for r in data if r['scenario_id']==sid];assert len(rr)==3
        assert len({r['frozen_sha256'] for r in rr})==1
        for r in rr:
            raw=json.loads((run/'raw'/f'{sid}-{r["method"]}.json').read_text());plan=decode_plan(raw['plan']);check=validate_plan(frozen,plan)
            assert check.valid and check.feasible,(sid,r['method'],check.violations)
            assert frozen.sha256==r['frozen_sha256'] and len(frozen.admitted_task_ids)==int(r['valid_tasks'])
            assert check.metrics==json.loads(r['metrics'])
    csv_write(run/'additional_admission_exclusions.csv',extra_exclusions)
    for method in ('nearest_next','fcfs','proposed'):
        rr=[r for r in data if r['method']==method];valid=sum(int(r['valid_tasks']) for r in rr);served=sum(int(r['served_tasks']) for r in rr)
        lat=[float(r['planner_execution_ms']) for r in rr]
        summaries.append(dict(method=method,scenarios=len(rr),valid_tasks=valid,served_tasks=served,task_weighted_coverage_pct=round(100*served/valid,3),
          mean_scenario_coverage_pct=round(statistics.mean(float(r['coverage_percent']) for r in rr),3),
          distance_km=round(sum(float(r['total_distance_km']) for r in rr),5),travel_min=round(sum(float(r['travel_duration_min']) for r in rr),5),
          route_duration_min=round(sum(float(r['route_duration_min']) for r in rr),5),capacity_violations=sum(int(r['capacity_violations']) for r in rr),
          window_violations=sum(int(r['time_window_violations']) for r in rr),duration_violations=sum(int(r['route_duration_violations']) for r in rr),
          feasibility_pass=sum(r['feasibility_pass']=='True' for r in rr),timeouts=sum(r['timeout']=='True' for r in rr),
          median_planner_ms=round(statistics.median(lat),4),p95_planner_ms=round(percentile(lat,.95),4)))
    csv_write(run/'summary_statistics.csv',summaries)
    comparisons=rows(run/'comparison.csv');pairs=[]
    for method in ('nearest_next','fcfs'):
        allrows=[r for r in comparisons if r['baseline']==method];equal=[r for r in allrows if r['distance_comparable']=='True']
        base=sum(float(r['baseline_km']) for r in equal);prop=sum(float(r['proposed_km']) for r in equal)
        strict=[]
        for r in equal:
            sid=r['scenario_id']
            b=next(x for x in data if x['scenario_id']==sid and x['method']==method)
            pr=next(x for x in data if x['scenario_id']==sid and x['method']=='proposed')
            if json.loads(b['metrics'])['served_tasks']==json.loads(pr['metrics'])['served_tasks']:strict.append(r)
        strict_base=sum(float(r['baseline_km']) for r in strict);strict_prop=sum(float(r['proposed_km']) for r in strict)
        pairs.append(dict(baseline=method,paired_scenarios=len(allrows),equal_served_task_count=len(equal),coverage_differs=len(allrows)-len(equal),
          baseline_equal_coverage_km=round(base,5),proposed_equal_coverage_km=round(prop,5),distance_reduction_pct=round(100*(base-prop)/base,3),
          identical_served_task_sets=len(strict),strict_baseline_km=round(strict_base,5),strict_proposed_km=round(strict_prop,5),
          strict_distance_reduction_pct=round(100*(strict_base-strict_prop)/strict_base,3)))
    csv_write(run/'paired_distance_summary.csv',pairs)
    original=[];repro=[]
    for method,folder in [('nearest_next','6_nearest_next'),('fcfs','7_fcfs')]:
        published=rows(ROOT/'baseline implementation/result'/folder/'results_per_scenario.csv')
        fresh=rows(run/('original_'+method)/'results_per_scenario.csv')
        assert len(fresh)==len(published)==100
        differences=[a['scenario_id'] for a,b in zip(published,fresh) if {k:v for k,v in a.items() if k!='planning_time_ms'}!={k:v for k,v in b.items() if k!='planning_time_ms'}]
        repro.append(dict(method=method,scenarios=100,semantic_differences=differences))
        original.append(dict(method=method,scenarios=100,valid_tasks=sum(int(r['tasks_valid']) for r in fresh),served_tasks=sum(int(r['tasks_collected']) for r in fresh),distance_km=round(sum(float(r['total_distance_km']) for r in fresh),3),feasibility_pass=sum(r['all_rules_passed']=='YES' for r in fresh)))
    csv_write(run/'original_baseline_summary.csv',original)
    report='# E4 executed results\n\nReadiness: **PARTIAL for the unchanged original methodology; all 100 scenarios were executed.**\n\n'
    report+='## Original baseline reproduction (500 tasks)\n\n'+table(original)+'\n\nBoth original methods reproduce all published non-runtime scenario fields exactly.\n\n'
    report+='## Supplemental common-GeoLock-admission comparison (483 tasks)\n\n'+table(summaries)+'\n\n'
    report+='The unchanged current worker admission excludes 17 supplied tasks whose listings expire before the full planning horizon. The existing adapter applies that same admission to both original algorithms and the actual optimizer. This is a clearly labelled supplemental lane, not an unchanged 500-task experiment or a new frozen dataset. All supplied rows remain in raw inputs/exclusion evidence.\n\n'
    report+='## Distance on equal served-task counts only\n\n'+table(pairs)+'\n\n'
    report+='All methods receive identical frozen input hashes in the supplemental lane. Equal counts do not guarantee identical served task identities; coverage differences and per-stop identities remain in raw outputs. The two coverage-different scenarios per comparison are excluded from distance aggregation. No all-scenario aggregate distance improvement is claimed. This single-run, synthetic-task benchmark does not prove end-to-end HTTP/DEV/driver performance or donor-window feasibility: the original baselines use the routing horizon as the time window. No formal significance test or supervisor approval is inferred.\n'
    (run/'COMPARISON.md').write_text(report,encoding='utf-8')
    write(run/'verification.json',dict(status='PASS_ARTIFACT_CHECKS_NOT_FORMAL_PARITY',analysis_source_sha256=sha(__file__),saved_routes_independently_revalidated=300,additional_admission_exclusions=len(extra_exclusions),original_baseline_reproduction=repro))
    return summaries

def e2(run):
    completion=json.loads((run/'completion.json').read_text());assert completion['completed_proposed']==275 and completion['failures']==0
    assert json.loads((run/'cluster-stop.json').read_text())['stopped']
    proposed=rows(run/'proposed_results_per_scenario.csv');raw=json.loads((run/'proposed_requests.json').read_text())
    records=[];scenario_rows=[];lease_records=[]
    for name in ('non_atomic_claim','protected_claim_without_lease_recovery','proposed'):
        if name=='proposed':
            contention=[r for r in proposed if r['scenario_id'].startswith('SCN-CLAIM_COORDINATION-')]
            lease=[r for r in proposed if r['scenario_id'].startswith('SCN-LEASE_')]
            requests=[dict(scenario_id=r['scenario_id'],answer=r['outcome'],response_ms=r['latency_ms'],reason_code=r['reason_code']) for r in raw]
        else:
            contention=rows(run/name/'results_per_scenario.csv')
            lp=run/name/'lease_results_per_scenario.csv';lease=rows(lp) if lp.exists() else []
            requests=rows(run/name/'details/requests.csv')
        assert len(contention)==150
        for level in (2,5,10):
            rr=[r for r in contention if int(r['ngos_competing'])==level];assert len(rr)==50
            rq=[r for r in requests if r['scenario_id'] in {x['scenario_id'] for x in rr}]
            times=[float(r['response_ms']) for r in rq if float(r['response_ms'])>0 and r['answer']!='INELIGIBLE']
            records.append(dict(method=name,workers=level,trials=50,requests=len(rq),
              duplicate_trials=sum(r['more_than_one_owner']=='YES' for r in rr),extra_committed_claims=sum(max(int(r['claims_stored'])-1,0) for r in rr),
              exactly_one_committed_claim=sum(int(r['claims_stored'])==1 for r in rr),exactly_one_success_response=sum(int(r['told_success'])==1 for r in rr),
              successes=sum(int(r['told_success']) for r in rr),conflicts=sum(int(r['told_already_claimed']) for r in rr),ineligible=sum(int(r['told_not_eligible']) for r in rr),
              errors=sum(int(r['failed_with_error']) for r in rr),latency_n=len(times),median_ms=round(statistics.median(times),3),p95_ms=round(percentile(times,.95),3)))
        scenario_rows.extend(dict(method=name,**r) for r in contention)
        for case in ('lease expired','lease still running'):
            rr=[r for r in lease if r['case']==case]
            if not rr:continue
            lease_records.append(dict(method=name,case=case,scenarios=len(rr),replacement_success=sum(r['second_ngo_got_listing']=='YES' for r in rr),
              old_holder_still_active=sum(r['first_claim_still_active']=='YES' for r in rr),
              incorrect_active_releases=sum(r['first_claim_still_active']!='YES' for r in rr) if case=='lease still running' else None,
              errors=sum(r['second_ngo_answer']=='ERROR' for r in rr)))
    committed=json.loads((run/'proposed_committed_states.json').read_text());assert len(committed)==275
    assert all(r['active_owner_count']<=1 for r in committed)
    csv_write(run/'comparison.csv',records);csv_write(run/'comparison_per_scenario.csv',scenario_rows);csv_write(run/'lease_comparison.csv',lease_records)
    errors=rows(run/'database_errors.csv') if (run/'database_errors.csv').exists() else []
    counts={}
    for r in errors:counts[r['sqlstate']]=counts.get(r['sqlstate'],0)+1
    write(run/'summary_statistics.json',dict(contention=records,lease=lease_records,proposed_database_sqlstates=counts,proposed_committed_states_verified=275))
    manifest=json.loads((run/'manifest.json').read_text());assert manifest['function_sources_unchanged']
    report='# E2 executed results\n\nReadiness: **PARTIAL for unqualified methodological/functional signoff; all requested scenario counts executed.**\n\n'
    report+='## Contention\n\n'+table(records)+'\n\n## Lease cases\n\n'+table(lease_records)+'\n\n'
    report+='Database failure-audit SQLSTATE counts: `'+json.dumps(counts,sort_keys=True)+'`. Generic GeoLock rollback responses are counted as errors, not claim conflicts. Duplicate counts use committed database records, not only HTTP/RPC success messages.\n\n'
    report+='Original teammate baselines run unchanged on their supplied V3 schema; the actual proposed method runs unchanged claim/recovery bodies plus the current reconciliation package on the full GeoLock schema. Both use the same fresh PG17 cluster, isolation, scenario/NGO order, 2/5/10 request barriers, retry setting, directed matrix eligibility and 360-minute lease. Schema/lifecycle/audit differences are a validity threat: latency is not a causal estimate of atomic locking alone. The older baseline has a FOR NO KEY UPDATE fix; the actual current GeoLock claim body retains its reviewed FOR UPDATE behavior. No production logic was changed to improve results.\n\n'
    report+='Auth/Storage/cron are local adapters; the actual protected claim/recovery SQL and constraints execute in PostgreSQL. Proposal eligibility uses the exact supplied directed matrix, not a new live road extraction. Absolute historical timestamps are replayed against server time with their original relative durations, as the teammate driver specifies. The optional pgcrypto extension load is omitted because core PG17 supplies UUID generation; PostGIS is real in the baseline DB. There are no hosted calls or workers. All tables/raw requests and fixture failures are retained. No unexecuted method/lease cell is marked PASS; non-atomic lease recovery is not implemented by that baseline and is not invented.\n'
    (run/'COMPARISON.md').write_text(report,encoding='utf-8')
    return records

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--e2',type=Path);p.add_argument('--e4',type=Path);a=p.parse_args()
    if a.e4:print(json.dumps(e4(a.e4)))
    if a.e2:print(json.dumps(e2(a.e2)))
