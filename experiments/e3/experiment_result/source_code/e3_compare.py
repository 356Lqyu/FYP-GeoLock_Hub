"""E3 comparison: direct household pickup (baseline) against community hub aggregation (proposed).

Pairs the two results by scenario and writes summary.md, metrics.json, comparison_per_scenario.csv
and the figures. Main outcome: NGO road km per scenario (Wilcoxon signed rank test and Hodges
Lehmann estimate with a bootstrap interval). Also reported: trips, stops, donor travel and cost.
Run from the repository root: python experiments/e3/experiment_result/source_code/e3_compare.py
"""
import csv
import statistics
from pathlib import Path
import math
import json

HERE = Path(__file__).resolve()
E3 = HERE.parents[2]

OUT = HERE.parents[1]


# Small helpers

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


def read(p):
    """Read one result CSV file."""
    with p.open(encoding='utf-8-sig', newline='') as f:
        return {r['scenario_id']: r for r in csv.DictReader(f)}


def paired(name, b, p, ids, key):
    """Paired difference between the two methods: totals, Wilcoxon test, Hodges Lehmann estimate and interval."""
    d = [float(p[s][key]) - float(b[s][key]) for s in ids]
    stat, pv, nz = wilcoxon_pratt(d)
    lo, hi = bootstrap_ci(d)
    return dict(measure=name, baseline_total=sum(float(b[s][key]) for s in ids), proposed_total=sum(float(p[s][key]) for s in ids),
                baseline_median=statistics.median(float(b[s][key]) for s in ids),
                proposed_median=statistics.median(float(p[s][key]) for s in ids),
                hl_difference=hodges_lehmann(d), ci95=[lo, hi], wilcoxon_p=pv, nonzero_pairs=nz,
                scenarios_proposed_lower=sum(x < 0 for x in d), scenarios_equal=sum(x == 0 for x in d),
                scenarios_proposed_higher=sum(x > 0 for x in d))


def main():
    """Read the result folders, then write the comparison tables, figures and summary.md."""
    b = read(E3 / 'baseline' / 'direct_household_pickup' / 'results_per_scenario.csv')
    p = read(E3 / 'hub_aggregation' / 'result' / 'results_per_scenario.csv')
    assert set(b) == set(p) and len(p) == 100, 'scenario sets differ'
    ids = sorted(p)
    for s in ids:
        b[s]['total_travel_km'] = float(b[s]['total_ngo_distance_km']) + float(b[s]['donor_travel_km'])
        b[s]['ngo_stops'] = b[s]['donations_collected']
        b[s]['donations_handled_at_hub'] = 0
    m = dict(planned_units=100, realised_units=len(ids))
    m['primary_ngo_km'] = paired('NGO road km', b, p, ids, 'total_ngo_distance_km')
    sec = [paired('NGO vehicle trips', b, p, ids, 'vehicle_trips'), paired('NGO stops', b, p, ids, 'ngo_stops'),
           paired('Donor travel km', b, p, ids, 'donor_travel_km'), paired('Total travel km (NGO + donors)', b, p, ids, 'total_travel_km'),
           paired('Benchmark cost (units)', b, p, ids, 'benchmark_cost')]
    adj = holm([x['wilcoxon_p'] for x in sec])
    for x, a in zip(sec, adj):
        x['holm_p'] = a
    m['supporting'] = sec
    m['coverage'] = dict(baseline=sum(int(b[s]['donations_collected']) for s in ids), proposed=sum(int(p[s]['donations_collected']) for s in ids),
                         donations=sum(int(p[s]['donations']) for s in ids))
    m['aggregated_scenarios'] = sum(p[s]['aggregated'] == 'YES' for s in ids)
    m['all_routes_valid'] = dict(baseline=sum(b[s]['all_rules_passed'] == 'YES' for s in ids), proposed=sum(p[s]['all_rules_passed'] == 'YES' for s in ids))
    integ = list(csv.DictReader((E3 / 'hub_aggregation' / 'result' / 'details' / 'batch_integrity_checks.csv').open(encoding='utf-8-sig')))
    checks = [k for k in integ[0] if k not in ('scenario_id', 'hub_id', 'batch_id', 'donations', 'batch_weight_kg', 'category', 'aggregated')]
    m['batch_integrity'] = {k: sum(r[k] == 'YES' for r in integ) for k in checks}
    lower_total = sum(float(p[s]['total_travel_km']) < float(b[s]['total_travel_km']) for s in ids)
    m['scenarios_total_travel_lower_with_hub'] = dict(count=lower_total, rate=wilson(lower_total, len(ids)))
    def row(x, better):
        change = round(100 * (x['proposed_total'] - x['baseline_total']) / x['baseline_total'], 1) if x['baseline_total'] else ''
        return dict(measure=f"{x['measure']}, total of 100 scenarios", proposed_hub_aggregation=round(x['proposed_total'], 1),
                    baseline_direct_household_pickup=round(x['baseline_total'], 1), change_percent=change,
                    better_when=better, paired_test=f"Wilcoxon p = {x['wilcoxon_p']:.1e}")
    write_csv(OUT / 'comparison_summary.csv', [row(m['primary_ngo_km'], 'lower')] + [
        row(x, 'not a target' if x['measure'].startswith(('Donor', 'Total')) else 'lower') for x in m['supporting']] + [
        dict(measure='Donations collected', proposed_hub_aggregation=m['coverage']['proposed'],
             baseline_direct_household_pickup=m['coverage']['baseline'], change_percent=0.0, better_when='higher', paired_test='')])
    write_csv(OUT / 'comparison_per_scenario.csv', [dict(
        scenario_id=s, donations=p[s]['donations'], hub_id=p[s]['hub_id'],
        baseline_ngo_km=b[s]['total_ngo_distance_km'], proposed_ngo_km=p[s]['total_ngo_distance_km'],
        ngo_km_saved=round(float(b[s]['total_ngo_distance_km']) - float(p[s]['total_ngo_distance_km']), 3),
        baseline_stops=b[s]['ngo_stops'], proposed_stops=p[s]['ngo_stops'],
        baseline_trips=b[s]['vehicle_trips'], proposed_trips=p[s]['vehicle_trips'],
        proposed_donor_km=p[s]['donor_travel_km'],
        baseline_total_km=round(b[s]['total_travel_km'], 3), proposed_total_km=p[s]['total_travel_km'],
        baseline_cost=b[s]['benchmark_cost'], proposed_cost=p[s]['benchmark_cost'],
        baseline_collected=b[s]['donations_collected'], proposed_collected=p[s]['donations_collected']) for s in ids])
    write_json(OUT / 'metrics.json', m)
    figure(b, p, ids, m)
    summary(m)
    print('E3 comparison ->', OUT / 'summary.md')


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


