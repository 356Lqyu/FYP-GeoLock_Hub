"""Independent raw-input route verification. No imports from solver/problem code."""

from collections import Counter
from dataclasses import dataclass
from datetime import datetime
from decimal import Decimal
import hashlib
import re

from ..contract import freeze_scenario
from .models import Plan

PICKUP_TASK_OBJECTIVE = "MAX_PICKUP_TASKS_THEN_MIN_DIRECTED_ROAD_KM"


@dataclass(frozen=True)
class ValidationResult:
    valid: bool
    feasible: bool
    violations: tuple[tuple[str, str], ...]
    mandatory_unserved: tuple[str, ...]
    metrics: dict


def validate_plan(snapshot, plan: Plan) -> ValidationResult:
    issues = []

    def issue(code, detail):
        issues.append((code, str(detail)))

    rebuilt = freeze_scenario(snapshot.to_dict()["input"])
    if rebuilt != snapshot or hashlib.sha256(snapshot.canonical_json.encode()).hexdigest() != snapshot.sha256:
        issue("SNAPSHOT_INTEGRITY", "input digest/admission metadata mismatch")
    p = rebuilt.to_dict()["input"]
    times = [p["cutoff"], p["ngo_location_verified_at"]]
    for task in p["tasks"]:
        times.extend(task[k] for k in ("created_at", "lease_issued_at", "lease_expires_at", "listing_expires_at") if task[k] is not None)
        times.extend((task["time_window"]["start"], task["time_window"]["end"]))
    if any(len(part) > 6 and any(c != "0" for c in part[6:])
           for timestamp_text in times for part in re.findall(r"[.,]([0-9]+)", timestamp_text)):
        issue("INPUT_PRECISION", "sub-microsecond timestamp is outside execution precision")
    admitted = set(rebuilt.admitted_task_ids)
    tasks = {t["task_id"]: t for t in p["tasks"]}
    vehicles = {v["vehicle_id"]: v for v in p["vehicles"]}
    matrix = p["matrix"]
    indices = {n: i for i, n in enumerate(matrix["node_order"])}
    cutoff = datetime.fromisoformat(p["cutoff"].replace("Z", "+00:00"))
    depot = p["depot"]

    def number(value):
        return Decimal(str(value))

    def us(minutes):
        # Deliberately recomputed from source values, not solver integer helpers.
        return number(minutes)*Decimal(60_000_000)

    def timestamp(value):
        delta = datetime.fromisoformat(value.replace("Z", "+00:00"))-cutoff
        return Decimal((delta.days*86400+delta.seconds)*1_000_000+delta.microseconds)

    def arc(a, b):
        if a not in indices or b not in indices:
            issue("ARC_UNAVAILABLE", f"unknown node {a}->{b}")
            return None
        i, j = indices[a], indices[b]
        if matrix["arc_status"][i][j] != "AVAILABLE" or matrix["distance_km"][i][j] is None or matrix["travel_minutes"][i][j] is None:
            issue("ARC_UNAVAILABLE", f"{a}->{b}")
            return None
        return number(matrix["distance_km"][i][j]), us(matrix["travel_minutes"][i][j])

    if plan.snapshot_sha256 != rebuilt.sha256 or plan.matrix_sha256 != rebuilt.matrix_sha256:
        issue("PLAN_STALE", "plan is bound to another input or matrix")
    if plan.dispatch_authority_issued:
        issue("AUTHORITY", "offline plans cannot grant dispatch authority")
    if rebuilt.readiness != "READY_FOR_PLANNING" and plan.routes:
        issue("INPUT_BLOCKED", rebuilt.readiness)
    used, seen = [], []
    km = duration = driving = service = waiting = fixed = distance_cost = Decimal(0)
    for rindex, route in enumerate(plan.routes):
        label = f"route {rindex}/{route.vehicle_id}"
        used.append(route.vehicle_id)
        if route.vehicle_id not in vehicles:
            issue("VEHICLE", label+": unknown vehicle")
            continue
        vehicle = vehicles[route.vehicle_id]
        if (route.vehicle_id not in rebuilt.available_vehicle_ids or vehicle["ngo_id"] != p["ngo_id"]
                or route.ngo_id != p["ngo_id"] or vehicle["depot_location_id"] != depot["location_id"]):
            issue("AUTHORITY", label+": unavailable/foreign vehicle or NGO/depot")
        if (route.start_location_id != depot["location_id"] or route.end_location_id != depot["location_id"]
                or route.start_node_id != depot["road_node_id"] or route.end_node_id != depot["road_node_id"]):
            issue("DEPOT", label)
        if type(route.departure_us) is not int or route.departure_us != 0:
            issue("DEPARTURE", label+": frozen departure is cutoff")
        if not route.stops:
            issue("EMPTY_ROUTE", label)
        current, now, load, route_km = route.start_node_id, Decimal(0), Decimal(0), Decimal(0)
        for stop in route.stops:
            seen.append(stop.task_id)
            if stop.task_id not in admitted:
                issue("AUTHORITY", label+": non-admitted task "+stop.task_id)
                continue
            task = tasks[stop.task_id]
            if (task["ngo_id"] != p["ngo_id"] or task["claim_ngo_id"] != p["ngo_id"]
                    or task["claim_status"] != "ACTIVE" or task["lease_status"] != "ACTIVE"
                    or task["task_status"] != "CONFIRMED" or task["listing_status"] != "CLAIMED"
                    or task["reconciliation_blocked"] or task["has_route_assignment"]):
                issue("AUTHORITY", stop.task_id)
            if (stop.location_id != task["authorized_pickup"]["location_id"]
                    or stop.road_node_id != task["authorized_pickup"]["road_node_id"]
                    or task["pickup"] != task["authorized_pickup"]):
                issue("PICKUP_LOCATION", stop.task_id)
            if task["source_type"] == "HUB_BATCH" and stop.location_id != task["batch"]["hub_id"]:
                issue("HUB_PICKUP", stop.task_id)
            edge = arc(current, stop.road_node_id)
            if edge is None:
                continue
            edge_km, edge_us = edge
            arrival = now+edge_us
            for key in ("arrival_us", "service_start_us", "departure_us"):
                if type(getattr(stop, key)) is not int:
                    issue("SCHEDULE", stop.task_id+": integer microsecond times required")
            if any(type(getattr(stop, key)) is not int for key in ("arrival_us", "service_start_us", "departure_us")):
                continue
            if stop.arrival_us != arrival:
                issue("SCHEDULE", stop.task_id+": arrival disagrees with directed travel")
            start = number(stop.service_start_us)
            if start < arrival or start < timestamp(task["time_window"]["start"]):
                issue("TIME_WINDOW", stop.task_id+": service starts too early")
            service_us = us(task["service_minutes"])
            departure = start+service_us
            if stop.departure_us != departure:
                issue("SERVICE_DURATION", stop.task_id)
            if departure > timestamp(task["time_window"]["end"]):
                issue("TIME_WINDOW", stop.task_id+": service finishes too late")
            if departure+us(p["configuration"]["dispatch_margin_minutes"]) >= timestamp(task["lease_expires_at"]):
                issue("AUTHORITY", stop.task_id+": insufficient lease at service completion")
            if task["listing_expires_at"] and departure >= timestamp(task["listing_expires_at"]):
                issue("AUTHORITY", stop.task_id+": listing expired")
            load += number(task["weight_kg"])
            if load > number(vehicle["capacity_kg"]):
                issue("CAPACITY", stop.task_id)
            if (type(stop.cumulative_load_kg) not in (int, float)
                    or not number(stop.cumulative_load_kg).is_finite()
                    or abs(number(stop.cumulative_load_kg)-load) > Decimal("0.000000001")):
                issue("LOAD_REPORT", stop.task_id)
            route_km += edge_km
            driving += edge_us
            service += service_us
            waiting += max(Decimal(0), start-arrival)
            now, current = departure, stop.road_node_id
        home = arc(current, route.end_node_id)
        if home is not None:
            route_km += home[0]
            driving += home[1]
            now += home[1]
        if type(route.return_us) is not int or route.return_us != now:
            issue("SCHEDULE", label+": return disagrees with travel/service")
        if now > us(vehicle["max_route_minutes"]) or now > us(p["configuration"]["planning_horizon_minutes"]):
            issue("DURATION", label)
        duration += now
        km += route_km
        fixed += number(vehicle["fixed_cost"])
        distance_cost += route_km*number(vehicle["distance_cost_per_km"])
    for vid, count in Counter(used).items():
        if count > 1:
            issue("DUPLICATE_VEHICLE", vid)
    for tid, count in Counter(seen).items():
        if count > 1:
            issue("DUPLICATE_TASK", tid)
    served = admitted & set(seen)
    expected_unserved = admitted-served
    if len(plan.unserved_tasks) != len(set(plan.unserved_tasks)) or set(plan.unserved_tasks) != expected_unserved:
        issue("UNSERVED_ACCOUNTING", "unserved IDs do not complement served admitted tasks")
    reason_ids = [t for t, reason in plan.unserved_reasons if type(reason) is str and reason.strip()]
    if len(reason_ids) != len(set(reason_ids)) or set(reason_ids) != expected_unserved:
        issue("UNSERVED_ACCOUNTING", "missing/duplicate unserved reasons")
    mandatory = tuple(sorted(t for t in expected_unserved if tasks[t]["mandatory"]))
    if mandatory and (plan.feasible or plan.status not in ("INFEASIBLE", "NO_FEASIBLE_PLAN", "ROUTE_UNAVAILABLE", "OPTIMISATION_TIMEOUT")):
        issue("MANDATORY", ",".join(mandatory))
    if plan.feasible and plan.status not in ("COMPLETE", "PARTIAL"):
        issue("STATUS", "failure status cannot claim feasibility")
    if not plan.feasible and plan.status in ("COMPLETE", "PARTIAL"):
        issue("STATUS", "success status cannot claim infeasibility")
    if plan.status == "COMPLETE" and expected_unserved:
        issue("STATUS", "complete status omits admitted tasks")
    if plan.status == "PARTIAL" and not expected_unserved:
        issue("STATUS", "partial status has no unserved tasks")
    pickup_task_count = len(served)
    if plan.optimization_objective == PICKUP_TASK_OBJECTIVE:
        if plan.feasible and plan.pickup_task_objective_value is None:
            issue("OPTIMIZATION_COVERAGE", "feasible pickup-task objective value is missing")
        elif plan.pickup_task_objective_value is not None and plan.pickup_task_objective_value != pickup_task_count:
            issue("OPTIMIZATION_COVERAGE", "reported pickup-task objective disagrees with independently served tasks")
        if not plan.solver_statuses or plan.coverage_optimal != (plan.solver_statuses[0] == "OPTIMAL"):
            issue("OPTIMIZATION_STATUS", "coverage proof flag disagrees with stage-one solver status")
        secondary_proven = len(plan.solver_statuses) > 1 and plan.solver_statuses[1] == "OPTIMAL"
        if plan.secondary_optimal != secondary_proven:
            issue("OPTIMIZATION_STATUS", "distance proof flag disagrees with stage-two solver status")
        expected_optimization_status = (
            "OPTIMAL" if plan.feasible and plan.coverage_optimal and plan.secondary_optimal
            else "FEASIBLE_UNPROVEN" if plan.feasible
            else "INFEASIBLE" if plan.infeasibility_proven
            else "NO_FEASIBLE_SOLUTION"
        )
        if plan.optimization_status != expected_optimization_status:
            issue("OPTIMIZATION_STATUS", "overall optimization status disagrees with feasibility and proof flags")
        if plan.pickup_task_objective_bound is not None:
            bound = number(plan.pickup_task_objective_bound)
            if not bound.is_finite() or bound+Decimal("0.000001") < pickup_task_count:
                issue("OPTIMIZATION_BOUND", "coverage upper bound is below the served pickup-task count")
            if plan.coverage_optimal and abs(bound-pickup_task_count) > Decimal("0.000001"):
                issue("OPTIMIZATION_BOUND", "proven coverage bound does not equal the pickup-task optimum")
        if plan.coverage_optimal and plan.pickup_task_objective_bound is None:
            issue("OPTIMIZATION_BOUND", "proven pickup-task optimum is missing its bound")
        if plan.secondary_objective_scaled is not None:
            reported_distance = number(plan.secondary_objective_scaled)
            actual_distance = km*Decimal(1_000_000)
            if not reported_distance.is_finite() or reported_distance != actual_distance:
                issue("OPTIMIZATION_DISTANCE", "reported secondary distance disagrees with independently summed directed arcs")
        if plan.secondary_bound_scaled is not None:
            distance_bound = number(plan.secondary_bound_scaled)
            actual_distance = km*Decimal(1_000_000)
            if not distance_bound.is_finite() or distance_bound > actual_distance+Decimal("0.000001"):
                issue("OPTIMIZATION_BOUND", "distance lower bound exceeds the independently measured route distance")
            if plan.secondary_optimal and abs(distance_bound-actual_distance) > Decimal("0.000001"):
                issue("OPTIMIZATION_BOUND", "proven distance bound does not equal independently measured route distance")
        if plan.secondary_optimal and plan.secondary_objective_scaled is None:
            issue("OPTIMIZATION_DISTANCE", "proven secondary optimum is missing its objective value")
        if plan.secondary_optimal and plan.secondary_bound_scaled is None:
            issue("OPTIMIZATION_BOUND", "proven secondary optimum is missing its bound")
    counters = Counter(code for code, _ in issues)
    metrics = {"total_travel_km": float(km), "total_route_minutes": float(duration/60_000_000),
               "driving_minutes": float(driving/60_000_000), "service_minutes": float(service/60_000_000),
               "waiting_minutes": float(waiting/60_000_000), "routes_used": len(plan.routes),
               "vehicles_used": len(set(used)), "served_tasks": sorted(served),
               "unserved_tasks": sorted(expected_unserved), "served_count": pickup_task_count,
               "served_pickup_task_count": pickup_task_count,
               "total_travel_distance_scaled": int(km*Decimal(1_000_000)),
               "served_pickup_tasks": sorted(served),
               "unserved_pickup_task_count": len(expected_unserved),
               "unserved_count": len(expected_unserved), "excluded_count": len(rebuilt.excluded_tasks),
               "mandatory_unserved_count": len(mandatory), "fixed_cost": float(fixed),
               "distance_cost": float(distance_cost), "total_cost": float(fixed+distance_cost),
               "weighted_secondary_cost": float(fixed*number(plan.config.fixed_cost_weight)
                                                +distance_cost*number(plan.config.distance_cost_weight)),
               "capacity_violations": counters["CAPACITY"], "time_window_violations": counters["TIME_WINDOW"],
               "duration_violations": counters["DURATION"], "arc_violations": counters["ARC_UNAVAILABLE"],
               "hard_violation_count": len(issues)}
    return ValidationResult(not issues, not issues and plan.feasible, tuple(issues), mandatory, metrics)
