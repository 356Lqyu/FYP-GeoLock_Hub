# Logic copied from "baseline implementation/source code/nearest_next_baseline.py". Only the paths changed and parts not used here were removed.
"""E4 baseline 1: Nearest-Next routing.

Each vehicle drives to the nearest pickup it can still fit and finish in time. Running this
file plans the 100 shared snapshots and checks every plan with the same validator as the
other methods (test_harness/e4_shared.py).
"""
FOLDER = '1_nearest_next'
# benchmark cost units, not money

from collections import defaultdict
import csv
from datetime import datetime, timedelta
import hashlib
import json
import math
from pathlib import Path
import sys


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

ROUTE_TABLES = ['scenarios', 'scenario_members', 'ngos', 'vehicles', 'listings', 'road_distance_matrix']


def setup_route_data(directory):
    """Load the benchmark tables needed for routing."""
    data = Benchmark(directory, ROUTE_TABLES)
    for name, key in [('vehicles', 'vehicle_id'), ('listings', 'listing_id')]:
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


def build_snapshot(data, scenario, args, condition='route'):
    """Fixed planning snapshot of the confirmed tasks of one scenario."""
    sid = scenario['scenario_id']
    owner = data.one(sid, 'NGO', 'INTENDED_CLAIMANT')
    fleet = []
    for vid in data.ids(sid, 'VEHICLE', 'AVAILABLE_FLEET'):
        v = data.vehicles[(vid,)]
        if v['ngo_id'] != owner:
            raise ValueError(f'Foreign vehicle: {sid}/{vid}')
        fleet.append(dict(vehicle_id=vid, ngo_id=owner, depot_road_node_id=v['depot_road_node_id'],
                          capacity_kg=positive(v['vehicle_capacity_kg'], 'vehicle capacity')))
    fleet.sort(key=lambda v: v['vehicle_id'])
    listing_rows = [data.listings[(lid,)] for lid in data.ids(sid, 'LISTING', 'INITIAL_AVAILABLE_LISTING')]
    if not listing_rows:
        raise ValueError(f'Empty route input: {sid}')
    listing_rows.sort(key=lambda row: (row['created_at'], row['listing_id']))
    # claims are admitted one per second after the last listing opens
    schedule_start = timestamp(max(r['created_at'] for r in listing_rows))
    claim_times = {row['listing_id']: (schedule_start + timedelta(seconds=i)).isoformat()
                   for i, row in enumerate(listing_rows)}
    cutoff = (schedule_start + timedelta(seconds=len(listing_rows))).isoformat()
    tasks, excluded = [], []
    for row in listing_rows:
        task_id = 'TASK-' + row['listing_id']
        status, _ = data.eligibility(owner, row['pickup_road_node_id'], args.geofence_km)
        if status != 'ELIGIBLE':
            excluded.append(dict(task_id=task_id, source_id=row['donation_id'], reason=status))
            continue
        task, reason = make_task(task_id, row['donation_id'], row['pickup_road_node_id'], row['listing_weight_kg'],
                                 claim_times[row['listing_id']], owner, args.lease_minutes,
                                 args.service_minutes, row['listing_expires_at'])
        if task is None:
            excluded.append(dict(task_id=task_id, source_id=row['donation_id'], reason=reason))
        else:
            tasks.append(task)
    snapshot = dict(scenario_id=sid, scenario_type=scenario['scenario_type'],
                    scenario_profile=scenario['scenario_profile'], condition=condition,
                    ngo_id=owner, cutoff=cutoff, matrix_id=data.manifest['matrix_id'],
                    matrix_sha256=data.hashes['road_distance_matrix.csv'],
                    tasks=sorted(tasks, key=lambda t: t['task_id']), excluded_tasks=excluded, fleet=fleet,
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


def route_configuration(args):
    """Routing settings stored in each planning snapshot."""
    return dict(geofence_km=positive(args.geofence_km, 'geofence radius'),
                lease_minutes=positive(args.lease_minutes, 'lease duration'),
                route_minutes=positive(args.route_minutes, 'route duration'),
                service_minutes=positive(args.service_minutes, 'service time', True),
                safety_margin_minutes=positive(args.safety_margin_minutes, 'safety margin', True),
                vehicle_order='ASCENDING_VEHICLE_ID', trips_per_vehicle=1,
                fcfs_infeasible_policy='SKIP_INFEASIBLE_AND_TRY_NEXT_TASK',
                cutoff='AFTER_FINAL_SCHEDULED_CLAIM',
                claim_schedule='LISTING_CREATED_AT_THEN_LISTING_ID_ONE_SECOND_SPACING')


if __name__ == '__main__':
    # E4 run on the shared snapshots (main() above is the old stand alone run and is not used)
    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'test_harness'))
    from e4_shared import run_and_save
    run_and_save('nearest_next', Path(__file__).resolve().parents[1] / FOLDER)
