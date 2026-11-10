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
import hashlib
import json
import math
import platform
import random
import time
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import sklearn
import xgboost
from sklearn.ensemble import RandomForestRegressor
from sklearn.model_selection import GroupKFold
from xgboost import XGBRegressor

# ============================================================================ shared rules
# Feature order, data loading, reference score, tie rule,
# metrics and model loading. 2_evaluate_on_test.py reuses these from this file.

ROOT = Path(__file__).resolve().parent            # .../ai hub ranking
REPO = ROOT.parent                                # repository root
DATASET_DIR = REPO / 'benchmark dataset' / 'dataset'
SPLIT_DIR = ROOT / 'data split' / 'split'
MODEL_DIR = ROOT / 'model'

SEED = 20260915
TOP_K = 3
# Frozen feature order (report Table A / training protocol). Tree models: no scaling.
FEATURES = ('road_distance_km', 'utilisation_ratio', 'capacity_pressure',
            'donation_weight_kg', 'handling_penalty')
TARGET = 'reference_score'
# Reference policy (generation manifest): lower is better.
REFERENCE_WEIGHTS = dict(distance=.45, utilisation=.20, capacity_pressure=.25, handling=.10)
# Base handling value of each benchmark category (its hardest storage need; generation manifest).
HANDLING_PENALTY = {'clothing': .10, 'books': .10, 'electronics': .40,
                    'food': .60, 'appliances': .80, 'furniture': .80}
HARD_RULES = ('item_compatible_flag', 'capacity_feasible_flag', 'operating_feasible_flag',
              'active_feasible_flag', 'route_available_flag')


# ----------------------------------------------------------------------------- data

def read_csv(path):
    with Path(path).open(encoding='utf-8-sig', newline='') as stream:
        return list(csv.DictReader(stream))


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def sha256_text(text):
    return hashlib.sha256(text.encode('utf-8')).hexdigest()


def split_info():
    manifest = json.loads((SPLIT_DIR / 'split_manifest.json').read_text(encoding='utf-8'))
    return dict(split_id=manifest['split_id'], seed=manifest['seed'],
                realized_scenario_counts=manifest['realized_scenario_counts'])


def scenario_ids(part):
    """Scenario IDs of one frozen part ('train', 'validation' or 'test')."""
    return [r['scenario_id'] for r in read_csv(SPLIT_DIR / f'{part}_scenario_ids.csv')]


def load_groups(part):
    """One group per recommendation scenario of `part`: its feasible candidate rows.

    Rows are the scenario's CANDIDATE_HUB members that pass all five hard rules
    (feasible_flag = 1). Only the scenario IDs of the requested part are read, so the
    test part is never touched when part != 'test'.

    The target is the benchmark's reference_score (report Eq. 3.1). It is recomputed from the
    features once as a check that the benchmark follows the report's formula.
    """
    wanted = set(scenario_ids(part))
    manifest = json.loads((DATASET_DIR / 'generation_manifest.json').read_text(encoding='utf-8'))
    for name in ('donation_hub_candidates', 'scenario_members', 'scenarios', 'donations'):
        expected = manifest['generated_csv_sha256'][name]
        if sha256(DATASET_DIR / f'{name}.csv') != expected:
            raise ValueError(f'{name}.csv differs from the generation manifest hash')
    sources, shortlist = {}, defaultdict(list)
    for r in read_csv(DATASET_DIR / 'scenario_members.csv'):
        if r['scenario_id'] not in wanted:
            continue
        if r['scenario_role'] == 'SOURCE_DONATION':
            if r['scenario_id'] in sources:
                raise ValueError(f"Two source donations in {r['scenario_id']}")
            sources[r['scenario_id']] = r['entity_id']
        elif r['scenario_role'] == 'CANDIDATE_HUB':
            shortlist[r['scenario_id']].append(r['entity_id'])
    needed = set(sources.values())
    candidates = {}
    for r in read_csv(DATASET_DIR / 'donation_hub_candidates.csv'):
        if r['donation_id'] in needed:
            candidates[(r['donation_id'], r['hub_id'])] = r
    groups = []
    for sid in sorted(wanted):
        did = sources[sid]
        rows = []
        for hid in shortlist[sid]:
            c = candidates[(did, hid)]
            if c['feasible_flag'] != '1':
                continue
            if not all(c[f] == '1' for f in HARD_RULES):
                raise ValueError(f'feasible_flag disagrees with the hard rules: {sid}/{hid}')
            row = dict(hub_id=hid, **{f: float(c[f]) for f in FEATURES})
            row[TARGET] = float(c[TARGET])
            rows.append(row)
        if not rows:
            raise ValueError(f'{sid} has no feasible hub but is in the {part} split')
        for r, s in zip(rows, reference_scores(rows)):
            if abs(s - r[TARGET]) > 1e-6:
                raise ValueError(f"reference_score does not match the report formula: {sid}/{r['hub_id']}")
        groups.append(dict(scenario_id=sid, donation_id=did,
                           geographic_group_id=c['geographic_group_id'], rows=rows))
    if len(groups) != len(wanted):
        raise ValueError('Scenario count mismatch')
    return groups


