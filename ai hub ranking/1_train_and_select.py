"""Step 1: train RandomForestRegressor and XGBRegressor and choose one (train + validation only).

Protocol (report Section 3.5.3 and Appendix training protocol, README "Step 1"):
- features in frozen order, no scaling; target = reference_score of each feasible pair
- per family: 30 seeded random configurations, each scored by 5-fold GroupKFold
  (groups = Geohash-5 cells) inside the train part
- best configuration per family = highest CV Top-1, then NDCG@3, then lower MAE
- each family's best configuration is refit on the whole train part and scored on the
  validation part; the family is chosen by validation Top-1, then NDCG@3, then lower MAE
- the test part is never loaded here

Writes model/ (frozen model, model_metadata.json, training_record.json, model_card.md)
and development/ (every configuration tried, validation_summary.md).
"""
import argparse
import csv
import json
import platform
import random
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import sklearn
import xgboost
from sklearn.ensemble import RandomForestRegressor
from sklearn.model_selection import GroupKFold
from xgboost import XGBRegressor

sys.path.insert(0, str(Path(__file__).resolve().parent))
import hub_ranking_core as core  # noqa: E402

N_CONFIGS = 30
N_FOLDS = 5


def sample_configs(family, rng):
    """30 seeded random configurations from a fixed search space."""
    configs = []
    for _ in range(N_CONFIGS):
        if family == 'RandomForestRegressor':
            configs.append(dict(
                n_estimators=rng.choice([100, 200, 300, 400]),
                max_depth=rng.choice([None, 8, 12, 16, 20, 24]),
                min_samples_leaf=rng.choice([1, 2, 4, 8]),
                max_features=rng.choice([1.0, 0.8, 0.6]),
                bootstrap=True))
        else:
            configs.append(dict(
                n_estimators=rng.choice([200, 400, 600, 800]),
                max_depth=rng.choice([3, 4, 5, 6, 8]),
                learning_rate=rng.choice([0.02, 0.05, 0.1, 0.2]),
                subsample=rng.choice([0.7, 0.85, 1.0]),
                colsample_bytree=rng.choice([0.8, 1.0]),
                min_child_weight=rng.choice([1, 3, 5, 10]),
                reg_lambda=rng.choice([0.1, 1.0, 5.0])))
    return configs


def build(family, params, jobs):
    if family == 'RandomForestRegressor':
        return RandomForestRegressor(random_state=core.SEED, n_jobs=jobs, **params)
    return XGBRegressor(random_state=core.SEED, n_jobs=jobs, tree_method='hist',
                        objective='reg:squarederror', **params)


def choice_key(m):
    """Higher Top-1, then higher NDCG@3, then lower MAE."""
    return (-m['top1_agreement'], -(m['ndcg_at_3'] or 0), m['score_mae'])


