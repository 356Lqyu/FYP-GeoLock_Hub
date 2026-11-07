"""Read-only audit of saved Phase B artifacts; writes only this review's output.

No solver rerun, benchmark overwrite, database adapter, or product-code changes.
Run from repository root using .venv-stage8 Python.
"""

from collections import Counter, defaultdict
from dataclasses import asdict
import hashlib
import json
import math
from pathlib import Path
import statistics

from backend.routing import freeze_scenario
from backend.routing.phase_b.benchmark import check_phase_a, digest, semantic
from backend.routing.phase_b.models import Plan, Route, Stop, ExecutionConfig
from backend.routing.phase_b.validation import validate_plan

ROOT = Path(__file__).resolve().parents[3]
RESULTS = ROOT / "results/stage8-phase-b"


def plan_from_json(value):
    p = dict(value)
    p["config"] = ExecutionConfig(**p["config"])
    p["routes"] = tuple(Route(**{**r, "stops": tuple(Stop(**s) for s in r["stops"])}) for r in p["routes"])
    for key in ("unserved_tasks", "solver_statuses"):
        p[key] = tuple(p[key])
    p["unserved_reasons"] = tuple(tuple(item) for item in p["unserved_reasons"])
    return Plan(**p)


def main():
    load = lambda name: json.loads((RESULTS/name).read_text(encoding="utf-8"))
    manifest, snapshot_rows, records, comparisons = (load(n) for n in
        ("manifest.json", "snapshots.json", "results.json", "comparison.json"))
    assert check_phase_a() == 17
    source_verified = all(hashlib.sha256((ROOT/p).read_bytes()).hexdigest() == h
                          for p, h in manifest["source_sha256"].items())
    assert source_verified
    assert digest(load("non-timing-results.json")) == manifest["non_timing_results_sha256"]
    snapshots = {name: freeze_scenario(row["envelope"]["input"]) for name, row in snapshot_rows.items()}
    for name, s in snapshots.items():
        assert s.sha256 == snapshot_rows[name]["sha256"]
        assert s.to_dict() == snapshot_rows[name]["envelope"]
    replayed, signature_groups, gaps = 0, defaultdict(set), Counter()
    for record in records:
        s = snapshots[record["scenario"]]
        plan = plan_from_json(record["plan"])
        validation = validate_plan(s, plan)
        assert validation.valid, (record["scenario"], record["method"], validation.violations)
        assert json.loads(json.dumps(asdict(validation))) == record["validation"]
        assert record["snapshot_sha256"] == s.sha256 == plan.snapshot_sha256
        assert record["matrix_sha256"] == s.matrix_sha256 == plan.matrix_sha256
        signature = digest(semantic(plan))
        assert signature == record["semantic_sha256"]
        signature_groups[record["scenario"], record["method"]].add(signature)
        if plan.optimality_gap is not None:
            assert plan.coverage_optimal and plan.solver_statuses[0] == "OPTIMAL"
            assert plan.solver_statuses[-1] in ("OPTIMAL", "FEASIBLE")
            assert plan.gap_scope == "FIXED_COVERAGE_SECONDARY"
            objective, bound = plan.secondary_objective_scaled, plan.secondary_bound_scaled
            assert objective is not None and bound is not None and bound <= objective
            expected = (validation.metrics["total_travel_km"] if plan.method == "distance_only"
                        else validation.metrics["weighted_secondary_cost"])*1_000_000
            assert math.isclose(objective, expected, rel_tol=0, abs_tol=.00001)
            assert math.isclose(plan.optimality_gap, max(0, objective-bound)/max(1, abs(objective)))
            gaps["supported_numeric_gap"] += 1
        else:
            gaps["not_available"] += 1
        replayed += 1
    assert all(len(values) == 1 for values in signature_groups.values())
    indexed = defaultdict(dict)
    for row in comparisons:
        indexed[row["scenario"]][row["method"]] = row
    dominance = {}
    for baseline in ("fcfs", "nearest_neighbour", "distance_only"):
        result = Counter()
        for name, methods in indexed.items():
            p, b = methods["proposed"], methods[baseline]
            if not (p["plan_feasible"] and b["plan_feasible"]):
                result["not_a_feasible_pair"] += 1
                continue
            result["feasible_pairs"] += 1
            diff = p["served_count"]-b["served_count"]
            result["coverage_better" if diff > 0 else "coverage_equal" if diff == 0 else "coverage_worse"] += 1
            pscore = (p["unserved_count"], p["weighted_secondary_cost"])
            bscore = (b["unserved_count"], b["weighted_secondary_cost"])
            result["lexicographic_better" if pscore < bscore else "lexicographic_equal" if pscore == bscore else "lexicographic_worse"] += 1
            if diff == 0:
                result["same_coverage_cost_better" if pscore[1] < bscore[1] else
                       "same_coverage_cost_equal" if pscore[1] == bscore[1] else "same_coverage_cost_worse"] += 1
        dominance[baseline] = dict(result)
    runtime = {}
    for method in ("fcfs", "nearest_neighbour", "distance_only", "proposed"):
        selected = [r for r in records if r["method"] == method]
        method_ms = sorted(r["plan"]["runtime_seconds"]*1000 for r in selected)
        solver_ms = sorted(r["plan"]["solver_runtime_seconds"]*1000 for r in selected if r["plan"]["solver_statuses"])
        runtime[method] = {"calls": len(selected), "median_method_ms": statistics.median(method_ms),
                           "p95_method_ms_nearest_rank": method_ms[math.ceil(.95*len(method_ms))-1],
                           "max_method_ms": max(method_ms), "solver_calls": len(solver_ms),
                           "median_solver_ms": statistics.median(solver_ms) if solver_ms else None,
                           "max_solver_ms": max(solver_ms) if solver_ms else None,
                           "timeout_count": sum(r["plan"]["timeout"] for r in selected)}
    case_rows = []
    for name, s in snapshots.items():
        case_rows.append({"scenario": name, "admitted": len(s.admitted_task_ids), "readiness": s.readiness,
                          "methods": {m: {k: r[k] for k in ("status", "plan_feasible", "served_count", "unserved_count",
                                      "total_travel_km", "total_route_minutes", "routes_used", "total_cost", "weighted_secondary_cost")}
                                      for m, r in indexed[name].items()}})
    result = {"phase_a_files_preserved": 17, "source_manifest_verified": source_verified,
              "non_timing_results_sha256": manifest["non_timing_results_sha256"],
              "records_revalidated": replayed, "reproducible_groups": len(signature_groups),
              "gap_records": dict(gaps), "dominance": dominance, "runtime": runtime,
              "comparison_status_counts": dict(Counter(r["status"] for r in comparisons)),
              "comparison_feasible": sum(r["plan_feasible"] for r in comparisons),
              "maximum_admitted_tasks": max(len(s.admitted_task_ids) for s in snapshots.values()),
              "maximum_vehicles": max(len(s.available_vehicle_ids) for s in snapshots.values()),
              "maximum_matrix_nodes": max(len(s.to_dict()["input"]["matrix"]["node_order"]) for s in snapshots.values()),
              "cases": case_rows}
    target = Path(__file__).with_name("phase-b-final-benchmark-audit.json")
    target.write_text(json.dumps(result, indent=2, sort_keys=True)+"\n", encoding="utf-8")
    lines = ["# Full Phase B Synthetic Scenario Review", "",
             "Each cell is served/unserved; km; configured weighted cost; status. All are synthetic.",
             "Infeasible/blocked rows are not objective-dominance comparisons.", "",
             "| Scenario | Admitted | FCFS | Nearest-neighbour | Distance-only | Proposed |",
             "|---|---:|---|---|---|---|"]
    for case in case_rows:
        cells = []
        for method in ("fcfs", "nearest_neighbour", "distance_only", "proposed"):
            r = case["methods"][method]
            cells.append(f"{r['served_count']}/{r['unserved_count']}; {r['total_travel_km']:g}; "
                         f"{r['weighted_secondary_cost']:g}; {r['status']}")
        lines.append(f"| {case['scenario']} | {case['admitted']} | "+" | ".join(cells)+" |")
    Path(__file__).with_name("phase-b-all-scenarios-review.md").write_text("\n".join(lines)+"\n", encoding="utf-8")
    print(json.dumps({k: v for k, v in result.items() if k != "cases"}, indent=2))


if __name__ == "__main__":
    main()
