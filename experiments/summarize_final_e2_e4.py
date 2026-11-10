"""Validate and summarize preserved final E2/E4 evidence without rerunning it."""
import argparse
import csv
import hashlib
import json
import math
import statistics
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULTS = {
    "original": ROOT / "experiments/e2_atomic_claiming/results/e2-final-20261109-r3",
    "corrected": ROOT / "experiments/e2_atomic_claiming/results/e2-lockfix-final-20261109-061706",
    "historical": ROOT / "experiments/e2_atomic_claiming/results/e2-final-20261109-r3",
    # No current final E4 result is retained; callers must supply a completed rerun.
    "e4": None,
}
CORRECTED_PATCH_SHA256 = "a0a35b5dfeab92351c79a240af79e46ad638f57b57f204a6cb54e9eeed3a0433"
CORRECTED_CLAIM_MD5 = "0e1954dc17a5d30b81c57a161d99faac"
CORRECTED_LOCK_HELPER_MD5 = "e97a3fd80673a827465f3eaa79b65903"
LEVELS = (2, 5, 10)
FINAL_METHODS = (
    "non_atomic_baseline",
    "atomic_without_lease_recovery",
    "atomic_with_lease_recovery_corrected",
)
BASELINE_FILES = {
    "non_atomic_baseline": "non_atomic_claim/results_per_scenario.csv",
    "atomic_without_lease_recovery": "protected_claim_without_lease_recovery/results_per_scenario.csv",
}
SOURCE_NAMES = {
    "non_atomic_baseline": "non_atomic_claim",
    "atomic_without_lease_recovery": "protected_claim_without_lease_recovery",
}
E4_METHODS = ("nearest_next", "fcfs", "proposed")


def read_csv(path):
    with Path(path).open(encoding="utf-8-sig", newline="") as stream:
        return list(csv.DictReader(stream))


def read_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def percentile(values, p):
    if not values:
        return None
    ordered = sorted(float(v) for v in values)
    rank = (len(ordered) - 1) * p
    low, high = math.floor(rank), math.ceil(rank)
    return ordered[low] + (ordered[high] - ordered[low]) * (rank - low)


def scenario_id_set(rows, label):
    ids = [r["scenario_id"] for r in rows]
    if len(ids) != len(set(ids)):
        raise ValueError(f"{label} contains duplicate scenario IDs")
    return set(ids)


def validate_three_method_rows(rows):
    expected = {(method, level) for method in FINAL_METHODS for level in LEVELS}
    actual = [(r.get("method"), int(r["concurrent_requests"])) for r in rows]
    if len(actual) != len(set(actual)):
        raise ValueError("Primary E2 comparison contains duplicate method/worker rows")
    if set(actual) != expected:
        raise ValueError(f"Primary E2 method/worker rows differ: missing={sorted(expected-set(actual))}, extra={sorted(set(actual)-expected)}")


def identity_distribution(rows):
    counts = Counter(int(r["different_ngos"]) for r in rows)
    return ";".join(f"{n} distinct NGOs:{counts[n]} scenarios" for n in sorted(counts))


def aggregate_method(method, result_rows, request_rows, comparison_rows, level):
    group = [r for r in result_rows if r.get("case", "") == "" and int(r["ngos_competing"]) == level]
    if len(group) != 50:
        raise ValueError(f"{method} requires 50 scenarios at {level} concurrent requests; found {len(group)}")
    scenario_id_set(group, f"{method}/{level}")
    ids = {r["scenario_id"] for r in group}
    requests = [r for r in request_rows if r["scenario_id"] in ids]
    expected_requests = 50 * level
    if len(requests) != expected_requests or len({r.get("request_id", r.get("request_uuid")) for r in requests}) != expected_requests:
        raise ValueError(f"{method}/{level} has {len(requests)} request rows; expected {expected_requests} unique requests")
    successful = sum(int(r["told_success"]) for r in group)
    conflicts = sum(int(r["told_already_claimed"]) for r in group)
    ineligible = sum(int(r["told_not_eligible"]) for r in group)
    errors = sum(int(r["failed_with_error"]) for r in group)
    duplicate_trials = sum(r["more_than_one_owner"] == "YES" for r in group)
    if method == "atomic_with_lease_recovery_corrected":
        outcomes = Counter(r.get("outcome") for r in requests)
        if outcomes != Counter({"SUCCESS": 50, "CONFLICT": expected_requests - 50}):
            raise ValueError(f"Corrected proposed request outcomes mismatch for {level}: {dict(outcomes)}")
        if any(r.get("reason_code") != "ALREADY_CLAIMED" for r in requests if r.get("outcome") == "CONFLICT"):
            raise ValueError(f"Corrected proposed conflicts are not all ALREADY_CLAIMED at {level}")
        if errors != 0:
            raise ValueError(f"Corrected proposed has surfaced errors at {level}")
        deadlocks = "N/A (no SQLSTATE failure audit in this run)"
        latencies = [float(r["latency_ms"]) for r in requests if r.get("latency_ms") not in (None, "")]
        median = round(statistics.median(latencies), 3) if latencies else "N/A"
        p95 = round(percentile(latencies, .95), 3) if latencies else "N/A"
        p99 = round(percentile(latencies, .99), 3) if latencies else "N/A"
    else:
        request_outcomes = Counter(r.get("answer") for r in requests)
        expected_outcomes = Counter({"SUCCESS": successful})
        if conflicts:
            expected_outcomes["CONFLICT"] = conflicts
        if ineligible:
            expected_outcomes["NOT_ELIGIBLE"] = ineligible
        if errors:
            expected_outcomes["ERROR"] = errors
        if request_outcomes != expected_outcomes:
            raise ValueError(f"{method}/{level} request records disagree with scenario totals: {dict(request_outcomes)} != {dict(expected_outcomes)}")
        match = [r for r in comparison_rows if r["method"] == SOURCE_NAMES[method] and int(r["workers"]) == level]
        if comparison_rows:
            if len(match) != 1:
                raise ValueError(f"Expected one saved comparison row for {method}/{level}; found {len(match)}")
            saved = match[0]
            for key, actual in (("successes", successful), ("conflicts", conflicts), ("errors", errors), ("duplicate_trials", duplicate_trials)):
                if int(saved[key]) != actual:
                    raise ValueError(f"Saved comparison mismatch for {method}/{level} field {key}")
            median, p95, p99 = saved.get("median_ms", "N/A"), saved.get("p95_ms", "N/A"), "N/A"
        else:
            latencies = [float(r["response_ms"]) for r in requests if r.get("response_ms") not in (None, "")]
            median = round(statistics.median(latencies), 3) if latencies else "N/A"
            p95 = round(percentile(latencies, .95), 3) if latencies else "N/A"
            p99 = round(percentile(latencies, .99), 3) if latencies else "N/A"
        deadlocks = "N/A (no per-method SQLSTATE audit)"
    return {
        "method": method, "concurrent_requests": level, "scenarios": len(group),
        "claim_requests": len(requests), "successful_requests": successful,
        "already_claimed_conflicts": conflicts, "ineligible_responses": ineligible,
        "surfaced_request_errors": errors, "sqlstate_40P01": deadlocks,
        "duplicate_claim_trials": duplicate_trials,
        "identity_distribution": identity_distribution(group),
        "median_latency_ms": median, "p95_latency_ms": p95, "p99_latency_ms": p99,
    }


