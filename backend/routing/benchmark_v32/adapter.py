"""Read original benchmark/baselines; adapt shared inputs without solving."""
import csv
from datetime import datetime, timedelta, timezone
import hashlib
import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace
import zipfile

from ..contract import VERSION, freeze_scenario
from ..generate_examples import token
from ..phase_b.problem import Problem

ROOT = Path(__file__).resolve().parents[3]


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def integrity(root=ROOT):
    root = Path(root)
    manifest = json.loads((root/'benchmark dataset/dataset/generation_manifest.json').read_text())
    if (manifest['benchmark_version'], manifest['matrix_id']) != ('GEOLOCK-BM-v3.2', 'OSM-DIRECTED-v3.2'):
        raise ValueError('V32_REQUIRED')
    result = {'archives': {}, 'csv': {}, 'errors': []}
    result['unlisted_csv_not_used'] = sorted(p.name for p in (root/'benchmark dataset/dataset').glob('*.csv')
        if p.stem not in manifest['generated_csv_sha256'])
    for name in ('benchmark dataset', 'baseline implementation', 'public dataset'):
        path = root/(name+'.zip')
        with zipfile.ZipFile(path) as z:
            names = [n for n in z.namelist() if not n.endswith('/')]
            missing, modified = [], []
            for n in names:
                target = (root/n).resolve()
                if not target.is_relative_to(root.resolve()):
                    raise ValueError('UNSAFE_ARCHIVE_PATH')
                if not target.is_file():
                    missing.append(n)
                elif sha(target) != hashlib.sha256(z.read(n)).hexdigest():
                    modified.append(n)
            result['archives'][name] = dict(sha256=sha(path), files=len(names), missing=missing, modified=modified)
            result['errors'].extend(missing+modified)
    for name, expected in manifest['generated_csv_sha256'].items():
        path = root/'benchmark dataset/dataset'/(name+'.csv')
        with path.open(encoding='utf-8-sig', newline='') as f:
            count = sum(1 for _ in csv.DictReader(f))
        good = sha(path) == expected and count == manifest['row_counts'][name]
        result['csv'][name] = dict(sha256=sha(path), rows=count, pass_check=good)
        if not good:
            result['errors'].append(name)
    if result['errors']:
        raise ValueError('PACKAGE_INTEGRITY_FAILURE: '+str(result['errors']))
    return result


def baselines(root=ROOT):
    modules = {}
    for name in ('fcfs', 'nearest_next'):
        path = Path(root)/'baseline implementation/source code'/(name+'_baseline.py')
        spec = importlib.util.spec_from_file_location('v32_'+name, path)
        module = importlib.util.module_from_spec(spec)
        # Compile source directly: importing must not refresh the teammate's
        # bundled __pycache__ files or trust an archived bytecode cache.
        exec(compile(path.read_bytes(), str(path), 'exec'), module.__dict__)
        modules[name] = module
    return modules


def check_settings(s):
    required = {'approved', 'geofence_km', 'lease_minutes', 'route_minutes', 'service_minutes',
                'safety_margin_minutes', 'mandatory', 'availability_policy', 'currency',
                'fixed_cost', 'distance_cost_per_km', 'solver_wall_seconds', 'deterministic_seconds_per_pass', 'seed', 'listing_expiry_policy'}
    if set(s) != required or s['mandatory'] is not False or s['availability_policy'] != 'BASELINE_ROUTING_WINDOW':
        raise ValueError('UNSUPPORTED_COMPARISON_POLICY')
    # Baseline permits lease equality; Stage 8 requires strict expiry and admits
    # only leases surviving the whole horizon. Prove these differences inactive.
    if s['lease_minutes'] <= s['route_minutes']+s['safety_margin_minutes']+1:
        raise ValueError('LEASE_BOUNDARY_POLICIES_NOT_EQUIVALENT')
    if s['currency'] != 'BENCHMARK_COST_UNIT':
        raise ValueError('NO_OBSERVED_RM_COSTS_SUPPLIED')
    if s['listing_expiry_policy'] not in ('REJECT_DIFFERENCES', 'COMMON_STAGE8_ADMISSION'):
        raise ValueError('UNREVIEWED_LISTING_EXPIRY_POLICY')
    for key in required-{'approved','mandatory','availability_policy','currency','listing_expiry_policy'}:
        import math
        if type(s[key]) not in (int, float) or not math.isfinite(s[key]) or s[key] < 0:
            raise ValueError('INVALID_SETTING: '+key)
    if any(s[k] <= 0 for k in ('geofence_km','route_minutes','solver_wall_seconds','deterministic_seconds_per_pass')):
        raise ValueError('POSITIVE_LIMIT_REQUIRED')
    if type(s['seed']) is not int or not 0 <= s['seed'] < 2**31:
        raise ValueError('INVALID_SEED')
    if type(s['approved']) is not bool:
        raise ValueError('INVALID_APPROVAL')


