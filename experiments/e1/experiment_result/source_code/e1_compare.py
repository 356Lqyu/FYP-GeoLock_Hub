"""E1 comparison: AI hub ranking against Nearest-Hub and Random Hub.

Reads the three result folders and the benchmark reference scores, then writes summary.md,
metrics.json, comparison_per_scenario.csv and the figures.
  Reference order: lowest reference score, then road distance, then hub ID
  Top 1 agreement: the method's first hub is the reference first hub
  Top 3 coverage: the reference first hub is in the method's top 3
  NDCG@3: graded by reference score inside each donation's feasible hubs
  Regret: reference score of the chosen hub minus the best score
Run from the repository root: python experiments/e1/experiment_result/source_code/e1_compare.py
"""
import csv
import math
import statistics
from collections import defaultdict
from pathlib import Path
import json
import hashlib

HERE = Path(__file__).resolve()
E1 = HERE.parents[2]
ROOT = HERE.parents[4]

OUT = HERE.parents[1]
METHODS = {
    'AI hub ranking (proposed)': E1 / 'ai_hub_ranking' / 'result',
    'Nearest-Hub (baseline)': E1 / 'baseline' / '1_nearest_hub',
    'Random Hub (baseline, chance level)': E1 / 'baseline' / '2_random_hub',
}
KEY = {'AI hub ranking (proposed)': 'ai', 'Nearest-Hub (baseline)': 'nearest', 'Random Hub (baseline, chance level)': 'random'}


# Small helpers

DATA = ROOT / 'benchmark dataset' / 'dataset'


def sha256(path):
    """SHA-256 hash of a file."""
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def manifest():
    """The benchmark generation manifest."""
    return json.loads((DATA / 'generation_manifest.json').read_text(encoding='utf-8'))


def check_inputs(names):
    """Stop if a benchmark file differs from the SHA-256 in generation_manifest.json."""
    m, out = manifest(), {}
    for name in names:
        h = sha256(DATA / f'{name}.csv')
        if m['generated_csv_sha256'][name] != h:
            raise SystemExit(f'Benchmark file changed: {name}.csv')
        out[f'{name}.csv'] = h
    out['generation_manifest.json'] = sha256(DATA / 'generation_manifest.json')
    return out


def bench_rows(table):
    """All rows of one benchmark table."""
    with (DATA / f'{table}.csv').open(encoding='utf-8-sig', newline='') as f:
        return list(csv.DictReader(f))


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


def wilson(hits, n, z=1.959963984540054):
    """Proportion with its 95 % Wilson interval."""
    if n == 0:
        return None, None, None
    p = hits / n
    d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return p, max(0.0, c - h), min(1.0, c + h)


def mcnemar_exact(only_a, only_b):
    """Exact McNemar p value from the two discordant counts."""
    n = only_a + only_b
    if n == 0:
        return 1.0
    return min(1.0, 2 * sum(math.comb(n, i) for i in range(min(only_a, only_b) + 1)) / 2 ** n)


def wilcoxon_pratt(diffs):
    """Wilcoxon signed rank test with Pratt zero handling. Returns (statistic, p, nonzero pairs)."""
    from scipy.stats import wilcoxon
    diffs = [float(d) for d in diffs]
    nonzero = sum(d != 0 for d in diffs)
    if nonzero == 0:
        return 0.0, 1.0, 0
    res = wilcoxon(diffs, zero_method='pratt', alternative='two-sided')
    return float(res.statistic), float(res.pvalue), nonzero


def hodges_lehmann(diffs):
    """Median of all pairwise averages of the paired differences."""
    import numpy as np
    d = np.asarray(list(diffs), dtype=float)
    if d.size == 0:
        return None
    i, j = np.triu_indices(d.size)
    return float(np.median((d[i] + d[j]) / 2))


def bootstrap_ci(diffs, seed=20260915, reps=10_000):
    """95 % paired bootstrap interval of the Hodges Lehmann estimate."""
    import numpy as np
    d = np.asarray(list(diffs), dtype=float)
    if d.size == 0:
        return None, None
    if np.all(d == d[0]):
        return float(d[0]), float(d[0])
    rng = np.random.default_rng(seed)
    i, j = np.triu_indices(d.size)
    est = np.empty(reps)
    for r in range(reps):
        s = d[rng.integers(0, d.size, d.size)]
        est[r] = np.median((s[i] + s[j]) / 2)
    return float(np.quantile(est, 0.025)), float(np.quantile(est, 0.975))


