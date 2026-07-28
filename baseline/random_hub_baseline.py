import random                  # Used to randomly select a community hub
import pandas as pd            # Used to read and write Excel files

# ==========================================================
# Random Hub Selection Baseline
# GeoLock Hub Benchmark Dataset
# ==========================================================

# Input benchmark dataset
FILE = "Benchmark Dataset.xlsx"

# ----------------------------------------------------------
# Load Benchmark Dataset
# ----------------------------------------------------------

donor_df = pd.read_excel(
    FILE,
    sheet_name="Donor"
)

hub_df = pd.read_excel(
    FILE,
    sheet_name="Community Hub"
)

donation_df = pd.read_excel(
    FILE,
    sheet_name="Donation"
)

print("Benchmark dataset loaded successfully.\n")

# ----------------------------------------------------------
# Set Random Seed
# ----------------------------------------------------------

# A fixed seed ensures that the same random hubs
# are selected every time the experiment is executed.
RANDOM_SEED = 42

random.seed(RANDOM_SEED)

# ----------------------------------------------------------
# Random Hub Selection Baseline
# ----------------------------------------------------------

# Store recommendation results
results = []

print("Performing random hub selection...")

# Process every donation
for _, donation in donation_df.iterrows():

    # Find the donor who made the current donation
    donor = donor_df[
        donor_df["donor_id"] == donation["donor_id"]
    ].iloc[0]

    # ------------------------------------------------------
    # Randomly select one community hub
    # ------------------------------------------------------

    # Randomly choose one hub from all available
    # community hubs in the benchmark dataset.
    random_hub = hub_df.sample(
        n=1,
        random_state=random.randint(0, 999999)
    ).iloc[0]

    # ------------------------------------------------------
    # Save recommendation result
    # ------------------------------------------------------

    results.append({
        "donation_id": donation["donation_id"],
        "donor_id": donor["donor_id"],
        "recommended_hub": random_hub["hub_id"],
        "hub_name": random_hub["hub_name"]
    })

# ----------------------------------------------------------
# Save Results
# ----------------------------------------------------------

# Convert result list into DataFrame
result_df = pd.DataFrame(results)

print("\nRandom Hub Selection Baseline Results:")

print(result_df)

# Output Excel file
OUTPUT_FILE = "random_hub_selection_results.xlsx"

result_df.to_excel(
    OUTPUT_FILE,
    index=False
)

print("\n==========================================")
print("Random Hub Baseline completed successfully.")
print(f"Results saved as: {OUTPUT_FILE}")
print("==========================================")