def corrected_contention_rows(result_rows, requests):
    rows = []
    for level in LEVELS:
        rows.append(aggregate_method("atomic_with_lease_recovery_corrected", result_rows, requests, [], level))
    return rows


def build_development_history(original_results, original_requests, original_audit, corrected_results, corrected_requests):
    original_claim_results = [r for r in original_results if r.get("case", "") == "" and r["scenario_id"].startswith("SCN-CLAIM_COORDINATION-")]
    original_claim_requests = [r for r in original_requests if r["scenario_id"].startswith("SCN-CLAIM_COORDINATION-")]
    if len(original_claim_results) != 150 or len(original_claim_requests) != 850:
        raise ValueError("Original proposed historical evidence is missing contention scenarios or requests")
    errored = [r for r in original_claim_requests if r.get("outcome") == "ERROR"]
    error_ids = {r["request_uuid"] for r in errored}
    matched_audit = [r for r in original_audit if r.get("request_id") in error_ids]
    if len(errored) != 683 or len(matched_audit) != 683 or any(r.get("sqlstate") != "40P01" or str(r.get("rollback_confirmed", "")).lower() != "true" for r in matched_audit):
        raise ValueError("Original proposed deadlock audit does not verify 683 rollback-confirmed SQLSTATE 40P01 failures")
    audit_by_request = {r["request_id"]: r for r in matched_audit}
    if len(audit_by_request) != len(matched_audit) or set(audit_by_request) != error_ids or len(original_audit) != len(matched_audit):
        raise ValueError("Original proposed failure audit has duplicate, missing, or unrelated request IDs")
    history = []
    for version, result_rows, request_rows, audit in (
        ("original_proposed_historical", original_results, original_requests, original_audit),
        ("corrected_proposed_final", corrected_results, corrected_requests, []),
    ):
        for level in LEVELS:
            group = [r for r in result_rows if r.get("case", "") == "" and r["scenario_id"].startswith("SCN-CLAIM_COORDINATION-") and int(r["ngos_competing"]) == level]
            ids = {r["scenario_id"] for r in group}
            req = [r for r in request_rows if r["scenario_id"] in ids]
            failed_requests = [r for r in req if r.get("outcome") == "ERROR"]
            failed_ids = {r.get("request_uuid") for r in failed_requests}
            matched = [r for r in audit if r.get("request_id") in failed_ids]
            states = Counter(r.get("sqlstate") for r in matched)
            if version == "original_proposed_historical":
                deadlocks = states.get("40P01", 0)
                if len(group) != 50 or len(req) != 50 * level or deadlocks != len(failed_requests):
                    raise ValueError(f"Original proposed per-level audit mismatch at {level}")
                sqlstate = deadlocks
            else:
                if len(group) != 50 or len(req) != 50 * level or failed_requests:
                    raise ValueError(f"Corrected proposed per-level request evidence mismatch at {level}")
                sqlstate = "N/A (no request errors to audit)"
            history.append({
                "implementation_version": version, "concurrent_requests": level,
                "scenarios": len(group), "claim_requests": len(req),
                "successful_requests": sum(int(r["told_success"]) for r in group),
                "controlled_conflicts": sum(int(r["told_already_claimed"]) for r in group),
                "surfaced_request_errors": len(failed_requests), "sqlstate_40P01": sqlstate,
                "duplicate_claim_trials": sum(r["more_than_one_owner"] == "YES" for r in group),
            })
    return history


