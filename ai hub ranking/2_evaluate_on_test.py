"""Score the saved model once on the test part and compare it with the baselines.

Baselines (report Table 3.6): Nearest-Hub and Random Hub. The weighted reference policy is the
target, not a competitor. Statistics (report 3.8, Table A.4): Wilson 95 % intervals for Top-1 and Top-3 coverage; exact McNemar
for Top-1 (paired binary); Wilcoxon signed-rank (Pratt zero handling) and the Hodges-Lehmann estimate with a 95 %
bootstrap interval for NDCG@3 (paired continuous); Holm adjustment of the secondary tests,
alpha = 0.05. Primary test: Top-1 against Nearest-Hub. Writes test result/.
"""
import argparse
import importlib.util
import csv
import json
import math
import random
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
from scipy.stats import wilcoxon

# Same data loading, reference score, tie rule, metrics and model loading as step 1.
_spec = importlib.util.spec_from_file_location('step1', Path(__file__).resolve().parent / '1_train_and_select.py')
step1 = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(step1)

BASELINES = {'Nearest-Hub': '1_nearest_hub', 'Random Hub': '2_random_hub'}
BOOTSTRAP = 10000


def baseline_orders(folder, wanted):
    path = step1.REPO / 'baseline implementation' / 'result' / folder / 'details' / 'hub_ranking.csv'
    if not path.exists():
        raise FileNotFoundError(f'Run the baseline first: {path}')
    ranks = defaultdict(list)
    for r in step1.read_csv(path):
        if r['scenario_id'] in wanted:
            ranks[r['scenario_id']].append((int(r['rank']), r['hub_id']))
    return {sid: [h for _, h in sorted(v)] for sid, v in ranks.items()}


def per_group(groups, orders):
    out = []
    for g, order in zip(groups, orders):
        ref = step1.reference_order(g['rows'])
        out.append(dict(top1=int(order[0] == ref[0]), top3=int(ref[0] in order[:step1.TOP_K]),
                        ndcg=step1.ndcg_at_k(g['rows'], order)))
    return out


def hodges_lehmann(diff):
    """Median of all pairwise (Walsh) averages of the paired differences."""
    d = np.asarray(diff, dtype=float)
    walsh = np.add.outer(d, d)[np.triu_indices(len(d))] / 2
    return float(np.median(walsh))


def hodges_lehmann_ci(diff, seed=step1.SEED):
    rng = np.random.default_rng(seed)
    d = np.asarray(diff, dtype=float)
    stats = sorted(hodges_lehmann(d[rng.integers(0, len(d), len(d))]) for _ in range(BOOTSTRAP))
    return stats[int(.025 * BOOTSTRAP)], stats[int(.975 * BOOTSTRAP) - 1]


def holm(p_values):
    """Holm step-down adjusted p-values, in the input order."""
    order = sorted(range(len(p_values)), key=lambda k: p_values[k])
    adjusted, running = [0.0] * len(p_values), 0.0
    for rank_, k in enumerate(order):
        running = max(running, min(1.0, (len(p_values) - rank_) * p_values[k]))
        adjusted[k] = running
    return adjusted


def wilson_ci(hits, n, z=1.959964):
    """Two-sided 95 % Wilson interval for a proportion (report Section 3.8)."""
    p = hits / n
    centre = (p + z * z / (2 * n)) / (1 + z * z / n)
    half = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / (1 + z * z / n)
    return centre - half, centre + half


def bootstrap_ci(values, seed=step1.SEED):
    rng = random.Random(seed)
    n = len(values)
    stats = sorted(sum(values[rng.randrange(n)] for _ in range(n)) / n for _ in range(BOOTSTRAP))
    return stats[int(.025 * BOOTSTRAP)], stats[int(.975 * BOOTSTRAP) - 1]


