"""E4 shared code, used by all three methods.

Builds one sealed planning snapshot per ROUTE_PLANNING scenario with the team's adapter
(experiments.routing_research.benchmark_v32), applies the app's admission rules, runs a method and checks
every plan with the app's independent validator. Nothing under backend/ is changed.
"""
import csv
import hashlib
import importlib.util
from importlib.metadata import version as installed_version
import json
import os
import sys
import time
from collections import Counter
from pathlib import Path
from types import SimpleNamespace
import platform
from datetime import datetime

E4 = Path(__file__).resolve().parents[1]
ROOT = E4.parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(E4))
from experiments.routing_research.benchmark_v32.adapter import Adapter as TeamAdapter  # noqa: E402
from experiments.routing_research.benchmark_v32.runner import baseline_plan  # noqa: E402
from backend.routing.contract import freeze_scenario  # noqa: E402
from backend.routing.planner.methods import proposed
from backend.routing.validator.validation import validate_plan  # noqa: E402
from backend.routing.route_plan import ExecutionConfig  # noqa: E402
from experiments.routing_research.algorithms.benchmark import semantic  # noqa: E402
from run_e4 import run_directory  # noqa: E402

SETTINGS = dict(approved=True, geofence_km=20, lease_minutes=360, route_minutes=240, service_minutes=10,
                safety_margin_minutes=0, mandatory=False, availability_policy='BASELINE_ROUTING_WINDOW',
                listing_expiry_policy='COMMON_STAGE8_ADMISSION', currency='BENCHMARK_COST_UNIT', fixed_cost=5,
                distance_cost_per_km=1, solver_wall_seconds=30, deterministic_seconds_per_pass=0.25, seed=42)
CONFIG = ExecutionConfig()  # the routing worker's default settings


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


def write_csv(path, records, fields=None):
    """Write rows to a CSV file."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    if not records and fields is None:
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


def _module(name):
    """Load a baseline file as a module."""
    p = E4 / 'baseline' / 'source_code' / f'{name}_baseline.py'
    spec = importlib.util.spec_from_file_location(name + '_baseline', p)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


class Adapter(TeamAdapter):
    """The team's routing adapter, pointed at the frozen benchmark and the E4 settings."""
    def __init__(self):
        self.input_sha256 = check_inputs(['road_nodes', 'road_distance_matrix', 'listings', 'vehicles', 'ngos', 'scenarios', 'scenario_members'])
        self.settings = dict(SETTINGS)
        self.root = ROOT
        self.modules = {n: _module(n) for n in ('nearest_next', 'fcfs')}
        self.base = self.modules['nearest_next']
        self.args = SimpleNamespace(**SETTINGS)
        self.data = self.base.setup_route_data(ROOT / 'benchmark dataset' / 'dataset')
        with (ROOT / 'benchmark dataset' / 'dataset' / 'road_nodes.csv').open(encoding='utf-8-sig') as f:
            self.nodes = {r['road_node_id']: r for r in csv.DictReader(f)}
        self.scenarios = self.base.select_scenarios(self.data, ('ROUTE_PLANNING',), None)
        assert len(self.scenarios) == 100

    def convert(self, scenario):
        # This is an E4-only adaptation: the benchmark expiry is copied from
        # legacy availability data, not supplied as a post-claim deadline by
        # the current donor workflow. The shared routing contract and its
        # lease, ownership, status, window, capacity and route checks remain on.
        # The shared v3.2 adapter admits tasks before returning, so provide an
        # in-memory non-expiring value while it builds the common snapshot.
        # Then set only this synthetic field to null and refreeze through the
        # normal contract. Restore the source dataset objects even on failure.
        original_expiries = {key: listing['listing_expires_at']
                             for key, listing in self.data.listings.items()}
        try:
            for listing in self.data.listings.values():
                listing['listing_expires_at'] = '9999-12-31T23:59:59'
            shared, frozen = super().convert(scenario)
        finally:
            for key, expiry in original_expiries.items():
                self.data.listings[key]['listing_expires_at'] = expiry
        payload = frozen.to_dict()['input']
        for task in payload['tasks']:
            task['listing_expires_at'] = None
        frozen = freeze_scenario(payload)

        def relabel(v):  # only the version label changes; data and costs stay the same
            if isinstance(v, dict):
                return {k: relabel(x) for k, x in v.items()}
            if isinstance(v, list):
                return [relabel(x) for x in v]
            return 'OSM-DIRECTED-v3.3' if v == 'OSM-DIRECTED-v3.2' else v
        payload = relabel(payload)
        payload['configuration']['version'] = 'E4-V33-EXPERIMENT'
        return shared, freeze_scenario(payload)


