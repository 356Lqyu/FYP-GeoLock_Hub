import csv
import os
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from pathlib import Path

import psycopg
from dotenv import load_dotenv

BASE = Path(__file__).resolve().parent
load_dotenv(BASE / '.env')
DATABASE_URL = os.getenv('TEST_DATABASE_URL')
if not DATABASE_URL:
    raise SystemExit('Missing TEST_DATABASE_URL in .env (isolated test project only)')

FIRST_LISTING_ID = uuid.UUID('88993b78-4dcb-4235-95ec-d9c9da8f70f7')
LEVELS = (2, 5, 10)
REPEATS = 3
NGO_EMAILS = ('ngo1@test.com', 'ngo2@test.com')
PICKUP_NODE = 'PICKUP_NODE_01'


def connect():
    return psycopg.connect(DATABASE_URL, connect_timeout=15)


def load_users():
    with connect() as conn, conn.cursor() as cur:
        cur.execute("SELECT email, id FROM auth.users WHERE email = ANY(%s)",
                    (['donor1@test.com', *NGO_EMAILS],))
        users = dict(cur.fetchall())
    missing = set(['donor1@test.com', *NGO_EMAILS]) - set(users)
    if missing:
        raise RuntimeError(f'Missing test users: {sorted(missing)}')
    return users


def check_fresh_listing(listing_id):
    with connect() as conn, conn.cursor() as cur:
        cur.execute('''
            SELECT listing_status, listing_version, pickup_road_node_id
            FROM public.listings WHERE listing_id = %s
        ''', (listing_id,))
        row = cur.fetchone()
    if row != ('AVAILABLE', 1, PICKUP_NODE):
        raise RuntimeError(f'Listing {listing_id} is not fresh: {row!r}')


def create_listing(donor_id, level, trial):
    title = f'G10 Geofenced Concurrency C{level} T{trial} {uuid.uuid4().hex[:10]}'
    items = '''[
      {"category":"food","item_name":"Rice Bags","quantity":2,"unit_weight_kg":5},
      {"category":"food","item_name":"Canned Food Packs","quantity":2,"unit_weight_kg":1}
    ]'''
    with connect() as conn, conn.cursor() as cur:
        cur.execute('''
            SELECT public.test_create_donation(
                %s::uuid, %s::text, %s::text, %s::text, %s::text,
                now(), now() + interval '48 hours', %s::jsonb
            )
        ''', (donor_id, title, 'Isolated synthetic geofenced concurrency test',
              'Synthetic test pickup location', PICKUP_NODE, items))
        donation_id = cur.fetchone()[0]
        cur.execute('''
            SELECT listing_id FROM public.listings
            WHERE donation_id = %s AND pickup_road_node_id = %s
        ''', (donation_id, PICKUP_NODE))
        row = cur.fetchone()
        if row is None:
            raise RuntimeError(f'No listing created for donation {donation_id}')
        listing_id = row[0]
    check_fresh_listing(listing_id)
    return listing_id


def claim_once(listing_id, ngo_id, ngo_email, request_id, gate):
    gate.wait(timeout=30)
    start = time.perf_counter()
    try:
        with connect() as conn, conn.cursor() as cur:
            cur.execute('''
                SELECT outcome, claim_id, message
                FROM public.test_claim_listing_geofenced(%s::uuid, %s::uuid, %s::uuid)
            ''', (listing_id, ngo_id, request_id))
            outcome, claim_id, message = cur.fetchone()
        error = ''
    except Exception as exc:
        outcome, claim_id, message = 'ERROR', None, ''
        error = f'{type(exc).__name__}: {exc}'
    return {
        'listing_id': str(listing_id), 'ngo_email': ngo_email,
        'request_id': str(request_id), 'outcome': outcome,
        'claim_id': str(claim_id) if claim_id else '',
        'message': message, 'error': error,
        'latency_ms': round((time.perf_counter() - start) * 1000, 2)
    }


