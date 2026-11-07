"""DEV-only rollback checks using the separately prepared test-only triggers.

Default preflight is read-only. Explicit approved execution mutates only the dedicated listing and private
geolock_stage2_test failpoint table. Do not run until the user reviews and
manually installs claim_write_failpoints_dev.sql in the disposable DEV project.
Every claim attempt uses an actual authenticated NGO JWT through Supabase RPC.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.parse
import uuid
from pathlib import Path

import claim_concurrency_test as common
import claim_e2e_contract as contract
from stage1_dev_env import load_env_file
from claim_concurrency_test import (
    http_call,
    jwt_subject,
    required,
    rest_rows,
    safety_gate,
)

FAILPOINTS = (
    "claim_requests_insert",
    "donation_claims_insert",
    "claim_leases_insert",
    "listings_update",
    "pickup_tasks_insert",
    "claim_requests_update",
    "audit_events_insert",
)


def verify_no_partial_state(conn, request_id: str, listing_id: str) -> None:
    checks = {
        "claim_requests": ("SELECT count(*) FROM public.claim_requests WHERE request_id=%s",),
        "donation_claims": ("SELECT count(*) FROM public.donation_claims WHERE request_id=%s",),
        "claim_leases": ("SELECT count(*) FROM public.claim_leases l JOIN public.donation_claims c USING (claim_id) WHERE c.request_id=%s",),
        "pickup_tasks": ("SELECT count(*) FROM public.pickup_tasks t JOIN public.donation_claims c USING (claim_id) WHERE c.request_id=%s",),
        "audit_events": ("SELECT count(*) FROM public.audit_events WHERE request_id=%s",),
    }
    with conn.cursor() as cursor:
        for table, (query,) in checks.items():
            cursor.execute(query, (request_id,))
            if cursor.fetchone()[0] != 0:
                raise RuntimeError(f"Rollback failed: residual {table} row exists.")
        cursor.execute("SELECT listing_status FROM public.listings WHERE listing_id=%s", (listing_id,))
        row = cursor.fetchone()
        if row is None or row[0] != "AVAILABLE":
            raise RuntimeError("Rollback failed: test listing is missing or no longer AVAILABLE.")


def verify_hooks(conn):
    with conn.cursor() as cursor:
        cursor.execute("SELECT to_regclass('geolock_stage2_test.claim_write_failpoints')")
        if cursor.fetchone()[0] is None:
            raise RuntimeError('Request-scoped hooks are absent; this runner never installs them.')
        cursor.execute('SELECT count(*) FROM geolock_stage2_test.claim_write_failpoints')
        if cursor.fetchone()[0] != 0:
            raise RuntimeError('Stale failpoint registrations require manual review; no global cleanup permitted.')
        cursor.execute("SELECT t.tgname,t.tgrelid::regclass::text,t.tgfoid::regprocedure::text,"
                       "t.tgenabled,pg_get_triggerdef(t.oid),md5(replace(p.prosrc,E'\\r\\n',E'\\n')) "
                       "FROM pg_trigger t JOIN pg_proc p ON p.oid=t.tgfoid "
                       "WHERE NOT t.tgisinternal AND t.tgname LIKE 'geolock_stage2_fail_%' ORDER BY t.tgname")
        return cursor.fetchall()


def verify_failure_authorization(base, key, tokens, listing, receipt):
    status, events = common.rpc(base, key, tokens[0], 'get_authorized_audit_events',
                               {'p_entity_type': 'LISTING', 'p_entity_id': listing})
    contract.check(status == 200 and isinstance(events, list)
        and any(e.get('event_id') == receipt['failure_audit_id'] and e.get('event_type') == 'CLAIM_FAILURE'
                and e.get('outcome') == 'ERROR' and e.get('lease_id') is None for e in events),
        'Actor cannot retrieve its own confirmed failure projection.')
    status, response = common.rpc(base, key, tokens[1], 'get_authorized_audit_events',
                                  {'p_entity_type': 'LISTING', 'p_entity_id': listing})
    contract.check(status >= 400 and isinstance(response, dict) and response.get('code') == 'P0001'
        and response.get('message') == 'AUDIT_NOT_FOUND_OR_FORBIDDEN',
        'Unrelated NGO must receive authoritative audit access denial.')


def main() -> int:
    import claim_two_actor_acceptance as suite
    import psycopg
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--env-file', type=Path, required=True)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--output-dir', type=Path, required=True)
    parser.add_argument('--actors', type=int, choices=(2, 10), default=2)
    parser.add_argument('--execute', action='store_true')
    parser.add_argument('--execution-approval')
    args = parser.parse_args()
    contract.check((args.execute and args.execution_approval == 'I_APPROVE_DEV_CLAIM_FAULT_INJECTION')
        or (not args.execute and args.execution_approval is None), 'Explicit fault-injection execution approval required.')
    ctx = suite.prepare(args, args.actors, 1, 'fault_injection', runner_path=Path(__file__))
    base, key, service, tokens, subjects, listings, db_url, health, read, journal, baseline = ctx
    listing = listings[0]
    # Inspection uses a READ ONLY connection. Missing hooks never trigger DDL.
    with psycopg.connect(db_url, connect_timeout=5) as conn:
        with conn.cursor() as cur:
            cur.execute('SET TRANSACTION READ ONLY')
            hooks = verify_hooks(conn)
    expected = {'geolock_stage2_fail_' + point: point.rsplit('_', 1)[0] for point in FAILPOINTS}
    contract.check({r[0]: r[1].split('.')[-1] for r in hooks} == expected,
                   'Installed hooks do not exactly match the seven request-scoped targets.')
    contract.check(all(r[2] == 'geolock_stage2_test.fail_claim_write()' and r[3] == 'O' for r in hooks),
                   'Hook function or enabled state differs.')
    # Exact definitions, trigger conditions and helper source require reviewed pins.
    hook_baseline = json.loads(args.manifest.read_text())['fault_hooks']
    contract.check([list(r) for r in hooks] == hook_baseline,
                   'Reviewed failpoint source/trigger definitions differ; do not auto-adopt them.')
    if not args.execute:
        journal.record('PREFLIGHT_PASS', note='No failpoint registrations or claim RPCs executed.')
        print('FAULT PREFLIGHT PASS; hooks were inspected only.')
        return 0
    try:
        with psycopg.connect(db_url, autocommit=True, connect_timeout=5) as conn, suite.record_rpcs(journal):
            for fail_at in FAILPOINTS:
                suite.validate_health(health(), baseline)
                before = read(listing)
                request = str(uuid.uuid4())
                journal.record('FAILPOINT_REGISTER', listing=listing, request=request, fail_at=fail_at)
                with conn.cursor() as cur:
                    cur.execute('INSERT INTO geolock_stage2_test.claim_write_failpoints(request_id,fail_at) VALUES (%s,%s)',
                                (request, fail_at))
                # On uncertainty or assertion failure, preserve this registration for review.
                # Clearing it automatically could make an interrupted retry consume the listing.
                first = common.claim_attempt(base, key, listing, tokens[0], request)
                contract.confirmed_receipt(200, first, contract.ROLLBACK_REASON)
                second = common.claim_attempt(base, key, listing, tokens[0], request)
                with common.concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
                    barrier = common.threading.Barrier(2)
                    concurrent = list(pool.map(lambda _: common.claim_attempt(
                        base, key, listing, tokens[0], request, barrier), range(2)))
                for receipt in [second] + concurrent:
                    contract.confirmed_receipt(200, receipt, contract.ROLLBACK_REASON)
                    contract.check(receipt['failure_audit_id'] == first['failure_audit_id'],
                                   'Failure retry created a different receipt ID.')
                after = read(listing)
                row = contract.failure_record(first, after['failures'], subjects[0], listing,
                                               request, after['donation']['donation_id'])
                contract.failure_append(before['failures'], after['failures'], first['failure_audit_id'])
                contract.check(row['details'].get('previous_state') == row['details'].get('resulting_state') == 'AVAILABLE',
                               'Confirmed rollback did not restore donation/listing state.')
                suite.assert_stable_unchanged(dict(before, failures=after['failures']), after)
                verify_no_partial_state(conn, request, listing)
                verify_failure_authorization(base, key, tokens, listing, first)
                journal.record('ROLLBACK_VERIFIED', request=request, failure=row, fail_at=fail_at)
                with conn.cursor() as cur:
                    cur.execute('DELETE FROM geolock_stage2_test.claim_write_failpoints WHERE request_id=%s AND fail_at=%s',
                                (request, fail_at))
                    contract.check(cur.rowcount == 1, 'Exact test-owned registration was not removed.')
                    cur.execute('SELECT count(*) FROM geolock_stage2_test.claim_write_failpoints WHERE request_id=%s', (request,))
                    contract.check(cur.fetchone()[0] == 0, 'Test registration remains after exact removal.')
            # The last failed request is retryable after its fault is removed.
            suite.validate_health(health(), baseline)
            success = common.claim_attempt(base, key, listing, tokens[0], request)
            state = common.assert_committed_round(base, service, listing,
                [{'request_id': request}], [success], [subjects[0]],
                expected_failure_ids=[first['failure_audit_id']])
            replay = common.claim_attempt(base, key, listing, tokens[0], request)
            contract.check(replay.get('replayed') is True and replay.get('claim_id') == success['claim_id'],
                           'Post-fault successful retry is not idempotent.')
            common.assert_unchanged(state, common.get_state(base, service, listing, [request]))
            journal.record('POST_FAULT_RETRY_VERIFIED', state=state, fixture=read(listing))
        print('PASS fault receipts and deduplication; retain all business/audit history. No recovery.')
        return 0
    except Exception:
        journal.record('STOP_REVIEW_REQUIRED', note='Preserve request UUID and failpoint registration; no automatic cleanup/retry.')
        raise


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception:
        print('FAULT TEST BLOCKED/FAILED: inspect private journal; outcome may be unconfirmed. No blind retry.', file=sys.stderr)
        sys.exit(1)
