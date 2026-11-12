"""Compare E4 methods and generate the team's report and figures.

Coverage and aggregate distance use all 100 snapshots. Paired distance/time
analysis uses only independently validated plans with identical served task IDs.
Run after the three methods have been run with the same GEOLOCK_E4_RUN_ID.
"""
import csv
import hashlib
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
ROUTE_FILES = dict(optimiser=E4 / 'or_tools_route_optimiser' / 'result' / 'details' / 'routes.csv',
                   nearest_next=E4 / 'baseline' / '1_nearest_next' / 'details' / 'routes.csv',
                   fcfs=E4 / 'baseline' / '2_fcfs' / 'details' / 'routes.csv')
MANIFEST_FILES = dict(optimiser=E4 / 'or_tools_route_optimiser' / 'result' / 'run_manifest.json',
                      nearest_next=E4 / 'baseline' / '1_nearest_next' / 'run_manifest.json',
                      fcfs=E4 / 'baseline' / '2_fcfs' / 'run_manifest.json')
ARTIFACT_FILES = {
    'optimiser': {'results_per_scenario.csv': FILES['optimiser'], 'details/routes.csv': ROUTE_FILES['optimiser'],
                  'run_info.md': E4 / 'or_tools_route_optimiser' / 'result' / 'run_info.md'},
    'nearest_next': {'results_per_scenario.csv': FILES['nearest_next'], 'details/routes.csv': ROUTE_FILES['nearest_next'],
                     'run_info.md': E4 / 'baseline' / '1_nearest_next' / 'run_info.md'},
    'fcfs': {'results_per_scenario.csv': FILES['fcfs'], 'details/routes.csv': ROUTE_FILES['fcfs'],
             'run_info.md': E4 / 'baseline' / '2_fcfs' / 'run_info.md'},
}
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
        rows = list(csv.DictReader(f))
    result = {r['scenario_id']: r for r in rows}
    if len(result) != len(rows):
        raise ValueError(f'Duplicate scenario IDs in {p}')
    return result


def read_served_task_sets(path, ids, results):
    """Reconstruct each method's served task IDs from its route-detail CSV."""
    allowed = set(ids)
    served = {sid: set() for sid in ids}
    with Path(path).open(encoding='utf-8-sig', newline='') as stream:
        rows = list(csv.DictReader(stream))
    for row in rows:
        sid = row['scenario_id']
        if sid not in allowed:
            raise ValueError(f'Unknown route scenario {sid} in {path}')
        ordered = [value.strip() for value in row['stops_in_order'].split('>') if value.strip()]
        if int(row['stops']) != len(ordered):
            raise ValueError(f'Route stop count does not match stop IDs for {sid} in {path}')
        if len(set(ordered)) != len(ordered) or served[sid].intersection(ordered):
            raise ValueError(f'Duplicate served task ID for {sid} in {path}')
        served[sid].update(ordered)
    for sid in ids:
        if len(served[sid]) != int(results[sid]['served_tasks']):
            raise ValueError(f'Route details disagree with served-task count for {sid} in {path}')
    return served


def matched_task_scenarios(p, b, ids, proposed_tasks, baseline_tasks):
    """Return validated snapshots where both methods served exactly the same task IDs."""
    return [sid for sid in ids
            if proposed_tasks[sid]
            and proposed_tasks[sid] == baseline_tasks[sid]
            and p[sid]['independent_check_passed'] == 'YES'
            and b[sid]['independent_check_passed'] == 'YES']


def validate_run_manifests(manifests):
    """Validate the method, common invocation, settings, inputs and source hashes."""
    expected_method = {'optimiser': 'or_tools_route_optimiser', 'nearest_next': 'nearest_next', 'fcfs': 'fcfs'}
    for key, value in manifests.items():
        if value.get('method') != expected_method[key] or not value.get('run_id'):
            raise ValueError(f'Missing or incorrect E4 run manifest for {key}; rerun all methods together')
    run_ids = {value['run_id'] for value in manifests.values()}
    if len(run_ids) != 1:
        raise ValueError('E4 result folders come from different run IDs; rerun all three methods together')
    for field in ('settings', 'input_sha256', 'source_sha256'):
        if any(value.get(field) != manifests['optimiser'].get(field) for value in manifests.values()):
            raise ValueError(f'E4 method manifests disagree on {field}; do not combine these results')
    for field in ('python', 'platform', 'packages'):
        if any(value.get('environment', {}).get(field) != manifests['optimiser'].get('environment', {}).get(field)
               for value in manifests.values()):
            raise ValueError(f'E4 method manifests disagree on environment.{field}; do not combine these results')
    return manifests['optimiser']['run_id']