def cross_validate(family, params, groups, jobs):
    labels = [g['geographic_group_id'] for g in groups]
    folds = []
    for fit_idx, val_idx in GroupKFold(n_splits=N_FOLDS).split(groups, groups=labels):
        fit = [groups[i] for i in fit_idx]
        val = [groups[i] for i in val_idx]
        X, y, _ = core.matrix(fit)
        model = build(family, params, jobs).fit(np.asarray(X), np.asarray(y))
        Xv, _, _ = core.matrix(val)
        pred = model.predict(np.asarray(Xv)).tolist()
        folds.append(core.evaluate(val, core.orders_from_predictions(val, pred), pred))
    mean = lambda k: float(np.mean([f[k] for f in folds]))
    return dict(top1_agreement=mean('top1_agreement'), ndcg_at_3=mean('ndcg_at_3'),
                top3_coverage=mean('top3_coverage'), score_mae=mean('score_mae'),
                top1_fold_sd=float(np.std([f['top1_agreement'] for f in folds])))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--jobs', type=int, default=-1, help='CPU cores for model fitting')
    parser.add_argument('--families', default='RandomForestRegressor,XGBRegressor')
    args = parser.parse_args()
    started = time.time()
    train = core.load_groups('train')
    validation = core.load_groups('validation')
    dev_dir = core.ROOT / 'development'
    dev_dir.mkdir(exist_ok=True)
    core.MODEL_DIR.mkdir(exist_ok=True)

    # Each finished configuration is saved, so an interrupted search resumes where it stopped.
    progress_path = dev_dir / 'search_progress.jsonl'
    done = {}
    if progress_path.exists():
        for line in progress_path.read_text(encoding='utf-8').splitlines():
            if line.strip():
                item = json.loads(line)
                done[(item['family'], item['config_no'], item['params'])] = item
    trials, best = [], {}
    for family in args.families.split(','):
        rng = random.Random(f'{core.SEED}-{family}')
        for i, params in enumerate(sample_configs(family, rng), 1):
            key = (family, i, json.dumps(params, sort_keys=True))
            t = time.time()
            if key in done:
                cv, seconds = done[key]['cv'], done[key]['seconds']
            else:
                cv = cross_validate(family, params, train, args.jobs)
                seconds = round(time.time() - t, 1)
                with progress_path.open('a', encoding='utf-8') as stream:
                    stream.write(json.dumps(dict(family=family, config_no=i, params=key[2],
                                                 cv=cv, seconds=seconds)) + '\n')
            trial = dict(family=family, config_no=i, params=json.dumps(params, sort_keys=True),
                         **{f'cv_{k}': round(v, 6) for k, v in cv.items()},
                         seconds=seconds)
            trials.append(trial)
            print(f"{family} {i:2d}/{N_CONFIGS} CV Top-1 {cv['top1_agreement']:.4f} "
                  f"NDCG@3 {cv['ndcg_at_3']:.4f} MAE {cv['score_mae']:.5f}", flush=True)
            if family not in best or choice_key(cv) < choice_key(best[family]['cv']):
                best[family] = dict(params=params, cv=cv, config_no=i)

    # Refit each family's best configuration on the whole train part; score on validation.
    X, y, _ = core.matrix(train)
    Xv, _, _ = core.matrix(validation)
    fitted = {}
    for family, b in best.items():
        model = build(family, b['params'], args.jobs).fit(np.asarray(X), np.asarray(y))
        pred = model.predict(np.asarray(Xv)).tolist()
        b['validation'] = core.evaluate(validation, core.orders_from_predictions(validation, pred), pred)
        fitted[family] = model
    chosen = min(best, key=lambda f: choice_key(best[f]['validation']))
    nearest_val = core.evaluate(validation, [[r['hub_id'] for r in sorted(
        g['rows'], key=lambda r: (r['road_distance_km'], r['hub_id']))] for g in validation])

    # Save the chosen model in a portable format.
    if chosen == 'XGBRegressor':
        model_file = 'hub_ranker_xgb.json'
        fitted[chosen].save_model(str(core.MODEL_DIR / model_file))
    else:
        import joblib
        model_file = 'hub_ranker_rf.joblib'
        joblib.dump(fitted[chosen], core.MODEL_DIR / model_file, compress=3)
    for old in core.MODEL_DIR.glob('hub_ranker_*'):
        if old.name != model_file:
            old.unlink()
    trained_at = datetime.now(timezone.utc).isoformat(timespec='seconds')
    version = f"hubrank-{chosen[:2].lower()}-{trained_at[:10]}-{core.sha256(core.MODEL_DIR / model_file)[:8]}"
    environment = dict(python=platform.python_version(), platform=platform.platform(),
                       numpy=np.__version__, scikit_learn=sklearn.__version__,
                       xgboost=xgboost.__version__)
    metadata = dict(
        model_version=version, family=chosen, model_file=model_file,
        model_sha256=core.sha256(core.MODEL_DIR / model_file),
        features=list(core.FEATURES), target=core.TARGET, score_direction='lower_is_better',
        tie_rule='ascending predicted score (9 dp), then lower road_distance_km, then hub_id',
        top_k=core.TOP_K, handling_penalty=core.HANDLING_PENALTY,
        reference_weights=core.REFERENCE_WEIGHTS, seed=core.SEED,
        benchmark_version=json.loads((core.DATASET_DIR / 'generation_manifest.json')
                                     .read_text(encoding='utf-8'))['benchmark_version'],
        split=core.split_info(), trained_at_utc=trained_at, environment=environment,
        params=best[chosen]['params'])
    (core.MODEL_DIR / 'model_metadata.json').write_text(json.dumps(metadata, indent=2) + '\n', encoding='utf-8')
    record = dict(
        metadata=metadata,
        protocol=dict(configs_per_family=N_CONFIGS, cv=f'{N_FOLDS}-fold GroupKFold by geographic_group_id inside train',
                      config_choice='CV Top-1, then NDCG@3, then lower MAE',
                      family_choice='validation Top-1, then NDCG@3, then lower MAE',
                      refit='best configuration refit on the whole train part (validation not used for fitting)',
                      test_part_loaded=False),
        data=dict(train_groups=len(train), train_rows=len(y),
                  validation_groups=len(validation), validation_rows=len(Xv)),
        best_per_family={f: dict(config_no=b['config_no'], params=b['params'], cv=b['cv'],
                                 validation=b['validation']) for f, b in best.items()},
        chosen_family=chosen, nearest_hub_on_validation=nearest_val,
        input_sha256={n: core.sha256(core.DATASET_DIR / n) for n in
                      ('donation_hub_candidates.csv', 'scenario_members.csv', 'generation_manifest.json')},
        runtime_seconds=round(time.time() - started, 1))
    (core.MODEL_DIR / 'training_record.json').write_text(json.dumps(record, indent=2) + '\n', encoding='utf-8')

    with (dev_dir / 'search_results.csv').open('w', newline='', encoding='utf-8') as stream:
        writer = csv.DictWriter(stream, fieldnames=list(trials[0]))
        writer.writeheader()
        writer.writerows(trials)
    write_reports(dev_dir, metadata, best, chosen, nearest_val, len(train), len(validation))
    print(json.dumps(dict(chosen=chosen, model_version=version,
                          validation=best[chosen]['validation']), indent=2))


