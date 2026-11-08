"""Portable local launcher: paths only, no alternate dataset or remote DSN."""
import argparse,json,re,sys
from functools import partial
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from experiments import repro_benchmark as shared

def main():
    if not __debug__:raise SystemExit('Do not run benchmark guards with Python -O/PYTHONOPTIMIZE.')
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--experiment',choices=('E2','E4'),required=True)
    p.add_argument('--run-id',required=True)
    p.add_argument('--teammate-root',type=Path,default=None,help='Optional external reference checkout for hash verification; not required to reproduce.')
    p.add_argument('--pg-bin',type=Path,default=None,help='Optional PostgreSQL 17 bin directory; otherwise use GEOLOCK_E2_PG_BIN or the standard Windows install.')
    p.add_argument('--scenario',help='One scenario ID, or comma-separated E2 lease smoke IDs; this is not a full benchmark.')
    p.add_argument('--check-only',action='store_true')
    a=p.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,79}',a.run_id):p.error('Use a simple, unique run-id.')
    teammate_root=a.teammate_root.resolve() if a.teammate_root else None
    if a.check_only:
        print(json.dumps(dict(status='INPUT_CHECK_ONLY_NOT_EXPERIMENT_RESULTS',integrity=shared.integrity(teammate_root),environment=shared.environment(),solvers_run=0,databases_started=0),indent=2));return
    shared.integrity=partial(shared.integrity,teammate_root=teammate_root)
    if a.experiment=='E2':
        from experiments.e2_atomic_claiming import run as runner
        from experiments.e2_claiming.e2_runner import find_pg_bin
        runner.BIN=find_pg_bin(str(a.pg_bin.resolve()) if a.pg_bin else None);parent='e2_atomic_claiming'
    else:
        from experiments.e4_post_claim_routing import run as runner
        parent='e4_post_claim_routing'
    output=shared.ROOT/'experiments'/parent/'results'/a.run_id
    if output.exists():raise SystemExit('Output already exists: choose a new run-id. Nothing is overwritten.')
    runner.run(output,a.scenario)
    print('Output:',output)

if __name__=='__main__':main()
