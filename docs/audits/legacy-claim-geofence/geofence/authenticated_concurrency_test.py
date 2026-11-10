import os
import uuid
from concurrent.futures import ThreadPoolExecutor
from threading import Event

import requests
from dotenv import load_dotenv

load_dotenv()

BASE_URL = os.environ['TEST_SUPABASE_URL'].rstrip('/')
API_KEY = os.environ['TEST_SUPABASE_ANON_KEY']
LISTING_A = 'a3baa790-2b12-4315-a8d1-9b18f33b437f'
LISTING_B = '9fbe979e-5a3a-43cd-8a6e-eca1c5bb8dcb'


def credentials(number):
    if number == 1:
        return os.environ['TEST_NGO_EMAIL'], os.environ['TEST_NGO_PASSWORD']
    return (os.environ.get(f'TEST_NGO{number}_EMAIL', f'ngo{number}@test.com'),
            os.environ[f'TEST_NGO{number}_PASSWORD'])


def sign_in(number):
    email, password = credentials(number)
    response = requests.post(
        f'{BASE_URL}/auth/v1/token',
        params={'grant_type': 'password'},
        headers={'apikey': API_KEY, 'Content-Type': 'application/json'},
        json={'email': email, 'password': password},
        timeout=30,
    )
    response.raise_for_status()
    session = response.json()
    print(f'NGO {number} authenticated: {session["user"]["id"]}')
    return session['access_token']


def claim(token, listing_id, request_id, start_event=None):
    if start_event is not None:
        if not start_event.wait(timeout=15):
            raise TimeoutError('Concurrent test start signal timed out')
    response = requests.post(
        f'{BASE_URL}/rest/v1/rpc/claim_listing',
        headers={
            'apikey': API_KEY,
            'Authorization': f'Bearer {token}',
            'Content-Type': 'application/json',
        },
        json={'p_listing_id': listing_id, 'p_request_id': request_id},
        timeout=60,
    )
    response.raise_for_status()
    data = response.json()
    assert isinstance(data, list) and len(data) == 1, data
    return data[0]


def main():
    print('G15: authenticated concurrency and geofence')
    tokens = {number: sign_in(number) for number in (1, 2, 3)}

    print('\nG15-A: simultaneous NGO 1 / NGO 2 claims')
    gate = Event()
    request_ids = {1: str(uuid.uuid4()), 2: str(uuid.uuid4())}
    with ThreadPoolExecutor(max_workers=2) as pool:
        futures = {
            number: pool.submit(claim, tokens[number], LISTING_A,
                                request_ids[number], gate)
            for number in (1, 2)
        }
        gate.set()
        results = {number: future.result() for number, future in futures.items()}

    for number in (1, 2):
        print(f'NGO {number}: {results[number]}')
    outcomes = sorted(record['outcome'] for record in results.values())
    assert outcomes == ['CONFLICT', 'SUCCESS'], outcomes
    winners = [number for number, record in results.items()
               if record['outcome'] == 'SUCCESS']
    winner = winners[0]
    winner_claim_id = results[winner]['claim_id']
    assert winner_claim_id is not None
    assert all(record['claim_id'] is None for number, record in results.items()
               if number != winner)
    print(f'G15-A: PASS — NGO {winner} won, one conflict')

    print('\nG15-A retry: winning request ID')
    repeated = claim(tokens[winner], LISTING_A, request_ids[winner])
    print('Retry:', repeated)
    assert repeated['outcome'] == 'SUCCESS'
    assert repeated['claim_id'] == winner_claim_id
    print('G15-A retry: PASS — same claim ID')

    print('\nG15-B: NGO 3 geofence rejection')
    denied_request_id = str(uuid.uuid4())
    denied = claim(tokens[3], LISTING_B, denied_request_id)
    print('NGO 3:', denied)
    assert denied['outcome'] == 'INELIGIBLE', denied
    assert denied['claim_id'] is None
    assert denied['message'] == 'Road distance exceeds eligibility limit', denied
    print('G15-B: PASS — ineligible NGO rejected')

    print('\nG15-B retry: same request ID')
    denied_retry = claim(tokens[3], LISTING_B, denied_request_id)
    print('Retry:', denied_retry)
    assert denied_retry['outcome'] == 'INELIGIBLE'
    assert denied_retry['claim_id'] is None
    print('G15-B retry: PASS — consistent rejection')

    print('\nTOTAL: 4/4 checks passed (API-level only)')
    print('G15-A winning claim ID:', winner_claim_id)
    print('G15-A request IDs:', request_ids)
    print('G15-B request ID:', denied_request_id)
    print('Next: verify listing, claims, leases and audit records in SQL.')


if __name__ == '__main__':
    main()
