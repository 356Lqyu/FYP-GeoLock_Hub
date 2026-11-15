"""E2 test harness.

The two baselines and the proposed method all run through this file, so they get the same
donations, NGOs, request schedule and checks. Only the claim and recovery functions differ.

What each condition runs (report Table 3.6):
  baseline 1  150 contention trials, 50 each with 2, 5 and 10 NGOs claiming one listing at once
  baseline 2  same 150 contention trials, plus 100 expired-lease and 25 active-lease cases; no recovery
  proposed    same contention and lease cases with recovery, plus geofence and extra recovery checks
"""
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
from contextlib import nullcontext
import csv
from datetime import datetime, timedelta
import hashlib
from importlib import metadata as package_metadata
import ipaddress
import json
import os
from pathlib import Path
import platform
import re
import socket
import statistics
import subprocess
import sys
import threading
import time
import uuid

import psycopg
import e2_hosted

HERE = Path(__file__).resolve().parent
E2 = HERE.parent
ROOT = E2.parents[1]
DATA = ROOT / 'benchmark dataset' / 'dataset'
SQL = E2 / 'database'
RESULTS_ROOT = E2 / 'experiment_result' / 'results'
BENCHMARK_NAME = 'GEOLOCK-BENCHMARK-DATASET'

E2_DATABASE_NAME = 'geolock_e2'
E2_TARGET_MARKER = 'public.e2_disposable_target'
LOCAL_HOST = '127.0.0.1'
LOCAL_SETUP_APPROVAL = 'created_as_new_e2_owned_cluster'
RESET_SCHEMAS = ('public', 'e2_baseline', 'e2_bench', 'routing_private', 'resolution_private')

RESET_PUBLIC_RELATIONS = frozenset({
    'claim_reconciliation_cases', 'operation_failure_events', 'active_task_route_assignments',
    'pickup_route_stops', 'pickup_routes', 'pickup_tasks', 'vehicles', 'claim_leases',
    'donation_claims', 'claim_requests', 'listings', 'hub_batch_members', 'hub_batches',
    'hub_inventory', 'hub_receipts', 'hub_reservations', 'donation_items', 'donations',
    'hub_accepted_categories', 'community_hubs', 'donation_categories', 'coordination_config',
    'hub_admin_profiles', 'ngo_profiles', 'donor_profiles', 'audit_events', 'user_profiles',
    'e2_disposable_target',
})
RESET_RELATIONS = {
    'public': RESET_PUBLIC_RELATIONS,
    'e2_baseline': frozenset({'naive_claims'}),
    'e2_bench': frozenset({'road_km'}),
    'routing_private': frozenset({'items', 'bindings', 'deferred_release_permits', 'deferred_stops'}),
    'resolution_private': frozenset({'cases'}),
}
RESET_TRIGGERS = frozenset({
    ('public', 'user_profiles', 'trg_role_immutable', 'prevent_role_change', ''),
    ('public', 'donations', 'trg_donation_transition', 'enforce_donation_transition', ''),
    ('public', 'listings', 'trg_listing_transition', 'enforce_listing_transition', ''),
    ('public', 'donation_items', 'trg_items_guard', 'guard_donation_items', ''),
    ('public', 'hub_batches', 'trg_batch_guard', 'guard_batch_immutability', ''),
    ('public', 'hub_batch_members', 'trg_members_guard', 'guard_batch_immutability', ''),
    ('public', 'audit_events', 'trg_audit_append_only', 'prevent_audit_mutation', ''),
})
RESET_FUNCTIONS = {
    'public': frozenset({
        'prevent_role_change', 'enforce_donation_transition', 'enforce_listing_transition',
        'guard_donation_items', 'guard_batch_immutability', 'prevent_audit_mutation',
        'register_role_profile', 'create_and_validate_donation', 'register_community_hub',
        'reserve_hub_capacity', 'confirm_hub_receipt', 'publish_whole_donation_batch',
        'discover_eligible_listings', 'claim_listing', 'start_pickup', 'complete_pickup',
        'recover_expired_claims', 'assign_task_to_route', 'geolock_lock_listing_donations',
        'geolock_transition_listing_donations', 'geolock_ngo_listing_road_check',
    }),
    'e2_baseline': frozenset({'non_atomic_check_listing', 'non_atomic_write_claim'}),
    'e2_bench': frozenset(),
    'routing_private': frozenset({'lock_route_for_recovery', 'release_expired_unstarted_stop', 'coord_release_allowed'}),
    'resolution_private': frozenset({'release_allowed'}),
}
RESET_FUNCTION_SIGNATURES = {
    'public': {
        'prevent_role_change': {''}, 'enforce_donation_transition': {''}, 'enforce_listing_transition': {''},
        'guard_donation_items': {''}, 'guard_batch_immutability': {''}, 'prevent_audit_mutation': {''},
        'register_role_profile': {'text, text, text, text, text, text, double precision, double precision, text'},
        'create_and_validate_donation': {'text, text, text, double precision, double precision, jsonb, text, timestamp with time zone, timestamp with time zone'},
        'register_community_hub': {'text, text, double precision, double precision, numeric, text'},
        'reserve_hub_capacity': {'uuid, uuid'}, 'confirm_hub_receipt': {'uuid, numeric'},
        'publish_whole_donation_batch': {'uuid, uuid[]'}, 'discover_eligible_listings': {''},
        'claim_listing': {'uuid, uuid'}, 'start_pickup': {'uuid'}, 'complete_pickup': {'uuid, boolean'},
        'recover_expired_claims': {'integer'}, 'assign_task_to_route': {'uuid, uuid, integer'},
        'geolock_lock_listing_donations': {'uuid, text[]'},
        'geolock_transition_listing_donations': {'uuid, text, text, uuid, uuid, text', 'uuid, text, text'},
        'geolock_ngo_listing_road_check': {'uuid, uuid'},
    },
    'e2_baseline': {'non_atomic_check_listing': {'uuid'}, 'non_atomic_write_claim': {'uuid, uuid'}},
    'e2_bench': {},
    'routing_private': {'lock_route_for_recovery': {'uuid'},
                        'release_expired_unstarted_stop': {'uuid, uuid, uuid, uuid'},
                        'coord_release_allowed': {'uuid, text'}},
    'resolution_private': {'release_allowed': {'uuid, text'}},
}

ACCOUNT_DOMAIN = 'geolock.example.com'
ACCOUNT_NAMESPACE = uuid.uuid5(uuid.NAMESPACE_URL, 'geolock-baseline/accounts')
TABLES = ('scenarios', 'scenario_members', 'ngos', 'donations', 'donors', 'listings', 'claim_initial_states',
          'road_distance_matrix')

GEOFENCE_KM = 20.0
LEASE_MINUTES = 360
WORKER_LEVELS = (2, 5, 10)
TRIALS_PER_LEVEL = 50
CONNECT_TIMEOUT_S = 15
STATEMENT_TIMEOUT_S = 30
BARRIER_TIMEOUT_S = 60
DELAY_S = 1.0
MAX_RETRIES = 1
TRANSIENT = (psycopg.errors.DeadlockDetected, psycopg.errors.SerializationFailure)

METHODS = {
    'non_atomic_claim': dict(
        title='Non-Atomic Claim (baseline 1)', parts=('CLAIM_COORDINATION',), two_step=True, recovery=False,
        check='select e2_baseline.non_atomic_check_listing(%s)',
        write='select e2_baseline.non_atomic_write_claim(%s, %s)'),
    'protected_claim_without_lease_recovery': dict(
        title='Protected Claim without Lease Recovery (baseline 2)',
        parts=('CLAIM_COORDINATION', 'LEASE_RECOVERY', 'LEASE_ACTIVE_VERIFICATION'), two_step=False, recovery=False,
        call='select public.claim_listing(%s, %s)'),
    'protected_claim_with_lease_recovery': dict(
        title='Protected Claim with Lease Recovery (proposed)', parts=('CLAIM_COORDINATION',) + ('LEASE_RECOVERY', 'LEASE_ACTIVE_VERIFICATION'), two_step=False,
        recovery=True,
        call='select public.claim_listing(%s, %s)'),
}


# Benchmark files and output writing

def sha256(path):
    """SHA-256 hash of a file."""
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def manifest():
    """The benchmark generation manifest."""
    return json.loads((DATA / 'generation_manifest.json').read_text(encoding='utf-8'))


def check_inputs(names):
    """Stop if a benchmark file differs from the SHA-256 in generation_manifest.json."""
    m, out = manifest(), {}
    for name in names:
        h = sha256(DATA / f'{name}.csv')
        if m['generated_csv_sha256'][name] != h:
            raise SystemExit(f'Benchmark file changed: {name}.csv')
        out[f'{name}.csv'] = h
    return out


def rows(name):
    """All rows of one benchmark table."""
    with (DATA / f'{name}.csv').open(encoding='utf-8-sig', newline='') as f:
        return list(csv.DictReader(f))


def write_csv(path, records):
    """Write rows to a CSV file."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    if not records:
        path.write_text('', encoding='utf-8')
        return
    with path.open('w', encoding='utf-8-sig', newline='') as f:
        w = csv.DictWriter(f, fieldnames=list(records[0]), extrasaction='ignore')
        w.writeheader()
        w.writerows(records)


def write_json(path, value):
    """Write a value to a JSON file."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, default=str) + '\n', encoding='utf-8')


