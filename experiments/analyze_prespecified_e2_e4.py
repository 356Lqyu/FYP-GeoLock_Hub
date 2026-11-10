"""Read-only, prespecified paired analysis of preserved E2/E4 results.

This script reads only saved CSV/JSON artifacts. It does not connect to a
database, rerun benchmarks, or modify source result directories. Write outputs
to a new directory with --output; existing directories are rejected.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import statistics
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
E2_R3 = ROOT / "experiments/e2_atomic_claiming/results/e2-final-20261109-r3"
E2_CORRECTED = ROOT / "experiments/e2_atomic_claiming/results/e2-three-method-20261109-164724"
E2_HISTORY = ROOT / "experiments/e2_atomic_claiming/results/e2-final-20261109-r3"
BOOTSTRAPS = 10_000
SEED = 20260915


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open("r", encoding="utf-8-sig", newline="") as f:
        return list(csv.DictReader(f))


def write_csv(path: Path, rows: list[dict], fields: list[str] | None = None) -> None:
    if not rows:
        path.write_text("", encoding="utf-8")
        return
    names = fields or list(dict.fromkeys(k for row in rows for k in row))
    with path.open("w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=names, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def wilson(successes: int, n: int, z: float = 1.959963984540054) -> tuple[float, float]:
    if n == 0:
        return math.nan, math.nan
    p = successes / n
    d = 1 + z * z / n
    center = (p + z * z / (2 * n)) / d
    half = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    # Floating-point roundoff can put boundary cases just outside [0, 1].
    low = 0.0 if successes == 0 else max(0.0, center - half)
    high = 1.0 if successes == n else min(1.0, center + half)
    return low, high


def binomial_two_sided(k: int, n: int) -> float:
    """Exact two-sided sign/McNemar p-value under Binomial(n, 1/2)."""
    if n == 0:
        return 1.0
    tail = sum(math.comb(n, i) for i in range(min(k, n - k) + 1)) / (2**n)
    return min(1.0, 2.0 * tail)


def mcnemar(a: list[bool], b: list[bool]) -> dict:
    if len(a) != len(b):
        raise ValueError("Paired binary vectors differ in length")
    a_only = sum(x and not y for x, y in zip(a, b))
    b_only = sum(y and not x for x, y in zip(a, b))
    return {
        "n_pairs": len(a),
        "a_only": a_only,
        "b_only": b_only,
        "paired_rate_difference_b_minus_a": (b_only - a_only) / len(a) if a else math.nan,
        "p_exact_two_sided": binomial_two_sided(min(a_only, b_only), a_only + b_only),
    }


def pratt_ranks(values: list[float]) -> list[float]:
    ordered = sorted((abs(v), i) for i, v in enumerate(values))
    ranks = [0.0] * len(values)
    start = 0
    while start < len(ordered):
        end = start + 1
        while end < len(ordered) and ordered[end][0] == ordered[start][0]:
            end += 1
        rank = ((start + 1) + end) / 2.0
        for _, idx in ordered[start:end]:
            ranks[idx] = rank
        start = end
    return ranks


def wilcoxon_pratt_exact(values: list[float]) -> dict:
    """Exact two-sided Wilcoxon signed-rank using Pratt zero ranking.

    Midranks (including zero differences) are doubled to integer weights, so
    the subset-sum distribution remains exact in the presence of ties.
    """
    if not values:
        return {"n_pairs": 0, "nonzero_pairs": 0, "w_plus": 0.0, "p_exact_two_sided": 1.0}
    ranks = pratt_ranks(values)
    weights = [int(round(rank * 2)) for value, rank in zip(values, ranks) if value != 0]
    w_plus = sum(int(round(rank * 2)) for value, rank in zip(values, ranks) if value > 0)
    dist = [1]
    for weight in weights:
        dist.extend([0] * weight)
        for i in range(len(dist) - 1, weight - 1, -1):
            dist[i] += dist[i - weight]
    total = 2 ** len(weights)
    lower = sum(dist[:w_plus + 1]) / total
    upper = sum(dist[w_plus:]) / total
    p = min(1.0, 2.0 * min(lower, upper))
    return {"n_pairs": len(values), "nonzero_pairs": len(weights), "w_plus": w_plus / 2, "p_exact_two_sided": p}


def holm(pvalues: list[float]) -> list[float]:
    order = sorted(range(len(pvalues)), key=lambda i: pvalues[i])
    adjusted = [1.0] * len(pvalues)
    running = 0.0
    for rank, idx in enumerate(order):
        running = max(running, min(1.0, (len(order) - rank) * pvalues[idx]))
        adjusted[idx] = running
    return adjusted


def hodges_lehmann(values: list[float]) -> float:
    arr = np.asarray(values, dtype=float)
    i, j = np.triu_indices(len(arr))
    return float(np.median((arr[i] + arr[j]) / 2.0))


def bootstrap_hl(values: list[float], seed: int) -> tuple[float, float]:
    arr = np.asarray(values, dtype=float)
    n = len(arr)
    if n == 0:
        return math.nan, math.nan
    i, j = np.triu_indices(n)
    rng = np.random.default_rng(seed)
    estimates = np.empty(BOOTSTRAPS, dtype=float)
    # Batching bounds temporary allocation while preserving the frozen seed.
    for base in range(0, BOOTSTRAPS, 128):
        size = min(128, BOOTSTRAPS - base)
        samples = arr[rng.integers(0, n, size=(size, n))]
        walsh = (samples[:, i] + samples[:, j]) / 2.0
        estimates[base:base + size] = np.median(walsh, axis=1)
    lo, hi = np.quantile(estimates, [0.025, 0.975], method="linear")
    return float(lo), float(hi)


def paired_continuous(a: list[float], b: list[float], seed: int) -> dict:
    if len(a) != len(b):
        raise ValueError("Paired continuous vectors differ in length")
    diffs = [y - x for x, y in zip(a, b)]
    test = wilcoxon_pratt_exact(diffs)
    lo, hi = bootstrap_hl(diffs, seed)
    return {
        "n_pairs": len(diffs),
        "mean_difference_b_minus_a": statistics.fmean(diffs) if diffs else math.nan,
        "median_difference_b_minus_a": statistics.median(diffs) if diffs else math.nan,
        "hodges_lehmann_paired_location": hodges_lehmann(diffs) if diffs else math.nan,
        "hl_bootstrap_95_ci_low": lo,
        "hl_bootstrap_95_ci_high": hi,
        **test,
    }


def bool_value(value: str) -> bool:
    return value.strip().upper() in {"YES", "TRUE", "1"}


def float_value(value: str) -> float:
    return float(value)


def add_proportion(rows: list[dict], domain: str, method: str, outcome: str, successes: int, n: int, note: str = "") -> None:
    lo, hi = wilson(successes, n)
    rows.append({"domain": domain, "method": method, "outcome": outcome, "successes": successes, "n_independent_units": n,
                 "proportion": successes / n if n else math.nan, "wilson_95_ci_low": lo, "wilson_95_ci_high": hi, "note": note})


def run(output: Path, e4_final: Path) -> None:
    if output.exists():
        raise FileExistsError(f"Refusing to overwrite analysis output: {output}")
    files = {
        "e2_non_atomic": E2_R3 / "non_atomic_claim/results_per_scenario.csv",
        "e2_no_recovery": E2_R3 / "protected_claim_without_lease_recovery/results_per_scenario.csv",
        "e2_no_recovery_leases": E2_R3 / "protected_claim_without_lease_recovery/lease_results_per_scenario.csv",
        "e2_corrected": E2_CORRECTED / "proposed_results_per_scenario.csv",
        "e2_corrected_requests": E2_CORRECTED / "proposed_requests.json",
        "e4_common": e4_final / "results_per_scenario.csv",
        "e4_original_nn": e4_final / "original_nearest_next/results_per_scenario.csv",
        "e4_original_fcfs": e4_final / "original_fcfs/results_per_scenario.csv",
    }
    missing = [str(p) for p in files.values() if not p.is_file()]
    if missing:
        raise FileNotFoundError("Missing preserved inputs: " + ", ".join(missing))
    before = {name: sha256(path) for name, path in files.items()}
    e2 = {name: read_csv(path) for name, path in files.items() if name not in {"e2_corrected_requests"}}
    # The request file is read for completeness and hashed, not used to treat
    # concurrent requests as independent statistical units.
    json.loads(files["e2_corrected_requests"].read_text(encoding="utf-8"))

    methods = {
        "non_atomic": {r["scenario_id"]: r for r in e2["e2_non_atomic"]},
        "atomic_no_recovery": {r["scenario_id"]: r for r in e2["e2_no_recovery"]},
        "atomic_recovery_corrected": {r["scenario_id"]: r for r in e2["e2_corrected"] if r["case"] == ""},
    }
    ids = set(methods["non_atomic"])
    if any(set(rows) != ids for rows in methods.values()):
        raise ValueError("E2 contention scenario IDs differ across the three methods")
    if len(ids) != 150:
        raise ValueError(f"Expected 150 paired E2 contention scenarios; found {len(ids)}")

    proportions: list[dict] = []
    e2_tests: list[dict] = []
    latency_rows: list[dict] = []
    method_labels = list(methods)
    pair_seed = 0
    for method, rows in methods.items():
        ordered = [rows[sid] for sid in sorted(ids)]
        duplicate = [bool_value(r["more_than_one_owner"]) for r in ordered]
        one_owner = [int(r["told_success"]) == 1 and not bool_value(r["more_than_one_owner"]) for r in ordered]
        add_proportion(proportions, "E2", method, "duplicate_owner_trial", sum(duplicate), len(duplicate), "Independent unit is one scenario, not each request.")
        add_proportion(proportions, "E2", method, "exactly_one_success_trial", sum(one_owner), len(one_owner), "Independent unit is one scenario.")
        for level in (2, 5, 10):
            group = [r for r in ordered if int(r["ngos_competing"]) == level]
            lat = [float_value(r["median_response_ms"]) for r in group]
            latency_rows.append({"method": method, "concurrent_requests": level, "scenarios": len(group),
                                 "median_scenario_median_ms": statistics.median(lat),
                                 "p95_scenario_median_ms": float(np.quantile(lat, .95)),
                                 "p99_scenario_median_ms": float(np.quantile(lat, .99)),
                                 "warning": "Descriptive scenario medians; not request-level independent observations."})

    e2_families: dict[str, list[int]] = {"duplicate_owner_trial": [], "exactly_one_success_trial": [], "latency_median_ms": []}
    for level in (2, 5, 10):
        scenario_ids = sorted(sid for sid in ids if int(methods["non_atomic"][sid]["ngos_competing"]) == level)
        if len(scenario_ids) != 50:
            raise ValueError(f"Expected 50 E2 scenarios at request concurrency {level}; found {len(scenario_ids)}")
        for i, a_name in enumerate(method_labels):
            for b_name in method_labels[i + 1:]:
                a_rows = [methods[a_name][sid] for sid in scenario_ids]
                b_rows = [methods[b_name][sid] for sid in scenario_ids]
                for metric, fn in (
                    ("duplicate_owner_trial", lambda r: bool_value(r["more_than_one_owner"])),
                    ("exactly_one_success_trial", lambda r: int(r["told_success"]) == 1 and not bool_value(r["more_than_one_owner"])),
                ):
                    result = mcnemar([fn(r) for r in a_rows], [fn(r) for r in b_rows])
                    row = {"family": metric, "request_concurrency": level, "method_a": a_name, "method_b": b_name, **result}
                    e2_families[metric].append(len(e2_tests)); e2_tests.append(row)
                pair_seed += 1
                a_lat = [float_value(r["median_response_ms"]) for r in a_rows]
                b_lat = [float_value(r["median_response_ms"]) for r in b_rows]
                result = paired_continuous(a_lat, b_lat, SEED + pair_seed)
                e2_families["latency_median_ms"].append(len(e2_tests))
                e2_tests.append({"family": "latency_median_ms", "request_concurrency": level, "method_a": a_name,
                                 "method_b": b_name, **result,
                                 "interpretation": "Descriptive paired timing only; function/schema differences confound causal attribution."})
    for family, positions in e2_families.items():
        adjusted = holm([e2_tests[i]["p_exact_two_sided"] for i in positions])
        for idx, p_adj in zip(positions, adjusted):
            e2_tests[idx]["p_holm_within_family"] = p_adj

    # Recovery / active-lease independent units are the saved 100/25 scenarios.
    no_recovery_lease = {r["scenario_id"]: r for r in e2["e2_no_recovery_leases"]}
    corrected_lease = {r["scenario_id"]: r for r in e2["e2_corrected"] if r["case"]}
    lease_rows: list[dict] = []
    for case, required_n in (("lease expired", 100), ("lease still running", 25)):
        before_rows = {sid: r for sid, r in no_recovery_lease.items() if r["case"] == case}
        after_rows = {sid: r for sid, r in corrected_lease.items() if r["case"] == case}
        if set(before_rows) != set(after_rows) or len(before_rows) != required_n:
            raise ValueError(f"E2 {case} scenarios are not paired/complete")
        if case == "lease expired":
            outcome_a = [r["second_ngo_got_listing"] == "YES" for r in before_rows.values()]
            outcome_b = [int(after_rows[sid]["recovery_affected_rows"] or 0) > 0 and after_rows[sid]["second_ngo_got_listing"] == "YES" for sid in before_rows]
            label = "expired_lease_recovered_and_reassigned"
        else:
            outcome_a = [r["first_claim_still_active"] == "YES" and r["second_ngo_got_listing"] == "NO" for r in before_rows.values()]
            outcome_b = [after_rows[sid]["first_claim_still_active"] == "YES" and after_rows[sid]["second_ngo_got_listing"] == "NO" for sid in before_rows]
            label = "active_lease_protected"
        a_ok, b_ok = sum(outcome_a), sum(outcome_b)
        add_proportion(proportions, "E2 lease", "atomic_no_recovery", label, a_ok, len(outcome_a), "Scenario-level independent units.")
        add_proportion(proportions, "E2 lease", "atomic_recovery_corrected", label, b_ok, len(outcome_b), "Scenario-level independent units.")
        test = mcnemar(outcome_a, outcome_b)
        lease_rows.append({"case": case, "metric": label, "n_scenarios": required_n, "no_recovery_successes": a_ok,
                           "corrected_successes": b_ok, **test, "p_holm_within_lease_family": None})
    lease_adj = holm([r["p_exact_two_sided"] for r in lease_rows])
    for row, p_adj in zip(lease_rows, lease_adj):
        row["p_holm_within_lease_family"] = p_adj

    # Corrected E4 contains 100 identical 500-task admitted snapshots for all methods.
    e4_rows = read_csv(files["e4_common"])
    e4_by_method = {m: {r["scenario_id"]: r for r in e4_rows if r["method"] == m} for m in ("nearest_next", "fcfs", "proposed")}
    e4_ids = set(e4_by_method["proposed"])
    if len(e4_ids) != 100 or any(set(v) != e4_ids for v in e4_by_method.values()):
        raise ValueError("E4 common-admission lanes must have identical 100 scenario IDs")
    e4_props: list[dict] = []
    e4_tests: list[dict] = []
    for method, rows in e4_by_method.items():
        ordered = [rows[sid] for sid in sorted(e4_ids)]
        feasible = [bool_value(r["feasibility_pass"]) and bool_value(r["validation_valid"]) for r in ordered]
        full_coverage = [int(r["served_tasks"]) == int(r["valid_tasks"]) for r in ordered]
        add_proportion(e4_props, "E4 common admission", method, "independent_validation_and_feasibility_pass", sum(feasible), len(feasible))
        add_proportion(e4_props, "E4 common admission", method, "all_admitted_tasks_served", sum(full_coverage), len(full_coverage))

    e4_secondary: list[int] = []
    for baseline in ("nearest_next", "fcfs"):
        a = e4_by_method[baseline]
        b = e4_by_method["proposed"]
        for metric, fn in (
            ("all_admitted_tasks_served", lambda r: int(r["served_tasks"]) == int(r["valid_tasks"])),
            ("independent_feasibility_pass", lambda r: bool_value(r["feasibility_pass"]) and bool_value(r["validation_valid"])),
        ):
            stat = mcnemar([fn(a[s]) for s in sorted(e4_ids)], [fn(b[s]) for s in sorted(e4_ids)])
            e4_tests.append({"family": "paired_binary", "method_a": baseline, "method_b": "proposed", "metric": metric, **stat,
                             "multiplicity": "primary binary outcome reported with exact paired test; no adjustment applied"})
        continuous = [
            ("served_tasks", lambda r: float(r["served_tasks"]), "primary coverage comparison"),
            ("coverage_percent", lambda r: float(r["coverage_percent"]), "primary coverage comparison"),
            ("method_pipeline_wall_ms", lambda r: float(r["method_pipeline_wall_ms"]), "secondary timing"),
            ("end_to_end_evaluation_ms", lambda r: float(r["end_to_end_evaluation_ms"]), "secondary timing"),
        ]
        for metric, fn, scope in continuous:
            av = [fn(a[s]) for s in sorted(e4_ids)]
            bv = [fn(b[s]) for s in sorted(e4_ids)]
            pair_seed += 1
            stat = paired_continuous(av, bv, SEED + 100 + pair_seed)
            row = {"family": "paired_continuous", "method_a": baseline, "method_b": "proposed", "metric": metric,
                   "analysis_scope": scope, **stat}
            if scope.startswith("secondary"):
                e4_secondary.append(len(e4_tests))
            e4_tests.append(row)
        # Distance/time comparisons only when both methods served precisely the same tasks.
        same = []
        for sid in sorted(e4_ids):
            ma = json.loads(a[sid]["metrics"])
            mb = json.loads(b[sid]["metrics"])
            if set(ma.get("served_pickup_tasks", [])) == set(mb.get("served_pickup_tasks", [])):
                same.append((a[sid], b[sid]))
        for metric, col in (("distance_km_identical_served_set", "total_distance_km"),
                            ("travel_duration_identical_served_set_min", "travel_duration_min")):
            av = [float(x[col]) for x, _ in same]
            bv = [float(y[col]) for _, y in same]
            pair_seed += 1
            stat = paired_continuous(av, bv, SEED + 100 + pair_seed)
            row = {"family": "paired_continuous", "method_a": baseline, "method_b": "proposed", "metric": metric,
                   "analysis_scope": "identical served-task sets only", **stat}
            e4_secondary.append(len(e4_tests)); e4_tests.append(row)
    e4_adj = holm([e4_tests[i]["p_exact_two_sided"] for i in e4_secondary])
    for idx, p_adj in zip(e4_secondary, e4_adj):
        e4_tests[idx]["p_holm_within_E4_secondary_family"] = p_adj

    original_lane = []
    for method, key in (("nearest_next", "e4_original_nn"), ("fcfs", "e4_original_fcfs")):
        rows = e2.get(key, [])
        original_lane.append({"method": method, "scenario_records": len(rows),
                              "valid_tasks_total": sum(int(r["tasks_valid"]) for r in rows),
                              "served_tasks_total": sum(int(r["tasks_collected"]) for r in rows),
                              "distance_km_total": sum(float_value(r["total_distance_km"]) for r in rows),
                              "note": "Original 500-task lane; no CP-SAT plan exists in this lane."})

    output.mkdir(parents=True, exist_ok=False)
    write_csv(output / "e2_scenario_proportions.csv", proportions)
    write_csv(output / "e2_paired_tests.csv", e2_tests)
    write_csv(output / "e2_latency_by_concurrency.csv", latency_rows)
    write_csv(output / "e2_lease_paired_tests.csv", lease_rows)
    write_csv(output / "e4_scenario_proportions.csv", e4_props)
    write_csv(output / "e4_paired_tests.csv", e4_tests)
    write_csv(output / "e4_original_500_task_lane.csv", original_lane)
    after = {name: sha256(path) for name, path in files.items()}
    if before != after:
        raise RuntimeError("An input artifact changed during analysis")
    manifest = {
        "status": "ANALYSIS_COMPLETE",
        "analysis_only": True,
        "remote_access": False,
        "database_connections": 0,
        "benchmarks_rerun": False,
        "random_seed": SEED,
        "bootstrap_replicates": BOOTSTRAPS,
        "methodology": {
            "independent_unit": "scenario/trial; requests within contention scenarios are not independent units",
            "paired_binary": "exact two-sided McNemar test",
            "paired_continuous": "exact Wilcoxon signed-rank using Pratt zero ranking and midranks",
            "effect_estimate": "Hodges-Lehmann paired location estimate with paired bootstrap percentile CI",
            "proportions": "Wilson score 95% confidence intervals",
            "multiplicity": "Holm within E2 outcome families, lease family, and E4 secondary-confirmatory family",
            "distance": "paired only when served task sets match exactly",
            "causal_limit": "E2 latency comparisons are descriptive because methods use different function/schema implementations",
            "population_limit": "bootstrap intervals describe this frozen scenario set, not a sampled population",
        },
        "python": sys.version,
        "numpy": np.__version__,
        "source_script_sha256": sha256(Path(__file__)),
        "input_artifacts": {name: {"path": str(path.relative_to(ROOT)), "sha256": before[name]} for name, path in files.items()},
        "historical_original_proposed": "e2-final-20261109-r3 remains development-history evidence only; not a primary method in this analysis",
    }
    (output / "analysis_manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    (output / "README.md").write_text(
        "# Prespecified E2/E4 derived analysis\n\n"
        "Derived from existing saved scenario records only. Original result directories were not modified.\n\n"
        "Run from the repository root with:\n\n"
        f"```powershell\n.venv-stage8/Scripts/python.exe experiments/analyze_prespecified_e2_e4.py --e4 PATH_TO_COMPLETED_E4_RUN --output {output.relative_to(ROOT).as_posix()}\n```\n\n"
        "Exact paired tests use scenarios as units. Distance is tested only for identical served-task sets. "
        "E2 timing differences are descriptive due to schema/function differences. The bootstrap describes the fixed scenarios, not a population.\n",
        encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--e4", type=Path, required=True, help="Completed E4 result directory; the final rerun is pending")
    parser.add_argument("--output", required=True, help="New output directory; must not already exist")
    args = parser.parse_args()
    path = Path(args.output)
    if not path.is_absolute():
        path = ROOT / path
    e4_final = args.e4 if args.e4.is_absolute() else ROOT / args.e4
    run(path, e4_final)


if __name__ == "__main__":
    main()
