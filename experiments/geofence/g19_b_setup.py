"""Create a fresh G19-B fixture in the known isolated Supabase test project.
Requires DATABASE_URL and G19_EXPECTED_PROJECT_REF. Uses existing test-only SQL functions.
No formal benchmark data is modified. Run once per desired fresh fixture.
"""
import os
import uuid
from urllib.parse import urlsplit, unquote
import psycopg
from psycopg.types.json import Jsonb

TEST_REF = 'enkeuhqubrxmwujybfry'
PREVIOUS_DONATION_ID = uuid.UUID('726e27da-74ef-4595-9fc8-0ba7e9a71f45')
NGO_ID = uuid.UUID('ea4ce2d8-2759-4607-a255-4767f472da39')

def main():
    url = os.environ.get('DATABASE_URL', '').strip()
    ref = os.environ.get('G19_EXPECTED_PROJECT_REF', '').strip().lower()
    if not url or ref != TEST_REF:
        raise RuntimeError('STOP: DATABASE_URL missing or expected project reference is not the isolated G19 test project')
    p = urlsplit(url)
    hostname = (p.hostname or '').lower()
    username = unquote(p.username or '').lower()
    if not (hostname == f'db.{ref}.supabase.co' or username.endswith('.' + ref)):
        raise RuntimeError('STOP: database connection does not identify the expected isolated Supabase project')

    with psycopg.connect(url, connect_timeout=12) as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT current_user, to_regprocedure('public.test_create_donation(uuid,text,text,text,text,timestamptz,timestamptz,jsonb)'), to_regprocedure('public.test_claim_listing(uuid,uuid,uuid)')")
            role, donation_fn, claim_fn = cur.fetchone()
            if role != 'postgres' or donation_fn is None or claim_fn is None:
                raise RuntimeError(f'STOP: missing privileged test role or test functions (role={role})')
            cur.execute('SELECT donor_user_id, pickup_road_node_id FROM public.donations WHERE donation_id=%s', (PREVIOUS_DONATION_ID,))
            prior = cur.fetchone()
            if prior is None or prior[1] != 'PICKUP_NODE_01':
                raise RuntimeError('STOP: known G19 reference donation missing or has unexpected pickup node')
            donor_id = prior[0]
            cur.execute("SELECT 1 FROM public.ngo_profiles WHERE user_id=%s AND active_flag=true", (NGO_ID,))
            if cur.fetchone() is None:
                raise RuntimeError('STOP: expected test NGO profile missing/inactive')
            cur.execute('''SELECT public.test_create_donation(
                %s, %s, %s, %s, %s,
                clock_timestamp(), clock_timestamp() + interval '7 days', %s
            )''', (
                donor_id, 'G19-B Recovery First 12kg Food',
                'Isolated G19-B controlled concurrency fixture',
                'Synthetic pickup location PICKUP_NODE_01', 'PICKUP_NODE_01',
                Jsonb([
                    {'category':'food','item_name':'Rice 5kg','quantity':2,'unit_weight_kg':5},
                    {'category':'food','item_name':'Canned food 1kg','quantity':2,'unit_weight_kg':1}
                ])
            ))
            donation_id = cur.fetchone()[0]
            cur.execute('''SELECT listing_id, listing_status, listing_version, listing_weight_kg, pickup_road_node_id
                           FROM public.listings WHERE donation_id=%s AND source_type='DIRECT_DONATION' ''', (donation_id,))
            listing = cur.fetchone()
            if listing is None or listing[1] != 'AVAILABLE' or listing[2] != 1 or float(listing[3]) != 12 or listing[4] != 'PICKUP_NODE_01':
                raise RuntimeError(f'STOP: new listing unexpected: {listing}')
            listing_id = listing[0]
            request_id = uuid.uuid4()
            cur.execute('SELECT outcome, claim_id, message FROM public.test_claim_listing(%s,%s,%s)', (listing_id, NGO_ID, request_id))
            outcome, claim_id, message = cur.fetchone()
            if outcome != 'SUCCESS' or claim_id is None:
                raise RuntimeError(f'STOP: test claim failed: {outcome} {message}')
            cur.execute('''SELECT l.listing_status,l.listing_version,dc.claim_status,cl.lease_status,
                                  cl.expires_at > clock_timestamp(),
                                  (SELECT count(*) FROM public.pickup_tasks WHERE claim_id=dc.claim_id)
                           FROM public.listings l
                           JOIN public.donation_claims dc ON dc.listing_id=l.listing_id
                           JOIN public.claim_leases cl ON cl.claim_id=dc.claim_id
                           WHERE l.listing_id=%s AND dc.claim_id=%s''', (listing_id, claim_id))
            state = cur.fetchone()
            if state != ('CLAIMED', 2, 'ACTIVE', 'ACTIVE', True, 0):
                raise RuntimeError(f'STOP: fixture verification failed: {state}')
        # Commit all new fixture rows only after validation.
    print('G19-B SETUP PASS: new donation, listing, active claim and unexpired lease committed')
    print('Donation ID:', donation_id)
    print('Listing ID:', listing_id)
    print('Claim ID:', claim_id)
    print('NGO ID:', NGO_ID)
    print('Copy and run these PowerShell commands in the SAME terminal:')
    print(f'$env:G19_B_LISTING_ID = "{listing_id}"')
    print(f'$env:G19_B_CLAIM_ID = "{claim_id}"')
    print(f'$env:G19_B_NGO_USER_ID = "{NGO_ID}"')
    print('py g19_recovery_first.py')

if __name__ == '__main__':
    main()
