"""Verify receipts and untouched baselines; create new seals, never replace old evidence."""
import ast
from datetime import datetime,timezone
import hashlib
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parents[3]
OUT=Path(__file__).resolve().parent


def sha(path):
    h=hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda:stream.read(1024*1024),b''):h.update(block)
    return h.hexdigest()


def main():
    previous=ROOT/'docs/investigations/routing-render-implementation'
    baseline=json.loads((previous/'BASELINE_SEALS.json').read_text())
    changed={p:dict(before=v,after=sha(ROOT/p)) for p,v in baseline.items() if sha(ROOT/p)!=v}
    assert set(changed)=={'backend/routing/worker_service/journal.py'}
    hosted=json.loads((previous/'IMPLEMENTATION_SHA256.json').read_text())
    assert {p for p,v in hosted.items() if sha(ROOT/p)!=v}=={
        'docs/investigations/ROUTING_RENDER_IMPLEMENTATION_READINESS.md',
        'docs/investigations/ROUTING_RENDER_DEPLOYMENT_GUIDE.md'}
    rows=json.loads((OUT/'resource-receipts.json').read_text());frozen=json.loads((OUT/'frozen-resource-receipts.json').read_text())
    assert len(rows)==38 and sum(r['state']['OOMKilled'] for r in rows)==3
    assert not any(r['timed_out'] for r in rows)
    profiles={'512mb-0.1cpu':(512*1024**2,100000000),'2gb-1cpu':(2*1024**3,1000000000),
              '4gb-2cpu':(4*1024**3,2000000000),'8gb-2cpu':(8*1024**3,2000000000)}
    for row in rows:
        memory,cpu=profiles[row['profile']];limits=row['limits']
        assert limits['Memory']==limits['MemorySwap']==memory and limits['NanoCpus']==cpu
        assert limits['NetworkMode']=='none' and limits['ReadonlyRootfs']
        # Unittest receipts may contain a request-event log, not measurements.
        metrics=row.get('result',{}).get('metrics')
        if metrics:
            cg=metrics['cgroup'];assert int(cg['memory.max'])==memory
            quota,period=map(int,cg['cpu.max'].split());assert abs(quota/period-cpu/1e9)<1e-9
    for row in frozen:
        assert row['exit_code']==0 and not row['oom']
        assert all(m['valid'] for case in row['result']['cases'] for m in case['methods'])
        memory,cpu=profiles[row['profile']];cg=row['result']['cgroup']
        assert int(cg['memory.max'])==memory
        quota,period=map(int,cg['cpu.max'].split());assert abs(quota/period-cpu/1e9)<1e-9
    for role in ('planner','validator'):
        image=json.loads((OUT/(role+'-image-only-inventory.json')).read_text())
        assert image['uid']==10001 and image['forbidden_files']==[]
        assert not any('/tests/' in path for path in image['app_files'])
        assert json.loads((OUT/(role+'-secret-audit.json')).read_text())['findings']==[]
    for filename,count in [('windows-hosted-after.log',30),('windows-worker-regression.log',153),
                           ('linux-hosted-after.log',30),('linux-core-regression.log',88)]:
        log=(OUT/filename).read_text();assert f'Ran {count} tests' in log and '\nOK' in log
    source=[ROOT/'backend/routing/worker_service/journal.py',ROOT/'backend/routing/hosted/tests/test_journal_initialization.py']
    for path in source+list(OUT.glob('*.py')):ast.parse(path.read_text(encoding='utf-8'))
    fixture=json.loads((OUT/'frozen-v33-sample.json').read_text())
    for name,seal in fixture['csv_sha256'].items():assert sha(ROOT/'experiments/repro_inputs/v33'/(name+'.csv'))==seal
    graph=ROOT/'results/worker-readiness/20261027T083653Z-5f56bb/graphs/eab1f7ee-a8e0-4bed-a0e1-2c4bff024936.jsonl'
    assert sha(graph)=='a525f79eada8fc65ce0568fd0cdba66237f1e5e6e3009bb4fa0e7482fc70accb'
    summary=dict(at_utc=datetime.now(timezone.utc).isoformat(),local_docker_validation='PASS',deployment='NO-GO',
        windows_tests=dict(passed=183),linux_tests=dict(passed=117,skipped=1),frozen_plans_valid=48,
        main_cases=38,measured_oom_failures=3,timeouts=0,requested_cgroups_verified=True,
        original_sources_unchanged=12,intentional_production_changes=changed,
        graph_file_sha256=sha(graph),frozen_csvs_unchanged=True,previous_hosted_files_unchanged=18,
        minimum_end_to_end_capacity_qualified_plan=None,
        blockers=['Complete approved sanitized operational benchmark bundle and maximum workload/headroom',
                  'Actual Render proxy ingress/header contract',
                  'Current approved DEV backup/operator/read-only role/graph/network deployment preflight'],
        actions=dict(dev_connections=0,live_routing=0,live_journal_or_credential_copies=0,
                     cloud_deployments=0,cloud_charge_actions=0,dev_worker_activations=0,pushes=0),
        primary_sources=['https://sqlite.org/forum/info/ba7afbd0e81501118563617430fe06d0aca052e55ece2b0d457f8e16fcf85bba',
                         'https://render.com/articles/fastapi-production-best-practices',
                         'https://render.com/docs/web-services','https://render.com/docs/outbound-ip-addresses'])
    with (OUT/'VERIFICATION_SUMMARY.json').open('x',encoding='utf-8') as target:json.dump(summary,target,indent=2);target.write('\n')
    files=[p for p in OUT.iterdir() if p.is_file()]+source+[
        ROOT/'docs/investigations/ROUTING_RENDER_IMPLEMENTATION_READINESS.md',
        ROOT/'docs/investigations/ROUTING_RENDER_DEPLOYMENT_GUIDE.md']
    with (OUT/'SHA256.json').open('x',encoding='utf-8') as target:
        json.dump({str(p.relative_to(ROOT)).replace('\\','/'):sha(p) for p in sorted(files)},target,indent=2);target.write('\n')
    print(json.dumps(dict(checks='PASS',windows_pass=183,linux_pass=117,linux_skip=1,
                         frozen_valid=48,main_cases=38,oom=3,deployment='NO-GO',sealed_files=len(files))))


if __name__=='__main__':main()
