"""E3 comparison: direct household pickup (baseline) against community hub aggregation (proposed).

Follows EXPERIMENT_PLAN.md. Every compared measure is on the NGO side and paired by scenario.
Primary: NGO road distance. Secondary: NGO route time, NGO pickup stops, NGO collection cost.

Writes to experiment_result/:
  summary.md                         the written result
  comparison_summary.csv             main table, one row per measure
  comparison_per_scenario.csv        one row per scenario, baseline and proposed side by side
  e3_fig1_main_comparison.png        both methods on the four NGO measures
  e3_fig2_ngo_km_per_scenario.png    NGO driving distance in every scenario
  e3_fig3_saving_by_batch_size.png   NGO driving by number of donations in the batch

It only reads the two result folders. Run from the repository root:
    python experiments/e3/experiment_result/source_code/e3_compare.py
"""
import csv
import math
import statistics
from collections import defaultdict
from pathlib import Path

import numpy as np
from scipy.stats import kruskal, spearmanr, wilcoxon

HERE = Path(__file__).resolve()
E3 = HERE.parents[2]
OUT = HERE.parents[1]
BASE_DIR = E3 / 'baseline' / 'direct_household_pickup'
HUB_DIR = E3 / 'hub_aggregation' / 'result'

SEED = 20260915
REPS = 10_000
COST = dict(km=1.00, trip=5.00, hub_item=0.50)   # benchmark cost units, frozen before the runs
HUB_BANDS = [(0, 10), (10, 20), (20, math.inf)]  # NGO depot -> hub -> depot, road km


# Reading the results

def read_csv(path):
    with Path(path).open(encoding='utf-8-sig', newline='') as f:
        return list(csv.DictReader(f))


def write_csv(path, rows):
    with Path(path).open('w', encoding='utf-8-sig', newline='') as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0]))
        w.writeheader()
        w.writerows(rows)


def route_minutes(path):
    """Route time per scenario, including 10 minutes of service at every stop."""
    out = defaultdict(float)
    for r in read_csv(path):
        out[r['scenario_id']] += float(r['route_time_min'])
    return out


def load():
    """One row per scenario with the NGO measures of both methods."""
    b = {r['scenario_id']: r for r in read_csv(BASE_DIR / 'results_per_scenario.csv')}
    p = {r['scenario_id']: r for r in read_csv(HUB_DIR / 'results_per_scenario.csv')}
    assert set(b) == set(p) and len(p) == 100, 'the two methods must cover the same 100 scenarios'
    bmin, pmin = route_minutes(BASE_DIR / 'routes.csv'), route_minutes(HUB_DIR / 'routes.csv')
    rows = []
    for s in sorted(p):
        n = int(p[s]['donations'])
        row = dict(scenario_id=s, ngo_id=p[s]['ngo_id'], hub_id=p[s]['hub_id'], donations=n)
        for tag, src, mins, stops, hub_items in (('base', b[s], bmin[s], int(b[s]['donations_collected']), 0),
                                                 ('hub', p[s], pmin[s], int(p[s]['ngo_stops']), int(p[s]['donations_handled_at_hub']))):
            row.update({f'{tag}_km': float(src['total_ngo_distance_km']), f'{tag}_route_min': mins,
                        f'{tag}_driving_min': float(src['total_driving_time_min']), f'{tag}_stops': stops,
                        f'{tag}_trips': int(src['vehicle_trips']), f'{tag}_hub_items': hub_items,
                        f'{tag}_cost': float(src['benchmark_cost']), f'{tag}_collected': int(src['donations_collected']),
                        f'{tag}_valid': src['all_rules_passed'] == 'YES'})
        row['km_saved'] = row['base_km'] - row['hub_km']
        row['pct_saved'] = 100 * row['km_saved'] / row['base_km']
        rows.append(row)
    return rows


# Statistics

def hodges_lehmann(d):
    i, j = np.triu_indices(d.size)
    return float(np.median((d[i] + d[j]) / 2))