def aware(text):
    d = datetime.fromisoformat(text)
    return (d.replace(tzinfo=timezone(timedelta(hours=8))) if d.tzinfo is None else d).isoformat()


class Adapter:
    def __init__(self, settings, root=ROOT):
        check_settings(settings)
        self.settings = dict(settings)
        self.root = Path(root)
        self.integrity = integrity(root)
        self.modules = baselines(root)
        self.base = self.modules['fcfs']
        self.args = SimpleNamespace(**settings)
        self.data = self.base.setup_route_data(self.root/'benchmark dataset/dataset')
        with (self.data.directory/'road_nodes.csv').open(encoding='utf-8-sig') as f:
            self.nodes = {r['road_node_id']: r for r in csv.DictReader(f)}
        self.scenarios = self.base.select_scenarios(self.data, ('ROUTE_PLANNING',), None)
        if len(self.scenarios) != 100:
            raise ValueError('EXPECTED_100_SCENARIOS')

    def convert(self, scenario, *, ignore_listing_expiry=False):
        """Convert a benchmark scenario into a routing snapshot.

        ``ignore_listing_expiry`` is an explicit benchmark adaptation option.
        Its default preserves the historical adapter behavior for every
        existing consumer. E4 opts in because its frozen synthetic expiry
        values mirror donor availability_end, which the current donor workflow
        does not collect and which is not an independent post-claim deadline.
        """
        shared = self.base.build_snapshot(self.data, scenario, self.args)
        s = self.settings
        cutoff = aware(shared['cutoff'])
        end = (datetime.fromisoformat(cutoff)+timedelta(minutes=s['route_minutes'])).isoformat()
        owner = shared['ngo_id']
        def loc(identity, node):
            row = self.nodes[node]
            return dict(location_id=identity, road_node_id=node, network_snapshot_id='OSM-DIRECTED-v3.2',
                        latitude=float(row['latitude']), longitude=float(row['longitude']), state_token=token(identity))
        depot_node = self.data.ngos[(owner,)]['road_node_id']
        depot = loc('BENCHMARK-DEPOT-'+owner, depot_node)
        tasks = []
        for t in shared['tasks']:
            listing = self.data.listings[(t['task_id'].removeprefix('TASK-'),)]
            pickup = loc('BENCHMARK-PICKUP-'+t['task_id'], t['road_node_id'])
            tasks.append(dict(task_id=t['task_id'], ngo_id=owner, claim_id=t['claim_id'], claim_ngo_id=owner,
                lease_id='BENCHMARK-LEASE-'+t['task_id'], listing_id=listing['listing_id'], source_type='DIRECT_DONATION',
                task_status='CONFIRMED', claim_status='ACTIVE', lease_status='ACTIVE', listing_status='CLAIMED',
                created_at=aware(t['created_at']), lease_issued_at=aware(t['created_at']),
                lease_expires_at=aware(t['claim_expires_at']),
                listing_expires_at=None if ignore_listing_expiry else aware(listing['listing_expires_at']),
                listing_version=2, task_state_token=token(t['task_id']), claim_state_token=token(t['claim_id']),
                lease_state_token=token('lease-'+t['task_id']), pickup=pickup, authorized_pickup=dict(pickup),
                weight_kg=t['weight_kg'], listing_weight_kg=t['weight_kg'],
                time_window=dict(start=cutoff, end=end, provenance='Explicit baseline-equivalent routing horizon; donor availability NOT evaluated'),
                service_minutes=t['service_minutes'], mandatory=False, has_route_assignment=False, reconciliation_blocked=False,
                donations=[dict(donation_id=t['source_id'], donation_status='CLAIMED', state_token=token(t['source_id']))], batch=None))
        order = sorted({depot_node}|{t['road_node_id'] for t in shared['tasks']})
        distances, minutes, statuses = [], [], []
        for a in order:
            dr, tr, sr = [], [], []
            for b in order:
                row = self.data.matrix.get((a,b))
                if row is None:
                    raise ValueError('MISSING_MATRIX_PAIR: '+a+'/'+b)
                if row['route_available_flag'] not in ('0','1'):
                    raise ValueError('INVALID_AVAILABILITY')
                available = row['route_available_flag'] == '1'
                dr.append(float(row['road_distance_km']) if available else None)
                tr.append(float(row['travel_time_min']) if available else None)
                sr.append('AVAILABLE' if available else 'UNREACHABLE')
            distances.append(dr); minutes.append(tr); statuses.append(sr)
        import ortools
        payload = dict(schema_version=VERSION, planning_run_id='OFFLINE-'+shared['snapshot_id'],
            scenario_id=shared['scenario_id'], source=dict(kind='SYNTHETIC_BENCHMARK', project_ref=None,
            provenance='Synthetic entities / simulated claims; actual supplied OSM-derived benchmark matrix, not DEV coverage',
            evidence_ref='benchmark dataset/dataset/generation_manifest.json'), ngo_id=owner, ngo_active=True,
            ngo_location_generation=1, ngo_location_verified_at=cutoff, cutoff=cutoff,
            configuration=dict(version='REVIEW-PROPOSAL-v32', currency=s['currency'], planning_horizon_minutes=s['route_minutes'],
                dispatch_margin_minutes=s['safety_margin_minutes'], objective='MIN_UNSERVED_THEN_FIXED_PLUS_DISTANCE_COST',
                time_window_policy='SERVICE_COMPLETION_WITHIN_WINDOW'), depot=depot,
            route_start_location_id=depot['location_id'], route_end_location_id=depot['location_id'],
            vehicles=[dict(vehicle_id=v['vehicle_id'], ngo_id=owner, vehicle_type=self.data.vehicles[(v['vehicle_id'],)]['vehicle_type'],
                capacity_kg=v['capacity_kg'], active=True, available_for_planning=True, fixed_cost=s['fixed_cost'],
                distance_cost_per_km=s['distance_cost_per_km'], max_route_minutes=s['route_minutes'],
                depot_location_id=depot['location_id'], state_token=token(v['vehicle_id'])) for v in shared['fleet']], tasks=tasks,
            matrix=dict(matrix_id='OSM-DIRECTED-v3.2', version=self.data.hashes['road_distance_matrix.csv'],
                network_snapshot_id='OSM-DIRECTED-v3.2', source_kind='SYNTHETIC_BENCHMARK',
                provenance='Supplied OSM-derived benchmark costs retained; synthetic entities, NOT synthetic road distances or DEV measurements',
                method='SUPPLIED_BENCHMARK_MATRIX', edge_speed_profile='Supplied extract speed profile; no live traffic',
                path_policy='DIRECTED_SHORTEST_DISTANCE_WITH_TIME_ON_SAME_PATH', unavailable_policy='FORBID_ARC',
                node_order=order, distance_km=distances, travel_minutes=minutes, arc_status=statuses),
            solver=dict(engine='OR_TOOLS', version=ortools.__version__, time_limit_seconds=s['solver_wall_seconds'], workers=1,
                seed=s['seed'], first_solution='PATH_CHEAPEST_ARC', local_search='GUIDED_LOCAL_SEARCH',
                tie_break='TASK_ID_THEN_VEHICLE_ID', timeout_policy='VALIDATED_INCUMBENT_ONLY'))
        frozen = freeze_scenario(payload)
        if frozen.excluded_tasks:
            if s['listing_expiry_policy'] != 'COMMON_STAGE8_ADMISSION':
                raise ValueError('ADMISSION_DIFFERS_FROM_BASELINES: '+str(frozen.excluded_tasks))
            # Apply the existing Stage 8 admission to BOTH methods. Keep rejected
            # source tasks in FrozenScenario exclusion evidence; never hide them.
            rejected = dict(frozen.excluded_tasks)
            kept = []
            for task in shared['tasks']:
                if task['task_id'] in rejected:
                    shared['excluded_tasks'].append(dict(task_id=task['task_id'], source_id=task['source_id'],
                        reason='COMMON_STAGE8_ADMISSION:'+','.join(rejected[task['task_id']])))
                else:
                    kept.append(task)
            shared['tasks'] = kept
            shared.pop('snapshot_id')
            shared['snapshot_id'] = self.base.digest(shared)
        if set(frozen.admitted_task_ids) != {t['task_id'] for t in shared['tasks']}:
            raise ValueError('ADMISSION_NOT_IDENTICAL')
        problem = Problem(frozen)  # exact numeric representation checks, no solver
        for a in order:
            for b in order:
                problem.arc(a,b)
        return shared, frozen