def environment():
    """Python version, package versions and run time, for the run record."""
    try:
        matplotlib_version = package_metadata.version('matplotlib')
    except package_metadata.PackageNotFoundError:
        matplotlib_version = None
    return dict(python=sys.version.split()[0], platform=platform.platform(), psycopg=psycopg.__version__,
                matplotlib=matplotlib_version,
                run_at=datetime.now().astimezone().isoformat(timespec='seconds'))


def validate_runtime_dependencies():
    """Fail before any reset if the E2 comparison/figure dependency is missing."""
    try:
        import matplotlib  # noqa: F401
    except ImportError:
        raise SystemExit('E2 comparison requires matplotlib. Install experiments/e2/requirements.txt first.') from None


def run_info(path, title, items):
    """Write run_info.md, a short record of how this result was made."""
    lines = [f'# Run information: {title}', '', '| Item | Value |', '| --- | --- |']
    lines += [f'| {k} | {v} |' for k, v in items]
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_text('\n'.join(lines) + '\n', encoding='utf-8')


# Connection and database setup

def default_local_root():
    """Return the fixed per-user root that setup_local_e2.ps1 owns."""
    base = os.environ.get('LOCALAPPDATA') or str(Path.home() / 'AppData' / 'Local')
    return Path(base) / 'GeoLockHub' / 'E2'


def default_local_config_path():
    """Return the one-time local cluster config location outside the repository."""
    return validate_external_config_path(default_local_root() / 'local.json')


def validate_external_config_path(path):
    """Keep the per-user target approval outside the Git worktree."""
    path = Path(path).expanduser()
    try:
        path.resolve().relative_to(ROOT.resolve())
    except ValueError:
        return path
    raise SystemExit('E2 local config must be stored outside the repository.')


def validate_local_config(config):
    """Validate the one-time E2-owned cluster configuration without connecting."""
    if config.get('version') != 1 or config.get('mode') != 'local':
        raise SystemExit('Local E2 config version or mode is unsupported.')
    if config.get('setup_approval') != LOCAL_SETUP_APPROVAL:
        raise SystemExit('Local E2 config was not produced by the E2 cluster setup workflow.')
    target_id = str(config.get('target_id', '')).replace('-', '').lower()
    if not re.fullmatch(r'[0-9a-f]{32}', target_id):
        raise SystemExit('Local E2 config has an invalid target marker identity.')
    if config.get('host') != LOCAL_HOST or config.get('dbname') != E2_DATABASE_NAME or config.get('user') != 'postgres':
        raise SystemExit('Local E2 config must target the E2-owned loopback database geolock_e2 as postgres.')
    try:
        port = int(config.get('port'))
    except (TypeError, ValueError):
        raise SystemExit('Local E2 config has an invalid PostgreSQL port.') from None
    if not 1024 <= port <= 65535 or port == 5432:
        raise SystemExit('Local E2 requires a dedicated user port other than 5432.')
    cluster_id = str(config.get('cluster_system_identifier', ''))
    if not re.fullmatch(r'\d{10,30}', cluster_id):
        raise SystemExit('Local E2 config has an invalid PostgreSQL cluster system identifier.')
    data_dir = Path(str(config.get('data_dir', ''))).expanduser()
    pg_bin = Path(str(config.get('pg_bin', ''))).expanduser()
    if not data_dir.is_absolute() or not pg_bin.is_absolute() or not data_dir.is_dir():
        raise SystemExit('Local E2 config must name an existing absolute cluster directory and PostgreSQL bin directory.')
    for path in (data_dir, *data_dir.parents, pg_bin):
        if _is_reparse_point(path):
            raise SystemExit('Local E2 config contains a symbolic link or reparse point; refusing to start/reset it.')
    try:
        data_dir.resolve().relative_to(ROOT.resolve())
    except ValueError:
        pass
    else:
        raise SystemExit('Local E2 PostgreSQL data directory must be outside the repository.')
    expected_data_dir = (default_local_root() / 'cluster' / 'data').resolve()
    if data_dir.resolve() != expected_data_dir:
        raise SystemExit('Local E2 config points outside the setup-owned E2 data directory; refusing to start or reset it.')
    required = ('pg_ctl.exe', 'postgres.exe', 'psql.exe', 'pg_controldata.exe')
    for name in required:
        exe = pg_bin / name
        if not exe.is_file() or exe.resolve().parent != pg_bin.resolve():
            raise SystemExit(f'Local E2 PostgreSQL executable is missing from the configured bin directory: {name}')
    dsn = f'host={LOCAL_HOST} port={port} dbname={E2_DATABASE_NAME} user=postgres'
    target = dict(mode='local', host=LOCAL_HOST, port=port, dbname=E2_DATABASE_NAME,
                  user='postgres', target_id=target_id, cluster_system_identifier=cluster_id,
                  data_dir=str(data_dir.resolve()), pg_bin=str(pg_bin.resolve()),
                  setup_approval_configured=True)
    return dsn, target


def _is_reparse_point(path):
    """Detect links and Windows reparse points without following them."""
    path = Path(path)
    try:
        if path.is_symlink() or (hasattr(path, 'is_junction') and path.is_junction()):
            return True
        info = path.lstat()
    except (FileNotFoundError, OSError):
        return False
    attributes = getattr(info, 'st_file_attributes', 0)
    reparse_flag = getattr(__import__('stat'), 'FILE_ATTRIBUTE_REPARSE_POINT', 0x400)
    return bool(attributes & reparse_flag)


class LocalPostgresCluster:
    """Start/stop only the E2-owned cluster named in local config."""
    def __init__(self, target):
        self.target = target
        self.started_here = False

    def start(self, *, allow_start=True):
        pg_ctl = str(Path(self.target['pg_bin']) / 'pg_ctl.exe')
        data_dir = self.target['data_dir']
        try:
            version = subprocess.run([str(Path(self.target['pg_bin']) / 'postgres.exe'), '--version'],
                                     capture_output=True, text=True, check=False, timeout=10)
        except (OSError, subprocess.SubprocessError):
            raise SystemExit('Could not verify the configured local PostgreSQL executable.') from None
        if version.returncode != 0 or not re.search(r'\b17\.', version.stdout + version.stderr):
            raise SystemExit('The configured E2 local cluster must use PostgreSQL 17 binaries.')
        control = subprocess.run([str(Path(self.target['pg_bin']) / 'pg_controldata.exe'), '-D', data_dir],
                                 capture_output=True, text=True, check=False, timeout=10)
        if control.returncode != 0:
            raise SystemExit('Could not inspect the configured E2 cluster control data; refusing to start it.')
        match = re.search(r'Database system identifier:\s*(\d+)', control.stdout + control.stderr)
        if not match or match.group(1) != str(self.target['cluster_system_identifier']):
            raise SystemExit('On-disk PostgreSQL cluster ID differs from E2 config; refusing to start or stop this cluster.')
        status = subprocess.run([pg_ctl, '-D', data_dir, 'status'], capture_output=True,
                                text=True, check=False, timeout=15)
        if status.returncode == 0:
            return
        if status.returncode != 3:
            raise SystemExit(f'Could not determine local E2 cluster status (pg_ctl exit {status.returncode}).')
        if not allow_start:
            raise SystemExit('E2 preflight requires a running cluster or explicit --allow-start.')
        if (Path(data_dir) / 'postmaster.pid').exists():
            raise SystemExit('The configured E2 cluster has a stale or unreadable postmaster.pid; inspect it before retrying.')
        try:
            with socket.create_connection((self.target['host'], self.target['port']), timeout=0.25):
                raise SystemExit('The configured E2 port is occupied by an unverified PostgreSQL process; refusing to start.')
        except OSError:
            pass
        start_options = f"-h {self.target['host']} -p {self.target['port']} -c listen_addresses={self.target['host']}"
        log_path = Path(data_dir).parents[1] / 'postgresql.log'
        if _is_reparse_point(log_path):
            raise SystemExit(f'E2 startup refused a reparse point at {log_path}.')
        result = subprocess.run([pg_ctl, '-D', data_dir, '-l', str(log_path),
                                 '-o', start_options, '-w', '-t', '45', 'start'],
                                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL, check=False, timeout=60)
        if result.returncode != 0:
            raise SystemExit(f'E2 pg_ctl start failed (exit {result.returncode}). Inspect {log_path} and check the cluster status before retrying.')
        self.started_here = True

    def stop(self):
        if not self.started_here:
            return
        pg_ctl = str(Path(self.target['pg_bin']) / 'pg_ctl.exe')
        result = subprocess.run([pg_ctl, '-D', self.target['data_dir'], '-m', 'fast', '-w', '-t', '45', 'stop'],
                                capture_output=True, text=True, check=False, timeout=60)
        self.started_here = False
        if result.returncode != 0:
            print('WARNING: E2 cluster stop failed. Inspect only the configured E2 cluster before retrying.', file=sys.stderr)

    def __enter__(self):
        self.start()
        return self

    def __exit__(self, _type, _value, _traceback):
        self.stop()