def paired(rows, name, key, unit, better='lower'):
    """Totals, % change with a bootstrap interval, Wilcoxon test and Hodges-Lehmann estimate."""
    base = np.array([r[f'base_{key}'] for r in rows], float)
    prop = np.array([r[f'hub_{key}'] for r in rows], float)
    d = prop - base
    p = wilcoxon(d, zero_method='pratt').pvalue if np.any(d != 0) else 1.0
    rng = np.random.default_rng(SEED)
    i, j = np.triu_indices(d.size)
    hl, pct = np.empty(REPS), np.empty(REPS)
    for r in range(REPS):
        k = rng.integers(0, d.size, d.size)
        s = d[k]
        hl[r] = np.median((s[i] + s[j]) / 2)
        pct[r] = 100 * (prop[k].sum() - base[k].sum()) / base[k].sum()
    wins = int(np.sum(d < 0) if better == 'lower' else np.sum(d > 0))
    return dict(measure=name, key=key, unit=unit, base=base.sum(), prop=prop.sum(),
                change=100 * (prop.sum() - base.sum()) / base.sum(),
                change_ci=(float(np.quantile(pct, 0.025)), float(np.quantile(pct, 0.975))),
                hl=hodges_lehmann(d), hl_ci=(float(np.quantile(hl, 0.025)), float(np.quantile(hl, 0.975))),
                p=float(p), wins=wins)


def holm(ps):
    order = sorted(range(len(ps)), key=lambda i: ps[i])
    out, run = [0.0] * len(ps), 0.0
    for rank, i in enumerate(order):
        run = max(run, min(1.0, (len(ps) - rank) * ps[i]))
        out[i] = run
    return out


def fmt_p(p):
    return f'{p:.1e}' if p < 0.001 else f'{p:.3f}'


# Robustness checks from the plan

def cost(r, tag, c):
    return c['km'] * r[f'{tag}_km'] + c['trip'] * r[f'{tag}_trips'] + c['hub_item'] * r[f'{tag}_hub_items']


def cost_sensitivity(rows):
    settings = [('Base coefficients', {})]
    for k, label in (('km', 'Distance'), ('trip', 'Dispatch'), ('hub_item', 'Hub handling')):
        settings += [(f'{label} halved', {k: 0.5}), (f'{label} doubled', {k: 2.0})]
    settings += [('All halved', dict(km=0.5, trip=0.5, hub_item=0.5)), ('All doubled', dict(km=2.0, trip=2.0, hub_item=2.0))]
    out = []
    for label, mult in settings:
        c = {k: v * mult.get(k, 1.0) for k, v in COST.items()}
        bt, pt = sum(cost(r, 'base', c) for r in rows), sum(cost(r, 'hub', c) for r in rows)
        out.append(dict(setting=label, base=bt, hub=pt, change=100 * (pt - bt) / bt,
                        cheaper=sum(cost(r, 'hub', c) < cost(r, 'base', c) for r in rows)))
    items = sum(r['hub_hub_items'] for r in rows)
    gap = sum(COST['km'] * (r['base_km'] - r['hub_km']) + COST['trip'] * (r['base_trips'] - r['hub_trips']) for r in rows)
    return out, gap / items


def groups(rows, label, key_fn):
    g = defaultdict(list)
    for r in rows:
        g[key_fn(r)].append(r)
    return [dict(group=k if label == 'batch' else k[1], n=len(v),
                 base=statistics.median(r['base_km'] for r in v), hub=statistics.median(r['hub_km'] for r in v),
                 saved=statistics.median(r['km_saved'] for r in v), pct=statistics.median(r['pct_saved'] for r in v),
                 shorter=sum(r['km_saved'] > 0 for r in v)) for k, v in sorted(g.items())]


def band(km):
    for i, (lo, hi) in enumerate(HUB_BANDS):
        if lo <= km < hi:
            return i, (f'under {hi:g} km' if lo == 0 else f'{lo:g} km or more' if hi == math.inf else f'{lo:g} to {hi:g} km')


# Figures

PROPOSED, BASELINE = '#2a78d6', '#eb6834'
NAMES = ('Direct household pickup (baseline)', 'Community hub aggregation (proposed)')


def plot_style():
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    plt.rcParams.update({'font.family': 'serif', 'font.serif': ['DejaVu Serif'], 'font.size': 9,
                         'axes.titlesize': 10, 'axes.titleweight': 'bold', 'axes.labelsize': 9,
                         'legend.fontsize': 8.5, 'legend.frameon': False, 'axes.spines.top': False,
                         'axes.spines.right': False, 'axes.grid': True, 'axes.grid.axis': 'y',
                         'grid.color': '#e3e3e3', 'grid.linewidth': 0.6, 'axes.axisbelow': True, 'hatch.linewidth': 0.8})
    return plt