def pct(x):
    return f'{100 * x:.2f} %'


def write_reports(dev_dir, meta, best, chosen, nearest_val, n_train, n_val):
    rows = ['| Method | Validation Top-1 | NDCG@3 | Top-3 coverage | Score MAE | CV Top-1 (train, 5-fold) |',
            '| --- | --- | --- | --- | --- | --- |']
    for f, b in best.items():
        v = b['validation']
        rows.append(f"| {f}{' **(chosen)**' if f == chosen else ''} | {pct(v['top1_agreement'])} "
                    f"({v['top1_count']}/{v['groups']}) | {v['ndcg_at_3']:.4f} | {pct(v['top3_coverage'])} "
                    f"| {v['score_mae']:.5f} | {pct(b['cv']['top1_agreement'])} ± {pct(b['cv']['top1_fold_sd'])} |")
    rows.append(f"| Nearest-Hub (for context) | {pct(nearest_val['top1_agreement'])} "
                f"({nearest_val['top1_count']}/{nearest_val['groups']}) | {nearest_val['ndcg_at_3']:.4f} "
                f"| {pct(nearest_val['top3_coverage'])} | – | – |")
    table = '\n'.join(rows)
    (dev_dir / 'validation_summary.md').write_text(f"""# Model development – validation summary

Train part: {n_train} donations; validation part: {n_val} donations (split `{meta['split']['split_id'][:16]}…`).
Each family tried {N_CONFIGS} seeded random configurations, each scored by {N_FOLDS}-fold GroupKFold
(by Geohash-5 group) inside the train part. The best configuration of each family was refit on the
whole train part and scored once on the validation part. The test part was not loaded.

{table}

Chosen family: **{chosen}** (validation Top-1, then NDCG@3, then lower MAE).
Configuration: `{json.dumps(best[chosen]['params'], sort_keys=True)}`.
Every configuration tried is in `search_results.csv`.

Top-1 agreement = share of donations where the model's first hub equals the reference policy's
first hub. NDCG@3 uses relevance 1 − (score − min)/(max − min) within each donation (report 3.7.2).
""", encoding='utf-8')
    v = best[chosen]['validation']
    (core.MODEL_DIR / 'model_card.md').write_text(f"""# Model card – {meta['model_version']}

| Item | Value |
| --- | --- |
| Task | Rank the community hubs that already passed the five hard rules for one small donation |
| Family | {chosen} |
| Features (in order, unscaled) | {', '.join(meta['features'])} |
| Target | reference_score (lower = better) of each feasible donation–hub pair |
| Ranking | ascending predicted score; ties: lower road distance, then hub ID; Top-{core.TOP_K} |
| Training data | GEOLOCK benchmark {meta['benchmark_version']}, train part only ({n_train} donations) |
| Validation Top-1 / NDCG@3 / Top-3 | {pct(v['top1_agreement'])} / {v['ndcg_at_3']:.4f} / {pct(v['top3_coverage'])} |
| Seed | {core.SEED} |
| Environment | Python {meta['environment']['python']}, scikit-learn {meta['environment']['scikit_learn']}, xgboost {meta['environment']['xgboost']}, numpy {meta['environment']['numpy']} |
| File | `{meta['model_file']}` (sha256 `{meta['model_sha256'][:16]}…`) |

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
""", encoding='utf-8')


if __name__ == '__main__':
    main()
