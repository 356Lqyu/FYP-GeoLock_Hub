"""Generate explicitly synthetic fixtures from a documented directed line graph.

No live records, operational road nodes, benchmark vehicles, or credentials are
imported. Unique line-graph paths are summed, not estimated from coordinates.
"""

from copy import deepcopy
import hashlib
import json
from pathlib import Path
import sys

from .contract import VERSION

EXAMPLES = Path(__file__).with_name("examples")
NODES = ["TOY-DEPOT", "TOY-DONOR", "TOY-HUB"]
# Directed edge -> (km, minutes). Unique paths between line-graph vertices.
EDGES = {(0, 1): (2.0, 4.0), (1, 0): (2.5, 5.0),
         (1, 2): (3.0, 6.0), (2, 1): (3.5, 7.0)}


def token(label):
    return hashlib.sha256(("SYNTHETIC_FIXTURE_ONLY:"+label).encode()).hexdigest()


def location(identity, node, offset):
    return {"location_id": identity, "road_node_id": node,
            "network_snapshot_id": "SYNTHETIC-LINE-v1",
            "latitude": 3.0+offset, "longitude": 101.0+offset,
            "state_token": token(identity)}


def task(identity, source_type, pickup, weight):
    donations = [{"donation_id": identity+f"-DONATION-{i}", "donation_status": "CLAIMED",
                  "state_token": token(identity+f"-DONATION-{i}")} for i in range(3 if source_type == "HUB_BATCH" else 1)]
    return {"task_id": identity, "ngo_id": "TOY-NGO", "claim_id": identity+"-CLAIM",
            "claim_ngo_id": "TOY-NGO", "lease_id": identity+"-LEASE", "listing_id": identity+"-LISTING",
            "source_type": source_type, "task_status": "CONFIRMED", "claim_status": "ACTIVE",
            "lease_status": "ACTIVE", "listing_status": "CLAIMED", "created_at": "2026-10-24T00:01:00Z",
            "lease_issued_at": "2026-10-24T00:00:00Z", "lease_expires_at": "2026-10-24T06:00:00Z",
            "listing_expires_at": None, "listing_version": 2,
            "task_state_token": token(identity+"task"), "claim_state_token": token(identity+"claim"),
            "lease_state_token": token(identity+"lease"), "pickup": deepcopy(pickup),
            "authorized_pickup": deepcopy(pickup), "weight_kg": weight, "listing_weight_kg": weight,
            "time_window": {"start": "2026-10-24T00:00:00Z", "end": "2026-10-24T05:00:00Z",
                            "provenance": "Synthetic fixture window; not an operational default"},
            "service_minutes": 10, "mandatory": True, "has_route_assignment": False,
            "reconciliation_blocked": False, "donations": donations,
            "batch": None if source_type == "DIRECT_DONATION" else
            {"batch_id": "TOY-BATCH", "hub_id": pickup["location_id"], "batch_version": 1,
             "batch_status": "PUBLISHED", "inventory_status": "BATCHED", "member_count": 3,
             "state_token": token("batch")}}


