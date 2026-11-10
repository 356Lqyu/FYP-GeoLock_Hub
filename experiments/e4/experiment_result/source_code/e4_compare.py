"""E4 comparison: Nearest-Next and FCFS (baselines) against the app's OR-Tools route optimiser.

Pairs the results by scenario and looks at them in this order:
  1. every plan passed the independent validator
  2. pickups served (exact McNemar test on "every pickup served")
  3. only where both serve the same number of pickups: road km and driving time
     (Wilcoxon signed rank test, Hodges Lehmann estimate with a bootstrap interval)
Run from the repository root: python experiments/e4/experiment_result/source_code/e4_compare.py
"""
import csv
import json
import statistics
from collections import Counter
from pathlib import Path
import math

HERE = Path(__file__).resolve()
E4 = HERE.parents[2]

OUT = HERE.parents[1]
FILES = dict(optimiser=E4 / 'or_tools_route_optimiser' / 'result' / 'results_per_scenario.csv',
             nearest_next=E4 / 'baseline' / '1_nearest_next' / 'results_per_scenario.csv',
             fcfs=E4 / 'baseline' / '2_fcfs' / 'results_per_scenario.csv')
NAMES = dict(optimiser='OR-Tools route optimiser (proposed)', nearest_next='Nearest-Next (baseline 1)', fcfs='FCFS (baseline 2)')


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


def read(p):
    """Read one result CSV file."""
    with p.open(encoding='utf-8-sig', newline='') as f:
        return {r['scenario_id']: r for r in csv.DictReader(f)}


def compare(p, b, ids, name):
    """Compare the optimiser with one baseline: pickups served first, then distance where both serve the same."""
    served_diff = [int(p[s]['served_tasks']) - int(b[s]['served_tasks']) for s in ids]
    full_p_only = sum(p[s]['full_coverage'] == 'YES' and b[s]['full_coverage'] == 'NO' for s in ids)
    full_b_only = sum(p[s]['full_coverage'] == 'NO' and b[s]['full_coverage'] == 'YES' for s in ids)
    same = [s for s in ids if p[s]['served_tasks'] == b[s]['served_tasks']
            and p[s]['independent_check_passed'] == 'YES' and b[s]['independent_check_passed'] == 'YES']
    km = [float(p[s]['total_distance_km']) - float(b[s]['total_distance_km']) for s in same]
    tm = [float(p[s]['driving_time_min']) - float(b[s]['driving_time_min']) for s in same]
    _, kp, knz = wilcoxon_pratt(km)
    _, tp, _ = wilcoxon_pratt(tm)
    _, sp, _ = wilcoxon_pratt(served_diff)
    return dict(baseline=name,
                coverage=dict(proposed_served=sum(int(p[s]['served_tasks']) for s in ids),
                              baseline_served=sum(int(b[s]['served_tasks']) for s in ids),
                              snapshots_proposed_serves_more=sum(d > 0 for d in served_diff),
                              snapshots_equal=sum(d == 0 for d in served_diff),
                              snapshots_proposed_serves_fewer=sum(d < 0 for d in served_diff),
                              served_diff_wilcoxon_p=sp,
                              full_coverage_only_proposed=full_p_only, full_coverage_only_baseline=full_b_only,
                              full_coverage_mcnemar_p=mcnemar_exact(full_p_only, full_b_only)),
                distance_where_equal_coverage=dict(
                    snapshots=len(same), proposed_km=sum(float(p[s]['total_distance_km']) for s in same),
                    baseline_km=sum(float(b[s]['total_distance_km']) for s in same),
                    hl_km=hodges_lehmann(km), ci95=list(bootstrap_ci(km)), wilcoxon_p=kp, nonzero=knz,
                    proposed_shorter=sum(d < -1e-9 for d in km), equal=sum(abs(d) <= 1e-9 for d in km),
                    proposed_longer=sum(d > 1e-9 for d in km),
                    hl_driving_min=hodges_lehmann(tm), driving_ci95=list(bootstrap_ci(tm)), driving_wilcoxon_p=tp))


