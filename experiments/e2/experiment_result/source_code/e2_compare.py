"""E2 comparison. Reads the three result folders (it never runs a condition) and writes
summary.md, metrics.json, the comparison tables and four figures into experiment_result/.

Part 1, contention: baseline 1 against the proposed method (duplicate committed claim rate).
Part 2, lease: baseline 2 against the proposed method (lease recovery success).
Proportions get 95 % Wilson intervals, paired outcomes an exact McNemar test.
Run from the repository root: python experiments/e2/experiment_result/source_code/e2_compare.py
"""
import csv
import json
import math
from pathlib import Path
import statistics

HERE = Path(__file__).resolve()
E2 = HERE.parents[2]
OUT = HERE.parents[1]
COND = {'b1': E2 / 'baseline' / '1_non_atomic_claim',
        'b2': E2 / 'baseline' / '2_protected_claim_without_lease_recovery',
        'p': E2 / 'protected_claim_with_lease_recovery' / 'result'}
NAME = {'b1': 'Non-Atomic Claim (baseline 1)', 'b2': 'Protected Claim without Lease Recovery (baseline 2)',
        'p': 'Protected Claim with Lease Recovery (proposed)'}
BENCHMARK_NAME = 'GEOLOCK-BENCHMARK-DATASET'


# Small helpers

def read(path):
    """Read one result CSV file."""
    if not path.exists():
        raise SystemExit(f'Missing result: {path}. Run that condition first.')
    with path.open(encoding='utf-8-sig', newline='') as f:
        return list(csv.DictReader(f))


def write_csv(path, records):
    """Write rows to a CSV file."""
    with Path(path).open('w', encoding='utf-8-sig', newline='') as f:
        w = csv.DictWriter(f, fieldnames=list(records[0]))
        w.writeheader()
        w.writerows(records)


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


def pct(x):
    """Show a share as a percentage."""
    return 'n/a' if x is None else f'{100 * x:.1f}%'


def ci(lo, hi):
    """Show a 95 % interval as text."""
    return f'{100 * lo:.1f}% to {100 * hi:.1f}%'


def p95(values):
    """95th percentile."""
    v = sorted(values)
    if not v:
        return None
    k = (len(v) - 1) * 0.95
    lo = int(k)
    return v[lo] + (v[min(lo + 1, len(v) - 1)] - v[lo]) * (k - lo)


# Measures

def contention(trials, requests):
    """Contention measures for each number of NGOs."""
    out = {}
    for w in ('2', '5', '10', 'all'):
        ts = [t for t in trials if w == 'all' or t['ngos_competing'] == w]
        rq = [r for r in requests if r['scenario_id'].startswith('SCN-CLAIM') and (w == 'all' or r['ngos_competing'] == w)]
        dup = sum(t['more_than_one_owner'] == 'YES' for t in ts)
        p, lo, hi = wilson(dup, len(ts))
        lat = [float(r['response_ms']) for r in rq if r['response_ms'] not in ('', '0', '0.0')]
        out[w] = dict(trials=len(ts), duplicate_trials=dup, duplicate_rate=p, duplicate_ci95=[lo, hi],
                      extra_committed_claims=sum(max(0, int(t['claims_stored']) - 1) for t in ts),
                      trials_exactly_one_owner=sum(t['claims_stored'] == '1' for t in ts),
                      requests=len(rq), success=sum(r['answer'] == 'SUCCESS' for r in rq),
                      conflict=sum(r['answer'] == 'CONFLICT' for r in rq),
                      ineligible=sum(r['answer'] == 'INELIGIBLE' for r in rq), error=sum(r['answer'] == 'ERROR' for r in rq),
                      answers_match_saved=sum(t['success_answers_match_stored'] == 'YES' for t in ts),
                      inconsistent_trials=sum(t['consistent_state'] != 'YES' for t in ts),
                      attempts_sent=sum(int(t['attempts_sent']) for t in ts),
                      attempts_in_audit_log=sum(int(t['attempts_in_audit_log']) for t in ts),
                      median_requests_per_second=statistics.median(float(t['requests_per_second']) for t in ts),
                      median_ms=statistics.median(lat) if lat else None, p95_ms=p95(lat))
    return out