def build_mixed():
    distances, minutes = [], []
    for i in range(3):
        drow, trow = [], []
        for j in range(3):
            step = 1 if j >= i else -1
            edges = [EDGES[(k, k+step)] for k in range(i, j, step)]
            drow.append(sum(edge[0] for edge in edges))
            trow.append(sum(edge[1] for edge in edges))
        distances.append(drow)
        minutes.append(trow)
    depot = location("TOY-NGO-DEPOT", NODES[0], 0)
    return {"schema_version": VERSION, "planning_run_id": "TOY-RUN-MIXED-v1",
            "scenario_id": "SYNTHETIC-MIXED-v1",
            "source": {"kind": "SYNTHETIC_BENCHMARK", "project_ref": None,
                       "provenance": "Hand-defined directed line graph; all entities fictional",
                       "evidence_ref": "backend/routing/README.md#synthetic-fixtures"},
            "ngo_id": "TOY-NGO", "ngo_active": True, "ngo_location_generation": 1,
            "ngo_location_verified_at": "2026-10-23T00:00:00Z", "cutoff": "2026-10-24T00:05:00Z",
            "configuration": {"version": "TOY-CONFIG-v1", "currency": "SYNTHETIC_COST_UNIT",
                              "planning_horizon_minutes": 240, "dispatch_margin_minutes": 10,
                              "objective": "MIN_UNSERVED_THEN_FIXED_PLUS_DISTANCE_COST",
                              "time_window_policy": "SERVICE_COMPLETION_WITHIN_WINDOW"},
            "depot": depot, "route_start_location_id": depot["location_id"], "route_end_location_id": depot["location_id"],
            "vehicles": [{"vehicle_id": "TOY-VEHICLE-"+str(i), "ngo_id": "TOY-NGO", "vehicle_type": "SYNTHETIC_VAN",
                          "capacity_kg": capacity, "active": True, "available_for_planning": True,
                          "fixed_cost": fixed, "distance_cost_per_km": cost, "max_route_minutes": 240,
                          "depot_location_id": depot["location_id"], "state_token": token("vehicle"+str(i))}
                         for i, capacity, fixed, cost in [(1, 40, 5, 1), (2, 80, 8, 1.2)]],
            "tasks": [task("TOY-DIRECT", "DIRECT_DONATION", location("TOY-DONOR-LOCATION", NODES[1], .01), 30),
                      task("TOY-HUB-TASK", "HUB_BATCH", location("TOY-HUB", NODES[2], .02), 12)],
            "matrix": {"matrix_id": "TOY-DIRECTED-LINE-v1", "version": "1", "network_snapshot_id": "SYNTHETIC-LINE-v1",
                       "source_kind": "SYNTHETIC_BENCHMARK", "provenance": "generate_examples.EDGES; unique directed line paths",
                       "method": "Sum km and minutes along the same unique directed edge sequence",
                       "edge_speed_profile": "Fixed edge pairs; forward/reverse modeled speeds are 30 km/h",
                       "path_policy": "DIRECTED_SHORTEST_DISTANCE_WITH_TIME_ON_SAME_PATH",
                       "unavailable_policy": "FAIL_SCENARIO", "node_order": NODES.copy(),
                       "distance_km": distances, "travel_minutes": minutes,
                       "arc_status": [["AVAILABLE"]*3 for _ in range(3)]},
            "solver": {"engine": "OR_TOOLS", "version": "NOT_INSTALLED_PHASE_A", "time_limit_seconds": 30,
                       "workers": 1, "seed": 42, "first_solution": "PATH_CHEAPEST_ARC",
                       "local_search": "GUIDED_LOCAL_SEARCH", "tie_break": "TASK_ID_THEN_VEHICLE_ID",
                       "timeout_policy": "VALIDATED_INCUMBENT_ONLY"}}


def examples():
    mixed = build_mixed()
    result = {"mixed": mixed}
    for name in ("direct_only", "hub_only", "no_vehicles", "expired_claim", "unreachable", "missing_edge", "reconciliation", "no_tasks"):
        p = deepcopy(mixed)
        p["planning_run_id"] = "TOY-RUN-"+name
        p["scenario_id"] = "SYNTHETIC-"+name
        if name == "direct_only": p["tasks"] = p["tasks"][:1]
        elif name == "hub_only": p["tasks"] = p["tasks"][1:]
        elif name == "no_vehicles": p["vehicles"] = []
        elif name == "no_tasks": p["tasks"] = []
        elif name == "expired_claim":
            p["tasks"] = p["tasks"][:1]
            p["tasks"][0]["lease_expires_at"] = p["cutoff"]
        elif name == "reconciliation":
            p["tasks"] = p["tasks"][:1]
            p["tasks"][0]["claim_status"] = "RECONCILIATION_REQUIRED"
            p["tasks"][0]["lease_status"] = "RECONCILIATION_REQUIRED"
            p["tasks"][0]["reconciliation_blocked"] = True
        elif name in ("unreachable", "missing_edge"):
            # Disconnect the hub; missing acquisition data is a separate case.
            pairs = [(0, 2), (1, 2), (2, 0), (2, 1)] if name == "unreachable" else [(0, 2)]
            for i, j in pairs:
                p["matrix"]["arc_status"][i][j] = "UNREACHABLE" if name == "unreachable" else "MISSING"
                p["matrix"]["distance_km"][i][j] = None
                p["matrix"]["travel_minutes"][i][j] = None
            if name == "unreachable":
                graph = "SYNTHETIC-LINE-DISCONNECTED-v1"
                p["matrix"]["network_snapshot_id"] = graph
                p["matrix"]["matrix_id"] = "TOY-DISCONNECTED-v1"
                p["matrix"]["provenance"] += "; remove edges (1,2) and (2,1); hub is isolated"
                p["depot"]["network_snapshot_id"] = graph
                for t in p["tasks"]:
                    t["pickup"]["network_snapshot_id"] = graph
                    t["authorized_pickup"]["network_snapshot_id"] = graph
            else:
                p["matrix"]["provenance"] += "; deliberately missing acquired OD pair (0,2)"
        result[name] = p
    return result


def main():
    check = "--check" in sys.argv
    for name, payload in examples().items():
        text = json.dumps(payload, indent=2, ensure_ascii=True, allow_nan=False)+"\n"
        path = EXAMPLES/(name+".json")
        if check:
            if path.read_text(encoding="utf-8") != text:
                raise SystemExit(f"Fixture differs from deterministic generator: {path}")
        else:
            EXAMPLES.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
    print(f"{'Verified' if check else 'Generated'} {len(examples())} explicitly synthetic scenarios")


if __name__ == "__main__":
    main()
