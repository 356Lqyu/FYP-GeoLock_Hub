"""GeoLock Hub — preliminary atomic-claim concurrency smoke test.

Tests C2, C5 and C10 with all requests in each trial competing concurrently.
Run ONLY against an isolated test database.
"""

import csv
import json
import os
import threading
import time
import uuid
from collections import Counter
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from pathlib import Path

import psycopg
from dotenv import load_dotenv

BASE_DIR = Path(__file__).resolve().parent
load_dotenv(BASE_DIR / ".env")
DATABASE_URL = os.getenv("TEST_DATABASE_URL")
if not DATABASE_URL:
    raise RuntimeError("TEST_DATABASE_URL missing from .env")

DONOR_EMAIL = "donor1@test.com"
NGO_EMAILS = ["ngo1@test.com", "ngo2@test.com", "ngo3@test.com"]
TEST_SIZES = (2, 5, 10)
REPEATS = 3
MAX_WORKERS = 10  # Keep below the observed session-pooler limit of 15.


def connect():
    return psycopg.connect(DATABASE_URL, connect_timeout=20, autocommit=True)


def user_id_for(email):
    with connect() as conn, conn.cursor() as cur:
        cur.execute("""
            select u.id
            from auth.users u
            join public.user_profiles p on p.user_id = u.id
            where u.email = %s and p.account_status = 'ACTIVE'
        """, (email,))
        row = cur.fetchone()
        if row is None:
            raise RuntimeError(f"Active user profile not found: {email}")
        return row[0]


def fresh_listing(donor_id):
    title = f"Concurrency Test {uuid.uuid4()}"
    items = json.dumps([
        {"category": "food", "item_name": "Rice bag", "quantity": 2, "unit_weight_kg": 5},
        {"category": "food", "item_name": "Canned food pack", "quantity": 2, "unit_weight_kg": 1},
    ])
    with connect() as conn, conn.cursor() as cur:
        cur.execute("""
            select public.test_create_donation(
                %s::uuid, %s::text, %s::text, %s::text, %s::text,
                now(), now() + interval '48 hours', %s::jsonb
            )
        """, (donor_id, title, "Synthetic claim contention test",
              "Synthetic Test Location", "TEST_NODE_001", items))
        donation_id = cur.fetchone()[0]
        cur.execute("""
            select listing_id from public.listings
            where donation_id = %s and listing_status = 'AVAILABLE'
        """, (donation_id,))
        row = cur.fetchone()
        if row is None:
            raise RuntimeError("No AVAILABLE listing for newly created donation")
        return donation_id, row[0]


def claim_worker(listing_id, ngo_id, barrier):
    request_id = uuid.uuid4()
    started = None
    try:
        # Open the connection BEFORE the wave barrier so the wave competes
        # over the same listing with already established DB sessions.
        with connect() as conn, conn.cursor() as cur:
            barrier.wait(timeout=45)
            started = time.perf_counter()
            cur.execute("""
                select outcome, claim_id, message
                from public.test_claim_listing(%s::uuid, %s::uuid, %s::uuid)
            """, (listing_id, ngo_id, request_id))
            outcome, claim_id, message = cur.fetchone()
            return {
                "ngo_id": str(ngo_id), "request_id": str(request_id),
                "outcome": outcome, "claim_id": str(claim_id) if claim_id else "",
                "message": message,
                "latency_ms": round((time.perf_counter() - started) * 1000, 3),
                "error": "",
            }
    except Exception as exc:
        return {
            "ngo_id": str(ngo_id), "request_id": str(request_id),
            "outcome": "ERROR", "claim_id": "", "message": "",
            "latency_ms": round((time.perf_counter() - started) * 1000, 3)
            if started is not None else "",
            "error": f"{type(exc).__name__}: {exc}",
        }