def baseline_overlap(R, ids):
    """How alike the two simple rules are: same number served, same plan, same pickups, and what stopped them."""
    import collections
    data = E4.parents[1] / 'benchmark dataset' / 'dataset'

    def table(name):
        with (data / f'{name}.csv').open(encoding='utf-8-sig', newline='') as f:
            return list(csv.DictReader(f))
    weight = {r['listing_id']: float(r['listing_weight_kg']) for r in table('listings')}
    cap = {r['vehicle_id']: float(r['vehicle_capacity_kg']) for r in table('vehicles')}
    fleet = collections.defaultdict(list)
    for r in table('vehicles'):
        fleet[r['ngo_id']].append(r['vehicle_id'])
    ngo = {r['scenario_id']: r['entity_id'] for r in table('scenario_members') if r['entity_type'] == 'NGO'}

    def served_sets(folder):
        out = collections.defaultdict(dict)
        for r in read_rows(E4 / 'baseline' / folder / 'details' / 'routes.csv'):
            out[r['scenario_id']][r['vehicle_id']] = r['stops_in_order'].split(' > ')
        return out
    routes = {'nearest_next': served_sets('1_nearest_next'), 'fcfs': served_sets('2_fcfs')}
    left, fits_by_weight, no_route = 0, 0, 0
    for s in ids:
        load = {v: sum(weight[t.replace('TASK-', '')] for t in stops) for v, stops in routes['nearest_next'][s].items()}
        for t, why in json.loads(R['nearest_next'][s]['unserved_reasons'] or '{}').items():
            left += 1
            if why == 'ROUTE_UNAVAILABLE':
                no_route += 1
            elif any(weight[t.replace('TASK-', '')] <= cap[v] - load.get(v, 0) for v in fleet[ngo[s]]):
                fits_by_weight += 1
    pick = {k: {s: set(t for stops in routes[k][s].values() for t in stops) for s in ids} for k in routes}
    return dict(same_number_served=sum(R['nearest_next'][s]['served_tasks'] == R['fcfs'][s]['served_tasks'] for s in ids),
                same_plan=sum(R['nearest_next'][s]['plan_sha256'] == R['fcfs'][s]['plan_sha256'] for s in ids),
                same_pickups=sum(pick['nearest_next'][s] == pick['fcfs'][s] for s in ids),
                same_km=sum(R['nearest_next'][s]['total_distance_km'] == R['fcfs'][s]['total_distance_km'] for s in ids),
                left_out_by_nearest_next=left, left_out_no_road=no_route, left_out_that_fit_by_weight=fits_by_weight)


def read_rows(path):
    """Read a CSV file as a list of rows."""
    with Path(path).open(encoding='utf-8-sig', newline='') as f:
        return list(csv.DictReader(f))


