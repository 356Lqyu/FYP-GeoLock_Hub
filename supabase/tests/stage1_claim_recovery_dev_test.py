"""Stateful Stage 1 claim recovery tests for a disposable Supabase project.

This test is intentionally not run by the preparation task. It changes data.
See stage1-dev-environment.md for fixture requirements and the mandatory
project-reference allowlist / disposable-project guard.

Fixture variables:
  GEOLOCK_DEV_EXPIRED_SAFE_CLAIM_ID
  GEOLOCK_DEV_CANCEL_SAME_REQUEST_CLAIM_ID
  GEOLOCK_DEV_CANCEL_DISTINCT_REQUEST_CLAIM_ID
  GEOLOCK_DEV_CANCEL_START_RACE_CLAIM_ID
  GEOLOCK_DEV_EXPIRED_PICKUP_CLAIM_ID
  GEOLOCK_DEV_CANCEL_RECOVERY_RACE_CLAIM_ID
  GEOLOCK_DEV_ROUTE_LINKED_EXPIRED_CLAIM_ID
  GEOLOCK_DEV_RECONCILE_POSITIVE_CLAIM_ID / _LISTING_ID
  GEOLOCK_DEV_RECONCILE_COUNTERPART_JWT
  GEOLOCK_DEV_RECONCILE_DISPATCHED_NO_HANDOVER_CLAIM_ID
  GEOLOCK_DEV_RECONCILE_DISPATCHED_COUNTERPART_JWT
  GEOLOCK_DEV_RECONCILE_CONFLICT_CLAIM_ID / _COUNTERPART_JWT
  GEOLOCK_DEV_RECONCILE_SAFE_RELEASE_CLAIM_ID / _LISTING_ID
  GEOLOCK_DEV_RECONCILE_SAFE_COUNTERPART_JWT
  GEOLOCK_DEV_AUDIT_OWN_CLAIM_ID / _FOREIGN_CLAIM_ID
  GEOLOCK_DEV_NGO_JWT, GEOLOCK_DEV_DONOR_JWT,
  GEOLOCK_DEV_RECONCILE_COUNTERPART_JWT, GEOLOCK_DEV_SERVICE_ROLE_JWT
"""
from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid
from concurrent.futures import ThreadPoolExecutor
from urllib.parse import urlparse
from stage1_dev_env import load_env_file

SHARED_REF = "mffccmlimmbrgasgfnnq"
DEV_REF = "rcgyuwiidqvrgbxswhqj"
CONFIRMATION = "I_CONFIRM_DISPOSABLE_DEV_PROJECT"
_RECOVERY_CANCEL_REQUEST = str(uuid.uuid4())
_RECOVERY_CANCEL_RESULT = None


