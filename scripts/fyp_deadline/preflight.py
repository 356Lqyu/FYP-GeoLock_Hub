"""Usage: python -B -m scripts.fyp_deadline.preflight --output NEW_DIRECTORY."""
import argparse
from pathlib import Path
from experiments.fyp_deadline.preflight import repository_preflight
from experiments.fyp_deadline.evidence import EvidenceWriter,manifest,verify_run

ROOT=Path(__file__).resolve().parents[2]

def main():
    p=argparse.ArgumentParser();p.add_argument('--output',required=True,type=Path);a=p.parse_args()
    output=a.output.resolve()
    if not output.is_relative_to((ROOT/'results/accelerated-batch1').resolve()):p.error('Deadline-owned results directory required')
    inputs,checks=repository_preflight(ROOT)
    writer=EvidenceWriter(output,manifest(inputs,{'mode':'READ_ONLY_PREFLIGHT','ranking_evaluation':'SYNTHETIC_TESTS_ONLY','training':False,'solver_execution':False,'database_access':False}))
    for row in checks:writer.check(row['name'],row['status'],row['details'])
    seal=writer.seal();verify_run(output)
    print('Integrity/preparation outcome:',seal['status'],seal['counts'])
    print('Formal experiments: NOT RUN. C.5/smoke/database/worker execution: NOT RUN.')
    return 1 if seal['counts']['FAIL'] else 2 if seal['counts']['BLOCKED'] else 0

if __name__=='__main__':raise SystemExit(main())