def verify_listing(listing_id):
    with connect() as conn, conn.cursor() as cur:
        cur.execute('''
            SELECT listing_status, listing_version
            FROM public.listings WHERE listing_id = %s
        ''', (listing_id,))
        listing = cur.fetchone()
        cur.execute('''
            SELECT
                count(*) FILTER (WHERE claim_status = 'ACTIVE'),
                count(*)
            FROM public.donation_claims WHERE listing_id = %s
        ''', (listing_id,))
        active_claims, total_claims = cur.fetchone()
        cur.execute('''
            SELECT count(*)
            FROM public.claim_leases cl
            JOIN public.donation_claims dc ON dc.claim_id = cl.claim_id
            WHERE dc.listing_id = %s AND cl.lease_status = 'ACTIVE'
        ''', (listing_id,))
        active_leases = cur.fetchone()[0]
    return {
        'listing_status': listing[0] if listing else 'MISSING',
        'listing_version': listing[1] if listing else None,
        'active_claims': active_claims,
        'total_claims': total_claims,
        'active_leases': active_leases,
    }


def save_csv(filename, rows):
    if not rows:
        return
    path = BASE / filename
    with path.open('w', newline='', encoding='utf-8') as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    print(f'Saved: {path}')


def main():
    users = load_users()
    print('G10 — Concurrent geofenced claims (synthetic graph)')
    print('WARNING: Run against geolock_hub_concurrency_test only.')
    print('Confirm TEST_DATABASE_URL points to that project before proceeding.')
    summary, requests = [], []
    all_passed = True
    for level in LEVELS:
        for trial in range(1, REPEATS + 1):
            listing_id = (FIRST_LISTING_ID if (level, trial) == (2, 1)
                          else create_listing(users['donor1@test.com'], level, trial))
            check_fresh_listing(listing_id)
            gate = threading.Barrier(level)
            with ThreadPoolExecutor(max_workers=level) as pool:
                futures = []
                for i in range(level):
                    email = NGO_EMAILS[i % len(NGO_EMAILS)]
                    request_id = uuid.uuid4()
                    futures.append(pool.submit(
                        claim_once, listing_id, users[email], email, request_id, gate))
                trial_requests = [f.result() for f in as_completed(futures)]
            counts = {key: sum(r['outcome'] == key for r in trial_requests)
                      for key in ('SUCCESS', 'CONFLICT', 'INELIGIBLE', 'ERROR')}
            state = verify_listing(listing_id)
            passed = (
                counts['SUCCESS'] == 1 and counts['CONFLICT'] == level - 1
                and counts['INELIGIBLE'] == 0 and counts['ERROR'] == 0
                and state == {'listing_status': 'CLAIMED', 'listing_version': 2,
                              'active_claims': 1, 'total_claims': 1, 'active_leases': 1}
            )
            all_passed &= passed
            summary.append({'timestamp_utc': datetime.now(timezone.utc).isoformat(),
                            'level': level, 'trial': trial, 'listing_id': str(listing_id),
                            **counts, **state, 'passed': passed})
            for r in trial_requests:
                requests.append({'level': level, 'trial': trial, **r})
            print(f'C{level} trial {trial}: successes={counts["SUCCESS"]}, '
                  f'conflicts={counts["CONFLICT"]}, errors={counts["ERROR"]}, '
                  f'active_claims={state["active_claims"]}, '
                  f'active_leases={state["active_leases"]}: '
                  f'{"PASS" if passed else "FAIL"}')
            if not passed:
                print('Unexpected request results:', [r for r in trial_requests
                                                    if r['outcome'] not in ('SUCCESS', 'CONFLICT')])
    save_csv('geofenced_concurrency_summary.csv', summary)
    save_csv('geofenced_concurrency_requests.csv', requests)
    print(f'\nTOTAL: {sum(r["passed"] for r in summary)}/{len(summary)} trials passed')
    if not all_passed:
        raise SystemExit('G10 FAILED: inspect output and CSVs')


if __name__ == '__main__':
    main()