def get_target_config(mode='local'):
    """Load the setup-owned cluster record; refuse legacy target overrides."""
    legacy_overrides = ('GEOLOCK_E2_CONFIG', 'GEOLOCK_E2_DSN', 'GEOLOCK_E2_TARGET_ID',
                        'GEOLOCK_E2_CONFIRM_DISPOSABLE', 'GEOLOCK_E2_EXPECTED_PROJECT_REF',
                        'GEOLOCK_E2_HOSTED_APPROVED_PROJECT_REF', 'PGHOST', 'PGHOSTADDR', 'PGPORT',
                        'PGDATABASE', 'PGUSER', 'PGSERVICE', 'PGSERVICEFILE')
    if os.environ.get('GEOLOCK_E2_MODE', 'local').strip().lower() != 'local':
        raise SystemExit('Local PostgreSQL only is the default. Clear GEOLOCK_E2_MODE; use --mode hosted explicitly.')
    overridden = [name for name in legacy_overrides if os.environ.get(name)]
    if overridden:
        raise SystemExit(f"E2 target/DSN overrides are refused. Clear: {', '.join(overridden)}.")
    path = hosted_config_path() if mode == 'hosted' else default_local_config_path()
    try:
        config = json.loads(path.read_text(encoding='utf-8'))
    except (OSError, json.JSONDecodeError):
        raise SystemExit(f'E2 config is missing or invalid ({path}). See experiments/e2/README.md.') from None
    if mode == 'hosted':
        target = e2_hosted.HostedTarget.from_config(config)
        return target, target
    return validate_local_config(config)


def hosted_config_path():
    return validate_external_config_path(default_local_root() / 'hosted.json')

def run_output_path(results_root, run_id, expected_root=None):
    """Resolve an append-only output path and refuse reparse points or reuse."""
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,63}', run_id or ''):
        raise SystemExit('E2 run ID contains unsafe path characters.')
    root = Path(results_root)
    expected = Path(expected_root).resolve() if expected_root else RESULTS_ROOT
    if root.is_symlink() or (hasattr(root, 'is_junction') and root.is_junction()):
        raise SystemExit('E2 results root must not be a symbolic link or junction.')
    if root.resolve() != expected:
        raise SystemExit('E2 output path must remain under experiment_result/results/.')
    out = root / run_id
    if out.exists() or out.is_symlink() or (hasattr(out, 'is_junction') and out.is_junction()):
        raise SystemExit(f'Result path already exists; refusing to overwrite: {out}')
    return out


def validate_reset_inventory(relations, functions, dependencies=(), current_user=None, triggers=(), schemas=()):
    """Reject unknown reset-scope objects, non-owned objects, or external dependencies."""
    unknown_relations = []
    for row in relations:
        schema, name, kind, owner, extension_owned = row
        if extension_owned:
            continue
        if schema not in RESET_RELATIONS or name not in RESET_RELATIONS[schema] or kind != 'r' or not owner or (current_user and owner != current_user):
            unknown_relations.append(f'{schema}.{name} ({kind}, owner {owner})')
    unknown_functions = []
    for row in functions:
        schema, name, signature, routine_kind, owner, extension_owned = row
        if extension_owned:
            continue
        allowed_signatures = RESET_FUNCTION_SIGNATURES.get(schema, {}).get(name, set())
        if schema not in RESET_FUNCTIONS or name not in RESET_FUNCTIONS[schema] or signature not in allowed_signatures or routine_kind != 'f' or not owner or (current_user and owner != current_user):
            unknown_functions.append(f'{schema}.{name}({signature}) ({routine_kind}, owner {owner})')
    unknown_triggers = [row for row in triggers if tuple(row) not in RESET_TRIGGERS]
    wrong_schema_owners = [row for row in schemas if current_user and row[1] != current_user]
    unexpected = {label: items for label, items in (
        ('relations', unknown_relations), ('functions', unknown_functions), ('dependencies', list(dependencies)),
        ('triggers', unknown_triggers), ('schema owners', wrong_schema_owners),
    ) if items}
    if unexpected:
        raise SystemExit(f'E2 reset refused: target inventory contains unapproved objects or dependencies. {unexpected}')
    return dict(relations=len(relations), functions=len(functions), external_dependencies=0, approved=True)


def inspect_reset_inventory(conn):
    """Read-only inventory for every schema/object family the reset can remove."""
    current_user = conn.execute('select current_user').fetchone()[0]
    relation_rows = conn.execute(
        "select n.nspname,c.relname,c.relkind,r.rolname,exists("
        "select 1 from pg_depend d where d.classid='pg_class'::regclass and d.objid=c.oid and d.deptype='e') "
        "from pg_class c join pg_namespace n on n.oid=c.relnamespace "
        "join pg_roles r on r.oid=c.relowner where n.nspname=any(%s) "
        "and c.relkind in ('r','p','v','m','f','S') order by 1,2", (list(RESET_SCHEMAS),)).fetchall()
    function_rows = conn.execute(
        "select n.nspname,p.proname,oidvectortypes(p.proargtypes),p.prokind,r.rolname,exists("
        "select 1 from pg_depend d where d.classid='pg_proc'::regclass and d.objid=p.oid and d.deptype='e') "
        "from pg_proc p join pg_namespace n on n.oid=p.pronamespace "
        "join pg_roles r on r.oid=p.proowner where n.nspname=any(%s) order by 1,2", (list(RESET_SCHEMAS),)).fetchall()
    dependencies = conn.execute(
        "select c.conname from pg_constraint c join pg_class src on src.oid=c.conrelid "
        "join pg_namespace sn on sn.oid=src.relnamespace join pg_class dst on dst.oid=c.confrelid "
        "join pg_namespace dn on dn.oid=dst.relnamespace "
        "where c.contype='f' and dn.nspname=any(%s) and sn.nspname<>all(%s)",
        (list(RESET_SCHEMAS), list(RESET_SCHEMAS))).fetchall()
    dependencies += conn.execute(
        "select dependent_schema.nspname,dependent.relname from pg_depend d "
        "join pg_class referenced on d.refclassid='pg_class'::regclass and d.refobjid=referenced.oid "
        "join pg_namespace referenced_schema on referenced_schema.oid=referenced.relnamespace "
        "join pg_rewrite rw on d.classid='pg_rewrite'::regclass and d.objid=rw.oid "
        "join pg_class dependent on dependent.oid=rw.ev_class "
        "join pg_namespace dependent_schema on dependent_schema.oid=dependent.relnamespace "
        "where referenced_schema.nspname=any(%s) and dependent_schema.nspname<>all(%s)",
        (list(RESET_SCHEMAS), list(RESET_SCHEMAS))).fetchall()
    dependencies += conn.execute(
        "select 'external relation/function dependency',d.classid::regclass::text,d.objid::text "
        "from pg_depend d join pg_class referenced on d.refclassid='pg_class'::regclass and d.refobjid=referenced.oid "
        "join pg_namespace rn on rn.oid=referenced.relnamespace "
        "left join pg_class dr on d.classid='pg_class'::regclass and dr.oid=d.objid "
        "left join pg_namespace drn on drn.oid=dr.relnamespace "
        "left join pg_proc dp on d.classid='pg_proc'::regclass and dp.oid=d.objid "
        "left join pg_namespace dpn on dpn.oid=dp.pronamespace "
        "where rn.nspname=any(%s) and d.deptype not in ('e','i') "
        "and ((dr.oid is not null and drn.nspname<>all(%s)) or (dp.oid is not null and dpn.nspname<>all(%s)))",
        (list(RESET_SCHEMAS), list(RESET_SCHEMAS), list(RESET_SCHEMAS))).fetchall()
    dependencies += conn.execute(
        "select 'auth.users external foreign key',sn.nspname,src.relname "
        "from pg_constraint c join pg_class src on src.oid=c.conrelid "
        "join pg_namespace sn on sn.oid=src.relnamespace "
        "where c.contype='f' and c.confrelid='auth.users'::regclass "
        "and sn.nspname not in ('auth') and sn.nspname<>all(%s)",
        (list(RESET_SCHEMAS),)).fetchall()
    auth_triggers = conn.execute(
        "select t.tgname from pg_trigger t where t.tgrelid='auth.users'::regclass and not t.tgisinternal").fetchall()
    triggers = conn.execute(
        "select n.nspname,c.relname,t.tgname,p.proname,oidvectortypes(p.proargtypes) "
        "from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace "
        "join pg_proc p on p.oid=t.tgfoid "
        "where not t.tgisinternal and n.nspname=any(%s)", (list(RESET_SCHEMAS),)).fetchall()
    policies = conn.execute(
        "select schemaname,tablename,policyname from pg_policies where schemaname=any(%s)",
        (list(RESET_SCHEMAS),)).fetchall()
    schemas = conn.execute(
        "select n.nspname,r.rolname from pg_namespace n join pg_roles r on r.oid=n.nspowner "
        "where n.nspname=any(%s) and n.nspname<>'public'", (list(RESET_SCHEMAS),)).fetchall()
    # A reset may only run when the target schemas contain the enumerated E2 objects.
    report = validate_reset_inventory(relation_rows, function_rows, dependencies, current_user, triggers, schemas)
    if policies:
        raise SystemExit('E2 reset refused: row-level security policies exist in the reset scope and are not part of the reviewed E2 schema.')
    if auth_triggers:
        raise SystemExit('E2 reset refused: auth.users has non-internal triggers with unreviewed delete side effects.')
    return report


