import os                      # Used to check whether the road network file already exists
import pandas as pd            # Used to read and write Excel files
import osmnx as ox             # Used to download and process OpenStreetMap road network
import networkx as nx          # Used to calculate shortest path on the road network

# ==========================================================
# Nearest Hub Baseline (Road Network Version)
# GeoLock Hub Benchmark Dataset
# ==========================================================

# Input benchmark dataset
FILE = "Benchmark Dataset.xlsx"

# Local copy of Kuala Lumpur road network
GRAPH_FILE = "kl_drive.graphml"

# ----------------------------------------------------------
# Load Benchmark Dataset
# ----------------------------------------------------------

donor_df = pd.read_excel(FILE, sheet_name="Donor")
hub_df = pd.read_excel(FILE, sheet_name="Community Hub")
donation_df = pd.read_excel(FILE, sheet_name="Donation")

# ----------------------------------------------------------
# Load or Download Kuala Lumpur Road Network
# ----------------------------------------------------------

# Check whether the road network has already been downloaded
if os.path.exists(GRAPH_FILE):

    # Load the existing road network from local storage
    print("Loading cached Kuala Lumpur road network...")
    G = ox.load_graphml(GRAPH_FILE)

else:

    # Download Kuala Lumpur driving road network
    print("Downloading Kuala Lumpur road network...")

    G = ox.graph_from_place(
        "Kuala Lumpur, Malaysia",
        network_type="drive"      # Download only roads accessible by vehicles
    )

    # Save road network for future use
    ox.save_graphml(G, GRAPH_FILE)

    print(f"Road network saved as {GRAPH_FILE}")

print("Road network ready.\n")

# ----------------------------------------------------------
# Find nearest road node for every donor
# ----------------------------------------------------------

print("Finding nearest road node for donors...")

# Convert each donor's latitude and longitude
# into the nearest OpenStreetMap road node
donor_df["road_node"] = donor_df.apply(
    lambda row: ox.distance.nearest_nodes(
        G,
        X=row["longitude"],
        Y=row["latitude"]
    ),
    axis=1
)

# ----------------------------------------------------------
# Find nearest road node for every community hub
# ----------------------------------------------------------

print("Finding nearest road node for community hubs...")

# Convert every community hub into the nearest
# OpenStreetMap road node
hub_df["road_node"] = hub_df.apply(
    lambda row: ox.distance.nearest_nodes(
        G,
        X=row["longitude"],
        Y=row["latitude"]
    ),
    axis=1
)

print("Road nodes assigned.\n")

# ----------------------------------------------------------
# Nearest Hub Baseline
# ----------------------------------------------------------

# Store recommendation results
results = []

print("Calculating nearest hub using road-network distance...")

# Process every donation
for _, donation in donation_df.iterrows():

    # Find the donor who made the current donation
    donor = donor_df[
        donor_df["donor_id"] == donation["donor_id"]
    ].iloc[0]

    # Get donor's nearest road node
    donor_node = donor["road_node"]

    # Initialise nearest hub
    nearest_hub = None

    # Initialise shortest distance with infinity
    nearest_distance = float("inf")

    # Compare donor with every community hub
    for _, hub in hub_df.iterrows():

        # Get hub's nearest road node
        hub_node = hub["road_node"]

        try:

            # --------------------------------------------------
            # Calculate shortest driving distance
            # --------------------------------------------------
            # NetworkX finds the shortest path between
            # donor and hub on the OpenStreetMap road network.
            #
            # weight="length" means road length (metres)
            # is used when calculating the shortest route.
            # --------------------------------------------------

            road_distance = nx.shortest_path_length(
                G,
                source=donor_node,
                target=hub_node,
                weight="length"
            )

            # Convert metres into kilometres
            road_distance = road_distance / 1000

            # Keep the hub with the shortest distance
            if road_distance < nearest_distance:
                nearest_distance = road_distance
                nearest_hub = hub

        except nx.NetworkXNoPath:

            # Skip this hub if no drivable path exists
            continue

    # ------------------------------------------------------
    # Save recommendation result
    # ------------------------------------------------------

    if nearest_hub is not None:

        results.append({
            "donation_id": donation["donation_id"],
            "donor_id": donor["donor_id"],
            "recommended_hub": nearest_hub["hub_id"],
            "hub_name": nearest_hub["hub_name"],
            "road_distance_km": round(nearest_distance, 3)
        })

# ----------------------------------------------------------
# Save Results
# ----------------------------------------------------------

# Convert result list into DataFrame
result_df = pd.DataFrame(results)

print("\nNearest Hub Baseline Results:")

print(result_df)

# Output Excel file
OUTPUT_FILE = "nearest_hub_road_network_results.xlsx"

result_df.to_excel(
    OUTPUT_FILE,
    index=False
)

print("\n==========================================")
print("Baseline completed successfully.")
print(f"Results saved as: {OUTPUT_FILE}")
print("==========================================")