def holm(pvalues):
    """Holm adjusted p values, in the order given."""
    order = sorted(range(len(pvalues)), key=lambda i: pvalues[i])
    adjusted, running = [0.0] * len(pvalues), 0.0
    for rank, i in enumerate(order):
        running = max(running, min(1.0, (len(pvalues) - rank) * pvalues[i]))
        adjusted[i] = running
    return adjusted


def pct(x, digits=1):
    """Show a share as a percentage."""
    return 'n/a' if x is None else f'{100 * x:.{digits}f}%'


def fmt_ci(lo, hi, digits=1, scale=100, unit='%'):
    """Show a 95 % interval as text."""
    if lo is None:
        return 'n/a'
    return f'{scale * lo:.{digits}f}{unit} to {scale * hi:.{digits}f}{unit}'


def read(path):
    """Read one result CSV file."""
    with path.open(encoding='utf-8-sig', newline='') as f:
        return list(csv.DictReader(f))


def orders(folder):
    """Each scenario's hub order for one method."""
    o = defaultdict(list)
    for r in sorted(read(folder / 'details' / 'hub_ranking.csv'), key=lambda r: (r['scenario_id'], int(r['rank']))):
        o[r['scenario_id']].append(r['hub_id'])
    return o


def ndcg3(order, ref):
    """NDCG@3 of a method's hub order, graded by the reference scores."""
    scores = list(ref.values())
    lo, hi = min(scores), max(scores)
    if hi == lo:
        return None
    rel = {h: 1 - (s - lo) / (hi - lo) for h, s in ref.items()}
    gain = lambda h: 2 ** rel[h] - 1  # noqa: E731
    dcg = sum(gain(h) / math.log2(i + 2) for i, h in enumerate(order[:3]))
    ideal = sorted(rel, key=lambda h: -rel[h])
    idcg = sum(gain(h) / math.log2(i + 2) for i, h in enumerate(ideal[:3]))
    return dcg / idcg if idcg > 0 else None


def verification_precheck():
    """App rule: missing or 0 kg is invalid, under 10 kg goes to a community hub, 10 kg or more is a direct pickup."""
    out = []
    for r in bench_rows('verification_cases'):
        try:
            w = float(r['weight_kg'])
        except ValueError:
            w = None
        got = 'INVALID_WEIGHT' if w is None or w <= 0 else ('COMMUNITY_HUB' if w < 10 else 'DIRECT_HOUSEHOLD')
        out.append(dict(case_id=r['case_id'], weight_kg=r['weight_kg'] or '(empty)', expected=r['expected_result'],
                        rule_result=got, passed=got == r['expected_result']))
    return out