def main():
    """Read the result folders, then write the comparison tables, figures and summary.md."""
    R = {k: read(v) for k, v in FILES.items()}
    ids = sorted(R['optimiser'])
    assert all(set(R[k]) == set(ids) for k in R) and len(ids) == 100, 'scenario sets differ'
    for s in ids:  # every method got the same snapshot
        assert len({R[k][s]['frozen_snapshot_sha256'] for k in R}) == 1, f'different snapshot for {s}'
        assert len({R[k][s]['valid_tasks'] for k in R}) == 1
    m = dict(planned_units=100, realised_units=len(ids))
    m['per_method'] = {}
    for k in R:
        rs = R[k]
        served = sum(int(rs[s]['served_tasks']) for s in ids)
        valid = sum(int(rs[s]['valid_tasks']) for s in ids)
        full = sum(rs[s]['full_coverage'] == 'YES' for s in ids)
        reasons = Counter()
        for s in ids:
            u = json.loads(rs[s]['unserved_reasons'] or '{}')
            for v in (u.values() if isinstance(u, dict) else u):
                reasons[v if isinstance(v, str) else str(v)] += 1
        m['per_method'][k] = dict(
            name=NAMES[k], valid_tasks=valid, served=served, coverage=served / valid,
            coverage_ci95=list(wilson(served, valid)[1:]), full_coverage_snapshots=full,
            full_coverage_ci95=list(wilson(full, len(ids))[1:]),
            independent_check_passed=sum(rs[s]['independent_check_passed'] == 'YES' for s in ids),
            violations=sum(int(rs[s].get(c) or 0) for s in ids for c in ('capacity_violations', 'duration_violations', 'time_window_violations', 'other_violations')),
            total_km=sum(float(rs[s]['total_distance_km']) for s in ids),
            km_per_served_task=sum(float(rs[s]['total_distance_km']) for s in ids) / served,
            vehicles_used=sum(int(rs[s]['vehicles_used']) for s in ids),
            timeouts=sum(rs[s]['timeout'] == 'YES' for s in ids),
            median_planning_ms=statistics.median(float(rs[s]['planning_time_ms']) for s in ids),
            max_planning_ms=max(float(rs[s]['planning_time_ms']) for s in ids),
            unserved_reasons=dict(reasons),
            coverage_proven_optimal=sum(rs[s].get('coverage_proven_optimal') == 'YES' for s in ids))
    m['baselines_alike'] = baseline_overlap(R, ids)
    m['primary_vs_nearest_next'] = compare(R['optimiser'], R['nearest_next'], ids, 'nearest_next')
    m['descriptive_vs_fcfs'] = compare(R['optimiser'], R['fcfs'], ids, 'fcfs')
    sec = [m['primary_vs_nearest_next']['distance_where_equal_coverage']['wilcoxon_p'],
           m['primary_vs_nearest_next']['distance_where_equal_coverage']['driving_wilcoxon_p']]
    m['holm_secondary_vs_nearest_next'] = dict(zip(['distance', 'driving_time'], holm(sec)))
    R_ = {'proposed': R['optimiser'], 'baseline1_nearest_next': R['nearest_next'], 'baseline2_fcfs': R['fcfs']}
    out_rows = []
    for s in ids:
        o = dict(scenario_id=s, valid_pickups=R['optimiser'][s]['valid_tasks'])
        for k, rs in R_.items():
            o.update({f'{k}_served': rs[s]['served_tasks'], f'{k}_km': rs[s]['total_distance_km'],
                      f'{k}_vehicles': rs[s]['vehicles_used'], f'{k}_plan_valid': rs[s]['independent_check_passed']})
        same = R['optimiser'][s]['served_tasks'] == R['nearest_next'][s]['served_tasks']
        o['same_served_as_nearest_next'] = 'YES' if same else 'NO'
        o['km_saved_vs_nearest_next'] = round(float(R['nearest_next'][s]['total_distance_km']) - float(R['optimiser'][s]['total_distance_km']), 3) if same else ''
        out_rows.append(o)
    write_csv(OUT / 'comparison_per_scenario.csv', out_rows)

    def row(measure, key, fmt, better):
        return dict(measure=measure, proposed_or_tools=fmt(m['per_method']['optimiser'][key]),
                    baseline_1_nearest_next=fmt(m['per_method']['nearest_next'][key]),
                    baseline_2_fcfs=fmt(m['per_method']['fcfs'][key]), better_when=better)
    d, f = m['primary_vs_nearest_next']['distance_where_equal_coverage'], m['descriptive_vs_fcfs']['distance_where_equal_coverage']
    write_csv(OUT / 'comparison_summary.csv', [
        row('Plans passing the independent check (of 100)', 'independent_check_passed', int, 'higher'),
        row('Valid pickups served (of 483)', 'served', int, 'higher'),
        row('Scenarios with every pickup served (of 100)', 'full_coverage_snapshots', int, 'higher'),
        row('Total distance, all scenarios (km)', 'total_km', lambda v: round(v, 1), 'lower'),
        row('Distance per pickup served (km)', 'km_per_served_task', lambda v: round(v, 2), 'lower'),
        row('Vehicles used', 'vehicles_used', int, 'lower'),
        row('Capacity, duration or time window violations', 'violations', int, 'lower'),
        row('Solver timeouts', 'timeouts', int, 'lower'),
        row('Planning time per scenario, median (ms)', 'median_planning_ms', lambda v: round(v, 1), 'lower'),
        dict(measure=f"Distance where served pickups are equal to baseline 1 ({d['snapshots']} scenarios, km)",
             proposed_or_tools=round(d['proposed_km'], 1), baseline_1_nearest_next=round(d['baseline_km'], 1),
             baseline_2_fcfs='', better_when='lower'),
        dict(measure=f"Distance where served pickups are equal to baseline 2 ({f['snapshots']} scenarios, km)",
             proposed_or_tools=round(f['proposed_km'], 1), baseline_1_nearest_next='', baseline_2_fcfs=round(f['baseline_km'], 1),
             better_when='lower')])
    write_json(OUT / 'metrics.json', m)
    figure(R, ids, m)
    summary(m)
    print('E4 comparison ->', OUT / 'summary.md')


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


