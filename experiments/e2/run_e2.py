"""Run E2 against a dedicated, explicitly verified database."""
import argparse
from collections import Counter
from contextlib import contextmanager
import errno
import json
import os
from pathlib import Path
import sys
import uuid

E2 = Path(__file__).resolve().parent
ROOT = E2.parents[1]
sys.path.insert(0, str(E2 / 'test_harness'))
import e2_harness as harness  # noqa: E402
import e2_hosted as hosted  # noqa: E402
import e2_results as results  # noqa: E402

sys.path.insert(0, str(E2 / 'experiment_result' / 'source_code'))
import e2_compare as compare  # noqa: E402

METHODS = {
    'baseline1': 'non_atomic_claim',
    'baseline2': 'protected_claim_without_lease_recovery',
    'proposed': 'protected_claim_with_lease_recovery',
}


@contextmanager
def cluster_run_lock(path, label='local cluster'):
    """Keep one Windows runner active per local cluster or results directory."""
    import msvcrt

    if harness._is_reparse_point(path):
        raise SystemExit(f'E2 run lock path is a reparse point: {path}')
    with path.open('a+b') as lock:
        lock.seek(0)
        try:
            msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
        except OSError as exc:
            if exc.errno in (errno.EACCES, errno.EAGAIN):
                raise SystemExit(f'Another E2 run holds the {label} lock. Wait for it to finish.') from None
            raise
        yield


def preflight(dsn, target):
    """Read-only identity and reset-inventory check."""
    with harness.connect(dsn) as conn:
        with conn.transaction():
            conn.execute('set transaction read only')
            identity = harness.validate_database_identity(conn, target=target)
            inventory = harness.inspect_reset_inventory(conn)
            if isinstance(target, hosted.HostedTarget):
                hosted.check_compatibility(conn)
                accounts = harness.fixture_accounts()
                users = conn.execute('select id::text, email from auth.users').fetchall()
                if any(account not in accounts or accounts[account] != email for account, email in users):
                    raise SystemExit('Hosted E2 refuses unexpected Auth users.')
        if isinstance(target, hosted.HostedTarget):
            hosted.check_session_contract(conn)
        return identity, inventory


@contextmanager
def hosted_run_lock(target):
    """Hold the database lock on the same session used for every reset."""
    with harness.connect(target) as conn:
        hosted.verify_identity(conn, target)
        if not conn.execute('select pg_try_advisory_lock(%s, %s)', hosted.RUN_LOCK).fetchone()[0]:
            raise SystemExit('Another E2 run holds the hosted project lock.')
        yield conn


def validate_standalone(out, method, root_manifest):
    """Check standalone evidence without assembling a three-method comparison."""
    saved = json.loads((out / 'run_manifest.json').read_text(encoding='utf-8'))
    expected = {'method': method, 'experiment_run_id': root_manifest['experiment_run_id'],
                'target_identity': root_manifest['target_identity'],
                'input_sha256': root_manifest['benchmark_input_sha256'],
                'source_sha256': root_manifest['source_sha256']}
    if any(saved.get(key) != value for key, value in expected.items()):
        raise SystemExit('Standalone method provenance differs from its run manifest.')
    compare.validate_run_provenance(root_manifest, ROOT, harness.DATA)
    trials = compare.scenario_map(out / 'results_per_scenario.csv', method)
    requests = compare.read(out / 'details' / 'requests.csv')
    contention = compare.validate_contention_requests(method, trials, requests)
    levels = Counter(int(row['ngos_competing']) for row in trials.values())
    if levels != {level: harness.TRIALS_PER_LEVEL for level in harness.WORKER_LEVELS} or len(contention) != 850:
        raise SystemExit('Standalone method has incomplete contention coverage.')
    if method != METHODS['baseline1']:
        leases = compare.read(out / 'lease_results_per_scenario.csv')
        if (len({row['scenario_id'] for row in leases}) != 125 or
                Counter(row['case'] for row in leases) != {'lease expired': 100, 'lease still running': 25}):
            raise SystemExit('Standalone method has incomplete lease coverage.')
    if method == METHODS['proposed']:
        pairs = compare.read(out / 'geofence_check' / 'details' / 'eligibility_pairs.csv')
        delayed = compare.read(out / 'details' / 'delayed_request_check.csv')
        if len(pairs) != 1100 or len({row['scenario_id'] for row in delayed}) != 50:
            raise SystemExit('Standalone proposed method has incomplete geofence or delayed-request evidence.')
        json.loads((out / 'geofence_check' / 'details' / 'claims_stored_after_check.json').read_text(encoding='utf-8'))
        json.loads((out / 'details' / 'concurrent_recovery_check.json').read_text(encoding='utf-8'))