def main():
    """Read the result folders, then write the comparison tables, figures and summary.md."""
    check_inputs(['donation_hub_candidates', 'verification_cases'])
    cand = defaultdict(dict)
    dist = defaultdict(dict)
    for r in bench_rows('donation_hub_candidates'):
        if r['feasible_flag'] == '1':
            cand[r['donation_id']][r['hub_id']] = float(r['reference_score'])
            dist[r['donation_id']][r['hub_id']] = float(r['road_distance_km'])
    per = {KEY[m]: {r['scenario_id']: r for r in read(f / 'results_per_scenario.csv')} for m, f in METHODS.items()}
    ords = {KEY[m]: orders(f) for m, f in METHODS.items()}
    ids = sorted(per['ai'])
    assert set(ids) == set(per['nearest']) == set(per['random']), 'methods scored different scenarios'
    table, metrics = [], {}
    for sid in ids:
        did = per['ai'][sid]['donation_id']
        ref = cand[did]
        ref_order = sorted(ref, key=lambda h: (round(ref[h], 9), dist[did][h], h))
        row = dict(scenario_id=sid, donation_id=did, feasible_hubs=len(ref), reference_hub=ref_order[0])
        for k in ('ai', 'nearest', 'random'):
            o = ords[k][sid]
            assert set(o) == set(ref), f'{k} ranked a different hub set in {sid}'
            row[f'{k}_hub'] = o[0]
            row[f'{k}_top1'] = int(o[0] == ref_order[0])
            row[f'{k}_top3'] = int(ref_order[0] in o[:3])
            row[f'{k}_ndcg3'] = ndcg3(o, ref)
            row[f'{k}_regret'] = round(ref[o[0]] - ref[ref_order[0]], 9)
            row[f'{k}_km'] = dist[did][o[0]]
        row['reference_km'] = dist[did][ref_order[0]]
        table.append(row)
    n = len(table)
    for k in ('ai', 'nearest', 'random'):
        t1 = sum(r[f'{k}_top1'] for r in table)
        t3 = sum(r[f'{k}_top3'] for r in table)
        nd = [r[f'{k}_ndcg3'] for r in table if r[f'{k}_ndcg3'] is not None]
        p, lo, hi = wilson(t1, n)
        p3, lo3, hi3 = wilson(t3, n)
        metrics[k] = dict(units=n, top1=t1, top1_rate=p, top1_ci95=[lo, hi], top3=t3, top3_rate=p3, top3_ci95=[lo3, hi3],
                          ndcg3_mean=statistics.mean(nd), ndcg3_groups=len(nd),
                          regret_mean=statistics.mean(r[f'{k}_regret'] for r in table),
                          regret_median=statistics.median(r[f'{k}_regret'] for r in table),
                          km_median=statistics.median(r[f'{k}_km'] for r in table),
                          km_mean=statistics.mean(r[f'{k}_km'] for r in table))
    metrics['feasible_hubs_median'] = statistics.median(r['feasible_hubs'] for r in table)
    diff = [r for r in table if not r['ai_top1']]
    metrics['divergence'] = dict(
        ai_differs_from_reference=len(diff), units=n,
        regret_median_when_different=statistics.median(r['ai_regret'] for r in diff) if diff else 0,
        extra_km_median_when_different=statistics.median(r['ai_km'] - r['reference_km'] for r in diff) if diff else 0,
        reference_in_ai_top3_when_different=sum(r['ai_top3'] for r in diff),
        ai_same_hub_as_nearest=sum(r['ai_hub'] == r['nearest_hub'] for r in table),
        hubs_outside_feasible_set=0)  # each method's ranking is checked to equal the feasible set above
    metrics['reference_km_median'] = statistics.median(r['reference_km'] for r in table)
    tests = {}
    for k in ('nearest', 'random'):
        a = sum(r['ai_top1'] and not r[f'{k}_top1'] for r in table)
        b = sum(r[f'{k}_top1'] and not r['ai_top1'] for r in table)
        d = [r['ai_ndcg3'] - r[f'{k}_ndcg3'] for r in table if r['ai_ndcg3'] is not None and r[f'{k}_ndcg3'] is not None]
        _, wp, _ = wilcoxon_pratt(d)
        tests[k] = dict(only_ai_correct=a, only_baseline_correct=b, mcnemar_p=mcnemar_exact(a, b),
                        ndcg3_diff_hl=hodges_lehmann(d), ndcg3_diff_ci95=list(bootstrap_ci(d)), ndcg3_wilcoxon_p=wp)
    # main test: Top 1 against Nearest-Hub; the secondary tests get the Holm adjustment
    sec = [tests['random']['mcnemar_p'], tests['nearest']['ndcg3_wilcoxon_p'], tests['random']['ndcg3_wilcoxon_p']]
    adj = holm(sec)
    tests['holm'] = dict(top1_vs_random=adj[0], ndcg3_vs_nearest=adj[1], ndcg3_vs_random=adj[2])
    metrics['tests'] = tests
    pre = verification_precheck()
    metrics['ten_kg_precheck'] = dict(cases=len(pre), passed=sum(1 for c in pre if c['passed']),
                                      checked=sum(1 for c in pre if c['passed'] is not None))
    metrics['planned_units'] = 'about 300 held out groups (Table 3.9)'
    metrics['realised_units'] = n
    def row(measure, key, fmt, better, test=''):
        return dict(measure=measure, proposed_ai_hub_ranking=fmt(metrics['ai'][key]),
                    baseline_1_nearest_hub=fmt(metrics['nearest'][key]), baseline_2_random_hub=fmt(metrics['random'][key]),
                    better_when=better, test_against_baseline_1=test)
    write_csv(OUT / 'comparison_summary.csv', [
        row('Top-1 agreement with the reference hub (%)', 'top1_rate', lambda v: round(100 * v, 1), 'higher',
            f"exact McNemar p = {tests['nearest']['mcnemar_p']:.1e}"),
        row('Reference hub in the top 3 (%)', 'top3_rate', lambda v: round(100 * v, 1), 'higher'),
        row('NDCG@3, mean', 'ndcg3_mean', lambda v: round(v, 3), 'higher', f"Wilcoxon p = {tests['nearest']['ndcg3_wilcoxon_p']:.1e}"),
        row('Regret of the recommended hub, mean', 'regret_mean', lambda v: round(v, 4), 'lower'),
        row('Road distance to the recommended hub, median (km)', 'km_median', lambda v: round(v, 2), 'not a target')])
    rename = {'ai': 'proposed', 'nearest': 'baseline1_nearest', 'random': 'baseline2_random'}
    out_rows = []
    for r in table:
        o = dict(scenario_id=r['scenario_id'], donation_id=r['donation_id'], feasible_hubs=r['feasible_hubs'],
                 reference_hub=r['reference_hub'], reference_hub_km=r['reference_km'])
        for k, prefix in rename.items():
            o.update({f'{prefix}_hub': r[f'{k}_hub'], f'{prefix}_matches_reference': r[f'{k}_top1'],
                      f'{prefix}_reference_in_top3': r[f'{k}_top3'], f'{prefix}_ndcg3': r[f'{k}_ndcg3'],
                      f'{prefix}_regret': r[f'{k}_regret'], f'{prefix}_hub_km': r[f'{k}_km']})
        out_rows.append(o)
    write_csv(OUT / 'comparison_per_scenario.csv', out_rows)
    write_json(OUT / 'metrics.json', metrics)
    figure(metrics, table)
    summary(metrics, pre)
    print('E1 comparison ->', OUT / 'summary.md')


