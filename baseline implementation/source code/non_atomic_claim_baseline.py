"""Non-Atomic Claim baseline (baseline 3), run on PostgreSQL.

Method: the unsafe read-then-write claim, e2_baseline.non_atomic_claim_listing()
(postgresql/02_e2_non_atomic_claim_baseline.sql). It reads the listing WITHOUT a lock,
runs the same eligibility checks as the proposed public.claim_listing(), waits a short
race window (default 50 ms, about one app-to-server round trip), then writes the claim
without rechecking. Its claim table has no one-active-claim unique index.

Each CLAIM_COORDINATION scenario is one trial: a fresh AVAILABLE listing and N claim
requests from the scenario's eligible NGOs (reused round-robin when N exceeds them),
one database connection per request, each signed in as its NGO the way Supabase does,
all released together by one barrier. Default N: 2 for scenarios 1-50, 5 for 51-100,
10 for 101-150. A deadlock or serialization failure gets one retry with the same
request ID (contention protocol); a logical conflict is never retried.

A baseline is a comparison METHOD, not an experiment: this script records what the
method does. Comparing it with the proposed protected claim is experiment E2.

Run:  python non_atomic_claim_baseline.py
(uses the Supabase baseline project; --dsn for another database). The database must
be prepared once as in ../postgresql/README.md.
Output: ../result/3_non_atomic_claim/ (summary.md, trials.csv, requests.csv, run_info.json).
"""
import argparse
from collections import defaultdict
import csv
from datetime import datetime, timedelta
import hashlib
import json
from pathlib import Path
import statistics
import sys
import threading
import time
import uuid

import psycopg
from psycopg.conninfo import conninfo_to_dict

FIXTURE_TITLE = 'BENCHMARK E2 FIXTURE'
FIXTURE_EMAIL_DOMAIN = 'geolock-benchmark.test'
TABLES = ('scenarios', 'scenario_members', 'ngos', 'donations', 'donors', 'listings', 'claim_initial_states')
LEASE_MINUTES = 360  # coordination_config.claim_lease_minutes; also built into claim_initial_states
TRANSIENT = (psycopg.errors.DeadlockDetected, psycopg.errors.SerializationFailure)
MAX_TRANSIENT_RETRIES = 1


def read_table(directory, name):
    with (directory / (name + '.csv')).open(encoding='utf-8-sig', newline='') as stream:
        return list(csv.DictReader(stream))


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def parse_time(value):
    return datetime.fromisoformat(value)


class Benchmark:
    """The benchmark tables E2 needs, each checked against the generation manifest."""

    def __init__(self, directory):
        self.directory = Path(directory)
        self.manifest = json.loads((self.directory / 'generation_manifest.json').read_text(encoding='utf-8'))
        self.hashes = {}
        for name in TABLES:
            digest = sha256(self.directory / (name + '.csv'))
            if self.manifest['generated_csv_sha256'][name] != digest:
                raise ValueError(f'Input hash differs from generation manifest: {name}')
            self.hashes[name + '.csv'] = digest
        tables = {name: read_table(self.directory, name) for name in TABLES}
        self.scenarios = sorted(tables['scenarios'], key=lambda r: r['scenario_id'])
        self.members = defaultdict(list)
        for row in tables['scenario_members']:
            self.members[row['scenario_id']].append(row)
        self.ngos = {r['ngo_id']: r for r in tables['ngos']}
        self.donations = {r['donation_id']: r for r in tables['donations']}
        self.donors = {r['donor_id']: r for r in tables['donors']}
        self.listings = {r['listing_id']: r for r in tables['listings']}
        self.claim_states = {r['scenario_id']: r for r in tables['claim_initial_states']}

    def ids(self, sid, kind, role):
        return sorted(r['entity_id'] for r in self.members[sid]
                      if r['entity_type'] == kind and r['scenario_role'] == role)

    def one(self, sid, kind, role):
        values = self.ids(sid, kind, role)
        if len(values) != 1:
            raise ValueError(f'Expected one {role} in {sid}')
        return values[0]

    def select(self, kinds, selection_file=None):
        chosen = None
        if selection_file:
            text = Path(selection_file).read_text(encoding='utf-8-sig').splitlines()
            chosen = ({r['scenario_id'] for r in csv.DictReader(text)} if text and text[0].split(',')[0] == 'scenario_id'
                      else {line.strip() for line in text if line.strip()})
        rows = [s for s in self.scenarios if s['scenario_type'] in kinds
                and (chosen is None or s['scenario_id'] in chosen)]
        if chosen is not None and chosen != {s['scenario_id'] for s in rows}:
            raise ValueError('Selection includes unknown or wrong-type scenarios')
        if not rows:
            raise ValueError('No scenarios selected')
        return rows