def matrix(groups):
    """Feature matrix, targets and geographic-group labels, in group/row order."""
    X = [[r[f] for f in FEATURES] for g in groups for r in g['rows']]
    y = [r[TARGET] for g in groups for r in g['rows']]
    labels = [g['geographic_group_id'] for g in groups for r in g['rows']]
    return X, y, labels


# ----------------------------------------------------------------------------- ranking

def reference_scores(rows):
    """The deterministic reference policy, recomputed from features (fallback scorer).

    Distance is min-max normalised within the donation's feasible hubs; a single hub or
    all-equal distances give 0.
    """
    distances = [r['road_distance_km'] for r in rows]
    lo, hi = min(distances), max(distances)
    w = REFERENCE_WEIGHTS
    out = []
    for r in rows:
        norm = 0.0 if hi == lo else (r['road_distance_km'] - lo) / (hi - lo)
        out.append(w['distance'] * norm + w['utilisation'] * r['utilisation_ratio']
                   + w['capacity_pressure'] * r['capacity_pressure']
                   + w['handling'] * r['handling_penalty'])
    return out


def rank(rows, scores):
    """Frozen tie rule: ascending score, then lower road distance, then hub_id.

    Scores are rounded to 9 decimals first so the order is identical across
    platforms and library builds.
    """
    paired = [dict(r, score=round(float(s), 9)) for r, s in zip(rows, scores)]
    return sorted(paired, key=lambda r: (r['score'], r['road_distance_km'], r['hub_id']))


def reference_order(rows):
    return [r['hub_id'] for r in sorted(
        rows, key=lambda r: (round(r[TARGET], 9), r['road_distance_km'], r['hub_id']))]


# ----------------------------------------------------------------------------- metrics

def relevance(rows):
    """Report Section 3.7.2: 1 - (score - min) / (max - min) within the group."""
    scores = [r[TARGET] for r in rows]
    lo, hi = min(scores), max(scores)
    if hi == lo:
        return None                       # degenerate: no ordering information
    return {r['hub_id']: 1 - (r[TARGET] - lo) / (hi - lo) for r in rows}


def ndcg_at_k(rows, predicted_order, k=TOP_K):
    rel = relevance(rows)
    if rel is None:
        return None
    gain = lambda h: 2 ** rel[h] - 1
    dcg = sum(gain(h) / math.log2(i + 2) for i, h in enumerate(predicted_order[:k]))
    ideal = sorted(rel, key=lambda h: -rel[h])
    idcg = sum(gain(h) / math.log2(i + 2) for i, h in enumerate(ideal[:k]))
    return dcg / idcg if idcg > 0 else None


def evaluate(groups, predicted_orders, predictions=None):
    """Top-1 agreement, NDCG@3 (non-degenerate groups only), Top-3 coverage, MAE."""
    top1 = cover = 0
    ndcgs, errors = [], []
    for i, g in enumerate(groups):
        order = predicted_orders[i]
        ref = reference_order(g['rows'])
        top1 += order[0] == ref[0]
        cover += ref[0] in order[:TOP_K]
        n = ndcg_at_k(g['rows'], order)
        if n is not None:
            ndcgs.append(n)
    if predictions is not None:
        targets = [r[TARGET] for g in groups for r in g['rows']]
        errors = [abs(p - t) for p, t in zip(predictions, targets)]
    n = len(groups)
    return dict(groups=n, top1_agreement=top1 / n, top1_count=top1,
                ndcg_at_3=sum(ndcgs) / len(ndcgs) if ndcgs else None,
                ndcg_groups=len(ndcgs), degenerate_groups=n - len(ndcgs),
                top3_coverage=cover / n, top3_count=cover,
                score_mae=sum(errors) / len(errors) if errors else None)


def orders_from_predictions(groups, predictions):
    orders, i = [], 0
    for g in groups:
        k = len(g['rows'])
        orders.append([r['hub_id'] for r in rank(g['rows'], predictions[i:i + k])])
        i += k
    return orders


# ----------------------------------------------------------------------------- model files