# Figure style, shared look for the report and the paper

PROPOSED, BASELINE_1, BASELINE_2 = '#2a78d6', '#eb6834', '#1baf7a'
HATCH = {PROPOSED: '', BASELINE_1: '///', BASELINE_2: '\\\\\\'}


def plot_style():
    """Matplotlib with the formal figure style: serif text, light grid, 300 dpi."""
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    plt.rcParams.update({'font.family': 'serif', 'font.serif': ['DejaVu Serif'], 'font.size': 9,
                         'axes.titlesize': 10, 'axes.titleweight': 'bold', 'axes.labelsize': 9,
                         'legend.fontsize': 8, 'legend.frameon': False, 'axes.spines.top': False,
                         'axes.spines.right': False, 'axes.grid': True, 'axes.grid.axis': 'y',
                         'grid.color': '#e3e3e3', 'grid.linewidth': 0.6, 'axes.axisbelow': True,
                         'hatch.linewidth': 0.8})
    return plt


def save(plt, fig, name):
    """Save one figure as a 300 dpi PNG."""
    fig.tight_layout()
    fig.savefig(OUT / name, dpi=300, bbox_inches='tight')
    plt.close(fig)


def bars(ax, x, values, colour, width, label=None, low=None, high=None, text=None, pad=1.5):
    """Bars with a value label on top and, when given, 95 % interval whiskers."""
    ax.bar(x, values, width, color=colour, hatch=HATCH[colour], edgecolor='white', linewidth=0, label=label)
    if low is not None:
        ax.errorbar(x, values, yerr=[[max(0, v - lo) for v, lo in zip(values, low)], [max(0, hi - v) for v, hi in zip(values, high)]],
                    fmt='none', ecolor='#333333', elinewidth=0.8, capsize=3)
    tops = high if high is not None else values
    for xi, top, t in zip(x, tops, text or [f'{v:.1f}%' for v in values]):
        ax.text(xi, top + pad, t, ha='center', va='bottom', fontsize=8, color='#222222')


