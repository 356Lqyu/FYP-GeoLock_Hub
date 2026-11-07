"""Offline paired benchmark. All methods consume the exact same FrozenScenario."""

import argparse
import csv
from dataclasses import asdict
import hashlib
from importlib.metadata import distributions
import json
from pathlib import Path
import platform
import statistics
import sys

from . import METHODS
from .models import ExecutionConfig
from .scenarios import scenarios
from .validation import validate_plan

ROOT = Path(__file__).resolve().parents[3]
PRESERVATION = ROOT/"docs/stage8/phase-b-phase-a-preservation.json"


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()).hexdigest()


def check_phase_a():
    expected = json.loads(PRESERVATION.read_text())
    changed = [path for path, sha in expected.items()
               if not (ROOT/path).is_file() or hashlib.sha256((ROOT/path).read_bytes()).hexdigest() != sha]
    if changed:
        raise RuntimeError("PHASE_A_CHANGED: "+", ".join(changed))
    return len(expected)


def semantic(plan):
    result = asdict(plan)
    result.pop("runtime_seconds")
    result.pop("solver_runtime_seconds")
    return result


def run_benchmark(output, repeats=3, config=ExecutionConfig(), selected=None):
    if type(repeats) is not int or repeats < 1:
        raise ValueError("repeats must be a positive integer")
    preserved = check_phase_a()
    # Warm imports before method timings; no timed method pays solver import cost.
    import ortools
    from ortools.sat.python import cp_model  # noqa: F401

    cases = selected if selected is not None else scenarios()
    records, comparisons, semantic_rows = [], [], []
    for name, snapshot in cases.items():
        if snapshot.to_dict()["input"]["source"]["kind"] != "SYNTHETIC_BENCHMARK":
            raise ValueError("Benchmark accepts explicitly synthetic inputs only")
        for method, solve in METHODS.items():
            attempts = []
            for repetition in range(repeats):
                plan = solve(snapshot, config)
                validation = validate_plan(snapshot, plan)
                if not validation.valid:
                    raise RuntimeError(f"INVALID_PLAN {name}/{method}: {validation.violations}")
                record = {"scenario": name, "method": method, "repetition": repetition,
                          "snapshot_sha256": snapshot.sha256, "matrix_sha256": snapshot.matrix_sha256,
                          "plan": asdict(plan), "validation": asdict(validation),
                          "semantic_sha256": digest(semantic(plan))}
                attempts.append(record)
                records.append(record)
            if len({r["semantic_sha256"] for r in attempts}) != 1:
                raise RuntimeError(f"NONREPRODUCIBLE_RESULT {name}/{method}; inspect limits and environment")
            p, validation = attempts[0]["plan"], attempts[0]["validation"]
            row = {"scenario": name, "method": method, "synthetic": True,
                   "snapshot_sha256": snapshot.sha256, "matrix_sha256": snapshot.matrix_sha256,
                   "status": p["status"], "validation_valid": validation["valid"],
                   "plan_feasible": validation["feasible"], **validation["metrics"],
                   "runtime_seconds_median": statistics.median(r["plan"]["runtime_seconds"] for r in attempts),
                   "runtime_seconds_min": min(r["plan"]["runtime_seconds"] for r in attempts),
                   "runtime_seconds_max": max(r["plan"]["runtime_seconds"] for r in attempts),
                   "solver_runtime_seconds_median": statistics.median(r["plan"]["solver_runtime_seconds"] for r in attempts),
                   "timeout": p["timeout"], "solver_statuses": p["solver_statuses"],
                   "optimality_gap": p["optimality_gap"], "gap_scope": p["gap_scope"],
                   "secondary_bound_scaled": p["secondary_bound_scaled"],
                   "secondary_objective_scaled": p["secondary_objective_scaled"],
                   "coverage_optimal": p["coverage_optimal"], "secondary_optimal": p["secondary_optimal"],
                   "infeasibility_proven": p["infeasibility_proven"],
                   "semantic_sha256": attempts[0]["semantic_sha256"]}
            comparisons.append(row)
            semantic_rows.append({"scenario": name, "method": method, "plan": semantic(plan),
                                  "validation": validation})
    check_phase_a()
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    source_root = ROOT/"backend/routing/phase_b"
    manifest = {"execution_contract_version": "geolock.routing.execution.v1",
                "synthetic_only": True, "live_database_access": False, "dispatch_authority_issued": False,
                "phase_a_files_preserved": preserved, "repeats": repeats, "scenario_count": len(cases),
                "method_count": len(METHODS), "execution_count": len(records),
                "python": sys.version, "platform": platform.platform(), "processor": platform.processor(),
                "solver_engine": "MIXED_SEE_METHOD_ENGINES", "solver_version": ortools.__version__,
                "method_engines": {name: ('OR-Tools RoutingModel' if solve.__module__.endswith('routing_model')
                    else 'OR-Tools CP-SAT' if solve.__module__.endswith('optimizers') else 'DETERMINISTIC_HEURISTIC')
                    for name,solve in METHODS.items()},
                "execution_config": asdict(config), "non_timing_results_sha256": digest(semantic_rows),
                "source_sha256": {p.relative_to(ROOT).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
                                  for p in sorted(source_root.rglob("*.py"))},
                "packages": {d.metadata["Name"]: d.version for d in distributions()},
                "limitations": ["synthetic toy cases, not operational road measurements",
                                "runtime is measured and not byte-deterministic",
                                "CP-SAT settings are execution-side; Phase A RoutingModel first_solution/local_search fields are not used",
                                "mandatory tasks are hard constraints for optimizers; heuristic infeasible plans are not impossibility proofs",
                                "no plan in this benchmark creates live dispatch authority"]}
    snapshots = {name: {"sha256": s.sha256, "matrix_sha256": s.matrix_sha256, "envelope": s.to_dict()}
                 for name, s in cases.items()}
    for name, data in (("manifest.json", manifest), ("snapshots.json", snapshots),
                       ("results.json", records), ("comparison.json", comparisons),
                       ("non-timing-results.json", semantic_rows)):
        (output/name).write_text(json.dumps(data, indent=2, sort_keys=True, allow_nan=False)+"\n", encoding="utf-8")
    with (output/"comparison.csv").open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(comparisons[0]) if comparisons else [])
        writer.writeheader()
        for row in comparisons:
            writer.writerow({k: json.dumps(v) if isinstance(v, (list, tuple)) else v for k, v in row.items()})
    lines = ["# Phase B Synthetic Routing Benchmark", "",
             f"{len(cases)} scenarios x {len(METHODS)} methods x {repeats} repetitions = {len(records)} executions.",
             "All inputs are synthetic. Validation-valid means internally consistent reporting; inspect plan-feasible separately.",
             "Infeasible/blocked zero-distance rows are not routing improvements. N/A means no justified solver gap.", "",
             "| Scenario | Method | Status | Feasible | Served/unserved | km | min | Routes | Cost | Runtime ms median | Gap |",
             "|---|---|---|---|---|---:|---:|---:|---:|---:|---:|"]
    for r in comparisons:
        gap = "N/A" if r["optimality_gap"] is None else f"{r['optimality_gap']:.4g}"
        lines.append(f"| {r['scenario']} | {r['method']} | {r['status']} | {r['plan_feasible']} | "
                     f"{r['served_count']}/{r['unserved_count']} | {r['total_travel_km']:g} | "
                     f"{r['total_route_minutes']:g} | {r['routes_used']} | {r['total_cost']:g} | "
                     f"{r['runtime_seconds_median']*1000:.3f} | {gap} |")
    lines.extend(["", "Capacity/time-window/duration violations are recorded separately in CSV/JSON.",
                  "Plans, exclusions, per-stop schedules, unavailable arcs, objective components, solver status/bounds and input hashes are retained in JSON.",
                  "Full interpretation and Phase C design: docs/stage8/2026-10-24-phase-b-offline-routing.md."])
    (output/"comparison.md").write_text("\n".join(lines)+"\n", encoding="utf-8")
    return manifest, comparisons


def main():
    parser = argparse.ArgumentParser(description="Run offline synthetic routing methods and independent validation")
    parser.add_argument("--output", default="results/stage8-phase-b")
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--fixed-cost-weight", type=float, default=1)
    parser.add_argument("--distance-cost-weight", type=float, default=1)
    parser.add_argument("--deterministic-seconds-per-pass", type=float, default=.25)
    args = parser.parse_args()
    config = ExecutionConfig(args.fixed_cost_weight, args.distance_cost_weight, args.deterministic_seconds_per_pass)
    manifest, _ = run_benchmark(args.output, args.repeats, config)
    print(json.dumps({"executions": manifest["execution_count"], "scenarios": manifest["scenario_count"],
                      "non_timing_results_sha256": manifest["non_timing_results_sha256"], "output": args.output}, indent=2))


if __name__ == "__main__":
    main()
