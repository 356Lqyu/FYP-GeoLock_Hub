# E1 – AI hub ranking on the held-out test part
Model `hubrank-xg-2026-11-01-894d3223` (XGBRegressor), scored once on 349
held-out test donations from Geohash-5 areas never seen in training
(planned: about 300, report Table 3.9; realised: 349). Every method ranks exactly
the same feasible hubs (five hard rules) and is compared with the weighted reference policy.

| Method | Top-1 agreement (95 % CI) | NDCG@3 (95 % CI) | Top-3 coverage (95 % CI) |
| --- | --- | --- | --- |
| AI model | 82.23 % (287/349; 77.88 %–85.89 %) | 0.9958 (0.9948–0.9967) | 99.14 % (346/349; 97.50 %–99.71 %) |
| Nearest-Hub | 41.83 % (146/349; 36.77 %–47.07 %) | 0.9311 (0.9251–0.9368) | 82.23 % (287/349; 77.88 %–85.89 %) |
| Random Hub | 4.58 % (16/349; 2.84 %–7.32 %) | 0.5201 (0.5015–0.5385) | 10.03 % (35/349; 7.30 %–13.63 %) |

Top-1 agreement (paired, exact McNemar):

| Comparison | Only model correct | Only baseline correct | Exact McNemar p | Holm-adjusted p |
| --- | --- | --- | --- | --- |
| AI model vs Nearest-Hub | 164 | 23 | 2e-27 | primary (not adjusted) |
| AI model vs Random Hub | 276 | 5 | 7.38e-75 | 2.22e-74 |

NDCG@3 (paired per donation, model minus baseline; Wilcoxon signed-rank):

| Comparison | NDCG@3 difference, Hodges-Lehmann (95 % CI) | Wilcoxon p | Holm-adjusted p |
| --- | --- | --- | --- |
| AI model vs Nearest-Hub | +0.0601 (+0.0533 to +0.0670) | 2.96e-55 | 2.96e-55 |
| AI model vs Random Hub | +0.4766 (+0.4566 to +0.4969) | 5.91e-59 | 1.18e-58 |

Primary test: Top-1 against Nearest-Hub (alpha = 0.05). The other three tests are secondary and
Holm-adjusted together (report Table A.4).

The model's first hub differs from the reference policy's first hub in 62 of 349
donations (17.77 %). 95 % intervals: Wilson for Top-1 and Top-3 coverage; percentile bootstrap
over donations for NDCG@3 (10,000 resamples, seed 20260915). NDCG@3 excludes all-equal (degenerate) groups
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
