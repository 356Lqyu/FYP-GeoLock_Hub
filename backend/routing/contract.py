"""Strict, versioned, immutable input boundary for later routing methods.

This module validates supplied snapshots, not live PostgreSQL authority. It never
creates claims, routes, assignments, vehicles, or dispatch authorisations.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta
import hashlib
import json
import math
from pathlib import Path
import re
from typing import Any

VERSION = "geolock.routing.scenario.v1"
DEV_PROJECT = "rcgyuwiidqvrgbxswhqj"
DONATION_STATES = {"SUBMITTED", "AVAILABLE", "HUB_ASSIGNED", "AT_HUB", "BATCHED",
                   "CLAIMED", "PICKUP_IN_PROGRESS", "COLLECTED", "CANCELLED"}
CLAIM_STATES = {"ACTIVE", "RELEASED", "EXPIRED", "COMPLETED", "CANCELLED", "RECONCILIATION_REQUIRED"}
LEASE_STATES = CLAIM_STATES - {"CANCELLED"}
TASK_STATES = {"CONFIRMED", "PLANNED", "DISPATCHED", "COLLECTED", "CANCELLED", "STALE"}


class ContractError(ValueError):
    """Malformed or internally inconsistent input, with a stable diagnostic code."""

    def __init__(self, code: str, path: str, message: str):
        self.code, self.path = code, path
        super().__init__(f"{code} at {path}: {message}")


def _require(ok: bool, code: str, path: str, message: str) -> None:
    if not ok:
        raise ContractError(code, path, message)


def _obj(value: Any, fields: str, path: str) -> dict:
    _require(type(value) is dict, "INVALID_OBJECT", path, "expected object")
    expected = set(fields.split())
    _require(set(value) == expected, "INVALID_FIELDS", path,
             f"missing={sorted(expected-set(value))}; unknown={sorted(set(value)-expected, key=str)}")
    return value


def _list(value: Any, path: str) -> list:
    _require(type(value) is list, "INVALID_ARRAY", path, "expected array")
    return value


def _text(value: Any, path: str) -> str:
    _require(type(value) is str and bool(value.strip()), "INVALID_TEXT", path, "nonblank string required")
    return value


def _enum(value: Any, choices: set, path: str) -> None:
    _text(value, path)
    _require(value in choices, "INVALID_VALUE", path, f"expected one of {sorted(choices)}")


def _number(value: Any, path: str, *, positive: bool = False) -> float:
    _require(type(value) in (int, float), "INVALID_NUMBER", path, "finite JSON number required")
    try:
        valid = math.isfinite(value) and (value > 0 if positive else value >= 0)
    except OverflowError:
        valid = False
    _require(valid, "INVALID_NUMBER", path, "finite positive number required" if positive else "finite nonnegative number required")
    return value


def _integer(value: Any, path: str, minimum: int = 1) -> int:
    _require(type(value) is int and value >= minimum, "INVALID_INTEGER", path, f"integer >= {minimum} required")
    return value


def _bool(value: Any, path: str) -> bool:
    _require(type(value) is bool, "INVALID_BOOLEAN", path, "boolean required")
    return value


def _token(value: Any, path: str) -> None:
    _require(type(value) is str and re.fullmatch(r"[0-9a-f]{64}", value) is not None,
             "INVALID_STATE_TOKEN", path, "lowercase SHA-256 of canonical source fields required")


def _time(value: Any, path: str) -> datetime:
    _text(value, path)
    try:
        result = datetime.fromisoformat(value.replace("Z", "+00:00"))
        _require(result.tzinfo is not None and result.utcoffset() is not None,
                 "INVALID_TIMESTAMP", path, "timezone offset required")
        return result
    except (ValueError, OverflowError) as exc:
        if isinstance(exc, ContractError):
            raise
        raise ContractError("INVALID_TIMESTAMP", path, "ISO-8601 timestamp required") from exc


def _unique(values: list, path: str) -> None:
    _require(len(values) == len(set(values)), "DUPLICATE_ID", path, "identities must be unique")


def _location(value: Any, path: str) -> None:
    _obj(value, "location_id road_node_id network_snapshot_id latitude longitude state_token", path)
    for key in ("location_id", "road_node_id", "network_snapshot_id"):
        _text(value[key], f"{path}.{key}")
    for key, limit in (("latitude", 90), ("longitude", 180)):
        v = value[key]
        _require(type(v) in (int, float) and -limit <= v <= limit,
                 "INVALID_COORDINATE", f"{path}.{key}", "finite coordinate in range required")
    _token(value["state_token"], f"{path}.state_token")


@dataclass(frozen=True)
class FrozenScenario:
    """Canonical JSON is the sole stored payload; callers only receive fresh copies."""

    canonical_json: str
    sha256: str
    matrix_sha256: str
    admitted_task_ids: tuple[str, ...]
    excluded_tasks: tuple[tuple[str, tuple[str, ...]], ...]
    available_vehicle_ids: tuple[str, ...]
    readiness: str
    unavailable_arcs: tuple[tuple[str, str, str], ...]

    def to_dict(self) -> dict:
        return json.loads(self.canonical_json)


def _configuration(c: dict) -> None:
    _obj(c, "version currency planning_horizon_minutes dispatch_margin_minutes objective time_window_policy", "configuration")
    for key in ("version", "currency"):
        _text(c[key], f"configuration.{key}")
    _number(c["planning_horizon_minutes"], "configuration.planning_horizon_minutes", positive=True)
    _number(c["dispatch_margin_minutes"], "configuration.dispatch_margin_minutes")
    _enum(c["objective"], {"MIN_UNSERVED_THEN_FIXED_PLUS_DISTANCE_COST"}, "configuration.objective")
    _enum(c["time_window_policy"], {"SERVICE_COMPLETION_WITHIN_WINDOW"}, "configuration.time_window_policy")


def _solver(s: dict) -> None:
    _obj(s, "engine version time_limit_seconds workers seed first_solution local_search tie_break timeout_policy", "solver")
    _enum(s["engine"], {"OR_TOOLS"}, "solver.engine")
    _text(s["version"], "solver.version")
    _number(s["time_limit_seconds"], "solver.time_limit_seconds", positive=True)
    _integer(s["workers"], "solver.workers")
    _require(s["workers"] == 1, "NONDETERMINISTIC_CONFIGURATION", "solver.workers", "Phase A requires one worker")
    _integer(s["seed"], "solver.seed", 0)
    _enum(s["first_solution"], {"PATH_CHEAPEST_ARC"}, "solver.first_solution")
    _enum(s["local_search"], {"GUIDED_LOCAL_SEARCH"}, "solver.local_search")
    _enum(s["tie_break"], {"TASK_ID_THEN_VEHICLE_ID"}, "solver.tie_break")
    _enum(s["timeout_policy"], {"VALIDATED_INCUMBENT_ONLY"}, "solver.timeout_policy")


def _task(t: dict, path: str) -> None:
    _obj(t, "task_id ngo_id claim_id claim_ngo_id lease_id listing_id source_type "
         "task_status claim_status lease_status listing_status created_at lease_issued_at lease_expires_at "
         "listing_expires_at listing_version task_state_token claim_state_token lease_state_token "
         "pickup authorized_pickup weight_kg listing_weight_kg time_window service_minutes mandatory "
         "has_route_assignment reconciliation_blocked donations batch", path)
    for key in ("task_id", "ngo_id", "claim_id", "claim_ngo_id", "lease_id", "listing_id"):
        _text(t[key], f"{path}.{key}")
    for key, choices in (("source_type", {"DIRECT_DONATION", "HUB_BATCH"}),
                         ("task_status", TASK_STATES), ("claim_status", CLAIM_STATES),
                         ("lease_status", LEASE_STATES),
                         ("listing_status", {"AVAILABLE", "CLAIMED", "CLOSED", "CANCELLED"})):
        _enum(t[key], choices, f"{path}.{key}")
    for key in ("task_state_token", "claim_state_token", "lease_state_token"):
        _token(t[key], f"{path}.{key}")
    _integer(t["listing_version"], f"{path}.listing_version")
    _time(t["created_at"], f"{path}.created_at")
    issued = _time(t["lease_issued_at"], f"{path}.lease_issued_at")
    expires = _time(t["lease_expires_at"], f"{path}.lease_expires_at")
    _require(issued < expires, "INVALID_LEASE_INTERVAL", path, "expiry must follow issue time")
    # DEV uses now() for task creation and clock_timestamp() for lease issuance;
    # a task's default timestamp can therefore precede lease issuance slightly.
    if t["listing_expires_at"] is not None:
        _time(t["listing_expires_at"], f"{path}.listing_expires_at")
    _location(t["pickup"], f"{path}.pickup")
    _location(t["authorized_pickup"], f"{path}.authorized_pickup")
    _number(t["weight_kg"], f"{path}.weight_kg", positive=True)
    _number(t["listing_weight_kg"], f"{path}.listing_weight_kg", positive=True)
    _number(t["service_minutes"], f"{path}.service_minutes")
    for key in ("mandatory", "has_route_assignment", "reconciliation_blocked"):
        _bool(t[key], f"{path}.{key}")
    w = _obj(t["time_window"], "start end provenance", f"{path}.time_window")
    _text(w["provenance"], f"{path}.time_window.provenance")
    _require(_time(w["start"], path+".time_window.start") < _time(w["end"], path+".time_window.end"),
             "INVALID_TIME_WINDOW", path, "window end must follow start")
    donations = _list(t["donations"], f"{path}.donations")
    _require(bool(donations), "EMPTY_DONATION_SET", path, "source donation set required")
    for d in donations:
        _obj(d, "donation_id donation_status state_token", path+".donations[]")
        _text(d["donation_id"], path+".donations[].donation_id")
        _enum(d["donation_status"], DONATION_STATES, path+".donations[].donation_status")
        _token(d["state_token"], path+".donations[].state_token")
    _unique([d["donation_id"] for d in donations], path+".donations")
    if t["source_type"] == "DIRECT_DONATION":
        _require(len(donations) == 1 and t["batch"] is None, "INVALID_DIRECT_SOURCE", path,
                 "one donation and no batch required")
    else:
        b = _obj(t["batch"], "batch_id hub_id batch_version batch_status inventory_status member_count state_token", path+".batch")
        for key in ("batch_id", "hub_id"):
            _text(b[key], path+".batch."+key)
        _integer(b["batch_version"], path+".batch.batch_version")
        _integer(b["member_count"], path+".batch.member_count")
        _require(b["member_count"] == len(donations), "BATCH_MEMBER_MISMATCH", path, "exact immutable member set required")
        _enum(b["batch_status"], {"DRAFT", "PUBLISHED", "CLAIMED", "COLLECTED", "CANCELLED"}, path+".batch.batch_status")
        _enum(b["inventory_status"], {"STORED", "BATCHED", "COLLECTED", "RECONCILIATION_REQUIRED"}, path+".batch.inventory_status")
        _token(b["state_token"], path+".batch.state_token")
        _require(t["authorized_pickup"]["location_id"] == b["hub_id"],
                 "WRONG_HUB_PICKUP", path, "authorized source must be the selected hub")


def _admission(t: dict, ngo: str, cutoff: datetime, end: datetime) -> tuple[str, ...]:
    reasons = []
    if t["ngo_id"] != ngo or t["claim_ngo_id"] != ngo:
        reasons.append("FOREIGN_OWNER")
    if t["task_status"] != "CONFIRMED":
        reasons.append("TASK_NOT_CONFIRMED")
    if t["claim_status"] != "ACTIVE" or t["lease_status"] != "ACTIVE":
        reasons.append("INVALID_AUTHORITY")
    if t["listing_status"] != "CLAIMED":
        reasons.append("LISTING_NOT_CLAIMED")
    if _time(t["created_at"], "task.created_at") > cutoff or _time(t["lease_issued_at"], "task.lease_issued_at") > cutoff:
        reasons.append("AFTER_CUTOFF")
    expiry = _time(t["lease_expires_at"], "task.lease_expires_at")
    if expiry <= cutoff:
        reasons.append("LEASE_EXPIRED")
    elif expiry <= end:
        reasons.append("INSUFFICIENT_LEASE_TIME")
    if t["listing_expires_at"] is not None and _time(t["listing_expires_at"], "task.listing_expires_at") <= end:
        reasons.append("LISTING_EXPIRES_BEFORE_HORIZON")
    if t["reconciliation_blocked"]:
        reasons.append("RECONCILIATION_REQUIRED")
    if t["has_route_assignment"]:
        reasons.append("TASK_ALREADY_ASSIGNED")
    if t["pickup"] != t["authorized_pickup"]:
        reasons.append("PICKUP_LOCATION_MISMATCH")
    if t["weight_kg"] != t["listing_weight_kg"]:
        reasons.append("WEIGHT_MISMATCH")
    if any(d["donation_status"] != "CLAIMED" for d in t["donations"]):
        reasons.append("DONATION_NOT_CLAIMED")
    if t["batch"] is not None and (t["batch"]["batch_status"] != "PUBLISHED" or t["batch"]["inventory_status"] != "BATCHED"):
        reasons.append("BATCH_NOT_READY")
    start = max(cutoff, _time(t["time_window"]["start"], "task.time_window.start"))
    window_end = _time(t["time_window"]["end"], "task.time_window.end")
    if t["service_minutes"] > (window_end-start).total_seconds()/60:
        reasons.append("TIME_WINDOW_CLOSED")
    return tuple(reasons)


def _matrix(m: dict, required_nodes: set[str], kind: str) -> tuple[tuple[str, str, str], ...]:
    _obj(m, "matrix_id version network_snapshot_id source_kind provenance method edge_speed_profile "
         "path_policy unavailable_policy node_order distance_km travel_minutes arc_status", "matrix")
    for key in ("matrix_id", "version", "network_snapshot_id", "provenance", "method", "edge_speed_profile"):
        _text(m[key], "matrix."+key)
    _enum(m["source_kind"], {"SYNTHETIC_BENCHMARK", "OPERATIONAL_ROAD_NETWORK"}, "matrix.source_kind")
    expected = "SYNTHETIC_BENCHMARK" if kind == "SYNTHETIC_BENCHMARK" else "OPERATIONAL_ROAD_NETWORK"
    _require(m["source_kind"] == expected, "MATRIX_PROVENANCE_MISMATCH", "matrix.source_kind", "benchmark and operational sources must not mix")
    if kind == "OPERATIONAL_SNAPSHOT":
        _require(m["network_snapshot_id"].startswith("OSM-OPS-"), "MATRIX_PROVENANCE_MISMATCH", "matrix.network_snapshot_id", "operational snapshot identifier required")
    _enum(m["path_policy"], {"DIRECTED_SHORTEST_DISTANCE_WITH_TIME_ON_SAME_PATH"}, "matrix.path_policy")
    _enum(m["unavailable_policy"], {"FAIL_SCENARIO", "FORBID_ARC"}, "matrix.unavailable_policy")
    nodes = _list(m["node_order"], "matrix.node_order")
    for node in nodes:
        _text(node, "matrix.node_order[]")
        if kind == "OPERATIONAL_SNAPSHOT":
            _require(re.fullmatch(r"[1-9][0-9]*", node) is not None,
                     "MATRIX_PROVENANCE_MISMATCH", "matrix.node_order[]", "operational OSM node identifier required")
    _unique(nodes, "matrix.node_order")
    _require(required_nodes <= set(nodes), "MISSING_MATRIX_NODE", "matrix.node_order", "all admitted pickups and depot must be covered")
    n = len(nodes)
    for key in ("distance_km", "travel_minutes", "arc_status"):
        grid = _list(m[key], "matrix."+key)
        _require(len(grid) == n, "INVALID_MATRIX_SHAPE", "matrix."+key, "square matrix required")
        for row in grid:
            _require(len(_list(row, "matrix."+key+"[]")) == n, "INVALID_MATRIX_SHAPE", "matrix."+key, "square matrix required")
    unavailable = []
    for i, source in enumerate(nodes):
        for j, target in enumerate(nodes):
            status = m["arc_status"][i][j]
            _enum(status, {"AVAILABLE", "UNREACHABLE", "MISSING"}, f"matrix.arc_status[{i}][{j}]")
            distance, minutes = m["distance_km"][i][j], m["travel_minutes"][i][j]
            if status == "AVAILABLE":
                _number(distance, f"matrix.distance_km[{i}][{j}]", positive=i != j)
                _number(minutes, f"matrix.travel_minutes[{i}][{j}]", positive=i != j)
                if i == j:
                    _require(distance == minutes == 0, "INVALID_MATRIX_DIAGONAL", "matrix", "self arcs must be zero")
            else:
                _require(i != j and distance is None and minutes is None, "INVALID_UNAVAILABLE_ARC", "matrix", "unavailable arcs need paired nulls and cannot be self arcs")
                if source in required_nodes and target in required_nodes:
                    unavailable.append((source, target, status))
    return tuple(unavailable)


def freeze_scenario(payload: dict) -> FrozenScenario:
    """Validate input and seal a common snapshot. Readiness never means feasibility."""
    _obj(payload, "schema_version planning_run_id scenario_id source ngo_id ngo_active ngo_location_verified_at ngo_location_generation cutoff configuration depot "
         "route_start_location_id route_end_location_id vehicles tasks matrix solver", "scenario")
    _enum(payload["schema_version"], {VERSION}, "schema_version")
    for key in ("planning_run_id", "scenario_id", "ngo_id"):
        _text(payload[key], key)
    source = _obj(payload["source"], "kind project_ref provenance evidence_ref", "source")
    _enum(source["kind"], {"SYNTHETIC_BENCHMARK", "OPERATIONAL_SNAPSHOT"}, "source.kind")
    for key in ("provenance", "evidence_ref"):
        _text(source[key], "source."+key)
    _require(source["project_ref"] == (None if source["kind"] == "SYNTHETIC_BENCHMARK" else DEV_PROJECT),
             "INVALID_PROJECT_SCOPE", "source.project_ref", "only DEV operational snapshots or project-free benchmarks are accepted")
    cutoff = _time(payload["cutoff"], "cutoff")
    _require(_bool(payload["ngo_active"], "ngo_active"), "INACTIVE_NGO", "ngo_active", "requesting NGO must be active")
    _integer(payload["ngo_location_generation"], "ngo_location_generation", 0)
    _require(_time(payload["ngo_location_verified_at"], "ngo_location_verified_at") <= cutoff,
             "UNVERIFIED_DEPOT", "ngo_location_verified_at", "location verification must precede snapshot cutoff")
    _configuration(payload["configuration"])
    config = payload["configuration"]
    try:
        end = cutoff + timedelta(minutes=config["planning_horizon_minutes"] + config["dispatch_margin_minutes"])
    except OverflowError as exc:
        raise ContractError("INVALID_HORIZON", "configuration", "horizon outside datetime range") from exc
    _location(payload["depot"], "depot")
    for key in ("route_start_location_id", "route_end_location_id"):
        _require(payload[key] == payload["depot"]["location_id"], "INVALID_DEPOT", key, "all routes must start and end at NGO depot")
    _solver(payload["solver"])
    tasks = _list(payload["tasks"], "tasks")
    for i, task in enumerate(tasks):
        _task(task, f"tasks[{i}]")
    for key in ("task_id", "claim_id", "lease_id", "listing_id"):
        _unique([t[key] for t in tasks], "tasks."+key)
    _unique([d["donation_id"] for t in tasks for d in t["donations"]], "tasks.donations")
    admitted, excluded = [], []
    for task in sorted(tasks, key=lambda t: t["task_id"]):
        reasons = _admission(task, payload["ngo_id"], cutoff, end)
        if reasons:
            excluded.append((task["task_id"], reasons))
        else:
            admitted.append(task)
    fleet = _list(payload["vehicles"], "vehicles")
    available = []
    for i, vehicle in enumerate(fleet):
        path = f"vehicles[{i}]"
        _obj(vehicle, "vehicle_id ngo_id vehicle_type capacity_kg active available_for_planning fixed_cost "
             "distance_cost_per_km max_route_minutes depot_location_id state_token", path)
        for key in ("vehicle_id", "ngo_id", "vehicle_type"):
            _text(vehicle[key], path+"."+key)
        _require(vehicle["ngo_id"] == payload["ngo_id"], "FOREIGN_VEHICLE", path, "vehicle must belong to requesting NGO")
        _require(vehicle["depot_location_id"] == payload["depot"]["location_id"], "INVALID_DEPOT", path, "one NGO depot required")
        for key in ("capacity_kg", "max_route_minutes"):
            _number(vehicle[key], path+"."+key, positive=True)
        _require(vehicle["max_route_minutes"] <= config["planning_horizon_minutes"],
                 "INVALID_ROUTE_HORIZON", path, "vehicle route duration cannot exceed frozen planning horizon")
        for key in ("fixed_cost", "distance_cost_per_km"):
            _number(vehicle[key], path+"."+key)
        _token(vehicle["state_token"], path+".state_token")
        if _bool(vehicle["active"], path+".active") and _bool(vehicle["available_for_planning"], path+".available_for_planning"):
            available.append(vehicle["vehicle_id"])
        else:
            _bool(vehicle["available_for_planning"], path+".available_for_planning")
    _unique([v["vehicle_id"] for v in fleet], "vehicles.vehicle_id")
    nodes = {payload["depot"]["road_node_id"]} | {t["pickup"]["road_node_id"] for t in admitted}
    unavailable = _matrix(payload["matrix"], nodes, source["kind"])
    for loc in [payload["depot"]] + [t["pickup"] for t in admitted]:
        _require(loc["network_snapshot_id"] == payload["matrix"]["network_snapshot_id"],
                 "ROAD_SNAPSHOT_MISMATCH", "locations", "depot, admitted pickups and matrix must use one road snapshot")
    readiness = ("NO_VALID_TASKS" if not admitted else "NO_FEASIBLE_PLAN" if not available else
                 "ROUTE_UNAVAILABLE" if unavailable and payload["matrix"]["unavailable_policy"] == "FAIL_SCENARIO" else "READY_FOR_PLANNING")
    # Copy through JSON only after strict validation; callers cannot mutate us.
    copied = json.loads(json.dumps(payload, allow_nan=False))
    copied["tasks"].sort(key=lambda t: t["task_id"])
    copied["vehicles"].sort(key=lambda v: v["vehicle_id"])
    matrix_json = json.dumps(copied["matrix"], sort_keys=True, separators=(",", ":"), ensure_ascii=True, allow_nan=False)
    matrix_sha = hashlib.sha256(matrix_json.encode("utf-8")).hexdigest()
    envelope = {"input": copied, "matrix_sha256": matrix_sha, "admitted_task_ids": [t["task_id"] for t in admitted],
                "excluded_tasks": [{"task_id": tid, "reasons": reasons} for tid, reasons in excluded],
                "available_vehicle_ids": sorted(available), "readiness": readiness,
                "unavailable_arcs": unavailable, "dispatch_authority_issued": False}
    canonical = json.dumps(envelope, sort_keys=True, separators=(",", ":"), ensure_ascii=True, allow_nan=False)
    return FrozenScenario(canonical, hashlib.sha256(canonical.encode("utf-8")).hexdigest(), matrix_sha,
                          tuple(t["task_id"] for t in admitted), tuple(excluded), tuple(sorted(available)), readiness, unavailable)


def _pairs(pairs: list) -> dict:
    result = {}
    for key, value in pairs:
        _require(key not in result, "DUPLICATE_JSON_KEY", key, "duplicate keys are ambiguous")
        result[key] = value
    return result


def load_scenario(path: str | Path) -> FrozenScenario:
    def invalid_constant(value: str) -> None:
        raise ContractError("INVALID_NUMBER", "json", f"non-finite {value} is forbidden")

    try:
        payload = json.loads(Path(path).read_text(encoding="utf-8"), object_pairs_hook=_pairs, parse_constant=invalid_constant)
    except json.JSONDecodeError as exc:
        raise ContractError("INVALID_JSON", "json", str(exc)) from exc
    return freeze_scenario(payload)
