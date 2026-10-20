"""DEV-only rollback checks using the separately prepared test-only triggers.

This script mutates only the dedicated fault-injection listing and private
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
        "audit_events": ("SELECT count(*) FROM public.audit_events WHERE request_id=%s AND event_type='CLAIM_ATTEMPT'",),
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


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--env-file", type=Path, default=None)
    args = parser.parse_args()
    load_env_file(str(args.env_file) if args.env_file else None)
    base, publishable, service_role, _ref, tokens, listing_ids = safety_gate()
    if len({jwt_subject(token) for token in tokens}) != 10:
        raise RuntimeError("The configured sessions must belong to ten distinct NGOs.")

    fault_listing = str(uuid.UUID(required("GEOLOCK_TEST_FAULT_LISTING_ID")))
    service_query = urllib.parse.urlencode({
        "listing_id": f"eq.{fault_listing}",
        "select": "listing_id,listing_status,pickup_road_node_id",
    })
    rows = rest_rows(base, service_role, f"listings?{service_query}")
    if len(rows) != 1 or rows[0].get("listing_status") != "AVAILABLE" or not rows[0].get("pickup_road_node_id"):
        raise RuntimeError("Fault-injection listing must be dedicated, AVAILABLE, and have trusted road-node assignment.")
    status, eligible = http_call(base, publishable, tokens[0], "rpc/discover_eligible_listing_cards", {})
    if status != 200 or not isinstance(eligible, list) or not any(
        isinstance(row, dict) and str(row.get("listing_id")) == fault_listing for row in eligible
    ):
        raise RuntimeError("Fault-injection NGO is not actually eligible for the dedicated listing.")

    db_url = required("GEOLOCK_TEST_DATABASE_URL")
    parsed = urllib.parse.urlparse(db_url)
    if (parsed.hostname != "aws-0-ap-northeast-2.pooler.supabase.com" or parsed.port != 5432
            or parsed.username != "postgres.rcgyuwiidqvrgbxswhqj" or parsed.path != "/postgres"
            or urllib.parse.parse_qs(parsed.query).get("sslmode") != ["require"]):
        raise RuntimeError("Fault injection requires the verified isolated DEV Session Pooler over SSL.")
    try:
        import psycopg
    except ImportError:
        raise RuntimeError("Install psycopg 3 from supabase/tests/requirements-dev-fixtures.txt.") from None

    try:
        conn = psycopg.connect(db_url, autocommit=True)
    except Exception:
        raise RuntimeError("Could not connect to the allowlisted DEV database; connection details were not logged.") from None
    try:
        with conn.cursor() as cursor:
            cursor.execute("SELECT to_regclass('geolock_stage2_test.claim_write_failpoints')")
            if cursor.fetchone()[0] is None:
                raise RuntimeError("Test-only failpoint hooks are not installed; review/install the separate SQL support file first.")
            cursor.execute("SELECT count(*) FROM geolock_stage2_test.claim_write_failpoints")
            if cursor.fetchone()[0] != 0:
                raise RuntimeError("Stale failpoint rows exist; inspect and run the separate cleanup script before testing.")
            cursor.execute(
                "SELECT t.tgname, t.tgrelid::regclass::text, "
                "n.nspname || '.' || p.proname "
                "FROM pg_catalog.pg_trigger AS t "
                "JOIN pg_catalog.pg_proc AS p ON p.oid=t.tgfoid "
                "JOIN pg_catalog.pg_namespace AS n ON n.oid=p.pronamespace "
                "WHERE NOT t.tgisinternal AND t.tgname LIKE 'geolock_stage2_fail_%'"
            )
            actual = {row[0]: (row[1], row[2]) for row in cursor.fetchall()}
            expected = {
                "geolock_stage2_fail_claim_requests_insert": ("claim_requests", "geolock_stage2_test.fail_claim_write"),
                "geolock_stage2_fail_claim_requests_update": ("claim_requests", "geolock_stage2_test.fail_claim_write"),
                "geolock_stage2_fail_donation_claims_insert": ("donation_claims", "geolock_stage2_test.fail_claim_write"),
                "geolock_stage2_fail_claim_leases_insert": ("claim_leases", "geolock_stage2_test.fail_claim_write"),
                "geolock_stage2_fail_listings_update": ("listings", "geolock_stage2_test.fail_claim_write"),
                "geolock_stage2_fail_pickup_tasks_insert": ("pickup_tasks", "geolock_stage2_test.fail_claim_write"),
                "geolock_stage2_fail_audit_events_insert": ("audit_events", "geolock_stage2_test.fail_claim_write"),
            }
            normalized = {name: (relation.split(".")[-1], function) for name, (relation, function) in actual.items()}
            if normalized != expected:
                raise RuntimeError("Installed failpoint triggers do not exactly match the expected test-owned trigger map; no claim test was started.")

        for fail_at in FAILPOINTS:
            request_id = str(uuid.uuid4())
            try:
                with conn.cursor() as cursor:
                    cursor.execute(
                        "INSERT INTO geolock_stage2_test.claim_write_failpoints(request_id,fail_at) VALUES (%s,%s)",
                        (request_id, fail_at),
                    )
                status, result = http_call(base, publishable, tokens[0], "rpc/claim_listing", {
                    "p_listing": fault_listing, "p_request": request_id,
                })
                message = result.get("message", "") if isinstance(result, dict) else ""
                expected = f"STAGE2_TEST_FAILPOINT:{fail_at}"
                if status < 400 or expected not in str(message):
                    raise RuntimeError(f"Expected {fail_at} injected failure was not observed.")
            finally:
                with conn.cursor() as cursor:
                    cursor.execute(
                        "DELETE FROM geolock_stage2_test.claim_write_failpoints WHERE request_id=%s",
                        (request_id,),
                    )
                    cursor.execute(
                        "SELECT count(*) FROM geolock_stage2_test.claim_write_failpoints WHERE request_id=%s",
                        (request_id,),
                    )
                    if cursor.fetchone()[0] != 0:
                        raise RuntimeError("Failpoint request UUID remains registered after cleanup.")
            verify_no_partial_state(conn, request_id, fault_listing)
            print(f"PASS rollback at {fail_at}: no claim/request/lease/listing/task/audit partial state remains.")
    finally:
        conn.close()

    print(json.dumps({"project_ref": "rcgyuwiidqvrgbxswhqj", "failpoints_checked": list(FAILPOINTS)}, indent=2))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        # Keep JWTs, DB URLs, and response bodies out of logs.
        print(f"FAULT-INJECTION TEST BLOCKED/FAILED: {error}", file=sys.stderr)
        sys.exit(1)
