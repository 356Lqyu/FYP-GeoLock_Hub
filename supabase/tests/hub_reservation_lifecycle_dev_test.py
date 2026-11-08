"""Explicit destructive integration cases for a disposable GeoLock Hub project.

This script calls state-changing RPCs. It requires an explicit disposable-project
confirmation and exact project-reference allowlist. It is intentionally NOT run.

Required environment:
  GEOLOCK_DEV_SUPABASE_URL
  GEOLOCK_DEV_ISOLATED_CONFIRMATION=I_CONFIRM_DISPOSABLE_DEV_PROJECT
  GEOLOCK_DEV_ALLOWED_PROJECT_REFS=comma,separated,project,refs
  GEOLOCK_DEV_PUBLISHABLE_KEY
  GEOLOCK_DEV_SERVICE_ROLE_KEY
  GEOLOCK_DEV_DONOR_JWT
  GEOLOCK_DEV_HUB_ADMIN_JWT
  GEOLOCK_DEV_EXPIRED_DONATION_ID
  GEOLOCK_DEV_REASSIGN_HUB_ID
  GEOLOCK_DEV_RACE_DONATION_ID
  GEOLOCK_DEV_RACE_RESERVATION_ID
  GEOLOCK_DEV_RACE_RECEIVED_WEIGHT_KG
  GEOLOCK_DEV_ALREADY_CANCELLED_DONATION_ID
  GEOLOCK_DEV_SECOND_OWNED_DONATION_ID
  GEOLOCK_DEV_BATCH_HUB_ID
  GEOLOCK_DEV_BATCH_DONATION_IDS (comma-separated, 3-5 stored donations)
  GEOLOCK_DEV_BATCH_RECEIPT_DONATION_ID / RESERVATION_ID / RECEIVED_WEIGHT_KG
  GEOLOCK_DEV_BATCH_CAPACITY_DONATION_ID

Fixtures must be disposable: a HUB_ASSIGNED donation with an expired latest
reservation and no receipt/custody; a separate HUB_ASSIGNED donation with a
current reservation and no receipt/custody; and an already-CANCELLED donation.
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

BLOCKED_REF = "mffccmlimmbrgasgfnnq"
CONFIRMATION = "I_CONFIRM_DISPOSABLE_DEV_PROJECT"


def required(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise RuntimeError(f"Missing required environment variable: {name}")
    return value


def call(url: str, key: str, jwt: str, path: str, payload=None):
    data = None if payload is None else json.dumps(payload).encode()
    req = urllib.request.Request(
        f"{url.rstrip('/')}/rest/v1/{path}", data=data,
        headers={"apikey": key, "Authorization": f"Bearer {jwt}",
                 "Content-Type": "application/json"},
        method="GET" if data is None else "POST")
    try:
        with urllib.request.urlopen(req, timeout=40) as response:
            body = response.read().decode()
            return response.status, json.loads(body) if body else None
    except urllib.error.HTTPError as error:
        body = error.read().decode(errors="replace")
        try:
            body = json.loads(body)
        except json.JSONDecodeError:
            pass
        return error.code, body


def require_success(result, label):
    if result[0] < 200 or result[0] >= 300:
        raise RuntimeError(f"{label} failed with HTTP {result[0]}: {result[1]}")
    return result[1]


def cancel_call(url, key, jwt, donation, request_id):
    return call(url, key, jwt, "rpc/cancel_donation",
                {"p_donation": donation, "p_request": request_id})


def reserve_call(url, key, jwt, donation, hub):
    return call(url, key, jwt, "rpc/reserve_hub_capacity",
                {"p_donation": donation, "p_hub": hub})


def post_race(url, *calls):
    with ThreadPoolExecutor(max_workers=len(calls)) as pool:
        return list(pool.map(lambda fn: fn(), calls))


def verify_hub_capacity(url, service, hub_admin_jwt, hub_id):
    reservations = require_success(call(url, service, service,
        f"hub_reservations?select=donation_id,reserved_weight_kg,reservation_status,expires_at&hub_id=eq.{hub_id}"), "reservations read")
    active_ids = [r["donation_id"] for r in reservations if r["reservation_status"] == "ACTIVE"]
    if len(active_ids) != len(set(active_ids)):
        raise RuntimeError("More than one ACTIVE reservation exists for a donation.")
    summary = require_success(call(url,service,hub_admin_jwt,"rpc/get_hub_dashboard",
        {"p_hub":hub_id}), "server-authoritative hub capacity summary")
    if not isinstance(summary,dict) or float(summary["committed_capacity_kg"]) > \
            float(summary["capacity_kg"]):
        raise RuntimeError("Server-authoritative hub capacity accounting invariant failed.")


def verify_cancel_audit(url, service, donation, request_id):
    rows = require_success(call(url, service, service,
        "audit_events?select=event_type,entity_id,request_id,outcome"
        f"&entity_id=eq.{donation}&request_id=eq.{request_id}"), "cancellation audit read")
    if not any(row["event_type"] == "CANCEL_DONATION" for row in rows):
        raise RuntimeError("Committed/rejected cancellation attempt has no durable audit row.")


def verify_event(url, service, entity_id, event_type):
    rows = require_success(call(url,service,service,
        "audit_events?select=event_type,entity_id,outcome"
        f"&entity_id=eq.{entity_id}&event_type=eq.{urllib.parse.quote(event_type)}"),
        f"{event_type} audit read")
    if not rows:
        raise RuntimeError(f"Missing committed {event_type} audit evidence for {entity_id}.")


def rows(url, service, path, label):
    return require_success(call(url, service, service, path), label)


def assert_one(rows_, label):
    if len(rows_) != 1:
        raise RuntimeError(f"Expected exactly one committed row for {label}; found {len(rows_)}.")
    return rows_[0]


def verify_target(url: str) -> None:
    if required("GEOLOCK_DEV_ISOLATED_CONFIRMATION") != CONFIRMATION:
        raise RuntimeError("Explicit disposable development project confirmation is required.")
    refs = {item.strip().lower() for item in
            required("GEOLOCK_DEV_ALLOWED_PROJECT_REFS").split(",") if item.strip()}
    if not refs:
        raise RuntimeError("Project-reference allowlist must contain at least one reference.")
    parsed = urllib.parse.urlparse(url)
    host = parsed.hostname or ""
    if parsed.scheme != "https" or parsed.port is not None or parsed.username or parsed.password \
            or parsed.path not in {"", "/"} or parsed.query or parsed.fragment:
        raise RuntimeError("Use only the canonical HTTPS Supabase project URL without extra URL parts.")
    suffix = ".supabase.co"
    if not host.lower().endswith(suffix):
        raise RuntimeError("Only a canonical <project-ref>.supabase.co URL is accepted.")
    ref = host[:-len(suffix)].lower()
    if ref == BLOCKED_REF or ref not in refs:
        raise RuntimeError("Target project reference is not explicitly allowlisted.")


def main() -> int:
    url = required("GEOLOCK_DEV_SUPABASE_URL")
    verify_target(url)
    key = required("GEOLOCK_DEV_PUBLISHABLE_KEY")
    service = required("GEOLOCK_DEV_SERVICE_ROLE_KEY")
    donor = required("GEOLOCK_DEV_DONOR_JWT")
    hub_admin = required("GEOLOCK_DEV_HUB_ADMIN_JWT")
    expired_donation = required("GEOLOCK_DEV_EXPIRED_DONATION_ID")
    reassignment_hub = required("GEOLOCK_DEV_REASSIGN_HUB_ID")
    race_donation = required("GEOLOCK_DEV_RACE_DONATION_ID")
    race_reservation = required("GEOLOCK_DEV_RACE_RESERVATION_ID")
    race_weight = float(required("GEOLOCK_DEV_RACE_RECEIVED_WEIGHT_KG"))
    cancelled_donation = required("GEOLOCK_DEV_ALREADY_CANCELLED_DONATION_ID")
    second_donation = required("GEOLOCK_DEV_SECOND_OWNED_DONATION_ID")
    # Extra destructive fixtures are mandatory so a partial run cannot be
    # mistaken for complete concurrency coverage.
    capacity_hub = required("GEOLOCK_DEV_CAPACITY_HUB_ID")
    capacity_donation_a = required("GEOLOCK_DEV_CAPACITY_DONATION_A_ID")
    capacity_donation_b = required("GEOLOCK_DEV_CAPACITY_DONATION_B_ID")
    reassignment_race_donation = required("GEOLOCK_DEV_CANCEL_REASSIGN_DONATION_ID")
    reassignment_race_hub = required("GEOLOCK_DEV_CANCEL_REASSIGN_HUB_ID")
    direct_donation = required("GEOLOCK_DEV_DIRECT_RACE_DONATION_ID")
    direct_listing = required("GEOLOCK_DEV_DIRECT_RACE_LISTING_ID")
    ngo = required("GEOLOCK_DEV_NGO_JWT")
    direct_claim_request = required("GEOLOCK_DEV_DIRECT_CLAIM_REQUEST_ID")
    expired_reservation = required("GEOLOCK_DEV_EXPIRED_RECEIPT_RESERVATION_ID")
    expired_receipt_weight = required("GEOLOCK_DEV_EXPIRED_RECEIPT_WEIGHT_KG")
    missing_history_donation = required("GEOLOCK_DEV_MISSING_HISTORY_DONATION_ID")
    released_history_donation = required("GEOLOCK_DEV_RELEASED_HISTORY_DONATION_ID")
    malformed_expired_history_donation = required("GEOLOCK_DEV_FUTURE_EXPIRED_HISTORY_DONATION_ID")
    same_request_donation = required("GEOLOCK_DEV_SAME_REQUEST_RACE_DONATION_ID")
    distinct_request_donation = required("GEOLOCK_DEV_DISTINCT_REQUEST_RACE_DONATION_ID")
    batch_hub = required("GEOLOCK_DEV_BATCH_HUB_ID")
    batch_donations = [v.strip() for v in required("GEOLOCK_DEV_BATCH_DONATION_IDS").split(",") if v.strip()]
    if not 3 <= len(batch_donations) <= 5 or len(set(batch_donations)) != len(batch_donations):
        raise RuntimeError("Batch fixture must contain 3-5 unique whole donations.")
    batch_receipt_donation = required("GEOLOCK_DEV_BATCH_RECEIPT_DONATION_ID")
    batch_receipt_reservation = required("GEOLOCK_DEV_BATCH_RECEIPT_RESERVATION_ID")
    batch_receipt_weight = float(required("GEOLOCK_DEV_BATCH_RECEIVED_WEIGHT_KG"))
    batch_capacity_donation = required("GEOLOCK_DEV_BATCH_CAPACITY_DONATION_ID")

    # Expiry is evaluated by SQL. This fixture must already be expired in DB.
    hubs = require_success(call(url, key, donor, "rpc/get_eligible_hubs",
                                {"p_donation": expired_donation}), "eligible hubs")
    if not any(str(row["hub_id"]) == reassignment_hub for row in hubs):
        raise RuntimeError("Prepared reassignment hub is not currently eligible.")
    new_reservation = require_success(call(
        url, key, donor, "rpc/reserve_hub_capacity",
        {"p_donation": expired_donation, "p_hub": reassignment_hub}),
        "expired-reservation reassignment")
    rows = require_success(call(
        url, service, service,
        "hub_reservations?select=reservation_id,reservation_status,expires_at,donation_id"
        f"&donation_id=eq.{expired_donation}&order=reserved_at.desc"),
        "reservation verification")
    active = [row for row in rows if row["reservation_status"] == "ACTIVE"]
    if len(active) != 1 or str(active[0]["reservation_id"]) != str(new_reservation):
        raise RuntimeError("Reassignment did not preserve history and produce one new active row.")
    if not any(row["reservation_status"] == "EXPIRED" for row in rows):
        raise RuntimeError("Previous reservation was not retained as EXPIRED.")
    verify_event(url,service,expired_donation,"RESERVE_HUB")
    verify_hub_capacity(url,service,hub_admin,reassignment_hub)

    # Race donor cancellation against authorized hub receipt. Exactly one may
    # commit; the losing call must fail after rechecking locked database state.
    request_id = str(uuid.uuid4())
    def cancel():
        return call(url, key, donor, "rpc/cancel_donation",
                    {"p_donation": race_donation, "p_request": request_id})
    def receive():
        return call(url, key, hub_admin, "rpc/confirm_hub_receipt",
                    {"p_reservation": race_reservation,
                     "p_received_weight": race_weight})
    with ThreadPoolExecutor(max_workers=2) as pool:
        cancellation, receipt = list(pool.map(lambda fn: fn(), (cancel, receive)))
    cancel_success = cancellation[0] == 200 and isinstance(cancellation[1], dict) \
        and cancellation[1].get("outcome") == "SUCCESS"
    receipt_success = receipt[0] == 200
    if cancellation[0] >= 500 or receipt[0] >= 500:
        raise RuntimeError("Cancellation/receipt race produced a server failure rather than a domain result.")
    if cancel_success == receipt_success:
        raise RuntimeError("Cancellation/receipt race did not have exactly one winner.")
    if not cancel_success and cancellation[0] == 200 and (
        not isinstance(cancellation[1],dict) or cancellation[1].get("outcome") != "REJECTED"):
        raise RuntimeError("Cancellation loser did not return its documented REJECTED result.")
    if not receipt_success and (receipt[0] < 400 or receipt[0] >= 500):
        raise RuntimeError("Receipt loser did not return an expected client/domain rejection.")
    donation_state = require_success(call(
        url, service, service,
        f"donations?select=donation_status&donation_id=eq.{race_donation}"),
        "race donation state verification")
    reservation_state = require_success(call(
        url, service, service,
        f"hub_reservations?select=reservation_status,hub_id&reservation_id=eq.{race_reservation}"),
        "race reservation state verification")
    receipts = require_success(call(
        url, service, service,
        f"hub_receipts?select=receipt_id&reservation_id=eq.{race_reservation}"),
        "race receipt verification")
    if cancel_success and (donation_state[0]["donation_status"] != "CANCELLED"
        or reservation_state[0]["reservation_status"] not in {"RELEASED", "EXPIRED"}
        or receipts):
        raise RuntimeError("Cancellation winner left contradictory receipt/reservation state.")
    if receipt_success and (donation_state[0]["donation_status"] != "AT_HUB"
        or reservation_state[0]["reservation_status"] != "CONSUMED"
        or len(receipts) != 1):
        raise RuntimeError("Receipt winner did not commit a single consistent receipt.")
    race_inventory = require_success(call(url,service,service,
        f"hub_inventory?select=inventory_status,hub_id&donation_id=eq.{race_donation}"),
        "cancel/receipt inventory state")
    if cancel_success and race_inventory:
        raise RuntimeError("Cancellation winner unexpectedly committed hub inventory.")
    if receipt_success and (len(race_inventory) != 1
        or race_inventory[0]["inventory_status"] != "STORED"
        or race_inventory[0]["hub_id"] != reservation_state[0]["hub_id"]):
        raise RuntimeError("Receipt winner lacks matching STORED inventory.")
    if receipt_success:
        verify_event(url,service,race_donation,"CONFIRM_HUB_RECEIPT")
    verify_cancel_audit(url,service,race_donation,request_id)
    if reservation_state:
        verify_hub_capacity(url,service,hub_admin,reservation_state[0]["hub_id"])

    # The deployed contract returns ALREADY_CANCELLED success. Replay of one
    # request UUID must return the stored response byte-for-byte semantically.
    idem_request = str(uuid.uuid4())
    payload = {"p_donation": cancelled_donation, "p_request": idem_request}
    first = require_success(call(url, key, donor, "rpc/cancel_donation", payload),
                            "already-cancelled request")
    second = require_success(call(url, key, donor, "rpc/cancel_donation", payload),
                             "idempotency replay")
    if first != second or first.get("reason_code") != "ALREADY_CANCELLED":
        raise RuntimeError("Already-cancelled or request replay semantics changed.")
    verify_cancel_audit(url,service,cancelled_donation,idem_request)
    reused = require_success(call(url, key, donor, "rpc/cancel_donation",
        {"p_donation": second_donation, "p_request": idem_request}),
        "cross-donation idempotency-key reuse")
    if reused.get("outcome") != "REJECTED" or reused.get("reason_code") != \
            "IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD":
        raise RuntimeError("A request UUID was reusable across donations.")
    verify_cancel_audit(url,service,second_donation,idem_request)

    # Ensure the partial unique invariant still holds for the reassigned test row.
    if len(active) != 1:
        raise RuntimeError("More than one active reservation exists.")

    # Two independent reservation requests contend for a hub with room for
    # exactly one fixture. Exactly one must commit; capacity and uniqueness are
    # checked from committed rows afterward.
    cap_results = post_race(url,
        lambda: reserve_call(url,key,donor,capacity_donation_a,capacity_hub),
        lambda: reserve_call(url,key,donor,capacity_donation_b,capacity_hub))
    cap_winners = [r for r in cap_results if 200 <= r[0] < 300]
    if len(cap_winners) != 1:
        raise RuntimeError("Near-capacity reservation race must have exactly one winner.")
    winner_index = next(i for i,result in enumerate(cap_results) if 200 <= result[0] < 300)
    verify_event(url,service,(capacity_donation_a,capacity_donation_b)[winner_index],"RESERVE_HUB")
    verify_hub_capacity(url,service,hub_admin,capacity_hub)

    # Cancellation versus reassignment may both return success only when the
    # reservation commits first and cancellation subsequently atomically
    # releases it. Final state must never retain an ACTIVE row on CANCELLED.
    reassignment_request = str(uuid.uuid4())
    race_results = post_race(url,
        lambda: cancel_call(url,key,donor,reassignment_race_donation,reassignment_request),
        lambda: reserve_call(url,key,donor,reassignment_race_donation,reassignment_race_hub))
    cancel_reassign_body = race_results[0][1] if race_results[0][0] == 200 else None
    if not isinstance(cancel_reassign_body,dict) or cancel_reassign_body.get("outcome") != "SUCCESS":
        raise RuntimeError("Cancellation did not safely complete in the reassignment race.")
    final_state = require_success(call(url,service,service,
        f"donations?select=donation_status&donation_id=eq.{reassignment_race_donation}"),
        "cancel/reassignment final state")
    final_res = require_success(call(url,service,service,
        "hub_reservations?select=reservation_status"
        f"&donation_id=eq.{reassignment_race_donation}"), "cancel/reassignment reservations")
    if final_state and final_state[0]["donation_status"] == "CANCELLED" and any(
            row["reservation_status"] == "ACTIVE" for row in final_res):
        raise RuntimeError("Cancelled donation retained an ACTIVE reservation.")
    if final_state and final_state[0]["donation_status"] == "HUB_ASSIGNED" \
            and sum(row["reservation_status"] == "ACTIVE" for row in final_res) != 1:
        raise RuntimeError("Reassignment winner did not retain exactly one ACTIVE reservation.")
    if not final_state or final_state[0]["donation_status"] not in {"CANCELLED","HUB_ASSIGNED"}:
        raise RuntimeError("Cancellation/reassignment race left an unexpected donation state.")
    if any(row["reservation_status"] == "CONSUMED" for row in final_res):
        raise RuntimeError("Cancellation/reassignment race created an impossible consumed reservation.")
    if 200 <= race_results[1][0] < 300:
        verify_event(url,service,reassignment_race_donation,"RESERVE_HUB")
    verify_cancel_audit(url,service,reassignment_race_donation,reassignment_request)
    verify_hub_capacity(url,service,hub_admin,reassignment_race_hub)

    # Batch publication preserves the deployed whole-donation rules and is
    # raced on the same hub against receipt and reservation capacity accounting.
    # Fixtures must leave enough capacity for all three operations to commit.
    batch_calls = post_race(url,
        lambda: call(url,key,hub_admin,"rpc/publish_whole_donation_batch",
            {"p_hub":batch_hub,"p_donation_ids":batch_donations}),
        lambda: call(url,key,hub_admin,"rpc/confirm_hub_receipt",
            {"p_reservation":batch_receipt_reservation,
             "p_received_weight":batch_receipt_weight}),
        lambda: reserve_call(url,key,donor,batch_capacity_donation,batch_hub))
    if any(not (200 <= r[0] < 300) for r in batch_calls):
        raise RuntimeError("Batch/receipt/capacity race failed; use fixtures with sufficient shared-hub capacity.")
    batch_id = batch_calls[0][1]
    batch = assert_one(rows(url,service,
        f"hub_batches?select=batch_id,batch_status,batch_weight_kg,batch_donation_count&batch_id=eq.{batch_id}",
        "published batch committed state"), "published batch")
    if batch["batch_status"] != "PUBLISHED" or int(batch["batch_donation_count"]) != len(batch_donations):
        raise RuntimeError("Batch publication did not commit the expected published whole batch.")
    members = rows(url,service,
        f"hub_batch_members?select=donation_id,membership_status&batch_id=eq.{batch_id}",
        "batch membership committed state")
    if len(members) != len(batch_donations) or {r["donation_id"] for r in members} != set(batch_donations) \
            or any(r["membership_status"] != "ACTIVE" for r in members):
        raise RuntimeError("Batch membership differs from the requested whole-donation set.")
    for donation_id in batch_donations:
        donation = assert_one(rows(url,service,
            f"donations?select=donation_status&donation_id=eq.{donation_id}", "batched donation state"),
            f"batched donation {donation_id}")
        inventory = assert_one(rows(url,service,
            f"hub_inventory?select=hub_id,inventory_status&donation_id=eq.{donation_id}",
            "batched inventory state"), f"inventory {donation_id}")
        if donation["donation_status"] != "BATCHED" or inventory["inventory_status"] != "BATCHED" \
                or inventory["hub_id"] != batch_hub:
            raise RuntimeError("Batch publication left donation and inventory states inconsistent.")
    listing = assert_one(rows(url,service,
        f"listings?select=listing_id,source_type,batch_id,listing_status,listing_expires_at&batch_id=eq.{batch_id}",
        "batch listing committed state"), "batch listing")
    if listing["source_type"] != "HUB_BATCH" or listing["listing_status"] != "AVAILABLE" \
            or listing["listing_expires_at"] is not None:
        raise RuntimeError("Batch listing must be available with the intentional NULL expiry.")
    verify_event(url,service,batch_id,"PUBLISH_BATCH")
    receipt_race_donation = assert_one(rows(url,service,
        f"donations?select=donation_status&donation_id=eq.{batch_receipt_donation}",
        "receipt race donation"), "receipt race donation")
    receipt_race_reservation = assert_one(rows(url,service,
        f"hub_reservations?select=reservation_status&reservation_id=eq.{batch_receipt_reservation}",
        "receipt race reservation"), "receipt race reservation")
    committed_receipt = rows(url,service,
        f"hub_receipts?select=receipt_id&reservation_id=eq.{batch_receipt_reservation}",
        "receipt race receipt")
    if receipt_race_donation["donation_status"] != "AT_HUB" \
            or receipt_race_reservation["reservation_status"] != "CONSUMED" or len(committed_receipt) != 1:
        raise RuntimeError("Receipt did not commit consistent donation/reservation/receipt states.")
    receipt_inventory = assert_one(rows(url,service,
        f"hub_inventory?select=hub_id,inventory_status&donation_id=eq.{batch_receipt_donation}",
        "receipt race inventory state"), "receipt race inventory")
    if receipt_inventory["hub_id"] != batch_hub or receipt_inventory["inventory_status"] != "STORED":
        raise RuntimeError("Receipt committed without matching STORED inventory.")
    verify_event(url,service,batch_receipt_donation,"CONFIRM_HUB_RECEIPT")
    capacity_reservation = rows(url,service,
        f"hub_reservations?select=reservation_status,donation_id&donation_id=eq.{batch_capacity_donation}",
        "batch race capacity reservation")
    if sum(r["reservation_status"] == "ACTIVE" for r in capacity_reservation) != 1:
        raise RuntimeError("Capacity operation did not commit exactly one active reservation.")
    verify_event(url,service,batch_capacity_donation,"RESERVE_HUB")
    verify_hub_capacity(url,service,hub_admin,batch_hub)

    # Direct cancellation and NGO claim race on the direct listing. One logical
    # state transition wins; any successful claim response must be committed.
    direct_cancel_request = str(uuid.uuid4())
    direct_results = post_race(url,
        lambda: cancel_call(url,key,donor,direct_donation,direct_cancel_request),
        lambda: call(url,key,ngo,"rpc/claim_listing",
                     {"p_listing":direct_listing,"p_request":direct_claim_request}))
    claim_body = direct_results[1][1] if direct_results[1][0] == 200 else None
    claim_success = isinstance(claim_body,dict) and claim_body.get("outcome") == "SUCCESS"
    cancel_body = direct_results[0][1] if direct_results[0][0] == 200 else None
    direct_cancel_success = isinstance(cancel_body,dict) and cancel_body.get("outcome") == "SUCCESS"
    if claim_success == direct_cancel_success:
        raise RuntimeError("Direct cancellation and eligible NGO claim did not have exactly one winner.")
    if direct_results[1][0] != 200 or (not claim_success and
            (not isinstance(claim_body,dict) or claim_body.get("reason_code") != "CLAIM_CONFLICT")):
        raise RuntimeError("Claim race fixture was not eligible or failed for an unexpected reason.")
    committed_listing = assert_one(rows(url,service,
        f"listings?select=listing_status&listing_id=eq.{direct_listing}", "direct race listing state"),
        "direct race listing")
    committed_donation = assert_one(rows(url,service,
        f"donations?select=donation_status&donation_id=eq.{direct_donation}", "direct race donation state"),
        "direct race donation")
    claim_rows = rows(url,service,
        f"donation_claims?select=claim_id,claim_status,listing_id&listing_id=eq.{direct_listing}",
        "direct race claim state")
    if claim_success:
        active_claim = next(r for r in claim_rows if r["claim_status"] == "ACTIVE")
        leases = rows(url,service,
            f"claim_leases?select=claim_id,lease_status,expires_at&claim_id=eq.{active_claim['claim_id']}",
            "direct race claim lease")
        if committed_listing["listing_status"] != "CLAIMED" or committed_donation["donation_status"] != "CLAIMED" \
                or len(leases) != 1 or leases[0]["lease_status"] != "ACTIVE":
            raise RuntimeError("Successful claim response is not reflected in committed listing/donation/claim state.")
        if leases[0]["claim_id"] != active_claim["claim_id"]:
            raise RuntimeError("Claim lease is not linked to the active committed claim.")
    elif committed_listing["listing_status"] != "CANCELLED" or committed_donation["donation_status"] != "CANCELLED" \
            or any(r["claim_status"] == "ACTIVE" for r in claim_rows):
        raise RuntimeError("Cancellation winner left an active claim or inconsistent direct states.")
    if direct_results[1][0] == 200:
        verify_event(url,service,direct_listing,"CLAIM_ATTEMPT")
    verify_cancel_audit(url,service,direct_donation,direct_cancel_request)

    # Cancellation idempotency under same-key and distinct-key concurrency.
    same_id = str(uuid.uuid4())
    same_results = post_race(url,
        lambda: cancel_call(url,key,donor,same_request_donation,same_id),
        lambda: cancel_call(url,key,donor,same_request_donation,same_id))
    if any(r[0] != 200 for r in same_results) or same_results[0][1] != same_results[1][1]:
        raise RuntimeError("Same request ID concurrent replay was not idempotent.")
    verify_cancel_audit(url,service,same_request_donation,same_id)
    different_ids=(str(uuid.uuid4()),str(uuid.uuid4()))
    different_results = post_race(url,
        lambda: cancel_call(url,key,donor,distinct_request_donation,different_ids[0]),
        lambda: cancel_call(url,key,donor,distinct_request_donation,different_ids[1]))
    if any(r[0] != 200 for r in different_results):
        raise RuntimeError("Different-request cancellation concurrency returned transport errors.")
    for request_id in different_ids:
        verify_cancel_audit(url,service,distinct_request_donation,request_id)

    # Missing or released reservation history must fail closed for an assigned
    # hub donation; no cancellation mutation is allowed.
    for bad_donation,label in ((missing_history_donation,"missing history"),
                               (released_history_donation,"released history"),
                               (malformed_expired_history_donation,"future-dated EXPIRED history")):
        bad_request = str(uuid.uuid4())
        bad_result = cancel_call(url,key,donor,bad_donation,bad_request)
        if bad_result[0] != 200 or not isinstance(bad_result[1],dict) \
                or bad_result[1].get("outcome") != "REJECTED":
            raise RuntimeError(f"{label} fixture did not fail closed.")
        bad_state = require_success(call(url,service,service,
            f"donations?select=donation_status&donation_id=eq.{bad_donation}"), f"{label} state")
        if bad_state[0]["donation_status"] != "HUB_ASSIGNED":
            raise RuntimeError(f"{label} fixture was mutated despite rejection.")
        verify_cancel_audit(url,service,bad_donation,bad_request)

    # Hub receipt after expiry must be rejected without a receipt/custody write.
    expired_result = call(url,key,hub_admin,"rpc/confirm_hub_receipt",
        {"p_reservation":expired_reservation,"p_received_weight":float(expired_receipt_weight)})
    if 200 <= expired_result[0] < 300:
        raise RuntimeError("Receipt succeeded after reservation expiry.")
    expired_rows = require_success(call(url,service,service,
        "hub_reservations?select=hub_id,reservation_status&reservation_id=eq."+expired_reservation),
        "expired receipt reservation state")
    expired_receipts = require_success(call(url,service,service,
        "hub_receipts?select=receipt_id&reservation_id=eq."+expired_reservation),
        "expired receipt absence check")
    if not expired_rows or expired_rows[0]["reservation_status"] != "ACTIVE" or expired_receipts:
        raise RuntimeError("Rejected expired receipt changed reservation/custody state.")
    verify_hub_capacity(url,service,hub_admin,expired_rows[0]["hub_id"])

    verify_hub_capacity(url,service,hub_admin,capacity_hub)
    verify_hub_capacity(url,service,hub_admin,reassignment_race_hub)
    if reservation_state:
        verify_hub_capacity(url,service,hub_admin,reservation_state[0]["hub_id"])
    print(json.dumps({"expired_reassignment": "PASS", "capacity_race": "PASS",
                      "cancel_vs_receipt": "PASS", "cancel_vs_reassignment": "PASS",
                      "direct_cancel_vs_claim": "PASS", "cancel_request_races": "PASS",
                      "bad_reservation_history_fails_closed": "PASS",
                      "receipt_after_expiry_rejected": "PASS",
                      "capacity_audit_invariants": "PASS", "batch_publication": "PASS",
                      "batch_vs_receipt_and_capacity": "PASS",
                      "already_cancelled_replay": "PASS",
                      "request_id_cross_donation_reuse": "PASS"},
                     indent=2))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        print(f"DEV TEST BLOCKED/FAILED: {exc}", file=sys.stderr)
        sys.exit(1)
