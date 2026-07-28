# FYP – GeoLock Hub System
GeoLock Hub is a mobile application designed to improve donation coordination among NGOs by reducing duplicate pickup claims and improving local resource allocation. The system integrates geolocation-based recommendations, atomic claim locking, and community collection hubs to support efficient donation management.

## Project structure
- 

## Setup
1. Install Dependencies
Install the required Python dependencies using:
pip install -r requirements.txt

## Baseline
This repository contains the baseline methods used for comparison with the proposed GeoLock Hub approach:
1. Coordination Baselines
   - Manual Non-Atomic Claim Processing
   - Atomic Direct Household Pickup 
2. Hub Selection Baselines
   - Random Hub Selection Baseline
   - Nearest Hub Baseline
   - Rule-Based Cost Selection Baseline
3. Pickup Cost Prediction Baseline
   - Rule-Based Cost Estimation

## Running the Baselines
1. Run Individual Baseline
To run each baseline individually:
python baseline/<baselineFileName>.py

Replace <baselineFileName> with the filename of the baseline you want to execute.
For example:
python baseline/nearest_hub_baseline.py

3. Run All Baselines
To run all baseline experiments:
python baseline/run_all_baselines.py

## Reproducibility
The baseline implementations use the benchmark dataset and Python dependencies provided in this repository. The baseline methods are implemented to support reproducible evaluation and comparison with the proposed GeoLock Hub approach.
Detailed methodology, baseline justification, evaluation metrics, experimental procedures, and results are documented in the FYP report.
