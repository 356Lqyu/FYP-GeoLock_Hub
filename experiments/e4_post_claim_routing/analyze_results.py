"""Paired, scenario-level statistics for one saved E4 run; never runs planners."""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from experiments.analyze_prespecified_e2_e4 import (  # noqa: E402
    SEED,
    bool_value,
    holm,
    mcnemar,
    paired_continuous,
)

METHODS = ("nearest_next", "fcfs", "proposed")


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open(encoding="utf-8-sig", newline="") as stream:
        return list(csv.DictReader(stream))


def write_csv(path: Path, rows: list[dict]) -> None:
    if not rows:
        raise ValueError(f"Refusing to write empty analysis table: {path.name}")
    fields = list(dict.fromkeys(key for row in rows for key in row))
    with path.open("w", encoding="utf-8", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=fields, extrasaction="raise")
        writer.writeheader()
        writer.writerows(rows)


def analyze(run: Path) -> Path:
    run = run.resolve()
    completion_path = run / "completion.json"
    results_path = run / "results_per_scenario.csv"
    if not completion_path.is_file() or not results_path.is_file():
        raise FileNotFoundError("Run must contain completion.json and results_per_scenario.csv")
    completion = json.loads(completion_path.read_text(encoding="utf-8"))
    if not completion.get("all_100_completed") or completion.get("evaluations") != 300:
        raise ValueError("E4 analysis requires all 100 scenarios and 300 method evaluations")
    if completion.get("errors") != 0:
        raise ValueError("E4 analysis refuses a run containing planner/evaluation errors")
    verification_path = run / "verification.json"
    if not verification_path.is_file():
        raise FileNotFoundError("Run must first pass the independent route-artifact verifier")
    verification = json.loads(verification_path.read_text(encoding="utf-8"))
    if verification.get("saved_routes_independently_revalidated") != 300:
        raise ValueError("Expected independent validation of all 300 saved method plans")
    if verification.get("additional_admission_exclusions") != 0:
        raise ValueError("Corrected E4 analysis requires no remaining admission exclusions")

    results = read_csv(results_path)
    if len(results) != 300:
        raise ValueError(f"Expected 300 result rows; found {len(results)}")
    by_method = {m: {} for m in METHODS}
    for row in results:
        method = row["method"]
        if method not in by_method:
            raise ValueError(f"Unexpected E4 method: {method}")
        sid = row["scenario_id"]
        if sid in by_method[method]:
            raise ValueError(f"Duplicate scenario/method result: {sid}/{method}")
        by_method[method][sid] = row
    scenario_ids = set(by_method["proposed"])
    if len(scenario_ids) != 100 or any(set(x) != scenario_ids for x in by_method.values()):
        raise ValueError("Methods must contain the same 100 scenario IDs")

    input_files = sorted((run / "raw").glob("*-input.json"))
    if len(input_files) != 100:
        raise ValueError(f"Expected 100 saved common inputs; found {len(input_files)}")
    candidate_total = admitted_total = excluded_total = 0
    input_by_id = {}
    for path in input_files:
        raw = json.loads(path.read_text(encoding="utf-8"))
        sid = raw["shared"]["scenario_id"]
        if sid in input_by_id or sid not in scenario_ids:
            raise ValueError(f"Duplicate or unknown saved common input: {sid}")
        candidate_ids = {t["task_id"] for t in raw["worker_input"]["input"]["tasks"]}
        admitted_ids = set(raw["worker_input"]["admitted_task_ids"])
        if candidate_ids != admitted_ids:
            raise ValueError(f"Not all candidate tasks were admitted in {sid}")
        candidate_total += len(candidate_ids)
        admitted_total += len(admitted_ids)
        excluded_total += len(raw["exclusions"])
        input_by_id[sid] = raw
        frozen_hashes = {by_method[m][sid]["frozen_sha256"] for m in METHODS}
        snapshot_hashes = {by_method[m][sid]["shared_snapshot_sha256"] for m in METHODS}
        if len(frozen_hashes) != 1 or len(snapshot_hashes) != 1:
            raise ValueError(f"Methods did not use the same frozen input in {sid}")

    if candidate_total != 500 or admitted_total != 500 or excluded_total != 0:
        raise ValueError(
            f"Expected 500 candidates/admissions and no exclusions; found "
            f"{candidate_total}/{admitted_total}/{excluded_total}"
        )

    tests: list[dict] = []
    secondary_positions: list[int] = []
    seed_index = 0
    for baseline in ("nearest_next", "fcfs"):
        base = by_method[baseline]
        proposed = by_method["proposed"]
        ordered = sorted(scenario_ids)
        for metric, fn in (
            ("all_admitted_tasks_served", lambda r: int(r["served_tasks"]) == int(r["valid_tasks"])),
            ("independent_feasibility_pass", lambda r: bool_value(r["feasibility_pass"]) and bool_value(r["validation_valid"])),
        ):
            stat = mcnemar([fn(base[s]) for s in ordered], [fn(proposed[s]) for s in ordered])
            tests.append({
                "family": "paired_binary", "baseline": baseline, "proposed": "proposed",
                "metric": metric, **stat, "p_holm_e4_secondary": "",
            })

        for metric, getter, scope in (
            ("served_tasks", lambda r: float(r["served_tasks"]), "primary_coverage"),
            ("coverage_percent", lambda r: float(r["coverage_percent"]), "primary_coverage"),
            ("method_pipeline_wall_ms", lambda r: float(r["method_pipeline_wall_ms"]), "secondary"),
            ("end_to_end_evaluation_ms", lambda r: float(r["end_to_end_evaluation_ms"]), "secondary"),
        ):
            seed_index += 1
            stat = paired_continuous(
                [getter(base[s]) for s in ordered],
                [getter(proposed[s]) for s in ordered],
                SEED + 500 + seed_index,
            )
            row = {"family": "paired_continuous", "baseline": baseline, "proposed": "proposed",
                   "metric": metric, "analysis_scope": scope, **stat, "p_holm_e4_secondary": ""}
            if scope == "secondary":
                secondary_positions.append(len(tests))
            tests.append(row)

        matched = []
        for sid in ordered:
            base_metrics = json.loads(base[sid]["metrics"])
            proposed_metrics = json.loads(proposed[sid]["metrics"])
            base_tasks = set(base_metrics.get("served_pickup_tasks", []))
            proposed_tasks = set(proposed_metrics.get("served_pickup_tasks", []))
            if base_tasks == proposed_tasks:
                matched.append(sid)
        for metric, field in (
            ("distance_km_identical_served_task_set", "total_distance_km"),
            ("driving_minutes_identical_served_task_set", "travel_duration_min"),
        ):
            seed_index += 1
            stat = paired_continuous(
                [float(base[s][field]) for s in matched],
                [float(proposed[s][field]) for s in matched],
                SEED + 500 + seed_index,
            )
            row = {"family": "paired_continuous", "baseline": baseline, "proposed": "proposed",
                   "metric": metric, "analysis_scope": "identical_served_task_sets_only",
                   "matched_scenarios": len(matched), **stat, "p_holm_e4_secondary": ""}
            secondary_positions.append(len(tests))
            tests.append(row)

    adjusted = holm([float(tests[i]["p_exact_two_sided"]) for i in secondary_positions])
    for position, p_adjusted in zip(secondary_positions, adjusted):
        tests[position]["p_holm_e4_secondary"] = p_adjusted

    out = run / "statistical_analysis"
    out.mkdir(exist_ok=False)
    write_csv(out / "paired_tests.csv", tests)
    manifest = {
        "status": "ANALYSIS_COMPLETE",
        "analysis_only": True,
        "benchmark_rerun": False,
        "independent_unit": "scenario",
        "candidate_tasks": candidate_total,
        "admitted_tasks": admitted_total,
        "exclusions": excluded_total,
        "bootstrap_replicates": 10000,
        "bootstrap_seed_base": SEED + 500,
        "methods": list(METHODS),
        "tests": {
            "paired_binary": "exact two-sided McNemar",
            "paired_continuous": "exact Wilcoxon signed-rank with Pratt zero ranking and midranks",
            "effect": "Hodges-Lehmann paired location with paired bootstrap percentile 95% CI",
            "multiplicity": "Holm across E4 secondary timing and identical-task-set distance/time comparisons",
            "route_distance_and_time": "only scenarios with exactly identical served task ID sets",
        },
        "population_limit": "Bootstrap intervals describe this fixed GEOLOCK-BM-v3.3 scenario set, not a sampled population.",
        "inputs": {
            "results_per_scenario.csv": sha256(results_path),
            "completion.json": sha256(completion_path),
            "saved_input_sha256": {p.name: sha256(p) for p in input_files},
        },
        "analysis_source_sha256": sha256(Path(__file__)),
        "paired_input_validation": "all methods share the same frozen and common snapshot hash per scenario",
    }
    (out / "analysis_manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    (out / "README.md").write_text(
        "# Corrected E4 paired analysis\n\n"
        "Derived only from the adjacent completed E4 run. Tests use scenarios as paired units. "
        "Distance and driving-time comparisons are restricted to exactly identical served task sets. "
        "Bootstrap intervals describe the fixed benchmark scenarios, not a population.\n",
        encoding="utf-8",
    )
    return out


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--run", type=Path, required=True, help="Completed corrected E4 run directory")
    args = parser.parse_args()
    path = args.run if args.run.is_absolute() else ROOT / args.run
    print(analyze(path))


if __name__ == "__main__":
    main()