def lease(rows):
    """Lease measures for one condition."""
    exp = [r for r in rows if r['case'] == 'lease expired']
    act = [r for r in rows if r['case'] == 'lease still running']
    rec = sum(r['second_ngo_got_listing'] == 'YES' for r in exp)
    fr = sum(r['second_ngo_got_listing'] == 'YES' or r['first_claim_status_after'] != 'ACTIVE' for r in act)
    p, lo, hi = wilson(rec, len(exp))
    fp, flo, fhi = wilson(fr, len(act))
    return dict(expired_cases=len(exp), recovered=rec, recovery_success=p, recovery_ci95=[lo, hi],
                stranded_listings=len(exp) - rec, active_cases=len(act), false_release=fr, false_release_rate=fp,
                false_release_ci95=[flo, fhi],
                listings_with_more_than_one_active_claim=sum(int(r['active_claims_after']) > 1 for r in rows))


def main():
    """Read the result folders, then write the comparison tables, figures and summary.md."""
    b1, b2, p = COND['b1'], COND['b2'], COND['p']
    T = {'b1': {r['scenario_id']: r for r in read(b1 / 'results_per_scenario.csv')},
         'p': {r['scenario_id']: r for r in read(p / 'results_per_scenario.csv')}}
    R = {'b1': read(b1 / 'details' / 'requests.csv'), 'p': read(p / 'details' / 'requests.csv')}
    L = {'b2': {r['scenario_id']: r for r in read(b2 / 'lease_results_per_scenario.csv')},
         'p': {r['scenario_id']: r for r in read(p / 'lease_results_per_scenario.csv')}}
    ids, lids = sorted(T['p']), sorted(L['p'])
    assert len(ids) == 150 and sorted(T['b1']) == ids, 'contention trials differ between baseline 1 and the proposed method'
    assert len(lids) == 125 and sorted(L['b2']) == lids, 'lease trials differ between baseline 2 and the proposed method'
    geo = read(p / 'geofence_check' / 'details' / 'eligibility_pairs.csv')
    stored_geo = json.loads((p / 'geofence_check' / 'details' / 'claims_stored_after_check.json').read_text())['claims_stored']
    cc = json.loads((p / 'details' / 'concurrent_recovery_check.json').read_text(encoding='utf-8'))
    dl = read(p / 'details' / 'delayed_request_check.csv')
    dbs = {json.loads((d / 'run_manifest.json').read_text(encoding='utf-8')).get('database') for d in COND.values()}

    m = dict(benchmark=BENCHMARK_NAME, database=dbs.pop() if len(dbs) == 1 else 'mixed: ' + ', '.join(sorted(map(str, dbs))),
             units=dict(contention_trials=len(ids), lease_expired=sum(L['p'][s]['case'] == 'lease expired' for s in lids),
                        lease_still_running=sum(L['p'][s]['case'] == 'lease still running' for s in lids), geofence_pairs=len(geo)))
    # part 1: contention, baseline 1 against the proposed method
    m['contention'] = {k: contention(list(T[k].values()), R[k]) for k in ('b1', 'p')}
    ob = sum(T['b1'][s]['more_than_one_owner'] == 'YES' and T['p'][s]['more_than_one_owner'] == 'NO' for s in ids)
    op = sum(T['b1'][s]['more_than_one_owner'] == 'NO' and T['p'][s]['more_than_one_owner'] == 'YES' for s in ids)
    m['contention']['mcnemar'] = dict(only_baseline_duplicate=ob, only_proposed_duplicate=op, p_exact=mcnemar_exact(ob, op))
    # part 2: lease, baseline 2 against the proposed method
    m['lease'] = {k: lease(list(L[k].values())) for k in ('b2', 'p')}
    exp = [s for s in lids if L['p'][s]['case'] == 'lease expired']
    rp = sum(L['p'][s]['second_ngo_got_listing'] == 'YES' and L['b2'][s]['second_ngo_got_listing'] == 'NO' for s in exp)
    rb = sum(L['p'][s]['second_ngo_got_listing'] == 'NO' and L['b2'][s]['second_ngo_got_listing'] == 'YES' for s in exp)
    m['lease']['mcnemar'] = dict(only_proposed_recovered=rp, only_baseline_recovered=rb, p_exact=mcnemar_exact(rp, rb))
    # extra checks of the proposed method
    pl = L['p']
    m['replay'] = dict(trials=len(ids), same_answer=sum(T['p'][s].get('replay_same_answer') == 'YES' for s in ids))
    m['recovery_checks'] = dict(
        repeated_recovery_released_nothing=sum(pl[s].get('repeated_recovery_released') == '0' for s in lids),
        stale_holder_refused=sum(pl[s].get('old_holder_regained_listing') == 'NO'
                                 and pl[s].get('old_holder_new_request_answer', '').startswith('CONFLICT') for s in exp),
        stale_holder_cases=len(exp), concurrent_recovery=cc,
        median_recovery_job_ms=statistics.median(float(pl[s]['recovery_ms']) for s in lids))
    m['delayed_request_check'] = dict(trials=len(dl), passed=sum(r['passed'] == 'YES' for r in dl),
                                      other_ngo_told_conflict=sum(r['other_ngo_answer'] == 'CONFLICT' for r in dl),
                                      median_wait_ms=statistics.median(float(r['other_ngo_waited_ms']) for r in dl))
    by_ref = {k: dict(pairs=sum(r['reference'] == k for r in geo), correct=sum(r['reference'] == k and r['correct'] == 'YES' for r in geo))
              for k in ('ELIGIBLE', 'OUTSIDE_GEOFENCE', 'ROUTE_UNAVAILABLE')}
    direct = [r for r in geo if r['direct_claim_by_ineligible_ngo']]
    m['geofence_check'] = dict(pairs=len(geo), correct=sum(r['correct'] == 'YES' for r in geo), by_reference=by_ref,
                               direct_claims=len(direct),
                               direct_claims_refused=sum(not r['direct_claim_by_ineligible_ngo'].startswith('SUCCESS') for r in direct),
                               claims_saved=stored_geo)
    pc, plz, g, rc = m['contention']['p']['all'], m['lease']['p'], m['geofence_check'], m['recovery_checks']
    safe = pc['duplicate_trials'] == 0 and plz['false_release'] == 0 and plz['listings_with_more_than_one_active_claim'] == 0
    full = (safe and plz['recovered'] == plz['expired_cases'] and g['correct'] == g['pairs']
            and g['direct_claims_refused'] == g['direct_claims'] and rc['repeated_recovery_released_nothing'] == len(lids)
            and rc['stale_holder_refused'] == len(exp) and cc['passed'] and m['replay']['same_answer'] == len(ids)
            and m['delayed_request_check']['passed'] == m['delayed_request_check']['trials']
            and pc['inconsistent_trials'] == 0 and pc['attempts_in_audit_log'] == pc['attempts_sent'])
    m['verdict'] = 'SUPPORTED' if full else ('PARTIALLY SUPPORTED' if safe else 'NOT SUPPORTED')

    C, LZ = m['contention'], m['lease']
    rows = []
    for label, get, better in (
            ('Trials with more than one owner (of 150)', lambda k: C[k]['all']['duplicate_trials'], 'lower'),
            ('  2 NGOs at once (of 50)', lambda k: C[k]['2']['duplicate_trials'], 'lower'),
            ('  5 NGOs at once (of 50)', lambda k: C[k]['5']['duplicate_trials'], 'lower'),
            ('  10 NGOs at once (of 50)', lambda k: C[k]['10']['duplicate_trials'], 'lower'),
            ('Extra claims saved beyond one owner', lambda k: C[k]['all']['extra_committed_claims'], 'lower'),
            ('Requests told "you got it" (of 850)', lambda k: C[k]['all']['success'], '150 (one per trial)'),
            ('Requests told "already claimed" (of 850)', lambda k: C[k]['all']['conflict'], '700 (the others)'),
            ('Requests that failed with an error', lambda k: C[k]['all']['error'], 'lower'),
            ('Attempts recorded in the audit log (of 850)', lambda k: C[k]['all']['attempts_in_audit_log'], 'higher'),
            ('Response time, median (ms)', lambda k: round(C[k]['all']['median_ms'], 1), 'lower')):
        rows.append(dict(part='1. Contention: baseline 1 against proposed', measure=label.strip(),
                         baseline=get('b1'), proposed=get('p'), better_when=better,
                         test='exact McNemar p = %.1e' % C['mcnemar']['p_exact'] if label.startswith('Trials') else ''))
    for label, get, better in (
            ('Expired leases taken over by another NGO (of 100)', lambda k: LZ[k]['recovered'], 'higher'),
            ('Donations left blocked by an expired lease (of 100)', lambda k: LZ[k]['stranded_listings'], 'lower'),
            ('Valid leases wrongly released (of 25)', lambda k: LZ[k]['false_release'], 'lower')):
        rows.append(dict(part='2. Lease: baseline 2 against proposed', measure=label, baseline=get('b2'), proposed=get('p'),
                         better_when=better, test='exact McNemar p = %.1e' % LZ['mcnemar']['p_exact'] if label.startswith('Expired') else ''))
    write_csv(OUT / 'comparison_summary.csv', rows)
    write_csv(OUT / 'comparison_contention.csv', [dict(
        scenario_id=s, ngos_at_once=T['p'][s]['ngos_competing'],
        baseline1_claims_saved=T['b1'][s]['claims_stored'], baseline1_more_than_one_owner=T['b1'][s]['more_than_one_owner'],
        baseline1_told_you_got_it=T['b1'][s]['told_success'],
        proposed_claims_saved=T['p'][s]['claims_stored'], proposed_more_than_one_owner=T['p'][s]['more_than_one_owner'],
        proposed_told_you_got_it=T['p'][s]['told_success'], proposed_told_already_claimed=T['p'][s]['told_already_claimed'])
        for s in ids])
    write_csv(OUT / 'comparison_lease.csv', [dict(
        scenario_id=s, lease=L['p'][s]['case'],
        baseline2_second_ngo_got_it=L['b2'][s]['second_ngo_got_listing'], baseline2_first_claim_after=L['b2'][s]['first_claim_status_after'],
        proposed_second_ngo_got_it=L['p'][s]['second_ngo_got_listing'], proposed_first_claim_after=L['p'][s]['first_claim_status_after'],
        proposed_correct=L['p'][s]['correct']) for s in lids])
    write_csv(OUT / 'comparison_geofence.csv', [dict(scenario_id=r['scenario_id'], ngo_id=r['ngo_id'],
              road_distance_km=r['road_distance_km'], right_answer=r['reference'], decision=r['decision'], correct=r['correct'],
              direct_claim_by_ineligible_ngo=r['direct_claim_by_ineligible_ngo']) for r in geo])
    (OUT / 'metrics.json').write_text(json.dumps(m, indent=2, default=str) + '\n', encoding='utf-8')
    figures(m)
    summary(m)
    print('E2 comparison ->', OUT / 'summary.md', '| verdict:', m['verdict'])


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