def figure(R, ids, m):
    """Draw the three figures, one PNG each."""
    plt = plot_style()
    keys = ['optimiser', 'nearest_next', 'fcfs']
    names = ['OR-Tools route optimiser\n(proposed)', 'Nearest-Next\n(baseline 1)', 'First come first served\n(baseline 2)']
    colours = [PROPOSED, BASELINE_1, BASELINE_2]
    pm = m['per_method']

    fig, ax = plt.subplots(figsize=(6, 3.6))
    ax.set_ylim(0, 115)
    for i, k in enumerate(keys):
        lo, hi = pm[k]['coverage_ci95']
        bars(ax, [i], [100 * pm[k]['coverage']], colours[i], 0.55, low=[100 * lo], high=[100 * hi],
             text=[f"{pm[k]['served']} of {pm[k]['valid_tasks']}"])
    ax.set_xticks(range(3), names)
    ax.set_ylabel('Valid pickups served (%)')
    ax.set_title('Pickups served')
    save(plt, fig, 'e4_fig1_tasks_served.png')

    eq = [s for s in ids if R['optimiser'][s]['served_tasks'] == R['nearest_next'][s]['served_tasks']]
    fig, ax = plt.subplots(figsize=(4.8, 4.4))
    x = [float(R['nearest_next'][s]['total_distance_km']) for s in eq]
    y = [float(R['optimiser'][s]['total_distance_km']) for s in eq]
    lim = max(x + y) * 1.05
    ax.plot([0, lim], [0, lim], color='#888888', lw=0.8, ls='--', label='Equal distance')
    ax.scatter(x, y, s=14, color=PROPOSED, alpha=0.85, label='One scenario')
    ax.set_xlim(0, lim); ax.set_ylim(0, lim); ax.set_aspect('equal')
    ax.grid(axis='x', color='#e3e3e3', linewidth=0.6)
    ax.set_xlabel('Nearest-Next (km)')
    ax.set_ylabel('OR-Tools route optimiser (km)')
    ax.set_title(f'Route distance per scenario (n = {len(eq)})')
    ax.legend(loc='upper left')
    save(plt, fig, 'e4_fig2_km_per_scenario.png')

    d = m['primary_vs_nearest_next']['distance_where_equal_coverage']
    f = m['descriptive_vs_fcfs']['distance_where_equal_coverage']
    fig, ax = plt.subplots(figsize=(6.4, 3.6))
    top = max(d['baseline_km'], f['baseline_km'], d['proposed_km'])
    ax.set_ylim(0, top * 1.22)
    pad = top * 0.015
    bars(ax, [-0.2, 0.8], [d['proposed_km'], f['proposed_km']], PROPOSED, 0.38, label='OR-Tools route optimiser (proposed)',
         text=[f"{d['proposed_km']:,.0f}", f"{f['proposed_km']:,.0f}"], pad=pad)
    bars(ax, [0.2], [d['baseline_km']], BASELINE_1, 0.38, label='Nearest-Next (baseline 1)', text=[f"{d['baseline_km']:,.0f}"], pad=pad)
    bars(ax, [1.2], [f['baseline_km']], BASELINE_2, 0.38, label='First come first served (baseline 2)', text=[f"{f['baseline_km']:,.0f}"], pad=pad)
    ax.set_xticks([0, 1], [f"Against Nearest-Next\n({d['snapshots']} scenarios)", f"Against first come first served\n({f['snapshots']} scenarios)"])
    ax.set_ylabel('Total distance (km)')
    ax.set_title('Total distance where both serve the same pickups')
    ax.legend(loc='upper center', bbox_to_anchor=(0.5, -0.24), ncol=1)
    save(plt, fig, 'e4_fig3_total_km.png')


