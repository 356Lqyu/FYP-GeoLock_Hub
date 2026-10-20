"""Atomic claim acceptance tests for the isolated GeoLock Hub DEV project.

This script is state-changing. It consumes only dedicated, disposable AVAILABLE
listings supplied in the local test env file. It requires ten distinct,
legitimately authenticated and already eligible NGO sessions. No fixture
locations or road-node records are created by this test.

Required local env keys are documented in claim_concurrency_test.env.template.
Never commit that filled file or print its contents/JWTs.
"""
from __future__ import annotations

import argparse
import base64
import concurrent.futures
import json
import os
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from datetime import datetime
from pathlib import Path
from urllib.parse import urlparse

from stage1_dev_env import load_env_file

DEV_PROJECT_REF = "rcgyuwiidqvrgbxswhqj"
BLOCKED_PROJECT_REF = "mffccmlimmbrgasgfnnq"
CONFIRMATION = "I_CONFIRM_DISPOSABLE_DEV_PROJECT"
COUNTS = (2, 10)
EXPECTED_CLAIM_LEASE_SECONDS = 360 * 60
DELAY_OBSERVATION_TIMEOUT_SECONDS = 20


def required(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value or "<paste-" in value.lower() or value.startswith("<"):
        raise RuntimeError(f"Missing or placeholder value for {name}.")
    return value


def parse_json_list(name: str, minimum: int) -> list[str]:
    try:
        value = json.loads(required(name))
    except json.JSONDecodeError:
        raise RuntimeError(f"{name} must contain a JSON array.") from None
    if not isinstance(value, list) or len(value) < minimum or not all(isinstance(x, str) and x for x in value):
        raise RuntimeError(f"{name} must contain at least {minimum} non-empty strings.")
    return value


def project_ref(url: str) -> str:
    parsed = urlparse(url)
    suffix = ".supabase.co"
    host = parsed.hostname or ""
    if parsed.scheme != "https" or not host.endswith(suffix):
        raise RuntimeError("Use the canonical HTTPS URL for the exact isolated DEV project.")
    if parsed.port is not None or parsed.username or parsed.password or parsed.path not in {"", "/"} or parsed.query or parsed.fragment:
        raise RuntimeError("The Supabase URL must not contain credentials, path, query, or fragment.")
    return host[:-len(suffix)]


def safety_gate() -> tuple[str, str, str, str, list[str], list[str]]:
    if required("GEOLOCK_TEST_CONFIRMATION") != CONFIRMATION:
        raise RuntimeError("Refusing to run without isolated disposable DEV confirmation.")
    base_url = required("GEOLOCK_TEST_SUPABASE_URL").rstrip("/")
    ref = project_ref(base_url)
    allowed = {item.strip() for item in required("GEOLOCK_TEST_ALLOWED_PROJECT_REFS").split(",") if item.strip()}
    configured = required("GEOLOCK_TEST_PROJECT_REF")
    if ref == BLOCKED_PROJECT_REF or ref != DEV_PROJECT_REF or configured != DEV_PROJECT_REF or allowed != {DEV_PROJECT_REF}:
        raise RuntimeError("Project reference and exact allowlist must contain only isolated DEV rcgyuwiidqvrgbxswhqj.")
    inherited = os.environ.get("SUPABASE_URL", "").strip()
    if inherited and project_ref(inherited.rstrip("/")) != ref:
        raise RuntimeError("Inherited SUPABASE_URL points to a different project; refusing to run.")

    publishable = required("GEOLOCK_TEST_PUBLISHABLE_KEY")
    service_role = required("GEOLOCK_TEST_SERVICE_ROLE_KEY")
    if publishable.startswith("sb_secret_") or "service_role" in publishable.lower():
        raise RuntimeError("Publishable-key variable contains a privileged credential.")
    if service_role == publishable:
        raise RuntimeError("Service-role and publishable credentials must be separate values.")
    tokens = parse_json_list("GEOLOCK_TEST_NGO_JWT_TOKENS", 10)
    listing_ids = parse_json_list("GEOLOCK_TEST_LISTING_IDS", 4)
    try:
        [str(uuid.UUID(value)) for value in listing_ids]
    except ValueError:
        raise RuntimeError("Every listing ID must be a UUID.") from None
    if len(set(listing_ids)) != 4:
        raise RuntimeError("Provide exactly four distinct dedicated AVAILABLE listing UUIDs.")
    if len(tokens) < 10:
        raise RuntimeError("At least ten NGO sessions are required.")
    return base_url, publishable, service_role, ref, tokens[:10], listing_ids


def jwt_subject(token: str) -> str:
    try:
        parts = token.split(".")
        if len(parts) != 3:
            raise ValueError
        payload = parts[1] + "=" * (-len(parts[1]) % 4)
        subject = json.loads(base64.urlsafe_b64decode(payload.encode("ascii"))).get("sub")
        return str(uuid.UUID(subject))
    except Exception:
        raise RuntimeError("An NGO token is malformed or has no valid subject.") from None


def http_call(base: str, key: str, token: str, path: str, payload: object | None = None,
              discard_body: bool = False) -> tuple[int, object | None]:
    data = None if payload is None else json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        f"{base}/rest/v1/{path}", data=data,
        headers={"apikey": key, "Authorization": f"Bearer {token}",
                 "Content-Type": "application/json"},
        method="GET" if data is None else "POST")
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            if discard_body:
                # The RPC has returned successfully and committed, but the
                # application intentionally discards its response body.
                return response.status, None
            body = response.read().decode("utf-8")
            return response.status, json.loads(body) if body else None
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8", errors="replace")
        try:
            parsed: object | None = json.loads(body)
        except json.JSONDecodeError:
            parsed = None
        return error.code, parsed
    except urllib.error.URLError as error:
        raise RuntimeError(f"Supabase request did not complete ({error.reason}); no credentials or response body logged.") from None


