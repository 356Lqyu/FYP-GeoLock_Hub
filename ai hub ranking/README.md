# AI hub ranking

The AI model that ranks community hubs for a small donation (< 10 kg). It only ranks hubs that
have already passed the five hard rules (category accepted, enough free capacity, opening hours
overlap the drop-off window, hub active, road route exists), so it can never pick an infeasible
hub. It learns the weighted reference hub policy: for every feasible hub it predicts the
reference score (lower = better), and the hubs are ranked by that prediction.

```
All hubs -> hard rules (database) -> feasible hubs -> AI ranking -> top 3 -> recommended hub
                                   (none left -> NO_FEASIBLE_HUB, the model is not asked)
```

The FastAPI service in `api/` serves the frozen model to the Flutter app.

## Folder

```
ai hub ranking/
├── data split/               frozen train / validation / test split
├── hub_ranking_core.py       shared contract: feature order, tie rule, reference score, metrics, model loading
├── requirements.txt          numpy, scikit-learn, joblib, xgboost (pinned: the saved model needs these versions)
├── 1_train_and_select.py     step 1: train and choose the model (train + validation only)
├── 2_evaluate_on_test.py     step 2: score the frozen model on the test part, once (experiment E1)
├── model/                    written by step 1: frozen model, model_metadata.json, training_record.json, model_card.md
├── development/              written by step 1: every configuration tried, validation_summary.md
├── test result/              written by step 2: results, comparison with the baselines, summary.md
└── api/                      FastAPI service for the Flutter app (see api/README.md)
    ├── main.py
    ├── requirements.txt
    ├── .env.example          copy to .env (Supabase URL + publishable key)
    └── README.md
```

## Setup (Windows, once)

Python 3.10–3.13. From the repository root `D:\fyp\FYP-GeoLock_Hub`:

```powershell
py -m venv .venv
.venv\Scripts\activate
pip install -r "ai hub ranking/api/requirements.txt"
```

`api/requirements.txt` includes `requirements.txt`, so this one command installs everything
for training, testing and the API:

| Package | Version | Used for |
| --- | --- | --- |
| numpy | 2.1.3 | arrays |
| scikit-learn | 1.5.2 | RandomForestRegressor, GroupKFold |
| joblib | 1.4.2 | saving / loading the Random Forest |
| xgboost | 2.1.4 | XGBRegressor |
| fastapi | 0.115.6 | the API |
| uvicorn[standard] | 0.32.1 | the server that runs the API |
| httpx | 0.28.1 | the API calling Supabase |
| pydantic | 2.10.4 | request validation |

Keep these exact versions: a model saved with one scikit-learn version may not load in another.

## How to run (from the repository root, with .venv active)

```powershell
python "ai hub ranking/data split/freeze_split.py"     # optional: checks the split is unchanged
python "ai hub ranking/1_train_and_select.py" 
python "ai hub ranking/2_evaluate_on_test.py"
```

Step 2 compares the model with the Nearest-Hub and Random Hub baselines, so their results must
exist in `baseline implementation/result/` first.

Then start the API and the app:

```powershell
copy "ai hub ranking\api\.env.example" "ai hub ranking\api\.env"
cd "ai hub ranking\api"
uvicorn main:app --host 0.0.0.0 --port 8000
```

- Check http://localhost:8000/health. It should show `"ranking_mode": "MODEL"`.
- Test the API by hand at http://localhost:8000/docs.

```powershell
cd frontend\geolock_hub_app
flutter pub get
flutter run --dart-define=GEOLOCK_AI_URL=http://10.0.2.2:8000      # Android emulator
flutter run --dart-define=GEOLOCK_AI_URL=http://192.168.x.x:8000   # real phone: your PC's IP (ipconfig)
```

Without `GEOLOCK_AI_URL`, or when the API is not running, the app falls back to nearest-by-road
order, so nothing breaks.

## data split/

`freeze_split.py` divides the 2,000 hub-recommendation scenarios into three fixed parts
(target 70 / 15 / 15 % by whole Geohash-5 group, seed 20260915; report Section 3.4):

| Part | Geographic groups | Donations (scenarios) | Share | Feasible donation-hub rows | Used for |
| --- | --- | --- | --- | --- | --- |
| train | 75 | 1,347 | 67.3 % | 37,272 | Fitting the models (and the 5-fold GroupKFold search inside it) |
| validation | 13 | 304 | 15.2 % | 11,378 | Choosing between Random Forest and XGBoost |
| test | 18 | 349 | 17.4 % | 11,374 | One final score of the chosen model (E1); never used before |

(Benchmark GEOLOCK-BM-v3.3, split `3375392a244c0e17…`, 106 Geohash-5 groups.) Shares differ
from 70 / 15 / 15 because whole groups are kept together (report Section 3.4.2); these are
the realised counts to report in Chapter 5.

