# Model development – validation summary

Train part: 1347 donations; validation part: 304 donations (split `3375392a244c0e17…`).
Each family tried 30 seeded random configurations, each scored by 5-fold GroupKFold
(by Geohash-5 group) inside the train part. The best configuration of each family was refit on the
whole train part and scored once on the validation part. The test part was not loaded.

| Method | Validation Top-1 | NDCG@3 | Top-3 coverage | Score MAE | CV Top-1 (train, 5-fold) |
| --- | --- | --- | --- | --- | --- |
| RandomForestRegressor | 81.91 % (249/304) | 0.9933 | 98.36 % | 0.02770 | 82.93 % ± 5.04 % |
| XGBRegressor **(chosen)** | 83.88 % (255/304) | 0.9928 | 98.03 % | 0.02580 | 86.27 % ± 4.04 % |
| Nearest-Hub (for context) | 46.38 % (141/304) | 0.9199 | 81.25 % | – | – |

Chosen family: **XGBRegressor** (validation Top-1, then NDCG@3, then lower MAE).
Configuration: `{"colsample_bytree": 0.8, "learning_rate": 0.1, "max_depth": 5, "min_child_weight": 5, "n_estimators": 200, "reg_lambda": 1.0, "subsample": 0.85}`.
Every configuration tried is in `search_results.csv`.

Top-1 agreement = share of donations where the model's first hub equals the reference policy's
first hub. NDCG@3 uses relevance 1 − (score − min)/(max − min) within each donation (report 3.7.2).