def verify_run_manifests():
    """Fail closed if result files were produced by different E4 invocations."""
    manifests = {key: json.loads(path.read_text(encoding='utf-8')) for key, path in MANIFEST_FILES.items()}
    run_id = validate_run_manifests(manifests)
    validate_result_artifacts(manifests)
    return run_id


def validate_result_artifacts(manifests, artifact_paths=ARTIFACT_FILES):
    """Verify saved per-method result files against their manifest hashes."""
    for method, paths in artifact_paths.items():
        expected = manifests[method].get('artifact_sha256')
        if not isinstance(expected, dict) or set(expected) != set(paths):
            raise ValueError(f'Missing or incomplete result artifact hashes for {method}')
        for name, path in paths.items():
            actual = hashlib.sha256(Path(path).read_bytes()).hexdigest()
            if actual != expected[name]:
                raise ValueError(f'Result artifact hash mismatch: {method}/{name}')


def compare(p, b, ids, name, proposed_tasks, baseline_tasks):
    """Compare coverage on all snapshots and distance/time on exact task-set matches."""
    served_diff = [int(p[s]['served_tasks']) - int(b[s]['served_tasks']) for s in ids]
    full_p_only = sum(p[s]['full_coverage'] == 'YES' and b[s]['full_coverage'] == 'NO' for s in ids)
    full_b_only = sum(p[s]['full_coverage'] == 'NO' and b[s]['full_coverage'] == 'YES' for s in ids)
    same = matched_task_scenarios(p, b, ids, proposed_tasks, baseline_tasks)
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
                distance_identical_task_set=dict(
                    analysis_scope='identical_served_task_ids_only', matched_scenario_ids=same,
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
    run_id = verify_run_manifests()
    R = {k: read(v) for k, v in FILES.items()}
    ids = sorted(R['optimiser'])
    assert all(set(R[k]) == set(ids) for k in R) and len(ids) == 100, 'scenario sets differ'
    task_sets = {}
    for method in R:
        task_sets[method] = read_served_task_sets(ROUTE_FILES[method], ids, R[method])
    for s in ids:  # every method got the same snapshot
        assert len({R[k][s]['frozen_snapshot_sha256'] for k in R}) == 1, f'different snapshot for {s}'
        assert len({R[k][s]['valid_tasks'] for k in R}) == 1
        if any(R[k][s].get('error') for k in R):
            raise ValueError(f'At least one method failed for {s}')
        if any(R[k][s]['independent_check_passed'] != 'YES' for k in R):
            raise ValueError(f'At least one plan failed independent validation for {s}')
        if any(int(R[k][s]['valid_tasks']) != 5 for k in R):
            raise ValueError(f'Expected five admitted tasks per snapshot; mismatch in {s}')
    if sum(int(R['optimiser'][s]['valid_tasks']) for s in ids) != 500:
        raise ValueError('Expected exactly 500 common-admission tasks across 100 scenarios')
    m = dict(planned_units=100, realised_units=len(ids))
    m['run_id'] = run_id
    m['admitted_task_total'] = 500
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
            total_driving_time_min=round(sum(float(rs[s]['driving_time_min']) for s in ids), 2),
            km_per_served_task=sum(float(rs[s]['total_distance_km']) for s in ids) / served,
            vehicles_used=sum(int(rs[s]['vehicles_used']) for s in ids),
            timeouts=sum(rs[s]['timeout'] == 'YES' for s in ids),
            median_planning_ms=statistics.median(float(rs[s]['planning_time_ms']) for s in ids),
            max_planning_ms=max(float(rs[s]['planning_time_ms']) for s in ids),
            unserved_reasons=dict(reasons),
            coverage_proven_optimal=sum(rs[s].get('coverage_proven_optimal') == 'YES' for s in ids))
    m['baselines_alike'] = baseline_overlap(R, ids)
    m['primary_vs_nearest_next'] = compare(R['optimiser'], R['nearest_next'], ids, 'nearest_next',
        task_sets['optimiser'], task_sets['nearest_next'])
    m['descriptive_vs_fcfs'] = compare(R['optimiser'], R['fcfs'], ids, 'fcfs',
        task_sets['optimiser'], task_sets['fcfs'])
    secondary_keys = [
        ('nearest_next', 'distance_km', m['primary_vs_nearest_next']['distance_identical_task_set']['wilcoxon_p']),
        ('nearest_next', 'driving_time_min', m['primary_vs_nearest_next']['distance_identical_task_set']['driving_wilcoxon_p']),
        ('fcfs', 'distance_km', m['descriptive_vs_fcfs']['distance_identical_task_set']['wilcoxon_p']),
        ('fcfs', 'driving_time_min', m['descriptive_vs_fcfs']['distance_identical_task_set']['driving_wilcoxon_p']),
    ]
    m['holm_secondary'] = [dict(baseline=baseline, measure=measure, p_raw=p, p_holm=p_holm)
                            for (baseline, measure, p), p_holm in zip(secondary_keys, holm([x[2] for x in secondary_keys]))]
    R_ = {'proposed': R['optimiser'], 'baseline1_nearest_next': R['nearest_next'], 'baseline2_fcfs': R['fcfs']}
    out_rows = []
    for s in ids:
        o = dict(scenario_id=s, valid_pickups=R['optimiser'][s]['valid_tasks'])
        for k, rs in R_.items():
            o.update({f'{k}_served': rs[s]['served_tasks'], f'{k}_km': rs[s]['total_distance_km'],
                      f'{k}_vehicles': rs[s]['vehicles_used'], f'{k}_plan_valid': rs[s]['independent_check_passed']})
        same_nearest = task_sets['optimiser'][s] == task_sets['nearest_next'][s]
        same_fcfs = task_sets['optimiser'][s] == task_sets['fcfs'][s]
        o['identical_served_task_ids_vs_nearest_next'] = 'YES' if same_nearest else 'NO'
        o['identical_served_task_ids_vs_fcfs'] = 'YES' if same_fcfs else 'NO'
        o['km_saved_vs_nearest_next'] = round(float(R['nearest_next'][s]['total_distance_km']) - float(R['optimiser'][s]['total_distance_km']), 3) if same_nearest else ''
        o['km_saved_vs_fcfs'] = round(float(R['fcfs'][s]['total_distance_km']) - float(R['optimiser'][s]['total_distance_km']), 3) if same_fcfs else ''
        out_rows.append(o)
    write_csv(OUT / 'comparison_per_scenario.csv', out_rows)

    def row(measure, key, fmt, better):
        return dict(measure=measure, proposed_or_tools=fmt(m['per_method']['optimiser'][key]),
                    baseline_1_nearest_next=fmt(m['per_method']['nearest_next'][key]),
                    baseline_2_fcfs=fmt(m['per_method']['fcfs'][key]), better_when=better)
    d, f = m['primary_vs_nearest_next']['distance_identical_task_set'], m['descriptive_vs_fcfs']['distance_identical_task_set']
    valid_task_total = sum(int(R['optimiser'][s]['valid_tasks']) for s in ids)
    write_csv(OUT / 'comparison_summary.csv', [
        row('Plans passing the independent check (of 100)', 'independent_check_passed', int, 'higher'),
        row(f'Valid pickups served (of {valid_task_total})', 'served', int, 'higher'),
        row('Scenarios with every pickup served (of 100)', 'full_coverage_snapshots', int, 'higher'),
        row('Total distance, all scenarios (km)', 'total_km', lambda v: round(v, 1), 'lower'),
        row('Distance per pickup served (km)', 'km_per_served_task', lambda v: round(v, 2), 'lower'),
        row('Vehicles used', 'vehicles_used', int, 'lower'),
        row('Capacity, duration or time window violations', 'violations', int, 'lower'),
        row('Solver timeouts', 'timeouts', int, 'lower'),
        row('Planning time per scenario, median (ms)', 'median_planning_ms', lambda v: round(v, 1), 'lower'),
        dict(measure=f"Matched-task distance (identical task IDs), Nearest-Next (n={d['snapshots']}, km)",
             proposed_or_tools=round(d['proposed_km'], 1), baseline_1_nearest_next=round(d['baseline_km'], 1),
             baseline_2_fcfs='', better_when='lower'),
        dict(measure=f"Matched-task distance (identical task IDs), FCFS (n={f['snapshots']}, km)",
             proposed_or_tools=round(f['proposed_km'], 1), baseline_1_nearest_next='', baseline_2_fcfs=round(f['baseline_km'], 1),
             better_when='lower')])
    write_json(OUT / 'metrics.json', m)
    figure(R, ids, m, task_sets)
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