- Whole geographic groups stay in one part, so every test donation comes from a donor area
  the model has not seen. Hubs are shared infrastructure, so the same hubs can appear in
  several parts (all 150 test hubs also appear in training); the hold-out is by donor area,
  not by hub.
- The 19 `HUB_RECOMMENDATION_VERIFICATION` scenarios (no feasible hub) are not in the split:
  the model is never asked for them. E1 reports them separately as NO_FEASIBLE_HUB.
- Training rows are selected by `train_scenario_ids.csv`, not by "everything except test".
  `donation_hub_candidates.csv` also holds 628 community-hub donations that belong to no
  recommendation scenario; 108 of them lie in test groups and are never used.
- The seed is fixed, so the split is the same on every run, and the script refuses to
  overwrite a split with a different one.

## Step 1 – training protocol (`1_train_and_select.py`)

| Item | Setting |
| --- | --- |
| Rows | Each scenario's CANDIDATE_HUB members with `feasible_flag = 1` |
| Features, in order | `road_distance_km`, `utilisation_ratio`, `capacity_pressure`, `donation_weight_kg`, `handling_penalty` (no scaling) |
| Target | `reference_score` of each feasible donation–hub pair |
| Model families | RandomForestRegressor, XGBRegressor |
| Search | 30 seeded random configurations per family, each scored by 5-fold GroupKFold (by geographic group) inside the train part |
| Best configuration per family | CV Top-1 agreement, then NDCG@3, then lower score MAE |
| Choice of family | Best configuration refit on the whole train part; validation Top-1, then NDCG@3, then lower MAE |
| Ranking | Ascending predicted score (rounded to 9 dp); ties by lower road distance, then hub_id; Top-k = 3 |
| Seed | 20260915 |

The test part is not loaded in step 1. Search spaces:

- **Random Forest:** n_estimators {100, 200, 300}, max_depth {None, 8, 12, 16, 20, 24}, min_samples_leaf {1, 2, 4, 8}, max_features {1.0, 0.8, 0.6}, max_samples {0.5, 0.7, all}
- **XGBoost:** n_estimators {200, 400, 600, 800}, max_depth {3, 4, 5, 6, 8}, learning_rate {0.02, 0.05, 0.1, 0.2}, subsample {0.7, 0.85, 1.0}, colsample_bytree {0.8, 1.0}, min_child_weight {1, 3, 5, 10}, reg_lambda {0.1, 1, 5}

Outputs:

- `model/model_metadata.json` – the model's identity: version, family, file hash, feature order, tie rule, library versions, split ID
- `model/training_record.json` – the full development record
- `model/model_card.md` – a one-page summary for the report
- `development/search_results.csv` – every configuration tried
- `development/validation_summary.md` – the validation comparison

## Step 2 – E1 on the test part (`2_evaluate_on_test.py`)

Metrics (report Section 3.7.2):

- **Top-1 agreement** (primary): the model's first hub is the same as the reference policy's first hub.
- **NDCG@3**: relevance is 1 − (score − min)/(max − min) within each donation, with gain 2^rel − 1. All-equal groups are excluded.
- **Top-3 coverage**: the reference policy's first hub appears in the model's top 3.
- **Statistics:** 95 % percentile-bootstrap intervals (10,000 resamples) and an exact McNemar test of the model against Nearest-Hub and against Random Hub.

Each test donation gets one complete record in `test result/details/recommendation_records.jsonl`:
feasible candidates and their features, model version, every candidate's score, the full ranking,
the top 3, the selected hub, a plain explanation, the hard rules passed, the ranking mode, the score
margin between the 1st and 2nd hub (confidence) and a timestamp.

If the model cannot be loaded, the reference score is used instead (`REFERENCE_FALLBACK`). Such
results are labelled as fallback and are not counted as model results. The script refuses to run
a second time over an existing `test result/metrics.json`, because E1 is scored once.

## The API (`api/`) and authority

- The API reads the feasible hubs from the database (`get_hub_options`) as the signed-in donor, so it can only reorder hubs the database already allows.
- It uses only the public publishable key. It cannot reserve, claim or change anything.
- Booking calls `reserve_hub_capacity`, which re-checks capacity, category, hours and route (Authority Contract INV-07: AI recommendations never grant or override authority).
- If the model is missing or fails, the API ranks by the reference rule (`REFERENCE_FALLBACK`).
- If the API is unreachable, the app uses the database order (nearest by road).

See `api/README.md` for the endpoints and the feature mapping.

## Known limitation

The reference score min-max normalises road distance within each donation's feasible hubs, but
the frozen feature set gives the model the raw distance only. The model cannot see that
group context, so some first-place disagreements are expected where two hubs have very close
scores. Report this together with the E1 Top-1 result.