def load_model(model_dir=MODEL_DIR):
    """Load the frozen model and its metadata. Raises if anything does not match."""
    model_dir = Path(model_dir)
    meta = json.loads((model_dir / 'model_metadata.json').read_text(encoding='utf-8'))
    path = model_dir / meta['model_file']
    if sha256(path) != meta['model_sha256']:
        raise ValueError('Model file hash differs from model_metadata.json')
    if tuple(meta['features']) != FEATURES:
        raise ValueError('Model feature order differs from the frozen contract')
    if meta['family'] == 'XGBRegressor':
        from xgboost import XGBRegressor
        model = XGBRegressor()
        model.load_model(str(path))
    else:
        import joblib
        model = joblib.load(path)
    return model, meta


# ============================================================================ training

N_CONFIGS = 30
N_FOLDS = 5

# Search space (report 3.5.2: kept in the training record).
SEARCH_SPACE = {
    'RandomForestRegressor': dict(n_estimators=[100, 200, 300, 400], max_depth=[None, 8, 12, 16, 20, 24],
                                  min_samples_leaf=[1, 2, 4, 8], max_features=[1.0, 0.8, 0.6]),
    'XGBRegressor': dict(n_estimators=[200, 400, 600, 800], max_depth=[3, 4, 5, 6, 8],
                         learning_rate=[0.02, 0.05, 0.1, 0.2], subsample=[0.7, 0.85, 1.0],
                         colsample_bytree=[0.8, 1.0], min_child_weight=[1, 3, 5, 10],
                         reg_lambda=[0.1, 1.0, 5.0])}
# Pre-processing chain (report 3.5.2, Algorithm 3 line 19). Tree models need none.
PREPROCESSING = 'none: the five raw features in the frozen order, no scaling or encoding'
PREPROCESSING_VERSION = 'raw-features-v1'


def sample_configs(family, rng):
    """30 seeded random configurations from SEARCH_SPACE."""
    configs = []
    for _ in range(N_CONFIGS):
        params = {name: rng.choice(values) for name, values in SEARCH_SPACE[family].items()}
        if family == 'RandomForestRegressor':
            params['bootstrap'] = True
        configs.append(params)
    return configs