def execute_run(args, dsn, target, *, reset_conn=None):
    """Execute preflight and the selected methods against the verified cluster."""
    # Connection is used only for SELECTs here. Each method repeats identity and
    # object-inventory checks immediately before its reset.
    identity, inventory = preflight(dsn, target)
    input_hashes = harness.check_inputs(harness.TABLES)
    print('Verified E2 target:', json.dumps(identity, sort_keys=True), flush=True)
    print('Reset inventory:', json.dumps(inventory, sort_keys=True), flush=True)
    if args.preflight_only:
        print('Read-only preflight passed; no result directory or database changes were made.')
        return 0

    publication = results.Publication(harness.RESULTS_ROOT, full=args.method == 'all')
    root = publication.active.parent
    root.mkdir(parents=True, exist_ok=True)
    with cluster_run_lock(root / '.publication.lock', 'results'):
        publication.recover()
        generate_results(args, dsn, target, identity, inventory, input_hashes, publication.pending,
                         reset_conn=reset_conn)
        publication.publish()
    print(f'E2 complete: {publication.active} (run ID: {args.run_id})')
    return 0


def generate_results(args, dsn, target, identity, inventory, input_hashes, out, *, reset_conn=None):
    """Write and validate one complete run in the staging directory."""
    out.mkdir(exist_ok=False)
    os.environ['GEOLOCK_E2_RUN_ID'] = args.run_id
    os.environ['GEOLOCK_E2_RUN_DIR'] = str(out.resolve())
    source_files = [E2 / 'run_e2.py', E2 / 'run.ps1', E2 / 'scripts' / 'setup_local_e2.ps1', E2 / 'requirements.txt',
                    E2 / 'scripts' / 'recover_local_e2.ps1',
                    E2 / 'test_harness' / 'e2_postgres_client.ps1',
                    E2 / 'test_harness' / 'e2_process_safety.ps1',
                    E2 / 'test_harness' / 'e2_harness.py',
                    E2 / 'test_harness' / 'e2_hosted.py',
                    E2 / 'test_harness' / 'e2_results.py',
                    E2 / 'database' / '00_provision_e2_target_marker.sql',
                    E2 / 'database' / '00_local_auth_compat.sql',
                    E2 / 'database' / '01_geolock_v3_schema.sql', E2 / 'database' / '02_app_claim_layer.sql',
                    E2 / 'database' / '03_non_atomic_baseline.sql', E2 / 'database' / '04_reset_e2_objects.sql',
                    E2 / 'baseline' / 'source_code' / 'run_non_atomic_claim.py',
                    E2 / 'baseline' / 'source_code' / 'run_protected_claim_without_lease_recovery.py',
                    E2 / 'protected_claim_with_lease_recovery' / 'source_code' / 'run_protected_claim_with_lease_recovery.py',
                    E2 / 'experiment_result' / 'source_code' / 'e2_compare.py']
    selected = list(METHODS.values()) if args.method == 'all' else [METHODS[args.method]]
    manifest = {
        'status': 'in_progress', 'experiment': 'E2', 'experiment_run_id': args.run_id,
        'mode': identity.get('mode', 'local'), 'target_identity': identity, 'reset_inventory': inventory,
        'local_isolated_cluster': not isinstance(target, hosted.HostedTarget), 'selected_methods': selected,
        'python_environment': harness.environment(),
        'benchmark_input_sha256': input_hashes,
        'source_sha256': {str(p.relative_to(ROOT)): harness.sha256(p) for p in source_files},
    }
    harness.write_json(out / 'run_manifest.json', manifest)
    try:
        for method in selected:
            method_out = out / 'methods' / method
            harness.run_method(method, method_out, dsn, target, identity, reset_conn=reset_conn)
            if reset_conn is not None:
                hosted.verify_run_lock(reset_conn)
                hosted.verify_identity(reset_conn, target)
        if args.method == 'all':
            compare.main()
        else:
            validate_standalone(method_out, method, manifest)
        manifest['status'] = 'completed'
        harness.write_json(out / 'run_manifest.json', manifest)
        results.seal(out, manifest, full=args.method == 'all')
    except (Exception, KeyboardInterrupt, SystemExit) as exc:
        manifest['status'] = 'failed_or_incomplete'
        manifest['failure_type'] = type(exc).__name__
        harness.write_json(out / 'run_manifest.json', manifest)
        raise


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument('--mode', choices=('local', 'hosted'), default='local')
    parser.add_argument('--register-hosted', nargs=3, metavar=('PROJECT_REF', 'POOLER_HOST', 'CA_FILE'),
                        help='write password-free local enrollment and print dashboard marker SQL')
    parser.add_argument('--confirm-project', help='exact enrolled project reference for a destructive hosted run')
    parser.add_argument('--method', choices=('all', *METHODS), default='all')
    offline = parser.add_mutually_exclusive_group()
    offline.add_argument('--verify-latest', action='store_true', help='verify published result checksums offline')
    offline.add_argument('--recover-results', action='store_true', help='recover interrupted result publication offline')
    parser.add_argument('--preflight-only', action='store_true')
    parser.add_argument('--allow-start', action='store_true',
                        help='allow a local preflight to start the configured E2 cluster')
    args = parser.parse_args(argv)
    if args.verify_latest or args.recover_results:
        if (args.register_hosted or args.confirm_project or args.preflight_only or args.allow_start
                or args.method != 'all' or args.mode != 'local'):
            parser.error('Result verification and recovery are separate offline operations')
        publication = results.Publication(harness.RESULTS_ROOT)
        with cluster_run_lock(publication.active.parent / '.publication.lock', 'results'):
            if args.recover_results:
                publication.recover()
                results.Publication(harness.RESULTS_ROOT, full=False).recover()
                print('E2 result publication recovery complete.')
            else:
                manifest = results.verify(publication.active)
                if manifest['benchmark_input_sha256'] != harness.check_inputs(harness.TABLES):
                    raise SystemExit('Published E2 benchmark hashes differ from the frozen inputs.')
                print(f"Verified latest E2 result and frozen inputs (run ID: {manifest['experiment_run_id']}).")
        return 0
    args.run_id = uuid.uuid4().hex
    if args.register_hosted:
        if args.preflight_only or args.confirm_project or args.allow_start or args.method != 'all':
            parser.error('--register-hosted is a separate offline operation')
        hosted.register(harness.hosted_config_path(), *args.register_hosted)
        return 0
    if args.preflight_only and args.method != 'all':
        parser.error('--preflight-only cannot be combined with an individual method')
    if args.mode == 'hosted' and args.allow_start:
        parser.error('--allow-start is for local mode only')
    if args.mode == 'local' and args.confirm_project:
        parser.error('--confirm-project is for hosted mode only')
    if args.mode == 'hosted' and not args.preflight_only and not args.confirm_project:
        parser.error('a hosted run requires --confirm-project with the enrolled project reference')
    dsn, target = harness.get_target_config(args.mode)
    harness.validate_runtime_dependencies()
    if args.mode == 'hosted':
        if args.preflight_only:
            return execute_run(args, dsn, target)
        if args.confirm_project != target.project:
            parser.error('--confirm-project must match the enrolled project reference')
        with hosted_run_lock(target) as reset_conn:
            return execute_run(args, dsn, target, reset_conn=reset_conn)
    cluster = harness.LocalPostgresCluster(target)
    with cluster_run_lock(harness.default_local_root() / 'run.lock'):
        try:
            cluster.start(allow_start=not args.preflight_only or args.allow_start)
            return execute_run(args, dsn, target)
        finally:
            cluster.stop()


if __name__ == '__main__':
    raise SystemExit(main())