def matched_task_savings_rows(metrics):
    """Return CP-SAT savings and transformed bootstrap intervals from saved metrics."""
    comparisons = [
        ('Nearest-Next', metrics['primary_vs_nearest_next']['distance_identical_task_set']),
        ('FCFS', metrics['descriptive_vs_fcfs']['distance_identical_task_set']),
    ]
    rows = []
    for label, result in comparisons:
        # The stored Hodges–Lehmann value is baseline minus CP-SAT. Negating it
        # expresses savings as positive values favouring CP-SAT; reverse the
        # confidence interval endpoints under the same transformation.
        estimate = -float(result['hl_km'])
        low = -float(result['ci95'][1])
        high = -float(result['ci95'][0])
        rows.append({
            'label': label,
            'snapshots': int(result['snapshots']),
            'estimate_km': estimate,
            'ci95_low_km': low,
            'ci95_high_km': high,
        })
    return rows


def figure4_matched_task_savings(metrics):
    """Write only Figure 4, with saved estimates and CIs in a separate column."""
    plt = plot_style()
    rows = matched_task_savings_rows(metrics)
    estimates = [row['estimate_km'] for row in rows]
    lows = [row['ci95_low_km'] for row in rows]
    highs = [row['ci95_high_km'] for row in rows]
    y = list(range(len(rows)))

    fig = plt.figure(figsize=(7.2, 2.75), constrained_layout=True)
    grid = fig.add_gridspec(1, 2, width_ratios=(0.69, 0.31), wspace=0.03)
    ax = fig.add_subplot(grid[0, 0])
    value_ax = fig.add_subplot(grid[0, 1], sharey=ax)

    ax.axvline(0, color='#888888', linewidth=0.8, linestyle='--', zorder=0)
    ax.errorbar(
        estimates, y,
        xerr=[[estimate - low for estimate, low in zip(estimates, lows)],
              [high - estimate for estimate, high in zip(estimates, highs)]],
        fmt='o', color=PROPOSED, ecolor=PROPOSED, capsize=3,
        linewidth=1.4, markersize=5, zorder=2,
    )
    ax.set_yticks(y, [f"{row['label']} (n={row['snapshots']})" for row in rows])
    ax.tick_params(axis='y', length=0, pad=6, labelsize=8)
    ax.set_ylim(-0.55, len(rows) - 0.45)
    ax.invert_yaxis()
    ax.set_xlim(0, max(highs) * 1.08)
    ax.set_xlabel('Matched-task road-distance savings (km); positive favours CP-SAT')
    ax.set_title('CP-SAT savings for identical served task sets')
    ax.grid(axis='x', color='#e3e3e3', linewidth=0.6)
    ax.grid(axis='y', visible=False)
    ax.spines['left'].set_visible(False)

    # Keep numeric annotations outside the data viewport so they cannot cover
    # error bars or gridlines. The shared y scale aligns each text block to its point.
    value_ax.set_xlim(0, 1)
    value_ax.set_ylim(ax.get_ylim())
    value_ax.axis('off')
    for index, row in enumerate(rows):
        value_ax.text(
            0.04, index,
            f"{row['estimate_km']:.2f} km\n"
            f"95% CI: {row['ci95_low_km']:.2f}–{row['ci95_high_km']:.2f} km",
            transform=value_ax.get_yaxis_transform(),
            ha='left', va='center', fontsize=8, color='#222222', linespacing=1.3,
        )

    fig.savefig(OUT / 'e4_fig4_matched_task_savings.png', dpi=300, bbox_inches='tight')
    fig.savefig(OUT / 'e4_fig4_matched_task_savings.pdf', bbox_inches='tight')
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