def build(family, params, jobs):
    if family == 'RandomForestRegressor':
        return RandomForestRegressor(random_state=SEED, n_jobs=jobs, **params)
    return XGBRegressor(random_state=SEED, n_jobs=jobs, tree_method='hist',
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
        X, y, _ = matrix(fit)
        model = build(family, params, jobs).fit(np.asarray(X), np.asarray(y))
        Xv, _, _ = matrix(val)
        pred = model.predict(np.asarray(Xv)).tolist()
        folds.append(evaluate(val, orders_from_predictions(val, pred), pred))
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
    train = load_groups('train')
    validation = load_groups('validation')
    dev_dir = ROOT / 'development'
    model_dir = MODEL_DIR
    dev_dir.mkdir(parents=True, exist_ok=True)
    model_dir.mkdir(parents=True, exist_ok=True)

    # Each finished configuration is saved, so an interrupted search resumes where it stopped.
    # Results from other training data (data_id) are ignored.
    data_id = sha256_text(json.dumps(matrix(train)[:2]))[:16]
    progress_path = dev_dir / 'search_progress.jsonl'
    done = {}
    if progress_path.exists():
        for line in progress_path.read_text(encoding='utf-8').splitlines():
            if line.strip():
                item = json.loads(line)
                if item.get('data_id') == data_id:
                    done[(item['family'], item['config_no'], item['params'])] = item
    trials, best = [], {}
    for family in args.families.split(','):
        rng = random.Random(f'{SEED}-{family}')
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
                                                 cv=cv, seconds=seconds, data_id=data_id)) + '\n')
            trial = dict(family=family, config_no=i, params=json.dumps(params, sort_keys=True),
                         **{f'cv_{k}': round(v, 6) for k, v in cv.items()},
                         seconds=seconds)
            trials.append(trial)
            print(f"{family} {i:2d}/{N_CONFIGS} CV Top-1 {cv['top1_agreement']:.4f} "
                  f"NDCG@3 {cv['ndcg_at_3']:.4f} MAE {cv['score_mae']:.5f}", flush=True)
            if family not in best or choice_key(cv) < choice_key(best[family]['cv']):
                best[family] = dict(params=params, cv=cv, config_no=i)

    # Refit each family's best configuration on the whole train part; score on validation.
    X, y, _ = matrix(train)
    Xv, _, _ = matrix(validation)
    fitted = {}
    for family, b in best.items():
        model = build(family, b['params'], args.jobs).fit(np.asarray(X), np.asarray(y))
        pred = model.predict(np.asarray(Xv)).tolist()
        b['validation'] = evaluate(validation, orders_from_predictions(validation, pred), pred)
        fitted[family] = model
    chosen = min(best, key=lambda f: choice_key(best[f]['validation']))
    nearest_val = evaluate(validation, [[r['hub_id'] for r in sorted(
        g['rows'], key=lambda r: (r['road_distance_km'], r['hub_id']))] for g in validation])

    # Save the chosen model in a portable format.
    if chosen == 'XGBRegressor':
        model_file = 'hub_ranker_xgb.json'
        fitted[chosen].save_model(str(model_dir / model_file))
    else:
        import joblib
        model_file = 'hub_ranker_rf.joblib'
        joblib.dump(fitted[chosen], model_dir / model_file, compress=3)
    for old in model_dir.glob('hub_ranker_*'):
        if old.name != model_file:
            old.unlink()
    trained_at = datetime.now(timezone.utc).isoformat(timespec='seconds')
    version = f"hubrank-{chosen[:2].lower()}-{trained_at[:10]}-{sha256(model_dir / model_file)[:8]}"
    environment = dict(python=platform.python_version(), platform=platform.platform(),
                       numpy=np.__version__, scikit_learn=sklearn.__version__,
                       xgboost=xgboost.__version__)
    metadata = dict(
        model_version=version, family=chosen, model_file=model_file,
        model_sha256=sha256(model_dir / model_file),
        features=list(FEATURES), target=TARGET, score_direction='lower_is_better',
        tie_rule='ascending predicted score (9 dp), then lower road_distance_km, then hub_id',
        preprocessing=PREPROCESSING, preprocessing_version=PREPROCESSING_VERSION,
        top_k=TOP_K, handling_penalty=dict(
            category_values=HANDLING_PENALTY,
            at_hub='read from the benchmark: base from the hardest storage need, lowered at a hub with that storage'),
        reference_weights=REFERENCE_WEIGHTS, seed=SEED,
        benchmark_version=json.loads((DATASET_DIR / 'generation_manifest.json')
                                     .read_text(encoding='utf-8'))['benchmark_version'],
        split=split_info(), trained_at_utc=trained_at, environment=environment,
        params=best[chosen]['params'])
    (model_dir / 'model_metadata.json').write_text(json.dumps(metadata, indent=2) + '\n', encoding='utf-8')
    record = dict(
        metadata=metadata,
        protocol=dict(selected_features=list(FEATURES), preprocessing=PREPROCESSING,
                      search_space=SEARCH_SPACE, validation_metric='Top-1 agreement, then NDCG@3, then lower score MAE',
                      configs_per_family=N_CONFIGS, cv=f'{N_FOLDS}-fold GroupKFold by geographic_group_id inside train',
                      config_choice='CV Top-1, then NDCG@3, then lower MAE',
                      family_choice='validation Top-1, then NDCG@3, then lower MAE',
                      refit='best configuration refit on the whole train part (validation not used for fitting)',
                      test_part_loaded=False),
        data=dict(train_groups=len(train), train_rows=len(y),
                  validation_groups=len(validation), validation_rows=len(Xv)),
        best_per_family={f: dict(config_no=b['config_no'], params=b['params'], cv=b['cv'],
                                 validation=b['validation']) for f, b in best.items()},
        chosen_family=chosen, nearest_hub_on_validation=nearest_val,
        input_sha256={n: sha256(DATASET_DIR / n) for n in
                      ('donation_hub_candidates.csv', 'scenario_members.csv', 'generation_manifest.json')},
        runtime_seconds=round(time.time() - started, 1))
    (model_dir / 'training_record.json').write_text(json.dumps(record, indent=2) + '\n', encoding='utf-8')

    with (dev_dir / 'search_results.csv').open('w', newline='', encoding='utf-8') as stream:
        writer = csv.DictWriter(stream, fieldnames=list(trials[0]))
        writer.writeheader()
        writer.writerows(trials)
    write_reports(dev_dir, model_dir, metadata, best, chosen, nearest_val, len(train), len(validation))
    print(json.dumps(dict(chosen=chosen, model_version=version,
                          validation=best[chosen]['validation']), indent=2))


def pct(x):
    return f'{100 * x:.2f} %'


def write_reports(dev_dir, model_dir, meta, best, chosen, nearest_val, n_train, n_val):
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
    (model_dir / 'model_card.md').write_text(f"""# Model card – {meta['model_version']}

| Item | Value |
| --- | --- |
| Task | Rank the community hubs that already passed the five hard rules for one small donation |
| Family | {chosen} |
| Features (in order, unscaled) | {', '.join(meta['features'])} |
| Target | reference_score (lower = better) of each feasible donation–hub pair |
| Ranking | ascending predicted score; ties: lower road distance, then hub ID; Top-{TOP_K} |
| Training data | GEOLOCK benchmark {meta['benchmark_version']}, train part only ({n_train} donations) |
| Validation Top-1 / NDCG@3 / Top-3 | {pct(v['top1_agreement'])} / {v['ndcg_at_3']:.4f} / {pct(v['top3_coverage'])} |
| Seed | {SEED} |
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
