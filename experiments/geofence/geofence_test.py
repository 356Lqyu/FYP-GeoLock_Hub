
import networkx as nx

# ==========================================
# PHASE 4: SYNTHETIC ROAD-NETWORK GEOFENCE
# ==========================================

MAX_DISTANCE_KM = 20.0

# Undirected synthetic road graph.
# Edge weights represent road lengths in kilometres.
G = nx.Graph()

G.add_weighted_edges_from([
    ("NGO_NODE_01", "PICKUP_NODE_01", 15.0),
    ("NGO_NODE_02", "PICKUP_NODE_01", 20.0),
    ("NGO_NODE_03", "PICKUP_NODE_01", 25.0),
])

# Isolated node for unreachable-route testing.
G.add_node("ISOLATED_NODE")


def check_geofence(ngo_node, pickup_node):
    if ngo_node not in G:
        return "INELIGIBLE", None, "Unknown NGO node"

    if pickup_node not in G:
        return "INELIGIBLE", None, "Unknown pickup node"

    try:
        distance_km = nx.shortest_path_length(
            G,
            source=ngo_node,
            target=pickup_node,
            weight="weight"
        )

    except nx.NetworkXNoPath:
        return "INELIGIBLE", None, "No road route exists"

    if distance_km <= MAX_DISTANCE_KM:
        return "ELIGIBLE", distance_km, "Within 20 km"

    return "INELIGIBLE", distance_km, "Exceeds 20 km"


test_cases = [
    ("G1", "NGO_NODE_01", "PICKUP_NODE_01", "ELIGIBLE"),
    ("G2", "NGO_NODE_02", "PICKUP_NODE_01", "ELIGIBLE"),
    ("G3", "NGO_NODE_03", "PICKUP_NODE_01", "INELIGIBLE"),
    ("G4", "ISOLATED_NODE", "PICKUP_NODE_01", "INELIGIBLE"),
    ("G5", "UNKNOWN_NODE", "PICKUP_NODE_01", "INELIGIBLE"),
]

print("\nPHASE 4 - ROAD-NETWORK GEOFENCE TEST")
print("=" * 78)

passed = 0

for test_id, ngo_node, pickup_node, expected in test_cases:
    outcome, distance, reason = check_geofence(
        ngo_node,
        pickup_node
    )

    status = "PASS" if outcome == expected else "FAIL"

    if status == "PASS":
        passed += 1

    distance_display = (
        f"{distance:.2f} km"
        if distance is not None
        else "N/A"
    )

    print(
        f"{test_id}: "
        f"{ngo_node} -> {pickup_node} | "
        f"Distance: {distance_display} | "
        f"Result: {outcome} | "
        f"{status}"
    )

print("=" * 78)
print(f"Total Passed: {passed}/{len(test_cases)}")

assert passed == len(test_cases), "Some geofence tests failed"