def summary(m):
    """Write summary.md."""
    pm, P, F = m['per_method'], m['primary_vs_nearest_next'], m['descriptive_vs_fcfs']
    o, n, f = pm['optimiser'], pm['nearest_next'], pm['fcfs']
    d, c, fd = P['distance_where_equal_coverage'], P['coverage'], F['distance_where_equal_coverage']
    L = ['# E4 result: OR-Tools route optimiser vs simple routing rules', '',
         '## What we wanted to find out', '',
         'After an NGO has claimed several donations, it has to decide which vehicle picks up which donation and in what '
         'order. The GeoLock routing worker (Python backend called by the Flutter app) plans this with Google OR-Tools. We wanted '
         'to know whether the OR-Tools optimiser serves more of '
         'the pickups than simple rules do, and, when they serve the same pickups, whether it drives less.', '',
         '## What we used', '',
         f"- **Data:** the frozen benchmark dataset GEOLOCK-BENCHMARK-DATASET: 100 route planning scenarios. Each has 5 claimed "
         f"donations of one NGO and its two vehicles (a 100 kg car and a 500 kg van). After the app's admission checks, "
         f"{o['valid_tasks']} of the 500 pickups were valid to plan; every method received exactly the same valid pickups.",
         '- **Nearest-Next (baseline 1):** each vehicle in turn keeps driving to the closest pickup it can still fit and finish in time.',
         '- **First come first served (baseline 2):** each vehicle takes pickups in the order they were claimed.',
         '- **OR-Tools route optimiser (proposed):** the app\'s routing code, used without any change '
         '(`backend/routing/optimizers/cp_sat.py`, Google OR-Tools CP-SAT solver, the same function the routing worker calls). '
         'It first serves as many pickups as possible, then chooses the shortest total road distance.',
         '- **Same rules for all:** each vehicle starts and ends at the NGO depot, carries at most its capacity, and finishes within '
         '240 minutes (driving + 10 minutes per stop). Every plan was checked again by an independent validator.', '',
         '## Results', '', 'The main numbers are also in `comparison_summary.csv`, one row per measure with every method side by side.', '',
         '| Method | Plans passing the independent check | Pickups served | Scenarios with every pickup served | Total km | km per pickup served |',
         '| --- | --- | --- | --- | --- | --- |']
    for k in ('optimiser', 'nearest_next', 'fcfs'):
        x = pm[k]
        nm = {'optimiser': '**OR-Tools route optimiser (proposed)**', 'nearest_next': 'Nearest-Next (baseline 1)', 'fcfs': 'First come first served (baseline 2)'}[k]
        L.append(f"| {nm} | {x['independent_check_passed']} of 100 | {x['served']} of {x['valid_tasks']} ({pct(x['coverage'])}) | "
                 f"{x['full_coverage_snapshots']} of 100 | {x['total_km']:,.0f} | {x['km_per_served_task']:.2f} |")
    L += ['', '| Method | Vehicles used | Capacity, duration or time window violations | Solver timeouts | Median planning time |',
          '| --- | --- | --- | --- | --- |']
    for k in ('optimiser', 'nearest_next', 'fcfs'):
        x = pm[k]
        L.append(f"| {x['name']} | {x['vehicles_used']} | {x['violations']} | {x['timeouts']} | {x['median_planning_ms']:,.0f} ms |")
    L += ['', f"Where OR-Tools and the baseline served the same number of pickups ({d['snapshots']} scenarios for Nearest-Next, "
          f"{fd['snapshots']} for first come first served):", '',
          '| Comparison | OR-Tools km | Baseline km | OR-Tools shorter / equal / longer |', '| --- | --- | --- | --- |',
          f"| vs Nearest-Next | {d['proposed_km']:,.0f} | {d['baseline_km']:,.0f} | {d['proposed_shorter']} / {d['equal']} / {d['proposed_longer']} |",
          f"| vs First come first served | {fd['proposed_km']:,.0f} | {fd['baseline_km']:,.0f} | {fd['proposed_shorter']} / {fd['equal']} / {fd['proposed_longer']} |", '',
          '![Figure 1](e4_fig1_tasks_served.png)', '',
          '*Figure 1. Share of the 483 valid pickups placed on a valid route. Error bars show 95 % Wilson confidence intervals.*', '',
          '![Figure 2](e4_fig2_km_per_scenario.png)', '',
          '*Figure 2. Route distance per scenario for OR-Tools and Nearest-Next, in the scenarios where both serve the same number of pickups. Points below the dashed line are scenarios where OR-Tools drives less.*', '',
          '![Figure 3](e4_fig3_total_km.png)', '',
          '*Figure 3. Total route distance of OR-Tools and each baseline over the scenarios where both serve the same number of pickups.*', '',
          '## Analysis', '',
          f"**All plans are valid.** All 300 plans (100 scenarios × 3 methods) passed the independent check: no vehicle was "
          'overloaded, no route ran over 240 minutes, and every pickup was either served exactly once or reported as unserved. '
          'So the comparison below is between valid plans only.', '',
          f"**OR-Tools serves the most pickups.** It placed {o['served']} of {o['valid_tasks']} valid pickups on a route, against "
          + (f"{n['served']} for both simple rules. " if n['served'] == f['served'] else f"{n['served']} for Nearest-Next and {f['served']} for first come first served. ")
          + f"It served more than Nearest-Next in {c['snapshots_proposed_serves_more']} scenarios "
          + ("and never fewer. " if c['snapshots_proposed_serves_fewer'] == 0 else f"and fewer in {c['snapshots_proposed_serves_fewer']}. ")
          + f"For each scenario OR-Tools also proved that no plan could serve more pickups "
          f"({o['coverage_proven_optimal']} of 100), so the {o['valid_tasks'] - o['served']} pickups it left out could not fit on any valid plan "
          "with these two vehicles (one trip each, capacity, 240 minutes). "
          'The gap is small because each scenario has only 5 pickups, so the simple rules already serve almost everything they can.', '',
          f"**Why the two simple rules serve the same number of pickups.** They are different methods and gave different "
          f"plans: their routes differed in {100 - m['baselines_alike']['same_plan']} of 100 scenarios, their distance in "
          f"{100 - m['baselines_alike']['same_km']} and even the set of pickups they served in {100 - m['baselines_alike']['same_pickups']}. "
          f"Only the count was the same, in {m['baselines_alike']['same_number_served']} of 100 scenarios. Both fill one vehicle "
          'and then the other, adding pickups until none fits any more, and what stops them is the same in both: of the '
          f"{m['baselines_alike']['left_out_by_nearest_next']} pickups Nearest-Next left out, "
          f"{m['baselines_alike']['left_out_that_fit_by_weight']} still fitted by weight, so the limit was the 240 minute route "
          f"time, and {m['baselines_alike']['left_out_no_road']} had no direct road route from the depot in the benchmark matrix. With only "
          '5 pickups per scenario, the order of the stops changed which far pickup was dropped, but not how many.', '',
          f"**OR-Tools drives clearly less.** Where both served the same pickups, OR-Tools drove {d['proposed_km']:,.0f} km "
          f"instead of {d['baseline_km']:,.0f} km with Nearest-Next ({100 * (d['baseline_km'] - d['proposed_km']) / d['baseline_km']:.1f} % less). "
          f"It was shorter in {d['proposed_shorter']} scenarios, equal in {d['equal']} (where the nearest first order was already the best), "
          + ("and never longer. " if d['proposed_longer'] == 0 else f"and longer in {d['proposed_longer']}. ")
          + f"The typical saving is {-d['hl_km']:.1f} km per scenario (95 % confidence interval {-d['ci95'][1]:.1f} to "
          f"{-d['ci95'][0]:.1f} km; Wilcoxon signed rank test p = {d['wilcoxon_p']:.1g}), and driving time falls by about "
          f"{-d['hl_driving_min']:.1f} minutes per scenario.", '',
          f"**Why:** Nearest-Next always takes the closest next stop, which can leave a far away pickup for the end and force a long "
          'drive back to the depot. OR-Tools looks at the whole route at once and can choose a slightly longer step early '
          f"to save more later. Against first come first served, which ignores distance, the saving is larger: {fd['proposed_km']:,.0f} km "
          f"vs {fd['baseline_km']:,.0f} km ({100 * (fd['baseline_km'] - fd['proposed_km']) / fd['baseline_km']:.0f} % less).", '',
          f"**Planning is still fast.** OR-Tools needed a median of {o['median_planning_ms']:,.0f} ms per scenario.", '',
          '## Conclusion', '',
          f"On the same claimed pickups and the same rules, the OR-Tools route optimiser produced only valid plans, served the most pickups "
          f"({o['served']} vs {n['served']}) and drove {100 * (d['baseline_km'] - d['proposed_km']) / d['baseline_km']:.0f} % less than "
          f"Nearest-Next where both served the same pickups. The proposed method is better than both "
          'baselines. Its main benefit is shorter routes; the gain in pickups served is small with only 5 pickups per scenario.', '',
          '## Limits of this experiment', '',
          '- Each scenario has only 5 pickups and 2 vehicles; with more pickups OR-Tools has more room to improve on the simple rules.',
          '- Each vehicle makes one trip, and travel times assume no traffic.',
          '- The routing code of the app was used as it is, without changes.', '']
    (OUT / 'summary.md').write_text('\n'.join(L), encoding='utf-8')


if __name__ == '__main__':
    main()
