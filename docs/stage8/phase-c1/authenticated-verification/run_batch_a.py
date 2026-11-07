"""Reproduce safe offline checks over an operator's SELECT-only MCP capture.

This runner cannot connect to Supabase, acquire sessions or execute Batch B.
Refresh batch-a-live-catalog.json via the unchanged postflight SQL before use.
"""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import subprocess
import sys

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[3]


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--include-isolated',action='store_true',help='New disposable loopback PostgreSQL only; requires local binaries')
    parser.add_argument('--output',type=Path,default=HERE/'batch-a-offline-runs.json')
    args=parser.parse_args()
    commands=[
        ('routing_regressions_and_local_c2',[sys.executable,'-m','unittest','discover','-s','backend/routing','-t','.','-p','test*.py','-q']),
        ('package_12',[sys.executable,'docs/stage8/phase-c1/deployment/test_verification_package.py','-q']),
        ('harness_23',[sys.executable,str(HERE/'test_harness.py'),'-q']),
        ('fixture_recovery_32',[sys.executable,str(HERE/'test_fixture_state.py'),'-q']),
        ('saved_synthetic_reports',[sys.executable,'-m','docs.stage8.review.phase_b_final_review'])]
    if args.include_isolated:
        commands.append(('isolated_44',[sys.executable,'supabase/tests/stage8_c1_fleet_v2_isolated_test.py','--run-isolated']))
    results=[]
    for name,command in commands:
        result=subprocess.run(command,cwd=ROOT,capture_output=True,text=True,timeout=300)
        results.append(dict(name=name,exit_code=result.returncode,output=result.stdout+result.stderr))
        if result.returncode:
            break
    path=args.output
    path.parent.mkdir(parents=True,exist_ok=True)
    path.write_text(json.dumps(dict(observed_at=datetime.now(timezone.utc).isoformat(),
        evidence_kind='OFFLINE_AND_CAPTURED_CATALOG_CHECKS',results=results),indent=2)+'\n',encoding='utf-8')
    print(json.dumps({item['name']:'PASS' if item['exit_code']==0 else 'FAIL' for item in results},indent=2))
    raise SystemExit(any(item['exit_code'] for item in results))


if __name__=='__main__': main()