def mcnemar_exact(a, b):
    """Two-sided exact McNemar test on paired Top-1 hits (a vs b)."""
    only_a = sum(1 for x, y in zip(a, b) if x and not y)
    only_b = sum(1 for x, y in zip(a, b) if y and not x)
    n = only_a + only_b
    if n == 0:
        return only_a, only_b, 1.0
    k = min(only_a, only_b)
    p = sum(math.comb(n, i) for i in range(k + 1)) / 2 ** n
    return only_a, only_b, min(1.0, 2 * p)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir', type=Path, default=step1.ROOT / 'test result')
    args = parser.parse_args()
    out = args.output_dir
    (out / 'details').mkdir(parents=True, exist_ok=True)
    if (out / 'metrics.json').exists():
        raise SystemExit('test result/metrics.json already exists: E1 is scored once. '
                         'Move the old folder away only if the model was legitimately re-frozen.')

    test = step1.load_groups('test')
    wanted = {g['scenario_id'] for g in test}
    try:
        model, meta = step1.load_model()
    except Exception as error:
        # Report Algorithm 3: a reference-policy fallback is model unavailability, never an RQ1 result.
        raise SystemExit(f'Model unavailable, E1 not scored (REFERENCE_FALLBACK is excluded from RQ1): {error}')
    mode = 'MODEL'

    X, _, _ = step1.matrix(test)
    predictions = model.predict(np.asarray(X)).tolist()
    model_orders = step1.orders_from_predictions(test, predictions)

    methods = {'AI model': model_orders}
    for name, folder in BASELINES.items():
        orders = baseline_orders(folder, wanted)
        methods[name] = [orders[g['scenario_id']] for g in test]
        for g, o in zip(test, methods[name]):
            if sorted(o) != sorted(r['hub_id'] for r in g['rows']):
                raise ValueError(f'{name} candidate set differs from the feasible set: {g["scenario_id"]}')

    metrics, details = {}, {}
    for name, orders in methods.items():
        m = step1.evaluate(test, orders, predictions if name == 'AI model' else None)
        d = per_group(test, orders)
        m['top1_ci95'] = wilson_ci(m['top1_count'], m['groups'])
        m['top3_ci95'] = wilson_ci(m['top3_count'], m['groups'])
        nd = [x['ndcg'] for x in d if x['ndcg'] is not None]
        m['ndcg_at_3_ci95'] = bootstrap_ci(nd)
        metrics[name], details[name] = m, d
    comparisons = {}
    for name in BASELINES:
        a, b, p = mcnemar_exact([x['top1'] for x in details['AI model']], [x['top1'] for x in details[name]])
        pairs = [(x['ndcg'], y['ndcg']) for x, y in zip(details['AI model'], details[name])
                 if x['ndcg'] is not None and y['ndcg'] is not None]
        diff = [x - y for x, y in pairs]
        comparisons[f'AI model vs {name}'] = dict(
            model_only_correct=a, baseline_only_correct=b, mcnemar_exact_p=p,
            ndcg_wilcoxon_p=float(wilcoxon([x for x, _ in pairs], [y for _, y in pairs],
                                            zero_method='pratt').pvalue),
            ndcg_hodges_lehmann=hodges_lehmann(diff), ndcg_hodges_lehmann_ci95=hodges_lehmann_ci(diff))
    # Primary: Top-1 vs Nearest-Hub. Every other test is secondary and Holm-adjusted together.
    secondary = [('AI model vs Random Hub', 'mcnemar_exact_p'),
                 ('AI model vs Nearest-Hub', 'ndcg_wilcoxon_p'), ('AI model vs Random Hub', 'ndcg_wilcoxon_p')]
    for (key, field), adj in zip(secondary, holm([comparisons[k][f] for k, f in secondary])):
        comparisons[key][field + '_holm'] = adj
    comparisons['AI model vs Nearest-Hub']['mcnemar_exact_p_holm'] = None   # primary, not adjusted
    differs = sum(1 for g, o in zip(test, model_orders) if o[0] != step1.reference_order(g['rows'])[0])

    # One record per test donation.
    hubs = {r['hub_id']: r['hub_name'] for r in step1.read_csv(step1.DATASET_DIR / 'hubs.csv')}
    now = datetime.now(timezone.utc).isoformat(timespec='seconds')
    i = 0
    rows_out = []
    with (out / 'details' / 'recommendation_records.jsonl').open('w', encoding='utf-8') as stream:
        for g, order, nearest in zip(test, model_orders, methods['Nearest-Hub']):
            k = len(g['rows'])
            ranked = step1.rank(g['rows'], predictions[i:i + k])
            i += k
            ref = step1.reference_order(g['rows'])
            top = ranked[0]
            margin = ranked[1]['score'] - top['score'] if len(ranked) > 1 else None
            record = dict(
                scenario_id=g['scenario_id'], donation_id=g['donation_id'],
                ranking_mode=mode, model_version=meta.get('model_version'),
                preprocessing_version=meta.get('preprocessing_version'),
                hard_rules_passed=list(step1.HARD_RULES), feasible_hub_count=k,
                candidates=[{**{f: r[f] for f in step1.FEATURES}, 'hub_id': r['hub_id'],
                             'predicted_score': r['score'], 'reference_score': r[step1.TARGET]}
                            for r in ranked],
                ranking=[r['hub_id'] for r in ranked], top_k=[r['hub_id'] for r in ranked[:step1.TOP_K]],
                selected_hub=top['hub_id'], reference_first_hub=ref[0],
                confidence_margin=None if margin is None else round(margin, 9),
                explanation=(f"{hubs.get(top['hub_id'], top['hub_id'])}: {top['road_distance_km']:.1f} km by road, "
                             f"{100 * top['utilisation_ratio']:.0f} % full, capacity pressure "
                             f"{top['capacity_pressure']:.2f}; lowest predicted score among {k} feasible hubs."),
                recorded_at_utc=now)
            stream.write(json.dumps(record) + '\n')
            rows_out.append(dict(scenario_id=g['scenario_id'], donation_id=g['donation_id'],
                                 feasible_hubs=k, model_hub=top['hub_id'], reference_hub=ref[0],
                                 nearest_hub=nearest[0], model_top1_agrees=int(top['hub_id'] == ref[0]),
                                 model_second=order[1] if k > 1 else '', model_third=order[2] if k > 2 else '',
                                 confidence_margin='' if margin is None else round(margin, 6)))
    with (out / 'results_per_scenario.csv').open('w', newline='', encoding='utf-8') as stream:
        writer = csv.DictWriter(stream, fieldnames=list(rows_out[0]))
        writer.writeheader()
        writer.writerows(rows_out)

    result = dict(experiment='E1', ranking_mode=mode, model=meta, test_groups=len(test),
                  planned_test_groups='about 300 (report Table 3.9)',
                  no_feasible_hub_scenarios='reported separately (HUB_RECOMMENDATION_VERIFICATION, not scored)',
                  metrics=metrics, comparisons=comparisons,
                  model_top1_differs_from_reference=dict(count=differs, total=len(test),
                                                         share=differs / len(test)),
                  scored_at_utc=now)
    (out / 'metrics.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    write_summary(out, result)
    print(json.dumps({k: {m: v[m] for m in ('top1_agreement', 'ndcg_at_3', 'top3_coverage')}
                      for k, v in metrics.items() if 'top1_agreement' in v}, indent=2))


def write_summary(out, r):
    pct = lambda x: f'{100 * x:.2f} %'
    lines = ['| Method | Top-1 agreement (95 % CI) | NDCG@3 (95 % CI) | Top-3 coverage (95 % CI) |',
             '| --- | --- | --- | --- |']
    for name, m in r['metrics'].items():
        if 'top1_ci95' not in m:
            continue
        lo, hi = m['top1_ci95']
        nlo, nhi = m['ndcg_at_3_ci95']
        lines.append(f"| {name} | {pct(m['top1_agreement'])} ({m['top1_count']}/{m['groups']}; "
                     f"{pct(lo)}–{pct(hi)}) | {m['ndcg_at_3']:.4f} ({nlo:.4f}–{nhi:.4f}) | "
                     f"{pct(m['top3_coverage'])} ({m['top3_count']}/{m['groups']}; "
                     f"{pct(m['top3_ci95'][0])}–{pct(m['top3_ci95'][1])}) |")
    adj = lambda v: 'primary (not adjusted)' if v is None else f'{v:.3g}'
    comp = ['| Comparison | Only model correct | Only baseline correct | Exact McNemar p | Holm-adjusted p |',
            '| --- | --- | --- | --- | --- |']
    for name, c in r['comparisons'].items():
        comp.append(f"| {name} | {c['model_only_correct']} | {c['baseline_only_correct']} "
                    f"| {c['mcnemar_exact_p']:.3g} | {adj(c['mcnemar_exact_p_holm'])} |")
    ndcg = ['| Comparison | NDCG@3 difference, Hodges-Lehmann (95 % CI) | Wilcoxon p | Holm-adjusted p |',
            '| --- | --- | --- | --- |']
    for name, c in r['comparisons'].items():
        lo, hi = c['ndcg_hodges_lehmann_ci95']
        ndcg.append(f"| {name} | {c['ndcg_hodges_lehmann']:+.4f} ({lo:+.4f} to {hi:+.4f}) "
                    f"| {c['ndcg_wilcoxon_p']:.3g} | {c['ndcg_wilcoxon_p_holm']:.3g} |")
    d = r['model_top1_differs_from_reference']
    (out / 'summary.md').write_text(f"""# E1 – AI hub ranking on the held-out test part
Model `{r['model'].get('model_version')}` ({r['model'].get('family')}), scored once on {r['test_groups']}
held-out test donations from Geohash-5 areas never seen in training
(planned: about 300, report Table 3.9; realised: {r['test_groups']}). Every method ranks exactly
the same feasible hubs (five hard rules) and is compared with the weighted reference policy.

{chr(10).join(lines)}

Top-1 agreement (paired, exact McNemar):

{chr(10).join(comp)}

NDCG@3 (paired per donation, model minus baseline; Wilcoxon signed-rank):

{chr(10).join(ndcg)}

Primary test: Top-1 against Nearest-Hub (alpha = 0.05). The other three tests are secondary and
Holm-adjusted together (report Table A.4).

The model's first hub differs from the reference policy's first hub in {d['count']} of {d['total']}
donations ({pct(d['share'])}). 95 % intervals: Wilson for Top-1 and Top-3 coverage; percentile bootstrap
over donations for NDCG@3 ({BOOTSTRAP:,} resamples, seed {step1.SEED}). NDCG@3 excludes all-equal (degenerate) groups
({r['metrics']['AI model']['degenerate_groups']} here).

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
""", encoding='utf-8')


if __name__ == '__main__':
    main()
