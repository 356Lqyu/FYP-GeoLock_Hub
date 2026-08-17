import random
import pandas as pd
from baseline_common import read_csv, save_csv, SEED

pairs = read_csv("recommendation_candidate_pairs.csv")
feasible = pairs[pairs["feasible"] == True].copy()

# Identify the single best "ground-truth" hub for each donation based on the deterministic benchmark oracle score
best = (feasible.sort_values(["donation_id", "oracle_score", "hub_id"])
        .groupby("donation_id", as_index=False).first()
        [["donation_id", "hub_id", "oracle_score"]]
        .rename(columns={"hub_id": "oracle_best_hub", "oracle_score": "oracle_best_score"}))
feasible = feasible.merge(best, on="donation_id", how="left")

# Randomly Selecting a Hub Using a Frozen Seed
rng = random.Random(SEED)
rows = []
for donation_id, group in feasible.groupby("donation_id", sort=True):
    row = group.iloc[rng.randrange(len(group))]
    rows.append({
        "donation_id": donation_id,
        "split": row["split"],
        "recommended_hub": row["hub_id"],
        "donor_to_hub_road_km": row["donor_to_hub_road_km"],
        "selected_oracle_score": row["oracle_score"],
        "oracle_best_hub": row["oracle_best_hub"],
        "oracle_best_score": row["oracle_best_score"],
        "top1_correct": row["hub_id"] == row["oracle_best_hub"],
    })

result = pd.DataFrame(rows)
save_csv(result, "random_hub_selection_results.csv")
print(result.to_string(index=False))