def rest_rows(base: str, service: str, table_query: str) -> list[dict]:
    status, result = http_call(base, service, service, table_query)
    if status != 200 or not isinstance(result, list):
        raise RuntimeError(f"Read-only DEV verification query failed for {table_query.split('?')[0]} (HTTP {status}).")
    return result


def rpc(base: str, key: str, token: str, name: str, payload: dict) -> tuple[int, object | None]:
    return http_call(base, key, token, f"rpc/{name}", payload)


def require_success(status: int, result: object, context: str) -> dict:
    if status != 200 or not isinstance(result, dict):
        raise RuntimeError(f"{context} did not return an authoritative JSON result (HTTP {status}).")
    return result


def assert_fresh_fixtures(base: str, service: str, key: str,
                          tokens: list[str], listing_ids: list[str]) -> list[str]:
    subjects = [jwt_subject(token) for token in tokens]
    if len(set(subjects)) != 10:
        raise RuntimeError("The ten JWTs must belong to ten distinct NGO users.")

    cfg = rest_rows(base, service, "coordination_config?select=singleton,claim_lease_minutes&singleton=eq.true")
    if len(cfg) != 1 or cfg[0].get("claim_lease_minutes") != 360:
        raise RuntimeError("DEV must have exactly one singleton coordination config with a 360-minute claim lease.")

    for listing_id in listing_ids:
        query = urllib.parse.urlencode({
            "listing_id": f"eq.{listing_id}",
            "select": "listing_id,listing_status,pickup_road_node_id",
        })
        rows = rest_rows(base, service, f"listings?{query}")
        if len(rows) != 1 or rows[0].get("listing_status") != "AVAILABLE" or not rows[0].get("pickup_road_node_id"):
            raise RuntimeError("Each dedicated listing must exist, be AVAILABLE, and have a trusted road-node assignment.")
        history_query = urllib.parse.urlencode({
            "listing_id": f"eq.{listing_id}", "select": "claim_id",
        })
        if rest_rows(base, service, f"donation_claims?{history_query}"):
            raise RuntimeError("Each dedicated listing must have no prior claim history.")
        active_query = urllib.parse.urlencode({
            "listing_id": f"eq.{listing_id}",
            "claim_status": "in.(ACTIVE,RECONCILIATION_REQUIRED)",
            "select": "claim_id",
        })
        if rest_rows(base, service, f"donation_claims?{active_query}"):
            raise RuntimeError("A dedicated listing already has an active or reconciliation-required claim.")

    # Check authorization and database eligibility through the actual discovery
    # RPC. Do not seed verification, locations, or road-node values here.
    eligibility = {
        listing_ids[0]: tokens[:2],
        listing_ids[1]: tokens[:10],
        listing_ids[2]: tokens[:2],
        listing_ids[3]: tokens[:1],
    }
    for listing_id, listing_tokens in eligibility.items():
        for token in listing_tokens:
            status, result = rpc(base, key, token, "discover_eligible_listing_cards", {})
            if status != 200 or not isinstance(result, list) or not any(str(row.get("listing_id")) == listing_id for row in result if isinstance(row, dict)):
                raise RuntimeError("A fixture is not discoverable for every assigned NGO; trusted verification/road-network eligibility is not satisfied.")
    return subjects


