"""Offline Stage 8 review runner; optional NEW loopback clusters, never DEV."""
from pathlib import Path
from datetime import datetime, timezone
import argparse
import json
import subprocess
import sys

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[2]


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--include-isolated',action='store_true')
    parser.add_argument('--skip-c1-isolated',action='store_true',help='Use already recorded unchanged C1 regression evidence')
    args=parser.parse_args()
    commands=[('offline_regressions',[sys.executable,str(ROOT/'docs/stage8/phase-c1/authenticated-verification/run_batch_a.py'),
                '--output',str(HERE/'offline-regression-results.json')])]
    if args.include_isolated:
        if not args.skip_c1_isolated:
            commands.append(('c1_existing_44',[sys.executable,str(ROOT/'supabase/tests/stage8_c1_fleet_v2_isolated_test.py'),'--run-isolated']))
        commands.append(('integration_20',[sys.executable,str(ROOT/'supabase/tests/stage8_integration_isolated_test.py'),'--run-isolated']))
    results=[]
    for name,command in commands:
        result=subprocess.run(command,cwd=ROOT,capture_output=True,text=True,timeout=300)
        results.append(dict(name=name,exit_code=result.returncode,output=result.stdout+result.stderr))
        print(name+': '+('PASS' if result.returncode==0 else 'FAIL'),flush=True)
        if result.returncode: break
    (HERE/'local-review-results.json').write_text(json.dumps(dict(recorded_at=datetime.now(timezone.utc).isoformat(),
        scope='OFFLINE_AND_DISPOSABLE_LOCAL_POSTGRESQL_ONLY',dev_writes=0,live_authenticated_tests=0,
        tested_migrations=json.loads((HERE/'package-manifest.json').read_text())['files'],results=results),indent=2)+'\n')
    raise SystemExit(any(r['exit_code'] for r in results))


if __name__=='__main__': main()