def validate_e4(e4):
    results = read_csv(e4 / "results_per_scenario.csv")
    common = read_csv(e4 / "summary_statistics.csv")
    original = read_csv(e4 / "original_baseline_summary.csv")
    verification = read_json(e4 / "verification.json")
    if len(results) != 300:
        raise ValueError(f"E4 must contain 300 common-admission scenario/method rows; found {len(results)}")
    pairs = [(r["scenario_id"], r["method"]) for r in results]
    if len(pairs) != len(set(pairs)) or {m for _, m in pairs} != set(E4_METHODS):
        raise ValueError("E4 common-admission results have missing/duplicated methods or scenario rows")
    by_scenario = {}
    for row in results:
        by_scenario.setdefault(row["scenario_id"], []).append(row)
    if len(by_scenario) != 100:
        raise ValueError("E4 common-admission run must have 100 distinct scenarios")
    for sid, group in by_scenario.items():
        if len(group) != 3 or len({r["valid_tasks"] for r in group}) != 1 or len({r["frozen_sha256"] for r in group}) != 1:
            raise ValueError(f"E4 methods did not share common inputs/admission in {sid}")
    if len(common) != 3 or {r["method"] for r in common} != set(E4_METHODS) or any(int(r["scenarios"]) != 100 or int(r["valid_tasks"]) != 500 for r in common):
        raise ValueError("Corrected E4 common-input summary must report 100 scenarios and 500 tasks for all three methods")
    if any(int(r["capacity_violations"]) or int(r["window_violations"]) or int(r["duration_violations"]) for r in common):
        raise ValueError("E4 common-admission summary contains constraint violations")
    if len(original) != 2 or {r["method"] for r in original} != {"nearest_next", "fcfs"} or any(int(r["scenarios"]) != 100 or int(r["valid_tasks"]) != 500 for r in original):
        raise ValueError("E4 original baseline lane must retain 100 scenarios and 500 tasks for Nearest-Next/FCFS")
    if verification.get("saved_routes_independently_revalidated") != 300:
        raise ValueError("E4 saved route validation count is not 300")
    if verification.get("additional_admission_exclusions") != 0:
        raise ValueError("Corrected E4 run must have no additional admission exclusions")
    return results, common, original, verification


