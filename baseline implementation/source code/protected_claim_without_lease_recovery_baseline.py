"""Protected Claim without Lease Recovery (baseline 4, experiment E2, RQ2), on PostgreSQL.

Calls the real public.claim_listing() (row lock, recheck, one-active-claim index,
idempotent request ID); public.recover_expired_claims() is never run.

  * CLAIM_COORDINATION (150): one new listing per trial, 2 / 5 / 10 NGOs claim it at the
    same moment (scenarios 1-50 / 51-100 / 101-150).
  * LEASE_RECOVERY (100) and LEASE_ACTIVE_VERIFICATION (25): the listing already has a
    claim whose lease has expired (or is still running); another NGO then claims it.

Run:  python protected_claim_without_lease_recovery_baseline.py
      (default: the Supabase baseline project in DEFAULT_DSN; --dsn or GEOLOCK_BASELINE_DSN
      for another database). Database prepared as in ../postgresql/README.md.
Output: ../result/4_protected_claim_without_lease_recovery/
"""
import argparse
from collections import defaultdict
import csv
from datetime import datetime, timedelta
import hashlib
import json
import os
import re
from pathlib import Path
import statistics
import sys
import threading
import time
import uuid

import psycopg
from psycopg.conninfo import conninfo_to_dict

METHOD = 'protected_claim_without_lease_recovery'
FOLDER = '4_protected_claim_without_lease_recovery'
TITLE = 'Protected Claim without Lease Recovery'
CALL = 'select public.claim_listing(%s, %s)'
ACCOUNT_DOMAIN = 'geolock.example.com'
ACCOUNT_NAMESPACE = uuid.uuid5(uuid.NAMESPACE_URL, 'geolock-baseline/accounts')
TABLES = ('scenarios', 'scenario_members', 'ngos', 'donations', 'donors', 'listings', 'claim_initial_states',
          'road_distance_matrix')
GEOFENCE_KM = 20.0
LEASE_MINUTES = 360
TRANSIENT = (psycopg.errors.DeadlockDetected, psycopg.errors.SerializationFailure)
MAX_TRANSIENT_RETRIES = 1
DEFAULT_DSN = 'postgresql://postgres.qvjxanyyidndqgyxewvv:GeolockHub112026@aws-0-ap-southeast-1.pooler.supabase.com:5432/postgres'
DB_LABEL = ''


def read_table(directory, name):
    with (directory / (name + '.csv')).open(encoding='utf-8-sig', newline='') as stream:
        return list(csv.DictReader(stream))


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def parse_time(value):
    return datetime.fromisoformat(value)


