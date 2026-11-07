"""Portable local launcher: paths only, no alternate dataset or remote DSN."""
import argparse,json,re,sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from experiments import repro_benchmark as shared

def main():
    if not __debug__:raise SystemExit('Do not run benchmark guards with Python -O/PYTHONOPTIMIZE.')
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--experiment',choices=('E2','E4'),required=True)
    p.add_argument('--run-id',required=True)
    p.add_argument('--teammate-root',type=Path,default=shared.ROOT.parent/'FYP-GeoLock_Hub-ss (1)/FYP-GeoLock_Hub-ss')
    p.add_argument('--pg-bin',type=Path,default=shared.ROOT/'.tmp/geolock-spatial-runtime-safe-cancel/pgsql/bin')
    p.add_argument('--scenario',help='One scenario ID, or comma-separated E2 lease smoke IDs; this is not a full benchmark.')
    p.add_argument('--check-only',action='store_true')
    a=p.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,79}',a.run_id):p.error('Use a simple, unique run-id.')
    shared.TEAM=a.teammate_root.resolve()
    if a.check_only:
        print(json.dumps(dict(status='INPUT_CHECK_ONLY_NOT_EXPERIMENT_RESULTS',integrity=shared.integrity(),environment=shared.environment(),solvers_run=0,databases_started=0),indent=2));return
    if a.experiment=='E2':
        from experiments.e2_atomic_claiming import run as runner
        runner.BIN=a.pg_bin.resolve();parent='e2_atomic_claiming'
    else:
        from experiments.e4_post_claim_routing import run as runner
        parent='e4_post_claim_routing'
    output=shared.ROOT/'experiments'/parent/'results'/a.run_id
    if output.exists():raise SystemExit('Output already exists: choose a new run-id. Nothing is overwritten.')
    runner.run(output,a.scenario)
    print('Output:',output)

if __name__=='__main__':main()
