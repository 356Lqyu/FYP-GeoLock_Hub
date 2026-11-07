"""Reproducible SYNTHETIC edge cases derived from Phase A's toy line graph.

Never imports live rows. Phase A fixtures are read unchanged. Scenario mutations
and their purposes are recorded in provenance, not inferred road measurements.
"""

from copy import deepcopy
from ..contract import freeze_scenario, load_scenario
from ..generate_examples import build_mixed, EXAMPLES


def edge_payloads():
    result = {}

    def new(name):
        p = build_mixed()
        p["scenario_id"] = "SYNTHETIC-PHASE-B-"+name
        p["planning_run_id"] = "TOY-PHASE-B-RUN-"+name
        p["source"]["provenance"] += "; Phase B edge case: "+name
        return p

    p = new("cost_tradeoff")
    template = p["vehicles"][0]
    p["vehicles"] = []
    for i, capacity, fixed in [(1, 50, 100), (2, 35, 1), (3, 20, 1)]:
        v = deepcopy(template)
        v.update(vehicle_id=f"TOY-TRADEOFF-VEHICLE-{i}", capacity_kg=capacity,
                 fixed_cost=fixed, distance_cost_per_km=1)
        p["vehicles"].append(v)
    result["cost_tradeoff"] = p

    p = new("urgent_hub_optional")
    p["vehicles"] = p["vehicles"][:1]
    p["vehicles"][0]["capacity_kg"] = 100
    for t in p["tasks"]:
        t["mandatory"] = False
    p["tasks"][1]["created_at"] = "2026-10-24T00:02:00Z"
    p["tasks"][1]["time_window"]["end"] = "2026-10-24T00:25:00Z"
    result["urgent_hub_optional"] = p

    p = new("capacity_infeasible")
    p["tasks"][0]["weight_kg"] = p["tasks"][0]["listing_weight_kg"] = 100
    result["capacity_infeasible"] = p

    p = new("duration_infeasible")
    for v in p["vehicles"]:
        v["max_route_minutes"] = 10
    result["duration_infeasible"] = p

    p = new("window_infeasible")
    p["tasks"] = p["tasks"][:1]
    p["tasks"][0]["time_window"]["end"] = "2026-10-24T00:15:00Z"
    result["window_infeasible"] = p

    p = new("waiting")
    p["tasks"] = p["tasks"][:1]
    p["tasks"][0]["time_window"]["start"] = "2026-10-24T00:35:00Z"
    result["waiting"] = p

    p = new("exact_duration")
    p["tasks"] = p["tasks"][:1]
    p["vehicles"] = p["vehicles"][:1]
    p["vehicles"][0]["max_route_minutes"] = 19
    result["exact_duration"] = p

    p = new("colocated_tasks")
    for key in ("pickup", "authorized_pickup"):
        p["tasks"][1][key]["road_node_id"] = p["tasks"][0][key]["road_node_id"]
    result["colocated_tasks"] = p

    p = new("primary_over_cost")
    for t in p["tasks"]:
        t["mandatory"] = False
    p["vehicles"][0].update(capacity_kg=50, fixed_cost=1_000_000, distance_cost_per_km=1)
    p["vehicles"][1].update(capacity_kg=30, fixed_cost=1, distance_cost_per_km=1)
    result["primary_over_cost"] = p

    # Read the already versioned genuinely disconnected Phase A graph unchanged.
    p = load_scenario(EXAMPLES/"unreachable.json").to_dict()["input"]
    p["scenario_id"] = "SYNTHETIC-PHASE-B-unreachable_forbid"
    p["planning_run_id"] = "TOY-PHASE-B-RUN-unreachable_forbid"
    p["matrix"]["unavailable_policy"] = "FORBID_ARC"
    result["unreachable_forbid"] = p
    p = deepcopy(p)
    p["scenario_id"] = "SYNTHETIC-PHASE-B-unreachable_optional"
    p["planning_run_id"] = "TOY-PHASE-B-RUN-unreachable_optional"
    for t in p["tasks"]:
        t["mandatory"] = False
    result["unreachable_optional"] = p

    p = new("no_return_arc")
    graph = "SYNTHETIC-LINE-NO-RETURN-v1"
    p["matrix"].update(network_snapshot_id=graph, matrix_id="TOY-NO-RETURN-v1", unavailable_policy="FORBID_ARC")
    p["matrix"]["provenance"] += "; remove edge (1,0): neither pickup can return to depot"
    p["depot"]["network_snapshot_id"] = graph
    for t in p["tasks"]:
        t["pickup"]["network_snapshot_id"] = graph
        t["authorized_pickup"]["network_snapshot_id"] = graph
    for i in (1, 2):
        p["matrix"]["arc_status"][i][0] = "UNREACHABLE"
        p["matrix"]["distance_km"][i][0] = p["matrix"]["travel_minutes"][i][0] = None
    result["no_return_arc"] = p
    return result


def scenarios():
    originals = {"phase_a/"+p.stem: load_scenario(p) for p in sorted(EXAMPLES.glob("*.json"))}
    added = {"phase_b/"+name: freeze_scenario(p) for name, p in edge_payloads().items()}
    return originals | added
