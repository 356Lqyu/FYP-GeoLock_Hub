"""E2 comparison. Reads the three methods in one run directory (it never runs a condition) and writes
summary.md, metrics.json, comparison tables and figures into that run's comparison/ folder.

Part 1, contention: all three methods (duplicate committed claim rate).
Part 2, lease: protected baseline against the proposed method (lease recovery success).
Proportions get 95 % Wilson intervals, paired outcomes an exact McNemar test.
Run through experiments/e2/run_e2.py after all three method outputs are complete.
"""
import csv
import hashlib
import json
import math
import os
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


def scenario_map(path, method):
    """Read trial rows without silently collapsing duplicated scenario IDs."""
    records = read(path)
    ids = [r['scenario_id'] for r in records]
    if len(ids) != len(set(ids)):
        raise SystemExit(f'{method} has duplicate contention scenario records.')
    return {r['scenario_id']: r for r in records}


def validate_contention_requests(method, trials, requests):
    """Require one saved row per scheduled request for every common contention trial."""
    rows = [r for r in requests if r['scenario_id'] in trials]
    expected = sum(int(t['ngos_competing']) for t in trials.values())
    if len(rows) != expected:
        raise SystemExit(f'{method} contention request count is {len(rows)}; expected {expected}.')
    ids = [r.get('request_id', '') for r in rows]
    if any(not value for value in ids) or len(ids) != len(set(ids)):
        raise SystemExit(f'{method} contention request IDs are missing or duplicated.')
    by_scenario = {}
    for row in rows:
        by_scenario.setdefault(row['scenario_id'], []).append(row)
    for sid, trial in trials.items():
        expected_ordinals = list(range(1, int(trial['ngos_competing']) + 1))
        ordinals = sorted(int(r['request_number']) for r in by_scenario.get(sid, []))
        if ordinals != expected_ordinals:
            raise SystemExit(f'{method} request ordinals do not match the scheduled requests in {sid}.')
    return rows


def validate_run_manifests(manifests, run_id):
    """Reject cross-run, cross-target, cross-input or incomplete method mixtures."""
    if set(manifests) != {'b1', 'b2', 'p'}:
        raise SystemExit('E2 comparison requires exactly the three primary methods.')
    if {m.get('experiment_run_id') for m in manifests.values()} != {run_id}:
        raise SystemExit('E2 methods have missing or mixed experiment run IDs.')
    identities = [m.get('target_identity') for m in manifests.values()]
    if any(not value for value in identities) or any(value != identities[0] for value in identities[1:]):
        raise SystemExit('E2 methods have mixed or missing database/project identities.')
    hashes = [m.get('input_sha256') for m in manifests.values()]
    if any(not value for value in hashes) or any(value != hashes[0] for value in hashes[1:]):
        raise SystemExit('E2 methods have mixed or missing benchmark hashes.')
    for key, manifest in manifests.items():
        if int(manifest.get('trials', -1)) != 150 or int(manifest.get('contention_requests', -1)) != 850:
            raise SystemExit(f'{key} is incomplete: expected 150 contention scenarios.')
        expected_leases = 0 if key == 'b1' else 125
        if int(manifest.get('lease_cases', -1)) != expected_leases:
            raise SystemExit(f'{key} is incomplete: expected {expected_leases} lease cases.')
        expected_expired, expected_active = (0, 0) if key == 'b1' else (100, 25)
        if int(manifest.get('expired_lease_cases', -1)) != expected_expired or int(manifest.get('active_lease_cases', -1)) != expected_active:
            raise SystemExit(f'{key} has incomplete expired/active lease case coverage.')
    return True


