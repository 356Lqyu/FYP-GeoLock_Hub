"""Standalone nearest next baseline using the frozen CSV benchmark."""
import argparse
from collections import defaultdict
import csv
from datetime import datetime, timedelta
import hashlib
import json
import math
from pathlib import Path
import sys


def read_table(directory, name):
    with (directory / (name + '.csv')).open(encoding='utf-8-sig', newline='') as stream:
        return list(csv.DictReader(stream))


def index_rows(rows, fields):
    result = {}
    for row in rows:
        key = tuple(row[field] for field in fields)
        if key in result:
            raise ValueError(f'Duplicate {fields}: {key}')
        result[key] = row
    return result


def positive(value, label, allow_zero=False):
    number = float(value)
    if not math.isfinite(number) or number < 0 or (number == 0 and not allow_zero):
        raise ValueError(f'Invalid {label}: {value}')
    return number


def timestamp(value):
    # Fixture timestamps are local Asia/Kuala_Lumpur; no host clock is used.
    return datetime.fromisoformat(value)


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def write_csv(path, rows, fields):
    with path.open('w', encoding='utf-8-sig', newline='') as stream:
        writer = csv.DictWriter(stream, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')


def base_parser(description):
    parser = argparse.ArgumentParser(description=description)
    parser.add_argument('--dataset-dir', type=Path,
                        default=Path(__file__).resolve().parents[2] / 'benchmark dataset' / 'dataset')
    parser.add_argument('--output-dir', type=Path,
                        default=Path(__file__).resolve().parents[1] / 'result')
    parser.add_argument('--scenario-ids', type=Path, help='CSV scenario_id column or one ID per line')
    parser.add_argument('--geofence-km', type=float, default=20)
    parser.add_argument('--lease-minutes', type=float, default=360)
    return parser


def select_scenarios(data, kinds, selection):
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
    def __init__(self, directory, names):
        self.directory = directory
        self.manifest = json.loads((directory / 'generation_manifest.json').read_text(encoding='utf-8'))
        self.tables = {name: read_table(directory, name) for name in names}
        self.hashes = {name + '.csv': hashlib.sha256((directory / (name + '.csv')).read_bytes()).hexdigest()
                       for name in names}
        self.hashes['generation_manifest.json'] = hashlib.sha256((directory / 'generation_manifest.json').read_bytes()).hexdigest()
        for name in names:
            expected = self.manifest.get('generated_csv_sha256', {}).get(name)
            if expected and expected != self.hashes[name + '.csv']:
                raise ValueError(f'Input hash differs from generation manifest: {name}')
        self.members = defaultdict(list)
        for row in self.tables['scenario_members']:
            self.members[row['scenario_id']].append(row)
        self.agents = index_rows(self.tables['ngo_agents'], ('ngo_agent_id',))
        self.matrix = index_rows(self.tables['road_distance_matrix'], ('from_node_id', 'to_node_id'))
        for row in self.tables['scenarios']:
            if row['matrix_id'] != self.manifest['matrix_id']:
                raise ValueError('Scenario matrix ID mismatch')

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
        if row['route_available_flag'] != '1' or row['matrix_id'] != self.manifest['matrix_id']:
            raise ValueError('Invalid road matrix record')
        return (positive(row['road_distance_km'], 'road distance', True),
                positive(row['travel_time_min'], 'travel time', True))

    def eligibility(self, agent_id, node, radius):
        agent = self.agents[(agent_id,)]
        if agent['active_flag'] != '1' or agent['benchmark_location_valid_flag'] != '1':
            return 'NOT_ELIGIBLE', None
        if agent['capability_profile'] != 'GENERAL_NONHAZARDOUS_SYNTHETIC':
            return 'CAPABILITY_UNSUPPORTED', None
        arc = self.arc(agent['road_node_id'], node)
        if arc is None:
            return 'ROUTE_UNAVAILABLE', None
        if arc[0] > radius:
            return 'OUTSIDE_GEOFENCE', arc[0]
        return 'ELIGIBLE', arc[0]

    def metadata(self, method, configuration):
        return dict(method=method, benchmark_version=self.manifest['benchmark_version'],
                    matrix_id=self.manifest['matrix_id'], dataset_dir=str(self.directory.resolve()),
                    input_sha256=self.hashes, runner_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                    python_version=sys.version, configuration=configuration, configuration_id=digest(configuration),
                    fixture_timezone=self.manifest.get('fixture_timezone', 'Asia/Kuala_Lumpur'),
                    evaluation_status='EXPLORATORY_CONTROLLED_SIMULATION',
                    backend='IN_MEMORY_SIMULATION_NOT_POSTGRESQL', dispatch_authority_issued=False)

ROUTE_TABLES = ['scenarios', 'scenario_members', 'ngo_agents', 'vehicles', 'listings',
                'road_distance_matrix', 'donations', 'donors', 'locations', 'hub_batches',
                'hub_batch_members', 'hubs', 'donation_hub_candidates']


def setup_route_data(directory):
    data = Benchmark(directory, ROUTE_TABLES)
    for name, key in [('vehicles', 'vehicle_id'), ('listings', 'listing_id'),
                      ('donations', 'donation_id'), ('donors', 'donor_id'),
                      ('locations', 'location_id'), ('hub_batches', 'batch_id'), ('hubs', 'hub_id')]:
        setattr(data, name, index_rows(data.tables[name], (key,)))
    data.candidates = index_rows(data.tables['donation_hub_candidates'], ('donation_id', 'hub_id'))
    return data


def make_task(task_id, source_id, node, weight, created, owner, lease_minutes,
              service_minutes, listing_expires, initial_state='AVAILABLE'):
    """Create a confirmed task only after simulated protected claim admission."""
    if initial_state != 'AVAILABLE' or timestamp(created) >= timestamp(listing_expires):
        return None, 'LISTING_NOT_AVAILABLE'
    positive(weight, 'task weight')
    positive(service_minutes, 'service time', True)
    return dict(task_id=task_id, source_id=source_id, road_node_id=node,
                weight_kg=float(weight), created_at=created, service_minutes=service_minutes,
                ngo_agent_id=owner, claim_id='CLM-'+task_id, claim_status='ACTIVE',
                claim_expires_at=(timestamp(created)+timedelta(minutes=lease_minutes)).isoformat(),
                task_status='CONFIRMED', task_version=1, listing_version=1), ''


def build_snapshot(data, scenario, args, condition='route'):
    sid = scenario['scenario_id']
    aggregation = scenario['scenario_type'] == 'HUB_AGGREGATION'
    owner = data.one(sid, 'NGO_AGENT', 'SAME_COMPARISON_NGO' if aggregation else 'INTENDED_CLAIMANT')
    fleet_ids = data.ids(sid, 'VEHICLE', 'SAME_COMPARISON_FLEET' if aggregation else 'AVAILABLE_FLEET')
    fleet = []
    for vid in fleet_ids:
        v = data.vehicles[(vid,)]
        if v['ngo_agent_id'] != owner:
            raise ValueError(f'Foreign vehicle: {sid}/{vid}')
        if v['active_flag'] != '1':
            continue
        fleet.append(dict(vehicle_id=vid, ngo_agent_id=owner, depot_road_node_id=v['depot_road_node_id'],
                          capacity_kg=positive(v['vehicle_capacity_kg'], 'vehicle capacity')))
    fleet.sort(key=lambda v: v['vehicle_id'])
    tasks, excluded, custody = [], [], []
    originals = []
    donor_burden = 0.0
    if not aggregation:
        listing_ids = data.ids(sid, 'LISTING', 'INITIAL_AVAILABLE_LISTING')
        listing_rows = [data.listings[(lid,)] for lid in listing_ids]
        if not listing_rows:
            raise ValueError(f'Empty route input: {sid}')
        listing_rows.sort(key=lambda row: (row['created_at'], row['listing_id']))
        schedule_start = timestamp(max(r['created_at'] for r in listing_rows))
        claim_times = {row['listing_id']: (schedule_start + timedelta(seconds=i)).isoformat()
                       for i, row in enumerate(listing_rows)}
        cutoff = (schedule_start + timedelta(seconds=len(listing_rows))).isoformat()
        opportunities = [(r['listing_id'], r['source_id'], r['pickup_road_node_id'],
                          r['listing_weight_kg'], r['listing_expires_at'], r['initial_state']) for r in listing_rows]
        originals = [r['source_id'] for r in listing_rows]
    else:
        bid = data.one(sid, 'HUB_BATCH', 'UNCOMMITTED_GROUP_TEMPLATE')
        batch = data.hub_batches[(bid,)]
        hid = data.one(sid, 'HUB', 'CANDIDATE_AGGREGATION_SITE')
        originals = data.ids(sid, 'DONATION', 'ORIGINAL_DONATION')
        members = [r['donation_id'] for r in data.tables['hub_batch_members'] if r['batch_id'] == bid]
        if len(members) != len(set(members)) or set(members) != set(originals):
            raise ValueError(f'Batch/scenario membership mismatch: {sid}')
        donated = [data.donations[(did,)] for did in originals]
        if batch['hub_id'] != hid or not donated:
            raise ValueError(f'Invalid aggregation group: {sid}')
        cutoff = max(d['availability_start'] for d in donated)
        expiry = min(d['availability_end'] for d in donated)
        if cutoff >= expiry:
            raise ValueError(f'No common donation availability: {sid}')
        mass = sum(positive(d['weight_kg'], 'donation weight') for d in donated)
        if not math.isclose(mass, float(batch['batch_weight_kg']), abs_tol=1e-6) or len(donated) != int(batch['batch_item_count']):
            raise ValueError(f'Batch aggregate mismatch: {sid}')
        if condition == 'hub':
            hub = data.hubs[(hid,)]
            if not 3 <= len(donated) <= 5 or mass > 30 or len({d['category'] for d in donated}) != 1:
                raise ValueError(f'Batch publication rule violation: {sid}')
            load = positive(hub['hub_load_kg'], 'hub load', True)
            reserved = positive(hub['hub_reserved_kg'], 'reserved load', True)
            capacity = positive(hub['hub_capacity_kg'], 'hub capacity')
            if load + reserved + mass > capacity + 1e-6:
                raise ValueError(f'Insufficient protected hub capacity: {sid}')
            for donation in sorted(donated, key=lambda d: (d['received_at'], d['donation_id'])):
                did = donation['donation_id']
                candidate = data.candidates[(did, hid)]
                if candidate['feasible_flag'] != '1' or hub['hub_active_flag'] != '1':
                    raise ValueError(f'Infeasible hub receipt: {sid}/{did}')
                if donation['category'] not in hub['accepted_categories'].split('|'):
                    raise ValueError('Category incompatible with hub')
                # Capacity reservation, verified receipt, and unique batching
                # are simulated transitions. No real physical receipt is claimed.
                donor = data.donors[(donation['donor_id'],)]
                loc = data.locations[(donor['location_id'],)]
                arc = data.arc(loc['road_node_id'], batch['pickup_road_node_id'])
                if arc is None:
                    raise ValueError('Unavailable donor-to-hub route')
                donor_burden += arc[0]
                custody.append(dict(donation_id=did, hub_id=hid, batch_id=bid,
                                    transitions=['ACTIVE_RESERVATION', 'VERIFIED_RECEIPT_SIMULATED', 'STORED', 'BATCHED'],
                                    weight_kg=float(donation['weight_kg']), donor_one_way_road_km=arc[0]))
            opportunities = [(bid, bid, batch['pickup_road_node_id'], mass, expiry, 'AVAILABLE')]
        else:
            opportunities = []
            for d in donated:
                donor = data.donors[(d['donor_id'],)]
                loc = data.locations[(donor['location_id'],)]
                opportunities.append((d['donation_id'], d['donation_id'], loc['road_node_id'],
                                      d['weight_kg'], expiry, 'AVAILABLE'))
    for identity, source_id, node, weight, expiry, state in opportunities:
        status, distance = data.eligibility(owner, node, args.geofence_km)
        task_id = 'TASK-'+identity
        if status != 'ELIGIBLE':
            excluded.append(dict(task_id=task_id, source_id=source_id, reason=status))
            continue
        claim_time = claim_times[identity] if not aggregation else cutoff
        task, reason = make_task(task_id, source_id, node, weight, claim_time, owner,
                                 args.lease_minutes, args.service_minutes, expiry, state)
        if task is None:
            excluded.append(dict(task_id=task_id, source_id=source_id, reason=reason))
        else:
            tasks.append(task)
    snapshot = dict(scenario_id=sid, scenario_type=scenario['scenario_type'],
                    scenario_profile=scenario.get('scenario_profile', ''), condition=condition,
                    ngo_agent_id=owner, cutoff=cutoff, matrix_id=data.manifest['matrix_id'],
                    matrix_sha256=data.hashes['road_distance_matrix.csv'],
                    tasks=sorted(tasks, key=lambda t: t['task_id']), excluded_tasks=excluded,
                    fleet=fleet, original_donation_ids=originals, original_weight_kg=sum(t['weight_kg'] for t in tasks),
                    donor_one_way_road_km=donor_burden, custody_transitions=custody,
                    claim_model='SERIAL_PROTECTED_IN_MEMORY_ADMISSION', dispatch_authority_issued=False,
                    claim_schedule='SOURCE_CREATED_AT_THEN_LISTING_ID_ONE_SECOND_SPACING' if not aggregation else 'MATCHED_COMMON_CUTOFF')
    snapshot['planning_contract'] = route_configuration(args)
    snapshot['snapshot_id'] = digest(snapshot)
    return snapshot


def extension(data, snapshot, vehicle, current, load, elapsed, task, args):
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
    if task['claim_status'] != 'ACTIVE' or task['ngo_agent_id'] != snapshot['ngo_agent_id']:
        return None, 'INVALID_AUTHORITY'
    if remaining_lease + 1e-8 < completion + args.safety_margin_minutes:
        return None, 'LEASE_INSUFFICIENT'
    return (outward, completion), ''


def plan_routes(data, snapshot, args):
    """One depot-returning route per vehicle in fixed ascending vehicle order."""
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
    """Recompute all loads, arcs, times and accounting from emitted stop IDs."""
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
            if task['claim_status'] != 'ACTIVE' or task['ngo_agent_id'] != snapshot['ngo_agent_id']:
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
    parser = base_parser(__doc__)
    parser.add_argument('--snapshot-file', type=Path, help='Use sealed shared snapshots instead of synthesizing claims')
    parser.add_argument('--route-minutes', type=float, default=240)
    parser.add_argument('--service-minutes', type=float, default=10)
    parser.add_argument('--safety-margin-minutes', type=float, default=0,
                        help='Exploratory default 0; freeze a margin before formal dispatch evaluation')
    return parser


def route_configuration(args):
    return dict(geofence_km=positive(args.geofence_km, 'geofence radius'),
                lease_minutes=positive(args.lease_minutes, 'lease duration'),
                route_minutes=positive(args.route_minutes, 'route duration'),
                service_minutes=positive(args.service_minutes, 'service time', True),
                safety_margin_minutes=positive(args.safety_margin_minutes, 'safety margin', True),
                vehicle_order='ASCENDING_VEHICLE_ID', trips_per_vehicle=1,
                fcfs_infeasible_policy='SKIP_INFEASIBLE_AND_TRY_NEXT_TASK',
                cutoff='AFTER_FINAL_SCHEDULED_CLAIM',
                claim_schedule='SOURCE_CREATED_AT_THEN_LISTING_ID_ONE_SECOND_SPACING',
                donor_burden_definition='ONE_WAY_DONOR_TO_HUB_KM_NO_RETURN_ASSUMED')


def append_evidence(snapshot, routes, unserved, metrics, results, route_rows, task_rows):
    sid = snapshot['scenario_id']
    condition = snapshot['condition']
    results.append(dict(scenario_id=sid, condition=condition, snapshot_id=snapshot['snapshot_id'],
                        ngo_agent_id=snapshot['ngo_agent_id'], scenario_profile=snapshot['scenario_profile'], **metrics))
    assignments = {}
    for route in routes:
        route_rows.append(dict(scenario_id=sid, condition=condition, snapshot_id=snapshot['snapshot_id'],
                               vehicle_id=route['vehicle_id'], depot_road_node_id=route['depot_road_node_id'],
                               stop_task_ids='|'.join(s['task_id'] for s in route['stops']),
                               load_kg=route['load_kg'], road_distance_km=route['road_distance_km'],
                               travel_time_min=route['travel_time_min'], duration_min=route['duration_min']))
        for i, stop in enumerate(route['stops'], 1):
            assignments[stop['task_id']] = (route['vehicle_id'], i, stop)
    for task in snapshot['tasks']:
        assigned = assignments.get(task['task_id'])
        task_rows.append(dict(scenario_id=sid, condition=condition, task_id=task['task_id'], source_id=task['source_id'],
                              status='SERVED' if assigned else 'UNSERVED', reason='' if assigned else unserved[task['task_id']],
                              vehicle_id=assigned[0] if assigned else '', stop_order=assigned[1] if assigned else '',
                              arrival_elapsed_min=assigned[2]['arrival_elapsed_min'] if assigned else '',
                              completion_elapsed_min=assigned[2]['completion_elapsed_min'] if assigned else ''))
    for task in snapshot['excluded_tasks']:
        task_rows.append(dict(scenario_id=sid, condition=condition, task_id=task['task_id'], source_id=task['source_id'],
                              status='EXCLUDED', reason=task['reason'], vehicle_id='', stop_order='',
                              arrival_elapsed_min='', completion_elapsed_min=''))


def save_route_outputs(args, data, configuration, results, route_rows, task_rows, snapshots):
    config_id=digest(configuration)
    for rows in (results,route_rows,task_rows):
        for row in rows: row['configuration_id']=config_id
    args.output_dir.mkdir(parents=True, exist_ok=True)
    prefix = args.output_dir / 'nearest_next'
    write_csv(prefix.with_name(prefix.name+'_results.csv'), results, list(results[0]))
    route_fields = ['scenario_id', 'condition', 'snapshot_id', 'vehicle_id', 'depot_road_node_id',
                    'stop_task_ids', 'load_kg', 'road_distance_km', 'travel_time_min', 'duration_min']
    task_fields = ['scenario_id', 'condition', 'task_id', 'source_id', 'status', 'reason', 'vehicle_id',
                   'stop_order', 'arrival_elapsed_min', 'completion_elapsed_min']
    route_fields.append('configuration_id')
    task_fields.append('configuration_id')
    write_csv(prefix.with_name(prefix.name+'_routes.csv'), route_rows, route_fields)
    write_csv(prefix.with_name(prefix.name+'_tasks.csv'), task_rows, task_fields)
    write_json(prefix.with_name(prefix.name+'_snapshots.json'), snapshots)
    summary = data.metadata('nearest_next', configuration)
    summary.update(scenarios=len({r['scenario_id'] for r in results}), condition_runs=len(results),
                   valid_tasks=sum(r['valid_task_count'] for r in results),
                   served_tasks=sum(r['served_tasks'] for r in results),
                   unserved_tasks=sum(r['unserved_tasks'] for r in results),
                   excluded_tasks=sum(r['excluded_task_count'] for r in results),
                   ngo_road_distance_km=sum(r['ngo_road_distance_km'] for r in results),
                   pickup_trips=sum(r['pickup_trips'] for r in results),
                   all_constraint_checks_passed=all(r['constraint_valid'] for r in results),
                   snapshot_set_sha256=digest(snapshots),
                   limitation='Simulated protected claims and receipts; current live authority and dispatch authorisation are not implemented')
    
    write_json(prefix.with_name(prefix.name+'_summary.json'), summary)
    print(json.dumps({k: summary[k] for k in ('method', 'scenarios', 'condition_runs', 'valid_tasks',
                                             'served_tasks', 'unserved_tasks', 'all_constraint_checks_passed')}, indent=2))


def load_shared_snapshots(path, data, scenarios, args):
    snapshots = json.loads(path.read_text(encoding='utf-8'))
    selected = {s['scenario_id'] for s in scenarios}
    expected_condition = {'direct', 'hub'} if scenarios[0]['scenario_type']=='HUB_AGGREGATION' else {'route'}
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
            if task['ngo_agent_id']!=snapshot['ngo_agent_id'] or timestamp(task['claim_expires_at'])<=timestamp(snapshot['cutoff']):
                raise ValueError('Invalid shared task authority')
            if task['task_version']<1 or task['listing_version']<1 or timestamp(task['created_at'])>timestamp(snapshot['cutoff']):
                raise ValueError('Invalid shared task version/time')
        for vehicle in snapshot['fleet']:
            benchmark_vehicle=data.vehicles[(vehicle['vehicle_id'],)]
            if vehicle['ngo_agent_id']!=snapshot['ngo_agent_id'] or vehicle['depot_road_node_id']!=benchmark_vehicle['depot_road_node_id']:
                raise ValueError('Shared vehicle owner/depot differs')
            if vehicle['capacity_kg']!=float(benchmark_vehicle['vehicle_capacity_kg']):
                raise ValueError('Shared vehicle capacity differs')
    return {(s['scenario_id'],s['condition']):s for s in chosen}


def main():
    parser = route_parser()
    args = parser.parse_args()
    configuration = route_configuration(args)
    data = setup_route_data(args.dataset_dir)
    scenarios = select_scenarios(data, ('ROUTE_PLANNING',), args.scenario_ids)
    configuration['selected_scenarios'] = [r['scenario_id'] for r in scenarios]
    shared = load_shared_snapshots(args.snapshot_file, data, scenarios, args) if args.snapshot_file else None
    configuration['snapshot_input_sha256'] = hashlib.sha256(args.snapshot_file.read_bytes()).hexdigest() if args.snapshot_file else None
    results, routes_output, tasks_output, snapshots = [], [], [], []
    for scenario in scenarios:
        snapshot = shared[(scenario['scenario_id'],'route')] if shared else build_snapshot(data, scenario, args)
        routes, unserved = plan_routes(data, snapshot, args)
        metrics = validate_plan(data, snapshot, routes, unserved, args)
        append_evidence(snapshot, routes, unserved, metrics, results, routes_output, tasks_output)
        snapshots.append(snapshot)
    save_route_outputs(args, data, configuration, results, routes_output, tasks_output, snapshots)



if __name__ == '__main__':
    main()
