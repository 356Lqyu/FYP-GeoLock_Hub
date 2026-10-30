# E1 – AI hub ranking on the held-out test part

Model `hubrank-xg-2026-10-30-dc363fd2` (XGBRegressor), scored once on 349
held-out test donations from Geohash-5 areas never seen in training. Every method ranks exactly
the same feasible hubs (five hard rules) and is compared with the weighted reference policy.

| Method | Top-1 agreement (95 % CI) | NDCG@3 (95 % CI) | Top-3 coverage |
| --- | --- | --- | --- |
| AI model | 85.67 % (299/349; 81.95 %–89.11 %) | 0.9964 (0.9955–0.9971) | 98.85 % (345/349) |
| Nearest-Hub | 42.12 % (147/349; 36.96 %–47.28 %) | 0.9335 (0.9280–0.9390) | 83.95 % (293/349) |
| Random Hub | 5.44 % (19/349; 3.15 %–8.02 %) | 0.5202 (0.5015–0.5384) | 12.03 % (42/349) |

| Comparison | Only model correct | Only baseline correct | Exact McNemar p |
| --- | --- | --- | --- |
| AI model vs Nearest-Hub | 165 | 13 | 1.04e-34 |
| AI model vs Random Hub | 283 | 3 | 6.27e-80 |

The model's first hub differs from the reference policy's first hub in 50 of 349
donations (14.33 %). 95 % intervals: percentile bootstrap over donations
(10,000 resamples, seed 20260915). NDCG@3 excludes all-equal (degenerate) groups
(0 here).

The 19 scenarios with no feasible hub are not scored: the model is never asked and the correct
answer, NO_FEASIBLE_HUB, comes from the hard rules.

## How to read it
- **Top-1 agreement** (primary): the model recommends the same hub as the reference policy.
- **Top-3 coverage**: the reference policy's first hub is somewhere in the model's top 3.
- **NDCG@3**: quality of the whole top 3, using relevance 1 − (score − min)/(max − min) per donation.
- High agreement means the model reproduces the fixed weighted rule; it is not evidence that
  the rule is better for donors or NGOs (report Section 3.5.3).

## Files
- `results_per_scenario.csv` – one row per test donation (model, reference and nearest first hub).
- `details/recommendation_records.jsonl` – full auditable record per donation: candidates and
  features, every score, the ranking, Top-3, selected hub, explanation, hard rules, ranking mode,
  model version, confidence margin and timestamp.
- `metrics.json` – all numbers above.
