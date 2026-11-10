# Logic copied from "baseline implementation/source code/direct_household_pickup_baseline.py". Only the paths changed and parts not used here were removed.
"""E3 baseline: direct household pickup.

The small donations of each HUB_AGGREGATION scenario stay separate home pickups. The NGO
collects them with the Nearest-Next rule and no hub is used. This file only writes the
baseline's results; the comparison is done in experiment_result.
"""
FOLDER = 'direct_household_pickup'
TITLE = 'Direct household pickup (E3 baseline)'
# benchmark cost units, not money
COST_PER_KM = 1.00
COST_PER_TRIP = 5.00
SAVE_SNAPSHOTS = False

import argparse
from collections import defaultdict
import csv
from datetime import datetime, timedelta
import hashlib
import json
import math
from pathlib import Path
import sys
import time


def read_table(directory, name):
    """Read one benchmark table."""
    with (directory / (name + '.csv')).open(encoding='utf-8-sig', newline='') as stream:
        return list(csv.DictReader(stream))


def index_rows(rows, fields):
    """Index rows by key columns and stop on a duplicate key."""
    result = {}
    for row in rows:
        key = tuple(row[field] for field in fields)
        if key in result:
            raise ValueError(f'Duplicate {fields}: {key}')
        result[key] = row
    return result


def positive(value, label, allow_zero=False):
    """Parse a number and stop if it is negative (or zero when that is not allowed)."""
    number = float(value)
    if not math.isfinite(number) or number < 0 or (number == 0 and not allow_zero):
        raise ValueError(f'Invalid {label}: {value}')
    return number


def timestamp(value):
    # benchmark times are Malaysia local time; the computer clock is never used
    """Parse a benchmark time."""
    return datetime.fromisoformat(value)


