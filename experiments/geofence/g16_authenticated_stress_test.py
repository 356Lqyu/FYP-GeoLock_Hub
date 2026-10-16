"""G16 preliminary authenticated claim concurrency test (isolated Supabase project only).

Requires: pip install requests python-dotenv psycopg[binary]
Environment: TEST_SUPABASE_URL, TEST_SUPABASE_ANON_KEY, TEST_DATABASE_URL,
TEST_NGO_EMAIL, TEST_NGO_PASSWORD, TEST_NGO2_EMAIL, TEST_NGO2_PASSWORD.

Uses a privileged SQL connection ONLY for fixture creation and verification.
Claim calls use real NGO JWTs and the authenticated REST RPC.
"""
import csv
import os
import time
import uuid
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from pathlib import Path
from threading import Barrier

import psycopg
import requests
from dotenv import load_dotenv

load_dotenv()
URL = os.environ['TEST_SUPABASE_URL'].rstrip('/')
KEY = os.environ['TEST_SUPABASE_ANON_KEY']
DB_URL = os.environ['TEST_DATABASE_URL']
ACCOUNTS = [
    (os.environ['TEST_NGO_EMAIL'], os.environ['TEST_NGO_PASSWORD']),
    (os.environ['TEST_NGO2_EMAIL'], os.environ['TEST_NGO2_PASSWORD']),
]
OUT = Path(__file__).resolve().parent / 'g16_results'
OUT.mkdir(exist_ok=True)


def login(email, password):
    r = requests.post(f'{URL}/auth/v1/token', params={'grant_type': 'password'},
                      headers={'apikey': KEY, 'Content-Type': 'application/json'},
                      json={'email': email, 'password': password}, timeout=30)
    r.raise_for_status()
    obj = r.json()
    return {'email': email, 'uid': obj['user']['id'], 'jwt': obj['access_token']}


def create_fixture(trial):
    with psycopg.connect(DB_URL) as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT id FROM auth.users WHERE email = 'donor1@test.com'")
            row = cur.fetchone()
            if not row:
                raise RuntimeError('Missing donor1@test.com')
            title = f'G16-{trial}-{uuid.uuid4().hex[:8]}'
            cur.execute("""
                SELECT public.test_create_donation(
                    %s::uuid, %s::text, %s::text, %s::text, %s::text,
                    now(), now() + interval '7 days', %s::jsonb
                )
            """, (row[0], title, 'G16 authenticated concurrency test',
                  'Synthetic Pickup Node 01', 'PICKUP_NODE_01',
                  '[{"category":"food","item_name":"Rice Bags","quantity":2,"unit_weight_kg":5},'
                  '{"category":"food","item_name":"Canned Food Packs","quantity":2,"unit_weight_kg":1}]'))
            donation_id = cur.fetchone()[0]
            cur.execute("""
                SELECT listing_id, listing_status, listing_weight_kg
                FROM public.listings WHERE donation_id = %s
            """, (donation_id,))
            listing = cur.fetchone()
            if not listing or listing[1] != 'AVAILABLE' or float(listing[2]) != 12:
                raise AssertionError(f'Unexpected fixture listing: {listing}')
        conn.commit()
    return str(listing[0])


def call_claim(account, listing_id, request_id, barrier):
    barrier.wait(timeout=30)
    started = time.perf_counter()
    try:
        r = requests.post(f'{URL}/rest/v1/rpc/claim_listing',
                          headers={'apikey': KEY, 'Authorization': f"Bearer {account['jwt']}",
                                   'Content-Type': 'application/json'},
                          json={'p_listing_id': listing_id, 'p_request_id': request_id},
                          timeout=90)
        elapsed = round((time.perf_counter() - started) * 1000, 2)
        payload = r.json()
        if r.status_code == 200 and isinstance(payload, list) and len(payload) == 1:
            result = payload[0]
            return {'ngo': account['email'], 'request_id': request_id,
                    'http': r.status_code, 'outcome': result.get('outcome'),
                    'claim_id': result.get('claim_id'), 'message': result.get('message'),
                    'latency_ms': elapsed}
        return {'ngo': account['email'], 'request_id': request_id,
                'http': r.status_code, 'outcome': 'ERROR', 'claim_id': None,
                'message': str(payload)[:300], 'latency_ms': elapsed}
    except Exception as exc:
        return {'ngo': account['email'], 'request_id': request_id,
                'http': None, 'outcome': 'ERROR', 'claim_id': None,
                'message': repr(exc), 'latency_ms': None}