def validate_database_identity(conn, *, target):
    """Verify the setup-owned database, cluster, Auth surface and marker."""
    if isinstance(target, e2_hosted.HostedTarget):
        return e2_hosted.verify_identity(conn, target)
    row = conn.execute(
        "select current_database(),inet_server_addr()::text,current_user,version(),"
        "to_regnamespace('auth') is not null,to_regprocedure('auth.uid()') is not null,"
        "(select count(*) from pg_roles where rolname in ('authenticated','service_role'))"
    ).fetchone()
    if not row or row[0] != E2_DATABASE_NAME or row[2] != 'postgres' or not row[1]:
        raise SystemExit('Connected database or role does not match the required local E2 target.')
    try:
        address = ipaddress.ip_interface(row[1])
    except ValueError:
        raise SystemExit('Could not verify the connected PostgreSQL server address.') from None
    if address != ipaddress.ip_interface(LOCAL_HOST):
        raise SystemExit('Connected server address differs from the configured E2 loopback host.')
    if conn.info.host != LOCAL_HOST or conn.info.user != 'postgres':
        raise SystemExit('Connected PostgreSQL host or user does not match the E2 local configuration.')
    try:
        cluster = conn.execute(
            "select inet_server_port(), current_setting('data_directory'), system_identifier::text "
            "from pg_control_system()"
        ).fetchone()
    except psycopg.Error:
        raise SystemExit('Could not verify the configured E2 cluster identity; reset refused.') from None
    validate_local_cluster_identity(cluster, target)
    if not row[4] or not row[5] or row[6] != 2:
        raise SystemExit('Target lacks the required local Auth compatibility schema, function or roles.')
    try:
        marker = conn.execute(
            f'select target_id, project_ref from {E2_TARGET_MARKER} where singleton is true'
        ).fetchall()
    except psycopg.Error:
        raise SystemExit('Local E2 target marker is missing or unreadable; reset refused.') from None
    if len(marker) != 1 or str(marker[0][0]).replace('-', '').lower() != target['target_id']:
        raise SystemExit('Local E2 target marker is missing or does not match configuration; reset refused.')
    if marker[0][1] is not None:
        raise SystemExit('Local E2 target marker must have a null project_ref; reset refused.')
    return dict(mode='local', target_id=target['target_id'], database=row[0], server_address=str(address.ip),
                current_user=row[2], server_version=row[3].split(' on ')[0], connection_host=conn.info.host,
                connection_user=conn.info.user, marker_verified=True, local_cluster_system_identifier=cluster[2],
                local_data_directory=str(Path(cluster[1]).resolve()), server_port=cluster[0])


def validate_local_cluster_identity(actual, target):
    """Compare read-only PostgreSQL control identity with the E2 setup record."""
    if not actual or len(actual) != 3:
        raise SystemExit('Local E2 cluster identity query returned an incomplete result.')
    port, data_dir, cluster_id = actual
    expected_dir = os.path.normcase(os.path.normpath(str(Path(target['data_dir']).resolve())))
    actual_dir = os.path.normcase(os.path.normpath(str(Path(data_dir).resolve())))
    if int(port) != int(target['port']):
        raise SystemExit('Connected PostgreSQL port does not match the E2-owned cluster configuration.')
    if actual_dir != expected_dir:
        raise SystemExit('Connected PostgreSQL data directory does not match the E2-owned cluster; reset refused.')
    if str(cluster_id) != str(target['cluster_system_identifier']):
        raise SystemExit('Connected PostgreSQL system identifier does not match the E2-owned cluster; reset refused.')
    return True


def connect(dsn):
    """Connect using a validated hosted enrollment or the exact local DSN form."""
    if isinstance(dsn, e2_hosted.HostedTarget):
        return dsn.connect(connect_timeout=CONNECT_TIMEOUT_S, statement_timeout=STATEMENT_TIMEOUT_S)
    match = re.fullmatch(r'host=127\.0\.0\.1 port=([0-9]{4,5}) dbname=geolock_e2 user=postgres', dsn)
    if not match or not 1024 <= int(match[1]) <= 65535 or int(match[1]) == 5432:
        raise SystemExit('E2 accepts only the setup-owned loopback DSN on a dedicated port.')
    return psycopg.connect(dsn, autocommit=True, connect_timeout=CONNECT_TIMEOUT_S,
                           hostaddr=LOCAL_HOST, options=f'-c statement_timeout={STATEMENT_TIMEOUT_S * 1000}')


def fixture_accounts():
    allowed = {}
    keys = [row['donor_id'] for row in rows('donors')] + [row['ngo_id'] for row in rows('ngos')]
    for key in keys:
        account_id = str(uuid.uuid5(ACCOUNT_NAMESPACE, key))
        email = f'{key.lower()}@{ACCOUNT_DOMAIN}'
        if account_id in allowed and allowed[account_id] != email:
            raise SystemExit('E2 benchmark account identity collision; refusing reset.')
        allowed[account_id] = email
    return allowed


def setup_database(dsn, target, preflight_identity, *, reset_conn=None):
    """Reset the confirmed disposable target and build it again: 04 reset, 01 schema, 02 app claim layer,
    03 baseline 1 functions, then the benchmark road matrix."""
    hosted = isinstance(target, e2_hosted.HostedTarget)
    if hosted and reset_conn is None:
        raise SystemExit('Hosted E2 reset requires the run-lock connection.')
    if hosted:
        check_inputs(TABLES)
    with (nullcontext(reset_conn) if hosted else connect(dsn)) as conn:
        actual = validate_database_identity(conn, target=target)
        if actual != preflight_identity:
            raise SystemExit('Connected database identity changed after read-only preflight; reset was refused.')
        inspect_reset_inventory(conn)
        target_id = target.target_id if hosted else target['target_id']
        # Session-local guards survive the reset SQL's implicit transaction. The
        # reset itself is atomic; subsequent builders retain their own transaction
        # boundaries (02_app_claim_layer.sql contains BEGIN/COMMIT).
        conn.execute("select set_config('app.geolock_e2_reset_target_id', %s, false)",
                     (str(uuid.UUID(target_id)),))
        conn.execute("select set_config('app.geolock_e2_allowed_accounts', %s, false)",
                     (json.dumps(fixture_accounts(), sort_keys=True),))
        conn.execute("select set_config('app.geolock_e2_project_ref', %s, false)",
                     (target.project if hosted else '',))
        try:
            conn.execute((SQL / '04_reset_e2_objects.sql').read_text(encoding='utf-8'))
        except psycopg.Error as exc:
            conn.rollback()
            raise SystemExit(f"04_reset_e2_objects.sql failed (SQLSTATE {exc.sqlstate}): {exc.diag.message_primary}") from None
        finally:
            conn.execute("select set_config('app.geolock_e2_reset_target_id', '', false), "
                         "set_config('app.geolock_e2_allowed_accounts', '', false), "
                         "set_config('app.geolock_e2_project_ref', '', false)")
        for name in ('01_geolock_v3_schema.sql', '02_app_claim_layer.sql', '03_non_atomic_baseline.sql'):
            try:
                conn.execute((SQL / name).read_text(encoding='utf-8'))
            except psycopg.Error as exc:
                raise SystemExit(f'{name} failed (SQLSTATE {exc.sqlstate}): {exc.diag.message_primary}') from None
        check_inputs(['road_distance_matrix'])
        with conn.cursor() as cur, cur.copy('copy e2_bench.road_km(from_node, to_node, km) from stdin') as cp:
            for r in rows('road_distance_matrix'):
                if r['route_available_flag'] == '1':
                    cp.write_row((r['from_node_id'], r['to_node_id'], float(r['road_distance_km'])))
        return actual


# Benchmark data

def parse_time(value):
    """Parse a benchmark time."""
    return datetime.fromisoformat(value)


class Benchmark:
    """The benchmark tables E2 needs, checked against the manifest."""
    def __init__(self):
        self.hashes = check_inputs(TABLES)
        m = manifest()
        t = {n: rows(n) for n in TABLES}
        self.scenarios = sorted(t['scenarios'], key=lambda r: r['scenario_id'])
        self.members = defaultdict(list)
        for r in t['scenario_members']:
            self.members[r['scenario_id']].append(r)
        self.ngos = {r['ngo_id']: r for r in t['ngos']}
        self.ngo_state = {r['ngo_id']: r['state'] for r in m['provenance']['ngos']}
        self.donations = {r['donation_id']: r for r in t['donations']}
        self.donors = {r['donor_id']: r for r in t['donors']}
        self.listings = {r['listing_id']: r for r in t['listings']}
        self.claim_states = {r['scenario_id']: r for r in t['claim_initial_states']}
        self.road = {(r['from_node_id'], r['to_node_id']): r for r in t['road_distance_matrix']}

    def ids(self, sid, kind, role):
        return sorted(r['entity_id'] for r in self.members[sid] if r['entity_type'] == kind and r['scenario_role'] == role)

    def one(self, sid, kind, role):
        v = self.ids(sid, kind, role)
        if len(v) != 1:
            raise ValueError(f'Expected one {role} in {sid}')
        return v[0]

    def road_km(self, ngo_id, listing_id):
        r = self.road.get((self.ngos[ngo_id]['road_node_id'], self.listings[listing_id]['pickup_road_node_id']))
        return float(r['road_distance_km']) if r and r['route_available_flag'] == '1' else None

    def select(self, kinds):
        return [s for s in self.scenarios if s['scenario_type'] in kinds]


