"""Default preflight only. Experiments require explicit reviewed settings."""
import argparse
from dataclasses import asdict
from decimal import Decimal
import hashlib
import json
from pathlib import Path
import platform
from time import perf_counter

from .adapter import Adapter, ROOT, sha
from ..phase_b import distance_only, proposed, validate_plan
from ..phase_b.benchmark import semantic
from ..phase_b.models import ExecutionConfig, Route, Stop
from ..phase_b.problem import Problem, TIME_SCALE


def baseline_plan(adapter, shared, frozen, method, config):
    module = adapter.modules[method]
    # Original teammate methods execute only here, after the experiment gate.
    started = perf_counter()
    routes, unserved = module.plan_routes(adapter.data, shared, adapter.args)
    elapsed = perf_counter()-started
    module.validate_plan(adapter.data, shared, routes, unserved, adapter.args)
    problem = Problem(frozen)
    depot = problem.p['depot']
    converted = []
    us = lambda minutes: round(Decimal(str(minutes))*TIME_SCALE)
    for r in routes:
        stops, load = [], Decimal(0)
        for stop in r['stops']:
            task = problem.tasks[stop['task_id']]
            load += Decimal(str(task['weight_kg']))
            arrival = us(stop['arrival_elapsed_min'])
            stops.append(Stop(task['task_id'], task['pickup']['location_id'], stop['road_node_id'],
                arrival, arrival, us(stop['completion_elapsed_min']), float(load)))
        converted.append(Route(r['vehicle_id'], shared['ngo_id'], depot['location_id'], r['depot_road_node_id'],
            depot['location_id'], r['depot_road_node_id'], 0, tuple(stops), us(r['duration_min'])))
    plan = problem.finish('teammate_'+method, converted, config, reasons=unserved, runtime_seconds=elapsed)
    if set(plan.unserved_tasks) != set(unserved):
        raise ValueError('BASELINE_ACCOUNTING_DIFFERS')
    return plan


def preflight(adapter):
    rows = []
    for scenario in adapter.scenarios:
        shared, frozen = adapter.convert(scenario)
        rows.append(dict(scenario_id=shared['scenario_id'], shared_snapshot_sha256=shared['snapshot_id'],
            frozen_sha256=frozen.sha256, matrix_sha256=frozen.matrix_sha256, admitted_tasks=len(frozen.admitted_task_ids),
            excluded_tasks=shared['excluded_tasks'], unavailable_arcs=len(frozen.unavailable_arcs),
            vehicle_count=len(frozen.available_vehicle_ids), readiness=frozen.readiness))
    return dict(status='INPUT_PREFLIGHT_ONLY_NOT_EXPERIMENT_RESULTS', settings=adapter.settings,
        integrity=adapter.integrity, scenarios=rows, scenario_count=len(rows),
        admitted_tasks=sum(r['admitted_tasks'] for r in rows),
        experiment_executed=False, database_access=False, dispatch_authority_issued=False)


def execution_gate(settings, execute):
    if not execute or settings['approved'] is not True:
        raise ValueError('EXPERIMENT_NOT_APPROVED')


def run(adapter, output, execute=False):
    execution_gate(adapter.settings, execute)
    prepared = [(adapter.convert(s)) for s in adapter.scenarios]
    output = Path(output).resolve()
    # Never write into original benchmark/baseline/public folders, or reuse a run.
    for name in ('benchmark dataset','baseline implementation','public dataset'):
        if output.is_relative_to((adapter.root/name).resolve()):
            raise ValueError('ORIGINAL_DATA_OUTPUT_FORBIDDEN')
    output.mkdir(parents=True, exist_ok=False)
    config = ExecutionConfig(deterministic_seconds_per_pass=adapter.settings['deterministic_seconds_per_pass'])
    manifest = preflight(adapter)
    manifest.update(status='EXPERIMENT_RUN', experiment_executed=True, python=platform.python_version(),
        methods=['teammate_fcfs','teammate_nearest_next','distance_only','proposed'],
        source_sha256={str(p.relative_to(ROOT)):sha(p) for directory in
            (ROOT/'backend/routing/benchmark_v32', ROOT/'backend/routing/phase_b')
            for p in sorted(directory.glob('*.py'))})
    manifest['source_sha256'].update({str(ROOT/'backend/routing/contract.py'):sha(ROOT/'backend/routing/contract.py'),
        **{str(adapter.root/'baseline implementation/source code'/f'{name}_baseline.py'):
        sha(adapter.root/'baseline implementation/source code'/f'{name}_baseline.py') for name in adapter.modules}})
    import ortools
    manifest['ortools_version'] = ortools.__version__
    write = lambda name, value: (output/name).write_text(json.dumps(value, indent=2, allow_nan=False)+'\n')
    write('manifest.json', manifest)
    records = []
    for shared, frozen in prepared:
        sealed_before = adapter.base.digest(shared)
        for method in manifest['methods']:
            if method.startswith('teammate_'):
                plan = baseline_plan(adapter, shared, frozen, method.removeprefix('teammate_'), config)
            else:
                plan = {'distance_only':distance_only, 'proposed':proposed}[method](frozen, config)
            if adapter.base.digest(shared) != sealed_before:
                raise ValueError('SHARED_INPUT_MUTATED')
            checked = validate_plan(frozen, plan)
            if not checked.valid:
                raise ValueError('INDEPENDENT_VALIDATION_FAILED: '+str(checked.violations))
            row = dict(scenario=shared['scenario_id'], method=method, frozen_sha256=frozen.sha256,
                matrix_sha256=frozen.matrix_sha256, plan=asdict(plan), validation=asdict(checked),
                semantic_sha256=hashlib.sha256(json.dumps(semantic(plan), sort_keys=True).encode()).hexdigest())
            records.append(row)
            write(shared['scenario_id']+'-'+method+'.json', row)
        write(shared['scenario_id']+'-input.json', dict(shared=shared, frozen=frozen.to_dict()))
    write('results.json', records)
    write('completion.json', dict(status='COMPLETE', independently_validated=len(records)))


def main():
    p = argparse.ArgumentParser(__doc__)
    p.add_argument('--settings', type=Path, default=Path(__file__).with_name('proposed_settings.json'))
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--execute-reviewed-config', action='store_true')
    args = p.parse_args()
    settings = json.loads(args.settings.read_text())
    adapter = Adapter(settings)
    if args.execute_reviewed_config:
        run(adapter, args.output, True)
    else:
        report = preflight(adapter)
        with args.output.open('x', encoding='utf-8') as f:
            json.dump(report, f, indent=2)
        print('Preflight only:', report['scenario_count'], 'scenarios;', report['admitted_tasks'], 'admitted tasks')


if __name__ == '__main__':
    main()