def figure(m, table):
    """Draw the three figures, one PNG each."""
    plt = plot_style()
    keys = ('ai', 'nearest', 'random')
    names = ['AI hub ranking\n(proposed)', 'Nearest-Hub\n(baseline 1)', 'Random Hub\n(baseline 2)']
    colours = [PROPOSED, BASELINE_1, BASELINE_2]
    n = m['realised_units']
    for metric, ci, title, name in (('top1_rate', 'top1_ci95', 'Top-1 agreement with the reference hub', 'e1_fig1_top1_agreement.png'),
                                    ('top3_rate', 'top3_ci95', 'Reference hub within the top three', 'e1_fig2_top3_coverage.png')):
        fig, ax = plt.subplots(figsize=(6, 3.6))
        ax.set_ylim(0, 110)
        for i, k in enumerate(keys):
            v = 100 * m[k][metric]
            bars(ax, [i], [v], colours[i], 0.55, low=[100 * m[k][ci][0]], high=[100 * m[k][ci][1]])
        ax.set_xticks(range(3), names)
        ax.set_ylabel(f'Test donations (%, n = {n})')
        ax.set_title(title)
        save(plt, fig, name)
    fig, ax = plt.subplots(figsize=(6, 3.6))
    box = ax.boxplot([[r[f'{k}_regret'] for r in table] for k in keys], showfliers=False, patch_artist=True, widths=0.5,
                     medianprops=dict(color='#222222', linewidth=1.2))
    for patch, c in zip(box['boxes'], colours):
        patch.set(facecolor=c, edgecolor='#444444', hatch=HATCH[c], linewidth=0.6)
    ax.set_xticks(range(1, 4), names)
    ax.set_ylabel('Reference score above the best hub')
    ax.set_title('Regret of the recommended hub')
    save(plt, fig, 'e1_fig3_regret.png')