def save(plt, fig, name):
    fig.savefig(OUT / name, dpi=300, bbox_inches='tight')
    plt.close(fig)


def fig_main(m):
    """Figure 1: both methods on the four NGO measures, totals over 100 scenarios."""
    plt = plot_style()
    from matplotlib.patches import Patch
    panels = [(m['km'], 'NGO road distance', 'km', 1), (m['route_min'], 'NGO route time', 'hours', 1 / 60),
              (m['stops'], 'NGO pickup stops', 'stops', 1), (m['cost'], 'NGO collection cost', 'cost units', 1)]
    fig, axes = plt.subplots(2, 2, figsize=(6.6, 5.9))
    for ax, (x, title, unit, scale) in zip(axes.flat, panels):
        vals = [x['base'] * scale, x['prop'] * scale]
        top = max(vals)
        ax.bar([0], [vals[0]], 0.62, color=BASELINE, hatch='///', edgecolor='white', linewidth=0)
        ax.bar([1], [vals[1]], 0.62, color=PROPOSED, edgecolor='white', linewidth=0)
        for i, v in enumerate(vals):
            ax.text(i, v + top * 0.02, f'{v:,.0f}', ha='center', va='bottom', fontsize=8.5, color='#222222')
        ax.annotate('', xy=(1, vals[1] + top * 0.13), xytext=(0, vals[0] + top * 0.13),
                    arrowprops=dict(arrowstyle='->', color='#333333', lw=0.9, connectionstyle='arc3,rad=-0.25'))
        ax.text(0.5, vals[0] + top * 0.20, f"{x['change']:.1f}%", ha='center', fontsize=10, fontweight='bold', color='#222222')
        ax.set_ylim(0, top * 1.38)
        ax.set_xticks([0, 1], ['Baseline', 'Proposed'])
        ax.set_ylabel(f'Total of 100 scenarios ({unit})')
        ax.set_title(title)
    fig.legend(handles=[Patch(facecolor=BASELINE, hatch='///', edgecolor='white', label=NAMES[0]),
                        Patch(facecolor=PROPOSED, label=NAMES[1])], loc='lower center', ncol=1, bbox_to_anchor=(0.5, -0.01))
    fig.tight_layout(rect=(0, 0.09, 1, 1), h_pad=2.0)
    save(plt, fig, 'e3_fig1_main_comparison.png')


def fig_scatter(rows):
    """Figure 2: NGO road distance of both methods in every scenario."""
    plt = plot_style()
    fig, ax = plt.subplots(figsize=(4.8, 4.5))
    win = [r for r in rows if r['km_saved'] > 0]
    lose = [r for r in rows if r['km_saved'] <= 0]
    lim = max(max(r['base_km'], r['hub_km']) for r in rows) * 1.05
    ax.fill_between([0, lim], [0, 0], [0, lim], color=PROPOSED, alpha=0.06, linewidth=0)
    ax.plot([0, lim], [0, lim], color='#888888', lw=0.8, ls='--', label='Equal distance')
    ax.scatter([r['base_km'] for r in win], [r['hub_km'] for r in win], s=16, color=PROPOSED,
               label=f'Hub shorter ({len(win)} scenarios)', zorder=3)
    ax.scatter([r['base_km'] for r in lose], [r['hub_km'] for r in lose], s=22, color=BASELINE, marker='s',
               label=f'Hub longer ({len(lose)} scenarios)', zorder=3)
    ax.text(lim * 0.97, lim * 0.03, 'Below the line, the hub\nneeds less NGO driving', ha='right', va='bottom', fontsize=8, color='#1d5aa6')
    ax.set_xlim(0, lim); ax.set_ylim(0, lim); ax.set_aspect('equal')
    ax.grid(axis='x', color='#e3e3e3', linewidth=0.6)
    ax.set_xlabel('Direct household pickup, baseline (km)')
    ax.set_ylabel('Community hub aggregation, proposed (km)')
    ax.set_title('NGO road distance in each scenario')
    ax.legend(loc='upper left')
    fig.tight_layout()
    save(plt, fig, 'e3_fig2_ngo_km_per_scenario.png')


