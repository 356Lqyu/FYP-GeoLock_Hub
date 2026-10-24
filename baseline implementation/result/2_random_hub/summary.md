# Random Hub (baseline 2)

Benchmark GEOLOCK-BM-v3.2. This describes this method on its own; comparing methods is done in experiment E1.

**Method.** Among the hubs that pass all four hard rules, recommend one at random. The random order is fixed by --seed and the scenario ID, so a rerun gives the same answer.

**Hard rules** (a hub must pass all four): accepts the donation's category; weight <= capacity - stored - reserved; hub active; a directed road route from the donor exists.

| Result | Value | Meaning |
| --- | --- | --- |
| Scenarios | 2,019 | Small donations (< 10 kg), each with every hub within 20 km as a candidate |
| Hub recommended | 2,000 | At least one hub passed all four hard rules |
| No feasible hub | 19 | No hub passed the hard rules, so the method correctly recommends nothing |
| Feasible hubs per donation | median 21 hubs (10th-90th percentile 9-45; max 51) | How many hubs the method could choose from |
| Road distance from donor to the recommended hub | median 14.7 km (10th-90th percentile 5.0-24.5; max 43.1) | Candidates are within 20 km in a straight line; the road distance can be longer |
| Random seed | 42 | Same seed, same recommendations |

## How the method works

1. Take the same feasible hubs as the other hub methods (all four hard rules pass).
2. Shuffle them in a random order fixed by the seed and the scenario ID (same seed = same answer).
3. The first hub after shuffling is the recommendation; the full shuffled order is the ranking.

## What to expect

- A random choice is the usual "chance level" lower bound: a method that has learned anything must do better than it.
- Chance level for this benchmark: with k feasible hubs, a random pick equals any particular hub (for example the reference policy's choice) with probability 1/k. Averaged over these scenarios that is 6.2%. Its distance should be close to the average distance of the feasible hubs (median over scenarios: 14.9 km).

## How to read the results

- **Hub recommended / No feasible hub**: same split as the other hub methods, because all use the same hard rules.
- **Road distance** should be near the average feasible-hub distance above; if it is, the method behaves as a fair random choice.
- `details/hub_ranking.csv` is the shuffled order. E1 scores it with Top-1, Top-3 and NDCG@3 [1], within each donation's candidate group [2]; random results should sit near chance level.

How to read a spread such as "median 3.8 km (10th-90th percentile 1.5-7.7; max 22.9)": half of the donations are at or below the median; 8 in 10 lie between the two percentiles; max is the single largest value.

## References

- [1] Järvelin, K., & Kekäläinen, J. (2002). Cumulated gain-based evaluation of IR techniques. *ACM Transactions on Information Systems*, 20(4), 422-446. https://doi.org/10.1145/582415.582418 *(not yet in the report: add it if you cite it)*
- [2] Cao, Z., Qin, T., Liu, T.-Y., Tsai, M.-F., & Li, H. (2007). Learning to rank: From pairwise approach to listwise approach. *Proceedings of the 24th International Conference on Machine Learning*, 129-136. https://doi.org/10.1145/1273496.1273513 *(in the report reference list)*

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