def preflight():
    """Verify the runtime and sealed benchmark admission without solving."""
    import matplotlib
    import numpy
    import ortools
    import scipy
    from ortools.sat.python import cp_model
    from scipy.stats import wilcoxon
    from backend.routing.planner.cp_sat import _optimise
    from backend.routing.validator.validation import validate_plan as independent_validator
    from backend.routing.planner.planning import OPERATIONAL_METHODS

    versions = {p.__name__: p.__version__ for p in (ortools, numpy, scipy, matplotlib)}
    for line in (E4 / 'requirements.txt').read_text(encoding='utf-8').splitlines():
        package, separator, version = line.partition('==')
        if separator and installed_version(package) != version:
            raise ValueError(f'E4 requires {package}=={version}; found {installed_version(package)}')
    if (sys.version_info[:3] != (3, 13, 9) or not callable(wilcoxon)
            or not hasattr(cp_model, 'CpSolver')):
        raise ValueError('E4 requires the documented Python 3.13.9 environment.')
    if (proposed is not OPERATIONAL_METHODS['proposed']
            or proposed.__globals__.get('_optimise') is not _optimise
            or validate_plan is not independent_validator):
        raise ValueError('E4 is not bound to the shared CP-SAT optimiser and validator.')
    adapter = Adapter()
    snapshots = {}
    admitted = set()
    for scenario in adapter.scenarios:
        shared, frozen = adapter.convert(scenario)
        fingerprint = snapshot_evidence(adapter, shared, frozen)
        task_ids = fingerprint['admitted_task_ids']
        if len(task_ids) != 5 or admitted.intersection(task_ids):
            raise ValueError(f'Unexpected admitted tasks in {scenario["scenario_id"]}')
        admitted.update(task_ids)
        snapshots[scenario['scenario_id']] = fingerprint
    if len(snapshots) != 100 or Counter(len(s['vehicle_ids']) for s in snapshots.values()) != {1: 50, 2: 50}:
        raise ValueError('The sealed benchmark scenario count or fleet distribution changed.')
    return dict(input_sha256=adapter.input_sha256, settings=SETTINGS,
                runtime_versions=versions, snapshots=snapshots)


def snapshot_evidence(adapter, shared, frozen):
    """Confirm that the baseline view and solver contract describe the same instance."""
    payload = frozen.to_dict()['input']
    matrix = payload['matrix']
    tasks = {t['task_id']: (t['road_node_id'], t['weight_kg']) for t in shared['tasks']}
    sealed_tasks = {t['task_id']: (t['pickup']['road_node_id'], t['weight_kg'])
                    for t in payload['tasks'] if t['task_id'] in frozen.admitted_task_ids}
    depot = payload['depot']['road_node_id']
    fleet = {v['vehicle_id']: v['capacity_kg'] for v in shared['fleet']
             if v['depot_road_node_id'] == depot}
    sealed_fleet = {v['vehicle_id']: v['capacity_kg'] for v in payload['vehicles']
                    if v['vehicle_id'] in frozen.available_vehicle_ids}
    if tasks != sealed_tasks or fleet != sealed_fleet or len(fleet) != len(shared['fleet']):
        raise ValueError(f'Baseline and sealed task, fleet or depot inputs differ: {shared["scenario_id"]}')
    for i, source in enumerate(matrix['node_order']):
        for j, target in enumerate(matrix['node_order']):
            actual = adapter.data.arc(source, target)
            expected = ((matrix['distance_km'][i][j], matrix['travel_minutes'][i][j])
                        if matrix['arc_status'][i][j] == 'AVAILABLE' else None)
            if actual != expected:
                raise ValueError(f'Directed matrix differs from baseline lookup: {source} -> {target}')
    return dict(frozen_snapshot_sha256=frozen.sha256, matrix_sha256=frozen.matrix_sha256,
                admitted_task_ids=sorted(tasks), vehicle_ids=sorted(fleet))


