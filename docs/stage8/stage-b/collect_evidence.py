"""Collect local Stage B evidence only; never connects or executes SQL."""
import hashlib
import json
from pathlib import Path
import platform
import sys

ROOT=Path(__file__).resolve().parents[3]
HERE=Path(__file__).resolve().parent
RESULTS=ROOT/'results/stage-b'
FILES={
 'backend/routing/phase_b/__init__.py':'Export RoutingModel as the primary proposed method; preserve baseline dispatch.',
 'backend/routing/phase_b/routing_model.py':'Actual RoutingModel implementation with unchanged authority and wire contracts.',
 'backend/routing/phase_b/benchmark.py':'Record accurate solver engine per method; keep replay guard.',
 'backend/routing/phase_b/README.md':'Document engine change and unresolved repeatability.',
 'backend/routing/phase_b/tests/test_algorithms.py':'Separate historical CP-SAT proof/repeat guarantees and explicit short unit profiles.',
 'backend/routing/phase_b/tests/test_routing_model.py':'Native RoutingModel/independent validator tests.',
 'backend/routing/worker_service/tests/test_solver_invocation.py':'Assert real RoutingModel invocation and returned candidate wire shape.',
 'backend/routing/worker_service/README.md':'Document local engine verification and transport limits.',
 'supabase/tests/stage8_stage_b_isolated_test.py':'Opt-in disposable full-business-schema PostgreSQL test harness.',
 'supabase/tests/stage8_stage_a_offline_test.py':'Regression for pre/post-publication assignment guards.',
 'docs/stage8/stage-a/build_package.py':'Fix source guard dependency ordering without adopting observed hashes.',
 'docs/stage8/stage-a/forward-migrations/20261101_routing_authority.sql':'Regenerated reviewed forward guard.',
 'docs/stage8/stage-a/forward-migrations/20261103_routing_pickup_and_reconciliation.sql':'Guard expected post-publication assignment definition.',
 'docs/stage8/stage-a/package-manifest.json':'Regenerated current forward-source hashes.',
 'docs/stage8/stage-a/postdeployment_catalog.sql':'Regenerated expected current forward-package catalog inspection.',
 'docs/stage8/stage-a/README.md':'Link current verification while retaining historical Stage A evidence.',
 'docs/stage8/stage-b/run_offline.py':'Run existing offline suite without overwriting Stage A evidence.',
 'docs/stage8/stage-b/collect_evidence.py':'Collect explicit source and result manifests without SQL/network.',
 'docs/stage8/stage-b/REPORT.md':'Detailed limited-scope verification report and blockers.',
 'docs/stage8/stage-b/CHAPTER5_READINESS.md':'Update all eight experiment tracks without running experiments.'}

def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def save(path,value):path.write_text(json.dumps(value,indent=2)+'\n',encoding='utf-8')
def log(name):
    data=(RESULTS/name).read_bytes()
    return data.decode('utf-16' if data.startswith((b'\xff\xfe',b'\xfe\xff')) else 'utf-8-sig')

def main():
    db=json.loads((RESULTS/'attempt-07/results.json').read_text())
    offline=json.loads((RESULTS/'offline-results.json').read_text())
    assert db['tests']==31 and not any(db[k] for k in ('errors','failures','skipped'))
    assert offline['totals']==dict(tests=193,failures=0,errors=0,skipped=0)
    routing=log('python-routing-tests-reviewed.log')
    flutter=log('flutter-tests.log')
    analysis=log('flutter-analyze.log')
    assert 'Ran 81 tests' in routing and routing.rstrip().endswith('OK')
    assert '+67: All tests passed!' in flutter
    assert 'No issues found!' in analysis
    save(HERE/'changed-files.json',dict(scope='Stage B only; unrelated preexisting worktree changes excluded',
        files=[dict(path=p,sha256=sha(ROOT/p),reason=reason) for p,reason in FILES.items()],
        generated_evidence_directory='results/stage-b',generated_manifests=['docs/stage8/stage-b/changed-files.json','results/stage-b/verification.json','results/stage-b/evidence-files.json']))
    save(RESULTS/'verification.json',dict(status='PARTIAL',platform=platform.platform(),python=sys.version,
        environment=json.loads((RESULTS/'attempt-07/environment.json').read_text()),
        ortools='9.15.6755',flutter='3.44.9',dart='3.12.2',postgis='UNAVAILABLE',pgrouting='UNAVAILABLE',
        final_suites=[dict(name=n,passed=p,failed=0,skipped=0) for n,p in [('offline',193),('routing_worker',81),('real_postgresql',31),('flutter',67)]],
        final_total=372,flutter_analyzer='PASS_NO_ISSUES',
        scope='Real PostgreSQL full business-schema; explicit external doubles; Flutter mocked transports',
        historical_attempts_retained=True,earlier_attempts_in_final_total=False,
        formal_experiments_executed=False,supabase_connections=0,
        commands=[
          '.venv-stage8/Scripts/python.exe -B docs/stage8/stage-b/run_offline.py',
          '.venv-stage8/Scripts/python.exe -B -m unittest backend.routing.phase_b.tests.test_algorithms backend.routing.phase_b.tests.test_validation backend.routing.phase_b.tests.test_routing_model backend.routing.worker_service.tests.test_solver_invocation -v',
          '.venv-stage8/Scripts/python.exe -B supabase/tests/stage8_stage_b_isolated_test.py --run-isolated --output-dir results/stage-b/attempt-07',
          'C:/flutter/src/flutter/bin/cache/dart-sdk/bin/dart.exe C:/flutter/src/flutter/bin/cache/flutter_tools.snapshot --no-version-check --suppress-analytics analyze --no-pub',
          'C:/flutter/src/flutter/bin/cache/dart-sdk/bin/dart.exe C:/flutter/src/flutter/bin/cache/flutter_tools.snapshot --no-version-check --suppress-analytics test --no-pub --reporter expanded test/ngo_routing_test.dart test/routing_worker_client_test.dart test/claim_request_test.dart test/claim_card_test.dart test/donation_status_test.dart test/road_routing_test.dart'],
        blockers=['Real PostGIS/pgRouting and real Auth/Storage/PostgREST gateway unavailable',
          'Actual Flutter-to-local-backend acceptance unexecuted',
          'RoutingModel short-budget replay variability; formal profile/repeat policy not frozen',
          'Whole-batch/legacy cutover, recovery/pickup race and remaining SQL negatives incomplete']))
    save(RESULTS/'evidence-files.json',[dict(path=p.relative_to(ROOT).as_posix(),sha256=sha(p))
        for p in sorted(RESULTS.rglob('*')) if p.is_file() and p.name!='evidence-files.json'])
    print('Verified 372 final passing tests; Stage B PARTIAL; evidence indexed.')

if __name__=='__main__':main()
