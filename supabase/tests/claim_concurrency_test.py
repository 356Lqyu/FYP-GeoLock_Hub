"""Atomic claim acceptance tests for the isolated GeoLock Hub DEV project.

Defaults to read-only preflight; explicit approved execution is state-changing. It consumes only dedicated, disposable AVAILABLE
listings supplied in the local test env file. The original suite requires ten
distinct NGO sessions; the Stage 3J runner reuses helpers with exactly two.
All sessions must be legitimately authenticated and eligible. No fixture
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
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlparse

from stage1_dev_env import load_env_file
import claim_e2e_contract as contract

DEV_PROJECT_REF = "rcgyuwiidqvrgbxswhqj"
BLOCKED_PROJECT_REF = "mffccmlimmbrgasgfnnq"
CONFIRMATION = "I_CONFIRM_DISPOSABLE_DEV_PROJECT"
COUNTS = (2, 10)
EXPECTED_CLAIM_LEASE_SECONDS = 360 * 60
DELAY_OBSERVATION_TIMEOUT_SECONDS = 20
EVENT_SINK = None
PROTECTED_LISTINGS = {
    '95d6cd51-866b-4eec-8a36-36dc24296aec',  # Retained Stage 3I evidence.
    '2d06b504-d2dd-4121-8840-c8bf893f8a60',
    'd7953dd2-7809-4cb4-87f3-52fc3294685b',
    '16e5b6a1-475d-4c5a-9460-d4834dd5640f',
}


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


def safety_gate(actor_count: int = 10, listing_count: int = 4) -> tuple[str, str, str, str, list[str], list[str]]:
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
    tokens = parse_json_list("GEOLOCK_TEST_NGO_JWT_TOKENS", actor_count)
    if len(tokens) != actor_count:
        raise RuntimeError(f'Provide exactly {actor_count} distinct NGO sessions; extras are not silently ignored.')
    listing_ids = parse_json_list("GEOLOCK_TEST_LISTING_IDS", listing_count)
    try:
        [str(uuid.UUID(value)) for value in listing_ids]
    except ValueError:
        raise RuntimeError("Every listing ID must be a UUID.") from None
    listing_ids = [str(uuid.UUID(value)) for value in listing_ids]
    if len(listing_ids) != listing_count or len(set(listing_ids)) != listing_count:
        raise RuntimeError(f"Provide exactly {listing_count} distinct dedicated AVAILABLE listing UUIDs.")
    if PROTECTED_LISTINGS.intersection(listing_ids):
        raise RuntimeError("Retained controlled-recovery evidence cannot be a claim test fixture.")
    return base_url, publishable, service_role, ref, tokens[:actor_count], listing_ids


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
    except (urllib.error.URLError, TimeoutError, OSError, ValueError):
        raise RuntimeError('UNCONFIRMED: network/response failure; retain the request UUID and inspect committed state.') from None


def rest_rows(base: str, service: str, table_query: str) -> list[dict]:
    # Stable snapshot ordering avoids falsely attributing row-order changes to replay.
    table = table_query.split('?')[0]
    primary_keys = {'donation_claims':'claim_id','claim_leases':'lease_id','pickup_tasks':'task_id',
                    'claim_requests':'request_id','audit_events':'event_id',
                    'operation_failure_events':'failure_id','listings':'listing_id','donations':'donation_id'}
    if table in primary_keys:
        table_query += ('&' if '?' in table_query else '?') + 'order=' + primary_keys[table] + '.asc'
    status, result = http_call(base, service, service, table_query)
    if status != 200 or not isinstance(result, list):
        raise RuntimeError(f"Read-only DEV verification query failed for {table_query.split('?')[0]} (HTTP {status}).")
    return result


def rpc(base: str, key: str, token: str, name: str, payload: dict) -> tuple[int, object | None]:
    if name not in {'claim_listing','cancel_claim','start_pickup','complete_pickup',
                    'get_authorized_audit_events','discover_eligible_listing_cards'}:
        raise RuntimeError('RPC not permitted by this claim harness; live recovery remains disabled.')
    return http_call(base, key, token, f"rpc/{name}", payload)


def require_success(status: int, result: object, context: str) -> dict:
    if status != 200 or not isinstance(result, dict):
        raise RuntimeError(f"UNCONFIRMED: {context} has no authoritative receipt (HTTP {status}); retain request UUID.")
    return result


def assert_fresh_fixtures(base: str, service: str, key: str,
                          tokens: list[str], listing_ids: list[str],
                          actor_count: int = 10) -> list[str]:
    subjects = [jwt_subject(token) for token in tokens]
    if len(subjects) != actor_count or len(set(subjects)) != actor_count:
        raise RuntimeError(f"Sessions must belong to exactly {actor_count} distinct NGO users.")

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
    eligibility = {listing: tokens for listing in listing_ids}
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
    started_at = datetime.now(timezone.utc).isoformat()
    started = time.perf_counter()
    status, result = rpc(base, key, token, "claim_listing", {
        "p_listing": listing_id, "p_request": request_id,
    })
    result = require_success(status, result, "claim_listing")
    if result.get('outcome') == 'ERROR':
        contract.confirmed_receipt(status, result)
    elif result.get('outcome') not in ('SUCCESS', 'CONFLICT', 'INELIGIBLE'):
        raise RuntimeError('Unexpected claim result; no success or rollback inferred.')
    result = dict(result, client_timing=dict(started_at=started_at,
                  elapsed_ms=(time.perf_counter()-started)*1000))
    if EVENT_SINK:
        EVENT_SINK('CLAIM_TIMING', listing=listing_id, request=request_id,
                   actor=jwt_subject(token), timing=result['client_timing'], outcome=result['outcome'])
    return result


def get_state(base: str, service: str, listing_id: str, request_ids: list[str]) -> dict:
    in_list = "(" + ",".join(request_ids) + ")"
    claim_q = urllib.parse.urlencode({
        "or": f"(listing_id.eq.{listing_id},request_id.in.{in_list})",
        "select": "claim_id,listing_id,ngo_user_id,request_id,claim_status,claimed_at",
    })
    claims = rest_rows(base, service, f"donation_claims?{claim_q}")
    active_claims = [row for row in claims if row.get("claim_status") in {"ACTIVE", "RECONCILIATION_REQUIRED"}]
    listing_q = urllib.parse.urlencode({"listing_id": f"eq.{listing_id}", "select": "listing_id,listing_status,source_type,donation_id,listing_version"})
    listings = rest_rows(base, service, f"listings?{listing_q}")
    request_q = urllib.parse.urlencode({
        "request_id": f"in.{in_list}",
        "select": "request_id,listing_id,ngo_user_id,outcome,result_claim_id,reason_code,completed_at",
    })
    requests = rest_rows(base, service, f"claim_requests?{request_q}")
    audit_q = urllib.parse.urlencode({
        "request_id": f"in.{in_list}", "event_type": "eq.CLAIM_ATTEMPT",
        "select": "event_id,actor_user_id,actor_role,entity_type,entity_id,event_type,request_id,claim_id,lease_id,previous_state,requested_state,resulting_state,reason_code,outcome,configuration_version,software_version,correlation_id,details,occurred_at",
    })
    audits = rest_rows(base, service, f"audit_events?{audit_q}")
    transition_q = urllib.parse.urlencode({
        'request_id': f'in.{in_list}', 'event_type': 'eq.DONATION_STATUS_CHANGED',
        'select': 'event_id,actor_user_id,actor_role,entity_type,entity_id,event_type,request_id,claim_id,lease_id,previous_state,requested_state,resulting_state,reason_code,outcome,configuration_version,software_version,correlation_id,details,occurred_at'})
    transitions = rest_rows(base, service, f'audit_events?{transition_q}')
    failure_q = urllib.parse.urlencode({'request_id': f'in.{in_list}',
        'select': 'failure_id,request_id,actor_user_id,actor_role,operation_name,donation_id,listing_id,claim_id,reason_code,occurred_at,details'})
    failures = rest_rows(base, service, f'operation_failure_events?{failure_q}')
    donations = []
    for listing in listings:
        if listing.get('source_type') != 'DIRECT_DONATION' or not listing.get('donation_id'):
            raise RuntimeError('This live harness requires manifest-approved direct donation fixtures.')
        q = urllib.parse.urlencode({'donation_id': 'eq.' + listing['donation_id'],
                                    'select': 'donation_id,donation_status'})
        donations.extend(rest_rows(base, service, f'donations?{q}'))
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
            "audits": audits, "leases": leases, "tasks": tasks,
            'transitions': transitions, 'failures': failures, 'donations': donations}


def assert_committed_round(base: str, service: str, listing_id: str,
                           attempts: list[dict], responses: list[dict],
                           subjects: list[str], expect_conflicts: bool = True,
                           expected_failure_ids=()) -> dict:
    state = get_state(base, service, listing_id, [a["request_id"] for a in attempts])
    for i, response in enumerate(responses):
        if response.get('outcome') == 'ERROR':
            receipt = contract.confirmed_receipt(200, response)
            contract.failure_record(receipt, state['failures'], subjects[i], listing_id,
                attempts[i]['request_id'], state['listings'][0]['donation_id'])
            raise RuntimeError('Confirmed rollback in a normal race; preserve evidence, do not count it as a business conflict.')
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
            if event.get('correlation_id') != attempt['request_id'] or event.get('software_version') != contract.VERSION:
                raise RuntimeError('Claim audit correlation/software version mismatch.')
        else:
            if request.get("outcome") != "CONFLICT" or request.get("reason_code") != "CLAIM_CONFLICT":
                raise RuntimeError("Losing request was not durably recorded as CLAIM_CONFLICT.")
            if event.get("outcome") != "REJECTED" or event.get("reason_code") != "CLAIM_CONFLICT":
                raise RuntimeError("Rejected claim audit is missing or does not show CLAIM_CONFLICT.")
            if event.get('claim_id') is not None or event.get('lease_id') is not None:
                raise RuntimeError('Rejected claim must not invent claim or lease linkage.')
    if len(state['transitions']) != 1 or len(state['donations']) != 1 or state['donations'][0]['donation_status'] != 'CLAIMED':
        raise RuntimeError('Winning direct donation transition/audit missing or duplicated.')
    event = state['transitions'][0]
    contract.donation_link(event, attempts[winner_index], claim_id, lease['lease_id'],
        subjects[winner_index], listing_id, state['listings'][0]['donation_id'])
    winner_audit = audits_by_id[attempts[winner_index]['request_id']][0]
    if winner_audit.get('details', {}).get('transaction_id') != event['details']['transaction_id']:
        raise RuntimeError('Claim and donation audit transaction IDs differ.')
    if {f['failure_id'] for f in state['failures']} != set(expected_failure_ids):
        raise RuntimeError('Unexpected failure events in an initially successful fresh race.')
    return state


def assert_unchanged(original: dict, current: dict) -> None:
    for key in original:
        if original[key] != current[key]:
            raise RuntimeError(f"Unexpected committed changes detected in {key} after an idempotency replay/mismatch.")


def expect_payload_rejection(base: str, key: str, token: str,
                             listing_id: str, request_id: str) -> dict:
    result = claim_attempt(base, key, listing_id, token, request_id)
    return contract.confirmed_receipt(200, result, contract.REUSE_REASON)


def verify_payload_rejection(base, key, service, token, listing_id, request_id):
    before = get_state(base, service, listing_id, [request_id])
    first = expect_payload_rejection(base, key, token, listing_id, request_id)
    second = expect_payload_rejection(base, key, token, listing_id, request_id)
    if first['failure_audit_id'] != second['failure_audit_id']:
        raise RuntimeError('Repeated payload mismatch duplicated its failure event.')
    after = get_state(base, service, listing_id, [request_id])
    contract.failure_record(second, after['failures'], jwt_subject(token), listing_id,
                             request_id, after['listings'][0]['donation_id'])
    contract.failure_append(before['failures'], after['failures'], second['failure_audit_id'])
    assert_unchanged(dict(before, failures=after['failures']), after)
    return second


def verify_receipt_visibility(base, key, token, other_token, listing, receipt):
    payload = {'p_entity_type': 'LISTING', 'p_entity_id': listing}
    status, rows = rpc(base, key, token, 'get_authorized_audit_events', payload)
    contract.check(status == 200 and isinstance(rows, list) and any(
        r.get('event_id') == receipt['failure_audit_id'] and r.get('event_type') == 'CLAIM_FAILURE'
        and r.get('actor_user_id') == jwt_subject(token) and r.get('outcome') == 'ERROR' for r in rows),
        'Own confirmed failure is missing from authorized audit retrieval.')
    status, rows = rpc(base, key, other_token, 'get_authorized_audit_events', payload)
    denied = (status >= 400 and isinstance(rows, dict) and rows.get('code') == 'P0001'
              and rows.get('message') == 'AUDIT_NOT_FOUND_OR_FORBIDDEN')
    filtered = (status == 200 and isinstance(rows, list)
                and all(r.get('event_id') != receipt['failure_audit_id'] for r in rows))
    contract.check(denied or filtered, 'Foreign NGO failure was exposed or access result was unconfirmed.')


def run_race(base: str, key: str, service: str, listing_id: str,
             tokens: list[str], subjects: list[str], count: int,
             label: str) -> tuple[list[dict], list[dict], dict]:
    attempts = [{"token": tokens[i], "request_id": str(uuid.uuid4())} for i in range(count)]
    if len(set(subjects[:count])) != count or len(tokens) < count:
        raise RuntimeError('Race requires distinct authenticated NGO subjects, not repeated sessions.')
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
    if EVENT_SINK:
        EVENT_SINK('DISCARDED_RESPONSE_START', listing=listing_id, request=request_id, actor=subject)
    try:
        status, _ = http_call(base, key, token, "rpc/claim_listing", {
            "p_listing": listing_id, "p_request": request_id,
        }, discard_body=True)
    except Exception:
        if EVENT_SINK:
            EVENT_SINK('RPC_UNCONFIRMED', listing=listing_id, request=request_id)
        raise
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
                     listing_id: str, tokens: list[str], subjects: list[str]) -> dict:
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
            cursor.execute("SET LOCAL lock_timeout = '5s'")
            cursor.execute("SET LOCAL statement_timeout = '30s'")
            cursor.execute("SET LOCAL stats_fetch_consistency = 'none'")
            cursor.execute("SELECT pg_backend_pid()")
            holder_pid = cursor.fetchone()[0]
            cursor.execute("SELECT listing_id FROM public.listings WHERE listing_id = %s FOR UPDATE", (listing_id,))
            if cursor.fetchone() is None:
                raise RuntimeError("Delayed-race listing disappeared before lock acquisition.")
        def call(attempt: dict) -> dict:
            return claim_attempt(base, key, listing_id, attempt["token"], attempt["request_id"], barrier)
        observed = False
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            try:
                futures = [pool.submit(call, attempt) for attempt in attempts]
                deadline = time.monotonic() + DELAY_OBSERVATION_TIMEOUT_SECONDS
                while time.monotonic() < deadline:
                    with lock_conn.cursor() as cursor:
                        # Activity snapshots can be cached for the transaction
                        # holding our row lock. Refresh only this session's view;
                        # this does not reset counters or change database rows.
                        cursor.execute("SELECT pg_stat_clear_snapshot()")
                        cursor.execute(
                            "WITH RECURSIVE waiters AS ("
                            " SELECT a.pid FROM pg_stat_activity a "
                            " WHERE a.datname=current_database() AND a.wait_event_type='Lock' "
                            " AND a.query ILIKE %s), "
                            " blockers(pid,blocker) AS ("
                            " SELECT pid,unnest(pg_blocking_pids(pid)) FROM waiters "
                            " UNION SELECT b.pid,unnest(pg_blocking_pids(b.blocker)) FROM blockers b) "
                            " SELECT count(DISTINCT pid) FROM blockers WHERE blocker=%s",
                            ('%claim_listing%', holder_pid),
                        )
                        count = cursor.fetchone()[0]
                    if count > 2:
                        raise RuntimeError("Unexpected competing claim waiters; stop and inspect committed state.")
                    if count == 2:
                        observed = True
                        break
                    time.sleep(0.2)
            finally:
                # __exit__ waits for worker threads. Unlock INSIDE the pool's
                # scope, including observation/submit failures, before it waits.
                # This connection only reads/locks: rollback releases its locks.
                try:
                    lock_conn.rollback()
                finally:
                    lock_conn.close()
        responses = [future.result(timeout=90) for future in futures]
        if not observed:
            raise RuntimeError("INCONCLUSIVE: Could not confirm both claim RPC sessions were blocked by this test's lock-holder PID. The requests were released and may have consumed the listing; verify its database state before reuse.")
    finally:
        if not lock_conn.closed:
            lock_conn.rollback()
            lock_conn.close()
    assert_committed_round(base, service, listing_id, attempts, responses, subjects[:2])
    print("PASS delayed concurrency: both claim RPC sessions were confirmed blocked by this test's lock-holder PID; one committed winner verified.")
    return {'holder_pid': holder_pid, 'observed_waiters': count,
            'method': 'transitive pg_blocking_pids chain to own listing-lock holder',
            'request_ids': [a['request_id'] for a in attempts],
            'responses': responses}


def main() -> int:
    # Keep the journal adapter on the same module when invoked as a script.
    sys.modules['claim_concurrency_test'] = sys.modules[__name__]
    import claim_two_actor_acceptance as suite
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--env-file', type=Path, required=True)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--output-dir', type=Path, required=True)
    parser.add_argument('--actors', type=int, choices=(2, 10), default=10)
    parser.add_argument('--execute', action='store_true')
    parser.add_argument('--execution-approval')
    args = parser.parse_args()
    contract.check((args.execute and args.execution_approval == 'I_APPROVE_DEV_CLAIM_CONCURRENCY')
        or (not args.execute and args.execution_approval is None), 'Explicit concurrency execution approval required.')
    purpose = 'two_actor' if args.actors == 2 else 'concurrency_10'
    ctx = suite.prepare(args, args.actors, 2 if args.actors == 2 else 4, purpose, runner_path=Path(__file__))
    base, key, service, tokens, subjects, listings, db_url, health, read, journal, baseline = ctx
    if not args.execute:
        journal.record('PREFLIGHT_PASS', note='No claim, recovery, concurrency or cleanup executed.')
        print('PREFLIGHT PASS; execution remains separately gated.')
        return 0
    def safe_point():
        suite.validate_health(health(), baseline)
    try:
        with suite.record_rpcs(journal):
            if args.actors == 2:
                suite.run_acceptance(base, key, service, tokens, subjects, listings,
                                     db_url, health, read, journal, baseline)
            else:
                safe_point()
                attempts, responses, state = run_race(base, key, service, listings[0], tokens, subjects, 2, 'two-NGO race')
                journal.record('RACE_2', responses=responses, state=state)
                safe_point()
                _, responses10, state10 = run_race(base, key, service, listings[1], tokens, subjects, 10, 'ten-NGO race')
                journal.record('RACE_10', responses=responses10, state=state10)
                winner = next(i for i, r in enumerate(responses) if r['outcome'] == 'SUCCESS')
                request = attempts[winner]['request_id']
                replay = claim_attempt(base, key, listings[0], tokens[winner], request)
                contract.check(replay.get('replayed') is True and replay.get('claim_id') == responses[winner]['claim_id'],
                               'Successful replay changed the original claim result.')
                assert_unchanged(state, get_state(base, service, listings[0], [a['request_id'] for a in attempts]))
                first = verify_payload_rejection(base, key, service, tokens[winner], listings[1], request)
                verify_receipt_visibility(base, key, tokens[winner], tokens[1-winner], listings[1], first)
                second = verify_payload_rejection(base, key, service, tokens[1-winner], listings[0], request)
                verify_receipt_visibility(base, key, tokens[1-winner], tokens[winner], listings[0], second)
                safe_point()
                journal.record('DELAY_OBSERVATION', **run_delayed_race(base, key, service, db_url, listings[2], tokens, subjects))
                safe_point()
                journal.record('DISCARDED_RESPONSE_VERIFIED', state=run_discarded_response_retry(
                    base, key, service, listings[3], tokens[0], subjects[0]))
        safe_point()
        journal.record('FINAL_FIXTURES', fixtures={l: read(l) for l in listings})
        print('PASS claim concurrency; retain all business/audit history. No recovery or global cleanup.')
        return 0
    except Exception:
        journal.record('STOP_REVIEW_REQUIRED', note='Inspect journaled request IDs; no automatic retry or cleanup.')
        raise


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        # Never print JWTs, keys, request bodies, or PostgreSQL connection URLs.
        print('CLAIM TEST BLOCKED/FAILED: inspect the private journal and committed state; no blind retry.', file=sys.stderr)
        sys.exit(1)