def evaluate(method):
    """Run one method on the 100 snapshots and return one checked row per scenario."""
    ad = Adapter()
    out = []
    for sc in ad.scenarios:
        shared, frozen = ad.convert(sc)
        evidence = snapshot_evidence(ad, shared, frozen)
        started = time.perf_counter()
        try:
            plan = proposed(frozen, CONFIG) if method == 'or_tools_route_optimiser' else baseline_plan(ad, shared, frozen, method, CONFIG)
            ms = (time.perf_counter() - started) * 1000
            v = validate_plan(frozen, plan)
            served = sum(len(r.stops) for r in plan.routes)
            valid = len(frozen.admitted_task_ids)
            viol = [x[0] for x in v.violations]
            met = v.metrics
            row = dict(scenario_id=sc['scenario_id'], method=method, valid_tasks=valid, served_tasks=served,
                       unserved_tasks=valid - served, coverage_percent=round(100 * served / valid, 1) if valid else None,
                       full_coverage='YES' if served == valid else 'NO',
                       total_distance_km=round(met.get('total_travel_km') or 0, 3),
                       driving_time_min=round(met.get('driving_minutes') or 0, 2),
                       route_duration_min=round(met.get('total_route_minutes') or 0, 2),
                       vehicles_used=sum(1 for r in plan.routes if r.stops),
                       capacity_violations=sum('CAPACITY' in x for x in viol),
                       duration_violations=sum('DURATION' in x for x in viol),
                       time_window_violations=sum('WINDOW' in x for x in viol),
                       other_violations=sum(not any(k in x for k in ('CAPACITY', 'DURATION', 'WINDOW')) for x in viol),
                       independent_check_passed='YES' if (v.valid and v.feasible) else 'NO',
                       plan_status=plan.status, timeout='YES' if plan.timeout else 'NO',
                       planning_time_ms=round(ms, 1),
                       unserved_reasons=json.dumps(dict(sorted(plan.unserved_reasons))),
                       coverage_proven_optimal='YES' if plan.coverage_optimal else 'NO',
                       optimization_status=plan.optimization_status,
                       solver_statuses=json.dumps(plan.solver_statuses),
                       secondary_proven_optimal='YES' if plan.secondary_optimal else 'NO',
                       coverage_bound=plan.pickup_task_objective_bound,
                       distance_bound_scaled=plan.secondary_bound_scaled,
                       distance_objective_scaled=plan.secondary_objective_scaled,
                       optimality_gap=plan.optimality_gap,
                       frozen_snapshot_sha256=evidence['frozen_snapshot_sha256'],
                       matrix_sha256=evidence['matrix_sha256'],
                       admitted_task_ids=json.dumps(evidence['admitted_task_ids']),
                       vehicle_ids=json.dumps(evidence['vehicle_ids']),
                       plan_sha256=hashlib.sha256(json.dumps(semantic(plan), sort_keys=True, default=str).encode()).hexdigest(),
                       error='')
            routes = [dict(scenario_id=sc['scenario_id'], vehicle_id=r.vehicle_id,
                           stops_in_order=' > '.join(s.task_id for s in r.stops), stops=len(r.stops)) for r in plan.routes if r.stops]
        except Exception as exc:  # keep failures visible
            row = dict(scenario_id=sc['scenario_id'], method=method, valid_tasks=len(frozen.admitted_task_ids),
                       independent_check_passed='NO', error=f'{type(exc).__name__}: {exc}')
            routes = []
        row['_routes'] = routes
        out.append(row)
    return out, ad