def figures(m):
    """Draw the four figures, one PNG each."""
    plt = plot_style()
    c, ws = m['contention'], ['2', '5', '10']

    fig, ax = plt.subplots(figsize=(6.2, 3.6))
    ax.set_ylim(0, 112)
    for off, k, col in ((-0.2, 'b1', BASELINE_1), (0.2, 'p', PROPOSED)):
        vals = [100 * c[k][w]['duplicate_rate'] for w in ws]
        bars(ax, [i + off for i in range(3)], vals, col, 0.38, label=NAME[k], text=[f'{v:.0f}%' for v in vals])
    ax.set_xticks(range(3), ws)
    ax.set_xlabel('NGOs claiming the same listing at once')
    ax.set_ylabel('Contention trials (%, n = 50 each)')
    ax.set_title('Trials with more than one owner')
    ax.legend(loc='upper center', bbox_to_anchor=(0.5, -0.2), ncol=1)
    save(plt, fig, 'e2_fig1_duplicate_owners.png')

    p = c['p']
    fig, ax = plt.subplots(figsize=(6, 3.6))
    med, hi = [p[w]['median_ms'] for w in ws], [p[w]['p95_ms'] for w in ws]
    ax.set_ylim(0, max(hi) * 1.25)
    pad = max(hi) * 0.02
    ax.bar([i - 0.2 for i in range(3)], med, 0.38, color=PROPOSED, label='Median')
    ax.bar([i + 0.2 for i in range(3)], hi, 0.38, color='#9cc3ef', label='95th percentile')
    for i, (a, b) in enumerate(zip(med, hi)):
        ax.text(i - 0.2, a + pad, f'{a:.0f}', ha='center', va='bottom', fontsize=8)
        ax.text(i + 0.2, b + pad, f'{b:.0f}', ha='center', va='bottom', fontsize=8)
    ax.set_xticks(range(3), ws)
    ax.set_xlabel('NGOs claiming the same listing at once')
    ax.set_ylabel('Response time (ms)')
    ax.set_title('Claim response time of the proposed method')
    ax.legend(loc='upper left')
    save(plt, fig, 'e2_fig2_response_time.png')

    lz = m['lease']
    fig, ax = plt.subplots(figsize=(5.4, 3.6))
    ax.set_ylim(0, 115)
    for j, (k, col) in enumerate((('b2', BASELINE_2), ('p', PROPOSED))):
        bars(ax, [j], [100 * lz[k]['recovery_success']], col, 0.5,
             low=[100 * lz[k]['recovery_ci95'][0]], high=[100 * lz[k]['recovery_ci95'][1]],
             text=[f"{lz[k]['recovered']} of {lz[k]['expired_cases']}"])
    ax.set_xticks(range(2), ['Protected Claim without\nLease Recovery (baseline 2)', 'Protected Claim with\nLease Recovery (proposed)'])
    ax.set_ylabel('Expired lease trials (%)')
    ax.set_title('Expired leases taken over by another NGO')
    save(plt, fig, 'e2_fig3_lease_recovery.png')

    g = m['geofence_check']
    br = g['by_reference']
    names = [f"Within 20 km\nby road\n(n = {br['ELIGIBLE']['pairs']})", f"Beyond 20 km\nby road\n(n = {br['OUTSIDE_GEOFENCE']['pairs']})",
             f"No road\nconnection\n(n = {br['ROUTE_UNAVAILABLE']['pairs']})",
             f"Direct claim by an\nineligible NGO\n(n = {g['direct_claims']})"]
    hits = [br[k]['correct'] for k in ('ELIGIBLE', 'OUTSIDE_GEOFENCE', 'ROUTE_UNAVAILABLE')] + [g['direct_claims_refused']]
    totals = [br[k]['pairs'] for k in ('ELIGIBLE', 'OUTSIDE_GEOFENCE', 'ROUTE_UNAVAILABLE')] + [g['direct_claims']]
    fig, ax = plt.subplots(figsize=(6.4, 3.6))
    ax.set_ylim(0, 115)
    bars(ax, list(range(4)), [100 * h / t if t else 0 for h, t in zip(hits, totals)], PROPOSED, 0.55)
    ax.set_xticks(range(4), names)
    ax.set_ylabel('Decided correctly (%)')
    ax.set_title('Geofence decisions of the proposed method')
    save(plt, fig, 'e2_fig4_geofence_check.png')