def figure(R, ids, m, task_sets):
    """Draw coverage, descriptive aggregate distance and exact-match figures."""
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

    eq = matched_task_scenarios(R['optimiser'], R['nearest_next'], ids,
                                task_sets['optimiser'], task_sets['nearest_next'])
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

    # Aggregate totals are descriptive across each method's own served tasks.
    fig, ax = plt.subplots(figsize=(6.4, 3.6))
    top = max(m['per_method'][key]['total_km'] for key in keys)
    ax.set_ylim(0, top * 1.22)
    pad = top * 0.015
    for i, key in enumerate(keys):
        value = m['per_method'][key]['total_km']
        bars(ax, [i], [value], colours[i], 0.55, text=[f'{value:,.0f}'], pad=pad)
    ax.set_xticks(range(3), names)
    ax.set_ylabel('Total directed-road distance (km)')
    ax.set_title('Aggregate route distance across all 100 snapshots')
    ax.text(0.5, -0.24, 'Descriptive totals; served task identities can differ by method.',
            ha='center', va='top', transform=ax.transAxes, fontsize=8, color='#555555')
    save(plt, fig, 'e4_fig3_total_km.png')

    figure4_matched_task_savings(m)


def summary(m):
    """Write an auditable summary that separates aggregate from matched-task results."""
    pm = m['per_method']
    near = m['primary_vs_nearest_next']
    fcfs = m['descriptive_vs_fcfs']
    dn = near['distance_identical_task_set']
    df = fcfs['distance_identical_task_set']
    labels = {'optimiser': 'OR-Tools CP-SAT (proposed)', 'nearest_next': 'Nearest-Next', 'fcfs': 'FCFS'}
    L = ['# E4 routing experiment', '', f"**Run ID:** `{m['run_id']}`", '',
         'The frozen benchmark contains 100 snapshots and 500 candidate tasks. The E4-only adapter ignores the synthetic listing-expiry field during post-claim admission; all three methods receive the same 500 admitted task IDs. Claim leases, ownership, task status, pickup windows, capacity, route duration, depot return and directed-road connectivity remain enforced.', '',
         '## Coverage and aggregate results', '',
         'Coverage and aggregate route totals below use all 100 snapshots. Aggregate distance totals describe each method’s routes and may cover different served-task sets.', '',
         '| Method | Served / admitted tasks | Coverage | Total directed-road distance (km) | Driving time (min) | Validated plans / 100 | Hard violations |',
         '| --- | ---: | ---: | ---: | ---: | ---: | ---: |']
    for key in ('nearest_next', 'fcfs', 'optimiser'):
        x = pm[key]
        L.append(f"| {labels[key]} | {x['served']} / {x['valid_tasks']} | {pct(x['coverage'])} | {x['total_km']:,.1f} | {x.get('total_driving_time_min', 'n/a')} | {x['independent_check_passed']} / 100 | {x['violations']} |")
    L += ['', '## Identical-served-task paired comparisons', '',
          'These paired distance and time comparisons include only snapshots where both independently validated plans served exactly the same task IDs. They are distinct from the aggregate totals above.', '',
          '| Baseline | Matched snapshots | CP-SAT distance (km) | Baseline distance (km) | CP-SAT distance saving (HL, 95% bootstrap CI) | Wilcoxon–Pratt p | CP-SAT driving-time saving (HL, 95% CI) | Wilcoxon–Pratt p |',
          '| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |']
    for label, result in (('Nearest-Next', dn), ('FCFS', df)):
        lo, hi = result['ci95']
        tlo, thi = result['driving_ci95']
        L.append(f"| {label} | {result['snapshots']} | {result['proposed_km']:,.1f} | {result['baseline_km']:,.1f} | {-result['hl_km']:.2f} ({-hi:.2f}, {-lo:.2f}) | {result['wilcoxon_p']:.4g} | {-result['hl_driving_min']:.2f} ({-thi:.2f}, {-tlo:.2f}) | {result['driving_wilcoxon_p']:.4g} |")
    L += ['', 'Secondary distance and driving-time p-values are Holm-adjusted across the four baseline-by-measure comparisons; see `metrics.json`.', '',
          '![Figure 1](e4_fig1_tasks_served.png)', '',
          '*Figure 1. Tasks served by each method across all 100 snapshots; whiskers are 95% Wilson intervals.*', '',
          '![Figure 2](e4_fig2_km_per_scenario.png)', '',
          '*Figure 2. Per-snapshot route distances for CP-SAT and Nearest-Next, restricted to snapshots with identical served task IDs and valid plans.*', '',
          '![Figure 3](e4_fig3_total_km.png)', '',
          '*Figure 3. Aggregate route-distance totals across all 100 snapshots. Methods may serve different task identities.*', '',
          '![Figure 4](e4_fig4_matched_task_savings.png)', '',
          '*Figure 4. Hodges–Lehmann paired road-distance savings for CP-SAT; positive values favour CP-SAT, with 95% bootstrap confidence intervals.*', '',
          '## Reproducibility and limitations', '',
          f"- Shared run ID: `{m['run_id']}`; admitted tasks: {m['admitted_task_total']} across {m['realised_units']} snapshots.",
          '- The figure and summaries are generated from scenario CSVs, route-detail CSVs, and manifests; no paper values are hard-coded.',
          '- Matched-snapshot inference conditions on identical served task sets; aggregate distance totals are descriptive and should not be interpreted as a paired causal comparison.',
          '- Each snapshot has five candidate tasks and two vehicles; vehicle routes are single trips and travel times do not model live traffic.', '']
    (OUT / 'summary.md').write_text('\n'.join(L), encoding='utf-8')


if __name__ == '__main__':
    main()