def source_fingerprints():
    """Fingerprint the routing package, including transitive Python modules."""
    files = [p for p in (ROOT / 'backend/routing').rglob('*.py') if 'tests' not in p.parts]
    files.extend(p for p in E4.rglob('*.py') if 'results' not in p.relative_to(E4).parts)
    benchmark = ROOT / 'experiments/routing_research/benchmark_v32'
    files.extend(benchmark / name for name in ('__init__.py', 'adapter.py', 'runner.py', 'test_adapter.py'))
    algorithms = ROOT / 'experiments/routing_research/algorithms'
    files.extend(algorithms / name for name in ('__init__.py', 'benchmark.py', 'routing_model.py', 'scenarios.py'))
    files.append(E4 / 'requirements.txt')
    backend_package = ROOT / 'backend' / '__init__.py'
    if backend_package.is_file():
        files.append(backend_package)
    return {p.relative_to(ROOT).as_posix(): sha256(p) for p in sorted(files)}


TITLES = dict(nearest_next='Nearest-Next (baseline 1)', fcfs='First come first served, FCFS (baseline 2)',
              or_tools_route_optimiser='OR-Tools route optimiser (proposed, current app)')
HOW = dict(nearest_next="its own plan_routes(): each vehicle in turn drives to the nearest pickup it can still fit and finish in time",
           fcfs="its own plan_routes(): each vehicle in turn takes pickups in the order they were claimed",
           or_tools_route_optimiser='backend.routing.planner.methods.proposed -> backend/routing/planner/cp_sat.py '
                                    '(Google OR-Tools CP-SAT; the same callable the routing worker uses)')


def run_and_save(method):
    """Run one method and write its result folder."""
    run_id = os.environ.get('GEOLOCK_E4_RUN_ID', '')
    directory = run_directory(run_id)
    if not (directory / 'run_manifest.json').is_file():
        raise ValueError('Start a new E4 run with run_e4.py.')
    manifest = json.loads((directory / 'run_manifest.json').read_text(encoding='utf-8'))
    fingerprints = source_fingerprints()
    if (manifest['run_id'] != run_id or manifest['status'] != 'in_progress'
            or manifest['source_sha256'] != fingerprints):
        raise ValueError('E4 run identity or source fingerprints changed.')
    out = directory / 'methods' / ('optimiser' if method == 'or_tools_route_optimiser' else method)
    if (directory / 'methods').resolve() != directory / 'methods':
        raise ValueError('The E4 method directory cannot be redirected.')
    out.mkdir(parents=True, exist_ok=False)
    rows, adapter = evaluate(method)
    write_csv(out / 'details' / 'routes.csv', [r for x in rows for r in x.pop('_routes')],
              fields=('scenario_id', 'vehicle_id', 'stops_in_order', 'stops'))
    write_csv(out / 'results_per_scenario.csv', rows, fields=list(dict.fromkeys(key for row in rows for key in row)))
    env = environment()
    info = [('Run ID', run_id), ('Run at', env['run_at']), ('Scenarios', f'{len(rows)} ROUTE_PLANNING snapshots (sealed, shared by all E4 methods)'),
            ('Method', HOW[method]), ('Execution policy', f'{CONFIG}'),
            ('Settings', '240 minute route, 10 min per stop, 360 minute lease, fixed cost 5 + 1 per km'),
            ('Validator', 'backend.routing.validator.validate_plan (independent recomputation)')]
    if method == 'or_tools_route_optimiser':
        info.append(('OR-Tools', env['packages'].get('ortools')))
    info.append(('Python', env['python']))
    run_info(out / 'run_info.md', TITLES[method], info)
    write_json(out / 'run_manifest.json', dict(method=method, run_id=run_id, settings=SETTINGS,
        input_sha256=adapter.input_sha256,
        source_sha256=fingerprints,
        artifact_sha256={'results_per_scenario.csv': sha256(out / 'results_per_scenario.csv'),
                         'details/routes.csv': sha256(out / 'details' / 'routes.csv'),
                         'run_info.md': sha256(out / 'run_info.md')},
        environment=env))
    print(f"{TITLES[method]}: {sum(r.get('served_tasks') or 0 for r in rows)}/{sum(r['valid_tasks'] for r in rows)} pickups served, "
          f"{sum(r.get('total_distance_km') or 0 for r in rows):,.1f} km, "
          f"{sum(r['independent_check_passed'] == 'YES' for r in rows)}/100 plans valid -> {out}")
    if len(rows) != 100 or any(row['independent_check_passed'] != 'YES' for row in rows):
        raise ValueError(f'E4 method {method} failed; partial evidence is in {out}')
    return rows
