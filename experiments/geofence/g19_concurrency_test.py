"""G19: overlapping protected pickup creation and expired-lease recovery.

Run ONLY against isolated Supabase geolock_hub_concurrency_test.
This script COMMITS a synthetic expired lease and pickup task.
Requires DATABASE_URL and G19_EXPECTED_PROJECT_REF (Supabase project reference).
"""
import os
import threading
import time
from urllib.parse import urlsplit, unquote
import psycopg

LISTING = '6100b124-4b02-4d1a-8105-27256bacdbe9'
CLAIM = '122a5a38-2b1b-49ef-8c51-89aacde11a8a'
NGO = 'ea4ce2d8-2759-4607-a255-4767f472da39'
VERSION = 2


def connect():
    return psycopg.connect(os.environ['DATABASE_URL'], connect_timeout=12)


def check_project():
    url = os.environ.get('DATABASE_URL', '')
    expected = os.environ.get('G19_EXPECTED_PROJECT_REF', '').strip().lower()
    if not url or not expected or len(expected) < 8:
        raise RuntimeError('Set DATABASE_URL and G19_EXPECTED_PROJECT_REF (Supabase project reference).')
    parts = urlsplit(url)
    hostname = (parts.hostname or '').lower()
    username = unquote(parts.username or '').lower()
    if not (hostname == f'db.{expected}.supabase.co' or username.endswith(f'.{expected}')):
        raise RuntimeError('STOP: DATABASE_URL does not identify expected Supabase project ref.')
    with connect() as c:
        with c.cursor() as cur:
            cur.execute('SELECT current_user, current_database()')
            role, database = cur.fetchone()
            cur.execute('SELECT listing_status, listing_version FROM public.listings WHERE listing_id = %s', (LISTING,))
            listing = cur.fetchone()
            cur.execute('''SELECT dc.claim_status, cl.lease_status, cl.expires_at > clock_timestamp()
                           FROM public.donation_claims dc JOIN public.claim_leases cl ON cl.claim_id=dc.claim_id
                           WHERE dc.claim_id=%s AND dc.listing_id=%s AND dc.ngo_user_id=%s''', (CLAIM, LISTING, NGO))
            claim = cur.fetchone()
            cur.execute('SELECT count(*) FROM public.pickup_tasks WHERE claim_id=%s', (CLAIM,))
            tasks = cur.fetchone()[0]
    print(f'Connected to project ref: {expected}; DB: {database}; role: {role}')
    if listing != ('CLAIMED', VERSION) or claim != ('ACTIVE', 'ACTIVE', True) or tasks != 0:
        raise RuntimeError(f'STOP: unexpected fixture state: listing={listing}, claim={claim}, tasks={tasks}')
    print('Preflight PASS: claimed v2, active unexpired lease, zero pickup tasks')


def main():
    check_project()
    ready = threading.Event()
    attempted = threading.Event()
    errors = []
    results = {}

    def pickup_first():
        try:
            with connect() as c:
                with c.cursor() as cur:
                    cur.execute('BEGIN')
                    cur.execute("SELECT set_config('lock_timeout', %s, true)", ('12s',))
                    cur.execute('''SELECT outcome, message, created_task_id
                                   FROM public.test_create_pickup_task_protected(%s,%s,%s,%s,%s,%s)''',
                                (LISTING, CLAIM, NGO, VERSION, 'PICKUP_NODE_01', 12))
                    result = cur.fetchone()
                    results['pickup'] = result
                    if result[0] != 'CREATED' or result[2] is None:
                        raise AssertionError(f'Pickup not created: {result}')
                    # Expire the lease AFTER successful pickup authorization,
                    # while holding the listing row lock; this models a lease
                    # crossing expiry before recovery can acquire the listing lock.
                    cur.execute('''UPDATE public.claim_leases
                                   SET issued_at=clock_timestamp()-interval '361 minutes',
                                       expires_at=clock_timestamp()-interval '1 minute'
                                   WHERE claim_id=%s AND lease_status='ACTIVE' ''', (CLAIM,))
                    if cur.rowcount != 1:
                        raise AssertionError('Expected exactly one active lease')
                    ready.set()
                    if not attempted.wait(timeout=8):
                        raise TimeoutError('Recovery thread did not start')
                    time.sleep(1.5)  # deliberately hold listing lock while recovery starts
                c.commit()
        except Exception as exc:
            errors.append(('pickup', repr(exc)))
            ready.set()

    def recovery_second():
        try:
            if not ready.wait(timeout=12):
                raise TimeoutError('Pickup transaction did not become ready')
            with connect() as c:
                with c.cursor() as cur:
                    cur.execute('BEGIN')
                    cur.execute("SELECT set_config('lock_timeout', %s, true)", ('12s',))
                    attempted.set()
                    cur.execute('SELECT outcome, message FROM public.test_recover_expired_claim(%s)', (LISTING,))
                    results['recovery'] = cur.fetchone()
                c.commit()
        except Exception as exc:
            errors.append(('recovery', repr(exc)))
            attempted.set()

    t1 = threading.Thread(target=pickup_first, name='pickup')
    t2 = threading.Thread(target=recovery_second, name='recovery')
    t1.start(); t2.start()
    t1.join(timeout=25); t2.join(timeout=25)
    if t1.is_alive() or t2.is_alive():
        raise RuntimeError('FAIL: thread did not finish')
    if errors:
        raise RuntimeError(f'FAIL: {errors}')
    print('Pickup result:', results.get('pickup'))
    print('Recovery result:', results.get('recovery'))
    with connect() as c:
        with c.cursor() as cur:
            cur.execute('SELECT listing_status, listing_version FROM public.listings WHERE listing_id=%s', (LISTING,))
            listing = cur.fetchone()
            cur.execute('SELECT claim_status FROM public.donation_claims WHERE claim_id=%s', (CLAIM,))
            claim = cur.fetchone()[0]
            cur.execute('SELECT lease_status FROM public.claim_leases WHERE claim_id=%s', (CLAIM,))
            lease = cur.fetchone()[0]
            cur.execute("SELECT count(*) FROM public.pickup_tasks WHERE claim_id=%s AND task_status='CONFIRMED'", (CLAIM,))
            tasks = cur.fetchone()[0]
    print('Final state:', dict(listing_status=listing[0], listing_version=listing[1], claim_status=claim, lease_status=lease, confirmed_tasks=tasks))
    assert results['recovery'][0] == 'RECONCILIATION_REQUIRED', 'Unexpected recovery outcome'
    assert listing == ('CLAIMED', VERSION) and claim == 'ACTIVE' and lease == 'RECONCILIATION_REQUIRED' and tasks == 1
    print('G19 PASS: overlapping pickup-first recovery preserved custody safeguards')
    print('Scope: one concurrent ordering only; NOT proof of all possible races.')


if __name__ == '__main__':
    main()