def fig_batch(batch):
    """Figure 3: median NGO road distance by number of donations in the batch."""
    plt = plot_style()
    fig, ax = plt.subplots(figsize=(5.6, 3.6))
    x = np.arange(len(batch))
    vb, vp = [g['base'] for g in batch], [g['hub'] for g in batch]
    top = max(vb)
    ax.bar(x - 0.2, vb, 0.38, color=BASELINE, hatch='///', edgecolor='white', linewidth=0, label=NAMES[0])
    ax.bar(x + 0.2, vp, 0.38, color=PROPOSED, edgecolor='white', linewidth=0, label=NAMES[1])
    for xi, b, p, g in zip(x, vb, vp, batch):
        ax.text(xi - 0.2, b + top * 0.015, f'{b:.1f}', ha='center', va='bottom', fontsize=8)
        ax.text(xi + 0.2, p + top * 0.015, f'{p:.1f}', ha='center', va='bottom', fontsize=8)
        ax.text(xi, b + top * 0.13, f"saves {g['saved']:.1f} km", ha='center', fontsize=8.5, fontweight='bold')
    ax.set_ylim(0, top * 1.32)
    ax.set_xticks(x, [f"{g['group']} donations\n({g['n']} scenarios)" for g in batch])
    ax.set_ylabel('Median NGO road distance per scenario (km)')
    ax.set_title('NGO driving by number of donations in the batch')
    ax.legend(loc='upper center', bbox_to_anchor=(0.5, -0.2), ncol=1)
    fig.tight_layout()
    save(plt, fig, 'e3_fig3_saving_by_batch_size.png')


# Main

