"""Shared contract of the AI hub-ranking model (used by training, evaluation and the API).

Everything that must be identical in development, the E1 test and the running service
lives here: the feature order, the tie rule, the reference (fallback) score, the
metrics and how a saved model is loaded. Report Sections 3.5 and 3.7.2, Algorithm 3.
"""
import csv
import hashlib
import json
import math
from collections import defaultdict
from pathlib import Path

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
HANDLING_PENALTY = {'clothing': .10, 'books': .20, 'electronics': .40,
                    'food': .60, 'appliances': .80, 'furniture': 1.00}
HARD_RULES = ('item_compatible_flag', 'capacity_feasible_flag', 'operating_feasible_flag',
              'active_feasible_flag', 'route_available_flag')


# ----------------------------------------------------------------------------- data

def read_csv(path):
    with Path(path).open(encoding='utf-8-sig', newline='') as stream:
        return list(csv.DictReader(stream))


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


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