def digest(value):
    """Stable SHA-256 of a JSON value."""
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def write_csv(path, rows, fields):
    """Write rows to a CSV file."""
    with path.open('w', encoding='utf-8-sig', newline='') as stream:
        writer = csv.DictWriter(stream, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def write_json(path, value):
    """Write a value to a JSON file."""
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')


def base_parser(description):
    """Command line options with their defaults."""
    parser = argparse.ArgumentParser(description=description)
    parser.add_argument('--dataset-dir', type=Path,
                        default=Path(__file__).resolve().parents[4] / 'benchmark dataset' / 'dataset')
    parser.add_argument('--output-dir', type=Path,
                        default=Path(__file__).resolve().parents[1] / FOLDER)
    parser.add_argument('--scenario-ids', type=Path, help='CSV scenario_id column or one ID per line')
    parser.add_argument('--geofence-km', type=float, default=20)
    parser.add_argument('--lease-minutes', type=float, default=360)
    return parser


def select_scenarios(data, kinds, selection):
    """The benchmark scenarios of the given types."""
    chosen = None
    if selection:
        text = selection.read_text(encoding='utf-8-sig')
        if not text.strip():
            raise ValueError('Empty scenario selection')
        if text.splitlines()[0].split(',')[0] == 'scenario_id':
            chosen = {row['scenario_id'] for row in csv.DictReader(text.splitlines())}
        else:
            chosen = {line.strip() for line in text.splitlines() if line.strip()}
    rows = [row for row in sorted(data.tables['scenarios'], key=lambda r: r['scenario_id'])
            if row['scenario_type'] in kinds and (chosen is None or row['scenario_id'] in chosen)]
    if chosen is not None and chosen != {r['scenario_id'] for r in rows}:
        raise ValueError('Selection includes unknown or wrong-type scenarios')
    if not rows:
        raise ValueError('No scenarios selected')
    return rows


class Benchmark:
    """The benchmark tables this baseline needs, checked against the manifest."""
    def __init__(self, directory, names):
        self.directory = directory
        self.manifest = json.loads((directory / 'generation_manifest.json').read_text(encoding='utf-8'))
        self.tables = {name: read_table(directory, name) for name in names}
        self.hashes = {name + '.csv': hashlib.sha256((directory / (name + '.csv')).read_bytes()).hexdigest()
                       for name in names}
        self.hashes['generation_manifest.json'] = hashlib.sha256((directory / 'generation_manifest.json').read_bytes()).hexdigest()
        for name in names:
            if self.manifest['generated_csv_sha256'][name] != self.hashes[name + '.csv']:
                raise ValueError(f'Input hash differs from generation manifest: {name}')
        self.members = defaultdict(list)
        for row in self.tables['scenario_members']:
            self.members[row['scenario_id']].append(row)
        self.ngos = index_rows(self.tables['ngos'], ('ngo_id',))
        self.matrix = index_rows(self.tables['road_distance_matrix'], ('from_node_id', 'to_node_id'))

    def ids(self, sid, kind, role):
        values = [r['entity_id'] for r in self.members[sid] if r['entity_type'] == kind and r['scenario_role'] == role]
        if len(values) != len(set(values)):
            raise ValueError(f'Duplicate scenario membership: {sid}/{role}')
        return sorted(values)

    def one(self, sid, kind, role):
        values = self.ids(sid, kind, role)
        if len(values) != 1:
            raise ValueError(f'Expected one {role} for {sid}')
        return values[0]

    def arc(self, origin, destination):
        row = self.matrix.get((str(origin), str(destination)))
        if row is None or row['route_available_flag'] == '0':
            return None
        if row['route_available_flag'] != '1':
            raise ValueError('Invalid road matrix record')
        return (positive(row['road_distance_km'], 'road distance', True),
                positive(row['travel_time_min'], 'travel time', True))

    def eligibility(self, ngo_id, node, radius):
        """App rule: road distance from NGO to pickup within the geofence radius."""
        arc = self.arc(self.ngos[(ngo_id,)]['road_node_id'], node)
        if arc is None:
            return 'ROUTE_UNAVAILABLE', None
        if arc[0] > radius:
            return 'OUTSIDE_GEOFENCE', arc[0]
        return 'ELIGIBLE', arc[0]

    def metadata(self, method, configuration):
        return dict(method=method, benchmark_version='GEOLOCK-BENCHMARK-DATASET',
                    matrix_id=self.manifest['matrix_id'],
                    input_sha256=self.hashes, runner_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                    python_version=sys.version.split()[0], configuration=configuration, configuration_id=digest(configuration),
                    timezone=self.manifest['fixture_timezone'],
                    run_type='BASELINE_METHOD_OUTPUT_NOT_EXPERIMENT_RESULT',
                    backend='IN_MEMORY_SIMULATION_NOT_POSTGRESQL', dispatch_authority_issued=False)

CONDITION = 'direct'
ROUTE_TABLES = ['scenarios', 'scenario_members', 'ngos', 'vehicles', 'donations', 'donors',
                'road_distance_matrix']


def setup_route_data(directory):
    """Load the benchmark tables needed for routing."""
    data = Benchmark(directory, ROUTE_TABLES)
    for name, key in [('vehicles', 'vehicle_id'), ('donations', 'donation_id'), ('donors', 'donor_id')]:
        setattr(data, name, index_rows(data.tables[name], (key,)))
    return data


def make_task(task_id, source_id, node, weight, created, owner, lease_minutes,
              service_minutes, listing_expires):
    """A confirmed task, created only after the claim is admitted."""
    if timestamp(created) >= timestamp(listing_expires):
        return None, 'LISTING_EXPIRED'
    positive(weight, 'task weight')
    positive(service_minutes, 'service time', True)
    return dict(task_id=task_id, source_id=source_id, road_node_id=node,
                weight_kg=float(weight), created_at=created, service_minutes=service_minutes,
                ngo_id=owner, claim_id='CLM-'+task_id, claim_status='ACTIVE',
                claim_expires_at=(timestamp(created)+timedelta(minutes=lease_minutes)).isoformat(),
                task_status='CONFIRMED', task_version=1), ''


def build_snapshot(data, scenario, args, condition='direct'):
    """Fixed planning snapshot of one scenario."""
    sid = scenario['scenario_id']
    owner = data.one(sid, 'NGO', 'SAME_COMPARISON_NGO')
    fleet = []
    for vid in data.ids(sid, 'VEHICLE', 'SAME_COMPARISON_FLEET'):
        v = data.vehicles[(vid,)]
        if v['ngo_id'] != owner:
            raise ValueError(f'Foreign vehicle: {sid}/{vid}')
        fleet.append(dict(vehicle_id=vid, ngo_id=owner, depot_road_node_id=v['depot_road_node_id'],
                          capacity_kg=positive(v['vehicle_capacity_kg'], 'vehicle capacity')))
    fleet.sort(key=lambda v: v['vehicle_id'])
    originals = data.ids(sid, 'DONATION', 'ORIGINAL_DONATION')
    donated = [data.donations[(did,)] for did in originals]
    if not donated or any(d['collection_path'] != 'COMMUNITY_HUB' for d in donated):
        raise ValueError(f'Aggregation scenario must hold small community hub donations: {sid}')
    # same cutoff as the hub condition: when the last donation becomes available
    cutoff = max(d['availability_start'] for d in donated)
    tasks, excluded = [], []
    for donation in sorted(donated, key=lambda d: d['donation_id']):
        did = donation['donation_id']
        node = data.donors[(donation['donor_id'],)]['road_node_id']
        task_id = 'TASK-' + did
        status, _ = data.eligibility(owner, node, args.geofence_km)
        if status != 'ELIGIBLE':
            excluded.append(dict(task_id=task_id, source_id=did, reason=status))
            continue
        task, reason = make_task(task_id, did, node, donation['weight_kg'], cutoff, owner,
                                 args.lease_minutes, args.service_minutes, donation['availability_end'])
        if task is None:
            excluded.append(dict(task_id=task_id, source_id=did, reason=reason))
        else:
            tasks.append(task)
    snapshot = dict(scenario_id=sid, scenario_type=scenario['scenario_type'],
                    scenario_profile=scenario['scenario_profile'], condition=condition,
                    ngo_id=owner, cutoff=cutoff, matrix_id=data.manifest['matrix_id'],
                    matrix_sha256=data.hashes['road_distance_matrix.csv'],
                    tasks=sorted(tasks, key=lambda t: t['task_id']), excluded_tasks=excluded, fleet=fleet,
                    original_donation_ids=originals,
                    claim_model='SERIAL_PROTECTED_IN_MEMORY_ADMISSION', dispatch_authority_issued=False)
    snapshot['planning_contract'] = route_configuration(args)
    snapshot['snapshot_id'] = digest(snapshot)
    return snapshot


def extension(data, snapshot, vehicle, current, load, elapsed, task, args):
    """Check whether a task still fits on the route; return the new times or the reason it does not fit."""
    if task['weight_kg'] + load > vehicle['capacity_kg'] + 1e-8:
        return None, 'CAPACITY_EXCEEDED'
    outward = data.arc(current, task['road_node_id'])
    home = data.arc(task['road_node_id'], vehicle['depot_road_node_id'])
    if outward is None or home is None:
        return None, 'ROUTE_UNAVAILABLE'
    completion = elapsed + outward[1] + task['service_minutes']
    if completion + home[1] > args.route_minutes + 1e-8:
        return None, 'ROUTE_DURATION_EXCEEDED'
    remaining_lease = (timestamp(task['claim_expires_at']) - timestamp(snapshot['cutoff'])).total_seconds()/60
    if task['claim_status'] != 'ACTIVE' or task['ngo_id'] != snapshot['ngo_id']:
        return None, 'INVALID_AUTHORITY'
    if remaining_lease + 1e-8 < completion + args.safety_margin_minutes:
        return None, 'LEASE_INSUFFICIENT'
    return (outward, completion), ''


def plan_routes(data, snapshot, args):
    """One route per vehicle, vehicles in ID order, each route ends at the depot."""
    unserved = {task['task_id']: task for task in snapshot['tasks']}
    routes = []
    for vehicle in snapshot['fleet']:
        current = vehicle['depot_road_node_id']
        load = elapsed = distance = travel = 0.0
        stops = []
        while unserved:
            feasible = []
            for task in unserved.values():
                addition, reason = extension(data, snapshot, vehicle, current, load, elapsed, task, args)
                if addition:
                    feasible.append((task, addition))
            if not feasible:
                break
            task, addition = min(feasible, key=lambda pair: (pair[1][0][0], pair[0]['task_id']))
            outward, completion = addition
            stops.append(dict(task_id=task['task_id'], road_node_id=task['road_node_id'],
                              arrival_elapsed_min=elapsed+outward[1], completion_elapsed_min=completion))
            load += task['weight_kg']
            elapsed = completion
            distance += outward[0]
            travel += outward[1]
            current = task['road_node_id']
            del unserved[task['task_id']]
        if stops:
            home = data.arc(current, vehicle['depot_road_node_id'])
            if home is None:
                raise ValueError('Invalid route return')
            routes.append(dict(vehicle_id=vehicle['vehicle_id'], depot_road_node_id=vehicle['depot_road_node_id'],
                               stops=stops, load_kg=load, road_distance_km=distance+home[0],
                               travel_time_min=travel+home[1], duration_min=elapsed+home[1]))
    reasons = {}
    for tid, task in unserved.items():
        if not snapshot['fleet']:
            reasons[tid] = 'NO_ACTIVE_VEHICLE'
            continue
        standalone_reasons = []
        for vehicle in snapshot['fleet']:
            addition, reason = extension(data, snapshot, vehicle, vehicle['depot_road_node_id'], 0, 0, task, args)
            standalone_reasons.append(reason)
        reasons[tid] = ('FLEET_CAPACITY_OR_ROUTE_BUDGET_EXHAUSTED' if '' in standalone_reasons
                        else '|'.join(sorted(set(standalone_reasons))))
    return routes, reasons


def validate_plan(data, snapshot, routes, unserved, args):
    """Recompute loads, distances, times and accounting from the stop IDs."""
    copy = dict(snapshot)
    expected_digest = copy.pop('snapshot_id')
    if digest(copy) != expected_digest:
        raise ValueError('Snapshot changed after sealing')
    tasks = {t['task_id']: t for t in snapshot['tasks']}
    fleet = {v['vehicle_id']: v for v in snapshot['fleet']}
    visited, used = set(), set()
    total_distance = total_travel = total_duration = total_load = 0.0
    for route in routes:
        vid = route['vehicle_id']
        if vid in used or vid not in fleet:
            raise ValueError('Duplicate or foreign vehicle')
        used.add(vid)
        vehicle = fleet[vid]
        node = vehicle['depot_road_node_id']
        if route['depot_road_node_id'] != node:
            raise ValueError('Wrong depot')
        load = elapsed = distance = travel = 0.0
        for stop in route['stops']:
            tid = stop['task_id']
            if tid in visited or tid not in tasks:
                raise ValueError('Duplicate or unknown served task')
            visited.add(tid)
            task = tasks[tid]
            if task['task_status'] != 'CONFIRMED' or task['task_version'] < 1:
                raise ValueError('Invalid confirmed task')
            arc = data.arc(node, task['road_node_id'])
            if arc is None or stop['road_node_id'] != task['road_node_id']:
                raise ValueError('Invalid route arc/node')
            arrival = elapsed + arc[1]
            elapsed = arrival + task['service_minutes']
            lease = (timestamp(task['claim_expires_at'])-timestamp(snapshot['cutoff'])).total_seconds()/60
            if task['claim_status'] != 'ACTIVE' or task['ngo_id'] != snapshot['ngo_id']:
                raise ValueError('Invalid task authority')
            if lease + 1e-8 < elapsed + args.safety_margin_minutes:
                raise ValueError('Lease insufficient at service completion')
            if not math.isclose(arrival, stop['arrival_elapsed_min'], abs_tol=1e-7) or not math.isclose(elapsed, stop['completion_elapsed_min'], abs_tol=1e-7):
                raise ValueError('Stop timing mismatch')
            load += task['weight_kg']
            distance += arc[0]
            travel += arc[1]
            node = task['road_node_id']
        home = data.arc(node, vehicle['depot_road_node_id'])
        if home is None:
            raise ValueError('Depot return unavailable')
        distance += home[0]
        travel += home[1]
        elapsed += home[1]
        if load > vehicle['capacity_kg'] + 1e-8 or elapsed > args.route_minutes + 1e-8:
            raise ValueError('Capacity or duration violation')
        for key, value in [('load_kg', load), ('road_distance_km', distance), ('travel_time_min', travel), ('duration_min', elapsed)]:
            if not math.isclose(route[key], value, abs_tol=1e-7):
                raise ValueError(f'Recomputed {key} mismatch')
        total_distance += distance
        total_travel += travel
        total_duration += elapsed
        total_load += load
    if visited & set(unserved) or visited | set(unserved) != set(tasks):
        raise ValueError('Exactly-once served/unserved accounting failed')
    return dict(served_tasks=len(visited), unserved_tasks=len(unserved),
                valid_task_count=len(tasks), excluded_task_count=len(snapshot['excluded_tasks']),
                valid_task_coverage=len(visited)/len(tasks) if tasks else None,
                ngo_road_distance_km=total_distance, travel_time_min=total_travel,
                route_duration_min=total_duration, collected_weight_kg=total_load,
                pickup_trips=len(routes), constraint_valid=1,
                plan_status='NO_VALID_TASKS' if not tasks else ('FEASIBLE' if not unserved else 'PARTIAL_COVERAGE'))


def route_parser():
    """Routing settings with their defaults."""
    parser = base_parser(__doc__)
    parser.add_argument('--snapshot-file', type=Path, help='Use sealed shared snapshots instead of synthesizing claims')
    parser.add_argument('--route-minutes', type=float, default=240)
    parser.add_argument('--service-minutes', type=float, default=10)
    parser.add_argument('--safety-margin-minutes', type=float, default=0,
                        help='Exploratory default 0; freeze a margin before formal dispatch evaluation')
    return parser


def route_configuration(args):
    """Routing settings stored in each planning snapshot."""
    return dict(geofence_km=positive(args.geofence_km, 'geofence radius'),
                lease_minutes=positive(args.lease_minutes, 'lease duration'),
                route_minutes=positive(args.route_minutes, 'route duration'),
                service_minutes=positive(args.service_minutes, 'service time', True),
                safety_margin_minutes=positive(args.safety_margin_minutes, 'safety margin', True),
                vehicle_order='ASCENDING_VEHICLE_ID', trips_per_vehicle=1,
                fcfs_infeasible_policy='SKIP_INFEASIBLE_AND_TRY_NEXT_TASK',
                cutoff='LATEST_DONATION_AVAILABILITY_START',
                claim_schedule='ALL_ORIGINALS_CLAIMED_AT_CUTOFF',
                downstream_routing='NEAREST_NEXT')


def append_evidence(snapshot, routes, unserved, metrics, results, route_rows, task_rows):
    """Add one scenario's routes and tasks to the output rows."""
    sid = snapshot['scenario_id']
    condition = snapshot['condition']
    results.append(dict(scenario_id=sid, condition=condition, snapshot_id=snapshot['snapshot_id'],
                        ngo_id=snapshot['ngo_id'], scenario_profile=snapshot['scenario_profile'], **metrics))
    assignments = {}
    for route in routes:
        route_rows.append(dict(scenario_id=sid, vehicle_id=route['vehicle_id'], depot_road_node_id=route['depot_road_node_id'],
                               stop_task_ids='|'.join(s['task_id'] for s in route['stops']),
                               load_kg=route['load_kg'], road_distance_km=route['road_distance_km'],
                               travel_time_min=route['travel_time_min'], duration_min=route['duration_min']))
        for i, stop in enumerate(route['stops'], 1):
            assignments[stop['task_id']] = (route['vehicle_id'], i, stop)
    for task in snapshot['tasks']:
        assigned = assignments.get(task['task_id'])
        task_rows.append(dict(scenario_id=sid, task_id=task['task_id'], source_id=task['source_id'],
                              status='SERVED' if assigned else 'UNSERVED', reason='' if assigned else unserved[task['task_id']],
                              vehicle_id=assigned[0] if assigned else '', stop_order=assigned[1] if assigned else '',
                              arrival_elapsed_min=assigned[2]['arrival_elapsed_min'] if assigned else '',
                              completion_elapsed_min=assigned[2]['completion_elapsed_min'] if assigned else ''))
    for task in snapshot['excluded_tasks']:
        task_rows.append(dict(scenario_id=sid, task_id=task['task_id'], source_id=task['source_id'],
                              status='EXCLUDED', reason=task['reason'], vehicle_id='', stop_order='',
                              arrival_elapsed_min='', completion_elapsed_min=''))


ROUTE_ROWS = []


def write_run_info(path, title, rows):
    """Record of what produced the results."""
    lines = [f'# Run information: {title}', '',
             'This file only records what produced the results in this folder, so the run can be repeated '
             'and checked. You do not need it to read the results.', '',
             '| Item | Value |', '| --- | --- |'] + [f'| {a} | {b} |' for a, b in rows] + ['']
    path.write_text('\n'.join(lines), encoding='utf-8')


def common_run_rows(manifest_path, script, command):
    """Rows shared by every run_info.md."""
    manifest = Path(manifest_path)
    version = 'GEOLOCK-BENCHMARK-DATASET'
    manifest_hash = hashlib.sha256(manifest.read_bytes()).hexdigest()[:16]
    script_hash = hashlib.sha256(Path(script).read_bytes()).hexdigest()[:16]
    return [('Run at', datetime.now().astimezone().strftime('%Y-%m-%d %H:%M %Z')),
            ('Benchmark', f'{version} (generation_manifest.json SHA-256 {manifest_hash}...; '
                          'every input CSV was checked against this manifest)'),
            ('Script', f'`{Path(script).name}` (SHA-256 {script_hash}...)'),
            ('Python', sys.version.split()[0]),
            ('Command to repeat', f'`{command}`')]


def save_route_outputs(args, data, configuration, results, route_rows, task_rows, snapshots):
    """Write the result CSV files and run_info.md."""
    out = args.output_dir
    (out / 'details').mkdir(parents=True, exist_ok=True)
    fleet = {s['scenario_id']: len(s['fleet']) for s in snapshots}
    longest = defaultdict(float)
    for r in route_rows:
        longest[r['scenario_id']] = max(longest[r['scenario_id']], r['duration_min'])
    yes = lambda v: 'YES' if v else 'NO'
    rows = []
    for r in results:
        sid = r['scenario_id']
        coverage = round(100 * r['served_tasks'] / r['valid_task_count'], 1) if r['valid_task_count'] else ''
        if CONDITION == 'direct':
            cost = COST_PER_KM * r['ngo_road_distance_km'] + COST_PER_TRIP * r['pickup_trips']
            rows.append(dict(scenario_id=sid, ngo_id=r['ngo_id'], vehicles_available=fleet[sid],
                             donations=r['valid_task_count'], donations_collected=r['served_tasks'],
                             coverage_percent=coverage, total_ngo_distance_km=round(r['ngo_road_distance_km'], 3),
                             total_driving_time_min=round(r['travel_time_min'], 1), vehicle_trips=r['pickup_trips'],
                             donor_travel_km=0, benchmark_cost=round(cost, 2),
                             cost_per_donation=round(cost / r['valid_task_count'], 2) if r['valid_task_count'] else '',
                             longest_route_min=round(longest[sid], 1), all_rules_passed=yes(r['constraint_valid']),
                             planning_time_ms=r['planning_runtime_ms']))
        else:
            rows.append(dict(scenario_id=sid, scenario_profile=r['scenario_profile'], ngo_id=r['ngo_id'],
                             vehicles_available=fleet[sid], tasks_valid=r['valid_task_count'],
                             tasks_collected=r['served_tasks'], tasks_not_collected=r['unserved_tasks'],
                             tasks_excluded=r['excluded_task_count'], coverage_percent=coverage,
                             total_distance_km=round(r['ngo_road_distance_km'], 3),
                             total_driving_time_min=round(r['travel_time_min'], 1), vehicle_trips=r['pickup_trips'],
                             longest_route_min=round(longest[sid], 1), all_rules_passed=yes(r['constraint_valid']),
                             planning_time_ms=r['planning_runtime_ms']))
    write_csv(out / 'results_per_scenario.csv', rows, list(rows[0]))
    write_csv(out / 'details' / 'routes.csv',
              [dict(scenario_id=r['scenario_id'], vehicle_id=r['vehicle_id'],
                    stops_in_order=' > '.join(r['stop_task_ids'].split('|')), stops=len(r['stop_task_ids'].split('|')),
                    load_kg=round(r['load_kg'], 2), distance_km=round(r['road_distance_km'], 3),
                    driving_time_min=round(r['travel_time_min'], 1), route_time_min=round(r['duration_min'], 1))
               for r in route_rows],
              ['scenario_id', 'vehicle_id', 'stops_in_order', 'stops', 'load_kg', 'distance_km', 'driving_time_min',
               'route_time_min'])
    write_csv(out / 'details' / 'tasks.csv',
              [dict(scenario_id=r['scenario_id'], task_id=r['task_id'], donation_id=r['source_id'], status=r['status'],
                    reason=r['reason'], vehicle_id=r['vehicle_id'], stop_number=r['stop_order'],
                    arrives_min_after_start=round(r['arrival_elapsed_min'], 1) if r['arrival_elapsed_min'] != '' else '',
                    finished_min_after_start=round(r['completion_elapsed_min'], 1) if r['completion_elapsed_min'] != '' else '')
               for r in sorted(task_rows, key=lambda r: (r['scenario_id'], {'SERVED': 0, 'UNSERVED': 1}.get(r['status'], 2),
                                                         r['vehicle_id'], r['stop_order'] or 0, r['task_id']))],
              ['scenario_id', 'task_id', 'donation_id', 'status', 'reason', 'vehicle_id', 'stop_number',
               'arrives_min_after_start', 'finished_min_after_start'])
    if SAVE_SNAPSHOTS:
        write_json(out / 'details' / 'planning_snapshots.json', snapshots)
    served = sum(r['served_tasks'] for r in results)
    valid = sum(r['valid_task_count'] for r in results)
    km = sum(r['ngo_road_distance_km'] for r in results)
    trips = sum(r['pickup_trips'] for r in results)
    run_rows = common_run_rows(args.dataset_dir / 'generation_manifest.json', __file__,
                               f'python {Path(__file__).name}' + (' --snapshot-file ...' if args.snapshot_file else ''))
    run_rows += [('Scenarios run', f"{len(results):,}" + (' (selected with --scenario-ids)' if args.scenario_ids else ' (all)')),
                 ('Planning input', 'shared snapshot file ' + args.snapshot_file.name if args.snapshot_file
                  else 'built from the benchmark (same snapshots as the other route baselines)'),
                 ('Settings', f"20 km geofence; 360 min lease; 240 min per route; 10 min per stop; "
                              f"safety margin {configuration['safety_margin_minutes']:g} min; one trip per vehicle"),
                 ('Note', 'Claims are taken as already protected; live dispatch authorisation is not part of this baseline')]
    write_run_info(out / 'run_info.md', TITLE, run_rows)
    ROUTE_ROWS[:] = route_rows
    print(f"{TITLE}: {served}/{valid} collected, {km:,.1f} km, {trips} trips -> {out}")


def load_shared_snapshots(path, data, scenarios, args):
    """Load planning snapshots saved earlier."""
    snapshots = json.loads(path.read_text(encoding='utf-8'))
    selected = {s['scenario_id'] for s in scenarios}
    expected_condition = {CONDITION}
    chosen = [s for s in snapshots if s['scenario_id'] in selected]
    pairs = [(s['scenario_id'],s['condition']) for s in chosen]
    if len(pairs)!=len(set(pairs)) or set(pairs)!={(sid,c) for sid in selected for c in expected_condition}:
        raise ValueError('Shared snapshot membership is incomplete or duplicated')
    for snapshot in chosen:
        unsealed = dict(snapshot)
        sealed_id = unsealed.pop('snapshot_id')
        if digest(unsealed)!=sealed_id:
            raise ValueError('Shared snapshot seal mismatch')
        if snapshot['matrix_id']!=data.manifest['matrix_id'] or snapshot['matrix_sha256']!=data.hashes['road_distance_matrix.csv']:
            raise ValueError('Shared snapshot road matrix differs')
        if snapshot.get('planning_contract')!=route_configuration(args):
            raise ValueError('Shared snapshot planning contract differs from CLI settings')
        if len({t['task_id'] for t in snapshot['tasks']})!=len(snapshot['tasks']):
            raise ValueError('Duplicate shared task identifiers')
        if len({v['vehicle_id'] for v in snapshot['fleet']})!=len(snapshot['fleet']):
            raise ValueError('Duplicate shared vehicle identifiers')
        for task in snapshot['tasks']:
            positive(task['weight_kg'], 'shared task weight')
            if task['service_minutes']!=args.service_minutes or task['task_status']!='CONFIRMED' or task['claim_status']!='ACTIVE':
                raise ValueError('Invalid shared task state/service time')
            if task['ngo_id']!=snapshot['ngo_id'] or timestamp(task['claim_expires_at'])<=timestamp(snapshot['cutoff']):
                raise ValueError('Invalid shared task authority')
            if task['task_version']<1 or timestamp(task['created_at'])>timestamp(snapshot['cutoff']):
                raise ValueError('Invalid shared task version/time')
        for vehicle in snapshot['fleet']:
            benchmark_vehicle=data.vehicles[(vehicle['vehicle_id'],)]
            if vehicle['ngo_id']!=snapshot['ngo_id'] or vehicle['depot_road_node_id']!=benchmark_vehicle['depot_road_node_id']:
                raise ValueError('Shared vehicle owner/depot differs')
            if vehicle['capacity_kg']!=float(benchmark_vehicle['vehicle_capacity_kg']):
                raise ValueError('Shared vehicle capacity differs')
    return {(s['scenario_id'],s['condition']):s for s in chosen}


def main():
    """Plan and check the direct pickup routes of every scenario and write the result folder."""
    parser = route_parser()
    args = parser.parse_args()
    configuration = route_configuration(args)
    data = setup_route_data(args.dataset_dir)
    scenarios = select_scenarios(data, ('HUB_AGGREGATION',), args.scenario_ids)
    configuration['selected_scenarios'] = [r['scenario_id'] for r in scenarios]
    shared = load_shared_snapshots(args.snapshot_file, data, scenarios, args) if args.snapshot_file else None
    configuration['snapshot_input_sha256'] = hashlib.sha256(args.snapshot_file.read_bytes()).hexdigest() if args.snapshot_file else None
    results, routes_output, tasks_output, snapshots = [], [], [], []
    for scenario in scenarios:
        snapshot = shared[(scenario['scenario_id'],CONDITION)] if shared else build_snapshot(data, scenario, args, CONDITION)
        started = time.perf_counter()
        routes, unserved = plan_routes(data, snapshot, args)
        runtime_ms = (time.perf_counter() - started) * 1000
        metrics = validate_plan(data, snapshot, routes, unserved, args)
        metrics['planning_runtime_ms'] = round(runtime_ms, 3)
        metrics['original_donations'] = len(snapshot['original_donation_ids'])
        metrics['collected_original_donations'] = metrics['served_tasks']
        append_evidence(snapshot, routes, unserved, metrics, results, routes_output, tasks_output)
        snapshots.append(snapshot)
    save_route_outputs(args, data, configuration, results, routes_output, tasks_output, snapshots)


if __name__ == '__main__':
    main()
