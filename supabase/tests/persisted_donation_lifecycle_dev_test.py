"""Prepared stateful acceptance tests. NOT part of offline contract discovery.

Requires six fresh, disposable, already eligible listings (DIRECT/HUB x
PICKUP/CANCEL/RACE), supplied as GEOLOCK_LIFECYCLE_<kind>_<scenario>_LISTING_ID.
Hub fixtures must already be published whole-donation batches. No fixtures are
created here. Uses the existing exact DEV allowlist and credential guards.
Never run before separate deployment/testing approval.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import uuid

from stage1_claim_recovery_dev_test import (
    load_env_file, safety_gate, required, rpc, read, ok, one,
)


def listing_state(listing_id):
    listing = one("listings",
                  f"select=source_type,donation_id,batch_id,listing_status&listing_id=eq.{listing_id}",
                  "listing")
    if listing["source_type"] == "DIRECT_DONATION":
        ids = [listing["donation_id"]]
    else:
        batch = one("hub_batches",
                    f"select=batch_donation_count&batch_id=eq.{listing['batch_id']}", "batch")
        members = ok(read("hub_batch_members",
                          f"select=donation_id&batch_id=eq.{listing['batch_id']}&membership_status=eq.ACTIVE"),
                     "members")
        ids = sorted(row["donation_id"] for row in members)
        assert len(ids) == batch["batch_donation_count"] > 0
    donations = [one("donations", f"select=donation_status&donation_id=eq.{donation}", "donation")
                 for donation in ids]
    return listing, ids, {row["donation_status"] for row in donations}


def assert_state(listing_id, expected, listing_status):
    listing, ids, states = listing_state(listing_id)
    assert states == {expected}, (expected, states)
    assert listing["listing_status"] == listing_status
    if listing["source_type"] == "HUB_BATCH":
        for donation in ids:
            inventory = one("hub_inventory",
                            f"select=inventory_status&donation_id=eq.{donation}", "inventory")
            assert inventory["inventory_status"] == ("COLLECTED" if expected == "COLLECTED" else "BATCHED")
        batch = one("hub_batches", f"select=batch_status&batch_id=eq.{listing['batch_id']}", "batch")
        assert batch["batch_status"] == ("COLLECTED" if expected == "COLLECTED" else "PUBLISHED")


def claim_fresh(listing_id, kind, ngo):
    assert_state(listing_id, "AVAILABLE" if kind == "DIRECT" else "BATCHED", "AVAILABLE")
    request = str(uuid.uuid4())
    payload = {"p_listing": listing_id, "p_request": request}
    response = ok(rpc("claim_listing", ngo, payload), "claim")
    assert response["outcome"] == "SUCCESS", response
    assert_state(listing_id, "CLAIMED", "CLAIMED")
    replay = ok(rpc("claim_listing", ngo, payload), "claim replay")
    assert replay["claim_id"] == response["claim_id"] and replay["replayed"] is True
    return response["claim_id"]


def exercise(kind, scenario, listing_id, ngo):
    claim = claim_fresh(listing_id, kind, ngo)
    released = "AVAILABLE" if kind == "DIRECT" else "BATCHED"
    if scenario == "PICKUP":
        ok(rpc("start_pickup", ngo, {"p_claim": claim}), "start")
        assert_state(listing_id, "PICKUP_IN_PROGRESS", "CLAIMED")
        ok(rpc("complete_pickup", ngo, {"p_claim": claim, "p_handover_confirmed": True}), "complete")
        assert_state(listing_id, "COLLECTED", "CLOSED")
    elif scenario == "CANCEL":
        payload = {"p_claim": claim, "p_request": str(uuid.uuid4())}
        result = ok(rpc("cancel_claim", ngo, payload), "cancel")
        assert result["outcome"] == "SUCCESS", result
        assert_state(listing_id, released, "AVAILABLE")
        assert ok(rpc("cancel_claim", ngo, payload), "cancel replay") == result
    else:
        payload = {"p_claim": claim, "p_request": str(uuid.uuid4())}
        with ThreadPoolExecutor(max_workers=2) as pool:
            start = pool.submit(rpc, "start_pickup", ngo, {"p_claim": claim})
            cancel = pool.submit(rpc, "cancel_claim", ngo, payload)
            start, cancel = start.result(), cancel.result()
        started = 200 <= start[0] < 300
        cancelled = (200 <= cancel[0] < 300 and isinstance(cancel[1], dict)
                     and cancel[1].get("outcome") == "SUCCESS")
        assert started != cancelled, (start, cancel)
        assert_state(listing_id, "PICKUP_IN_PROGRESS" if started else released,
                     "CLAIMED" if started else "AVAILABLE")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--run-stateful", action="store_true", required=True)
    parser.parse_args()
    load_env_file()
    safety_gate()  # No network operations before the existing exact DEV gate.
    fixtures = [(kind, scenario, str(uuid.UUID(required(
        f"GEOLOCK_LIFECYCLE_{kind}_{scenario}_LISTING_ID"))))
        for kind in ("DIRECT", "HUB") for scenario in ("PICKUP", "CANCEL", "RACE")]
    if len({listing for _, _, listing in fixtures}) != 6:
        raise RuntimeError("Six distinct disposable listings are required.")
    ngo = required("GEOLOCK_DEV_NGO_JWT")
    for kind, scenario, listing in fixtures:
        exercise(kind, scenario, listing, ngo)
        print(f"PASS {kind} {scenario}: full persisted donation set and coordination verified")


if __name__ == "__main__":
    main()