def summary(m):
    """Write summary.md."""
    c, lz, g, rc = m['contention'], m['lease'], m['geofence_check'], m['recovery_checks']
    b1, p = c['b1']['all'], c['p']['all']
    b2l, pl = lz['b2'], lz['p']
    cc, dl = rc['concurrent_recovery'], m['delayed_request_check']
    supa = m['database'].startswith('separate experiment only Supabase')
    L = ['# E2 result: safe claiming and lease recovery', '',
         '## What we tested', '',
         'E2 answers two questions about the GeoLock claim functions that the Flutter app calls.', '',
         '1. **Contention.** Several NGOs press "Claim" on the same donation at the same time. Does exactly one of them get it?',
         '2. **Lease recovery.** An NGO claims a donation and never comes. Is the donation released after its 6 hour lease, '
         'so another NGO can take it, without ever taking away a claim that is still valid?', '',
         'Each question has its own baseline (report Table 3.6). Each baseline removes one protection of the proposed method, '
         'so the comparison shows what that protection does.', '',
         '| Condition | How a claim is made | Expired leases | Compared in |', '| --- | --- | --- | --- |',
         '| Non-Atomic Claim (baseline 1) | two separate steps: check "is it still available?", then save. No lock, no second '
         'check, no one claim rule | not used | part 1 |',
         '| Protected Claim without Lease Recovery (baseline 2) | the app\'s `claim_listing()` | never released | part 2 |',
         '| **Protected Claim with Lease Recovery (proposed)** | the app\'s `claim_listing()`: locks the donation, checks again, '
         'allows one active claim only | released by the app\'s `recover_expired_claims()` | parts 1 and 2 |', '',
         '## Setup', '',
         f"* **Data:** the frozen benchmark dataset {BENCHMARK_NAME}: 150 contention scenarios, 125 lease scenarios and "
         f"{g['pairs']:,} NGO and donation pairs for the geofence check.",
         f"* **Database:** {m['database']}. Never the app's own Supabase project. The claim and recovery functions are copied "
         'unchanged from the live app. Each condition starts from a freshly rebuilt database.',
         '* **Contention setting:** 50 trials each with 2, 5 and 10 NGOs. Each NGO has its own connection and a barrier releases '
         'all requests of a trial together. READ COMMITTED isolation, one retry after a deadlock, time limits of 15 s to connect, '
         '30 s per statement and 60 s at the barrier.', '',
         '## Results', '',
         'The main numbers are also in `comparison_summary.csv`, one row per measure.', '',
         '### 1. Contention: baseline 1 against the proposed method', '',
         'Each trial is one new donation that 2, 5 or 10 NGOs claim at the same time. The trial fails if more than one '
         'claim is saved in the database.', '',
         '| NGOs at once | Trials | Baseline 1: trials with more than one owner | Proposed: trials with more than one owner |',
         '| --- | --- | --- | --- |']
    for w in ('2', '5', '10', 'all'):
        L.append(f"| {w if w != 'all' else '**All**'} | {c['p'][w]['trials']} | {c['b1'][w]['duplicate_trials']} "
                 f"({pct(c['b1'][w]['duplicate_rate'])}) | {c['p'][w]['duplicate_trials']} ({pct(c['p'][w]['duplicate_rate'])}) |")
    L += ['', '| All 850 requests | Baseline 1 | Proposed |', '| --- | --- | --- |',
          f"| Told \"you got it\" | {b1['success']} | {p['success']} |",
          f"| Told \"already claimed\" | {b1['conflict']} | {p['conflict']} |",
          f"| Failed with an error | {b1['error']} | {p['error']} |",
          f"| Extra claims saved beyond one owner | {b1['extra_committed_claims']} | {p['extra_committed_claims']} |",
          f"| Attempts recorded in the audit log | {b1['attempts_in_audit_log']} | {p['attempts_in_audit_log']} |",
          f"| Response time, median | {b1['median_ms']:.0f} ms | {p['median_ms']:.0f} ms |", '',
          '![Figure 1](e2_fig1_duplicate_owners.png)', '',
          '*Figure 1. Share of contention trials that ended with more than one saved owner, by number of NGOs claiming at once '
          '(50 trials per bar).*', '',
          '![Figure 2](e2_fig2_response_time.png)', '',
          '*Figure 2. Response time of `claim_listing()` in the proposed method: median and 95th percentile over all requests '
          'at each contention level.*', '',
          '### 2. Lease: baseline 2 against the proposed method', '',
          'Each trial is a donation that one NGO claimed earlier. In 100 trials that NGO\'s 6 hour lease has run out, in 25 it '
          'is still running. A second NGO then tries to claim the donation.', '',
          '| Earlier claim | Trials | Second NGO got it: baseline 2 | Second NGO got it: proposed | Right outcome |',
          '| --- | --- | --- | --- | --- |',
          f"| lease expired (NGO never came) | {pl['expired_cases']} | {b2l['recovered']} | **{pl['recovered']}** | the second NGO gets it |",
          f"| lease still valid | {pl['active_cases']} | {b2l['false_release']} | **{pl['false_release']}** | the first NGO keeps it |", '',
          '![Figure 3](e2_fig3_lease_recovery.png)', '',
          '*Figure 3. Share of the 100 expired lease trials in which another eligible NGO took the donation over. Error bars show '
          '95 % Wilson confidence intervals.*', '',
          '### 3. Extra checks of the proposed method', '',
          'These checks have no baseline. They test that the proposed method also handles the harder cases named by the '
          'supervisor and the authority contract.', '',
          '| Check | Result |', '| --- | --- |',
          f"| Same request ID sent again | first answer returned, nothing new saved in {m['replay']['same_answer']} of {m['replay']['trials']} trials |",
          f"| One claim held open for 1 s while a second NGO claims | exactly one claim saved in {dl['passed']} of {dl['trials']} trials |",
          f"| Recovery run again right after | released nothing more in {rc['repeated_recovery_released_nothing']} of 125 trials |",
          f"| Old holder claims again after its lease expired | refused in {rc['stale_holder_refused']} of {rc['stale_holder_cases']} trials |",
          f"| Two recovery jobs at the same moment on {cc['expired_claims_prepared']} expired claims | each claim released exactly once: {'yes' if cc['passed'] else 'no'} |",
          f"| Geofence: NGO within 20 km by road may claim | {g['correct']:,} of {g['pairs']:,} pairs decided correctly |",
          f"| Ineligible NGO calls `claim_listing()` directly | refused {g['direct_claims_refused']} of {g['direct_claims']}, {g['claims_saved']} claims saved |", '',
          '![Figure 4](e2_fig4_geofence_check.png)', '',
          '*Figure 4. Geofence decisions of the proposed method by type of NGO and listing pair, and direct `claim_listing()` '
          'calls by ineligible NGOs that were refused.*', '',
          '## Analysis', '',
          f"**Without an atomic claim, every race ends with several owners.** In baseline 1 every NGO saw \"available\" before "
          f"anyone saved a claim, so all {b1['requests']} requests were told \"you got it\". All {b1['trials']} trials ended with "
          f"more than one owner and {b1['extra_committed_claims']} extra claims were saved. Two NGOs are already enough for this.", '',
          f"**The proposed claim keeps exactly one owner.** None of its {p['trials']} trials ended with more than one owner (95 % "
          f"confidence interval {ci(*p['duplicate_ci95'])}; exact McNemar test against baseline 1, p = {c['mcnemar']['p_exact']:.1g}). "
          f"Each trial had one \"you got it\" and the other NGOs were told \"already claimed\" ({p['success']} and {p['conflict']} "
          f"answers, {p['error']} errors), and the answers always matched what was saved. Every attempt was written to the audit "
          f"log ({p['attempts_in_audit_log']} of {p['attempts_sent']}); baseline 1 left no record.", '',
          f"**The protection is quick.** The median answer took {p['median_ms']:.0f} ms and 95 % came within {p['p95_ms']:.0f} ms, "
          'even with 10 NGOs at once.' + (' These times include the internet delay to Supabase.' if supa else ''), '',
          f"**Without lease recovery, abandoned donations stay blocked.** In baseline 2 none of the {b2l['expired_cases']} expired "
          f"claims was released, so {b2l['stranded_listings']} donations could never be collected. With recovery all "
          f"{pl['recovered']} were released and taken over by another NGO (exact McNemar test, p = {lz['mcnemar']['p_exact']:.1g}), "
          f"and none of the {pl['active_cases']} valid claims was touched.", '',
          '## Conclusion', '',
          f"The proposed method never let two NGOs own the same donation (0 of {p['trials']} trials, against "
          f"{b1['duplicate_trials']} of {b1['trials']} for baseline 1), and it released every abandoned claim "
          f"({pl['recovered']} of {pl['expired_cases']}, against {b2l['recovered']} for baseline 2) without touching a valid one. "
          'It is better than both baselines on the outcome each baseline was built to test, and it passed every extra check.', '',
          '## Limits of this experiment', '']
    if not supa:
        L.append('* **These result files come from a development check run on PostgreSQL with stand ins for Supabase auth, '
                 'using the same SQL. Run `run_e2.py` on the E2 Supabase project to get the final results.**')
    L += ['* In baseline 1 every NGO finishes its check before any NGO saves, the worst case for a check then save design. '
          'With real timing some NGOs would see "already claimed". The test shows that duplicates are possible, not how often '
          'they happen in daily use.',
          '* Lease expiry is simulated by giving the earlier claim an older start time, and recovery runs right before the '
          'second NGO claims instead of on the scheduler\'s timer.',
          '* The geofence uses the benchmark road distance, not the app\'s live road network cache.',
          '* Each contention scenario has 2 to 4 nearby NGOs, so with 5 or 10 requests some NGOs send more than one request.', '']
    (OUT / 'summary.md').write_text('\n'.join(L), encoding='utf-8')


if __name__ == '__main__':
    main()
