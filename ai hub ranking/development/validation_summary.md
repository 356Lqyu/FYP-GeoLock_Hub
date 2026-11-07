# Model development – validation summary

Train part: 1347 donations; validation part: 304 donations (split `d639954a5414e4ae…`).
Each family tried 30 seeded random configurations, each scored by 5-fold GroupKFold
(by Geohash-5 group) inside the train part. The best configuration of each family was refit on the
whole train part and scored once on the validation part. The test part was not loaded.

| Method | Validation Top-1 | NDCG@3 | Top-3 coverage | Score MAE | CV Top-1 (train, 5-fold) |
| --- | --- | --- | --- | --- | --- |
| RandomForestRegressor | 80.59 % (245/304) | 0.9927 | 98.36 % | 0.02742 | 83.89 % ± 6.36 % |
| XGBRegressor **(chosen)** | 84.21 % (256/304) | 0.9931 | 99.34 % | 0.02590 | 85.90 % ± 5.66 % |
| Nearest-Hub (for context) | 44.74 % (136/304) | 0.9185 | 82.57 % | – | – |

Chosen family: **XGBRegressor** (validation Top-1, then NDCG@3, then lower MAE).
Configuration: `{"colsample_bytree": 0.8, "learning_rate": 0.02, "max_depth": 5, "min_child_weight": 3, "n_estimators": 800, "reg_lambda": 5.0, "subsample": 0.7}`.
Every configuration tried is in `search_results.csv`.

Top-1 agreement = share of donations where the model's first hub equals the reference policy's
first hub. NDCG@3 uses relevance 1 − (score − min)/(max − min) within each donation (report 3.7.2).
