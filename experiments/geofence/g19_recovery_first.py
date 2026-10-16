"""G19-B: recovery-first overlap against a FRESH isolated test fixture.

Required environment: DATABASE_URL, G19_EXPECTED_PROJECT_REF,
G19_B_LISTING_ID, G19_B_CLAIM_ID, G19_B_NGO_USER_ID.
Optional: G19_B_LISTING_VERSION (default 2), G19_B_PICKUP_NODE (default PICKUP_NODE_01),
G19_B_LOAD_KG (default 12).

Commits expiry/recovery in the isolated test database. Never run against production.
"""
import os
import threading
import time
import uuid
from urllib.parse import urlsplit, unquote

import psycopg


def required(name):
    value = os.environ.get(name, '').strip()
    if not value:
        raise RuntimeError(f'Missing {name}')
    return value


def conn():
    return psycopg.connect(required('DATABASE_URL'), connect_timeout=12)


def main():
    ref = required('G19_EXPECTED_PROJECT_REF').lower()
    url = required('DATABASE_URL')
    parts = urlsplit(url)
    host = (parts.hostname or '').lower()
    user = unquote(parts.username or '').lower()
    if len(ref) < 8 or not (host == f'db.{ref}.supabase.co' or user.endswith(f'.{ref}')):
        raise RuntimeError('STOP: DATABASE_URL does not match expected test project reference')
    listing_id = str(uuid.UUID(required('G19_B_LISTING_ID')))
    claim_id = str(uuid.UUID(required('G19_B_CLAIM_ID')))
    ngo_id = str(uuid.UUID(required('G19_B_NGO_USER_ID')))
    version = int(os.environ.get('G19_B_LISTING_VERSION', '2'))
    node = os.environ.get('G19_B_PICKUP_NODE', 'PICKUP_NODE_01')
    load = os.environ.get('G19_B_LOAD_KG', '12')
    if ref != 'enkeuhqubrxmwujybfry':
        raise RuntimeError('STOP: this G19 experiment is restricted to the known isolated test project')

    with conn() as c, c.cursor() as cur:
        cur.execute('SELECT listing_status, listing_version, pickup_road_node_id FROM public.listings WHERE listing_id=%s', (listing_id,))
        listing = cur.fetchone()
        cur.execute('''SELECT dc.claim_status, cl.lease_status, cl.expires_at > clock_timestamp()
                       FROM public.donation_claims dc JOIN public.claim_leases cl ON cl.claim_id=dc.claim_id
                       WHERE dc.claim_id=%s AND dc.listing_id=%s AND dc.ngo_user_id=%s''', (claim_id, listing_id, ngo_id))
        claim = cur.fetchone()
        cur.execute('SELECT count(*) FROM public.pickup_tasks WHERE claim_id=%s', (claim_id,))
        tasks = cur.fetchone()[0]
        cur.execute('SELECT to_regprocedure(%s), to_regprocedure(%s)',
                    ('public.test_recover_expired_claim(uuid)',
                     'public.test_create_pickup_task_protected(uuid,uuid,uuid,bigint,text,numeric)'))
        funcs = cur.fetchone()
    if listing != ('CLAIMED', version, node) or claim != ('ACTIVE', 'ACTIVE', True) or tasks != 0 or any(f is None for f in funcs):
        raise RuntimeError(f'STOP: fresh fixture not ready: listing={listing}, claim={claim}, tasks={tasks}, functions={funcs}')
    print('Preflight PASS: fresh claimed listing, active unexpired lease, zero tasks')

    recovery_has_lock = threading.Event()
    pickup_attempting = threading.Event()
    results = {}
    errors = []

    def recovery_first():
        try:
            with conn() as c, c.cursor() as cur:
                cur.execute("SELECT set_config('lock_timeout', %s, true)", ('15s',))
                cur.execute('SELECT listing_id FROM public.listings WHERE listing_id=%s FOR UPDATE', (listing_id,))
                # Set a deliberately expired lease in this same transaction, after locking the listing.
                cur.execute('''UPDATE public.claim_leases
                               SET issued_at=clock_timestamp()-interval '361 minutes',
                                   expires_at=clock_timestamp()-interval '1 minute'
                               WHERE claim_id=%s AND lease_status='ACTIVE' ''', (claim_id,))
                if cur.rowcount != 1:
                    raise AssertionError('Could not expire exactly one active test lease')
                recovery_has_lock.set()
                if not pickup_attempting.wait(10):
                    raise TimeoutError('Pickup worker did not start')
                time.sleep(1.5)  # keep the listing lock while pickup attempts to acquire it
                cur.execute('SELECT outcome, message FROM public.test_recover_expired_claim(%s)', (listing_id,))
                results['recovery'] = cur.fetchone()
                if results['recovery'][0] != 'RECOVERED':
                    raise AssertionError(f'Recovery did not succeed: {results["recovery"]}')
            # COMMIT: pickup can now see recovered state
        except Exception as e:
            errors.append(('recovery', repr(e)))
            recovery_has_lock.set()

    def pickup_second():
        try:
            if not recovery_has_lock.wait(12):
                raise TimeoutError('Recovery worker never locked listing')
            with conn() as c, c.cursor() as cur:
                cur.execute("SELECT set_config('lock_timeout', %s, true)", ('15s',))
                pickup_attempting.set()
                cur.execute('''SELECT outcome, message, created_task_id
                               FROM public.test_create_pickup_task_protected(%s,%s,%s,%s,%s,%s)''',
                            (listing_id, claim_id, ngo_id, version, node, load))
                results['pickup'] = cur.fetchone()
        except Exception as e:
            errors.append(('pickup', repr(e)))
            pickup_attempting.set()

    a = threading.Thread(target=recovery_first, name='recovery')
    b = threading.Thread(target=pickup_second, name='pickup')
    a.start(); b.start()
    a.join(30); b.join(30)
    if a.is_alive() or b.is_alive() or errors:
        raise RuntimeError(f'G19-B FAIL: errors={errors}; threads_alive={(a.is_alive(), b.is_alive())}')

    with conn() as c, c.cursor() as cur:
        cur.execute('SELECT listing_status, listing_version FROM public.listings WHERE listing_id=%s', (listing_id,))
        final_listing = cur.fetchone()
        cur.execute('SELECT claim_status FROM public.donation_claims WHERE claim_id=%s', (claim_id,))
        final_claim = cur.fetchone()[0]
        cur.execute('SELECT lease_status FROM public.claim_leases WHERE claim_id=%s', (claim_id,))
        final_lease = cur.fetchone()[0]
        cur.execute('SELECT count(*) FROM public.pickup_tasks WHERE claim_id=%s', (claim_id,))
        final_tasks = cur.fetchone()[0]
    print('Recovery result:', results.get('recovery'))
    print('Pickup result:', results.get('pickup'))
    print('Final state:', dict(listing=final_listing, claim=final_claim, lease=final_lease, pickup_tasks=final_tasks))
    assert results['recovery'][0] == 'RECOVERED'
    assert results['pickup'][0] == 'REJECTED' and results['pickup'][2] is None
    assert final_listing == ('AVAILABLE', version + 1)
    assert final_claim == 'EXPIRED' and final_lease == 'EXPIRED' and final_tasks == 0
    print('G19-B PASS: recovery-first overlap rejected stale pickup creation')
    print('Scope: controlled two-transaction ordering, not exhaustive concurrency verification')


if __name__ == '__main__':
    main()