def required(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise RuntimeError(f"Missing required variable {name}")
    return value


def project_ref(url: str) -> str:
    host = urlparse(url).hostname or ""
    suffix = ".supabase.co"
    if not host.endswith(suffix):
        raise RuntimeError("Development URL must be https://<project-ref>.supabase.co")
    return host[: -len(suffix)]


def safety_gate() -> None:
    if required("GEOLOCK_DEV_ISOLATED_CONFIRMATION") != CONFIRMATION:
        raise RuntimeError("Disposable development-project confirmation is missing.")
    url = required("GEOLOCK_DEV_SUPABASE_URL").rstrip("/")
    parsed = urlparse(url)
    if (parsed.scheme != "https" or parsed.hostname != f"{DEV_REF}.supabase.co"
            or parsed.port is not None or parsed.username or parsed.password
            or parsed.path not in {"", "/"} or parsed.query or parsed.fragment):
        raise RuntimeError("Use the canonical HTTPS URL for the exact isolated DEV project.")
    ref = project_ref(url)
    allow = {part.strip() for part in required("GEOLOCK_DEV_ALLOWED_PROJECT_REFS").split(",") if part.strip()}
    configured_ref = required("GEOLOCK_DEV_PROJECT_REF")
    if ref == SHARED_REF or ref != DEV_REF or configured_ref != DEV_REF or allow != {DEV_REF}:
        raise RuntimeError("Project reference must be the exact isolated DEV ref and the only allowlisted ref.")
    inherited = os.environ.get("SUPABASE_URL", "").strip()
    if inherited and project_ref(inherited.rstrip("/")) != ref:
        raise RuntimeError("Inherited SUPABASE_URL points to a different project; refusing to run.")
    key = required("GEOLOCK_DEV_PUBLISHABLE_KEY")
    if key.startswith("sb_secret_") or "service_role" in key.lower():
        raise RuntimeError("Publishable key variable contains a secret/service-role credential.")
    required("GEOLOCK_DEV_SERVICE_ROLE_JWT")


def call(path: str, jwt: str, payload=None):
    base = required("GEOLOCK_DEV_SUPABASE_URL").rstrip("/")
    key = required("GEOLOCK_DEV_PUBLISHABLE_KEY")
    data = None if payload is None else json.dumps(payload).encode()
    req = urllib.request.Request(
        f"{base}/rest/v1/{path}", data=data,
        headers={"apikey": key, "Authorization": f"Bearer {jwt}",
                 "Content-Type": "application/json"},
        method="GET" if data is None else "POST")
    try:
        with urllib.request.urlopen(req, timeout=45) as response:
            body = response.read().decode()
            return response.status, json.loads(body) if body else None
    except urllib.error.HTTPError as error:
        body = error.read().decode(errors="replace")
        try:
            body = json.loads(body)
        except json.JSONDecodeError:
            pass
        return error.code, body


def rpc(name: str, jwt: str, payload: dict):
    return call(f"rpc/{name}", jwt, payload)


def read(table: str, query: str):
    return call(f"{table}?{query}", required("GEOLOCK_DEV_SERVICE_ROLE_JWT"))


def ok(result, label: str):
    if not 200 <= result[0] < 300:
        raise AssertionError(f"{label}: HTTP {result[0]} {result[1]}")
    return result[1]


def expect_rejected(result, label: str):
    if 200 <= result[0] < 300 and not (
        isinstance(result[1], dict) and result[1].get("outcome") == "REJECTED"
    ):
        raise AssertionError(f"{label}: expected backend rejection; got {result}")


def one(table: str, query: str, label: str):
    rows = ok(read(table, query), label)
    if len(rows) != 1:
        raise AssertionError(f"{label}: expected one committed row, found {len(rows)}")
    return rows[0]


def audit_exists(entity_id: str, event_type: str, request_id: str | None = None):
    clauses = [f"entity_id=eq.{entity_id}", f"event_type=eq.{urllib.parse.quote(event_type)}"]
    if request_id:
        clauses.append(f"request_id=eq.{request_id}")
    rows = ok(read("audit_events", "select=event_id,outcome,reason_code&" + "&".join(clauses)), "audit read")
    if not rows:
        raise AssertionError(f"Missing committed {event_type} audit evidence for {entity_id}")


def assert_persisted_donations(claim: str, state: str):
    """Post-redesign assertion; also validates every member of a hub listing."""
    row = one("donation_claims", f"select=listing_id&claim_id=eq.{claim}", "claim listing")
    listing = one("listings",
                  f"select=source_type,donation_id,batch_id&listing_id=eq.{row['listing_id']}", "listing source")
    expected = state
    if listing["source_type"] == "DIRECT_DONATION":
        ids = [listing["donation_id"]]
    else:
        if state == "AVAILABLE":
            expected = "BATCHED"
        batch = one("hub_batches",
                    f"select=batch_donation_count&batch_id=eq.{listing['batch_id']}", "batch count")
        members = ok(read("hub_batch_members",
                          f"select=donation_id&batch_id=eq.{listing['batch_id']}&membership_status=eq.ACTIVE"),
                     "active members")
        ids = [member["donation_id"] for member in members]
        if not ids or len(ids) != batch["batch_donation_count"]:
            raise AssertionError("Incomplete hub batch membership")
    for donation in ids:
        row = one("donations", f"select=donation_status&donation_id=eq.{donation}", "persisted donation")
        if row["donation_status"] != expected:
            raise AssertionError(f"Expected every donation to be {expected}")


def run(label, action):
    action()
    print(f"PASS {label}")


def test_recovery_authorization():
    anon = required("GEOLOCK_DEV_ANON_JWT")
    donor = required("GEOLOCK_DEV_DONOR_JWT")
    expect_rejected(rpc("recover_expired_claims", anon, {"p_limit": 1}), "anon recovery")
    expect_rejected(rpc("recover_expired_claims", donor, {"p_limit": 1}), "donor recovery")


def test_overlapping_recovery():
    global _RECOVERY_CANCEL_RESULT
    service = required("GEOLOCK_DEV_SERVICE_ROLE_JWT")
    ngo = required("GEOLOCK_DEV_NGO_JWT")
    cancel_claim_id = required("GEOLOCK_DEV_CANCEL_RECOVERY_RACE_CLAIM_ID")
    with ThreadPoolExecutor(max_workers=3) as pool:
        recovery_futures = [pool.submit(rpc, "recover_expired_claims", service, {"p_limit": 20}) for _ in range(2)]
        cancel_future = pool.submit(rpc, "cancel_claim", ngo, {
            "p_claim": cancel_claim_id, "p_request": _RECOVERY_CANCEL_REQUEST})
        results = [future.result() for future in recovery_futures]
        _RECOVERY_CANCEL_RESULT = cancel_future.result()
    counts = [int(ok(result, "recovery RPC")) for result in results]
    if sum(counts) != 4:
        raise AssertionError(f"Overlapping recovery processed {sum(counts)} records; expected all four expired fixtures exactly once")
    expect_rejected(_RECOVERY_CANCEL_RESULT, "expired cancellation versus recovery")
    expected_states = (
        ("GEOLOCK_DEV_EXPIRED_SAFE_CLAIM_ID", "RELEASED"),
        ("GEOLOCK_DEV_CANCEL_RECOVERY_RACE_CLAIM_ID", "RELEASED"),
        ("GEOLOCK_DEV_ROUTE_LINKED_EXPIRED_CLAIM_ID", "RECONCILIATION_REQUIRED"),
        ("GEOLOCK_DEV_EXPIRED_PICKUP_CLAIM_ID", "RELEASED"),
    )
    for env_name, expected in expected_states:
        claim = required(env_name)
        c = one("donation_claims", f"select=claim_id,claim_status,listing_id&claim_id=eq.{claim}", "recovered claim")
        le = one("claim_leases", f"select=claim_id,lease_status&claim_id=eq.{claim}", "recovered lease")
        t = one("pickup_tasks", f"select=claim_id,task_status&claim_id=eq.{claim}", "recovered task")
        l = one("listings", f"select=listing_id,listing_status&listing_id=eq.{c['listing_id']}", "recovered listing")
        if c["claim_status"] != expected or le["lease_status"] != expected:
            raise AssertionError(f"Claim and lease should both be {expected}")
        expected_pair = ("RELEASED", "STALE", "AVAILABLE") if expected == "RELEASED" else (
            "RECONCILIATION_REQUIRED", "CONFIRMED", "CLAIMED")
        if (le["lease_status"], t["task_status"], l["listing_status"]) != expected_pair:
            raise AssertionError("Recovery left inconsistent claim, lease, task, and listing states")
        audit_exists(claim, "LEASE_RECOVERY")
        assert_persisted_donations(claim, "AVAILABLE" if expected == "RELEASED" else "CLAIMED")


def test_same_request_cancel():
    claim = required("GEOLOCK_DEV_CANCEL_SAME_REQUEST_CLAIM_ID")
    ngo = required("GEOLOCK_DEV_NGO_JWT")
    request = str(uuid.uuid4())
    def submit(_):
        return rpc("cancel_claim", ngo, {"p_claim": claim, "p_request": request})
    with ThreadPoolExecutor(max_workers=10) as pool:
        results = list(pool.map(submit, range(10)))
    bodies = [ok(result, "same-request cancellation") for result in results]
    if len({json.dumps(body, sort_keys=True) for body in bodies}) != 1:
        raise AssertionError("Idempotent request replay returned different outcomes")
    state = one("donation_claims", f"select=claim_id,claim_status&claim_id=eq.{claim}", "cancel claim state")
    if state["claim_status"] != "RELEASED":
        raise AssertionError("Successful same-request cancellation did not commit RELEASED")
    expect_rejected(rpc("start_pickup", required("GEOLOCK_DEV_NGO_JWT"), {
        "p_claim": claim}), "old holder after cancellation")
    audit_exists(claim, "CANCEL_CLAIM", request)
    assert_persisted_donations(claim, "AVAILABLE")


def test_distinct_request_cancel_race():
    claim = required("GEOLOCK_DEV_CANCEL_DISTINCT_REQUEST_CLAIM_ID")
    ngo = required("GEOLOCK_DEV_NGO_JWT")
    def submit(_):
        return rpc("cancel_claim", ngo, {"p_claim": claim, "p_request": str(uuid.uuid4())})
    with ThreadPoolExecutor(max_workers=10) as pool:
        results = list(pool.map(submit, range(10)))
    bodies = [ok(result, "distinct-request cancellation") for result in results]
    if sum(body.get("outcome") == "SUCCESS" for body in bodies) != 1:
        raise AssertionError("Distinct request race must have exactly one committed release")
    state = one("donation_claims", f"select=claim_id,claim_status&claim_id=eq.{claim}", "race claim state")
    lease = one("claim_leases", f"select=claim_id,lease_status&claim_id=eq.{claim}", "race lease state")
    if (state["claim_status"], lease["lease_status"]) != ("RELEASED", "RELEASED"):
        raise AssertionError("Claim/lease committed states diverged after cancellation race")
    assert_persisted_donations(claim, "AVAILABLE")


def test_cancel_vs_start():
    claim = required("GEOLOCK_DEV_CANCEL_START_RACE_CLAIM_ID")
    ngo = required("GEOLOCK_DEV_NGO_JWT")
    args = {"p_claim": claim, "p_request": str(uuid.uuid4())}
    with ThreadPoolExecutor(max_workers=2) as pool:
        cancel_future = pool.submit(rpc, "cancel_claim", ngo, args)
        start_future = pool.submit(rpc, "start_pickup", ngo, {"p_claim": claim})
        cancel_result, start_result = cancel_future.result(), start_future.result()
    cancel_body = cancel_result[1] if cancel_result[0] < 300 else None
    start_committed = 200 <= start_result[0] < 300
    cancel_committed = isinstance(cancel_body, dict) and cancel_body.get("outcome") == "SUCCESS"
    if cancel_committed and start_committed:
        raise AssertionError("Cancellation and pickup start both committed")
    if cancel_committed == start_committed:
        raise AssertionError("Expected exactly one of cancellation or pickup start to commit")
    state = one("donation_claims", f"select=claim_id,claim_status&claim_id=eq.{claim}", "cancel/start claim")
    lease = one("claim_leases", f"select=claim_id,lease_status,expires_at&claim_id=eq.{claim}", "cancel/start lease")
    task = one("pickup_tasks", f"select=claim_id,task_status&claim_id=eq.{claim}", "cancel/start task")
    listing = one("donation_claims", f"select=listing_id&claim_id=eq.{claim}", "cancel/start listing id")
    listing_state = one("listings", f"select=listing_id,listing_status&listing_id=eq.{listing['listing_id']}", "cancel/start listing")
    if state["claim_status"] == "RELEASED":
        if (lease["lease_status"], task["task_status"], listing_state["listing_status"]) != (
            "RELEASED", "STALE", "AVAILABLE"
        ):
            raise AssertionError("Cancellation committed without releasing lease, staling task, and reopening listing together")
    elif state["claim_status"] == "ACTIVE":
        if lease["lease_status"] != "ACTIVE" or listing_state["listing_status"] != "CLAIMED":
            raise AssertionError("Active claim lost its lease or claimed listing")
        if task["task_status"] not in ("CONFIRMED", "DISPATCHED"):
            raise AssertionError("Active claim has an unexpected pickup task state")
    else:
        raise AssertionError(f"Cancellation/start race left unexpected claim state {state['claim_status']}")
    if task["task_status"] == "DISPATCHED" and state["claim_status"] != "ACTIVE":
        raise AssertionError("Dispatched task does not retain its authoritative active claim")
    audit_exists(claim, "CANCEL_CLAIM", args["p_request"])
    if start_committed:
        audit_exists(claim, "START_PICKUP")
    assert_persisted_donations(claim, "PICKUP_IN_PROGRESS" if start_committed else "AVAILABLE")


def test_expired_lease_rejects_pickup():
    claim = required("GEOLOCK_DEV_EXPIRED_PICKUP_CLAIM_ID")
    ngo = required("GEOLOCK_DEV_NGO_JWT")
    start = rpc("start_pickup", ngo, {"p_claim": claim})
    expect_rejected(start, "start with expired lease")
    complete = rpc("complete_pickup", ngo, {
        "p_claim": claim, "p_handover_confirmed": True})
    expect_rejected(complete, "complete with expired lease")
    task = one("pickup_tasks", f"select=claim_id,task_status&claim_id=eq.{claim}", "expired pickup task")
    lease = one("claim_leases", f"select=claim_id,lease_status&claim_id=eq.{claim}", "expired lease")
    claim_row = one("donation_claims", f"select=claim_id,claim_status,listing_id&claim_id=eq.{claim}", "expired claim")
    listing = one("listings", f"select=listing_status&listing_id=eq.{claim_row['listing_id']}", "expired listing")
    if (claim_row["claim_status"], lease["lease_status"], task["task_status"], listing["listing_status"]) != (
        "ACTIVE", "ACTIVE", "CONFIRMED", "CLAIMED"
    ):
        raise AssertionError("Rejected expired-lease pickup changed committed claim/task/listing state")


def test_cancel_vs_recovery():
    claim = required("GEOLOCK_DEV_CANCEL_RECOVERY_RACE_CLAIM_ID")
    expect_rejected(_RECOVERY_CANCEL_RESULT, "expired claim cancellation")
    claim_row = one("donation_claims", f"select=claim_id,claim_status&claim_id=eq.{claim}", "recovery/cancel claim")
    if claim_row["claim_status"] not in ("RELEASED", "RECONCILIATION_REQUIRED"):
        raise AssertionError("Recovery/cancellation race left an active expired claim")
    lease = one("claim_leases", f"select=claim_id,lease_status&claim_id=eq.{claim}", "recovery/cancel lease")
    task = one("pickup_tasks", f"select=claim_id,task_status&claim_id=eq.{claim}", "recovery/cancel task")
    listing_id = one("donation_claims", f"select=listing_id&claim_id=eq.{claim}", "recovery/cancel listing id")["listing_id"]
    listing = one("listings", f"select=listing_id,listing_status&listing_id=eq.{listing_id}", "recovery/cancel listing")
    if claim_row["claim_status"] == "RELEASED":
        if (lease["lease_status"], task["task_status"], listing["listing_status"]) != (
            "RELEASED", "STALE", "AVAILABLE"
        ):
            raise AssertionError("Safe expired recovery did not commit claim, lease, task, and listing consistently")
    elif (lease["lease_status"], task["task_status"], listing["listing_status"]) != (
        "RECONCILIATION_REQUIRED", "CONFIRMED", "CLAIMED"
    ):
        raise AssertionError("Uncertain expiry did not remain consistently reserved for reconciliation")
    audit_exists(claim, "CANCEL_CLAIM", _RECOVERY_CANCEL_REQUEST)
    audit_exists(claim, "LEASE_RECOVERY")


def test_route_activity_reconciles():
    claim = required("GEOLOCK_DEV_ROUTE_LINKED_EXPIRED_CLAIM_ID")
    c = one("donation_claims", f"select=claim_id,claim_status&claim_id=eq.{claim}", "route-linked claim")
    l = one("claim_leases", f"select=claim_id,lease_status&claim_id=eq.{claim}", "route-linked lease")
    if c["claim_status"] != "RECONCILIATION_REQUIRED" or l["lease_status"] != "RECONCILIATION_REQUIRED":
        raise AssertionError("Route-linked task was automatically released")
    cases = ok(read("claim_reconciliation_cases", f"select=case_id,case_status&claim_id=eq.{claim}"), "reconciliation case")
    if not cases or cases[0]["case_status"] != "OPEN":
        raise AssertionError("Route-linked recovery did not preserve an open reconciliation case")
    audit_exists(claim, "LEASE_RECOVERY")


def test_positive_reconciliation():
    claim = required("GEOLOCK_DEV_RECONCILE_POSITIVE_CLAIM_ID")
    ngo = required("GEOLOCK_DEV_NGO_JWT")
    counterpart = required("GEOLOCK_DEV_RECONCILE_COUNTERPART_JWT")
    first_request, second_request = str(uuid.uuid4()), str(uuid.uuid4())
    # Submissions are independent authenticated evidence; one from each party.
    first = ok(rpc("submit_claim_reconciliation", ngo, {
        "p_claim": claim, "p_handover_confirmed": True, "p_request": first_request}), "NGO evidence")
    second = ok(rpc("submit_claim_reconciliation", counterpart, {
        "p_claim": claim, "p_handover_confirmed": True, "p_request": second_request}), "counterpart evidence")
    if first.get("outcome") != "AWAITING_COUNTERPART" or second.get("outcome") != "SUCCESS":
        raise AssertionError("Matching handover evidence did not resolve")
    c = one("donation_claims", f"select=claim_id,claim_status&claim_id=eq.{claim}", "reconciled claim")
    l = one("claim_leases", f"select=claim_id,lease_status&claim_id=eq.{claim}", "reconciled lease")
    t = one("pickup_tasks", f"select=claim_id,task_status&claim_id=eq.{claim}", "reconciled task")
    if (c["claim_status"], l["lease_status"], t["task_status"]) != ("COMPLETED", "COMPLETED", "COLLECTED"):
        raise AssertionError("Committed reconciliation states are inconsistent")
    listing_id = required("GEOLOCK_DEV_RECONCILE_POSITIVE_LISTING_ID")
    row = one("listings", f"select=listing_id,listing_status&listing_id=eq.{listing_id}", "reconciled listing")
    if row["listing_status"] != "CLOSED":
        raise AssertionError("Collected listing is not closed")
    audit_exists(claim, "CLAIM_RECONCILIATION_EVIDENCE")
    assert_persisted_donations(claim, "COLLECTED")
    # Resolved cases must replay both original UUID responses, including the
    # final response lost in transit, without creating additional evidence/audits.
    before = ok(read("audit_events", f"select=event_id&claim_id=eq.{claim}&order=event_id"), "audit before replay")
    for actor, request, expected in ((ngo, first_request, first), (counterpart, second_request, second)):
        replay = ok(rpc("submit_claim_reconciliation", actor, {
            "p_claim": claim, "p_handover_confirmed": True, "p_request": request}), "resolved evidence replay")
        if replay != expected:
            raise AssertionError("Resolved reconciliation did not replay its recorded response")
    after = ok(read("audit_events", f"select=event_id&claim_id=eq.{claim}&order=event_id"), "audit after replay")
    if before != after:
        raise AssertionError("Resolved reconciliation replay wrote duplicate audit history")


def test_negative_after_dispatch_stays_review():
    claim = required("GEOLOCK_DEV_RECONCILE_DISPATCHED_NO_HANDOVER_CLAIM_ID")
    ngo = required("GEOLOCK_DEV_NGO_JWT")
    counterpart = required("GEOLOCK_DEV_RECONCILE_DISPATCHED_COUNTERPART_JWT")
    first = ok(rpc("submit_claim_reconciliation", ngo, {
        "p_claim": claim, "p_handover_confirmed": False, "p_request": str(uuid.uuid4())}), "first negative reconciliation evidence")
    if first.get("outcome") != "AWAITING_COUNTERPART":
        raise AssertionError("First negative evidence was not recorded awaiting the donor.")
    body = ok(rpc("submit_claim_reconciliation", counterpart, {
        "p_claim": claim, "p_handover_confirmed": False, "p_request": str(uuid.uuid4())}), "negative reconciliation")
    if body.get("outcome") != "RECONCILIATION_REQUIRED":
        raise AssertionError("Pickup-started negative evidence must remain under review")
    c = one("donation_claims", f"select=claim_id,claim_status&claim_id=eq.{claim}", "manual-review claim")
    if c["claim_status"] != "RECONCILIATION_REQUIRED":
        raise AssertionError("Pickup-started claim was incorrectly released")


def test_conflicting_reconciliation_evidence():
    claim = required("GEOLOCK_DEV_RECONCILE_CONFLICT_CLAIM_ID")
    ngo = required("GEOLOCK_DEV_NGO_JWT")
    counterpart = required("GEOLOCK_DEV_RECONCILE_CONFLICT_COUNTERPART_JWT")
    first = ok(rpc("submit_claim_reconciliation", ngo, {
        "p_claim": claim, "p_handover_confirmed": True, "p_request": str(uuid.uuid4())}), "first conflicting reconciliation evidence")
    if first.get("outcome") != "AWAITING_COUNTERPART":
        raise AssertionError("First conflict-case evidence was not recorded awaiting the donor.")
    body = ok(rpc("submit_claim_reconciliation", counterpart, {
        "p_claim": claim, "p_handover_confirmed": False, "p_request": str(uuid.uuid4())}), "conflicting reconciliation")
    if body.get("outcome") != "RECONCILIATION_REQUIRED":
        raise AssertionError("Conflicting party evidence did not remain in reconciliation")
    c = one("donation_claims", f"select=claim_id,claim_status&claim_id=eq.{claim}", "conflict claim")
    l = one("claim_leases", f"select=claim_id,lease_status&claim_id=eq.{claim}", "conflict lease")
    if c["claim_status"] != "RECONCILIATION_REQUIRED" or l["lease_status"] != "RECONCILIATION_REQUIRED":
        raise AssertionError("Conflicting evidence changed authoritative claim ownership")


def test_safe_no_handover_releases():
    claim = required("GEOLOCK_DEV_RECONCILE_SAFE_RELEASE_CLAIM_ID")
    listing = required("GEOLOCK_DEV_RECONCILE_SAFE_RELEASE_LISTING_ID")
    ngo = required("GEOLOCK_DEV_NGO_JWT")
    counterpart = required("GEOLOCK_DEV_RECONCILE_SAFE_COUNTERPART_JWT")
    first = ok(rpc("submit_claim_reconciliation", ngo, {
        "p_claim": claim, "p_handover_confirmed": False, "p_request": str(uuid.uuid4())}), "first safe-release evidence")
    if first.get("outcome") != "AWAITING_COUNTERPART":
        raise AssertionError("First no-handover evidence was not recorded awaiting the donor.")
    body = ok(rpc("submit_claim_reconciliation", counterpart, {
        "p_claim": claim, "p_handover_confirmed": False, "p_request": str(uuid.uuid4())}), "safe no-handover reconciliation")
    if body.get("outcome") != "SUCCESS":
        raise AssertionError("Matching no-handover evidence did not safely release an unstarted claim")
    c = one("donation_claims", f"select=claim_id,claim_status&claim_id=eq.{claim}", "safe-release claim")
    le = one("claim_leases", f"select=claim_id,lease_status&claim_id=eq.{claim}", "safe-release lease")
    task = one("pickup_tasks", f"select=claim_id,task_status&claim_id=eq.{claim}", "safe-release task")
    listing_row = one("listings", f"select=listing_id,listing_status&listing_id=eq.{listing}", "safe-release listing")
    if (c["claim_status"], le["lease_status"], task["task_status"], listing_row["listing_status"]) != (
        "RELEASED", "RELEASED", "STALE", "AVAILABLE"):
        raise AssertionError("No-handover release committed inconsistent claim/listing/task states")
    assert_persisted_donations(claim, "AVAILABLE")


def test_role_scoped_audit():
    claim = required("GEOLOCK_DEV_AUDIT_OWN_CLAIM_ID")
    ngo = required("GEOLOCK_DEV_NGO_JWT")
    result = ok(rpc("get_authorized_audit_events", ngo, {
        "p_entity_type": "CLAIM", "p_entity_id": claim}), "own-claim audit")
    if not isinstance(result, list):
        raise AssertionError("Audit RPC did not return rows")
    foreign = required("GEOLOCK_DEV_AUDIT_FOREIGN_CLAIM_ID")
    expect_rejected(rpc("get_authorized_audit_events", ngo, {
        "p_entity_type": "CLAIM", "p_entity_id": foreign}), "foreign-claim audit")
    cases = ok(rpc("get_my_reconciliation_cases", ngo, {}), "own reconciliation inbox")
    if not isinstance(cases, list):
        raise AssertionError("Reconciliation inbox did not return rows")


def main() -> int:
    env_path = load_env_file()
    safety_gate()  # No URL/key/HTTP use is allowed before this gate succeeds.
    print(f"Using guarded DEV environment: {env_path}")
    tests = [
        ("recovery authorization", test_recovery_authorization),
        ("same-request cancellation idempotency under 10 callers", test_same_request_cancel),
        ("different-request cancellation race", test_distinct_request_cancel_race),
        ("cancellation versus pickup start", test_cancel_vs_start),
        ("expired lease cannot authorize pickup start or completion", test_expired_lease_rejects_pickup),
        ("overlapping recovery, expiry cancellation race, and exact committed states", test_overlapping_recovery),
        ("claim cancellation versus expired-lease recovery", test_cancel_vs_recovery),
        ("route-linked expiry enters reconciliation", test_route_activity_reconciles),
        ("matching positive reconciliation commits COLLECTED", test_positive_reconciliation),
        ("negative evidence after dispatch remains in review", test_negative_after_dispatch_stays_review),
        ("conflicting reconciliation evidence remains fail-closed", test_conflicting_reconciliation_evidence),
        ("matching no-handover evidence safely releases only unstarted claim", test_safe_no_handover_releases),
        ("role-scoped audit retrieval", test_role_scoped_audit),
    ]
    failures = 0
    for label, test in tests:
        try:
            run(label, test)
        except Exception as error:  # report all fixture failures in one run
            failures += 1
            print(f"FAIL {label}: {error}", file=sys.stderr)
    if failures:
        print(f"{failures} Stage 1 case(s) failed", file=sys.stderr)
        return 1
    print("All configured Stage 1 claim-recovery cases passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