def claim_attempt(base: str, key: str, listing_id: str, token: str,
                  request_id: str, barrier: threading.Barrier | None = None) -> dict:
    if barrier is not None:
        barrier.wait(timeout=30)
    status, result = rpc(base, key, token, "claim_listing", {
        "p_listing": listing_id, "p_request": request_id,
    })
    return require_success(status, result, "claim_listing")


def get_state(base: str, service: str, listing_id: str, request_ids: list[str]) -> dict:
    in_list = "(" + ",".join(request_ids) + ")"
    claim_q = urllib.parse.urlencode({
        "or": f"(listing_id.eq.{listing_id},request_id.in.{in_list})",
        "select": "claim_id,listing_id,ngo_user_id,request_id,claim_status,claimed_at",
    })
    claims = rest_rows(base, service, f"donation_claims?{claim_q}")
    active_claims = [row for row in claims if row.get("claim_status") in {"ACTIVE", "RECONCILIATION_REQUIRED"}]
    listing_q = urllib.parse.urlencode({"listing_id": f"eq.{listing_id}", "select": "listing_id,listing_status"})
    listings = rest_rows(base, service, f"listings?{listing_q}")
    request_q = urllib.parse.urlencode({
        "request_id": f"in.{in_list}",
        "select": "request_id,listing_id,ngo_user_id,outcome,result_claim_id,reason_code,completed_at",
    })
    requests = rest_rows(base, service, f"claim_requests?{request_q}")
    audit_q = urllib.parse.urlencode({
        "request_id": f"in.{in_list}", "event_type": "eq.CLAIM_ATTEMPT",
        "select": "event_id,actor_user_id,actor_role,entity_type,entity_id,event_type,request_id,claim_id,lease_id,previous_state,requested_state,resulting_state,reason_code,outcome,configuration_version,occurred_at",
    })
    audits = rest_rows(base, service, f"audit_events?{audit_q}")
    leases: list[dict] = []
    tasks: list[dict] = []
    for claim in claims:
        lease_q = urllib.parse.urlencode({
            "claim_id": f"eq.{claim['claim_id']}",
            "select": "lease_id,claim_id,lease_status,issued_at,expires_at",
        })
        leases.extend(rest_rows(base, service, f"claim_leases?{lease_q}"))
        task_q = urllib.parse.urlencode({
            "claim_id": f"eq.{claim['claim_id']}",
            "select": "task_id,claim_id,listing_id,ngo_user_id,pickup_road_node_id,load_kg,task_status",
        })
        tasks.extend(rest_rows(base, service, f"pickup_tasks?{task_q}"))
    return {"claims": claims, "active_claims": active_claims, "listings": listings, "requests": requests,
            "audits": audits, "leases": leases, "tasks": tasks}


