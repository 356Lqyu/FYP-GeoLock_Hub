"""Solver-side problem view and schedule construction; validator does not import it."""

from datetime import datetime
from decimal import Decimal
import re
from .models import ExecutionConfig, Plan, Route, Stop
from ..contract import freeze_scenario

TIME_SCALE = 60_000_000  # microseconds per minute
MASS_SCALE = 1_000_000
DISTANCE_SCALE = 1_000_000  # Input km: one tick is one millimetre.
COST_SCALE = 1_000_000
SAFE_INTEGER = 2**53 - 1  # exact reporting as well as conservative CP-SAT bounds


def exact(value, scale=1):
    d = Decimal(str(value)) * scale
    if not d.is_finite() or d != d.to_integral_value() or abs(d) > SAFE_INTEGER:
        raise ValueError(f"UNSUPPORTED_PRECISION_OR_RANGE: {value} at scale {scale}")
    return int(d)


def offset(value, cutoff):
    delta = datetime.fromisoformat(value.replace("Z", "+00:00")) - cutoff
    result = (delta.days * 86400 + delta.seconds) * 1_000_000 + delta.microseconds
    if abs(result) > SAFE_INTEGER:
        raise ValueError("UNSUPPORTED_TIMESTAMP_RANGE")
    return result


class Problem:
    def __init__(self, snapshot):
        rebuilt = freeze_scenario(snapshot.to_dict()["input"])
        if rebuilt != snapshot:
            raise ValueError("SNAPSHOT_INTEGRITY_FAILURE")
        self.snapshot = snapshot
        self.p = snapshot.to_dict()["input"]
        times = [self.p["cutoff"], self.p["ngo_location_verified_at"]]
        for task in self.p["tasks"]:
            times.extend(task[k] for k in ("created_at", "lease_issued_at", "lease_expires_at", "listing_expires_at") if task[k] is not None)
            times.extend((task["time_window"]["start"], task["time_window"]["end"]))
        for timestamp in times:
            if any(len(part) > 6 and any(c != "0" for c in part[6:]) for part in re.findall(r"[.,]([0-9]+)", timestamp)):
                raise ValueError("UNSUPPORTED_TIMESTAMP_PRECISION: sub-microsecond timestamp")
        self.cutoff = datetime.fromisoformat(self.p["cutoff"].replace("Z", "+00:00"))
        self.tasks = {t["task_id"]: t for t in self.p["tasks"] if t["task_id"] in snapshot.admitted_task_ids}
        self.fleet = {v["vehicle_id"]: v for v in self.p["vehicles"] if v["vehicle_id"] in snapshot.available_vehicle_ids}
        self.matrix = self.p["matrix"]
        self.node_index = {n: i for i, n in enumerate(self.matrix["node_order"])}
        self.depot = self.p["depot"]["road_node_id"]
        self.horizon = exact(self.p["configuration"]["planning_horizon_minutes"], TIME_SCALE)
        self.margin = exact(self.p["configuration"]["dispatch_margin_minutes"], TIME_SCALE)

    def arc(self, source, target):
        i, j = self.node_index[source], self.node_index[target]
        if self.matrix["arc_status"][i][j] != "AVAILABLE":
            return None
        return (exact(self.matrix["distance_km"][i][j], DISTANCE_SCALE),
                exact(self.matrix["travel_minutes"][i][j], TIME_SCALE))

    def schedule(self, vehicle_id, ids):
        vehicle = self.fleet[vehicle_id]
        current, now, load = self.depot, 0, 0
        stops = []
        for tid in ids:
            task = self.tasks[tid]
            node = task["pickup"]["road_node_id"]
            arc = self.arc(current, node)
            if arc is None:
                return None, "ROUTE_UNAVAILABLE"
            arrival = now + arc[1]
            start = max(arrival, offset(task["time_window"]["start"], self.cutoff))
            now = start + exact(task["service_minutes"], TIME_SCALE)
            if now > offset(task["time_window"]["end"], self.cutoff):
                return None, "TIME_WINDOW"
            if now + self.margin >= offset(task["lease_expires_at"], self.cutoff):
                return None, "LEASE_EXPIRES"
            load += exact(task["weight_kg"], MASS_SCALE)
            if load > exact(vehicle["capacity_kg"], MASS_SCALE):
                return None, "CAPACITY"
            stops.append(Stop(tid, task["pickup"]["location_id"], node, arrival, start, now, load/MASS_SCALE))
            current = node
        home = self.arc(current, self.depot)
        if home is None:
            return None, "ROUTE_UNAVAILABLE"
        returned = now + home[1]
        if returned > min(self.horizon, exact(vehicle["max_route_minutes"], TIME_SCALE)):
            return None, "MAX_DURATION"
        d = self.p["depot"]
        return Route(vehicle_id, self.p["ngo_id"], d["location_id"], self.depot,
                     d["location_id"], self.depot, 0, tuple(stops), returned), None

    def finish(self, method, routes, config, *, status=None, reasons=None, **metadata):
        served = {stop.task_id for route in routes for stop in route.stops}
        unserved = tuple(sorted(set(self.tasks)-served))
        mandatory_missed = any(self.tasks[t]["mandatory"] for t in unserved)
        if status is None:
            status = "INFEASIBLE" if mandatory_missed else "PARTIAL" if unserved else "COMPLETE"
        feasible = status in ("COMPLETE", "PARTIAL") and not mandatory_missed
        reasons = reasons or {}
        return Plan(method, self.snapshot.sha256, self.snapshot.matrix_sha256,
                    tuple(routes), unserved, tuple((t, reasons.get(t, status)) for t in unserved),
                    status, feasible, config, **metadata)

    def blocked(self, method, config):
        if self.snapshot.readiness != "READY_FOR_PLANNING":
            return self.finish(method, (), config, status=self.snapshot.readiness)
        return None