class Benchmark:
    """Benchmark tables used by E2, each checked against generation_manifest.json."""

    def __init__(self, directory):
        self.directory = Path(directory)
        self.manifest = json.loads((self.directory / 'generation_manifest.json').read_text(encoding='utf-8'))
        for name in TABLES:
            if self.manifest['generated_csv_sha256'][name] != sha256(self.directory / (name + '.csv')):
                raise ValueError(f'Input hash differs from generation manifest: {name}')
        tables = {name: read_table(self.directory, name) for name in TABLES}
        self.scenarios = sorted(tables['scenarios'], key=lambda r: r['scenario_id'])
        self.members = defaultdict(list)
        for row in tables['scenario_members']:
            self.members[row['scenario_id']].append(row)
        self.ngos = {r['ngo_id']: r for r in tables['ngos']}
        self.ngo_state = {r['ngo_id']: r['state'] for r in self.manifest['provenance']['ngos']}
        self.donations = {r['donation_id']: r for r in tables['donations']}
        self.donors = {r['donor_id']: r for r in tables['donors']}
        self.listings = {r['listing_id']: r for r in tables['listings']}
        self.claim_states = {r['scenario_id']: r for r in tables['claim_initial_states']}
        self.road = {(r['from_node_id'], r['to_node_id']): r for r in tables['road_distance_matrix']}

    def ids(self, sid, kind, role):
        return sorted(r['entity_id'] for r in self.members[sid]
                      if r['entity_type'] == kind and r['scenario_role'] == role)

    def one(self, sid, kind, role):
        values = self.ids(sid, kind, role)
        if len(values) != 1:
            raise ValueError(f'Expected one {role} in {sid}')
        return values[0]

    def road_km(self, ngo_id, listing_id):
        """Directed NGO-to-pickup road distance (None = no route)."""
        row = self.road.get((self.ngos[ngo_id]['road_node_id'], self.listings[listing_id]['pickup_road_node_id']))
        return float(row['road_distance_km']) if row and row['route_available_flag'] == '1' else None

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
    """Scenarios 1-50 -> 2 NGOs, 51-100 -> 5, 101-150 -> 10 (report Table A.4)."""
    if override is not None:
        return override
    return (2, 5, 10)[min((int(scenario_id.rsplit('-', 1)[1]) - 1) // 50, 2)]


class Database:
    """Writes the accounts, donations, listings and earlier claims a trial starts from."""

    def __init__(self, dsn, run_id):
        self.run_id = run_id
        self.namespace = uuid.uuid5(uuid.NAMESPACE_URL, f'geolock-e2/{run_id}')
        self.conn = psycopg.connect(dsn, autocommit=True)
        self.users = set()

    def uid(self, kind, key):
        return uuid.uuid5(self.namespace, f'{kind}/{key}')

    def check_baseline_database(self, allow_shared):
        """Stop if the database holds donations from accounts other than the baseline accounts."""
        with self.conn.cursor() as cur:
            cur.execute('select count(*) from public.donations d left join auth.users u on u.id = d.donor_user_id '
                        'where u.email is null or u.email not like %s', ('%@' + ACCOUNT_DOMAIN,))
            other = cur.fetchone()[0]
        if other and not allow_shared:
            raise SystemExit(f'Refusing to run: the database holds {other} donations from other accounts. '
                             'Use the baseline database (or --allow-shared-database if you are sure).')

    def check_new_run(self, listing_uuids):
        with self.conn.cursor() as cur:
            cur.execute('select count(*) from public.listings where listing_id = any(%s)', (list(listing_uuids),))
            if cur.fetchone()[0]:
                raise SystemExit(f'Run ID "{self.run_id}" was already used in this database; choose a new --run-id.')

    def require_function(self, signature, setup_file):
        with self.conn.cursor() as cur:
            cur.execute('select to_regprocedure(%s) is not null', (signature,))
            if not cur.fetchone()[0]:
                raise SystemExit(f'{signature} is missing: run postgresql/{setup_file} first (postgresql/README.md)')

    def require_claim_fix(self):
        """Stop if claim_listing() still locks FOR UPDATE: E2 must use the same function as the proposed method."""
        with self.conn.cursor() as cur:
            cur.execute("select pg_get_functiondef('public.claim_listing(uuid,uuid)'::regprocedure)")
            body = cur.fetchone()[0]
        if not re.search(r'for\s+no\s+key\s+update', body, re.IGNORECASE):
            raise SystemExit('public.claim_listing() in this database still locks the listing FOR UPDATE '
                             '(deadlocks with 5-10 NGOs). Apply the FOR NO KEY UPDATE fix '
                             '(postgresql/README.md), then run again.')

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
        """One permanent account per NGO, location verified at its benchmark coordinates."""
        row = bench.ngos[ngo_id]
        with self.conn.cursor() as cur:
            user_id = self._user(cur, ngo_id, row['ngo_name'], 'NGO')
            cur.execute('insert into public.ngo_profiles(user_id, ngo_name, operating_address, latitude, longitude, '
                        'road_node_id, location_verified_at) values (%s, %s, %s, %s, %s, %s, clock_timestamp()) '
                        'on conflict (user_id) do nothing',
                        (user_id, row['ngo_name'], f"{bench.ngo_state[ngo_id]}, Malaysia",
                         float(row['latitude']), float(row['longitude']), row['road_node_id']))
        return user_id

    def listing(self, bench, listing_id, instance, opened_ago=timedelta(0)):
        """A READY_FOR_PICKUP donation and its AVAILABLE listing, opened `opened_ago` before now."""
        bl = bench.listings[listing_id]
        donation = bench.donations[bl['donation_id']]
        donor = bench.donors[donation['donor_id']]
        lifetime = parse_time(bl['listing_expires_at']) - parse_time(bl['created_at'])
        donation_uuid = self.uid('DONATION', f'{bl["donation_id"]}/{instance}')
        listing_uuid = self.uid('LISTING', f'{listing_id}/{instance}')
        with self.conn.cursor() as cur:
            donor_id = self._user(cur, donation['donor_id'], f"Donor {donation['donor_id']}", 'DONOR')
            cur.execute('insert into public.donor_profiles(user_id) values (%s) on conflict do nothing', (donor_id,))
            cur.execute('select clock_timestamp() - %s', (opened_ago,))
            opened = cur.fetchone()[0]
            cur.execute("insert into public.donations(donation_id, donor_user_id, title, collection_path, "
                        "donation_status, pickup_address, latitude, longitude, pickup_road_node_id, total_weight_kg, "
                        "availability_start, availability_end) "
                        "values (%s, %s, %s, 'DIRECT_PICKUP', 'READY_FOR_PICKUP', %s, %s, %s, %s, %s, %s, %s)",
                        (donation_uuid, donor_id, f"{donation['category'].capitalize()} donation {bl['donation_id']}",
                         f"Home pickup, donor {donation['donor_id']}", float(donor['latitude']),
                         float(donor['longitude']), donor['road_node_id'], float(donation['weight_kg']),
                         opened, opened + lifetime))
            cur.execute("insert into public.listings(listing_id, source_type, donation_id, listing_status, "
                        "listing_weight_kg, pickup_latitude, pickup_longitude, pickup_road_node_id, created_at, "
                        "listing_expires_at) values (%s, 'DIRECT_DONATION', %s, 'AVAILABLE', %s, %s, %s, %s, %s, %s)",
                        (listing_uuid, donation_uuid, float(bl['listing_weight_kg']), float(donor['latitude']),
                         float(donor['longitude']), bl['pickup_road_node_id'], opened, opened + lifetime))
        return listing_uuid

    def prior_claim(self, sid, listing_uuid, holder_uuid, claimed_ago):
        """The earlier claim of a lease case, written as claim_listing() writes it (360-minute lease)."""
        request_uuid, claim_uuid = self.uid('PRIOR_REQUEST', sid), self.uid('PRIOR_CLAIM', sid)
        with self.conn.transaction(), self.conn.cursor() as cur:
            cur.execute('select clock_timestamp() - %s', (claimed_ago,))
            issued = cur.fetchone()[0]
            cur.execute("insert into public.claim_requests(request_id, listing_id, ngo_user_id, request_digest, "
                        "created_at) values (%s, %s, %s, md5(%s), %s)",
                        (request_uuid, listing_uuid, holder_uuid, f'{listing_uuid}:{holder_uuid}', issued))
            cur.execute("insert into public.donation_claims(claim_id, listing_id, ngo_user_id, request_id, "
                        "claim_status, claimed_at) values (%s, %s, %s, %s, 'ACTIVE', %s)",
                        (claim_uuid, listing_uuid, holder_uuid, request_uuid, issued))
            cur.execute("update public.claim_requests set outcome = 'SUCCESS', result_claim_id = %s, "
                        "completed_at = %s where request_id = %s", (claim_uuid, issued, request_uuid))
            cur.execute("insert into public.claim_leases(claim_id, lease_status, issued_at, expires_at) "
                        "values (%s, 'ACTIVE', %s, %s)", (claim_uuid, issued, issued + timedelta(minutes=LEASE_MINUTES)))
            cur.execute("update public.listings set listing_status = 'CLAIMED', listing_version = listing_version + 1 "
                        "where listing_id = %s", (listing_uuid,))
            cur.execute("insert into public.pickup_tasks(claim_id, listing_id, ngo_user_id, pickup_road_node_id, "
                        "load_kg, created_at) select %s, listing_id, %s, pickup_road_node_id, listing_weight_kg, %s "
                        "from public.listings where listing_id = %s", (claim_uuid, holder_uuid, issued, listing_uuid))
        return claim_uuid

    def claims_on(self, listing_uuid):
        with self.conn.cursor() as cur:
            cur.execute('select c.claim_id, c.ngo_user_id, c.claim_status from public.donation_claims c '
                        'where c.listing_id = %s', (listing_uuid,))
            rows = cur.fetchall()
            cur.execute('select listing_status from public.listings where listing_id = %s', (listing_uuid,))
            return rows, cur.fetchone()[0]

    def server(self):
        with self.conn.cursor() as cur:
            cur.execute("select version(), current_setting('default_transaction_isolation')")
            version, isolation = cur.fetchone()
        return version.split(' on ')[0], isolation


def sign_in(conn, user_uuid):
    """Act as a signed-in Supabase user (role authenticated + request.jwt.claims)."""
    with conn.cursor() as cur:
        cur.execute('set role authenticated')
        cur.execute("select set_config('request.jwt.claims', %s, false)",
                    (json.dumps({'sub': str(user_uuid), 'role': 'authenticated'}),))


def send_together(dsn, requests, sql, extra=()):
    """Send the requests at the same moment, one signed-in connection each.

    Road eligibility (<= 20 km, report Table A.4) is checked first; an ineligible NGO is not sent.
    A deadlock or serialization failure gets one retry with the same request ID; a conflict is never retried.
    """
    for item in requests:
        km = item['road_distance_km']
        item.update(retries=0, error='', latency_ms=0.0, claim_id='', outcome='', reason_code='')
        if km is None or km > GEOFENCE_KM:
            item.update(outcome='INELIGIBLE', reason_code='ROUTE_UNAVAILABLE' if km is None else 'OUTSIDE_GEOFENCE')
    sent = [item for item in requests if not item['outcome']]
    connections = []
    try:
        for item in sent:
            conn = psycopg.connect(dsn, autocommit=True)
            connections.append(conn)
            sign_in(conn, item['ngo_uuid'])
        barrier = threading.Barrier(max(len(sent), 1))

        def worker(i, item):
            barrier.wait(timeout=60)
            started = time.perf_counter()
            while True:
                try:
                    with connections[i].cursor() as cur:
                        cur.execute(sql, (item['listing_uuid'], item['request_uuid']) + tuple(extra))
                        out = cur.fetchone()[0]
                    item.update(outcome=out.get('outcome'), reason_code=out.get('reason_code') or '',
                                claim_id=out.get('claim_id') or '')
                    break
                except TRANSIENT as exc:
                    if item['retries'] >= MAX_TRANSIENT_RETRIES:
                        item.update(outcome='ERROR', error=str(exc).splitlines()[0])
                        break
                    item['retries'] += 1
                except psycopg.Error as exc:
                    item.update(outcome='ERROR', error=str(exc).splitlines()[0])
                    break
            item['latency_ms'] = round((time.perf_counter() - started) * 1000, 1)

        threads = [threading.Thread(target=worker, args=(i, item)) for i, item in enumerate(sent)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        return requests
    finally:
        for conn in connections:
            conn.close()


def write_csv(path, rows):
    with path.open('w', encoding='utf-8-sig', newline='') as stream:
        writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def yes(value):
    return 'YES' if value else 'NO'


def median(values):
    return statistics.median(values) if values else 0.0


def resolve_dsn(dsn):
    global DB_LABEL
    dsn = dsn or os.environ.get('GEOLOCK_BASELINE_DSN') or DEFAULT_DSN
    if not dsn:
        raise SystemExit('Give the baseline database with --dsn "postgresql://..." or set GEOLOCK_BASELINE_DSN.')
    host = conninfo_to_dict(dsn).get('host', 'localhost')
    if 'supabase' in host:
        DB_LABEL = f'Supabase project ({host}); response times include the network delay'
    elif host.startswith('/') or host in ('localhost', '127.0.0.1', '::1'):
        DB_LABEL = 'local PostgreSQL'
    else:
        DB_LABEL = f'PostgreSQL at {host}'
    return dsn


def request_rows(requests):
    return [dict(scenario_id=r['scenario_id'], listing_id=r['listing_id'], ngos_competing=r['workers'],
                 request_number=r['request_no'], ngo_id=r['ngo_id'], road_distance_km=r['road_distance_km'],
                 answer=r['outcome'], reason_code=r['reason_code'], retries=r['retries'], error_message=r['error'],
                 response_ms=r['latency_ms'], request_id=str(r['request_uuid']), claim_id=str(r['claim_id']))
            for r in requests]


def trial_row(sid, listing_id, workers, done, stored, status_after):
    times = [r['latency_ms'] for r in done if r['latency_ms']]
    return dict(scenario_id=sid, listing_id=listing_id, ngos_competing=workers,
                different_ngos=len({r['ngo_id'] for r in done}),
                told_success=sum(r['outcome'] == 'SUCCESS' for r in done),
                told_already_claimed=sum(r['outcome'] == 'CONFLICT' for r in done),
                told_not_eligible=sum(r['outcome'] == 'INELIGIBLE' for r in done),
                failed_with_error=sum(r['outcome'] == 'ERROR' for r in done),
                retries_after_deadlock=sum(r['retries'] for r in done),
                claims_stored=len(stored), more_than_one_owner=yes(len(stored) > 1),
                listing_status_after=status_after, median_response_ms=round(median(times), 1),
                slowest_response_ms=round(max(times), 1) if times else 0.0)


TRIAL_COLUMNS = [
    ('scenario_id', 'Benchmark contention scenario: the key used to pair this row with the proposed method'),
    ('listing_id', 'Benchmark listing copied into the database for this trial'),
    ('ngos_competing', 'Claim requests sent at the same moment (2, 5 or 10)'),
    ('different_ngos', 'Different NGOs among them (the scenario has 2-4 nearby NGOs, reused in turn)'),
    ('told_success', 'Requests told "the listing is yours"'),
    ('told_already_claimed', 'Requests told "already claimed" (CONFLICT)'),
    ('told_not_eligible', 'Requests refused by the 20 km road geofence or another eligibility rule'),
    ('failed_with_error', 'Requests aborted by the database even after one retry (nothing stored)'),
    ('retries_after_deadlock', 'Retries used after a deadlock or serialization failure'),
    ('claims_stored', 'Active claims stored for the listing afterwards (correct = 1)'),
    ('more_than_one_owner', 'YES = duplicate committed claim (the E2 safety metric)'),
    ('listing_status_after', 'Listing status afterwards'),
    ('median_response_ms', 'Middle response time of the requests'),
    ('slowest_response_ms', 'Slowest response time'),
]
LEASE_COLUMNS = [
    ('scenario_id', 'Benchmark lease scenario: the key used to pair this row with the proposed method'),
    ('case', '"lease expired" (should be released) or "lease still running" (should be kept)'),
    ('listing_id', 'Benchmark listing'),
    ('first_ngo', 'NGO that claimed the listing earlier'),
    ('second_ngo', 'Another eligible NGO that now tries to claim it'),
    ('second_ngo_answer', 'Answer to the second NGO (SUCCESS / CONFLICT)'),
    ('second_ngo_reason', 'Reason code (CLAIM_CONFLICT = listing still claimed)'),
    ('second_ngo_got_listing', 'YES if the second NGO got the listing (lease recovery success)'),
    ('first_claim_still_active', 'YES if the first NGO still holds the listing'),
    ('active_claims_after', 'Active claims on the listing afterwards (correct = 1)'),
    ('listing_status_after', 'Listing status afterwards'),
    ('second_ngo_response_ms', 'Time from the second NGO pressing claim to its answer'),
]


def write_summary(path, bench, trials, lease, run_rows):
    lines = [f'# {TITLE}', '',
             'Benchmark ' + bench.manifest['benchmark_version'] + f'. Database: {DB_LABEL}.', '',
             '## What this baseline does', '',
             'It is the GeoLock claim **without lease recovery**. Claims are protected exactly as in the proposed '
             'system: the real `public.claim_listing()` locks the listing row, checks again that it is still '
             'AVAILABLE, and a unique index allows only one active claim per listing. The difference is that the job '
             'that releases expired claims, `public.recover_expired_claims()`, is never run. So an NGO that claims a '
             'listing and never collects it keeps it blocked, even after its 360-minute lease has expired.', '',
             '## Compared with (experiment E2, RQ2)', '',
             '| | This baseline | Proposed method (E2) |', '| --- | --- | --- |',
             '| Claim | `claim_listing()` | the same `claim_listing()` |',
             '| Expired leases | never released | `recover_expired_claims()` runs before the second NGO claims |',
             '| Same inputs | | same scenarios, listings, NGOs, request order, 20 km road geofence, 360-min lease, '
             'database and retry rule |', '',
             'Pair the files by `scenario_id`. Main E2 metrics: **duplicate committed-claim rate** '
             '(`more_than_one_owner`) and **lease recovery success** (`second_ngo_got_listing` in the '
             '"lease expired" cases). Expected: both methods 0 duplicates; only the proposed method recovers expired '
             'leases; neither may take over a lease that is still running.', '']
    if trials:
        dup = sum(t['more_than_one_owner'] == 'YES' for t in trials)
        one = sum(t['claims_stored'] == 1 for t in trials)
        lines += ['## Part 1 - several NGOs claim the same listing at the same moment', '',
                  '| Result | Value | Meaning |', '| --- | --- | --- |',
                  f'| Contention trials | {len(trials)} | One new listing per trial |',
                  f'| Trials with exactly 1 stored claim | {one} of {len(trials)} | Correct ownership |',
                  f'| **Duplicate committed-claim rate** | {dup} of {len(trials)} ({dup / len(trials):.0%}) | Must be 0% |',
                  f"| Requests told CONFLICT | {sum(t['told_already_claimed'] for t in trials)} | Clear \"already claimed\" answers |",
                  f"| Requests failed with a database error | {sum(t['failed_with_error'] for t in trials)} | Should be 0 |", '']
        lines += contention_table(trials)
    if lease:
        lines += ['', '## Part 2 - another NGO claims a listing that was claimed earlier', '',
                  '| Earlier claim at replay time | Cases | Second NGO got the listing | Earlier claim still active '
                  '| Median response (ms) |',
                  '| --- | --- | --- | --- | --- |']
        for case in ('lease expired', 'lease still running'):
            cs = [c for c in lease if c['case'] == case]
            if cs:
                lines.append(f"| {case} | {len(cs)} | {sum(c['second_ngo_got_listing'] == 'YES' for c in cs)} | "
                             f"{sum(c['first_claim_still_active'] == 'YES' for c in cs)} | "
                             f"{median([c['second_ngo_response_ms'] for c in cs]):,.0f} |")
        expired = [c for c in lease if c['case'] == 'lease expired']
        if expired:
            rec = sum(c['second_ngo_got_listing'] == 'YES' for c in expired)
            lines += ['', f'**Lease recovery success**: {rec} of {len(expired)} expired-lease listings '
                      f'({rec / len(expired):.0%}) could be claimed by another NGO. Without recovery the expired claim '
                      'is never released, so the listing stays blocked; this is the gap the proposed method must close.']
    lines += ['', '## How a trial runs', '',
              '1. A new AVAILABLE listing is made from the benchmark listing (same location, weight and claim window).',
              '2. Each NGO is checked against the 20 km road geofence using the benchmark road matrix.',
              '3. Part 1: every request opens its own signed-in connection; all are released at the same moment and call '
              '`claim_listing()`. Part 2: the earlier claim is written first, timed so that "now" is the benchmark replay '
              'time, then the second NGO calls `claim_listing()`.',
              '4. A deadlock gets one retry with the same request ID; a CONFLICT is never retried.',
              '5. The claims actually stored for the listing are read back from the database.', '',
              '## How to read the results', '',
              '- `claims_stored` = 1 and `more_than_one_owner` = NO in every trial means ownership is safe.',
              '- In "lease expired" cases, `second_ngo_got_listing` = NO is the problem this baseline shows; in '
              '"lease still running" cases NO is the correct answer.',
              '- Response times include the network delay when the database is a Supabase project.', '',
              '## Files', '', '| File | Content |', '| --- | --- |',
              '| `results_per_scenario.csv` | Part 1: one row per contention trial |',
              '| `lease_results_per_scenario.csv` | Part 2: one row per lease case |',
              '| `details/requests.csv` | Every claim request: NGO, road distance, answer, reason, retries, response time |',
              '| `run_info.md` | Database, PostgreSQL version, script fingerprint, settings |', '',
              '### Columns of results_per_scenario.csv', '', '| Column | Meaning |', '| --- | --- |']
    lines += [f'| `{a}` | {b} |' for a, b in TRIAL_COLUMNS]
    lines += ['', '### Columns of lease_results_per_scenario.csv', '', '| Column | Meaning |', '| --- | --- |']
    lines += [f'| `{a}` | {b} |' for a, b in LEASE_COLUMNS]
    lines += ['', '## References', '',
              '- PostgreSQL Global Development Group. (2026). SELECT: the locking clause. *PostgreSQL 18 documentation*. '
              'https://www.postgresql.org/docs/18/sql-select.html',
              '- Gray, C. G., & Cheriton, D. R. (1989). Leases: An efficient fault-tolerant mechanism for distributed file '
              'cache consistency. *Proceedings of the 12th ACM SOSP*, 202-210. https://doi.org/10.1145/74850.74870', '']
    path.write_text('\n'.join(lines), encoding='utf-8')


def contention_table(trials):
    lines = ['### By number of NGOs claiming at once', '', '| NGOs claiming at once | Trials | SUCCESS | CONFLICT | ERROR | Trials with 1 stored claim | '
             'Trials with a duplicate | Median response (ms) |', '| --- | --- | --- | --- | --- | --- | --- | --- |']
    for w in sorted({t['ngos_competing'] for t in trials}) + ['All']:
        ts = [t for t in trials if w == 'All' or t['ngos_competing'] == w]
        lines.append(f"| {w} | {len(ts)} | {sum(t['told_success'] for t in ts)} | "
                     f"{sum(t['told_already_claimed'] for t in ts)} | {sum(t['failed_with_error'] for t in ts)} | "
                     f"{sum(t['claims_stored'] == 1 for t in ts)} | {sum(t['more_than_one_owner'] == 'YES' for t in ts)} | "
                     f"{median([t['median_response_ms'] for t in ts]):,.0f} |")
    return lines


def write_run_info(path, rows):
    lines = [f'# Run information: {TITLE}', '', '| Item | Value |', '| --- | --- |']
    lines += [f'| {a} | {b} |' for a, b in rows] + ['']
    path.write_text('\n'.join(lines), encoding='utf-8')


def main():
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--dsn', help='Baseline database (default: GEOLOCK_BASELINE_DSN, else the Supabase baseline project)')
    parser.add_argument('--dataset-dir', type=Path, default=root / 'benchmark dataset' / 'dataset')
    parser.add_argument('--output-dir', type=Path, default=root / 'baseline implementation' / 'result' / FOLDER)
    parser.add_argument('--scenario-ids', type=Path, help='CSV with a scenario_id column, or one ID per line')
    parser.add_argument('--workers', type=int, help='Requests per contention trial (default 2 / 5 / 10)')
    parser.add_argument('--run-id', help='Label for this run (default: random)')
    parser.add_argument('--allow-shared-database', action='store_true')
    args = parser.parse_args()
    if args.workers is not None and args.workers < 2:
        parser.error('--workers must be at least 2')
    bench = Benchmark(args.dataset_dir)
    scenarios = bench.select(('CLAIM_COORDINATION', 'LEASE_RECOVERY', 'LEASE_ACTIVE_VERIFICATION'), args.scenario_ids)
    dsn = resolve_dsn(args.dsn)
    run_id = args.run_id or uuid.uuid4().hex[:12]
    db = Database(dsn, run_id)
    db.check_baseline_database(args.allow_shared_database)
    db.check_new_run(db.uid('LISTING', f"{bench.one(s['scenario_id'], 'LISTING', 'CLAIMABLE_LISTING')}/{METHOD}/{s['scenario_id']}")
                     for s in scenarios)
    db.require_function('public.claim_listing(uuid,uuid)', '01_GeoLock_Hub_Supabase_Schema_V3_10kg_360min.sql')
    db.require_claim_fix()

    trials, lease, requests = [], [], []
    for scenario in scenarios:
        sid, kind = scenario['scenario_id'], scenario['scenario_type']
        listing_id = bench.one(sid, 'LISTING', 'CLAIMABLE_LISTING')
        if kind == 'CLAIM_COORDINATION':
            ngos = bench.ids(sid, 'NGO', 'POTENTIAL_REQUESTER_UNASSESSED')
            workers = worker_count(sid, args.workers)
            listing_uuid = db.listing(bench, listing_id, f'{METHOD}/{sid}')
            batch = [dict(scenario_id=sid, listing_id=listing_id, workers=workers, request_no=i + 1,
                          ngo_id=ngos[i % len(ngos)], ngo_uuid=db.ngo(bench, ngos[i % len(ngos)]),
                          road_distance_km=bench.road_km(ngos[i % len(ngos)], listing_id), listing_uuid=listing_uuid,
                          request_uuid=db.uid('REQUEST', f'{METHOD}/{sid}/{i + 1}')) for i in range(workers)]
            done = send_together(dsn, batch, CALL)
            rows, status_after = db.claims_on(listing_uuid)
            stored = [r for r in rows if r[2] in ('ACTIVE', 'RECONCILIATION_REQUIRED')]
            trials.append(trial_row(sid, listing_id, workers, done, stored, status_after))
        else:
            state = bench.claim_states[sid]
            prior = bench.one(sid, 'NGO', 'PRIOR_CLAIMANT')
            second = bench.one(sid, 'NGO', 'POTENTIAL_REPLACEMENT_CLAIMANT')
            if state['listing_id'] != listing_id or state['ngo_id'] != prior:
                raise ValueError(f'Lease case does not match scenario members: {sid}')
            claimed_ago = parse_time(state['replay_at']) - parse_time(bench.listings[listing_id]['created_at'])
            listing_uuid = db.listing(bench, listing_id, f'{METHOD}/{sid}', opened_ago=claimed_ago)
            prior_claim = db.prior_claim(sid, listing_uuid, db.ngo(bench, prior), claimed_ago)
            with db.conn.cursor() as cur:
                cur.execute('select expires_at <= clock_timestamp() from public.claim_leases where claim_id = %s',
                            (prior_claim,))
                if cur.fetchone()[0] != (state['input_state'] == 'EXPIRED'):
                    raise ValueError(f'Lease case state does not match its expiry time: {sid}')
            item = dict(scenario_id=sid, listing_id=listing_id, workers=1, request_no=1, ngo_id=second,
                        ngo_uuid=db.ngo(bench, second), road_distance_km=bench.road_km(second, listing_id),
                        listing_uuid=listing_uuid, request_uuid=db.uid('REQUEST', f'{METHOD}/{sid}/1'))
            done = send_together(dsn, [item], CALL)
            rows, status_after = db.claims_on(listing_uuid)
            prior_status = next(r[2] for r in rows if r[0] == prior_claim)
            lease.append(dict(scenario_id=sid,
                              case='lease expired' if state['input_state'] == 'EXPIRED' else 'lease still running',
                              listing_id=listing_id, first_ngo=prior, second_ngo=second,
                              second_ngo_answer=done[0]['outcome'], second_ngo_reason=done[0]['reason_code'],
                              second_ngo_got_listing=yes(done[0]['outcome'] == 'SUCCESS'),
                              first_claim_still_active=yes(prior_status == 'ACTIVE'),
                              active_claims_after=sum(r[2] in ('ACTIVE', 'RECONCILIATION_REQUIRED') for r in rows),
                              listing_status_after=status_after,
                              second_ngo_response_ms=done[0]['latency_ms']))
        requests.extend(done)

    version, isolation = db.server()
    db.conn.close()
    out = args.output_dir
    (out / 'details').mkdir(parents=True, exist_ok=True)
    if trials:
        write_csv(out / 'results_per_scenario.csv', trials)
    if lease:
        write_csv(out / 'lease_results_per_scenario.csv', lease)
    write_csv(out / 'details' / 'requests.csv', request_rows(requests))
    manifest = args.dataset_dir / 'generation_manifest.json'
    run_rows = [('Run at', datetime.now().astimezone().strftime('%Y-%m-%d %H:%M %Z')),
                ('Benchmark', f"{bench.manifest['benchmark_version']} (manifest SHA-256 {sha256(manifest)[:16]}...; "
                              'every input CSV checked against it)'),
                ('Script', f'`{Path(__file__).name}` (SHA-256 {sha256(__file__)[:16]}...)'),
                ('Python', sys.version.split()[0]), ('Database', DB_LABEL), ('PostgreSQL', version),
                ('Transaction isolation', isolation),
                ('claim_listing() row lock', 'FOR NO KEY UPDATE (checked before the run)'), ('Run ID', run_id),
                ('Scenarios run', f'{len(trials)} contention trials, {len(lease)} lease cases'
                                  + (' (selected with --scenario-ids)' if args.scenario_ids else ' (all)')),
                ('Settings', (f'{args.workers} requests per trial' if args.workers else '2 / 5 / 10 requests per trial')
                 + f'; {GEOFENCE_KM:g} km road geofence; {LEASE_MINUTES}-min lease; one retry after a deadlock; '
                 'lease recovery off')]
    write_run_info(out / 'run_info.md', run_rows)
    write_summary(out / 'summary.md', bench, trials, lease, run_rows)
    print(f"{TITLE}: {sum(t['claims_stored'] == 1 for t in trials)}/{len(trials)} trials with one claim, "
          f"{sum(r['outcome'] == 'ERROR' for r in requests)} errors, "
          f"{sum(c['second_ngo_got_listing'] == 'YES' for c in lease if c['case'] == 'lease expired')}/"
          f"{sum(c['case'] == 'lease expired' for c in lease)} expired leases reclaimed -> {out / 'summary.md'}")


if __name__ == '__main__':
    main()
