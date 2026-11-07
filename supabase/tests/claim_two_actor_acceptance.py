"""Stage 3J two-actor DEV acceptance. Defaults to read-only preflight.

Execution requires a separate explicit CLI approval. Uses normal authenticated
claim/cancel RPCs only; never recovery, expiry writes, fixture DML or cron APIs.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import json
import sys
import threading
import time
import urllib.request
import uuid
from contextlib import contextmanager
from pathlib import Path

import claim_concurrency_test as claim
import claim_e2e_contract as contract
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[2]
PACKAGE = ROOT / 'supabase/tests/review-only/stage3j/two_actor'
APPROVAL = 'I_APPROVE_STAGE3J_TWO_ACTOR_ACCEPTANCE'


class AcceptanceBlocked(RuntimeError):
    """Only fixed, credential-free guard messages may be displayed."""


def check(ok, message):
    if not ok:
        raise AcceptanceBlocked(message)


def database_url():
    value = claim.required('GEOLOCK_TEST_DATABASE_URL')
    p = claim.urlparse(value)
    check(p.scheme in ('postgres', 'postgresql')
          and p.hostname == 'aws-0-ap-northeast-2.pooler.supabase.com'
          and p.port == 5432 and p.username == 'postgres.' + claim.DEV_PROJECT_REF
          and p.path == '/postgres' and bool(p.password) and not p.fragment
          and claim.urllib.parse.parse_qs(p.query) == {'sslmode': ['require']},
          'Use only the approved DEV Session Pooler over required SSL.')
    return value


def sql_read(db_url, filename, params=None):
    import psycopg
    # Every verification connection is READ ONLY, including when --execute is used.
    with psycopg.connect(db_url, connect_timeout=5) as conn:
        with conn.cursor() as cur:
            cur.execute('SET TRANSACTION READ ONLY')
            cur.execute("SET LOCAL statement_timeout = '15s'")
            cur.execute((PACKAGE / filename).read_text(encoding='utf-8'), params)
            return cur.fetchone()[0]


def verify_sessions(base, key, tokens, actor_count=2):
    subjects = [claim.jwt_subject(t) for t in tokens]
    check(len(subjects) == actor_count and len(set(subjects)) == actor_count,
          'Exactly the approved number of distinct authenticated NGO subjects required.')
    for token, subject in zip(tokens, subjects):
        req = urllib.request.Request(base + '/auth/v1/user', headers={
            'apikey': key, 'Authorization': 'Bearer ' + token}, method='GET')
        try:
            with urllib.request.urlopen(req, timeout=15) as response:
                user = json.load(response)
        except Exception:
            raise RuntimeError('A DEV NGO session could not be verified; refresh its access token.') from None
        check(user.get('id') == subject and user.get('role') == 'authenticated',
              'Token does not represent the expected authenticated user.')
    return subjects


def validate_health(snapshot, baseline):
    contract.validate_health(snapshot, baseline)


def validate_fixture(state, listing_id, donation_id, label):
    listing, donation = state['listing'], state['donation']
    check(listing is not None and donation is not None, 'Dedicated fixture is missing.')
    check(listing['listing_id'] == listing_id and listing['donation_id'] == donation_id
          and donation['donation_id'] == donation_id and donation['title'].startswith(label + '-')
          and listing['source_type'] == 'DIRECT_DONATION'
          and donation['collection_path'] == 'DIRECT_PICKUP', 'Fixture mapping/label/path mismatch.')
    check(listing['listing_status'] == donation['donation_status'] == 'AVAILABLE'
          and listing['listing_expires_at'] is None and listing['pickup_road_node_id'] is not None,
          'Fixture must be AVAILABLE, road-resolved and have NULL listing expiration.')
    check(float(listing['listing_weight_kg']) >= 10, 'Direct test donation must meet the 10 kg minimum.')
    check(not state['claims'] and not state['cases'] and not state['route_count'] and not state['failures']
          and state['photo_count'] in (1, 2, 3) and state['item_count'] > 0,
          'Fixture is not fresh or lacks required photo/item evidence.')
    check(state['current_refresh_completed'], 'Current listing eligibility refresh is incomplete.')


class Journal:
    def __init__(self, folder):
        self.folder = folder
        folder.mkdir(parents=True, exist_ok=False)
        self.lock = threading.Lock()

    def record(self, kind, **values):
        # No JWT, service key, DB URL, address or photo path enters the journal.
        with self.lock:
            with (self.folder / 'events.jsonl').open('a', encoding='utf-8') as out:
                out.write(json.dumps({'event': kind, 'observed_at': datetime.now(timezone.utc).isoformat(),
                                      **values}, sort_keys=True) + '\n')


@contextmanager
def record_rpcs(journal):
    original = claim.rpc

    def recorded(base, key, token, name, payload):
        journal.record('RPC_START', rpc=name, actor=claim.jwt_subject(token), params=payload)
        started = time.perf_counter()
        try:
            status, response = original(base, key, token, name, payload)
        except Exception:
            journal.record('RPC_UNCONFIRMED', rpc=name, params=payload,
                           elapsed_ms=(time.perf_counter()-started)*1000)
            raise
        journal.record('RPC_RESULT', rpc=name, params=payload, http=status,
                       outcome=response.get('outcome') if isinstance(response, dict) else None,
                       sqlstate=response.get('code') if isinstance(response, dict) else None,
                       reason_code=response.get('reason_code') if isinstance(response, dict) else None,
                       rollback_confirmed=response.get('rollback_confirmed') if isinstance(response, dict) else None,
                       failure_audit_id=response.get('failure_audit_id') if isinstance(response, dict) else None,
                       classification=contract.classify(status, response),
                       elapsed_ms=(time.perf_counter()-started)*1000)
        return status, response

    claim.rpc = recorded
    old_sink = claim.EVENT_SINK
    claim.EVENT_SINK = journal.record
    try:
        yield
    finally:
        claim.rpc = original
        claim.EVENT_SINK = old_sink


def rejected_pickup(base, key, token, claim_id):
    for name, params in [('start_pickup', {'p_claim': claim_id}),
                         ('complete_pickup', {'p_claim': claim_id, 'p_handover_confirmed': True})]:
        status, response = claim.rpc(base, key, token, name, params)
        check(status >= 400 and isinstance(response, dict)
              and response.get('code') == 'P0001'
              and response.get('message') == 'NOT_ACTIVE_CLAIM_HOLDER',
              'Expected authoritative holder rejection, not an auth/network/permission error.')


def assert_release(before, after, claim_id, request_id):
    check(after['listing']['listing_status'] == after['donation']['donation_status'] == 'AVAILABLE',
          'Cancellation did not restore listing/donation atomically.')
    check(after['listing']['listing_version'] == before['listing']['listing_version'] + 1
          and after['listing']['eligibility_generation'] == before['listing']['eligibility_generation'] + 1,
          'Cancellation version/generation increment mismatch.')
    c = next(c for c in after['claims'] if c['claim_id'] == claim_id)
    le = next(le for le in after['leases'] if le['claim_id'] == claim_id)
    t = next(t for t in after['tasks'] if t['claim_id'] == claim_id)
    check(c['claim_status'] == le['lease_status'] == 'RELEASED'
          and c['close_reason'] == le['release_reason'] == 'NGO_CANCELLED_BEFORE_PICKUP'
          and t['task_status'] == 'STALE', 'Released holder artifacts are inconsistent.')
    new = [a for a in after['audits'] if a['event_id'] not in {a['event_id'] for a in before['audits']}]
    check(len(new) == 2 and {a['event_type'] for a in new} == {'CANCEL_CLAIM', 'DONATION_STATUS_CHANGED'}
          and all(a['outcome'] == 'SUCCESS' for a in new)
          and all(a['request_id'] == request_id and a['claim_id'] == claim_id
                  and a['lease_id'] == le['lease_id'] and a['correlation_id'] == request_id for a in new)
          and next(a for a in new if a['event_type'] == 'DONATION_STATUS_CHANGED')['reason_code'] == 'NGO_CANCELLED_BEFORE_PICKUP'
          and not after['cases'] and not after['route_count'], 'Cancellation audit/custody mismatch.')
    check(after['refresh_enqueued'], 'Cancellation did not enqueue the new eligibility generation.')


def assert_claim_transition(before, after):
    check(after['listing']['listing_status'] == after['donation']['donation_status'] == 'CLAIMED'
          and after['listing']['listing_version'] == before['listing']['listing_version'] + 1
          and after['listing']['eligibility_generation'] == before['listing']['eligibility_generation'],
          'Claim did not atomically transition donation/listing with the expected version/generation.')
    check(len(after['tasks']) == 1 and after['tasks'][0]['task_status'] == 'CONFIRMED'
          and after['tasks'][0]['pickup_road_node_id'] == after['listing']['pickup_road_node_id']
          and after['tasks'][0]['load_kg'] == after['listing']['listing_weight_kg']
          and not after['cases'] and not after['route_count'],
          'Initial pickup task/custody snapshot is inconsistent.')
    new = [a for a in after['audits'] if a['event_id'] not in {a['event_id'] for a in before['audits']}]
    check(len(new) == 3 and sum(a['event_type'] == 'CLAIM_ATTEMPT' for a in new) == 2
          and sum(a['event_type'] == 'DONATION_STATUS_CHANGED' and a['previous_state'] == 'AVAILABLE'
                  and a['resulting_state'] == 'CLAIMED' and a['outcome'] == 'SUCCESS' for a in new) == 1,
          'Expected exactly two request audits and one donation transition audit.')
    success = next(a for a in new if a['event_type'] == 'CLAIM_ATTEMPT' and a['outcome'] == 'SUCCESS')
    transition = next(a for a in new if a['event_type'] == 'DONATION_STATUS_CHANGED')
    contract.donation_link(transition, success, success['claim_id'], success['lease_id'],
                           success['actor_user_id'], after['listing']['listing_id'], after['donation']['donation_id'])
    check(success['details']['transaction_id'] == transition['details']['transaction_id'],
          'Claim and donation audit transaction IDs differ.')


def assert_stable_unchanged(before, after):
    # A legitimate eligibility worker can complete during a negative/replay test.
    # Queue existence, generation, claims, tasks, audits and all other fields remain checked.
    claim.assert_unchanged({k: v for k, v in before.items() if k != 'current_refresh_completed'},
                           {k: v for k, v in after.items() if k != 'current_refresh_completed'})


def run_acceptance(base, key, service, tokens, subjects, listings, db_url, health, read, journal, baseline):
    def safe_point():
        validate_health(health(), baseline)

    def replay(listing, token, request, claim_id):
        response = claim.claim_attempt(base, key, listing, token, request)
        check(response.get('outcome') == 'SUCCESS' and response.get('replayed') is True
              and response.get('claim_id') == claim_id, 'Replay did not return the original historical result.')

    def cancel(listing, token, claim_id):
        safe_point()
        before = read(listing)
        check(not before['cases'] and not before['route_count'], 'New custody/reconciliation evidence; stop.')
        request = str(uuid.uuid4())
        status, response = claim.rpc(base, key, token, 'cancel_claim',
                                     {'p_claim': claim_id, 'p_request': request})
        check(status == 200 and isinstance(response, dict) and response.get('outcome') == 'SUCCESS',
              'Cancellation not confirmed. Preserve its journaled UUID and inspect; do not blindly retry.')
        after = read(listing)
        assert_release(before, after, claim_id, request)
        journal.record('CANCEL_VERIFIED', listing=listing, claim=claim_id, request=request)

    safe_point()
    initial = {l: read(l) for l in listings}
    attempts, responses, _ = claim.run_race(base, key, service, listings[0], tokens, subjects, 2, 'Stage 3J two-actor')
    winner = next(i for i, r in enumerate(responses) if r['outcome'] == 'SUCCESS')
    loser = 1 - winner
    old_id, old_request = responses[winner]['claim_id'], attempts[winner]['request_id']
    before = read(listings[0])
    assert_claim_transition(initial[listings[0]], before)
    other_before = read(listings[1])
    replay(listings[0], tokens[winner], old_request, old_id)
    for token, listing in ((tokens[loser], listings[0]), (tokens[winner], listings[1])):
        first = claim.expect_payload_rejection(base, key, token, listing, old_request)
        second = claim.expect_payload_rejection(base, key, token, listing, old_request)
        check(first['failure_audit_id'] == second['failure_audit_id'], 'Mismatch retry duplicated its failure receipt.')
        state = read(listing)
        contract.failure_record(second, state['failures'], claim.jwt_subject(token), listing,
                                old_request, state['donation']['donation_id'])
        other = tokens[winner] if token == tokens[loser] else tokens[loser]
        claim.verify_receipt_visibility(base, key, token, other, listing, second)
    # Assert exact new failure rows without excluding the ledger from replay snapshots.
    for original, listing, actor in ((before, listings[0], subjects[loser]),
                                      (other_before, listings[1], subjects[winner])):
        current = read(listing)
        check(len(current['failures']) == len(original['failures']) + 1,
              'Changed payload must add exactly one confirmed failure event per deduplication key.')
        expected = dict(original, failures=current['failures'])
        assert_stable_unchanged(expected, current)
    before, other_before = read(listings[0]), read(listings[1])
    barrier = threading.Barrier(2)
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        futures = [pool.submit(claim.claim_attempt, base, key, listings[0], tokens[winner], old_request, barrier)
                   for _ in range(2)]
        check(all(r.get('replayed') is True and r.get('claim_id') == old_id
                  for r in [f.result() for f in futures]), 'Concurrent replay duplicated/changed the result.')
    rejected_pickup(base, key, tokens[loser], old_id)
    assert_stable_unchanged(before, read(listings[0]))
    assert_stable_unchanged(other_before, read(listings[1]))
    cancel(listings[0], tokens[winner], old_id)
    before = read(listings[0])
    replay(listings[0], tokens[winner], old_request, old_id)
    rejected_pickup(base, key, tokens[winner], old_id)
    # Worker completion fields are deliberately excluded from stable snapshots.
    assert_stable_unchanged(before, read(listings[0]))
    journal.record('REPLAY_PAYLOAD_AND_STALE_HOLDER_PASS', listing=listings[0], claim=old_id)

    safe_point()
    delayed_evidence = claim.run_delayed_race(base, key, service, db_url, listings[1], tokens, subjects)
    journal.record('DELAY_OBSERVATION', **delayed_evidence)
    delayed = read(listings[1])
    assert_claim_transition(initial[listings[1]], delayed)
    active = [c for c in delayed['claims'] if c['claim_status'] == 'ACTIVE']
    check(len(active) == 1, 'Delayed race did not yield exactly one active holder.')
    idx = subjects.index(active[0]['ngo_user_id'])
    cancel(listings[1], tokens[idx], active[0]['claim_id'])
    journal.record('TWO_ACTOR_ACCEPTANCE_PASS', note='No recovery executed; both test claims normally cancelled.')


def prepare(args, actor_count, fixture_count, purpose, runner_path=None):
    """Shared, non-mutating preflight for all three live entry points."""
    check(not args.output_dir.resolve().is_relative_to(ROOT), 'Keep private journals outside the repository.')
    claim.load_env_file(str(args.env_file))
    base, key, service, _, tokens, listings = claim.safety_gate(actor_count, fixture_count)
    label = claim.required('GEOLOCK_STAGE3J_FIXTURE_LABEL')
    donations = [str(uuid.UUID(x)) for x in claim.parse_json_list('GEOLOCK_STAGE3J_DONATION_IDS', fixture_count)]
    subjects = [claim.jwt_subject(t) for t in tokens]
    # All file/target/manifest checks precede the first network request.
    manifest = contract.load_manifest(args.manifest, subjects, listings, donations, label, purpose)
    db_url = database_url()
    journal = Journal(args.output_dir)
    health = lambda: sql_read(db_url, '01_health.sql')
    read = lambda listing: sql_read(db_url, '02_fixture.sql', {'listing': listing})
    baseline = manifest['health_baseline']
    runner_path = Path(runner_path or __file__)
    try:
        subjects = verify_sessions(base, key, tokens, actor_count)
        snapshot = health()
        validate_health(snapshot, baseline)
        journal.record('HEALTH', snapshot=snapshot, actor_subjects=subjects,
                       approval_ref=manifest['approval_ref'], operator=manifest['operator'],
                       manifest_sha256=hashlib.sha256(args.manifest.read_bytes()).hexdigest(),
                       migration_sha256=baseline['migration_sha256'],
                       runner_sha256=hashlib.sha256(runner_path.read_bytes()).hexdigest(),
                       runner=runner_path.name,
                       harness_sha256={name: hashlib.sha256((ROOT/'supabase/tests'/name).read_bytes()).hexdigest()
                         for name in ('claim_two_actor_acceptance.py','claim_concurrency_test.py',
                                      'claim_fault_injection_dev_test.py','claim_e2e_contract.py')})
        for listing, donation in zip(listings, donations):
            validate_fixture(read(listing), listing, donation, label)
        claim.assert_fresh_fixtures(base, service, key, tokens, listings, actor_count)
        journal.record('FIXTURE_BASELINE', fixtures={l: read(l) for l in listings})
    except Exception:
        journal.record('PREFLIGHT_BLOCKED', note='No mutation authorized by this preflight.')
        raise
    return base, key, service, tokens, subjects, listings, db_url, health, read, journal, baseline


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--env-file', type=Path, required=True)
    parser.add_argument('--output-dir', type=Path, required=True, help='New private results folder outside the repo.')
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--execute', action='store_true')
    parser.add_argument('--execution-approval')
    args = parser.parse_args()
    # Refuse before loading credentials or making network calls if approval is wrong.
    check((args.execute and args.execution_approval == APPROVAL)
          or (not args.execute and args.execution_approval is None), 'Explicit two-actor execution approval required.')
    base, key, service, tokens, subjects, listings, db_url, health, read, journal, baseline = prepare(args, 2, 2, 'two_actor')

    try:
        if not args.execute:
            journal.record('PREFLIGHT_PASS', note='No claim/cancel/pickup RPC executed.')
            print('PREFLIGHT PASS. Execution requires separate approval and --execute.')
            return 0
        # Fresh checks immediately before writes; no external three-minute deadline.
        validate_health(health(), baseline)
        with record_rpcs(journal):
            run_acceptance(base, key, service, tokens, subjects, listings, db_url, health, read, journal, baseline)
        final_health = health()
        validate_health(final_health, baseline)
        journal.record('FINAL_HEALTH', snapshot=final_health)
        journal.record('FINAL_FIXTURES', fixtures={l: read(l) for l in listings})
        print('PASS two-actor acceptance. Retain fixtures/audits and private result journal.')
        return 0
    except Exception:
        journal.record('STOP_REVIEW_REQUIRED', note='Inspect journaled UUIDs and committed state; no automatic retry/cleanup.')
        raise


if __name__ == '__main__':
    try:
        sys.exit(main())
    except AcceptanceBlocked as error:
        print(f'BLOCKED: {error} Inspect the private journal; no blind retry.', file=sys.stderr)
        sys.exit(1)
    except Exception:
        # psycopg/HTTP exceptions can contain credentials or payloads; never dump them.
        print('BLOCKED/FAILED: inspect the private journal and reviewed preflight; no blind retry.', file=sys.stderr)
        sys.exit(1)
