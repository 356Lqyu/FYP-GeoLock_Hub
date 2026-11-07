# Nearest-Hub (baseline 1)

Benchmark GEOLOCK-BM-v3.3.

## What this baseline does

Among the hubs that pass all five hard rules, recommend the one with the shortest road distance from the donor (ties: hub ID). Same order as the backend get_eligible_hubs().

## Compared with (experiment E1, RQ1)

| | This baseline | Proposed method (E1) |
| --- | --- | --- |
| Ranking | shortest road distance | AI model (Random Forest / XGBoost) that predicts the reference score |
| Same inputs | | same feasible hubs (five hard rules), same road distances, same tie rule (shorter distance, then hub ID), Top-k = 3 |

Score only the 349 held-out test donations listed in `ai hub ranking/data split/split/test_scenario_ids.csv`, pairing rows by `scenario_id`. Main metric: **Top-1 agreement** with the weighted reference policy (`../ref_weighted_hub/`); NDCG@3 and Top-3 coverage come from `details/hub_ranking.csv`. This baseline tests whether road distance alone can reproduce the reference ranking (report Section 3.5.3).

**Hard rules** (a hub must pass all five): accepts the donation's category; weight <= capacity - stored - reserved; the donation window overlaps the hub opening hours by at least 30 min; hub active; a directed road route from the donor exists.

## Results

| Result | Value | Meaning |
| --- | --- | --- |
| Scenarios | 2,019 | Small donations (< 10 kg), each with every hub within 20 km as a candidate |
| Hub recommended | 2,000 | At least one hub passed all five hard rules |
| No feasible hub | 19 | No hub passed the hard rules, so the method correctly recommends nothing |
| Feasible hubs per donation | median 26 hubs (10th-90th percentile 10-54; max 62) | How many hubs the method could choose from |
| Road distance from donor to the recommended hub | median 3.4 km (10th-90th percentile 1.1-6.8; max 11.7) | Candidates are within 20 km in a straight line; the road distance can be longer |

## How the method works

1. Take every hub within 20 km (straight line) of the donor as a candidate.
2. Remove each candidate that fails a hard rule (category, free capacity, opening hours, active, road route).
3. Sort the rest by road distance from the donor, shortest first (ties: hub ID).
4. Rank 1 is the recommendation. If no hub is left, the answer is NO_FEASIBLE_HUB.

## What to expect

- Assigning each demand point to its closest open facility ("closest assignment") is the standard default rule in facility-location models [1]. It gives every donor the shortest possible trip.
- It looks only at distance, so it does not avoid hubs that are nearly full or busy; that is what the weighted reference policy adds.
- So by construction the recommended hub is always the shortest road distance among the feasible hubs.

## How to read the results

- **Hub recommended / No feasible hub** add up to all scenarios. NO_FEASIBLE_HUB is the correct answer when no hub passes the hard rules, not an error.
- **Road distance** is the donor's trip to the recommended hub. Lower is better for the donor.
- In `details/hub_ranking.csv`, `rank` 1 is the recommendation and `distance_km` never decreases down the ranks.
- E1 uses this ranking for Top-1 agreement with the reference policy (the main hub metric), Top-3 coverage and NDCG@3 [2], always within each donation's own candidate group [3].

How to read a spread such as "median 3.8 km (10th-90th percentile 1.5-7.7; max 22.9)": half of the donations are at or below the median; 8 in 10 lie between the two percentiles; max is the single largest value.

## References

- [1] Church, R. L., & Gerrard, R. A. (1996). Closest assignment constraints and location models: Properties and structure. *Location Science*, 4(4), 251-270. *(not yet in the report: add it if you cite it)*
- [2] Järvelin, K., & Kekäläinen, J. (2002). Cumulated gain-based evaluation of IR techniques. *ACM Transactions on Information Systems*, 20(4), 422-446. https://doi.org/10.1145/582415.582418 *(not yet in the report: add it if you cite it)*
- [3] Cao, Z., Qin, T., Liu, T.-Y., Tsai, M.-F., & Li, H. (2007). Learning to rank: From pairwise approach to listwise approach. *Proceedings of the 24th International Conference on Machine Learning*, 129-136. https://doi.org/10.1145/1273496.1273513 *(in the report reference list)*

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
| `status` | RECOMMENDED, or NO_FEASIBLE_HUB when no hub passes the five hard rules |
| `feasible_hubs` | How many hubs passed the hard rules (the method's choices) |
| `recommended_hub` | The method's first choice (empty when NO_FEASIBLE_HUB) |
| `distance_to_recommended_hub_km` | Road distance from the donor to that hub |
| `second_hub`, `third_hub` | The method's 2nd and 3rd choices (empty if fewer hubs) |