def worker_count(scenario_id, override):
    """Default cohorts: CLAIM_COORDINATION 1-50 -> 2 workers, 51-100 -> 5, 101-150 -> 10."""
    if override is not None:
        return override
    ordinal = int(scenario_id.rsplit('-', 1)[1]) - 1
    return (2, 5, 10)[min(ordinal // 50, 2)]


class Fixtures:
    """Creates the benchmark records a trial needs in the baseline database (as the database owner)."""

    def __init__(self, dsn, run_id):
        self.dsn = dsn
        self.run_id = run_id
        self.namespace = uuid.uuid5(uuid.NAMESPACE_URL, f'geolock-e2/{run_id}')
        self.conn = psycopg.connect(dsn, autocommit=True)
        self.users = set()

    def uid(self, kind, key):
        return uuid.uuid5(self.namespace, f'{kind}/{key}')

    def check_separate_database(self, allow_shared):
        """Refuse to write into a database that holds real (non-benchmark) donations."""
        with self.conn.cursor() as cur:
            cur.execute('select count(*) from public.donations where title not like %s', (FIXTURE_TITLE + '%',))
            foreign = cur.fetchone()[0]
        if foreign and not allow_shared:
            raise SystemExit(f'Refusing to run: the database holds {foreign} non-benchmark donations. '
                             'Use a separate baseline database (or --allow-shared-database if you are sure).')

    def check_new_run(self, listing_uuids):
        """Refuse to reuse a run ID for the same method and scenarios (the rows would clash)."""
        with self.conn.cursor() as cur:
            cur.execute('select count(*) from public.listings where listing_id = any(%s)', (list(listing_uuids),))
            if cur.fetchone()[0]:
                raise SystemExit(f'Run ID "{self.run_id}" was already used for this method in this database. '
                                 'Choose a new --run-id (or leave it out to get a new random one).')

    def require_function(self, signature, setup_file):
        with self.conn.cursor() as cur:
            cur.execute('select to_regprocedure(%s) is not null', (signature,))
            if not cur.fetchone()[0]:
                raise SystemExit(f'{signature} is missing: run baseline implementation/postgresql/{setup_file} '
                                 'on the baseline database first (see postgresql/README.md)')

    def _user(self, cur, kind, key, role):
        user_id = self.uid(kind, key)
        if user_id not in self.users:
            cur.execute('insert into auth.users(id, email) values (%s, %s) on conflict (id) do nothing',
                        (user_id, f'{kind.lower()}-{key.lower()}-{self.run_id}@{FIXTURE_EMAIL_DOMAIN}'))
            cur.execute('insert into public.user_profiles(user_id, full_name, role) values (%s, %s, %s) '
                        'on conflict (user_id) do nothing', (user_id, f'{kind} {key}', role))
            self.users.add(user_id)
        return user_id

    def ngo(self, bench, ngo_id):
        """One NGO account per benchmark NGO, location verified at the benchmark coordinates."""
        row = bench.ngos[ngo_id]
        with self.conn.cursor() as cur:
            user_id = self._user(cur, 'NGO', ngo_id, 'NGO')
            cur.execute('insert into public.ngo_profiles(user_id, ngo_name, registration_number, operating_address, '
                        'latitude, longitude, road_node_id, location_verified_at) '
                        'values (%s, %s, %s, %s, %s, %s, %s, clock_timestamp()) on conflict (user_id) do nothing',
                        (user_id, row['ngo_name'], f'{ngo_id}-{self.run_id}', f'Benchmark NGO {ngo_id}',
                         float(row['latitude']), float(row['longitude']), row['road_node_id']))
        return user_id

    def listing(self, bench, listing_id, instance, opened_ago=timedelta(0)):
        """A READY_FOR_PICKUP donation and its AVAILABLE listing on the database clock.

        The listing opened `opened_ago` before now and keeps its benchmark lifetime
        (listing_expires_at - created_at).
        """
        bl = bench.listings[listing_id]
        donation = bench.donations[bl['donation_id']]
        donor = bench.donors[donation['donor_id']]
        lifetime = parse_time(bl['listing_expires_at']) - parse_time(bl['created_at'])
        donation_uuid = self.uid('DONATION', f'{bl["donation_id"]}/{instance}')
        listing_uuid = self.uid('LISTING', f'{listing_id}/{instance}')
        with self.conn.cursor() as cur:
            donor_id = self._user(cur, 'DONOR', donation['donor_id'], 'DONOR')
            cur.execute('insert into public.donor_profiles(user_id) values (%s) on conflict do nothing', (donor_id,))
            cur.execute('select clock_timestamp() - %s', (opened_ago,))
            opened = cur.fetchone()[0]
            cur.execute("insert into public.donations(donation_id, donor_user_id, title, collection_path, "
                        "donation_status, pickup_address, latitude, longitude, pickup_road_node_id, total_weight_kg, "
                        "availability_start, availability_end) "
                        "values (%s, %s, %s, 'DIRECT_PICKUP', 'READY_FOR_PICKUP', %s, %s, %s, %s, %s, %s, %s)",
                        (donation_uuid, donor_id, f'{FIXTURE_TITLE} {bl["donation_id"]}',
                         f'Benchmark donor {donation["donor_id"]}', float(donor['latitude']),
                         float(donor['longitude']), donor['road_node_id'], float(donation['weight_kg']),
                         opened, opened + lifetime))
            cur.execute("insert into public.listings(listing_id, source_type, donation_id, listing_status, "
                        "listing_weight_kg, pickup_latitude, pickup_longitude, pickup_road_node_id, created_at, "
                        "listing_expires_at) values (%s, 'DIRECT_DONATION', %s, 'AVAILABLE', %s, %s, %s, %s, %s, %s)",
                        (listing_uuid, donation_uuid, float(bl['listing_weight_kg']), float(donor['latitude']),
                         float(donor['longitude']), bl['pickup_road_node_id'], opened, opened + lifetime))
        return listing_uuid

    def close(self):
        self.conn.close()


def sign_in(conn, user_uuid):
    """Act as an authenticated Supabase user for the rest of this connection's session."""
    with conn.cursor() as cur:
        cur.execute('set role authenticated')
        cur.execute("select set_config('request.jwt.claims', %s, false)",
                    (json.dumps({'sub': str(user_uuid), 'role': 'authenticated'}),))


def concurrent_requests(dsn, requests, sql, extra_params=()):
    """Send every request at the same moment, each on its own signed-in connection.

    Connections are opened and signed in BEFORE the barrier, so after the barrier each
    worker runs exactly one statement (one transaction). Returns the request dicts with
    outcome, reason_code, claim_id, error and latency_ms added.
    """
    connections = []
    try:
        for item in requests:
            conn = psycopg.connect(dsn, autocommit=True)
            connections.append(conn)
            sign_in(conn, item['ngo_uuid'])
        barrier = threading.Barrier(len(requests))
        results = [None] * len(requests)

        def worker(i, item):
            record = dict(item, retries=0, first_error='')
            params = (item['listing_uuid'], item['request_uuid']) + tuple(extra_params)
            barrier.wait(timeout=60)
            started = time.perf_counter()
            while True:
                try:
                    with connections[i].cursor() as cur:
                        cur.execute(sql, params)
                        out = cur.fetchone()[0]
                    record.update(outcome=out.get('outcome'), reason_code=out.get('reason_code') or '',
                                  claim_id=out.get('claim_id') or '', error='')
                    break
                except TRANSIENT as exc:
                    # Contention protocol: a transient database failure (deadlock or
                    # serialization failure, nothing committed) gets ONE retry with the SAME
                    # request ID. Logical conflicts are never retried.
                    if record['retries'] >= MAX_TRANSIENT_RETRIES:
                        record.update(outcome='ERROR', reason_code='', claim_id='', error=str(exc).splitlines()[0])
                        break
                    record['retries'] += 1
                    record['first_error'] = type(exc).__name__
                except psycopg.Error as exc:
                    record.update(outcome='ERROR', reason_code='', claim_id='', error=str(exc).splitlines()[0])
                    break
            record['latency_ms'] = round((time.perf_counter() - started) * 1000, 3)
            results[i] = record

        threads = [threading.Thread(target=worker, args=(i, item)) for i, item in enumerate(requests)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        return results
    finally:
        for conn in connections:
            conn.close()


def write_csv(path, rows, fields=None):
    with path.open('w', encoding='utf-8-sig', newline='') as stream:
        writer = csv.DictWriter(stream, fieldnames=fields or list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def request_row(r):
    """One CSV row per claim request (UUIDs as text, internal handles dropped)."""
    return dict(scenario_id=r['scenario_id'], listing_id=r['listing_id'], workers=r['workers'],
                request_no=r['request_no'], ngo_id=r['ngo_id'], request_id=str(r['request_uuid']),
                outcome=r['outcome'], reason_code=r['reason_code'], claim_id=str(r['claim_id'] or ''),
                transient_retries=r['retries'], first_transient_error=r['first_error'], error=r['error'],
                latency_ms=r['latency_ms'])


# Default database: the Supabase project prepared for the baselines (see postgresql/README.md).
# Inside a connection string the "@" in the password must be written as %40.
DEFAULT_DSN = ('postgresql://postgres.wwmwjudfzislprjsekti:Geolock%402027'
               '@aws-0-ap-southeast-1.pooler.supabase.com:5432/postgres')
DB_LABEL = ''


def resolve_dsn(dsn):
    """--dsn if given, otherwise the Supabase baseline project."""
    global DB_LABEL
    dsn = dsn or DEFAULT_DSN
    host = conninfo_to_dict(dsn).get('host', 'localhost')
    if 'supabase' in host:
        DB_LABEL = f'Supabase project ({host}); network delay is included in response times'
    elif host.startswith('/') or host in ('localhost', '127.0.0.1', '::1'):
        DB_LABEL = 'local PostgreSQL on this computer'
    else:
        DB_LABEL = f'PostgreSQL at {host}'
    return dsn


def parser_with_common_options(description):
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=description, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--dsn', default=None,
                        help='Connection string of another baseline database prepared as in postgresql/README.md '
                             '(default: the Supabase baseline project), '
                             'e.g. postgresql://postgres:PASSWORD@localhost:5432/geolock_baseline')
    parser.add_argument('--dataset-dir', type=Path, default=root / 'benchmark dataset' / 'dataset')
    parser.add_argument('--output-dir', type=Path, default=root / 'baseline implementation' / 'result' / FOLDER)
    parser.add_argument('--scenario-ids', type=Path, help='CSV with a scenario_id column, or one ID per line')
    parser.add_argument('--workers', type=int,
                        help='Concurrent requests in every contention trial (>= 2), e.g. 50 for a stress test; '
                             'default: 50 trials each at 2, 5 and 10')
    parser.add_argument('--run-id', default=None, help='Label for this run (default: a new random ID)')
    parser.add_argument('--allow-shared-database', action='store_true',
                        help='Run even if the database holds non-benchmark donations (not recommended)')
    return parser


def check_workers(parser, args):
    if args.workers is not None and args.workers < 2:
        parser.error('--workers must be at least 2')


def median(values):
    return statistics.median(values) if values else float('nan')


def contention_table(trials, requests):
    """Markdown rows per worker count for the contention trials."""
    lines = ['| Concurrent requests per trial | Trials | Requests | SUCCESS | CONFLICT | ERROR | Retries | '
             'Trials with exactly 1 committed claim | Trials with a duplicate claim | Median latency (ms) |',
             '| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |']
    groups = sorted({t['workers'] for t in trials})
    for w in groups + ['All']:
        ts = [t for t in trials if w == 'All' or t['workers'] == w]
        rs = [r for r in requests if r['scenario_id'] in {t['scenario_id'] for t in ts}]
        lines.append(f"| {w} | {len(ts)} | {len(rs)} | {sum(r['outcome'] == 'SUCCESS' for r in rs)} | "
                     f"{sum(r['outcome'] == 'CONFLICT' for r in rs)} | {sum(r['outcome'] == 'ERROR' for r in rs)} | "
                     f"{sum(r['transient_retries'] for r in rs)} | "
                     f"{sum(t['committed_active_claims'] == 1 for t in ts)} | "
                     f"{sum(t['duplicate_committed_claim'] for t in ts)} | "
                     f"{median([r['latency_ms'] for r in rs]):,.0f} |")
    return lines


OUTCOMES = [
    ('SUCCESS', 'The function answered that this NGO now holds the listing.'),
    ('CONFLICT', 'The function answered that the listing is already claimed by another NGO (reason code CLAIM_CONFLICT).'),
    ('INELIGIBLE', 'The NGO failed an eligibility rule (geofence, location, listing expired).'),
    ('ERROR', 'The database aborted the request (e.g. deadlock) and it also failed its one retry; '
              'nothing was committed for it.'),
]

METHOD = 'non_atomic_claim'
FOLDER = '3_non_atomic_claim'
CALL = 'select e2_baseline.non_atomic_claim_listing(%s, %s, %s)'
TRIAL_FIELDS = ['scenario_id', 'listing_id', 'workers', 'success_responses', 'conflict_responses',
                'ineligible_responses', 'error_responses', 'transient_retries', 'committed_active_claims',
                'committed_ngo_identities', 'duplicate_committed_claim', 'listing_status_after']


CLAIM_REFS = {
    'gray76': 'Gray, J. N., Lorie, R. A., Putzolu, G. R., & Traiger, I. L. (1976). Granularity of locks and degrees of consistency in a shared data base. In G. M. Nijssen (Ed.), *Modelling in Data Base Management Systems* (pp. 365-394). North-Holland. *(in the report reference list)*',
    'bg81': 'Bernstein, P. A., & Goodman, N. (1981). Concurrency control in distributed database systems. *ACM Computing Surveys*, 13(2), 185-221. https://doi.org/10.1145/356842.356846 *(in the report reference list)*',
    'berenson': 'Berenson, H., Bernstein, P., Gray, J., Melton, J., O\'Neil, E., & O\'Neil, P. (1995). A critique of ANSI SQL isolation levels. *Proceedings of ACM SIGMOD 1995*, 1-10. https://doi.org/10.1145/223784.223785 (the "lost update" anomaly) *(not yet in the report: add it if you cite it)*',
    'pgiso': 'PostgreSQL Global Development Group. (2026a). Transaction isolation. *PostgreSQL 18 documentation*. https://www.postgresql.org/docs/18/transaction-iso.html *(in the report reference list)*',
}
GUIDE_HOW = [
    'For each trial, create a new AVAILABLE listing copied from the benchmark listing.',
    'N NGOs (2, 5 or 10) each open their own database connection, sign in, and press "claim" at the same moment.',
    'Each request reads the listing WITHOUT locking it and sees AVAILABLE; it checks the NGO is eligible.',
    'It waits the race window (default 50 ms, standing for the gap between the app reading and writing).',
    'It writes its claim and marks the listing CLAIMED, without checking again. No unique index stops a second claim.',
    'After the trial, the script counts how many claims are actually stored for the listing.',
]
GUIDE_EXPECT = [
    'This is the classic read-then-write race on shared data: two transactions both read the listing as '
    'available before either commits, and each then writes its own claim. Database research treats it as a '
    'concurrency-control problem that needs locking or an equivalent rule [1, 2]; it is known as the '
    '"lost update" anomaly [3]. PostgreSQL\'s default READ COMMITTED isolation does not stop it unless the code '
    'locks the row or a constraint rejects the second write [4].',
    'Here every request reads before any request writes, so the expected result is that every request '
    'succeeds: N claims stored per trial and a duplicate in every trial (duplicate committed-claim rate '
    '100%). This failure is the point of the baseline: it shows what goes wrong without protection.',
]
GUIDE_READ = [
    '**Requests answered SUCCESS**: how many NGOs were told "the listing is yours".',
    '**Claims committed in the database**: what is really stored. A correct system stores at most 1 per trial.',
    '**Duplicate committed-claim rate** is the key number (main safety metric): the share of '
    'trials with more than one committed active claim. 0% means safe; anything above 0% means two or more NGOs '
    'would drive to the same food.',
    'The table by number of concurrent requests shows the effect of more NGOs at once. **Median latency** is the '
    'time from pressing claim to getting the answer (it includes the 50 ms race window).',
    '`results_per_scenario.csv` has one row per trial (`more_than_one_owner` = YES marks a duplicate); '
    '`details/requests.csv` has one row per request.',
]
GUIDE_REFS = ['[1] ' + CLAIM_REFS['gray76'], '[2] ' + CLAIM_REFS['bg81'], '[3] ' + CLAIM_REFS['berenson'],
              '[4] ' + CLAIM_REFS['pgiso']]


def guide_lines():
    lines = ['', '## How the method works', ''] + [f'{i}. {t}' for i, t in enumerate(GUIDE_HOW, 1)]
    lines += ['', '## What to expect', ''] + [f'- {t}' for t in GUIDE_EXPECT]
    lines += ['', '## How to read the results', ''] + [f'- {t}' for t in GUIDE_READ]
    lines += ['', '## References', ''] + [f'- {t}' for t in GUIDE_REFS]
    return lines


def write_run_info(path, title, rows):
    """Plain record of what produced the results (only needed to repeat or audit the run)."""
    lines = [f'# Run information: {title}', '',
             'This file only records what produced the results in this folder, so the run can be repeated '
             'and checked. You do not need it to read the results.', '',
             '| Item | Value |', '| --- | --- |'] + [f'| {a} | {b} |' for a, b in rows] + ['']
    path.write_text('\n'.join(lines), encoding='utf-8')


def common_run_rows(manifest_path, script, command):
    manifest = Path(manifest_path)
    version = json.loads(manifest.read_text(encoding='utf-8'))['benchmark_version']
    manifest_hash = hashlib.sha256(manifest.read_bytes()).hexdigest()[:16]
    script_hash = hashlib.sha256(Path(script).read_bytes()).hexdigest()[:16]
    return [('Run at', datetime.now().astimezone().strftime('%Y-%m-%d %H:%M %Z')),
            ('Benchmark', f'{version} (generation_manifest.json SHA-256 {manifest_hash}...; '
                          'every input CSV was checked against this manifest)'),
            ('Script', f'`{Path(script).name}` (SHA-256 {script_hash}...)'),
            ('Python', sys.version.split()[0]),
            ('Command to repeat', f'`{command}`')]


def database_rows(conn):
    with conn.cursor() as cur:
        cur.execute("select version(), current_setting('default_transaction_isolation')")
        server, isolation = cur.fetchone()
    return [('Database', DB_LABEL), ('PostgreSQL', server.split(' on ')[0]), ('Transaction isolation', isolation)]


def yes(value):
    return 'YES' if value else 'NO'


def readable_trials(trials, requests):
    by = defaultdict(list)
    for r in requests:
        by[r['scenario_id']].append(r['latency_ms'])
    return [dict(scenario_id=t['scenario_id'], listing_id=t['listing_id'], ngos_competing=t['workers'],
                 told_success=t['success_responses'], told_already_claimed=t['conflict_responses'],
                 told_not_eligible=t['ineligible_responses'], failed_with_error=t['error_responses'],
                 retries_after_deadlock=t['transient_retries'], claims_stored=t['committed_active_claims'],
                 more_than_one_owner=yes(t['duplicate_committed_claim']), listing_status_after=t['listing_status_after'],
                 median_response_ms=round(statistics.median(by[t['scenario_id']]), 1),
                 slowest_response_ms=round(max(by[t['scenario_id']]), 1)) for t in trials]


def readable_requests(requests):
    return [dict(scenario_id=r['scenario_id'], listing_id=r['listing_id'], ngos_competing=r['workers'],
                 request_number=r['request_no'], ngo_id=r['ngo_id'], answer=r['outcome'], reason_code=r['reason_code'],
                 retries=r['transient_retries'], error_message=r['error'], response_ms=round(r['latency_ms'], 1),
                 request_id=r['request_id'], claim_id=r['claim_id']) for r in requests]


TRIAL_COLUMNS = [
    ('scenario_id', 'Benchmark contention scenario (one listing, several NGOs claiming at the same moment)'),
    ('listing_id', 'Benchmark listing that was copied into the database for this trial'),
    ('ngos_competing', 'How many NGOs pressed "claim" at the same moment (2, 5 or 10)'),
    ('told_success', 'NGOs told "the listing is yours"'),
    ('told_already_claimed', 'NGOs told "already claimed" (CONFLICT)'),
    ('told_not_eligible', 'NGOs refused by an eligibility rule'),
    ('failed_with_error', 'Requests aborted by the database (deadlock) even after one retry; nothing was stored for them'),
    ('retries_after_deadlock', 'Retries used after a deadlock or serialization failure'),
    ('claims_stored', 'Active claims actually stored for the listing afterwards (correct = 1)'),
    ('more_than_one_owner', 'YES if more than one NGO owns the listing (a duplicate claim)'),
    ('listing_status_after', 'Listing status afterwards (CLAIMED)'),
    ('median_response_ms', 'Middle response time of the requests in this trial'),
    ('slowest_response_ms', 'Slowest response time in this trial'),
]
REQUEST_NOTE = ('`details/requests.csv`: one row per request (NGO, answer, reason code, retries, error message, response '
                'time in ms, request and claim IDs).')


def write_summary(path, bench, trials, requests, race_window_ms):
    dup = sum(t['duplicate_committed_claim'] for t in trials)
    committed = sum(t['committed_active_claims'] for t in trials)
    errors = sum(r['outcome'] == 'ERROR' for r in requests)
    lines = ['# Non-Atomic Claim (baseline 3)', '',
             f"Benchmark {bench.manifest['benchmark_version']}, run on PostgreSQL ({DB_LABEL}). This describes this method on its own; "
             'comparing it with the proposed protected claim is experiment E2.', '',
             '**Method.** Read the listing without a lock, check eligibility, wait a race window of '
             f'{race_window_ms} ms, then write the claim without checking again. There is no one-active-claim '
             'unique index. Several NGOs press "claim" on the same listing at the same moment.', '',
             '| Result | Value | Meaning |', '| --- | --- | --- |',
             f'| Contention trials | {len(trials)} | One new listing per trial, claimed at the same moment by 2, 5 or 10 NGOs |',
             f'| Claim requests | {len(requests)} | One database connection per request |',
             f"| Requests answered SUCCESS | {sum(r['outcome'] == 'SUCCESS' for r in requests)} | Each of these NGOs was told it owns the listing |",
             f'| Claims committed in the database | {committed} | A listing should never have more than 1 |',
             f'| **Duplicate committed-claim rate** (main safety metric) | {dup} of {len(trials)} trials ({dup / len(trials):.0%}) | '
             'Trials where more than one NGO owns the listing; the ownership error this method allows |',
             f'| Requests that failed with a database error | {errors} | |', '',
             '## By number of concurrent requests', ''] + contention_table(trials, requests)
    lines += ['', '## Request outcomes', '', '| Outcome | Meaning |', '| --- | --- |']
    lines += [f'| {a} | {b} |' for a, b in OUTCOMES]
    lines += guide_lines()
    lines += ['', '## Files', '', '| File | Content |', '| --- | --- |',
              '| `results_per_scenario.csv` | **The main result.** One row per contention trial. |',
              '| `details/requests.csv` | Every single claim request (for checking response times and errors). |',
              '| `run_info.md` | What produced this run (date, database, PostgreSQL version, script fingerprint, command). |',
              '', '### Columns of results_per_scenario.csv', '', '| Column | Meaning |', '| --- | --- |']
    lines += [f'| `{a}` | {b} |' for a, b in TRIAL_COLUMNS]
    lines += ['', REQUEST_NOTE, '']
    path.write_text('\n'.join(lines), encoding='utf-8')


def main():
    parser = parser_with_common_options(__doc__)
    parser.add_argument('--race-window-ms', type=int, default=50,
                        help='Pause between the availability read and the claim write (default 50 ms; 0 = no pause)')
    args = parser.parse_args()
    check_workers(parser, args)
    bench = Benchmark(args.dataset_dir)
    scenarios = bench.select(('CLAIM_COORDINATION',), args.scenario_ids)
    args.dsn = resolve_dsn(args.dsn)
    run_id = args.run_id or uuid.uuid4().hex[:12]
    fx = Fixtures(args.dsn, run_id)
    fx.check_separate_database(args.allow_shared_database)
    fx.check_new_run(fx.uid('LISTING', f"{bench.one(s['scenario_id'], 'LISTING', 'CLAIMABLE_LISTING')}/{METHOD}/{s['scenario_id']}")
                     for s in scenarios)
    fx.require_function('e2_baseline.non_atomic_claim_listing(uuid,uuid,integer)', '02_e2_non_atomic_claim_baseline.sql')

    trials, requests = [], []
    for scenario in scenarios:
        sid = scenario['scenario_id']
        listing_id = bench.one(sid, 'LISTING', 'CLAIMABLE_LISTING')
        ngos = bench.ids(sid, 'NGO', 'POTENTIAL_REQUESTER_UNASSESSED')
        workers = worker_count(sid, args.workers)
        listing_uuid = fx.listing(bench, listing_id, f'{METHOD}/{sid}')
        batch = [dict(scenario_id=sid, listing_id=listing_id, workers=workers, request_no=i + 1,
                      ngo_id=ngos[i % len(ngos)], ngo_uuid=fx.ngo(bench, ngos[i % len(ngos)]),
                      listing_uuid=listing_uuid, request_uuid=fx.uid('REQUEST', f'{METHOD}/{sid}/{i + 1}'))
                 for i in range(workers)]
        done = [request_row(r) for r in concurrent_requests(args.dsn, batch, CALL, (args.race_window_ms,))]
        with fx.conn.cursor() as cur:
            cur.execute("select ngo_user_id from e2_baseline.naive_claims where listing_id = %s and claim_status = 'ACTIVE'",
                        (listing_uuid,))
            committed = [row[0] for row in cur.fetchall()]
            cur.execute('select listing_status from public.listings where listing_id = %s', (listing_uuid,))
            status_after = cur.fetchone()[0]
        trials.append(dict(scenario_id=sid, listing_id=listing_id, workers=workers,
                           success_responses=sum(r['outcome'] == 'SUCCESS' for r in done),
                           conflict_responses=sum(r['outcome'] == 'CONFLICT' for r in done),
                           ineligible_responses=sum(r['outcome'] == 'INELIGIBLE' for r in done),
                           error_responses=sum(r['outcome'] == 'ERROR' for r in done),
                           transient_retries=sum(r['transient_retries'] for r in done),
                           committed_active_claims=len(committed), committed_ngo_identities=len(set(committed)),
                           duplicate_committed_claim=int(len(committed) > 1), listing_status_after=status_after))
        requests.extend(done)

    db_rows = database_rows(fx.conn)
    fx.close()
    out = args.output_dir
    (out / 'details').mkdir(parents=True, exist_ok=True)
    write_csv(out / 'results_per_scenario.csv', readable_trials(trials, requests))
    write_csv(out / 'details' / 'requests.csv', readable_requests(requests))
    rows = common_run_rows(args.dataset_dir / 'generation_manifest.json', __file__,
                           f'python {Path(__file__).name}' + (' --dsn ...' if args.dsn != DEFAULT_DSN else ''))
    rows += db_rows + [
        ('Run ID', run_id),
        ('Scenarios run', f'{len(trials)} contention trials' + (' (selected with --scenario-ids)' if args.scenario_ids else ' (all)')),
        ('Settings', (f'{args.workers} NGOs per trial' if args.workers else '2, 5 and 10 NGOs per trial (50 trials each)')
         + f'; race window {args.race_window_ms} ms; one retry after a deadlock')]
    write_run_info(out / 'run_info.md', 'Non-Atomic Claim (baseline 3)', rows)
    write_summary(out / 'summary.md', bench, trials, requests, args.race_window_ms)
    info = dict(trials_with_duplicate_claim=sum(t['duplicate_committed_claim'] for t in trials),
                committed_active_claims=sum(t['committed_active_claims'] for t in trials))
    print(f"Non-Atomic Claim: {info['trials_with_duplicate_claim']}/{len(trials)} trials with a duplicate claim, "
          f"{info['committed_active_claims']} claims committed -> {out / 'summary.md'}")


if __name__ == '__main__':
    main()