def worker_count(sid):
    # scenarios 1 to 50 use 2 NGOs, 51 to 100 use 5, 101 to 150 use 10
    """How many NGOs claim at once in this scenario."""
    return WORKER_LEVELS[min((int(sid.rsplit('-', 1)[1]) - 1) // TRIALS_PER_LEVEL, 2)]


class Database:
    """Writes the test data into the experiment database and reads back what was saved."""
    def __init__(self, dsn, run_id):
        self.namespace = uuid.uuid5(uuid.NAMESPACE_URL, f'geolock-e2/{run_id}')
        self.dsn = dsn
        self.conn = connect(dsn)
        self.users = set()

    def uid(self, kind, key):
        return uuid.uuid5(self.namespace, f'{kind}/{key}')

    def check(self):
        with self.conn.cursor() as cur:
            cur.execute("select count(*) from auth.users where email is null or email not like %s", ('%@' + ACCOUNT_DOMAIN,))
            if cur.fetchone()[0]:
                raise SystemExit('Refusing to run: this project has real user accounts. Use the separate E2 project.')
            cur.execute("select pg_get_functiondef('public.claim_listing(uuid,uuid)'::regprocedure)")
            return cur.fetchone()[0]

    def _user(self, cur, key, full_name, role):
        user_id = uuid.uuid5(ACCOUNT_NAMESPACE, key)
        if user_id not in self.users:
            cur.execute('insert into auth.users(id, email) values (%s, %s) on conflict (id) do nothing',
                        (user_id, f'{key.lower()}@{ACCOUNT_DOMAIN}'))
            cur.execute('insert into public.user_profiles(user_id, full_name, role) values (%s, %s, %s) '
                        'on conflict (user_id) do nothing', (user_id, full_name, role))
            self.users.add(user_id)
        return user_id

    def ngo(self, bench, ngo_id):
        row = bench.ngos[ngo_id]
        with self.conn.cursor() as cur:
            user_id = self._user(cur, ngo_id, row['ngo_name'], 'NGO')
            cur.execute('insert into public.ngo_profiles(user_id, ngo_name, operating_address, latitude, longitude, '
                        'road_node_id, location_verified_at) values (%s,%s,%s,%s,%s,%s, clock_timestamp()) '
                        'on conflict (user_id) do nothing',
                        (user_id, row['ngo_name'], f"{bench.ngo_state[ngo_id]}, Malaysia",
                         float(row['latitude']), float(row['longitude']), row['road_node_id']))
        return user_id

    def listing(self, bench, listing_id, instance, opened_ago=timedelta(0)):
        """A new AVAILABLE donation and its AVAILABLE listing, as the app creates them."""
        bl = bench.listings[listing_id]
        donation = bench.donations[bl['donation_id']]
        donor = bench.donors[donation['donor_id']]
        lifetime = parse_time(bl['listing_expires_at']) - parse_time(bl['created_at'])
        d_uuid = self.uid('DONATION', f'{bl["donation_id"]}/{instance}')
        l_uuid = self.uid('LISTING', f'{listing_id}/{instance}')
        with self.conn.cursor() as cur:
            donor_id = self._user(cur, donation['donor_id'], f"Donor {donation['donor_id']}", 'DONOR')
            cur.execute('insert into public.donor_profiles(user_id) values (%s) on conflict do nothing', (donor_id,))
            cur.execute('select clock_timestamp() - %s', (opened_ago,))
            opened = cur.fetchone()[0]
            cur.execute("insert into public.donations(donation_id, donor_user_id, title, collection_path, "
                        "donation_status, pickup_address, latitude, longitude, pickup_road_node_id, total_weight_kg, "
                        "availability_start, availability_end) "
                        "values (%s,%s,%s,'DIRECT_PICKUP','AVAILABLE',%s,%s,%s,%s,%s,%s,%s)",
                        (d_uuid, donor_id, f"{donation['category'].capitalize()} donation {bl['donation_id']}",
                         f"Home pickup, donor {donation['donor_id']}", float(donor['latitude']),
                         float(donor['longitude']), donor['road_node_id'], float(donation['weight_kg']),
                         opened, opened + lifetime))
            cur.execute("insert into public.listings(listing_id, source_type, donation_id, listing_status, "
                        "listing_weight_kg, pickup_latitude, pickup_longitude, pickup_road_node_id, created_at, "
                        "listing_expires_at) values (%s,'DIRECT_DONATION',%s,'AVAILABLE',%s,%s,%s,%s,%s,%s)",
                        (l_uuid, d_uuid, float(bl['listing_weight_kg']), float(donor['latitude']),
                         float(donor['longitude']), bl['pickup_road_node_id'], opened, opened + lifetime))
        return l_uuid, d_uuid

    def prior_claim(self, sid, instance, listing_uuid, donation_uuid, holder_uuid, claimed_ago):
        """The earlier claim of a lease case, saved exactly as the app's claim_listing() leaves it."""
        req, claim = self.uid('PRIOR_REQUEST', f'{sid}/{instance}'), self.uid('PRIOR_CLAIM', f'{sid}/{instance}')
        with self.conn.transaction(), self.conn.cursor() as cur:
            cur.execute('select clock_timestamp() - %s', (claimed_ago,))
            issued = cur.fetchone()[0]
            cur.execute("insert into public.claim_requests(request_id, listing_id, ngo_user_id, request_digest, created_at) "
                        "values (%s,%s,%s,md5(%s),%s)", (req, listing_uuid, holder_uuid, f'{listing_uuid}:{holder_uuid}', issued))
            cur.execute("insert into public.donation_claims(claim_id, listing_id, ngo_user_id, request_id, claim_status, claimed_at) "
                        "values (%s,%s,%s,%s,'ACTIVE',%s)", (claim, listing_uuid, holder_uuid, req, issued))
            cur.execute("update public.claim_requests set outcome='SUCCESS', result_claim_id=%s, completed_at=%s "
                        "where request_id=%s", (claim, issued, req))
            cur.execute("insert into public.claim_leases(claim_id, lease_status, issued_at, expires_at) "
                        "values (%s,'ACTIVE',%s,%s)", (claim, issued, issued + timedelta(minutes=LEASE_MINUTES)))
            cur.execute("update public.listings set listing_status='CLAIMED', listing_version=listing_version+1 "
                        "where listing_id=%s", (listing_uuid,))
            cur.execute("insert into public.pickup_tasks(claim_id, listing_id, ngo_user_id, pickup_road_node_id, load_kg, created_at) "
                        "select %s, listing_id, %s, pickup_road_node_id, listing_weight_kg, %s from public.listings "
                        "where listing_id=%s", (claim, holder_uuid, issued, listing_uuid))
            cur.execute("update public.donations set donation_status='CLAIMED' where donation_id=%s", (donation_uuid,))
        return claim

    def recover(self):
        """Run the app's recovery job as the scheduler (service_role). Returns (released, ms)."""
        with connect(self.dsn) as c, c.cursor() as cur:
            cur.execute('set role service_role')
            cur.execute("select set_config('request.jwt.claims', %s, false)", (json.dumps({'role': 'service_role'}),))
            t = time.perf_counter()
            cur.execute('select public.recover_expired_claims(1000)')
            n = cur.fetchone()[0]
            return n, round((time.perf_counter() - t) * 1000, 1)

    def claims_on(self, listing_uuid):
        """What is really saved for a listing, read from both claim tables."""
        with self.conn.cursor() as cur:
            cur.execute('select claim_id, ngo_user_id, claim_status from public.donation_claims where listing_id=%s '
                        'union all select claim_id, ngo_user_id, claim_status from e2_baseline.naive_claims where listing_id=%s',
                        (listing_uuid, listing_uuid))
            claims = cur.fetchall()
            cur.execute('select l.listing_status, d.donation_status from public.listings l '
                        'join public.donations d using (donation_id) where l.listing_id=%s', (listing_uuid,))
            status, donation = cur.fetchone()
            cur.execute('select count(*) from public.claim_reconciliation_cases where listing_id=%s', (listing_uuid,))
            recon = cur.fetchone()[0]
        return claims, status, donation, recon

    def attempts_recorded(self, listing_uuid, request_ids):
        """How many of the given requests left a CLAIM_ATTEMPT row in the app's audit log."""
        return self.conn.execute("select count(distinct request_id) from public.audit_events where event_type='CLAIM_ATTEMPT' "
                                 "and entity_id=%s and request_id = any(%s)", (listing_uuid, request_ids)).fetchone()[0]

    def server(self):
        with self.conn.cursor() as cur:
            cur.execute("select version(), current_setting('default_transaction_isolation')")
            v, iso = cur.fetchone()
            cur.execute("select extname, extversion from pg_extension where extname in ('postgis','pgcrypto') order by extname")
            extensions = {name: version for name, version in cur.fetchall()}
        if set(extensions) != {'postgis', 'pgcrypto'}:
            raise SystemExit('E2 requires installed postgis and pgcrypto extensions.')
        kind = ('verified isolated Supabase E2 target' if isinstance(self.dsn, e2_hosted.HostedTarget)
                else 'verified local E2 target (cluster identity and marker checked before setup)')
        return v.split(' on ')[0], iso, kind, extensions


# Sending claim requests

def sign_in(conn, user_uuid):
    """Act as this NGO in the session, the way Supabase does for a signed in user."""
    with conn.cursor() as cur:
        cur.execute('set role authenticated')
        cur.execute(f"set statement_timeout = '{STATEMENT_TIMEOUT_S}s'")
        cur.execute("select set_config('request.jwt.claims', %s, false)",
                    (json.dumps({'sub': str(user_uuid), 'role': 'authenticated'}),))


def append_sqlstate(item, sqlstate):
    """Retain distinct SQLSTATEs observed for one request, including errors later retried."""
    code = (sqlstate or '').strip()
    if code:
        states = item.setdefault('sqlstates', [])
        if code not in states:
            states.append(code)


def safe_error_label(exc):
    """Keep exception evidence useful without persisting messages that may contain connection details."""
    code = getattr(exc, 'sqlstate', None)
    return f'{type(exc).__name__} (SQLSTATE {code})' if code else type(exc).__name__


def failure_audit_sqlstate(dsn, request_uuid):
    """Read SQLSTATE captured by claim_listing after its claim subtransaction rolls back."""
    try:
        with connect(dsn) as conn:
            row = conn.execute(
                "select details->>'sqlstate' from public.operation_failure_events "
                "where request_id=%s and operation_name='claim_listing' order by occurred_at desc limit 1",
                (request_uuid,)).fetchone()
        return row[0] if row and row[0] else None
    except psycopg.Error:
        # Diagnostic lookup must not alter the outcome or retry semantics.
        return None


def send_together(dsn, requests, spec):
    """Send the requests of one trial at the same moment, one connection per NGO.
    NGOs that are more than 20 km away by road are refused before a request is sent."""
    for item in requests:
        km = item['road_distance_km']
        item.update(retries=0, error='', latency_ms=0.0, claim_id='', outcome='', reason_code='', sqlstates=[])
        if km is None or km > GEOFENCE_KM:
            item.update(outcome='INELIGIBLE', reason_code='ROUTE_UNAVAILABLE' if km is None else 'OUTSIDE_GEOFENCE')
    sent = [i for i in requests if not i['outcome']]
    if not sent:
        return requests

    def open_signed_in(item):
        c = connect(dsn)
        sign_in(c, item['ngo_uuid'])
        return c

    conns = []
    try:
        with ThreadPoolExecutor(max_workers=len(sent)) as pool:
            futures = [pool.submit(open_signed_in, item) for item in sent]
            for f in futures:
                conns.append(f.result())
        start = threading.Barrier(len(sent))
        checked = threading.Barrier(len(sent))
        released = []

        def call(conn, sql, args):
            with conn.cursor() as cur:
                cur.execute(sql, args)
                return cur.fetchone()[0]

        def two_step(i, item):
            # baseline 1: everybody checks first, then everybody writes
            start.wait(timeout=BARRIER_TIMEOUT_S)
            released.append(time.perf_counter())
            ms, ok = 0.0, False
            try:
                t = time.perf_counter()
                out = call(conns[i], spec['check'], (item['listing_uuid'],))
                ms += (time.perf_counter() - t) * 1000
                ok = out.get('outcome') == 'AVAILABLE'
                if not ok:
                    item.update(outcome=out.get('outcome'), reason_code=out.get('reason_code') or '')
            except psycopg.Error as exc:
                append_sqlstate(item, exc.sqlstate)
                item.update(outcome='ERROR', error=safe_error_label(exc))
            checked.wait(timeout=BARRIER_TIMEOUT_S)
            if ok:
                try:
                    t = time.perf_counter()
                    out = call(conns[i], spec['write'], (item['listing_uuid'], item['request_uuid']))
                    ms += (time.perf_counter() - t) * 1000
                    item.update(outcome=out.get('outcome'), reason_code=out.get('reason_code') or '',
                                claim_id=out.get('claim_id') or '')
                except psycopg.Error as exc:
                    append_sqlstate(item, exc.sqlstate)
                    item.update(outcome='ERROR', error=safe_error_label(exc))
            item['latency_ms'] = round(ms, 1)

        def one_call(i, item):
            start.wait(timeout=BARRIER_TIMEOUT_S)
            t = time.perf_counter()
            released.append(t)
            while True:
                try:
                    out = call(conns[i], spec['call'], (item['listing_uuid'], item['request_uuid']))
                    item.update(outcome=out.get('outcome'), reason_code=out.get('reason_code') or '',
                                claim_id=out.get('claim_id') or '')
                    break
                except TRANSIENT as exc:
                    append_sqlstate(item, exc.sqlstate)
                    if item['retries'] >= MAX_RETRIES:
                        item.update(outcome='ERROR', error=safe_error_label(exc))
                        break
                    item['retries'] += 1
                except psycopg.Error as exc:
                    append_sqlstate(item, exc.sqlstate)
                    item.update(outcome='ERROR', error=safe_error_label(exc))
                    break
            item['latency_ms'] = round((time.perf_counter() - t) * 1000, 1)
            # The function catches some PostgreSQL errors and returns an ERROR
            # receipt. Retrieve its trusted SQLSTATE after timing is stopped.
            if item['outcome'] == 'ERROR':
                append_sqlstate(item, failure_audit_sqlstate(dsn, item['request_uuid']))

        target = two_step if spec['two_step'] else one_call
        threads = [threading.Thread(target=target, args=(i, it)) for i, it in enumerate(sent)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        trial_ms = round((time.perf_counter() - min(released)) * 1000, 1)
        for item in requests:
            item['trial_ms'] = trial_ms
        return requests
    finally:
        for c in conns:
            c.close()


def replay_request(dsn, item):
    """Send the same request ID again. The app must return the first answer and save nothing new."""
    with connect(dsn) as c:
        sign_in(c, item['ngo_uuid'])
        return c.execute('select public.claim_listing(%s,%s)', (item['listing_uuid'], item['request_uuid'])).fetchone()[0]


def yes(v):
    """YES or NO."""
    return 'YES' if v else 'NO'


def med(values):
    """Median, rounded to 0.1."""
    return round(statistics.median(values), 1) if values else 0.0


# Contention and lease trials

def run(method, out, dsn):
    """Run the contention and lease trials for one condition and write its result folder."""
    spec = METHODS[method]
    bench = Benchmark()
    run_id = os.environ.get('GEOLOCK_E2_RUN_ID') or uuid.uuid4().hex
    db = Database(dsn, run_id)
    claim_body = db.check()
    out = Path(out)
    trials, lease, requests = [], [], []
    scenarios = bench.select(spec['parts'])
    for n, s in enumerate(scenarios, 1):
        sid, kind = s['scenario_id'], s['scenario_type']
        listing_id = bench.one(sid, 'LISTING', 'CLAIMABLE_LISTING')
        inst = f'{method}/{sid}'
        if kind == 'CLAIM_COORDINATION':
            ngos = bench.ids(sid, 'NGO', 'POTENTIAL_REQUESTER_UNASSESSED')
            w = worker_count(sid)
            l_uuid, _ = db.listing(bench, listing_id, inst)
            batch = [dict(scenario_id=sid, listing_id=listing_id, workers=w, request_no=i + 1,
                          ngo_id=ngos[i % len(ngos)], ngo_uuid=db.ngo(bench, ngos[i % len(ngos)]),
                          road_distance_km=bench.road_km(ngos[i % len(ngos)], listing_id), listing_uuid=l_uuid,
                          request_uuid=db.uid('REQUEST', f'{inst}/{i + 1}')) for i in range(w)]
            done = send_together(dsn, batch, spec)
            sent_ids = [r['request_uuid'] for r in done if r['outcome'] != 'INELIGIBLE']
            audited = db.attempts_recorded(l_uuid, sent_ids)
            replay = {}
            if not spec['two_step']:
                first = next((r for r in done if r['outcome'] in ('SUCCESS', 'CONFLICT')), None)
                if first:
                    again = replay_request(dsn, first)
                    replay = dict(replay_flagged=yes(again.get('replayed')),
                                  replay_same_answer=yes(again.get('outcome') == first['outcome']
                                                         and str(again.get('claim_id') or '') == str(first['claim_id'] or '')))
            claims, status, dstatus, _ = db.claims_on(l_uuid)
            stored = [c for c in claims if c[2] in ('ACTIVE', 'RECONCILIATION_REQUIRED')]
            times = [r['latency_ms'] for r in done if r['latency_ms']]
            told = sum(r['outcome'] == 'SUCCESS' for r in done)
            consistent = told == len(stored) and (status == 'CLAIMED') == (len(stored) > 0)
            trial_s = (done[0].get('trial_ms') or 0) / 1000
            trials.append(dict(
                scenario_id=sid, listing_id=listing_id, ngos_competing=w,
                different_ngos=len({r['ngo_id'] for r in done}),
                told_success=sum(r['outcome'] == 'SUCCESS' for r in done),
                told_already_claimed=sum(r['outcome'] == 'CONFLICT' for r in done),
                told_not_eligible=sum(r['outcome'] == 'INELIGIBLE' for r in done),
                failed_with_error=sum(r['outcome'] == 'ERROR' for r in done),
                retries_after_deadlock=sum(r['retries'] for r in done),
                claims_stored=len(stored), more_than_one_owner=yes(len(stored) > 1),
                success_answers_match_stored=yes(sum(r['outcome'] == 'SUCCESS' for r in done) == len(stored)),
                listing_status_after=status, donation_status_after=dstatus,
                median_response_ms=med(times), slowest_response_ms=max(times) if times else 0.0,
                trial_ms=done[0].get('trial_ms', ''), requests_per_second=round(len(sent_ids) / trial_s, 1) if trial_s else '',
                attempts_sent=len(sent_ids), attempts_in_audit_log=audited, consistent_state=yes(consistent), **replay))
        else:
            state = bench.claim_states[sid]
            prior = bench.one(sid, 'NGO', 'PRIOR_CLAIMANT')
            second = bench.one(sid, 'NGO', 'POTENTIAL_REPLACEMENT_CLAIMANT')
            if state['listing_id'] != listing_id or state['ngo_id'] != prior:
                raise ValueError(f'Lease case does not match scenario members: {sid}')
            claimed_ago = parse_time(state['replay_at']) - parse_time(bench.listings[listing_id]['created_at'])
            l_uuid, d_uuid = db.listing(bench, listing_id, inst, opened_ago=claimed_ago)
            prior_claim = db.prior_claim(sid, inst, l_uuid, d_uuid, db.ngo(bench, prior), claimed_ago)
            with db.conn.cursor() as cur:
                cur.execute('select expires_at <= clock_timestamp() from public.claim_leases where claim_id=%s', (prior_claim,))
                if cur.fetchone()[0] != (state['input_state'] == 'EXPIRED'):
                    raise ValueError(f'Lease case state does not match its expiry time: {sid}')
            recovered, recovery_ms = db.recover() if spec['recovery'] else (0, 0.0)
            item = dict(scenario_id=sid, listing_id=listing_id, workers=1, request_no=1, ngo_id=second,
                        ngo_uuid=db.ngo(bench, second), road_distance_km=bench.road_km(second, listing_id),
                        listing_uuid=l_uuid, request_uuid=db.uid('REQUEST', f'{inst}/1'))
            done = send_together(dsn, [item], spec)
            claims, status, dstatus, recon = db.claims_on(l_uuid)
            prior_status = next(c[2] for c in claims if c[0] == prior_claim)
            expired = state['input_state'] == 'EXPIRED'
            got = done[0]['outcome'] == 'SUCCESS'
            extra = {}
            if spec['recovery']:
                again = db.recover()[0]
                stale = dict(scenario_id=sid, listing_id=listing_id, workers=1, request_no=2, ngo_id=prior,
                             ngo_uuid=db.ngo(bench, prior), road_distance_km=bench.road_km(prior, listing_id),
                             listing_uuid=l_uuid, request_uuid=db.uid('STALE_REQUEST', f'{inst}/1'))
                sdone = send_together(dsn, [stale], spec)
                claims, status, dstatus, recon = db.claims_on(l_uuid)
                active = [c for c in claims if c[2] == 'ACTIVE']
                extra = dict(repeated_recovery_released=again,
                             old_holder_new_request_answer=f"{sdone[0]['outcome']}/{sdone[0]['reason_code']}",
                             old_holder_regained_listing=yes(expired and any(c[1] == stale['ngo_uuid'] for c in active)),
                             active_claims_after_stale_attempt=len(active))
                requests.extend(sdone)
            lease.append(dict(
                scenario_id=sid, case='lease expired' if expired else 'lease still running',
                listing_id=listing_id, first_ngo=prior, second_ngo=second,
                recovery_ran=yes(spec['recovery']), claims_released_by_recovery=recovered,
                recovery_ms=recovery_ms, second_ngo_answer=done[0]['outcome'],
                second_ngo_reason=done[0]['reason_code'], second_ngo_got_listing=yes(got),
                first_claim_status_after=prior_status,
                active_claims_after=sum(c[2] in ('ACTIVE', 'RECONCILIATION_REQUIRED') for c in claims),
                listing_status_after=status, donation_status_after=dstatus, reconciliation_cases=recon,
                correct=yes(got if expired else (not got and prior_status == 'ACTIVE')),
                second_ngo_response_ms=done[0]['latency_ms'], **extra))
        requests.extend(done)
        if n % 25 == 0:
            print(f'  {n}/{len(scenarios)} trials', flush=True)
    version, isolation, kind, extensions = db.server()
    db.conn.close()
    if trials:
        levels = {w: sum(t['ngos_competing'] == w for t in trials) for w in WORKER_LEVELS}
        assert levels == {w: TRIALS_PER_LEVEL for w in WORKER_LEVELS}, levels
        write_csv(out / 'results_per_scenario.csv', trials)
    if lease:
        write_csv(out / 'lease_results_per_scenario.csv', lease)
    write_csv(out / 'details' / 'requests.csv', [dict(
        scenario_id=r['scenario_id'], listing_id=r['listing_id'], ngos_competing=r['workers'],
        request_number=r['request_no'], ngo_id=r['ngo_id'], road_distance_km=r['road_distance_km'],
        answer=r['outcome'], reason_code=r['reason_code'], retries=r['retries'], error_message=r['error'],
        sqlstate=';'.join(r.get('sqlstates', [])),
        response_ms=r['latency_ms'], trial_ms=r.get('trial_ms', ''), request_id=str(r['request_uuid']), claim_id=str(r['claim_id'])) for r in requests])
    env = environment()
    sync = 'one database connection per NGO, all requests of a trial released together by a barrier'
    if spec['two_step']:
        sync += '; a second barrier makes every NGO finish its check before any NGO saves'
    info = [('Condition', spec['title']), ('Run at', env['run_at']),
            ('Benchmark', f'{BENCHMARK_NAME} (every input checked against generation_manifest.json)'),
            ('Database', f'{kind} ({version})'), ('Isolation', isolation),
            ('PostgreSQL extensions', json.dumps(extensions, sort_keys=True)),
            ('Schema', '01_geolock_v3_schema.sql, 02_app_claim_layer.sql (app functions copied from the deployed '
                       'Supabase export of 2026-11-09), 03_non_atomic_baseline.sql'),
            ('claim_listing() SHA-256', hashlib.sha256(claim_body.encode()).hexdigest()[:16] + '...'),
            ('Contention trials', f'{len(trials)}: 50 each with 2, 5 and 10 NGOs' if trials else 'not run (lease part only)'),
            ('Lease trials', f"{sum(c['case'] == 'lease expired' for c in lease)} expired, "
                             f"{sum(c['case'] == 'lease still running' for c in lease)} still running" if lease
             else 'not run (contention part only)'),
            ('Synchronisation', sync),
            ('Retry', 'none' if spec['two_step'] else 'one retry with the same request ID after a deadlock or serialization failure'),
            ('Timeout', f'connect {CONNECT_TIMEOUT_S} s, statement {STATEMENT_TIMEOUT_S} s, barrier {BARRIER_TIMEOUT_S} s'),
            ('Rules', f'{GEOFENCE_KM:g} km road geofence, {LEASE_MINUTES} min lease'),
            ('Lease recovery', 'runs before the second NGO claims' if spec['recovery'] else 'never runs'),
            ('Run ID', run_id), ('Python', env['python']), ('psycopg', env['psycopg'])]
    run_info(out / 'run_info.md', spec['title'], info)
    root_manifest_path = Path(os.environ['GEOLOCK_E2_RUN_DIR']) / 'run_manifest.json'
    root_manifest = json.loads(root_manifest_path.read_text(encoding='utf-8'))
    write_json(out / 'run_manifest.json', dict(method=method, experiment_run_id=run_id,
                                                method_run_id=hashlib.sha256(f'{run_id}/{method}'.encode()).hexdigest()[:16],
                                                input_sha256=bench.hashes, environment=env, database=kind,
                                                target_identity=json.loads(os.environ.get('GEOLOCK_E2_TARGET_IDENTITY', '{}')),
                                                source_sha256=root_manifest['source_sha256'],
                                                server_version=version,
                                                extension_versions=extensions,
                                                trials=len(trials), lease_cases=len(lease),
                                                contention_requests=sum(int(t['ngos_competing']) for t in trials),
                                                expired_lease_cases=sum(c['case'] == 'lease expired' for c in lease),
                                                active_lease_cases=sum(c['case'] == 'lease still running' for c in lease),
                                                request_records=len(requests)))
    return trials, lease, requests


# Extra checks of the proposed method

def reference_eligibility(bench, ngo_id, listing_id):
    """The right geofence answer, from the benchmark road distance."""
    km = bench.road_km(ngo_id, listing_id)
    if km is None:
        return 'ROUTE_UNAVAILABLE', None
    return ('ELIGIBLE' if km <= GEOFENCE_KM else 'OUTSIDE_GEOFENCE'), km


def run_geofence(out, dsn):
    """Geofence check: 100 listings x 11 NGOs. The right answer is the benchmark road distance
    within 20 km. NGOs that are not allowed also call claim_listing() directly."""
    bench = Benchmark()
    run_id = uuid.uuid4().hex[:12]
    db = Database(dsn, run_id)
    db.check()
    out = Path(out)
    pairs = []
    ngo_conn = connect(dsn)
    for s in bench.select(('GEOFENCE_VERIFICATION',)):
        sid = s['scenario_id']
        listing_id = bench.one(sid, 'LISTING', 'CLAIMABLE_LISTING')
        l_uuid, _ = db.listing(bench, listing_id, f'geofence/{sid}')
        for ngo_id in bench.ids(sid, 'NGO', 'POTENTIAL_REQUESTER_UNASSESSED'):
            ngo_uuid = db.ngo(bench, ngo_id)
            ref, km = reference_eligibility(bench, ngo_id, listing_id)
            t = time.perf_counter()
            decision = db.conn.execute('select public.geolock_ngo_listing_road_check(%s,%s)',
                                       (ngo_uuid, l_uuid)).fetchone()[0]['outcome']
            ms = round((time.perf_counter() - t) * 1000, 2)
            admitted, should = decision == 'ELIGIBLE', ref == 'ELIGIBLE'
            direct = ''
            if not should:
                sign_in(ngo_conn, ngo_uuid)
                got = ngo_conn.execute('select public.claim_listing(%s,%s)',
                                       (l_uuid, uuid.uuid5(db.namespace, f'direct/{sid}/{ngo_id}'))).fetchone()[0]
                direct = f"{got.get('outcome')}/{got.get('reason_code')}"
            pairs.append(dict(scenario_id=sid, listing_id=listing_id, ngo_id=ngo_id, direct_claim_by_ineligible_ngo=direct,
                              road_distance_km=round(km, 3) if km is not None else '', reference=ref, decision=decision,
                              correct=yes(admitted == should),
                              error_type='' if admitted == should else ('FALSE_ELIGIBLE' if admitted else 'FALSE_INELIGIBLE'),
                              decision_ms=ms))
    ngo_conn.close()
    stored = db.conn.execute('select count(*) from public.donation_claims').fetchone()[0]
    db.conn.close()
    write_json(out / 'details' / 'claims_stored_after_check.json', dict(claims_stored=stored))
    write_csv(out / 'details' / 'eligibility_pairs.csv', pairs)
    by = defaultdict(list)
    for p in pairs:
        by[p['scenario_id']].append(p)
    write_csv(out / 'results_per_scenario.csv', [dict(
        scenario_id=s, listing_id=ps[0]['listing_id'], ngo_pairs=len(ps),
        reference_eligible=sum(p['reference'] == 'ELIGIBLE' for p in ps),
        decided_eligible=sum(p['decision'] == 'ELIGIBLE' for p in ps),
        correct=sum(p['correct'] == 'YES' for p in ps),
        all_correct=yes(all(p['correct'] == 'YES' for p in ps))) for s, ps in sorted(by.items())])
    run_info(out / 'run_info.md', 'Geofence check of the proposed method', [
        ('Run at', environment()['run_at']), ('Pairs', f'{len(pairs)} NGO listing pairs in 100 scenarios'),
        ('Right answer', 'benchmark road distance from NGO to pickup is 20 km or less, and a route exists'),
        ('Decision', 'deployed geolock_ngo_listing_road_check() logic, road distance from the benchmark'),
        ('Direct claims', 'every NGO that is not allowed also calls claim_listing() directly'), ('Run ID', run_id)])
    return pairs


def delayed_request_check(dsn):
    """Two NGOs claim the same listing. NGO A's claim is held open for DELAY_S seconds before it
    commits, and NGO B claims during that time. Only one claim may be saved. Run on the 50
    contention scenarios with two NGOs."""
    bench = Benchmark()
    db = Database(dsn, uuid.uuid4().hex[:12] + '-delayed')
    rows_out = []
    for s in bench.select(('CLAIM_COORDINATION',)):
        sid = s['scenario_id']
        if worker_count(sid) != 2:
            continue
        listing_id = bench.one(sid, 'LISTING', 'CLAIMABLE_LISTING')
        a_id, b_id = bench.ids(sid, 'NGO', 'POTENTIAL_REQUESTER_UNASSESSED')[:2]
        l_uuid, _ = db.listing(bench, listing_id, f'delayed/{sid}')
        a, b = connect(dsn), connect(dsn)
        sign_in(a, db.ngo(bench, a_id))
        sign_in(b, db.ngo(bench, b_id))
        holding, out = threading.Event(), {}

        def slow():
            with a.transaction():
                out['a'] = a.execute('select public.claim_listing(%s,%s)', (l_uuid, db.uid('DELAYED_A', sid))).fetchone()[0]
                holding.set()
                time.sleep(DELAY_S)

        def fast():
            holding.wait(timeout=BARRIER_TIMEOUT_S)
            t = time.perf_counter()
            out['b'] = b.execute('select public.claim_listing(%s,%s)', (l_uuid, db.uid('DELAYED_B', sid))).fetchone()[0]
            out['b_ms'] = round((time.perf_counter() - t) * 1000, 1)
        ts = [threading.Thread(target=slow), threading.Thread(target=fast)]
        for t in ts:
            t.start()
        for t in ts:
            t.join()
        a.close()
        b.close()
        claims = db.claims_on(l_uuid)[0]
        active = sum(c[2] == 'ACTIVE' for c in claims)
        rows_out.append(dict(scenario_id=sid, delayed_ngo_answer=out['a']['outcome'], other_ngo_answer=out['b']['outcome'],
                             other_ngo_waited_ms=out['b_ms'], active_claims=active, passed=yes(active == 1)))
    db.conn.close()
    return rows_out


def concurrent_recovery_check(dsn, workers=2):
    """All 100 expired leases are prepared, then two recovery jobs start at the same moment.
    Each claim must be released exactly once."""
    bench = Benchmark()
    db = Database(dsn, uuid.uuid4().hex[:12] + '-concurrent')
    prepared = []
    for s in bench.select(('LEASE_RECOVERY',)):
        sid = s['scenario_id']
        state = bench.claim_states[sid]
        listing_id = bench.one(sid, 'LISTING', 'CLAIMABLE_LISTING')
        prior = bench.one(sid, 'NGO', 'PRIOR_CLAIMANT')
        ago = parse_time(state['replay_at']) - parse_time(bench.listings[listing_id]['created_at'])
        l_uuid, d_uuid = db.listing(bench, listing_id, f'concurrent/{sid}', opened_ago=ago)
        prepared.append(db.prior_claim(sid, 'concurrent', l_uuid, d_uuid, db.ngo(bench, prior), ago))
    counts, errors = [0] * workers, []
    barrier = threading.Barrier(workers)

    def worker(i):
        try:
            with connect(dsn) as c:
                c.execute('set role service_role')
                c.execute("select set_config('request.jwt.claims', %s, false)", (json.dumps({'role': 'service_role'}),))
                barrier.wait(timeout=BARRIER_TIMEOUT_S)
                counts[i] = c.execute('select public.recover_expired_claims(1000)').fetchone()[0]
        except Exception as exc:
            errors.append(safe_error_label(exc))
    ts = [threading.Thread(target=worker, args=(i,)) for i in range(workers)]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    second = db.recover()[0]
    with db.conn.cursor() as cur:
        cur.execute("select count(*) filter (where claim_status='RELEASED') from public.donation_claims "
                    "where claim_id = any(%s)", (prepared,))
        released = cur.fetchone()[0]
        cur.execute("select claim_id, count(*) from public.audit_events where event_type='LEASE_RECOVERY' "
                    "and claim_id = any(%s) group by 1", (prepared,))
        audits = dict(cur.fetchall())
        cur.execute("select count(*) from public.listings l join public.donation_claims c using(listing_id) "
                    "where c.claim_id = any(%s) and l.listing_status='AVAILABLE'", (prepared,))
        reopened = cur.fetchone()[0]
    db.conn.close()
    return dict(expired_claims_prepared=len(prepared), workers=workers, released_per_worker=counts,
                released_total_reported=sum(counts), claims_released=released, listings_reopened=reopened,
                claims_with_exactly_one_recovery_audit=sum(1 for c in prepared if audits.get(c) == 1),
                claims_with_more_than_one_recovery_audit=sum(1 for c in prepared if audits.get(c, 0) > 1),
                repeated_run_released=second, worker_errors=errors,
                passed=(released == len(prepared) and sum(counts) == len(prepared) and second == 0 and not errors
                        and all(audits.get(c) == 1 for c in prepared)))


def main(method, _out):
    """Keep the method entry points on the same guarded runner path."""
    sys.path.insert(0, str(E2))
    from run_e2 import METHODS as selections, main as run_e2
    selection = {value: key for key, value in selections.items()}[method]
    raise SystemExit(run_e2([*sys.argv[1:], '--method', selection]))


def run_method(method, out, dsn, target, preflight_identity, *, reset_conn=None):
    """Rebuild and execute one condition under the runner's cluster lock."""
    spec = METHODS[method]
    if out.exists():
        raise SystemExit(f'Result path already exists; refusing to overwrite: {out}')
    print(f"{spec['title']}: rebuilding the experiment database ...", flush=True)
    identity = setup_database(dsn, target, preflight_identity, reset_conn=reset_conn)
    os.environ['GEOLOCK_E2_TARGET_IDENTITY'] = json.dumps(identity, sort_keys=True)
    out.mkdir(parents=True, exist_ok=False)
    if spec['recovery']:
        pairs = run_geofence(out / 'geofence_check', dsn)
        print(f"  geofence check: {sum(p['correct'] == 'YES' for p in pairs)}/{len(pairs)} pairs correct", flush=True)
    trials, lease, req = run(method, out, dsn)
    if spec['recovery']:
        cc = concurrent_recovery_check(dsn)
        write_json(out / 'details' / 'concurrent_recovery_check.json', cc)
        print(f"  two recovery jobs at once: passed={cc['passed']}", flush=True)
        dl = delayed_request_check(dsn)
        write_csv(out / 'details' / 'delayed_request_check.csv', dl)
        print(f"  delayed request: {sum(r['passed'] == 'YES' for r in dl)}/{len(dl)} passed", flush=True)
    exp = [c for c in lease if c['case'] == 'lease expired']
    done = []
    if trials:
        done.append(f"{sum(t['more_than_one_owner'] == 'YES' for t in trials)}/{len(trials)} contention trials with more than one owner")
    if lease:
        done.append(f"{sum(c['second_ngo_got_listing'] == 'YES' for c in exp)}/{len(exp)} expired leases taken over")
    done.append(f"{sum(r['outcome'] == 'ERROR' for r in req)} errors")
    print(f"{spec['title']}: {', '.join(done)} -> {out}")
