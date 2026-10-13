"""Standalone non atomic claim baseline using the frozen CSV benchmark."""
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

from concurrent.futures import ThreadPoolExecutor
import threading


def run_contention(data, scenario, workers, radius, lease_minutes):
    """Run a real thread barrier over simulated state, not a live backend."""
    sid = scenario['scenario_id']
    lid = data.one(sid, 'LISTING', 'CLAIMABLE_LISTING')
    listing = data.listings[(lid,)]
    now = timestamp(listing['created_at'])
    agents = data.ids(sid, 'NGO_AGENT', 'POTENTIAL_REQUESTER_UNASSESSED')
    if not agents:
        raise ValueError(f'No requesters: {sid}')
    schedule = [{'request_id': f'{sid}-REQ-{i+1:02d}', 'ngo_agent_id': agents[i % len(agents)]}
                for i in range(workers)]
    barrier = threading.Barrier(workers)
    lock = threading.Lock()
    commits = []

    def request(item):
        status, distance = data.eligibility(item['ngo_agent_id'], listing['pickup_road_node_id'], radius)
        initial_available = (listing['initial_state'] == 'AVAILABLE' and
                             now < timestamp(listing['listing_expires_at']))
        record = dict(scenario_id=sid, listing_id=lid, workers=workers, **item,
                      request_at=now.isoformat(), road_distance_km=distance if distance is not None else '',
                      eligibility=status, observed_available=False, outcome='', claim_id='', task_id='')
        # All workers reach this phase, including rejected requests, to avoid
        # a barrier deadlock. Each request is a distinct idempotency key.
        record['observed_available'] = initial_available and not commits
        barrier.wait(timeout=30)
        if status != 'ELIGIBLE':
            record['outcome'] = status
        elif not record['observed_available']:
            record['outcome'] = 'CLAIM_CONFLICT'
        else:
            # Deliberately unsafe: the write trusts the pre-barrier read.
            # No current-state recheck or one-active-claim uniqueness guard.
            with lock:
                commits.append(item['request_id'])
            record.update(outcome='CLAIM_COMMITTED', claim_id='CLM-'+item['request_id'],
                          task_id='TASK-'+item['request_id'])
        return record

    with ThreadPoolExecutor(max_workers=workers) as executor:
        requests = list(executor.map(request, schedule))
    committed = [r for r in requests if r['outcome'] == 'CLAIM_COMMITTED']
    result = dict(scenario_id=sid, listing_id=lid, workers=workers,
                  eligible_requests=sum(r['eligibility'] == 'ELIGIBLE' for r in requests),
                  committed_claims=len(committed),
                  committed_ngo_identities=len({r['ngo_agent_id'] for r in committed}),
                  duplicate_committed_claim=int(len(committed) > 1),
                  one_active_claim_invariant=int(len(committed) <= 1),
                  request_schedule_sha256=digest(schedule),
                  lease_released=0, reclaim_success=0, input_state='', outcome='CONTENTION_COMPLETED')
    claims = [dict(scenario_id=sid, listing_id=lid, claim_id=r['claim_id'], ngo_agent_id=r['ngo_agent_id'],
                   status='ACTIVE', committed_at=now.isoformat(),
                   expires_at=(now + timedelta(minutes=lease_minutes)).isoformat(),
                   valid_authority_at_replay=1, task_id=r['task_id']) for r in committed]
    return result, requests, claims


def run_lease_case(data, scenario, radius):
    sid = scenario['scenario_id']
    state = data.states[(sid,)]
    lid = data.one(sid, 'LISTING', 'CLAIMABLE_LISTING')
    listing = data.listings[(lid,)]
    prior = data.one(sid, 'NGO_AGENT', 'PRIOR_CLAIMANT')
    replacement = data.one(sid, 'NGO_AGENT', 'POTENTIAL_REPLACEMENT_CLAIMANT')
    if state['listing_id'] != lid or state['ngo_agent_id'] != prior or prior == replacement:
        raise ValueError(f'Invalid lease fixture: {sid}')
    now = timestamp(state['replay_at'])
    expired = now >= timestamp(state['claim_expires_at'])
    if expired != (state['input_state'] == 'EXPIRED'):
        raise ValueError(f'Lease state/time mismatch: {sid}')
    eligible, distance = data.eligibility(replacement, listing['pickup_road_node_id'], radius)
    if eligible != 'ELIGIBLE':
        outcome = eligible
    elif now >= timestamp(listing['listing_expires_at']):
        outcome = 'LISTING_EXPIRED'
    elif state['handover_status'] != 'NOT_TRANSFERRED':
        outcome = 'RECONCILIATION_REQUIRED'
    elif expired:
        outcome = 'EXPIRED_CLAIM_NOT_RELEASED'
    else:
        outcome = 'ALREADY_CLAIMED'
    # Expired ownership is retained and blocks reclaim; it is never reported
    # as valid unexpired authority. This is the intended ablation condition.
    result = dict(scenario_id=sid, listing_id=lid, workers=1, eligible_requests=int(eligible == 'ELIGIBLE'),
                  committed_claims=0, committed_ngo_identities=0, duplicate_committed_claim=0,
                  one_active_claim_invariant=1, request_schedule_sha256=digest([replacement, now.isoformat()]),
                  lease_released=0, reclaim_success=0, input_state=state['input_state'], outcome=outcome)
    request = dict(scenario_id=sid, listing_id=lid, workers=1, request_id=sid+'-RECLAIM',
                   ngo_agent_id=replacement, request_at=now.isoformat(),
                   road_distance_km=distance if distance is not None else '', eligibility=eligible,
                   observed_available=False, outcome=outcome, claim_id='', task_id='')
    claim = dict(scenario_id=sid, listing_id=lid, claim_id=sid+'-PRIOR', ngo_agent_id=prior,
                 status='RETAINED_EXPIRED' if expired else 'ACTIVE', committed_at='',
                 expires_at=state['claim_expires_at'], valid_authority_at_replay=int(not expired), task_id='')
    return result, [request], [claim]