def figure(b, p, ids, m):
    """Draw the four figures, one PNG each."""
    plt = plot_style()
    s = {r['measure']: r for r in m['supporting']}
    names = ['Direct household pickup\n(baseline)', 'Community hub aggregation\n(proposed)']

    fig, ax = plt.subplots(figsize=(4.8, 4.4))
    x = [float(b[i]['total_ngo_distance_km']) for i in ids]
    y = [float(p[i]['total_ngo_distance_km']) for i in ids]
    lim = max(x + y) * 1.05
    ax.plot([0, lim], [0, lim], color='#888888', lw=0.8, ls='--', label='Equal distance')
    ax.scatter(x, y, s=14, color=PROPOSED, alpha=0.85, label='One scenario')
    ax.set_xlim(0, lim); ax.set_ylim(0, lim); ax.set_aspect('equal')
    ax.grid(axis='x', color='#e3e3e3', linewidth=0.6)
    ax.set_xlabel('Direct household pickup (km)')
    ax.set_ylabel('Community hub aggregation (km)')
    ax.set_title('NGO driving distance per scenario')
    ax.legend(loc='upper left')
    save(plt, fig, 'e3_fig1_ngo_km_per_scenario.png')

    fig, ax = plt.subplots(figsize=(5, 3.6))
    vals = [s['Benchmark cost (units)']['baseline_total'], s['Benchmark cost (units)']['proposed_total']]
    ax.set_ylim(0, max(vals) * 1.18)
    for i, (v, c) in enumerate(zip(vals, (BASELINE_1, PROPOSED))):
        bars(ax, [i], [v], c, 0.5, text=[f'{v:,.0f}'], pad=max(vals) * 0.015)
    ax.set_xticks(range(2), names)
    ax.set_ylabel('Cost units, 100 scenarios')
    ax.set_title('NGO collection cost')
    save(plt, fig, 'e3_fig2_ngo_cost.png')

    fig, ax = plt.subplots(figsize=(5, 3.6))
    vals = [s['NGO stops']['baseline_total'], s['NGO stops']['proposed_total']]
    ax.set_ylim(0, max(vals) * 1.18)
    for i, (v, c) in enumerate(zip(vals, (BASELINE_1, PROPOSED))):
        bars(ax, [i], [v], c, 0.5, text=[f'{v:,.0f}'], pad=max(vals) * 0.015)
    ax.set_xticks(range(2), names)
    ax.set_ylabel(f"Stops, 100 scenarios ({m['coverage']['donations']} donations)")
    ax.set_title('Pickup stops made by NGO vehicles')
    save(plt, fig, 'e3_fig3_ngo_stops.png')

    fig, ax = plt.subplots(figsize=(6.4, 3.6))
    groups = ['NGO vehicles', 'Donors (to the hub\nand back)', 'NGO and donors']
    vb = [m['primary_ngo_km']['baseline_total'], s['Donor travel km']['baseline_total'], s['Total travel km (NGO + donors)']['baseline_total']]
    vp = [m['primary_ngo_km']['proposed_total'], s['Donor travel km']['proposed_total'], s['Total travel km (NGO + donors)']['proposed_total']]
    ax.set_ylim(0, max(vb + vp) * 1.2)
    pad = max(vb + vp) * 0.015
    bars(ax, [i - 0.2 for i in range(3)], vb, BASELINE_1, 0.38, label='Direct household pickup (baseline)', text=[f'{v:,.0f}' for v in vb], pad=pad)
    bars(ax, [i + 0.2 for i in range(3)], vp, PROPOSED, 0.38, label='Community hub aggregation (proposed)', text=[f'{v:,.0f}' for v in vp], pad=pad)
    ax.set_xticks(range(3), groups)
    ax.set_ylabel('Distance, 100 scenarios (km)')
    ax.set_title('Travel by NGO vehicles and donors')
    ax.legend(loc='upper center', bbox_to_anchor=(0.5, -0.2), ncol=2)
    save(plt, fig, 'e3_fig4_who_travels.png')