def verify(listing_id, request_count):
    with psycopg.connect(DB_URL) as conn:
        with conn.cursor() as cur:
            cur.execute("""
                SELECT l.listing_status, l.listing_version, d.donation_status,
                  (SELECT count(*) FROM public.donation_claims c WHERE c.listing_id=l.listing_id),
                  (SELECT count(*) FROM public.donation_claims c WHERE c.listing_id=l.listing_id AND c.claim_status='ACTIVE'),
                  (SELECT count(*) FROM public.claim_leases x JOIN public.donation_claims c ON c.claim_id=x.claim_id
                     WHERE c.listing_id=l.listing_id AND x.lease_status='ACTIVE'),
                  (SELECT count(*) FROM public.claim_requests r WHERE r.listing_id=l.listing_id),
                  (SELECT count(*) FROM public.audit_events a WHERE a.entity_id=l.listing_id
                     AND a.event_type='AUTHENTICATED_CLAIM_ATTEMPT')
                FROM public.listings l LEFT JOIN public.donations d ON d.donation_id=l.donation_id
                WHERE l.listing_id=%s
            """, (listing_id,))
            actual = cur.fetchone()
    expected = ('CLAIMED', 2, 'CLAIMED', 1, 1, 1, request_count, request_count)
    return actual, actual == expected


def main():
    print('G16 preliminary authenticated concurrency stress test')
    accounts = [login(*pair) for pair in ACCOUNTS]
    for a in accounts:
        print('Authenticated:', a['email'], a['uid'])
    summary = []
    details = []
    for count in (2, 10, 50):
        for repeat in range(1, 4):
            label = f'C{count}-R{repeat}'
            listing_id = create_fixture(label)
            barrier = Barrier(count)
            tasks = [(accounts[i % 2], str(uuid.uuid4())) for i in range(count)]
            with ThreadPoolExecutor(max_workers=count) as pool:
                futures = [pool.submit(call_claim, account, listing_id, req, barrier)
                           for account, req in tasks]
                results = [f.result() for f in as_completed(futures)]
            successes = [x for x in results if x['outcome'] == 'SUCCESS']
            conflicts = [x for x in results if x['outcome'] == 'CONFLICT']
            errors = [x for x in results if x['outcome'] not in ('SUCCESS', 'CONFLICT')]
            db, db_ok = verify(listing_id, count)
            ok = len(successes) == 1 and len(conflicts) == count - 1 and not errors and db_ok
            print(f'{label}: {"PASS" if ok else "FAIL"} | success={len(successes)} '
                  f'conflict={len(conflicts)} errors={len(errors)} | DB={db}')
            summary.append({'trial': label, 'listing_id': listing_id, 'requests': count,
                            'successes': len(successes), 'conflicts': len(conflicts),
                            'errors': len(errors), 'db_ok': db_ok, 'pass': ok,
                            'winner': successes[0]['ngo'] if len(successes) == 1 else ''})
            for result in results:
                details.append({'trial': label, 'listing_id': listing_id, **result})
    for filename, rows in [('g16_summary.csv', summary), ('g16_requests.csv', details)]:
        with (OUT / filename).open('w', newline='', encoding='utf-8') as f:
            writer = csv.DictWriter(f, fieldnames=rows[0].keys())
            writer.writeheader()
            writer.writerows(rows)
    passed = sum(x['pass'] for x in summary)
    print(f'\nTOTAL: {passed}/9 trials passed')
    print(f'Results: {OUT}')
    if passed != 9:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
