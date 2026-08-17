import numpy as np
import pandas as pd
from baseline_common import read_csv, save_csv

# Claim Concurrency & Coordination Baselines (RQ1)
claims = read_csv("claim_input_events.csv").copy()
geofence = read_csv("geofence_notification_events.csv").copy()

# Determine geofence eligibility from search round records
geofence["listing_key"] = geofence["listing_id"]
eligible = (geofence.groupby(["listing_key", "ngo_id"], as_index=False)["geofence_eligible"]
            .max().rename(columns={"geofence_eligible": "eligible"}))
claims["listing_key"] = claims["listing_id"]
claims = claims.merge(eligible, on=["listing_key", "ngo_id"], how="left")
claims["eligible"] = claims["eligible"].fillna(False).astype(bool)
claims = claims.sort_values(["split", "listing_key", "attempt_delay_seconds", "claim_id"]).reset_index(drop=True)

# Baseline 1: Manual Non-Atomic Claim Processing
# No transaction protection; every geographically eligible request is accepted, causing race conditions.
manual = claims.copy()
manual["accepted"] = manual["eligible"]
manual["reason"] = np.where(manual["eligible"], "NON_ATOMIC_ACCEPTED", "INELIGIBLE")
save_csv(manual, "manual_non_atomic_claim_results.csv")

# Baseline 2: Transaction-Protected Reservation (Without Lease Management)
# Serializes access: earliest eligible request wins; subsequent simultaneous requests are rejected.
atomic = claims.copy()
atomic["accepted"] = False
for _, group in atomic.groupby("listing_key", sort=False):
    eligible_indices = group.index[group["eligible"]]
    if len(eligible_indices):
        atomic.loc[eligible_indices[0], "accepted"] = True
atomic["reason"] = np.where(
    ~atomic["eligible"], "INELIGIBLE",
    np.where(atomic["accepted"], "ATOMIC_WINNER", "ALREADY_RESERVED")
)
save_csv(atomic, "transaction_protected_reservation_results.csv")

# Calculate evaluation metrics for coordination stress testing
summary_rows = []

for name, df in [("manual_non_atomic", manual), ("transaction_protected_reservation", atomic)]:
    test = df[(df["split"] == "test") & (df["eligible"])]
    listing = test.groupby("listing_key")["accepted"].agg(successes="sum", attempts="size").reset_index()
    duplicate = int((listing["successes"] > 1).sum())
    wasted = int(np.maximum(listing["successes"] - 1, 0).sum())
    
    summary_rows.append({
        "baseline": name,
        "eligible_attempts": len(test),
        "successful_claims": int(test["accepted"].sum()),
        "claim_success_rate": float(test["accepted"].mean()) if len(test) else 0.0,
        "duplicate_claim_listings": duplicate,
        "duplicate_claim_rate": duplicate / len(listing) if len(listing) else 0.0,
        "wasted_dispatches": wasted,
    })

# Convert and save as CSV
summary_df = pd.DataFrame(summary_rows)
save_csv(summary_df, "claim_evaluation_summary.csv")

print("\nClaim Evaluation Summary Generated:")
print(summary_df.to_string(index=False))