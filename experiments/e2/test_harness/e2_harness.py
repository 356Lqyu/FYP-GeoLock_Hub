"""E2 test harness.

The two baselines and the proposed method all run through this file, so they get the same
donations, NGOs, request schedule and checks. Only the claim and recovery functions differ.

What each condition runs (report Table 3.6):
  baseline 1  150 contention trials, 50 each with 2, 5 and 10 NGOs claiming one listing at once
  baseline 2  100 lease expiry and reclaim trials, plus 25 cases where the lease is still running
  proposed    both, plus the geofence check and the extra recovery checks
"""
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
import csv
from datetime import datetime, timedelta
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import statistics
import sys
import threading
import time
import uuid

import psycopg

HERE = Path(__file__).resolve().parent
E2 = HERE.parent
ROOT = E2.parents[1]
DATA = ROOT / 'benchmark dataset' / 'dataset'
SQL = E2 / 'database'
BENCHMARK_NAME = 'GEOLOCK-BENCHMARK-DATASET'

# Connection string of the separate E2 Supabase project (Session pooler). Never the app's project.
DSN = 'postgresql://postgres.xigdlbnmlfszklujlbnq:GeolockHub2027@aws-0-ap-southeast-1.pooler.supabase.com:5432/postgres'

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
        title='Protected Claim without Lease Recovery (baseline 2)', parts=('LEASE_RECOVERY', 'LEASE_ACTIVE_VERIFICATION'), two_step=False, recovery=False,
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
    return dict(python=sys.version.split()[0], platform=platform.platform(), psycopg=psycopg.__version__,
                run_at=datetime.now().astimezone().isoformat(timespec='seconds'))


def run_info(path, title, items):
    """Write run_info.md, a short record of how this result was made."""
    lines = [f'# Run information: {title}', '', '| Item | Value |', '| --- | --- |']
    lines += [f'| {k} | {v} |' for k, v in items]
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_text('\n'.join(lines) + '\n', encoding='utf-8')


# Connection and database setup

def get_dsn():
    """Connection string of the E2 Supabase project (DSN above; GEOLOCK_E2_DSN overrides it)."""
    return os.environ.get('GEOLOCK_E2_DSN', '').strip() or DSN


def connect(dsn):
    """Open a database connection with a time limit."""
    return psycopg.connect(dsn, autocommit=True, connect_timeout=CONNECT_TIMEOUT_S)


def setup_database(dsn):
    """Empty the experiment project and build it again: 04 reset, 01 schema, 02 app claim layer,
    03 baseline 1 functions, then the benchmark road matrix."""
    with connect(dsn) as conn:
        ok = conn.execute("select to_regnamespace('auth') is not null and to_regprocedure('auth.uid()') is not null "
                          "and (select count(*) from pg_roles where rolname in ('authenticated','service_role')) = 2").fetchone()[0]
        if not ok:
            raise SystemExit('This database is not a Supabase project. Create a new Supabase project for E2.')
        for name in ('04_reset_e2_objects.sql', '01_geolock_v3_schema.sql', '02_app_claim_layer.sql',
                     '03_non_atomic_baseline.sql'):
            try:
                conn.execute((SQL / name).read_text(encoding='utf-8'))
            except psycopg.Error as exc:
                raise SystemExit(f'{name} failed: {str(exc).splitlines()[0]}')
        check_inputs(['road_distance_matrix'])
        with conn.cursor() as cur, cur.copy('copy e2_bench.road_km(from_node, to_node, km) from stdin') as cp:
            for r in rows('road_distance_matrix'):
                if r['route_available_flag'] == '1':
                    cp.write_row((r['from_node_id'], r['to_node_id'], float(r['road_distance_km'])))


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
            cur.execute("select version(), current_setting('default_transaction_isolation'), "
                        "exists(select 1 from pg_roles where rolname = 'supabase_admin')")
            v, iso, supa = cur.fetchone()
        kind = ('separate experiment only Supabase project' if supa
                else 'PostgreSQL with stand ins for Supabase auth (development check, not the final run)')
        return v.split(' on ')[0], iso, kind


# Sending claim requests

def sign_in(conn, user_uuid):
    """Act as this NGO in the session, the way Supabase does for a signed in user."""
    with conn.cursor() as cur:
        cur.execute('set role authenticated')
        cur.execute(f"set statement_timeout = '{STATEMENT_TIMEOUT_S}s'")
        cur.execute("select set_config('request.jwt.claims', %s, false)",
                    (json.dumps({'sub': str(user_uuid), 'role': 'authenticated'}),))


def send_together(dsn, requests, spec):
    """Send the requests of one trial at the same moment, one connection per NGO.
    NGOs that are more than 20 km away by road are refused before a request is sent."""
    for item in requests:
        km = item['road_distance_km']
        item.update(retries=0, error='', latency_ms=0.0, claim_id='', outcome='', reason_code='')
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
                item.update(outcome='ERROR', error=str(exc).splitlines()[0])
            checked.wait(timeout=BARRIER_TIMEOUT_S)
            if ok:
                try:
                    t = time.perf_counter()
                    out = call(conns[i], spec['write'], (item['listing_uuid'], item['request_uuid']))
                    ms += (time.perf_counter() - t) * 1000
                    item.update(outcome=out.get('outcome'), reason_code=out.get('reason_code') or '',
                                claim_id=out.get('claim_id') or '')
                except psycopg.Error as exc:
                    item.update(outcome='ERROR', error=str(exc).splitlines()[0])
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
                    if item['retries'] >= MAX_RETRIES:
                        item.update(outcome='ERROR', error=str(exc).splitlines()[0])
                        break
                    item['retries'] += 1
                except psycopg.Error as exc:
                    item.update(outcome='ERROR', error=str(exc).splitlines()[0])
                    break
            item['latency_ms'] = round((time.perf_counter() - t) * 1000, 1)

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
    run_id = uuid.uuid4().hex[:12]
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
    version, isolation, kind = db.server()
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
        response_ms=r['latency_ms'], trial_ms=r.get('trial_ms', ''), request_id=str(r['request_uuid']), claim_id=str(r['claim_id'])) for r in requests])
    env = environment()
    sync = 'one database connection per NGO, all requests of a trial released together by a barrier'
    if spec['two_step']:
        sync += '; a second barrier makes every NGO finish its check before any NGO saves'
    info = [('Condition', spec['title']), ('Run at', env['run_at']),
            ('Benchmark', f'{BENCHMARK_NAME} (every input checked against generation_manifest.json)'),
            ('Database', f'{kind} ({version})'), ('Isolation', isolation),
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
    write_json(out / 'run_manifest.json', dict(method=method, run_id=run_id, input_sha256=bench.hashes,
                                                environment=env, database=kind, server_version=version,
                                                trials=len(trials), lease_cases=len(lease)))
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
            errors.append(f'{type(exc).__name__}: {exc}')
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


def main(method, out):
    """Rebuild the database, run one condition and write its result folder."""
    spec = METHODS[method]
    dsn = get_dsn()
    print(f"{spec['title']}: rebuilding the experiment database ...", flush=True)
    setup_database(dsn)
    out = Path(out)
    if out.exists():
        shutil.rmtree(out)  # start the result folder fresh, so no file from an older run is left
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