def assert_committed_round(base: str, service: str, listing_id: str,
                           attempts: list[dict], responses: list[dict],
                           subjects: list[str], expect_conflicts: bool = True) -> dict:
    state = get_state(base, service, listing_id, [a["request_id"] for a in attempts])
    winners = [i for i, response in enumerate(responses) if response.get("outcome") == "SUCCESS"]
    if len(winners) != 1:
        raise RuntimeError("Expected exactly one SUCCESS response.")
    winner_index = winners[0]
    expected_other = {"CONFLICT"} if expect_conflicts else {"CONFLICT", "INELIGIBLE"}
    if any(response.get("outcome") not in ({"SUCCESS"} | expected_other) for response in responses):
        raise RuntimeError("A claim returned an unexpected outcome.")
    for response in responses:
        if response.get("outcome") == "CONFLICT" and response.get("reason_code") != "CLAIM_CONFLICT":
            raise RuntimeError("A CONFLICT response did not include reason_code=CLAIM_CONFLICT.")
    winner_response = responses[winner_index]
    claim_id = winner_response.get("claim_id")
    if not claim_id:
        raise RuntimeError("SUCCESS response has no claim ID.")
    if len(state["active_claims"]) != 1 or state["active_claims"][0]["claim_id"] != claim_id:
        raise RuntimeError("Committed database state does not contain exactly the response's one active claim.")
    if len(state["claims"]) != 1:
        raise RuntimeError("Fresh test listing contains unexpected additional historical claim records.")
    claim = state["active_claims"][0]
    if claim["request_id"] != attempts[winner_index]["request_id"] or claim["ngo_user_id"] != subjects[winner_index]:
        raise RuntimeError("Committed claim owner/request does not match the winning authenticated NGO.")
    if len(state["listings"]) != 1 or state["listings"][0].get("listing_status") != "CLAIMED":
        raise RuntimeError("Listing did not commit as CLAIMED with its active claim.")
    if len(state["leases"]) != 1 or state["leases"][0].get("claim_id") != claim_id or state["leases"][0].get("lease_status") != "ACTIVE":
        raise RuntimeError("Expected exactly one active lease for the winning claim.")
    lease = state["leases"][0]
    try:
        issued = datetime.fromisoformat(lease["issued_at"].replace("Z", "+00:00"))
        expires = datetime.fromisoformat(lease["expires_at"].replace("Z", "+00:00"))
    except (KeyError, ValueError, TypeError):
        raise RuntimeError("Lease timestamps were not returned in a parseable format.") from None
    if abs((expires - issued).total_seconds() - EXPECTED_CLAIM_LEASE_SECONDS) > 2:
        raise RuntimeError("Committed claim lease duration is not 360 minutes.")
    if len(state["tasks"]) != 1 or state["tasks"][0].get("claim_id") != claim_id or state["tasks"][0].get("listing_id") != listing_id:
        raise RuntimeError("Expected exactly one pickup task linked to the winning claim and listing.")
    if len(state["requests"]) != len(attempts) or len(state["audits"]) != len(attempts):
        raise RuntimeError("Each initial attempt must have one persisted claim request and one CLAIM_ATTEMPT audit event.")
    requests_by_id = {row["request_id"]: row for row in state["requests"]}
    audits_by_id: dict[str, list[dict]] = {}
    for event in state["audits"]:
        audits_by_id.setdefault(event["request_id"], []).append(event)
    for i, attempt in enumerate(attempts):
        request = requests_by_id.get(attempt["request_id"])
        events = audits_by_id.get(attempt["request_id"], [])
        if request is None or len(events) != 1:
            raise RuntimeError("Claim request or its durable audit event is missing/duplicated.")
        if request["ngo_user_id"] != subjects[i] or request["listing_id"] != listing_id:
            raise RuntimeError("Persisted request actor or listing differs from the request payload.")
        event = events[0]
        if event.get("actor_user_id") != subjects[i] or event.get("actor_role") != "NGO" or event.get("entity_id") != listing_id:
            raise RuntimeError("Claim audit actor, role, or entity does not match the authenticated request.")
        if i == winner_index:
            if request.get("outcome") != "SUCCESS" or request.get("result_claim_id") != claim_id:
                raise RuntimeError("Winning request did not persist the successful claim result.")
            if event.get("outcome") != "SUCCESS" or event.get("claim_id") != claim_id or event.get("lease_id") != lease["lease_id"]:
                raise RuntimeError("Successful claim audit does not reference the committed claim and lease.")
        else:
            if request.get("outcome") != "CONFLICT" or request.get("reason_code") != "CLAIM_CONFLICT":
                raise RuntimeError("Losing request was not durably recorded as CLAIM_CONFLICT.")
            if event.get("outcome") != "REJECTED" or event.get("reason_code") != "CLAIM_CONFLICT":
                raise RuntimeError("Rejected claim audit is missing or does not show CLAIM_CONFLICT.")
    return state


def assert_unchanged(original: dict, current: dict) -> None:
    for key in ("claims", "listings", "requests", "audits", "leases", "tasks"):
        if original[key] != current[key]:
            raise RuntimeError(f"Unexpected committed changes detected in {key} after an idempotency replay/mismatch.")


