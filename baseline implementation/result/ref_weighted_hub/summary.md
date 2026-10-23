# Weighted reference hub policy (reference, not a competing baseline)

Benchmark GEOLOCK-BM-v3.2. This describes this method on its own; comparing methods is done in experiment E1.

**Method.** Score every hub that passes the hard rules: 0.45 x road distance (scaled 0-1 within the donation's feasible hubs) + 0.20 x hub utilisation + 0.25 x capacity pressure + 0.10 x handling penalty. The lowest score wins (ties: shorter distance, then hub ID). This is the policy the AI model learns and falls back to; it is a reference, not a competing baseline.

**Hard rules** (a hub must pass all four): accepts the donation's category; weight <= capacity - stored - reserved; hub active; a directed road route from the donor exists.

| Result | Value | Meaning |
| --- | --- | --- |
| Scenarios | 2,019 | Small donations (< 10 kg), each with every hub within 20 km as a candidate |
| Hub recommended | 2,000 | At least one hub passed all four hard rules |
| No feasible hub | 19 | No hub passed the hard rules, so the method correctly recommends nothing |
| Feasible hubs per donation | median 21 hubs (10th-90th percentile 9-45; max 51) | How many hubs the method could choose from |
| Road distance from donor to the recommended hub | median 4.7 km (10th-90th percentile 1.8-9.3; max 24.9) | Candidates are within 20 km in a straight line; the road distance can be longer |

## How the method works

1. Take the feasible hubs (all four hard rules pass).
2. For each hub, scale its road distance to 0-1 within this donation's feasible hubs (nearest = 0, farthest = 1).
3. Score = 0.45 x scaled distance + 0.20 x utilisation (stored load / capacity: how full the hub already is) + 0.25 x capacity pressure (donation weight / remaining capacity: how much of the free space this donation would take) + 0.10 x handling penalty (by item category, clothing 0.1 up to furniture 1.0; the same for every hub of one donation, so it does not change the order). Lower is better.
4. Sort by score, lowest first (ties: shorter distance, then hub ID). Rank 1 is the recommendation.

## What to expect

- This is a weighted-sum rule (simple additive weighting), a multi-criteria rule [1]. Distance has the largest weight, so it usually picks a near hub, but it will accept a somewhat longer trip to avoid a hub that is full or busy.
- So its median distance should be a little above the nearest-hub method, while staying far below a random choice. It is the reference policy that the AI model learns and that the backend falls back to, not a competing baseline.

## How to read the results

- **Road distance** is the donor's trip to the chosen hub; read it together with the hub load columns in the benchmark if needed.
- In `details/hub_ranking.csv`, `weighted_score` is the score above (lower is better); rank 1 has the lowest score. The script stops if any score differs from the frozen `reference_score` in the benchmark, so the ranking is exactly the reference policy.
- E1 measures every hub method, including the AI model, against this ranking.

How to read a spread such as "median 3.8 km (10th-90th percentile 1.5-7.7; max 22.9)": half of the donations are at or below the median; 8 in 10 lie between the two percentiles; max is the single largest value.

## References

- [1] Hwang, C.-L., & Yoon, K. (1981). *Multiple Attribute Decision Making: Methods and Applications*. Springer. (simple additive weighting) *(not yet in the report: add it if you cite it)*
- [2] Järvelin, K., & Kekäläinen, J. (2002). Cumulated gain-based evaluation of IR techniques. *ACM Transactions on Information Systems*, 20(4), 422-446. https://doi.org/10.1145/582415.582418 *(not yet in the report: add it if you cite it)*

## Files

| File | Content |
| --- | --- |
| `results_per_scenario.csv` | **The main result.** One row per donation (scenario). |
| `details/hub_ranking.csv` | Every feasible hub of every donation, in this method's order (rank 1 = recommended). |
| `run_info.md` | What produced this run (date, benchmark, script fingerprint, command). |

### Columns of results_per_scenario.csv

| Column | Meaning |
| --- | --- |
| `scenario_id` | Benchmark scenario (one small donation looking for a hub) |
| `donation_id` | The donation |
| `status` | RECOMMENDED, or NO_FEASIBLE_HUB when no hub passes the four hard rules |
| `feasible_hubs` | How many hubs passed the hard rules (the method's choices) |
| `recommended_hub` | The method's first choice (empty when NO_FEASIBLE_HUB) |
| `distance_to_recommended_hub_km` | Road distance from the donor to that hub |
| `second_hub`, `third_hub` | The method's 2nd and 3rd choices (empty if fewer hubs) |