def database_state(listing_id):
    with connect() as conn, conn.cursor() as cur:
        cur.execute("""
            select
                (select count(*) from public.donation_claims
                 where listing_id = %s and claim_status = 'ACTIVE'),
                (select count(*) from public.claim_leases cl
                 join public.donation_claims dc on dc.claim_id = cl.claim_id
                 where dc.listing_id = %s and cl.lease_status = 'ACTIVE'),
                (select listing_status from public.listings where listing_id = %s),
                (select count(*) from public.donation_claims where listing_id = %s)
        """, (listing_id, listing_id, listing_id, listing_id))
        return cur.fetchone()


def run_trial(n, trial, donor_id, ngo_ids):
    donation_id, listing_id = fresh_listing(donor_id)
    print(f"Running C{n}, trial {trial}: listing {listing_id}", flush=True)
    results = []

    # All workers start together for the report-defined levels (2, 5, 10).
    for wave_start in range(0, n, MAX_WORKERS):
        wave_count = min(MAX_WORKERS, n - wave_start)
        barrier = threading.Barrier(wave_count)
        with ThreadPoolExecutor(max_workers=wave_count) as executor:
            futures = [
                executor.submit(
                    claim_worker, listing_id,
                    ngo_ids[(wave_start + i) % len(ngo_ids)], barrier
                )
                for i in range(wave_count)
            ]
            for future in as_completed(futures):
                results.append(future.result())

    counts = Counter(r["outcome"] for r in results)
    active_claims, active_leases, status, total_claims = database_state(listing_id)
    passed = (
        counts["SUCCESS"] == 1 and counts["CONFLICT"] == n - 1
        and counts["INELIGIBLE"] == 0 and counts["ERROR"] == 0
        and active_claims == 1 and active_leases == 1
        and total_claims == 1 and status == "CLAIMED"
    )
    print(
        f"  SUCCESS={counts['SUCCESS']}, CONFLICT={counts['CONFLICT']}, "
        f"INELIGIBLE={counts['INELIGIBLE']}, ERROR={counts['ERROR']}; "
        f"active_claims={active_claims}, active_leases={active_leases}, "
        f"total_claims={total_claims}, status={status}, PASS={passed}",
        flush=True,
    )
    if counts["ERROR"]:
        sample = next(r["error"] for r in results if r["outcome"] == "ERROR")
        print(f"  First error: {sample[:350]}", flush=True)

    summary = {
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "test_size": n, "trial": trial,
        "max_concurrent_db_workers": min(n, MAX_WORKERS),
        "donation_id": str(donation_id), "listing_id": str(listing_id),
        "successes": counts["SUCCESS"], "conflicts": counts["CONFLICT"],
        "ineligible": counts["INELIGIBLE"], "errors": counts["ERROR"],
        "active_claims": active_claims, "active_leases": active_leases,
        "total_claims": total_claims, "listing_status": status,
        "passed": passed,
    }
    request_rows = [
        {"test_size": n, "trial": trial, "listing_id": str(listing_id), **r}
        for r in results
    ]
    return summary, request_rows


def write_csv(path, rows):
    if not rows:
        return
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)
    print(f"Saved {path}")


def main():
    print("GeoLock Hub: preliminary atomic claim contention test")
    print(f"Maximum concurrent DB workers: {MAX_WORKERS}")
    print("Testing report-defined concurrency levels: C2, C5, C10.\n")
    donor_id = user_id_for(DONOR_EMAIL)
    ngo_ids = [user_id_for(email) for email in NGO_EMAILS]
    summaries, request_rows = [], []

    for n in TEST_SIZES:
        for trial in range(1, REPEATS + 1):
            summary, rows = run_trial(n, trial, donor_id, ngo_ids)
            summaries.append(summary)
            request_rows.extend(rows)

    write_csv(BASE_DIR / "concurrency_summary.csv", summaries)
    write_csv(BASE_DIR / "concurrency_requests.csv", request_rows)
    if all(s["passed"] for s in summaries):
        print("\nAll preliminary contention trials PASSED.")
    else:
        print("\nSome trials FAILED. Inspect concurrency_requests.csv.")
        raise SystemExit(1)


if __name__ == "__main__":
    main()