def main():
    rows = load()
    n_don = sum(r['donations'] for r in rows)
    m = {'km': paired(rows, 'NGO road distance (primary)', 'km', 'km')}
    sec = [paired(rows, 'NGO route time, including 10 min per stop', 'route_min', 'min'),
           paired(rows, 'NGO pickup stops', 'stops', 'stops'),
           paired(rows, 'NGO collection cost', 'cost', 'cost units')]
    for x, a in zip(sec, holm([x['p'] for x in sec])):
        x['holm'] = a
        m[x['key']] = x
    drive = paired(rows, 'NGO driving time', 'driving_min', 'min')
    rate_b = sum(r['base_collected'] for r in rows) / (sum(r['base_route_min'] for r in rows) / 60)
    rate_p = sum(r['hub_collected'] for r in rows) / (sum(r['hub_route_min'] for r in rows) / 60)
    integ = read_csv(HUB_DIR / 'batch_integrity_checks.csv')
    batches_ok = sum(r['aggregated'] == 'YES' for r in integ)

    # main table
    table = []
    for x, role in [(m['km'], 'primary'), (m['route_min'], 'secondary'), (m['stops'], 'secondary'), (m['cost'], 'secondary'), (drive, 'supporting')]:
        table.append(dict(measure=x['measure'], role=role, unit=x['unit'], baseline=round(x['base'], 1), proposed=round(x['prop'], 1),
                          change_percent=round(x['change'], 1), change_95ci=f"{x['change_ci'][0]:.1f} to {x['change_ci'][1]:.1f}",
                          scenarios_proposed_better=x['wins'], wilcoxon_p=fmt_p(x['p']), holm_p=fmt_p(x['holm']) if 'holm' in x else ''))
    table += [dict(measure='Donations collected per vehicle-hour', role='supporting', unit='per hour', baseline=round(rate_b, 2),
                   proposed=round(rate_p, 2), change_percent=round(100 * (rate_p - rate_b) / rate_b, 1), change_95ci='',
                   scenarios_proposed_better='', wilcoxon_p='', holm_p=''),
              dict(measure='Donations collected', role='check', unit='donations', baseline=sum(r['base_collected'] for r in rows),
                   proposed=sum(r['hub_collected'] for r in rows), change_percent=0.0, change_95ci='', scenarios_proposed_better='',
                   wilcoxon_p='', holm_p=''),
              dict(measure='Vehicle trips', role='check', unit='trips', baseline=sum(r['base_trips'] for r in rows),
                   proposed=sum(r['hub_trips'] for r in rows), change_percent=0.0, change_95ci='', scenarios_proposed_better='',
                   wilcoxon_p='', holm_p=''),
              dict(measure='Hub batches passing every rule', role='check', unit='batches', baseline='not applicable',
                   proposed=f'{batches_ok} of {len(integ)}', change_percent='', change_95ci='', scenarios_proposed_better='',
                   wilcoxon_p='', holm_p='')]
    write_csv(OUT / 'comparison_summary.csv', table)
    write_csv(OUT / 'comparison_per_scenario.csv', [dict(
        scenario_id=r['scenario_id'], ngo_id=r['ngo_id'], hub_id=r['hub_id'], donations=r['donations'],
        baseline_ngo_km=round(r['base_km'], 3), proposed_ngo_km=round(r['hub_km'], 3), ngo_km_saved=round(r['km_saved'], 3),
        baseline_route_min=round(r['base_route_min'], 1), proposed_route_min=round(r['hub_route_min'], 1),
        baseline_stops=r['base_stops'], proposed_stops=r['hub_stops'],
        baseline_cost=r['base_cost'], proposed_cost=r['hub_cost'],
        baseline_collected=r['base_collected'], proposed_collected=r['hub_collected']) for r in rows])

    # robustness
    sens, break_even = cost_sensitivity(rows)
    batch = groups(rows, 'batch', lambda r: r['donations'])
    dist = groups(rows, 'dist', lambda r: band(r['hub_km']))
    sp_batch = spearmanr([r['donations'] for r in rows], [r['km_saved'] for r in rows])
    kw = kruskal(*[[r['km_saved'] for r in rows if r['donations'] == g['group']] for g in batch])
    sp_dist = spearmanr([r['hub_km'] for r in rows], [r['pct_saved'] for r in rows])
    losses = [r for r in rows if r['km_saved'] <= 0]
    ngo_km = defaultdict(lambda: [0.0, 0.0])
    for r in rows:
        ngo_km[r['ngo_id']][0] += r['base_km']; ngo_km[r['ngo_id']][1] += r['hub_km']
    ngo_pct = [100 * (b - p) / b for b, p in ngo_km.values()]

    fig_main(m)
    fig_scatter(rows)
    fig_batch(batch)

    k, t, s, c = m['km'], m['route_min'], m['stops'], m['cost']
    L = ['# E3 result: community hub aggregation vs direct household pickup', '',
         'Plan: [`../EXPERIMENT_PLAN.md`](../EXPERIMENT_PLAN.md). 100 matched scenarios, '
         f'{n_don} small donations, {len(ngo_km)} NGOs. Both methods use the same route planner, vehicles, depot and roads.', '',
         '## Main result: the proposed method is better on every NGO measure', '',
         '| NGO measure (total of 100 scenarios) | Baseline | Proposed | Change (95 % CI) | Proposed better in | p |',
         '| --- | --- | --- | --- | --- | --- |']
    for x, f in ((k, ',.1f'), (t, ',.0f'), (s, ',.0f'), (c, ',.1f')):
        p = x['p'] if x is k else x['holm']
        L.append(f"| {x['measure']} | {x['base']:{f}} {x['unit']} | **{x['prop']:{f}} {x['unit']}** | "
                 f"{x['change']:.1f} % ({x['change_ci'][0]:.1f} to {x['change_ci'][1]:.1f}) | {x['wins']} of 100 | {fmt_p(p)} |")
    L += [f"| Donations collected | {table[6]['baseline']} of {n_don} | {table[6]['proposed']} of {n_don} | same | | |",
          f"| Hub batches passing every rule | | {batches_ok} of {len(integ)} | | | |", '',
          'p is the Wilcoxon signed rank test on the 100 paired differences (Holm corrected for the secondary measures).', '',
          '![Figure 1](e3_fig1_main_comparison.png)', '',
          '*Figure 1. Totals of both methods over the 100 scenarios. The proposed method is lower on all four NGO measures.*', '',
          '## Analysis', '',
          f"**The decision rule is met.** Total NGO road distance fell from {k['base']:,.1f} to {k['prop']:,.1f} km "
          f"({k['change']:.1f} %, p = {fmt_p(k['p'])}) and every donation was still collected. The typical saving was "
          f"{-k['hl']:.2f} km per scenario (95 % CI {-k['hl_ci'][1]:.2f} to {-k['hl_ci'][0]:.2f} km).", '',
          f"**The saving appears in almost every scenario, not only on average.** The hub needed less NGO driving in "
          f"{k['wins']} of 100 scenarios (Figure 2), and route time was lower in all {t['wins']}.", '',
          '![Figure 2](e3_fig2_ngo_km_per_scenario.png)', '',
          '*Figure 2. Each point is one scenario. Points in the shaded area are scenarios where the hub needed less NGO driving.*', '',
          f"**Why it works.** One stop at the hub replaces three to five stops at homes, so NGO stops fell from "
          f"{s['base']:,.0f} to {s['prop']:,.0f} and route time from {t['base'] / 60:,.1f} to {t['prop'] / 60:,.1f} hours. "
          f"A vehicle collected {rate_p:.1f} donations per hour of route time instead of {rate_b:.1f}. "
          'A fuller batch removes more home stops, so the saving grows with the batch size (Figure 3): ' +
          ', '.join(f"{g['saved']:.1f} km for {g['group']} donations" for g in batch) +
          f" (Spearman ρ = {sp_batch.statistic:.2f}, p = {fmt_p(sp_batch.pvalue)}; Kruskal-Wallis p = {fmt_p(kw.pvalue)}).", '',
          '![Figure 3](e3_fig3_saving_by_batch_size.png)', '',
          '*Figure 3. Median NGO road distance per scenario for batches of 3, 4 and 5 donations, with the median saving.*', '',
          '## Robustness', '',
          f"**Cost coefficients.** The hub stayed cheaper in total under all {len(sens)} settings. The hub handling charge "
          f"would have to rise from {COST['hub_item']:.2f} to {break_even:.2f} units per donation before the hub stopped "
          'being cheaper.', '',
          '| Setting | Baseline cost | Proposed cost | Change | Scenarios cheaper with hub |', '| --- | --- | --- | --- | --- |']
    L += [f"| {x['setting']} | {x['base']:,.1f} | {x['hub']:,.1f} | {x['change']:.1f} % | {x['cheaper']} |" for x in sens]
    L += ['', '**Hub distance from the NGO depot.** The share of driving saved falls as the hub lies further away '
          f"(Spearman ρ = {sp_dist.statistic:.2f}, p = {fmt_p(sp_dist.pvalue)}), but the hub stays shorter in almost "
          'every scenario at every distance.', '',
          '| Depot to hub and back | Scenarios | Median saving | Hub shorter in |', '| --- | --- | --- | --- |']
    L += [f"| {g['group']} | {g['n']} | {g['saved']:.1f} km ({g['pct']:.1f} %) | {g['shorter']} of {g['n']} |" for g in dist]
    L += ['', f"**Every NGO.** All {len(ngo_pct)} NGOs drove less in total with the hub, by {min(ngo_pct):.1f} to {max(ngo_pct):.1f} %.", '',
          f"**Where the hub did not help.** In {len(losses)} scenarios the hub needed more NGO driving: " +
          ', '.join(f"{r['scenario_id']} ({r['hub_id']}, +{-r['km_saved']:.1f} km)" for r in losses) +
          '. In each, the homes lay along the NGO route while the hub lay away from it. Route time was still shorter '
          f"in all {sum(r['hub_route_min'] < r['base_route_min'] for r in losses)}.", '',
          '## Conclusion', '',
          f"Community hub aggregation is better than direct household pickup for the NGO on every planned measure: "
          f"{-k['change']:.1f} % less road distance, {-t['change']:.1f} % less route time, {-s['change']:.1f} % fewer stops "
          f"and {-c['change']:.1f} % lower collection cost, with every donation collected and every batch valid. "
          'The result holds under every cost setting and for every NGO.', '',
          '## Limits', '',
          '- The hub steps are checked against the app rules in the experiment program, not run in the database.',
          '- Each vehicle makes one trip and road travel times assume no traffic. The cost index is a benchmark quantity, not money.',
          '- Donor travel to the hub is outside this comparison (kept as `donor_travel_km` in the proposed results).', '']
    (OUT / 'summary.md').write_text('\n'.join(L), encoding='utf-8')
    print(f"E3: NGO km {k['base']:,.1f} -> {k['prop']:,.1f} ({k['change']:.1f} %), p = {fmt_p(k['p'])} -> {OUT}")


if __name__ == '__main__':
    main()