def expect_payload_rejection(base: str, key: str, token: str,
                             listing_id: str, request_id: str) -> None:
    status, result = rpc(base, key, token, "claim_listing", {
        "p_listing": listing_id, "p_request": request_id,
    })
    message = result.get("message", "") if isinstance(result, dict) else ""
    if status < 400 or "IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD" not in str(message):
        raise RuntimeError("Changed payload was not rejected with IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD.")


def run_race(base: str, key: str, service: str, listing_id: str,
             tokens: list[str], subjects: list[str], count: int,
             label: str) -> tuple[list[dict], list[dict], dict]:
    attempts = [{"token": tokens[i], "request_id": str(uuid.uuid4())} for i in range(count)]
    barrier = threading.Barrier(count)
    def call(attempt: dict) -> dict:
        return claim_attempt(base, key, listing_id, attempt["token"], attempt["request_id"], barrier)
    with concurrent.futures.ThreadPoolExecutor(max_workers=count) as pool:
        responses = list(pool.map(call, attempts))
    state = assert_committed_round(base, service, listing_id, attempts, responses, subjects)
    print(f"PASS {label}: one SUCCESS, {count - 1} CONFLICT; committed claim/lease/listing/task/audit verified.")
    return attempts, responses, state


def run_discarded_response_retry(base: str, key: str, service: str, listing_id: str,
                                 token: str, subject: str) -> dict:
    request_id = str(uuid.uuid4())
    status, _ = http_call(base, key, token, "rpc/claim_listing", {
        "p_listing": listing_id, "p_request": request_id,
    }, discard_body=True)
    if status != 200:
        raise RuntimeError("Discarded-response case did not receive a successful HTTP response.")
    replay = claim_attempt(base, key, listing_id, token, request_id)
    if replay.get("outcome") != "SUCCESS" or replay.get("replayed") is not True or not replay.get("claim_id"):
        raise RuntimeError("Retry after discarded response did not reconcile to the original committed claim.")
    attempt = [{"token": token, "request_id": request_id}]
    state = assert_committed_round(base, service, listing_id, attempt, [replay], [subject], expect_conflicts=False)
    if len(state["claims"]) != 1 or state["claims"][0].get("claim_id") != replay["claim_id"] or state["claims"][0].get("ngo_user_id") != subject:
        raise RuntimeError("Discarded-response retry created missing or duplicate claim state.")
    if len(state["leases"]) != 1 or len(state["tasks"]) != 1 or len(state["audits"]) != 1 or len(state["requests"]) != 1:
        raise RuntimeError("Discarded-response retry created duplicate/missing committed artifacts.")
    print("PASS discarded-response retry: HTTP response received and body discarded; same UUID returned original claim.")
    return state


