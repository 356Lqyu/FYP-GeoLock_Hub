"""Read existing runs; write comparison only inside the NEW corrected run."""
import argparse
import csv
import json
from pathlib import Path
import statistics
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[2]))
from experiments.repro_benchmark import ROOT,rows,csv_write,write,sha
from experiments.summarize_repro_benchmarks import percentile,table

def summarize(run):
    old=ROOT/'experiments/e2_atomic_claiming/results/e2-20261105-v33-actual-01'
    run=Path(run).resolve()
    assert run.parent==old.parent and run!=old
    result=rows(run/'proposed_results_per_scenario.csv')
    previous=rows(old/'proposed_results_per_scenario.csv')
    assert {r['scenario_id'] for r in result}=={r['scenario_id'] for r in previous} and len(result)==275
    requests=json.loads((run/'proposed_requests.json').read_text())
    stats=json.loads((old/'summary_statistics.json').read_text())
    comparison=[dict(r,method='original_proposed' if r['method']=='proposed' else r['method'],evidence_run=old.name) for r in stats['contention']]
    for workers in (2,5,10):
        rr=[r for r in result if r['scenario_id'].startswith('SCN-CLAIM_COORDINATION-') and int(r['ngos_competing'])==workers]
        assert len(rr)==50
        ids={r['scenario_id'] for r in rr};rq=[r for r in requests if r['scenario_id'] in ids]
        times=[float(r['latency_ms']) for r in rq]
        comparison.append(dict(method='corrected_proposed',workers=workers,trials=len(rr),requests=len(rq),
          duplicate_trials=sum(r['more_than_one_owner']=='YES' for r in rr),extra_committed_claims=sum(max(0,int(r['claims_stored'])-1) for r in rr),
          exactly_one_committed_claim=sum(int(r['claims_stored'])==1 for r in rr),exactly_one_success_response=sum(int(r['told_success'])==1 for r in rr),
          successes=sum(int(r['told_success']) for r in rr),conflicts=sum(int(r['told_already_claimed']) for r in rr),ineligible=sum(int(r['told_not_eligible']) for r in rr),
          errors=sum(int(r['failed_with_error']) for r in rr),latency_n=len(times),median_ms=round(statistics.median(times),3),p95_ms=round(percentile(times,.95),3),evidence_run=run.name))
    lease=[dict(r,method='original_proposed' if r['method']=='proposed' else r['method'],evidence_run=old.name) for r in stats['lease']]
    for case in ('lease expired','lease still running'):
        rr=[r for r in result if r.get('case')==case]
        lease.append(dict(method='corrected_proposed',case=case,scenarios=len(rr),replacement_success=sum(r['second_ngo_got_listing']=='YES' for r in rr),
          old_holder_still_active=sum(r['first_claim_still_active']=='YES' for r in rr),incorrect_active_releases=sum(r['first_claim_still_active']!='YES' for r in rr) if case=='lease still running' else None,
          errors=sum(r['second_ngo_answer']=='ERROR' for r in rr),evidence_run=run.name))
    state=json.loads((run/'proposed_committed_states.json').read_text());assert len(state)==275
    regress=json.loads((run/'regressions.json').read_text())
    completed=json.loads((run/'completion.json').read_text());stopped=json.loads((run/'cluster-stop.json').read_text())
    fixed=[r for r in comparison if r['method']=='corrected_proposed']
    leases=[r for r in lease if r['method']=='corrected_proposed']
    passed=completed['executed'] and completed['failures']==0 and stopped['stopped'] and regress.get('passed') is True and all(r['active_owner_count']==1 for r in state)
    passed=passed and all(r['duplicate_trials']==0 and r['errors']==0 and r['successes']==50 and r['conflicts']==r['requests']-50 for r in fixed)
    passed=passed and leases[0]['replacement_success']==100 and leases[0]['errors']==0 and leases[1]['incorrect_active_releases']==0 and leases[1]['errors']==0
    csv_write(run/'comparison.csv',comparison);csv_write(run/'lease_comparison.csv',lease)
    errorfile=run/'database_errors.csv'
    if not errorfile.exists():
        errorfile.write_text('request_id,reason_code,sqlstate,rollback_confirmed\n')
    sqlstates={}
    for r in rows(errorfile):sqlstates[r['sqlstate']]=sqlstates.get(r['sqlstate'],0)+1
    passed=passed and not sqlstates
    summary=dict(readiness='PASS_LOCAL_E2_CORRECTNESS_AND_ROBUSTNESS' if passed else 'PARTIAL',
      formal_methodology_caveats='Historical baselines use older schema; one local run; Auth/Storage/roads are adapters; no DEV or end-to-end phone performance claim',
      contention=comparison,lease=lease,corrected_benchmark_sqlstates=sqlstates,regression_checks=len(regress['checks']),
      original_run=old.name,corrected_run=run.name,analysis_source_sha256=sha(__file__))
    write(run/'corrected_summary.json',summary)
    report='# E2 corrected proposed-method comparison\n\n'+summary['readiness']+'\n\n'
    report+='Original proposed and baseline measurements are reused unchanged from `'+old.name+'`; only corrected proposed was rerun.\n\n'
    report+=table(comparison)+'\n\n## Lease cases\n\n'+table(lease)+'\n\n'
    report+='Benchmark database errors: '+json.dumps(sqlstates)+'. Expected authorization/fault/drift negative controls are in regressions.json, outside benchmark scenario counts.\n\n'
    report+=summary['formal_methodology_caveats']+'. No automatic product or driver retries were added. No E4 change or rerun.\n'
    (run/'COMPARISON.md').write_text(report,encoding='utf-8')
    print(json.dumps(dict(readiness=summary['readiness'],corrected=fixed,regressions=len(regress['checks']))))

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--run',type=Path,required=True)
    summarize(p.parse_args().run)
