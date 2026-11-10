"""E1 proposed method: AI hub ranking, done the same way as the app's API.

Uses the same feasible hubs as the baselines and the frozen model in "ai hub ranking/model".
FEATURES, load_model() and rank() are read from "ai hub ranking/api/main.py", so the ranking
rule is exactly the app's. Top 3 hubs per donation.
Run from the repository root: python experiments/e1/ai_hub_ranking/source_code/run_ai_hub_ranking.py
"""
import argparse
import ast
import hashlib
import importlib.util
import json
import sys
import time
from pathlib import Path

import numpy as np
import platform
from datetime import datetime
import csv

HERE = Path(__file__).resolve()
ROOT = HERE.parents[4]

API = ROOT / 'ai hub ranking' / 'api' / 'main.py'
MODEL_DIR = ROOT / 'ai hub ranking' / 'model'
TEST_IDS = ROOT / 'ai hub ranking' / 'data split' / 'split' / 'test_scenario_ids.csv'
TOP_K = 3


# Small helpers

def sha256(path):
    """SHA-256 hash of a file."""
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def write_csv(path, records, fields=None):
    """Write rows to a CSV file."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    if not records:
        path.write_text('', encoding='utf-8')
        return
    with path.open('w', encoding='utf-8-sig', newline='') as f:
        w = csv.DictWriter(f, fieldnames=fields or list(records[0]), extrasaction='ignore')
        w.writeheader()
        w.writerows(records)


def write_json(path, value):
    """Write a value to a JSON file."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False, default=str) + '\n', encoding='utf-8')


def environment():
    """Python version, package versions and run time, for the run record."""
    packages = {}
    for name in ('numpy', 'scipy', 'sklearn', 'xgboost', 'ortools', 'matplotlib'):
        try:
            packages[name] = getattr(__import__(name), '__version__', '?')
        except Exception:
            pass
    return dict(python=sys.version.split()[0], platform=platform.platform(), packages=packages,
                run_at=datetime.now().astimezone().isoformat(timespec='seconds'))


def run_info(path, title, items):
    """Write run_info.md, a short record of how this result was made."""
    lines = [f'# Run information: {title}', '', '| Item | Value |', '| --- | --- |']
    lines += [f'| {k} | {v} |' for k, v in items]
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_text('\n'.join(lines) + '\n', encoding='utf-8')


def app_functions():
    """Run only FEATURES, load_model() and rank() from the API file (FastAPI is not needed)."""
    tree = ast.parse(API.read_text(encoding='utf-8'))
    keep = [n for n in tree.body if (isinstance(n, ast.FunctionDef) and n.name in ('rank', 'load_model'))
            or (isinstance(n, ast.Assign) and any(getattr(t, 'id', '') == 'FEATURES' for t in n.targets))]
    ns = {'json': json, 'hashlib': hashlib}
    exec(compile(ast.Module(body=keep, type_ignores=[]), str(API), 'exec'), ns)
    return ns['FEATURES'], ns['load_model'], ns['rank'], hashlib.sha256(
        '\n'.join(ast.get_source_segment(API.read_text(encoding='utf-8'), n) for n in keep).encode()).hexdigest()


def baseline_module():
    """Load the baseline file, so the same code is reused here."""
    path = HERE.parents[2] / 'baseline' / 'source_code' / 'nearest_hub_baseline.py'
    spec = importlib.util.spec_from_file_location('nearest_hub_baseline', path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main():
    """Rank the hubs of every test donation and write the result folder."""
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--output-dir', type=Path, default=HERE.parents[1] / 'result')
    p.add_argument('--scenario-ids', type=Path, default=TEST_IDS)
    a = p.parse_args()
    FEATURES, load_model, rank, app_sha = app_functions()
    model, meta = load_model(MODEL_DIR)
    base = baseline_module()
    selected = base.read_table(a.scenario_ids.parent, a.scenario_ids.stem)
    groups, manifest, hashes = base.load_groups(ROOT / 'benchmark dataset' / 'dataset',
                                                {r['scenario_id'] for r in selected})
    recs, ranking = [], []
    started = time.perf_counter()
    for g in groups:
        rows = [dict(r, **{f: float(r[f]) for f in FEATURES}) for r in g['feasible']]
        if not rows:
            recs.append(dict(scenario_id=g['scenario_id'], donation_id=g['donation_id'], status='NO_FEASIBLE_HUB',
                             feasible_hubs=0, recommended_hub='', distance_to_recommended_hub_km='',
                             second_hub='', third_hub='', predicted_score='', confidence_margin=''))
            continue
        scores = model.predict(np.asarray([[r[f] for f in FEATURES] for r in rows])).tolist()
        ordered = rank(rows, scores)
        top = ordered[:TOP_K] + [None] * (TOP_K - min(TOP_K, len(ordered)))
        recs.append(dict(scenario_id=g['scenario_id'], donation_id=g['donation_id'], status='RECOMMENDED',
                         feasible_hubs=len(ordered), recommended_hub=ordered[0]['hub_id'],
                         distance_to_recommended_hub_km=round(ordered[0]['road_distance_km'], 3),
                         second_hub=top[1]['hub_id'] if top[1] else '', third_hub=top[2]['hub_id'] if top[2] else '',
                         predicted_score=ordered[0]['score'],
                         confidence_margin=round(ordered[1]['score'] - ordered[0]['score'], 9) if len(ordered) > 1 else ''))
        for pos, r in enumerate(ordered, 1):
            ranking.append(dict(scenario_id=g['scenario_id'], donation_id=g['donation_id'], rank=pos, hub_id=r['hub_id'],
                                distance_km=r['road_distance_km'], predicted_score=r['score']))
    ms = (time.perf_counter() - started) * 1000
    out = a.output_dir
    write_csv(out / 'results_per_scenario.csv', recs)
    write_csv(out / 'details' / 'hub_ranking.csv', ranking)
    env = environment()
    run_info(out / 'run_info.md', 'AI hub ranking (E1 proposed)', [
        ('Run at', env['run_at']), ('Benchmark', f"GEOLOCK-BENCHMARK-DATASET (inputs checked against the manifest)"),
        ('Scenarios', f'{len(groups)} held out test donations ({a.scenario_ids.name})'),
        ('Model', f"{meta['model_version']} ({meta['family']}), SHA-256 {meta['model_sha256'][:16]}... (checked)"),
        ('Features', ', '.join(FEATURES)),
        ('Ranking rule', 'api/main.py rank(): predicted score (9 dp), then road distance, then hub ID; Top-k 3'),
        ('App code used', f'FEATURES, load_model(), rank() from ai hub ranking/api/main.py (SHA-256 of extracted source {app_sha[:16]}...)'),
        ('Runner', f'{HERE.name} SHA-256 {sha256(HERE)[:16]}...'),
        ('Scoring time', f'{ms:,.0f} ms for {len(groups)} donations ({ms / max(len(groups), 1):.2f} ms each)'),
        ('Python / xgboost', f"{env['python']} / {env['packages'].get('xgboost')}")])
    write_json(out / 'run_manifest.json', dict(method='ai_hub_ranking', benchmark='GEOLOCK-BENCHMARK-DATASET',
                                                model={k: v for k, v in meta.items() if k != 'benchmark_version'}, input_sha256=hashes,
                                                api_rank_source_sha256=app_sha, environment=env, scenarios=len(groups)))
    print(f'AI hub ranking: {sum(r["status"] == "RECOMMENDED" for r in recs)}/{len(recs)} recommended -> {out}')


if __name__ == '__main__':
    main()
