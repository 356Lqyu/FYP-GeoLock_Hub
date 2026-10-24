# AI hub ranking

Code and data preparation for the AI model that ranks feasible hubs (Random Forest /
XGBoost learning the reference hub policy). The model training code will be added here.

## data split/

`freeze_split.py` divides the 2,000 hub-recommendation scenarios of the benchmark into
three fixed parts:

| Part | Scenarios | Used for |
| --- | --- | --- |
| train | 1,368 | Training the model |
| validation | 295 | Tuning and choosing the model |
| test | 337 | Final scoring only; never used during training |

Whole geographic groups (Geohash-5 cells) stay in one part, so the test part contains only
areas the model has not seen. The seed is fixed, so the split is the same on every run.

```powershell
python "ai hub ranking/data split/freeze_split.py"
```

Output in `data split/split/`: `train_scenario_ids.csv`, `validation_scenario_ids.csv`,
`test_scenario_ids.csv` (columns `scenario_id, donation_id, geographic_group_id`) and
`split_manifest.json` (seed, counts, input fingerprints and a `split_id`). The script refuses
to overwrite an existing split with a different one.

The hub baselines (`baseline implementation/result/1_nearest_hub`, `2_random_hub`,
`ref_weighted_hub`) cover all scenarios; when the model is evaluated, every method is scored
on the same `test_scenario_ids.csv`.