def write_csv(path, records):
    records = list(records)
    fields = list(dict.fromkeys(k for row in records for k in row))
    with Path(path).open("w", encoding="utf-8", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=fields, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(records)


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def _validated_corrected_run(path):
    """Validate one corrected run's invariants without assuming a particular winner."""
    path = Path(path)
    results = read_csv(path / "proposed_results_per_scenario.csv")
    requests = read_json(path / "proposed_requests.json")
    committed = read_json(path / "proposed_committed_states.json")
    completion = read_json(path / "completion.json")
    manifest = read_json(path / "manifest.json")
    validate_corrected_manifest(manifest)
    if completion.get("executed") is not True or completion.get("completed_proposed") != 275 or completion.get("failures") != 0 or completion.get("remote_connections") != 0:
        raise ValueError(f"Corrected E2 run {path.name} is incomplete, failed, or not local-only")

    integrity = manifest.get("integrity", {})
    if integrity.get("version") != "GEOLOCK-BM-v3.3":
        raise ValueError(f"Corrected E2 run {path.name} does not identify GEOLOCK-BM-v3.3")
    for relative, expected in integrity.get("verified_sha256", {}).items():
        source = ROOT.joinpath(*relative.replace("\\", "/").split("/"))
        if not source.is_file() or sha256(source) != expected:
            raise ValueError(f"Corrected E2 frozen/source hash mismatch in {path.name}: {relative}")

    scenarios = read_csv(ROOT / "experiments/repro_inputs/v33/scenarios.csv")
    expected_types = {
        row["scenario_id"]: row["scenario_type"] for row in scenarios
        if row["scenario_type"] in {"CLAIM_COORDINATION", "LEASE_RECOVERY", "LEASE_ACTIVE_VERIFICATION"}
    }
    expected_ids = set(expected_types)
    result_by_id = {row["scenario_id"]: row for row in results}
    state_by_id = {row["scenario_id"]: row for row in committed}
    if len(result_by_id) != len(results) or len(state_by_id) != len(committed):
        raise ValueError(f"Corrected E2 run {path.name} contains duplicate scenario/ownership rows")
    if set(result_by_id) != expected_ids or set(state_by_id) != expected_ids or len(expected_ids) != 275:
        raise ValueError(f"Corrected E2 run {path.name} scenario IDs do not match the frozen 275-scenario E2 set")
    if len(requests) != 975:
        raise ValueError(f"Corrected E2 run {path.name} must contain 975 request records")

    request_by_key = {}
    request_ids = set()
    for request in requests:
        sid = request["scenario_id"]
        key = (sid, int(request["request_no"]))
        rid = request.get("request_uuid")
        if key in request_by_key or not rid or rid in request_ids:
            raise ValueError(f"Corrected E2 run {path.name} has duplicate/missing request identity at {key}")
        request_by_key[key] = request
        request_ids.add(rid)
        outcome = request.get("outcome")
        reason = request.get("reason_code") or ""
        error = request.get("error") or ""
        sqlstate = request.get("sqlstate") or request.get("error_sqlstate") or ""
        try:
            retries = int(request.get("retries", 0))
        except (TypeError, ValueError) as exc:
            raise ValueError(f"Corrected E2 run {path.name} has invalid retry count at {key}") from exc
        if retries != 0:
            raise ValueError(f"Corrected E2 run {path.name} has unexpected retry count {retries} at {key}")
        if error or sqlstate or outcome not in {"SUCCESS", "CONFLICT"}:
            raise ValueError(f"Corrected E2 run {path.name} has an unexpected request error/outcome at {key}: {outcome}/{sqlstate}")
        if (outcome == "SUCCESS" and reason) or (outcome == "CONFLICT" and reason != "ALREADY_CLAIMED"):
            raise ValueError(f"Corrected E2 run {path.name} has an unexpected reason code at {key}: {reason}")

    failures_path = path / "failures.json"
    if failures_path.is_file() and read_json(failures_path):
        raise ValueError(f"Corrected E2 run {path.name} contains failure records")
    audit_path = path / "database_errors.csv"
    audit_rows = read_csv(audit_path) if audit_path.is_file() else []
    if audit_rows:
        raise ValueError(f"Corrected E2 run {path.name} contains database error/SQLSTATE audit rows")

    result_groups = {"contention": [], "lease expired": [], "lease still running": []}
    for sid, result in result_by_id.items():
        state = state_by_id[sid]
        claims = state.get("claims", [])
        active = [claim for claim in claims if claim.get("claim_status") in {"ACTIVE", "RECONCILIATION_REQUIRED"}]
        if int(state.get("active_owner_count", -1)) != 1 or len({claim.get("ngo_uuid") for claim in active}) != 1 or len(active) != 1:
            raise ValueError(f"Corrected E2 run {path.name} violates committed ownership in {sid}")
        if state.get("listing_status") != "CLAIMED":
            raise ValueError(f"Corrected E2 run {path.name} has unexpected listing state in {sid}")
        case = result.get("case", "")
        expected_case = {"CLAIM_COORDINATION": "", "LEASE_RECOVERY": "lease expired", "LEASE_ACTIVE_VERIFICATION": "lease still running"}[expected_types[sid]]
        if case != expected_case:
            raise ValueError(f"Corrected E2 run {path.name} scenario type/case mismatch in {sid}")
        if not case:
            result_groups["contention"].append(result)
            workers = int(result["ngos_competing"])
            if workers not in LEVELS or result.get("more_than_one_owner") != "NO" or int(result.get("claims_stored", 0)) != 1:
                raise ValueError(f"Corrected E2 run {path.name} has invalid contention ownership in {sid}")
            expected_keys = {(sid, n) for n in range(1, workers + 1)}
            actual_keys = {key for key in request_by_key if key[0] == sid}
            if actual_keys != expected_keys:
                raise ValueError(f"Corrected E2 run {path.name} has missing/extra requests in {sid}")
            scenario_requests = [request_by_key[key] for key in sorted(expected_keys)]
            if any(int(request.get("workers", 0)) != workers for request in scenario_requests):
                raise ValueError(f"Corrected E2 run {path.name} request concurrency differs in {sid}")
            successes = sum(request["outcome"] == "SUCCESS" for request in scenario_requests)
            conflicts = sum(request["outcome"] == "CONFLICT" for request in scenario_requests)
            if (successes, conflicts) != (1, workers - 1):
                raise ValueError(f"Corrected E2 run {path.name} must have one success and {workers - 1} controlled conflicts in {sid}")
            if (int(result["told_success"]), int(result["told_already_claimed"]), int(result["told_not_eligible"]), int(result["failed_with_error"]), int(result["retries_after_deadlock"])) != (1, workers - 1, 0, 0, 0):
                raise ValueError(f"Corrected E2 run {path.name} scenario totals are invalid in {sid}")
        elif case in result_groups:
            result_groups[case].append(result)
            expected = ("SUCCESS", "", "YES", "NO", 1) if case == "lease expired" else ("CONFLICT", "ALREADY_CLAIMED", "NO", "YES", 0)
            observed = (result.get("second_ngo_answer"), result.get("second_ngo_reason", ""), result.get("second_ngo_got_listing"), result.get("first_claim_still_active"), int(result.get("recovery_affected_rows", -1)))
            if observed != expected:
                raise ValueError(f"Corrected E2 run {path.name} lease behavior is invalid in {sid}: {observed}")
            lease_request = request_by_key.get((sid, 1))
            wanted_outcome = "SUCCESS" if case == "lease expired" else "CONFLICT"
            wanted_reason = "" if case == "lease expired" else "ALREADY_CLAIMED"
            if not lease_request or lease_request.get("outcome") != wanted_outcome or (lease_request.get("reason_code") or "") != wanted_reason:
                raise ValueError(f"Corrected E2 run {path.name} lease request result is invalid in {sid}")
        else:
            raise ValueError(f"Corrected E2 run {path.name} has unexpected scenario case {case!r} in {sid}")
    if tuple(len(result_groups[case]) for case in ("contention", "lease expired", "lease still running")) != (150, 100, 25):
        raise ValueError(f"Corrected E2 run {path.name} has incorrect contention/lease scenario counts")
    if len(request_by_key) != 975 or set(key[0] for key in request_by_key) != expected_ids:
        raise ValueError(f"Corrected E2 run {path.name} request coverage does not match the frozen scenario set")

    return {"results": result_by_id, "requests": request_by_key, "states": state_by_id,
            "integrity": integrity, "manifest": manifest, "scenario_count": len(result_by_id),
            "request_count": len(request_by_key), "contention_count": len(result_groups["contention"]),
            "lease_expired_count": len(result_groups["lease expired"]),
            "lease_active_count": len(result_groups["lease still running"]),
            "sqlstate_error_count": len(audit_rows)}


def corrected_behavior_comparison(candidate, reference):
    """Validate both runs, then report nondeterministic winners instead of requiring them to match."""
    left = _validated_corrected_run(candidate)
    right = _validated_corrected_run(reference)
    if left["integrity"] != right["integrity"]:
        raise ValueError("Corrected E2 candidate and reference frozen benchmark hashes differ")
    if left["results"].keys() != right["results"].keys():
        raise ValueError("Corrected E2 candidate and reference scenario IDs differ")
    if left["requests"].keys() != right["requests"].keys():
        raise ValueError("Corrected E2 candidate and reference request slots differ")

    comparison_rows, request_differences = [], []
    winner_request_changes = winner_ngo_changes = 0
    outcome_fields = ("outcome", "reason_code", "error", "retries", "sqlstate", "error_sqlstate")
    input_fields = ("workers", "listing_id", "ngo_id", "ngo_uuid", "road_distance_km")
    for key in sorted(left["requests"]):
        a, b = left["requests"][key], right["requests"][key]
        if any(a.get(field, "") != b.get(field, "") for field in input_fields):
            raise ValueError(f"Corrected E2 candidate/reference frozen request input differs at {key}")
        if any(a.get(field, "") != b.get(field, "") for field in outcome_fields):
            request_differences.append({
                "scenario_id": key[0], "request_no": key[1],
                "candidate_request_uuid": a.get("request_uuid", ""), "reference_request_uuid": b.get("request_uuid", ""),
                "candidate_ngo_id": a.get("ngo_id", ""), "reference_ngo_id": b.get("ngo_id", ""),
                "candidate_outcome": a.get("outcome", ""), "reference_outcome": b.get("outcome", ""),
                "candidate_reason": a.get("reason_code", ""), "reference_reason": b.get("reason_code", ""),
                "candidate_retries": a.get("retries", 0), "reference_retries": b.get("retries", 0),
                "candidate_sqlstate": a.get("sqlstate", a.get("error_sqlstate", "")),
                "reference_sqlstate": b.get("sqlstate", b.get("error_sqlstate", "")),
                "classification": "request-level winner scheduling difference; both runs passed per-scenario invariants",
            })

    for sid in sorted(left["results"]):
        a, b = left["results"][sid], right["results"][sid]
        case = a.get("case", "")
        if case != b.get("case", ""):
            raise ValueError(f"Corrected E2 candidate/reference case differs in {sid}")
        state_a, state_b = left["states"][sid], right["states"][sid]
        if (int(state_a["active_owner_count"]), int(state_b["active_owner_count"])) != (1, 1):
            raise ValueError(f"Corrected E2 candidate/reference committed ownership is invalid in {sid}")
        ra = [r for (scenario, _), r in left["requests"].items() if scenario == sid and r.get("outcome") == "SUCCESS"]
        rb = [r for (scenario, _), r in right["requests"].items() if scenario == sid and r.get("outcome") == "SUCCESS"]
        winner_a = ra[0] if ra else None
        winner_b = rb[0] if rb else None
        ordinal_changed = bool(winner_a and winner_b and int(winner_a["request_no"]) != int(winner_b["request_no"]))
        ngo_changed = bool(winner_a and winner_b and winner_a.get("ngo_id") != winner_b.get("ngo_id"))
        winner_request_changes += ordinal_changed
        winner_ngo_changes += ngo_changed
        comparison_rows.append({
            "scenario_id": sid, "case": case, "behavior_match": True,
            "candidate_successes": len(ra), "reference_successes": len(rb),
            "candidate_conflicts": sum(r["outcome"] == "CONFLICT" for (s, _), r in left["requests"].items() if s == sid),
            "reference_conflicts": sum(r["outcome"] == "CONFLICT" for (s, _), r in right["requests"].items() if s == sid),
            "candidate_active_owner_count": state_a["active_owner_count"], "reference_active_owner_count": state_b["active_owner_count"],
            "candidate_winner_request_no": winner_a.get("request_no", "") if winner_a else "",
            "reference_winner_request_no": winner_b.get("request_no", "") if winner_b else "",
            "candidate_winner_request_uuid": winner_a.get("request_uuid", "") if winner_a else "",
            "reference_winner_request_uuid": winner_b.get("request_uuid", "") if winner_b else "",
            "candidate_winner_ngo_id": winner_a.get("ngo_id", "") if winner_a else "",
            "reference_winner_ngo_id": winner_b.get("ngo_id", "") if winner_b else "",
            "winner_request_ordinal_changed": ordinal_changed,
            "winner_ngo_identity_changed": ngo_changed,
            "schedule_difference": "concurrent winner ordering" if ordinal_changed or ngo_changed else "same observed winner",
        })

    request_uuid_differences = sum(a.get("request_uuid") != b.get("request_uuid") for key, a in left["requests"].items() for b in (right["requests"][key],))
    summary = {
        "scenario_count_each_run": 275, "request_count_each_run": 975,
        "candidate_vs_reference_request_uuid_differences": request_uuid_differences,
        "request_outcome_reason_retry_sqlstate_record_differences": len(request_differences),
        "scenarios_with_winner_request_ordinal_change": winner_request_changes,
        "scenarios_with_winner_ngo_identity_change": winner_ngo_changes,
        "candidate_sqlstate_error_rows": left["sqlstate_error_count"],
        "reference_sqlstate_error_rows": right["sqlstate_error_count"],
        "interpretation": "Run-scoped request UUIDs and winner ordering may differ; both runs independently passed identical frozen-scenario correctness and lease invariants.",
    }
    for level in LEVELS:
        def timing(run):
            values = [float(row["latency_ms"]) for (sid, _), row in run["requests"].items()
                      if sid.startswith("SCN-CLAIM_COORDINATION-") and int(row["workers"]) == level]
            return values
        a, b = timing(left), timing(right)
        summary[f"level_{level}_candidate_latency_median_ms"] = round(statistics.median(a), 3)
        summary[f"level_{level}_reference_latency_median_ms"] = round(statistics.median(b), 3)
        comparison_rows.append({"scenario_id": f"TIMING_{level}_CONCURRENT_REQUESTS", "case": "timing",
                                "behavior_match": "N/A", "candidate_successes": "", "reference_successes": "",
                                "candidate_conflicts": "", "reference_conflicts": "",
                                "candidate_active_owner_count": "", "reference_active_owner_count": "",
                                "candidate_winner_request_no": "", "reference_winner_request_no": "",
                                "candidate_winner_request_uuid": "", "reference_winner_request_uuid": "",
                                "candidate_winner_ngo_id": "", "reference_winner_ngo_id": "",
                                "winner_request_ordinal_changed": "N/A", "winner_ngo_identity_changed": "N/A",
                                "schedule_difference": f"candidate n={len(a)} median_ms={statistics.median(a):.3f} p95_ms={percentile(a,.95):.3f}; reference n={len(b)} median_ms={statistics.median(b):.3f} p95_ms={percentile(b,.95):.3f}"})
    comparison_rows.append({"scenario_id": "COMPARISON_TOTALS", "case": "aggregate",
                            "behavior_match": True, **summary})
    return {"scenario_rows": comparison_rows, "request_differences": request_differences, "summary": summary}


def source_artifacts(original, corrected, e4, historical=None, reference_corrected=None):
    historical = Path(historical or original).resolve()
    reference_corrected = Path(reference_corrected or DEFAULTS["corrected"]).resolve()
    paths = [
        original / "non_atomic_claim/results_per_scenario.csv",
        original / "non_atomic_claim/details/requests.csv",
        original / "protected_claim_without_lease_recovery/results_per_scenario.csv",
        original / "protected_claim_without_lease_recovery/details/requests.csv",
        original / "protected_claim_without_lease_recovery/lease_results_per_scenario.csv",
        historical / "proposed_results_per_scenario.csv", historical / "proposed_requests.json",
        historical / "database_errors.csv",
        corrected / "proposed_results_per_scenario.csv", corrected / "proposed_requests.json",
        corrected / "proposed_committed_states.json", corrected / "completion.json",
        corrected / "manifest.json", e4 / "results_per_scenario.csv", e4 / "summary_statistics.csv",
        e4 / "original_baseline_summary.csv", e4 / "paired_distance_summary.csv",
        e4 / "paired_uncertainty.csv", e4 / "verification.json",
    ]
    if (original / "comparison.csv").is_file():
        paths.append(original / "comparison.csv")
    if (original / "lease_comparison.csv").is_file():
        paths.append(original / "lease_comparison.csv")
    if (corrected / "regressions.json").is_file():
        paths.append(corrected / "regressions.json")
    if (corrected / "failures.json").is_file():
        paths.append(corrected / "failures.json")
    if (corrected / "database_errors.csv").is_file():
        paths.append(corrected / "database_errors.csv")
    if reference_corrected != corrected:
        paths += [reference_corrected / name for name in ("proposed_results_per_scenario.csv", "proposed_requests.json", "proposed_committed_states.json", "completion.json", "manifest.json")]
        for name in ("failures.json", "database_errors.csv"):
            if (reference_corrected / name).is_file():
                paths.append(reference_corrected / name)
    return list(dict.fromkeys(Path(p) for p in paths))


def baseline_lease_rows(original):
    summary = original / "lease_comparison.csv"
    if summary.is_file():
        return read_csv(summary)
    raw = original / "protected_claim_without_lease_recovery/lease_results_per_scenario.csv"
    rows = read_csv(raw)
    grouped = {}
    for case in ("lease expired", "lease still running"):
        group = [r for r in rows if r["case"] == case]
        grouped[case] = {
            "method": "protected_claim_without_lease_recovery", "case": case,
            "scenarios": len(group),
            "replacement_success": sum(r["second_ngo_got_listing"] == "YES" for r in group),
            "old_holder_still_active": sum(r["first_claim_still_active"] == "YES" for r in group),
        }
    return list(grouped.values())


def validate_corrected_manifest(manifest, *, combined=False):
    if manifest.get("correction_patch_sha256") != CORRECTED_PATCH_SHA256:
        raise ValueError("Corrected E2 migration hash is missing or does not match the approved lock patch")
    catalog = manifest.get("function_catalog", {}).get("e2_proposed", {})
    claim = catalog.get("claim_listing(uuid,uuid)", {})
    helper = catalog.get("geolock_lock_listing_donations(uuid,text[])", {})
    recovery = catalog.get("recover_expired_claims(integer)", {})
    if claim.get("md5") != CORRECTED_CLAIM_MD5 or helper.get("md5") != CORRECTED_LOCK_HELPER_MD5:
        raise ValueError("Corrected E2 function catalog does not match the two-lock proposed implementation")
    if recovery.get("md5") != "05fe46d8b76085f71c87fcc5f6520775":
        raise ValueError("Corrected E2 fixture recovery function differs from the preserved lease implementation")
    if combined:
        methods = ["non_atomic_claim", "protected_claim_without_lease_recovery", "corrected_atomic_claim_with_lease_recovery"]
        if manifest.get("primary_methods") != methods or manifest.get("method_runs") != 3:
            raise ValueError("Combined E2 manifest must identify exactly the three approved primary methods")
        if manifest.get("environment", {}).get("remote_access") is not False:
            raise ValueError("Combined E2 manifest does not confirm local-only execution")


def summarize(original, corrected, e4, output, historical=None, reference_corrected=None):
    original, corrected, e4 = [Path(p).resolve() for p in (original, corrected, e4)]
    historical = Path(historical or original).resolve()
    reference_corrected = Path(reference_corrected or DEFAULTS["corrected"]).resolve()
    output = Path(output).resolve()
    if output.exists():
        raise FileExistsError(f"Summary output already exists: {output}")

    original_results = {}
    primary_rows = []
    comparison = read_csv(original / "comparison.csv") if (original / "comparison.csv").is_file() else []
    original_run_results = read_csv(historical / "proposed_results_per_scenario.csv")
    original_requests = read_json(historical / "proposed_requests.json")
    original_audit = read_csv(historical / "database_errors.csv")
    for method, relative in BASELINE_FILES.items():
        rows = read_csv(original / relative)
        reqs = read_csv(original / ("non_atomic_claim/details/requests.csv" if method == "non_atomic_baseline" else "protected_claim_without_lease_recovery/details/requests.csv"))
        if len(rows) != 150 or len({r["scenario_id"] for r in rows}) != 150:
            raise ValueError(f"{method} must contain 150 unique contention scenarios")
        contention_ids = {r["scenario_id"] for r in rows}
        reqs = [r for r in reqs if r["scenario_id"] in contention_ids]
        if len(reqs) != 850:
            raise ValueError(f"{method} must contain 850 contention request records; found {len(reqs)}")
        scenario_id_set(rows, method)
        scenario_id_set([{ "scenario_id": r["scenario_id"] } for r in rows], method)
        original_results[method] = rows
        for level in LEVELS:
            primary_rows.append(aggregate_method(method, rows, reqs, comparison, level))

    corrected_results = read_csv(corrected / "proposed_results_per_scenario.csv")
    corrected_requests = read_json(corrected / "proposed_requests.json")
    corrected_completion = read_json(corrected / "completion.json")
    corrected_manifest = read_json(corrected / "manifest.json")
    validate_corrected_manifest(corrected_manifest, combined=original == corrected)
    regression_path = corrected / "regressions.json"
    if corrected_completion.get("completed_proposed") != 275 or corrected_completion.get("failures") != 0:
        raise ValueError("Corrected E2 source run is not the completed 275-scenario passing artifact")
    if regression_path.is_file() and read_json(regression_path).get("passed") is not True:
        raise ValueError("Corrected E2 focused regression evidence did not pass")
    if len(corrected_results) != 275 or len(corrected_requests) != 975:
        raise ValueError("Corrected E2 artifacts must have 275 scenarios and 975 total requests (850 contention plus 125 lease)")
    committed = read_json(corrected / "proposed_committed_states.json")
    if len(committed) != 275 or any(int(r["active_owner_count"]) != 1 for r in committed):
        raise ValueError("Corrected E2 committed ownership evidence is incomplete or invalid")
    reference_comparison = corrected_behavior_comparison(corrected, reference_corrected)
    primary_rows += corrected_contention_rows(corrected_results, corrected_requests)
    validate_three_method_rows(primary_rows)
    for method in FINAL_METHODS:
        group = [r for r in primary_rows if r["method"] == method]
        totals = tuple(sum(int(r[k]) for r in group) for k in ("claim_requests", "successful_requests", "already_claimed_conflicts", "duplicate_claim_trials", "surfaced_request_errors"))
        if method == "non_atomic_baseline":
            requests, successes, conflicts, duplicates, errors = totals
            if requests != 850 or successes + conflicts + errors != requests or duplicates != 150:
                raise ValueError(f"Non-atomic E2 outcomes or duplicate ownership evidence are inconsistent: {totals}")
            continue
        expected = {
            "atomic_without_lease_recovery": (850, 150, 700, 0, 0),
            "atomic_with_lease_recovery_corrected": (850, 150, 700, 0, 0),
        }[method]
        if totals != expected:
            raise ValueError(f"Final E2 primary comparison totals differ for {method}: {totals} != {expected}")
    identity_sets = {r["identity_distribution"] for r in primary_rows if r["method"] == FINAL_METHODS[0]}
    for level in LEVELS:
        same = {r["identity_distribution"] for r in primary_rows if int(r["concurrent_requests"]) == level}
        if len(same) != 1:
            raise ValueError(f"E2 methods use different frozen actor identity distributions at {level} requests")

    history = build_development_history(original_run_results, original_requests, original_audit, corrected_results, corrected_requests)
    if sum(int(r["surfaced_request_errors"]) for r in history if r["implementation_version"] == "original_proposed_historical") != 683:
        raise ValueError("Original proposed development history no longer totals 683 errors")

    original_lease = baseline_lease_rows(original)
    baseline_lease = {r["case"]: r for r in original_lease if r["method"] == "protected_claim_without_lease_recovery"}
    if len(baseline_lease) != 2 or int(baseline_lease["lease expired"]["scenarios"]) != 100 or int(baseline_lease["lease expired"]["replacement_success"]) != 0 or int(baseline_lease["lease still running"]["scenarios"]) != 25 or int(baseline_lease["lease still running"]["old_holder_still_active"]) != 25:
        raise ValueError("Protected baseline lease evidence does not match the expected 0/100 recovery and 25/25 active protection")
    corrected_lease_rows = []
    for case, scenarios, want_recovery, want_active in (("lease expired", 100, 100, 0), ("lease still running", 25, 0, 25)):
        group = [r for r in corrected_results if r.get("case") == case]
        got_recovery = sum(r["second_ngo_got_listing"] == "YES" for r in group)
        got_active = sum(r["first_claim_still_active"] == "YES" for r in group)
        failures = sum(r["second_ngo_answer"] == "ERROR" for r in group)
        if len(group) != scenarios or got_recovery != want_recovery or got_active != want_active or failures != 0:
            raise ValueError(f"Corrected proposed lease evidence mismatch for {case}")
        corrected_lease_rows.append({"method": FINAL_METHODS[2], "case": case, "scenarios": scenarios,
                                     "successful_recovery_or_reassignment": got_recovery,
                                     "active_lease_protected": got_active, "surfaced_request_errors": failures})
    lease_rows = [
        {"method": FINAL_METHODS[0], "case": case, "scenarios": "N/A", "successful_recovery_or_reassignment": "N/A (not tested)", "active_lease_protected": "N/A (not tested)", "surfaced_request_errors": "N/A"}
        for case in ("lease expired", "lease still running")
    ]
    lease_rows += [
        {"method": FINAL_METHODS[1], "case": "lease expired", "scenarios": 100, "successful_recovery_or_reassignment": 0, "active_lease_protected": 100, "surfaced_request_errors": 0},
        {"method": FINAL_METHODS[1], "case": "lease still running", "scenarios": 25, "successful_recovery_or_reassignment": 0, "active_lease_protected": 25, "surfaced_request_errors": 0},
    ] + corrected_lease_rows

    e4_results, e4_summary, e4_original, verification = validate_e4(e4)
    sources = source_artifacts(original, corrected, e4, historical, reference_corrected)
    missing = [p for p in sources if not p.is_file()]
    if missing:
        raise FileNotFoundError(f"Required preserved source artifact missing: {missing[0]}")
    source_hashes = {str(p.relative_to(ROOT)) if p.is_relative_to(ROOT) else str(p): sha256(p) for p in sources}
    output.mkdir(parents=True, exist_ok=False)
    write_csv(output / "e2_primary_three_method_comparison.csv", primary_rows)
    write_csv(output / "e2_lease_comparison.csv", lease_rows)
    write_csv(output / "e2_development_history.csv", history)
    write_csv(output / "e2_corrected_reference_comparison.csv", reference_comparison["scenario_rows"])
    write_csv(output / "e2_corrected_request_differences.csv", reference_comparison["request_differences"])
    write_csv(output / "e4_common_admission_summary.csv", e4_summary)
    write_csv(output / "e4_original_500_task_baseline.csv", e4_original)
    write_csv(output / "e4_paired_distance_summary.csv", read_csv(e4 / "paired_distance_summary.csv"))
    write_csv(output / "e4_paired_uncertainty.csv", read_csv(e4 / "paired_uncertainty.csv"))
    manifest = {
        "source_runs": {"baseline_e2": original.name, "historical_original_proposed_e2": historical.name, "corrected_proposed_e2": corrected.name, "corrected_reference_e2": reference_corrected.name, "final_e4": e4.name},
        "source_sha256": source_hashes,
        "primary_e2_methods": list(FINAL_METHODS),
        "historical_original_proposed": "Separate development evidence only; excluded from primary three-method E2 comparison.",
        "e2_level_semantics": "2/5/10 are concurrent requests. Frozen NGO identities can repeat; per-method identity_distribution records the exact distinct eligible NGO count per scenario.",
        "e4_lanes": {"original_baseline_reproduction": "500 tasks, Nearest-Next/FCFS", "corrected_common_input": "500 tasks, Nearest-Next/FCFS/CP-SAT"},
        "independently_revalidated_e4_routes": verification["saved_routes_independently_revalidated"],
        "corrected_reference_behavior_match": True,
        "corrected_reference_comparison": reference_comparison["summary"],
    }
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    report = [
        "# Final E2/E4 summary", "",
        "## E2 primary research comparison", "",
        "The primary E2 comparison contains exactly three methods: non-atomic baseline; atomic without lease recovery; and atomic with lease recovery using the corrected proposed implementation. See `e2_primary_three_method_comparison.csv` for results at each concurrency level.",
        "", "The 2/5/10 values are concurrent request counts, not distinct NGO counts. The frozen actor pool contains two to four distinct eligible NGOs and can reuse an identity across requests; the CSV records the per-level identity distribution. The corrected synthetic distinct-actor regression is diagnostic evidence and is not counted as GEOLOCK-BM-v3.3 benchmark data.",
        "", "Lease results are in `e2_lease_comparison.csv`. The non-atomic method's lease values are N/A because that baseline did not test lease recovery. The atomic-without-recovery baseline recovered 0/100 expired leases and protected 25/25 active leases. Corrected proposed recovered/reassigned 100/100 expired leases and protected 25/25 active leases.",
        "", "## E2 implementation development history", "",
        f"`e2_development_history.csv` keeps the original proposed version separate from the research comparison. The historical version in `{historical.name}` had 683 request errors, all matched to rollback-confirmed SQLSTATE 40P01 audit records across the 850 contention requests. The corrected version in `{corrected.name}` has 0 surfaced contention request errors; corrected SQLSTATE-by-error is N/A because no request errors were recorded. Original result artifacts remain unchanged.",
        f"The corrected candidate was validated independently and compared with preserved run `{reference_corrected.name}`. Each run must satisfy the same frozen scenarios, exact per-scenario claim/lease/ownership invariants, and zero unexpected errors or retries. Concurrent winners may differ: `e2_corrected_reference_comparison.csv` records winner request ordinals and NGO identities per scenario, and `e2_corrected_request_differences.csv` records request-level outcome/reason/retry/SQLSTATE differences with run-scoped IDs. These are reported as scheduling differences when both runs pass the invariants. Timing is descriptive, not a parity criterion.",
        "", "## E4", "",
        "`e4_original_500_task_baseline.csv` reports the original 500-task Nearest-Next/FCFS baseline reproduction. `e4_common_admission_summary.csv` reports the corrected 500-task common-input comparison for Nearest-Next, FCFS, and CP-SAT. The E4-only adapter ignores only synthetic listing expiry; all 300 method/scenario routes passed independent validation. Paired distance and uncertainty tables are retained separately; distance conclusions remain restricted to scenarios with identical served-task sets. The superseded 483-task result directory is not used.",
        "", "Latency results are descriptive across separate runs. E2 schema/function differences confound a causal latency interpretation; E4 uncertainty intervals describe the fixed benchmark scenario set, not population inference.", "",
    ]
    (output / "COMPARISON.md").write_text("\n".join(report), encoding="utf-8")
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--original-e2", type=Path, default=DEFAULTS["original"])
    parser.add_argument("--corrected-e2", type=Path, default=DEFAULTS["corrected"])
    parser.add_argument("--historical-e2", type=Path, default=DEFAULTS["historical"], help="Preserved original 683-deadlock evidence; excluded from primary methods")
    parser.add_argument("--combined-e2", type=Path, help="One normal E2 run containing both baselines and the corrected proposed method")
    parser.add_argument("--reference-corrected-e2", type=Path, default=DEFAULTS["corrected"], help="Preserved corrected run used for behavior parity comparison")
    parser.add_argument("--e4", type=Path, required=True, help="Completed E4 run to summarize; no current final E4 result is retained")
    parser.add_argument("--output", type=Path, required=True, help="New output directory; must not already exist")
    args = parser.parse_args()
    if args.combined_e2:
        original = corrected = args.combined_e2
        historical = args.historical_e2
    else:
        original, corrected, historical = args.original_e2, args.corrected_e2, args.historical_e2
    print(summarize(original, corrected, args.e4, args.output, historical, args.reference_corrected_e2))


if __name__ == "__main__":
    main()