def main():
    parser = base_parser(__doc__)
    parser.add_argument('--workers', type=int, choices=(2, 5, 10),
                        help='Override default cohorts of 50 trials at each of 2, 5 and 10 workers')
    args = parser.parse_args()
    positive(args.geofence_km, 'geofence radius')
    positive(args.lease_minutes, 'lease duration')
    names = ['scenarios', 'scenario_members', 'ngo_agents', 'listings', 'road_distance_matrix', 'claim_initial_states']
    data = Benchmark(args.dataset_dir, names)
    data.listings = index_rows(data.tables['listings'], ('listing_id',))
    data.states = index_rows(data.tables['claim_initial_states'], ('scenario_id',))
    kinds = ('CLAIM_COORDINATION',)
    scenarios = select_scenarios(data, kinds, args.scenario_ids)
    results, requests, claims = [], [], []
    for scenario in scenarios:
        if scenario['scenario_type'] == 'CLAIM_COORDINATION':
            # The cohort is tied to the original scenario ordinal, so selecting
            # a subset does not silently change its worker count.
            ordinal = int(scenario['scenario_id'].rsplit('-', 1)[1]) - 1
            workers = args.workers or (2, 5, 10)[min(ordinal // 50, 2)]
            result, log, state = run_contention(data, scenario, workers, args.geofence_km, args.lease_minutes)
        else:
            result, log, state = run_lease_case(data, scenario, args.geofence_km)
        results.append(result)
        requests.extend(log)
        claims.extend(state)
    configuration = dict(geofence_km=args.geofence_km, lease_minutes=args.lease_minutes,
                         workers_override=args.workers, default_worker_cohorts=[2, 5, 10],
                         trials_per_default_cohort=50, synchronization='THREAD_BARRIER',
                         ownership_operation='UNSAFE_READ_THEN_WRITE', logical_conflict_retries=0,
                         lease_recovery_enabled=False,
                         selected_scenarios=[r['scenario_id'] for r in scenarios])
    summary = data.metadata('non_atomic_claim', configuration)
    contention = [r for r in results if r['outcome'] == 'CONTENTION_COMPLETED']
    cohorts = {}
    for workers in (2, 5, 10):
        group = [r for r in contention if r['workers'] == workers]
        cohorts[str(workers)] = dict(trials=len(group), duplicate_trials=sum(r['duplicate_committed_claim'] for r in group),
                                    duplicate_committed_claim_rate=(sum(r['duplicate_committed_claim'] for r in group)/len(group)) if group else None)
    summary.update(scenarios=len(results), contention_trials=len(contention), worker_cohorts=cohorts,
                   duplicate_trials=sum(r['duplicate_committed_claim'] for r in contention),
                   lease_expired_cases=sum(r['input_state'] == 'EXPIRED' for r in results),
                   lease_active_cases=sum(r['input_state'] == 'ACTIVE' for r in results),
                   lease_releases=sum(r['lease_released'] for r in results),
                   reclaim_successes=sum(r['reclaim_success'] for r in results),
                   limitation='Thread simulation; no PostgreSQL READ COMMITTED transactions or database isolation measurements')
    args.output_dir.mkdir(parents=True, exist_ok=True)
    prefix = args.output_dir / 'non_atomic_claim'
    write_csv(prefix.with_name(prefix.name+'_results.csv'), results, list(results[0]))
    write_csv(prefix.with_name(prefix.name+'_requests.csv'), requests, list(requests[0]))
    fields = ['scenario_id', 'listing_id', 'claim_id', 'ngo_agent_id', 'status', 'committed_at', 'expires_at', 'valid_authority_at_replay', 'task_id']
    write_csv(prefix.with_name(prefix.name+'_claims.csv'), claims, fields)
    tasks = []
    for claim in claims:
        if not claim['task_id']:
            continue
        listing = data.listings[(claim['listing_id'],)]
        tasks.append(dict(scenario_id=claim['scenario_id'], task_id=claim['task_id'],
                          listing_id=claim['listing_id'], claim_id=claim['claim_id'],
                          ngo_agent_id=claim['ngo_agent_id'], task_status='CONFIRMED_SIMULATED',
                          pickup_road_node_id=listing['pickup_road_node_id'],
                          weight_kg=positive(listing['listing_weight_kg'], 'task weight'),
                          created_at=claim['committed_at'], claim_expires_at=claim['expires_at'],
                          listing_version=listing['listing_version'], task_version=1))
    task_fields = ['scenario_id', 'task_id', 'listing_id', 'claim_id', 'ngo_agent_id', 'task_status',
                   'pickup_road_node_id', 'weight_kg', 'created_at', 'claim_expires_at', 'listing_version', 'task_version']
    write_csv(prefix.with_name(prefix.name+'_tasks.csv'), tasks, task_fields)
    write_json(prefix.with_name(prefix.name+'_summary.json'), summary)
    print(json.dumps({k: summary[k] for k in ('method', 'scenarios', 'contention_trials', 'duplicate_trials',
                                             'lease_expired_cases', 'lease_active_cases', 'reclaim_successes')}, indent=2))


if __name__ == '__main__':
    main()