def run_delayed_race(base: str, key: str, service: str, db_url: str,
                     listing_id: str, tokens: list[str], subjects: list[str]) -> None:
    try:
        import psycopg
    except ImportError:
        raise RuntimeError("Delayed-lock test needs psycopg 3; install supabase/tests/requirements-dev-fixtures.txt.") from None
    parsed = urlparse(db_url)
    if (parsed.hostname != "aws-0-ap-northeast-2.pooler.supabase.com" or parsed.port != 5432
            or parsed.username != f"postgres.{DEV_PROJECT_REF}" or parsed.path != "/postgres"
            or urllib.parse.parse_qs(parsed.query).get("sslmode") != ["require"]):
        raise RuntimeError("Delayed-lock database connection must use the verified isolated DEV Session Pooler with SSL.")

    attempts = [{"token": tokens[i], "request_id": str(uuid.uuid4())} for i in range(2)]
    barrier = threading.Barrier(2)
    lock_conn = psycopg.connect(db_url, autocommit=False)
    try:
        with lock_conn.cursor() as cursor:
            cursor.execute("SELECT pg_backend_pid()")
            holder_pid = cursor.fetchone()[0]
            cursor.execute("SELECT listing_id FROM public.listings WHERE listing_id = %s FOR UPDATE", (listing_id,))
            if cursor.fetchone() is None:
                raise RuntimeError("Delayed-race listing disappeared before lock acquisition.")
        def call(attempt: dict) -> dict:
            return claim_attempt(base, key, listing_id, attempt["token"], attempt["request_id"], barrier)
        observed = False
        try:
            with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
                futures = [pool.submit(call, attempt) for attempt in attempts]
                deadline = time.monotonic() + DELAY_OBSERVATION_TIMEOUT_SECONDS
                while time.monotonic() < deadline:
                    with lock_conn.cursor() as cursor:
                        cursor.execute(
                            "SELECT count(DISTINCT a.pid) "
                            "FROM pg_stat_activity AS a "
                            "WHERE a.datname = current_database() "
                            "AND a.wait_event_type = 'Lock' "
                            "AND a.query ILIKE '%claim_listing%' "
                            "AND %s = ANY(pg_blocking_pids(a.pid))",
                            (holder_pid,),
                        )
                        count = cursor.fetchone()[0]
                    if count >= 2:
                        observed = True
                        break
                    time.sleep(0.2)
        finally:
            # Release the blocker before executor shutdown/result collection so
            # an inconclusive observation cannot strand requests behind a lock.
            lock_conn.commit()
        responses = [future.result(timeout=90) for future in futures]
        if not observed:
            raise RuntimeError("INCONCLUSIVE: Could not confirm both claim RPC sessions were blocked by this test's lock-holder PID. The requests were released and may have consumed the listing; verify its database state before reuse.")
    finally:
        if not lock_conn.closed:
            lock_conn.rollback()
            lock_conn.close()
    assert_committed_round(base, service, listing_id, attempts, responses, subjects[:2])
    print("PASS delayed concurrency: both claim RPC sessions were confirmed blocked by this test's lock-holder PID; one committed winner verified.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--env-file", type=Path, default=None,
                        help="Local secret env file; never commit it. Defaults to GEOLOCK_TEST_ENV_FILE or the stage1 generated env path.")
    args = parser.parse_args()
    load_env_file(str(args.env_file) if args.env_file else None)
    base, key, service, _ref, tokens, listing_ids = safety_gate()
    subjects = assert_fresh_fixtures(base, service, key, tokens, listing_ids)

    attempts2, responses2, state2 = run_race(base, key, service, listing_ids[0], tokens, subjects, 2, "two-NGO race")
    attempts10, _responses10, _state10 = run_race(base, key, service, listing_ids[1], tokens, subjects, 10, "ten-NGO race")

    # Identical replay must return the committed claim without duplicating any
    # request, claim, lease, task, listing transition, or audit row.
    winner_index = next(i for i, response in enumerate(responses2) if response.get("outcome") == "SUCCESS")
    winner = attempts2[winner_index]
    winner_response = responses2[winner_index]
    replay = claim_attempt(base, key, listing_ids[0], winner["token"], winner["request_id"])
    if replay.get("outcome") != "SUCCESS" or replay.get("claim_id") != winner_response.get("claim_id") or replay.get("replayed") is not True:
        raise RuntimeError("Identical request replay did not return the original claim.")
    assert_unchanged(state2, get_state(base, service, listing_ids[0], [a["request_id"] for a in attempts2]))
    print("PASS identical replay: original claim returned with no duplicate records.")

    # Both changed listing and changed authenticated NGO must fail before any
    # original result or audit evidence is altered.
    expect_payload_rejection(base, key, winner["token"], listing_ids[1], winner["request_id"])
    expect_payload_rejection(base, key, tokens[(winner_index + 1) % 2], listing_ids[0], winner["request_id"])
    assert_unchanged(state2, get_state(base, service, listing_ids[0], [a["request_id"] for a in attempts2]))
    print("PASS changed payload: different listing and different NGO rejected; original committed state unchanged.")

    run_delayed_race(base, key, service, required("GEOLOCK_TEST_DATABASE_URL"), listing_ids[2], tokens, subjects)
    run_discarded_response_retry(base, key, service, listing_ids[3], tokens[0], subjects[0])
    print(json.dumps({"project_ref": DEV_PROJECT_REF, "normal_race_sizes": list(COUNTS),
                      "eligible_ngo_count": len(subjects),
                      "status": "claim concurrency scenarios passed; rollback fault injection remains separately gated"}, indent=2))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        # Never print JWTs, keys, request bodies, or PostgreSQL connection URLs.
        print(f"CLAIM TEST BLOCKED/FAILED: {error}", file=sys.stderr)
        sys.exit(1)