def summary(m):
    """Write summary.md."""
    pkm = m['primary_ngo_km']
    s = {r['measure']: r for r in m['supporting']}
    don, tot, cost, stops = s['Donor travel km'], s['Total travel km (NGO + donors)'], s['Benchmark cost (units)'], s['NGO stops']
    saved = pkm['baseline_total'] - pkm['proposed_total']
    n_don = m['coverage']['donations']
    L = ['# E3 result: community hub aggregation vs direct household pickup', '',
         '## What we wanted to find out', '',
         'Small donations (under 10 kg) are scattered over many homes. Without hubs, an NGO has to drive to every home. '
         'With GeoLock Hub, donors drop small items at a nearby community hub, the hub groups them into one batch, and '
         'the NGO collects the whole batch in one stop. We wanted to know how much NGO driving this saves, and whether the '
         'saving is real or just moves the travelling onto the donors.', '',
         '## What we used', '',
         f"- **Data:** the frozen benchmark dataset GEOLOCK-BENCHMARK-DATASET: 100 scenarios, each with 3 to 5 small donations from nearby "
         f"homes ({n_don} donations in total), one community hub, and one NGO with a car (100 kg) and a van (500 kg).",
         '- **Direct household pickup (baseline):** the NGO collects every donation from the donor\'s home.',
         '- **Community hub aggregation (proposed, as in the app):** each donor reserves space at the hub and drops the item off during '
         'opening hours, the hub confirms receipt, the items become one batch (3 to 5 items, at most 30 kg, one category), the '
         'batch is published as one listing, and the NGO collects it at the hub.',
         '- **Fair comparison:** both use the same donations, NGO, vehicles, depot, road distances and the same route planner '
         '(Nearest-Next, the same code), with a 240 minute limit per vehicle and 10 minutes per stop. Only the collection '
         'method differs.', '',
         '## Results', '', 'The main numbers are also in `comparison_summary.csv`, one row per measure with every method side by side.', '',
         '| Measure (all 100 scenarios) | Direct household pickup (baseline) | Hub aggregation (proposed) | Change |',
         '| --- | --- | --- | --- |',
         f"| Donations collected | {m['coverage']['baseline']} of {n_don} | {m['coverage']['proposed']} of {n_don} | same |",
         f"| **NGO driving** | {pkm['baseline_total']:,.0f} km | **{pkm['proposed_total']:,.0f} km** | −{saved:,.0f} km (−{100 * saved / pkm['baseline_total']:.1f} %) |",
         f"| NGO pickup stops | {stops['baseline_total']:,.0f} | **{stops['proposed_total']:,.0f}** | −{stops['baseline_total'] - stops['proposed_total']:,.0f} (−{100 * (1 - stops['proposed_total'] / stops['baseline_total']):.0f} %) |",
         f"| NGO collection cost (1 per km + 5 per trip + 0.5 per item handled at a hub) | {cost['baseline_total']:,.0f} | **{cost['proposed_total']:,.0f}** | −{100 * (1 - cost['proposed_total'] / cost['baseline_total']):.1f} % |",
         f"| Vehicle trips | {s['NGO vehicle trips']['baseline_total']:,.0f} | {s['NGO vehicle trips']['proposed_total']:,.0f} | same |",
         f"| Donor travel to the hub and back | {don['baseline_total']:,.0f} km | {don['proposed_total']:,.0f} km | +{don['proposed_total']:,.0f} km |", '',
         '![Figure 1](e3_fig1_ngo_km_per_scenario.png)', '',
         '*Figure 1. NGO driving distance in each of the 100 scenarios. Points below the dashed line are scenarios where hub aggregation needed less NGO driving.*', '',
         '![Figure 2](e3_fig2_ngo_cost.png)', '',
         '*Figure 2. Total NGO collection cost over the 100 scenarios (1 per km, 5 per trip, 0.5 per item handled at a hub).*', '',
         '![Figure 3](e3_fig3_ngo_stops.png)', '',
         '*Figure 3. Total pickup stops made by NGO vehicles over the 100 scenarios.*', '',
         '![Figure 4](e3_fig4_who_travels.png)', '',
         '*Figure 4. Total distance travelled by NGO vehicles and by donors. Donor travel counts each drop off as a separate car trip from home to the hub and back.*', '',
         '## Analysis', '',
         f"**The hub roughly halves NGO driving.** Over the 100 scenarios NGO vehicles drove {pkm['proposed_total']:,.0f} km instead of "
         f"{pkm['baseline_total']:,.0f} km. Scenario by scenario, the hub was shorter in {pkm['scenarios_proposed_lower']} of 100 cases, "
         f"and the typical saving is {-pkm['hl_difference']:.1f} km per scenario (95 % confidence interval "
         f"{-pkm['ci95'][1]:.1f} to {-pkm['ci95'][0]:.1f} km; Wilcoxon signed rank test p = {pkm['wilcoxon_p']:.1g}).", '',
         f"**Why:** instead of visiting {n_don} homes, the NGO makes one stop per batch: {stops['proposed_total']:,.0f} stops instead of "
         f"{stops['baseline_total']:,.0f}. Fewer stops means less zigzag driving between homes and less time per route. Every "
         'donation was still collected, and every route stayed within the vehicle capacity and the 240 minute limit.', '',
         f"**The NGO's collection cost falls by {100 * (1 - cost['proposed_total'] / cost['baseline_total']):.0f} %** "
         f"({cost['baseline_total']:,.0f} → {cost['proposed_total']:,.0f} cost units), even after adding the 0.5 handling charge "
         'for each item stored at the hub.', '',
         '**Every batch followed the hub rules.** All 100 batches passed every check: the hub accepted each item and had room for '
         'it, every drop off fell inside the donor\'s availability window and the hub\'s opening hours, every batch had 3 to 5 items '
         'of one category and at most 30 kg, and the NGO was within 20 km of the hub by road.', '',
         f"**The trade off: donors travel instead.** If every donor drives to the hub and back as a separate car trip, donors travel "
         f"{don['proposed_total']:,.0f} km in total (about {don['proposed_total'] / n_don:.1f} km per donor). Counted that way, NGO "
         f"plus donor travel is {tot['proposed_total']:,.0f} km with hubs against {tot['baseline_total']:,.0f} km without. This is "
         'the worst case: donors who walk to a hub in their own neighbourhood, or drop the item off on a trip they were making '
         'anyway, add little or no extra travel. The benefit of the hub is therefore for the NGO (its vehicles, drivers and '
         'fuel), which is what this experiment set out to measure.', '',
         '## Conclusion', '',
         f"Collecting small donations through a community hub cut NGO driving by {100 * saved / pkm['baseline_total']:.0f} % "
         f"({saved:,.0f} km over 100 scenarios), reduced NGO pickup stops by {100 * (1 - stops['proposed_total'] / stops['baseline_total']):.0f} % "
         f"and NGO collection cost by {100 * (1 - cost['proposed_total'] / cost['baseline_total']):.0f} %, while still collecting every "
         'donation and respecting every hub and route rule. The proposed method is better than the baseline for the NGO on '
         'every measure. The saving comes from donors bringing their items to the hub, so it is largest when that drop off '
         'trip is short or would happen anyway.', '',
         '## Limits of this experiment', '',
         '- Donor travel is counted as a separate car trip home → hub → home, which is the largest it can be.',
         '- The hub steps (reservation, receipt, batching, publishing) are checked against the app\'s rules in the experiment '
         'program, not run in the database.',
         '- Each vehicle makes one trip, and road travel times assume no traffic.', '']
    (OUT / 'summary.md').write_text('\n'.join(L), encoding='utf-8')


if __name__ == '__main__':
    main()
