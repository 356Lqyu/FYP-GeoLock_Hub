# Model card – hubrank-xg-2026-10-30-dc363fd2

| Item | Value |
| --- | --- |
| Task | Rank the community hubs that already passed the five hard rules for one small donation |
| Family | XGBRegressor |
| Features (in order, unscaled) | road_distance_km, utilisation_ratio, capacity_pressure, donation_weight_kg, handling_penalty |
| Target | reference_score (lower = better) of each feasible donation–hub pair |
| Ranking | ascending predicted score; ties: lower road distance, then hub ID; Top-3 |
| Training data | GEOLOCK benchmark GEOLOCK-BM-v3.3, train part only (1347 donations) |
| Validation Top-1 / NDCG@3 / Top-3 | 83.88 % / 0.9928 / 98.03 % |
| Seed | 20260915 |
| Environment | Python 3.12.10, scikit-learn 1.5.2, xgboost 2.1.4, numpy 2.1.3 |
| File | `hub_ranker_xgb.json` (sha256 `dc363fd24a5aab45…`) |

## Intended use
Advisory ordering of feasible hubs in the donor's "Choose a drop-off hub" screen, served by the
FastAPI service in `api/`. It never adds, removes or makes a hub feasible; `reserve_hub_capacity`
re-checks every rule in the database.

## Limitations
- It is a surrogate of a fixed weighted rule (policy emulation), not a model of real donor or
  NGO preference; a high agreement only means the rule is reproduced.
- The reference score normalises road distance within each donation's feasible hubs, but the
  frozen feature set gives the model the raw distance only, so it cannot see that group context.
- Trained on synthetic operating states (load, reservations, hours) at real OSM hub locations.
- If the model cannot be loaded, the service uses the reference score itself
  (`REFERENCE_FALLBACK`); those recommendations are not model results.