def validate_run_provenance(root_manifest, repo_root, input_dir):
    """Verify all source and frozen-input hashes recorded for the run."""
    source_hashes = root_manifest.get('source_sha256') or {}
    input_hashes = root_manifest.get('benchmark_input_sha256') or {}
    if not source_hashes or not input_hashes:
        raise SystemExit('E2 root manifest is missing source or benchmark hashes.')
    for rel_path, expected in source_hashes.items():
        path = Path(repo_root) / rel_path
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise SystemExit(f'E2 source changed since the run manifest was recorded: {rel_path}')
    generation = json.loads((Path(input_dir) / 'generation_manifest.json').read_text(encoding='utf-8'))
    for filename, expected in input_hashes.items():
        actual = hashlib.sha256((Path(input_dir) / filename).read_bytes()).hexdigest()
        if actual != expected or generation['generated_csv_sha256'].get(filename.removesuffix('.csv')) != actual:
            raise SystemExit(f'E2 frozen benchmark input hash changed: {filename}')
    return True


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
    contention_ids = {t['scenario_id'] for t in trials}
    for w in ('2', '5', '10', 'all'):
        ts = [t for t in trials if w == 'all' or t['ngos_competing'] == w]
        rq = [r for r in requests if r['scenario_id'] in contention_ids
              and (w == 'all' or r['ngos_competing'] == w)]
        dup = sum(t['more_than_one_owner'] == 'YES' for t in ts)
        p, lo, hi = wilson(dup, len(ts))
        lat = [float(r['response_ms']) for r in rq if r['response_ms'] not in ('', '0', '0.0')]
        states = {}
        for r in rq:
            for state in filter(None, (r.get('sqlstate') or '').split(';')):
                states[state] = states.get(state, 0) + 1
        scenario_medians = [float(t['median_response_ms']) for t in ts if t.get('median_response_ms') not in ('', None)]
        request_rates = [float(t['requests_per_second']) for t in ts if t.get('requests_per_second') not in ('', None)]
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
                      median_requests_per_second=statistics.median(request_rates) if request_rates else None,
                      median_ms=statistics.median(lat) if lat else None,
                      median_scenario_median_ms=statistics.median(scenario_medians) if scenario_medians else None,
                      p95_ms=p95(lat), sqlstate_counts=states,
                      sqlstate_40P01=states.get('40P01', 0), sqlstate_40001=states.get('40001', 0),
                      other_sqlstate_counts={k: v for k, v in states.items() if k not in ('40P01', '40001')})
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
    global OUT, COND
    run_root_raw = os.environ.get('GEOLOCK_E2_RUN_DIR')
    run_id = os.environ.get('GEOLOCK_E2_RUN_ID')
    if not run_root_raw or not run_id:
        raise SystemExit('Comparison requires GEOLOCK_E2_RUN_ID and GEOLOCK_E2_RUN_DIR from run_e2.py.')
    run_root = Path(run_root_raw).resolve()
    OUT = run_root / 'comparison'
    COND = {'b1': run_root / 'methods' / 'non_atomic_claim',
            'b2': run_root / 'methods' / 'protected_claim_without_lease_recovery',
            'p': run_root / 'methods' / 'protected_claim_with_lease_recovery'}
    if OUT.exists():
        raise SystemExit(f'Comparison output already exists; refusing to overwrite: {OUT}')
    root_manifest_path = run_root / 'run_manifest.json'
    if not root_manifest_path.is_file():
        raise SystemExit('Missing E2 root run manifest.')
    root_manifest = json.loads(root_manifest_path.read_text(encoding='utf-8'))
    if root_manifest.get('experiment_run_id') != run_id or root_manifest.get('status') != 'in_progress':
        raise SystemExit('E2 root manifest run ID/status is inconsistent.')
    repo_root = E2.parents[1]
    input_dir = repo_root / 'benchmark dataset' / 'dataset'
    validate_run_provenance(root_manifest, repo_root, input_dir)
    manifests = {}
    for key, path in COND.items():
        mp = path / 'run_manifest.json'
        if not mp.is_file():
            raise SystemExit(f'Missing complete method manifest: {mp}')
        manifests[key] = json.loads(mp.read_text(encoding='utf-8'))
    validate_run_manifests(manifests, run_id)
    if any(m.get('target_identity') != root_manifest.get('target_identity') for m in manifests.values()):
        raise SystemExit('Method manifests do not match the root run target identity.')
    if any(m.get('input_sha256') != root_manifest.get('benchmark_input_sha256') for m in manifests.values()):
        raise SystemExit('Method manifests do not match the root benchmark input hashes.')
    if any(m.get('source_sha256') != root_manifest.get('source_sha256') for m in manifests.values()):
        raise SystemExit('Method manifests do not match the root source hashes.')
    b1, b2, p = COND['b1'], COND['b2'], COND['p']
    T = {k: scenario_map(COND[k] / 'results_per_scenario.csv', k) for k in ('b1', 'b2', 'p')}
    R = {k: read(COND[k] / 'details' / 'requests.csv') for k in ('b1', 'b2', 'p')}
    L = {'b2': {r['scenario_id']: r for r in read(b2 / 'lease_results_per_scenario.csv')},
         'p': {r['scenario_id']: r for r in read(p / 'lease_results_per_scenario.csv')}}
    ids, lids = sorted(T['p']), sorted(L['p'])
    assert len(ids) == 150 and all(sorted(T[k]) == ids for k in ('b1', 'b2')), 'contention scenario IDs differ across methods'
    for k in ('b1', 'b2', 'p'):
        validate_contention_requests(k, T[k], R[k])
        if len(validate_contention_requests(k, T[k], R[k])) != 850:
            raise SystemExit(f'{k} must record exactly 850 contention requests.')
        assert len(T[k]) == 150, f'{k} must record exactly 150 contention trials'
        level_counts = {w: sum(t['ngos_competing'] == str(w) for t in T[k].values()) for w in (2, 5, 10)}
        assert level_counts == {2: 50, 5: 50, 10: 50}, f'{k} concurrency coverage differs: {level_counts}'
    assert len(lids) == 125 and sorted(L['b2']) == lids, 'lease trials differ between baseline 2 and the proposed method'
    geo = read(p / 'geofence_check' / 'details' / 'eligibility_pairs.csv')
    stored_geo = json.loads((p / 'geofence_check' / 'details' / 'claims_stored_after_check.json').read_text())['claims_stored']
    cc = json.loads((p / 'details' / 'concurrent_recovery_check.json').read_text(encoding='utf-8'))
    dl = read(p / 'details' / 'delayed_request_check.csv')
    dbs = {m.get('database') for m in manifests.values()}

    m = dict(benchmark=BENCHMARK_NAME, database=dbs.pop() if len(dbs) == 1 else 'mixed: ' + ', '.join(sorted(map(str, dbs))),
             units=dict(contention_trials=len(ids), lease_expired=sum(L['p'][s]['case'] == 'lease expired' for s in lids),
                        lease_still_running=sum(L['p'][s]['case'] == 'lease still running' for s in lids), geofence_pairs=len(geo)))
    # Part 1: all three methods independently run the same contention scenario IDs.
    m['contention'] = {k: contention(list(T[k].values()), R[k]) for k in ('b1', 'b2', 'p')}
    pair_tests = {}
    for a, b in (('b1', 'b2'), ('b1', 'p'), ('b2', 'p')):
        only_a = sum(T[a][s]['more_than_one_owner'] == 'YES' and T[b][s]['more_than_one_owner'] == 'NO' for s in ids)
        only_b = sum(T[a][s]['more_than_one_owner'] == 'NO' and T[b][s]['more_than_one_owner'] == 'YES' for s in ids)
        pair_tests[f'{a}_vs_{b}'] = {'only_a_duplicate': only_a, 'only_b_duplicate': only_b,
                                     'method_a': a, 'method_b': b,
                                     'p_exact': mcnemar_exact(only_a, only_b)}
    m['contention']['mcnemar'] = pair_tests
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
            ('Duplicate-trial rate, all scenarios (%)', lambda k: round(100 * C[k]['all']['duplicate_rate'], 2), 'lower'),
            ('Duplicate-trial 95% Wilson CI, all scenarios (%)',
             lambda k: f"{100*C[k]['all']['duplicate_ci95'][0]:.2f}–{100*C[k]['all']['duplicate_ci95'][1]:.2f}", 'lower'),
            ('  2 NGOs at once (of 50)', lambda k: C[k]['2']['duplicate_trials'], 'lower'),
            ('  5 NGOs at once (of 50)', lambda k: C[k]['5']['duplicate_trials'], 'lower'),
            ('  10 NGOs at once (of 50)', lambda k: C[k]['10']['duplicate_trials'], 'lower'),
            ('Extra claims saved beyond one owner', lambda k: C[k]['all']['extra_committed_claims'], 'lower'),
            ('Requests told "you got it" (of 850)', lambda k: C[k]['all']['success'], '150 (one per trial)'),
            ('Requests told "already claimed" (of 850)', lambda k: C[k]['all']['conflict'], '700 (the others)'),
            ('Requests that failed with an error', lambda k: C[k]['all']['error'], 'lower'),
            ('Attempts recorded in the audit log (of 850)', lambda k: C[k]['all']['attempts_in_audit_log'], 'higher'),
            ('Response time, median of scenario medians (ms)', lambda k: round(C[k]['all']['median_scenario_median_ms'], 1), 'lower'),
            ('Response time, pooled request median (ms)', lambda k: round(C[k]['all']['median_ms'], 1), 'lower'),
            ('Response time, pooled 95th percentile (ms)', lambda k: round(C[k]['all']['p95_ms'], 1), 'lower'),
            ('SQLSTATE 40P01 deadlocks', lambda k: C[k]['all']['sqlstate_40P01'], 'lower'),
            ('SQLSTATE 40001 serialization failures', lambda k: C[k]['all']['sqlstate_40001'], 'lower')):
        rows.append(dict(part='1. Contention: three-method comparison', measure=label.strip(),
                         non_atomic=get('b1'), protected_no_recovery=get('b2'), proposed=get('p'), better_when=better,
                         test=json.dumps(C['mcnemar'], sort_keys=True) if label.startswith('Trials') else ''))
    for w in ('2', '5', '10'):
        rows.append(dict(part=f'1. Contention at {w} concurrent requests', measure='Duplicate-trial rate (%)',
                         non_atomic=round(100 * C['b1'][w]['duplicate_rate'], 2),
                         protected_no_recovery=round(100 * C['b2'][w]['duplicate_rate'], 2),
                         proposed=round(100 * C['p'][w]['duplicate_rate'], 2), better_when='lower', test=''))
        rows.append(dict(part=f'1. Contention at {w} concurrent requests', measure='Duplicate-trial 95% Wilson CI (%)',
                         non_atomic=f"{100*C['b1'][w]['duplicate_ci95'][0]:.2f}–{100*C['b1'][w]['duplicate_ci95'][1]:.2f}",
                         protected_no_recovery=f"{100*C['b2'][w]['duplicate_ci95'][0]:.2f}–{100*C['b2'][w]['duplicate_ci95'][1]:.2f}",
                         proposed=f"{100*C['p'][w]['duplicate_ci95'][0]:.2f}–{100*C['p'][w]['duplicate_ci95'][1]:.2f}", better_when='lower', test=''))
        for label, metric in (('Median of scenario medians (ms)', 'median_scenario_median_ms'),
                              ('Pooled request median (ms)', 'median_ms'),
                              ('Pooled request P95 (ms)', 'p95_ms')):
            rows.append(dict(part=f'1. Contention at {w} concurrent requests', measure=label,
                             non_atomic=round(C['b1'][w][metric], 1),
                             protected_no_recovery=round(C['b2'][w][metric], 1),
                             proposed=round(C['p'][w][metric], 1), better_when='lower', test=''))
    for label, get, better in (
            ('Expired leases taken over by another NGO (of 100)', lambda k: LZ[k]['recovered'], 'higher'),
            ('Donations left blocked by an expired lease (of 100)', lambda k: LZ[k]['stranded_listings'], 'lower'),
            ('Valid leases wrongly released (of 25)', lambda k: LZ[k]['false_release'], 'lower')):
        rows.append(dict(part='2. Lease: baseline 2 against proposed', measure=label, non_atomic='N/A', protected_no_recovery=get('b2'), proposed=get('p'),
                         better_when=better, test='exact McNemar p = %.1e' % LZ['mcnemar']['p_exact'] if label.startswith('Expired') else ''))
    OUT.mkdir(parents=True, exist_ok=False)
    write_csv(OUT / 'comparison_summary.csv', rows)
    write_csv(OUT / 'comparison_contention.csv', [dict(
        scenario_id=s, ngos_at_once=T['p'][s]['ngos_competing'],
        baseline1_claims_saved=T['b1'][s]['claims_stored'], baseline1_more_than_one_owner=T['b1'][s]['more_than_one_owner'],
        baseline1_success=T['b1'][s]['told_success'], baseline1_conflict=T['b1'][s]['told_already_claimed'],
        baseline2_claims_saved=T['b2'][s]['claims_stored'], baseline2_more_than_one_owner=T['b2'][s]['more_than_one_owner'],
        baseline2_success=T['b2'][s]['told_success'], baseline2_conflict=T['b2'][s]['told_already_claimed'],
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
    methods = (('b1', BASELINE_1), ('b2', BASELINE_2), ('p', PROPOSED))
    for off, (k, col) in zip((-0.27, 0, 0.27), methods):
        vals = [100 * c[k][w]['duplicate_rate'] for w in ws]
        low = [100 * c[k][w]['duplicate_ci95'][0] for w in ws]
        high = [100 * c[k][w]['duplicate_ci95'][1] for w in ws]
        bars(ax, [i + off for i in range(3)], vals, col, 0.24, label=NAME[k],
             low=low, high=high, text=[f'{v:.0f}%' for v in vals], pad=1.1)
    ax.set_xticks(range(3), ws)
    ax.set_xlabel('NGOs claiming the same listing at once')
    ax.set_ylabel('Contention trials (%, n = 50 each)')
    ax.set_title('Trials with more than one owner')
    ax.legend(loc='upper center', bbox_to_anchor=(0.5, -0.2), ncol=1)
    save(plt, fig, 'e2_fig1_duplicate_owners.png')

    fig, ax = plt.subplots(figsize=(7.4, 4.2))
    # The comparator aggregates trial medians already rounded by the harness.
    medians = {k: [c[k][w]['median_scenario_median_ms'] for w in ws] for k, _ in methods}
    ax.set_ylim(0, max(max(values) for values in medians.values()) * 1.15 or 1)
    for off, (k, col), label in zip((-0.25, 0, 0.25), methods, ('Baseline 1', 'Baseline 2', 'Proposed')):
        group = ax.bar([i + off for i in range(3)], medians[k], 0.22, color=col, label=label)
        ax.bar_label(group, fmt='%.1f', padding=3, fontsize=8)
    ax.set_xticks(range(3), ws)
    ax.set_xlabel('Concurrent claim requests')
    ax.set_ylabel('Response time (ms)')
    ax.set_title('Claim response time by method and concurrency', pad=26)
    ax.legend(loc='lower center', bbox_to_anchor=(0.5, 1.01), ncol=3)
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
    """Write the three-method RQ2 summary and preserve method-specific comparisons."""
    c, lz, g, rc = m['contention'], m['lease'], m['geofence_check'], m['recovery_checks']
    labels = [('b1', 'Non-Atomic Claim'), ('b2', 'Protected Claim, no lease recovery'),
              ('p', 'Protected Claim with lease recovery (proposed)')]
    lines = ['# E2 result: protected claim and lease recovery', '',
             '## Contention: three primary methods', '',
             'All three methods used the same 150 frozen contention scenarios: 50 each with 2, 5, and 10 concurrent requests '
             '(850 requests per method). Request count is not a count of distinct NGO identities; the frozen scenario NGO pool '
             'may be reused when request count exceeds the number of eligible identities.', '',
             '| Method | Duplicate trials / 150 (95% Wilson CI) | SUCCESS | CONFLICT | ERROR | 40P01 | 40001 | Median of scenario medians (ms) | Pooled P95 (ms) |',
             '| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |']
    for key, label in labels:
        x = c[key]['all']
        lines.append(f"| {label} | {x['duplicate_trials']}/150 ({pct(x['duplicate_rate'])}; {ci(*x['duplicate_ci95'])}) | "
                     f"{x['success']} | {x['conflict']} | {x['error']} | {x['sqlstate_40P01']} | {x['sqlstate_40001']} | "
                     f"{x['median_scenario_median_ms']:.1f} | {x['p95_ms']:.1f} |")
    lines += ['', '### Contention by concurrent request level', '',
              '| Requests at once | Method | Trials | Duplicate trials (95% Wilson CI) | SUCCESS | CONFLICT | ERROR | Median of scenario medians (ms) |',
              '| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |']
    for w in ('2', '5', '10'):
        for key, label in labels:
            x = c[key][w]
            lines.append(f"| {w} | {label} | {x['trials']} | {x['duplicate_trials']} ({pct(x['duplicate_rate'])}; {ci(*x['duplicate_ci95'])}) | "
                         f"{x['success']} | {x['conflict']} | {x['error']} | {x['median_scenario_median_ms']:.1f} |")
    lines += ['', '### Paired duplicate-ownership tests', '',
              '| Pair | Only first method has duplicate ownership | Only second method has duplicate ownership | Exact McNemar p |',
              '| --- | ---: | ---: | ---: |']
    for pair, result in c['mcnemar'].items():
        lines.append(f"| {result['method_a']} vs {result['method_b']} | {result['only_a_duplicate']} | "
                     f"{result['only_b_duplicate']} | {result['p_exact']:.6g} |")
    lines += ['', 'The test uses each shared contention scenario as its paired unit.',
              '', '![Figure 1](e2_fig1_duplicate_owners.png)', '',
              '*Figure 1. Duplicate-ownership trial rates by method and concurrency; whiskers show 95% Wilson intervals.*', '',
              '![Figure 2](e2_fig2_response_time.png)', '',
              '*Figure 2. Claim response time by method and concurrency. Each bar represents the median of 50 contention-trial medians, measured in milliseconds.*', '',
              '## Lease recovery comparison', '',
              'Lease checks are separate from contention: both protected methods use 100 expired-lease cases and 25 active-lease controls. '
              'The non-atomic method has no lease mechanism and is not included in this comparison.', '',
              '| Measure | Protected, no recovery | Proposed, with recovery |', '| --- | ---: | ---: |',
              f"| Expired leases recovered (/100) | {lz['b2']['recovered']}/{lz['b2']['expired_cases']} | {lz['p']['recovered']}/{lz['p']['expired_cases']} |",
              f"| Active leases incorrectly released (/25) | {lz['b2']['false_release']}/{lz['b2']['active_cases']} | {lz['p']['false_release']}/{lz['p']['active_cases']} |",
              f"| Exact paired McNemar p | {lz['mcnemar']['p_exact']:.6g} |", '',
              '![Figure 3](e2_fig3_lease_recovery.png)', '',
              '*Figure 3. Expired-lease recovery with 95% Wilson intervals.*', '',
              '## Additional proposed-method checks', '',
              f"- Request replay returned the same answer in {m['replay']['same_answer']}/{m['replay']['trials']} contention trials.",
              f"- Repeated recovery released nothing additional in {rc['repeated_recovery_released_nothing']}/125 lease cases.",
              f"- Stale holder was refused in {rc['stale_holder_refused']}/{rc['stale_holder_cases']} expired cases.",
              f"- Concurrent recovery passed: {rc['concurrent_recovery']['passed']}.",
              f"- Geofence decisions correct: {g['correct']}/{g['pairs']}; direct ineligible claims refused: {g['direct_claims_refused']}/{g['direct_claims']}.", '',
              '![Figure 4](e2_fig4_geofence_check.png)', '',
              '## Reproducibility notes', '',
              f"- Frozen benchmark: {BENCHMARK_NAME}; input hashes are recorded in each method manifest.",
              f"- Database metadata: {m['database']} (see manifests; credentials are not recorded here).",
              '- Baseline 1 deliberately synchronizes its read step before its write step to expose the non-atomic race.',
              '- Retry behavior remains one retry using the same request ID after SQLSTATE 40P01 or 40001; every observed SQLSTATE is retained in request records.',
              '- Lease expiry is simulated from frozen claim-state timestamps; recovery is invoked directly for this controlled test.',
              '- Request counts at concurrency levels 5 and 10 may reuse NGO identities from the scenario’s eligible NGO pool.', '',
              f"**Assessment: {m['verdict']}.**"]
    (OUT / 'summary.md').write_text('\n'.join(lines) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()
