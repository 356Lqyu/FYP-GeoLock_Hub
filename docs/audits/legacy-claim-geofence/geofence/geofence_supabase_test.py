
import os
import networkx as nx
import psycopg
from dotenv import load_dotenv

load_dotenv()

DATABASE_URL = os.getenv("TEST_DATABASE_URL")

LISTING_ID = "17cdc000-88d7-48ca-9443-b0c8267dfc0a"
MAX_DISTANCE_KM = 20.0

if not DATABASE_URL:
    raise RuntimeError("TEST_DATABASE_URL is missing from .env")

# Synthetic road network used in Phase 4 Step 4.
graph = nx.Graph()

graph.add_weighted_edges_from([
    ("NGO_NODE_01", "PICKUP_NODE_01", 15.0),
    ("NGO_NODE_02", "PICKUP_NODE_01", 20.0),
    ("NGO_NODE_03", "PICKUP_NODE_01", 25.0),
])

graph.add_node("ISOLATED_NODE")


def calculate_eligibility(ngo_node, pickup_node):
    if not ngo_node or not pickup_node:
        return "INELIGIBLE", None, "Missing road node"

    if ngo_node not in graph or pickup_node not in graph:
        return "INELIGIBLE", None, "Unknown road node"

    try:
        distance = nx.shortest_path_length(
            graph,
            source=ngo_node,
            target=pickup_node,
            weight="weight"
        )
    except nx.NetworkXNoPath:
        return "INELIGIBLE", None, "No route exists"

    if distance <= MAX_DISTANCE_KM:
        return "ELIGIBLE", distance, "Within 20 km"

    return "INELIGIBLE", distance, "Exceeds 20 km"


with psycopg.connect(DATABASE_URL) as conn:
    with conn.cursor() as cur:

        # Read the actual listing.
        cur.execute(
            """
            SELECT
                listing_id,
                pickup_road_node_id,
                listing_status,
                listing_version
            FROM public.listings
            WHERE listing_id = %s::uuid
            """,
            (LISTING_ID,)
        )

        listing = cur.fetchone()

        if not listing:
            raise RuntimeError("Test listing not found")

        listing_id, pickup_node, status, version = listing

        if status != "AVAILABLE":
            raise RuntimeError(
                f"Expected AVAILABLE listing, found {status}"
            )

        # Read NGO profiles from Supabase.
        cur.execute(
            """
            SELECT
                u.email,
                np.road_node_id,
                np.service_radius_km,
                np.active_flag
            FROM public.ngo_profiles np
            JOIN auth.users u
                ON u.id = np.user_id
            WHERE u.email IN (
                'ngo1@test.com',
                'ngo2@test.com',
                'ngo3@test.com'
            )
            ORDER BY u.email
            """
        )

        ngos = cur.fetchall()


expected = {
    "ngo1@test.com": "ELIGIBLE",
    "ngo2@test.com": "ELIGIBLE",
    "ngo3@test.com": "INELIGIBLE",
}

print("\nPHASE 4 - SUPABASE GEOFENCE INTEGRATION")
print("=" * 75)
print(f"Listing: {listing_id}")
print(f"Pickup node: {pickup_node}")
print(f"Listing version: {version}")
print("=" * 75)

passed = 0

for email, ngo_node, service_radius, active in ngos:

    if not active:
        outcome, distance, reason = (
            "INELIGIBLE", None, "Inactive NGO"
        )
    else:
        outcome, distance, reason = calculate_eligibility(
            ngo_node,
            pickup_node
        )

        # Enforce both the fixed 20 km limit
        # and the NGO's configured service radius.
        if (
            outcome == "ELIGIBLE"
            and distance is not None
            and (
                service_radius is None
                or distance > float(service_radius)
            )
        ):
            outcome = "INELIGIBLE"
            reason = "Outside NGO service radius"

    result = (
        "PASS"
        if outcome == expected[email]
        else "FAIL"
    )

    if result == "PASS":
        passed += 1

    distance_text = (
        f"{distance:.2f} km"
        if distance is not None
        else "N/A"
    )

    print(
        f"{email}: "
        f"{ngo_node} -> {pickup_node} | "
        f"{distance_text} | "
        f"{outcome} | {result}"
    )

print("=" * 75)
print(f"Total Passed: {passed}/{len(expected)}")

assert len(ngos) == len(expected), "Missing NGO profiles"
assert passed == len(expected), "Geofence integration test failed"