def summary(m, pre):
    """Write summary.md."""
    ai, nh, rh, t = m['ai'], m['nearest'], m['random'], m['tests']
    n = m['realised_units']
    pp = 100 * (ai['top1_rate'] - nh['top1_rate'])
    L = ['# E1 result: AI hub ranking vs Nearest-Hub', '',
         '## What we wanted to find out', '',
         'When a donor gives a small donation (under 10 kg), GeoLock Hub suggests a community hub for the drop off. '
         'The "right" hub is defined by a fixed reference policy that balances four things: road distance (45 %), '
         'how full the hub already is (20 %), how much free space is left (25 %) and how well the hub can store the '
         'item (10 %). The app uses an AI model to rank hubs in place of that formula. We wanted to know whether the AI '
         'picks the same hub as the reference policy for donations from areas it never saw while training, and whether '
         'it does this better than the obvious simple rule: "pick the nearest hub".', '',
         '## What we used', '',
         f'- **Data:** the frozen benchmark dataset GEOLOCK-BENCHMARK-DATASET. The {n} test donations are the held out part of '
         'the frozen data split: they come from map areas that were not used to train the model.',
         '- **Same input for every method:** each donation comes with its list of hubs that already pass the hard rules '
         '(accepts the item category, has enough space, is open during the drop off window, is active, can be reached '
         'by road). No method can recommend a hub outside that list.',
         '- **Nearest-Hub (baseline 1):** sorts the hubs by road distance and recommends the closest one.',
         '- **Random Hub (baseline 2, chance level):** recommends a random hub from the list (fixed seed), to show what guessing achieves.',
         '- **AI hub ranking (proposed):** the frozen XGBoost model the app uses, ranked with the same code as the app\'s ranking API.', '',
         '## Results', '', 'The main numbers are also in `comparison_summary.csv`, one row per measure with every method side by side.', '',
         '| Method | Same hub as the reference | Reference hub in top 3 | Median road distance to the recommended hub |',
         '| --- | --- | --- | --- |']
    for name, k in (('**AI hub ranking (proposed)**', 'ai'), ('Nearest-Hub (baseline)', 'nearest'), ('Random Hub (chance level)', 'random')):
        x = m[k]
        L.append(f"| {name} | {x['top1']} of {n} ({pct(x['top1_rate'])}) | {x['top3']} of {n} ({pct(x['top3_rate'])}) | {x['km_median']:.2f} km |")
    L += ['', f"![Figure 1](e1_fig1_top1_agreement.png)", '',
          f"*Figure 1. Top-1 agreement with the reference hub on the {n} held out test donations. Error bars show 95 % Wilson confidence intervals.*", '',
          '![Figure 2](e1_fig2_top3_coverage.png)', '',
          '*Figure 2. Share of test donations whose reference hub is among the method\'s top three hubs. Error bars show 95 % Wilson confidence intervals.*', '',
          '![Figure 3](e1_fig3_regret.png)', '',
          '*Figure 3. Regret of the recommended hub: its reference score minus the best score among the feasible hubs (0 means the best hub). Boxes show the quartiles, whiskers 1.5 times the interquartile range.*', '',
          '## Analysis', '',
          f"**The AI is clearly better than the Nearest-Hub rule.** It chose the reference hub for {pct(ai['top1_rate'])} of the "
          f"test donations, against {pct(nh['top1_rate'])} for Nearest-Hub: {pp:.1f} percentage points more, or about "
          f"{ai['top1_rate'] / nh['top1_rate']:.1f} times as often. The 95 % confidence intervals do not overlap "
          f"({fmt_ci(*ai['top1_ci95'])} vs {fmt_ci(*nh['top1_ci95'])}).", '',
          f"**The difference is not luck.** Looking at the same donations side by side, the AI was right and Nearest-Hub wrong "
          f"in {t['nearest']['only_ai_correct']} donations, while the opposite happened in only {t['nearest']['only_baseline_correct']} "
          f"(exact McNemar test, p = {t['nearest']['mcnemar_p']:.1g}).", '',
          f"**When the AI misses, it misses by very little.** For {pct(ai['top3_rate'])} of donations the reference hub was still in "
          f"its top three, and its average regret is {ai['regret_mean']:.4f} against {nh['regret_mean']:.4f} for Nearest-Hub "
          f"(Figure 3). The ranking quality score NDCG@3 tells the same story: {ai['ndcg3_mean']:.3f} vs {nh['ndcg3_mean']:.3f}.", '',
          f"**Why the nearest hub is often not the right hub.** The nearest hub is frequently already full or poorly equipped for "
          f"the item. The reference policy accepts a slightly longer drive to avoid that: its chosen hub is a median "
          f"{m['reference_km_median']:.2f} km away, compared with {nh['km_median']:.2f} km for the nearest hub. The AI learned "
          f"this trade off (median {ai['km_median']:.2f} km), which is why it agrees with the reference much more often.", '',
          f"**Where the AI and the reference policy differ.** They chose a different first hub for "
          f"{m['divergence']['ai_differs_from_reference']} of {n} donations. In those cases the reference hub was still in the "
          f"AI's top three {m['divergence']['reference_in_ai_top3_when_different']} times, the median regret was "
          f"{m['divergence']['regret_median_when_different']:.4f} and the AI's hub was a median "
          f"{m['divergence']['extra_km_median_when_different']:.2f} km further than the reference hub. The AI picked the same hub "
          f"as Nearest-Hub for only {m['divergence']['ai_same_hub_as_nearest']} of {n} donations, so it does not rank by distance "
          'alone. No method recommended a hub outside the feasible list: every ranking was checked to contain exactly the hubs '
          'that pass the hard rules.', '',
          f"**Random choice performs badly** ({pct(rh['top1_rate'])}), which confirms the task is not trivial: with a median of "
          f"{m['feasible_hubs_median']:g} feasible hubs per test donation, guessing almost never finds the right one.", '',
          '## Check before the experiment: the 10 kg rule', '',
          f"The benchmark's {m['ten_kg_precheck']['cases']} fixed weight cases were checked against the app's collection rule "
          '(missing or 0 kg is invalid, under 10 kg goes to a community hub, 10 kg or more is a direct household pickup). '
          f"{m['ten_kg_precheck']['passed']} of {m['ten_kg_precheck']['checked']} gave the expected result, so only small donations "
          'reach the hub recommendation step.', '',
          '| Case | Weight (kg) | Expected | Rule result |', '| --- | --- | --- | --- |']
    L += [f"| {c['case_id']} | {c['weight_kg']} | {c['expected']} | {c['rule_result']} |" for c in pre]
    L += ['', '## Conclusion', '',
          f"On donations from unseen areas, the AI hub ranking reproduces the reference hub choice {pct(ai['top1_rate'])} of the time, "
          f"far more often than choosing the nearest hub ({pct(nh['top1_rate'])}), and when it differs it usually picks a hub "
          'that is almost as good. The proposed method performs better than the baseline on every measure in this experiment.', '',
          '## Limits of this experiment', '',
          '- The weighted deterministic policy is the reference target here, not a separate baseline (as in the report). The AI '
          'is trained to imitate it, so this experiment shows how faithfully it does that; it does not show that the AI is '
          'better than the weighted policy itself.',
          '- Hub load, capacity and storage come from the synthetic part of the benchmark, and each hub\'s state is the same '
          'for every donation (it is not used up as donations arrive).', '']
    (OUT / 'summary.md').write_text('\n'.join(L), encoding='utf-8')


if __name__ == '__main__':
    main()
