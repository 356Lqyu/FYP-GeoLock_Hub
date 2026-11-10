"""E3 proposed method: community hub aggregation, following the app's hub workflow.

For each HUB_AGGREGATION scenario:
  1. each donation reserves hub capacity (five hard rules, capacity never exceeded)
  2. each donor drops off inside their own time window and the hub's opening hours
  3. the received items form one batch (3 to 5 donations, at most 30 kg, one category)
  4. the batch is published as one listing and the NGO claims it (within 20 km by road)
  5. the NGO collects it with the same planner and validator as the baseline
A scenario that breaks a rule keeps its donations as home pickups and is reported.
Run from the repository root: python experiments/e3/hub_aggregation/source_code/run_hub_aggregation.py
"""
import importlib.util
import statistics
import sys
import time
from datetime import timedelta
from pathlib import Path
import platform
import json
import hashlib
from datetime import datetime
import csv

HERE = Path(__file__).resolve()
ROOT = HERE.parents[4]

BATCH_MIN, BATCH_MAX, BATCH_MAX_KG = 3, 5, 30.0  # coordination_config in the app
COST_PER_KM, COST_PER_TRIP, COST_PER_HUB_DONATION = 1.00, 5.00, 0.50  # report cost formula


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


def rows(table):
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


def baseline_module():
    """Load the baseline file, so the same code is reused here."""
    path = HERE.parents[2] / 'baseline' / 'source_code' / 'direct_household_pickup_baseline.py'
    spec = importlib.util.spec_from_file_location('direct_household_pickup_baseline', path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def minutes(hhmm):
    """Minutes since midnight for an HH:MM time."""
    h, m = hhmm.split(':')[:2]
    return int(h) * 60 + int(m)


def main():
    """Run the hub workflow and routing for every scenario and write the result folder."""
    base = baseline_module()
    args = base.route_parser().parse_args(sys.argv[1:])
    out = HERE.parents[1] / 'result'
    data = base.setup_route_data(args.dataset_dir)
    hashes = check_inputs(['hubs', 'hub_batches', 'hub_batch_members', 'donation_hub_candidates', 'donors', 'donations'])
    hubs = {r['hub_id']: r for r in rows('hubs')}
    batches = {r['batch_id']: r for r in rows('hub_batches')}
    members = {}
    for r in rows('hub_batch_members'):
        members.setdefault(r['batch_id'], []).append(r)
    feasible = {(r['donation_id'], r['hub_id']): r for r in rows('donation_hub_candidates')}
    scenarios = base.select_scenarios(data, ('HUB_AGGREGATION',), None)
    results, route_rows, task_rows, integrity, donor_rows = [], [], [], [], []
    for sc in scenarios:
        sid = sc['scenario_id']
        started = time.perf_counter()
        owner = data.one(sid, 'NGO', 'SAME_COMPARISON_NGO')
        hub_id = data.one(sid, 'HUB', 'CANDIDATE_AGGREGATION_SITE')
        batch_id = data.one(sid, 'HUB_BATCH', 'UNCOMMITTED_GROUP_TEMPLATE')
        hub, batch = hubs[hub_id], batches[batch_id]
        originals = data.ids(sid, 'DONATION', 'ORIGINAL_DONATION')
        donated = [data.donations[(d,)] for d in originals]
        mem = {m['donation_id']: m for m in members[batch_id]}
        checks = {}
        # 1. reservation
        free = float(hub['hub_capacity_kg']) - float(hub['hub_load_kg']) - float(hub['hub_reserved_kg'])
        reserved = 0.0
        ok_rules = True
        for d in sorted(donated, key=lambda d: mem[d['donation_id']]['added_at']):
            c = feasible.get((d['donation_id'], hub_id))
            ok_rules &= bool(c) and c['feasible_flag'] == '1'
            reserved += float(d['weight_kg'])
        checks['hub_passes_five_rules_for_every_donation'] = ok_rules
        checks['reservations_fit_free_capacity'] = reserved <= free + 1e-9
        checks['hub_active'] = hub['hub_active_flag'] == '1'
        # 2. drop off and receipt
        open_m, close_m = minutes(hub['operating_start']), minutes(hub['operating_end'])
        in_window = all(d['availability_start'] <= mem[d['donation_id']]['added_at'] <= d['availability_end'] for d in donated)
        in_hours = all(open_m <= minutes(mem[d['donation_id']]['added_at'][11:16]) <= close_m for d in donated)
        checks['drop_off_inside_donor_window'] = in_window
        checks['drop_off_inside_hub_opening_hours'] = in_hours
        # 3. batch
        cats = {d['category'] for d in donated}
        weight = round(sum(float(d['weight_kg']) for d in donated), 3)
        checks['members_equal_batch_template'] = set(mem) == set(originals)
        checks['batch_size_3_to_5'] = BATCH_MIN <= len(donated) <= BATCH_MAX
        checks['batch_weight_at_most_30kg'] = weight <= BATCH_MAX_KG + 1e-9
        checks['one_category'] = len(cats) == 1 and batch['batch_category'] in cats
        checks['batch_weight_matches_template'] = abs(weight - float(batch['batch_weight_kg'])) < 0.01
        checks['all_small_donations'] = all(d['collection_path'] == 'COMMUNITY_HUB' and float(d['weight_kg']) < 10 for d in donated)
        # 4. publication and claim
        elig, km = data.eligibility(owner, hub['road_node_id'], args.geofence_km)
        checks['ngo_within_20km_road_of_hub'] = elig == 'ELIGIBLE'
        aggregate = all(checks.values())
        integrity.append(dict(scenario_id=sid, hub_id=hub_id, batch_id=batch_id, donations=len(donated),
                              batch_weight_kg=weight, category='|'.join(sorted(cats)),
                              **{k: 'YES' if v else 'NO' for k, v in checks.items()}, aggregated='YES' if aggregate else 'NO'))
        # 5. routing
        fleet = []
        for vid in data.ids(sid, 'VEHICLE', 'SAME_COMPARISON_FLEET'):
            v = data.vehicles[(vid,)]
            fleet.append(dict(vehicle_id=vid, ngo_id=owner, depot_road_node_id=v['depot_road_node_id'],
                              capacity_kg=float(v['vehicle_capacity_kg'])))
        fleet.sort(key=lambda v: v['vehicle_id'])
        cutoff = max(d['availability_start'] for d in donated)  # same cutoff as the baseline
        tasks, excluded = [], []
        donor_km = 0.0
        if aggregate:
            # the items are already at the hub, so only the 360 minute lease limits the listing
            expires = (base.timestamp(cutoff) + timedelta(days=7)).isoformat()
            t, reason = base.make_task('TASK-' + batch_id, batch_id, hub['road_node_id'], weight, cutoff, owner,
                                       args.lease_minutes, args.service_minutes, expires)
            (tasks.append(t) if t else excluded.append(dict(task_id='TASK-' + batch_id, source_id=batch_id, reason=reason)))
            for d in donated:
                node = data.donors[(d['donor_id'],)]['road_node_id']
                go, back = data.arc(node, hub['road_node_id']), data.arc(hub['road_node_id'], node)
                trip = (go[0] if go else float('nan')) + (back[0] if back else float('nan'))
                donor_km += trip
                donor_rows.append(dict(scenario_id=sid, donation_id=d['donation_id'], donor_id=d['donor_id'], hub_id=hub_id,
                                       to_hub_km=go[0] if go else '', back_home_km=back[0] if back else '', round_trip_km=round(trip, 3)))
        else:  # a rule was broken: the donations stay home pickups
            for d in sorted(donated, key=lambda d: d['donation_id']):
                node = data.donors[(d['donor_id'],)]['road_node_id']
                t, reason = base.make_task('TASK-' + d['donation_id'], d['donation_id'], node, d['weight_kg'], cutoff,
                                           owner, args.lease_minutes, args.service_minutes, d['availability_end'])
                (tasks.append(t) if t else excluded.append(dict(task_id='TASK-' + d['donation_id'], source_id=d['donation_id'], reason=reason)))
        snapshot = dict(scenario_id=sid, scenario_type=sc['scenario_type'], scenario_profile=sc['scenario_profile'],
                        condition='hub' if aggregate else 'hub_fallback_direct', ngo_id=owner, cutoff=cutoff,
                        matrix_id=data.manifest['matrix_id'], matrix_sha256=data.hashes['road_distance_matrix.csv'],
                        tasks=sorted(tasks, key=lambda t: t['task_id']), excluded_tasks=excluded, fleet=fleet,
                        original_donation_ids=originals, hub_id=hub_id, batch_id=batch_id,
                        claim_model='SERIAL_PROTECTED_IN_MEMORY_ADMISSION', dispatch_authority_issued=False)
        snapshot['planning_contract'] = base.route_configuration(args)
        snapshot['snapshot_id'] = base.digest(snapshot)
        routes, unserved = base.plan_routes(data, snapshot, args)
        m = base.validate_plan(data, snapshot, routes, unserved, args)
        ms = (time.perf_counter() - started) * 1000
        collected = len(donated) if aggregate and m['served_tasks'] == 1 else (m['served_tasks'] if not aggregate else 0)
        hub_donations = len(donated) if aggregate else 0
        cost = COST_PER_KM * m['ngo_road_distance_km'] + COST_PER_TRIP * m['pickup_trips'] + COST_PER_HUB_DONATION * hub_donations
        results.append(dict(
            scenario_id=sid, ngo_id=owner, hub_id=hub_id, batch_id=batch_id, vehicles_available=len(fleet),
            donations=len(donated), donations_collected=collected,
            coverage_percent=round(100 * collected / len(donated), 1), aggregated='YES' if aggregate else 'NO',
            ngo_stops=sum(len(r['stops']) for r in routes),
            total_ngo_distance_km=round(m['ngo_road_distance_km'], 3), total_driving_time_min=round(m['travel_time_min'], 1),
            vehicle_trips=m['pickup_trips'], donor_travel_km=round(donor_km, 3),
            total_travel_km=round(m['ngo_road_distance_km'] + donor_km, 3),
            donations_handled_at_hub=hub_donations, benchmark_cost=round(cost, 2),
            cost_per_donation=round(cost / len(donated), 2),
            longest_route_min=round(max((r['duration_min'] for r in routes), default=0), 1),
            all_rules_passed='YES' if m['constraint_valid'] == 1 else 'NO', planning_time_ms=round(ms, 3)))
        for r in routes:
            route_rows.append(dict(scenario_id=sid, vehicle_id=r['vehicle_id'],
                                   stops_in_order=' > '.join(s['task_id'] for s in r['stops']), stops=len(r['stops']),
                                   load_kg=round(r['load_kg'], 3), distance_km=round(r['road_distance_km'], 3),
                                   driving_time_min=round(r['travel_time_min'], 1), route_time_min=round(r['duration_min'], 1)))
        for t in snapshot['tasks']:
            task_rows.append(dict(scenario_id=sid, task_id=t['task_id'], source_id=t['source_id'], weight_kg=t['weight_kg'],
                                  status='UNSERVED' if t['task_id'] in unserved else 'SERVED',
                                  reason=unserved.get(t['task_id'], '')))
    write_csv(out / 'results_per_scenario.csv', results)
    write_csv(out / 'details' / 'routes.csv', route_rows)
    write_csv(out / 'details' / 'tasks.csv', task_rows)
    write_csv(out / 'details' / 'batch_integrity_checks.csv', integrity)
    write_csv(out / 'details' / 'donor_trips_to_hub.csv', donor_rows)
    env = environment()
    agg = sum(r['aggregated'] == 'YES' for r in results)
    run_info(out / 'run_info.md', 'Community hub aggregation (E3 proposed)', [
        ('Run at', env['run_at']), ('Benchmark', f"GEOLOCK-BENCHMARK-DATASET (inputs checked against the manifest)"),
        ('Scenarios', f'{len(results)} HUB_AGGREGATION; {agg} aggregated, {len(results) - agg} kept as direct pickups'),
        ('Hub workflow rules', f'five hard rules + capacity; drop off in donor window and hub hours; batch {BATCH_MIN}-{BATCH_MAX} items, '
                               f'<= {BATCH_MAX_KG:g} kg, one category; NGO <= {args.geofence_km:g} km road from hub'),
        ('Routing', 'Nearest-Next + independent validator imported from the baseline (identical code)'),
        ('Settings', f'{args.route_minutes:g}-min route, {args.service_minutes:g} min per stop, {args.lease_minutes:g}-min lease, '
                     'one trip per vehicle, cutoff = last donation available'),
        ('Cost index', f'{COST_PER_KM} x NGO km + {COST_PER_TRIP} x trips + {COST_PER_HUB_DONATION} x donations handled at a hub'),
        ('Runner', f'{HERE.name} SHA-256 {sha256(HERE)[:16]}...'), ('Python', env['python'])])
    write_json(out / 'run_manifest.json', dict(method='hub_aggregation', input_sha256={**data.hashes, **hashes}, environment=env))
    print(f"Hub aggregation: {agg}/{len(results)} aggregated, "
          f"{sum(r['donations_collected'] for r in results)}/{sum(r['donations'] for r in results)} donations collected, "
          f"{sum(r['total_ngo_distance_km'] for r in results):,.1f} NGO km, "
          f"median donor travel {statistics.median(r['donor_travel_km'] for r in results):.1f} km per scenario -> {out}")


if __name__ == '__main__':
    main()
