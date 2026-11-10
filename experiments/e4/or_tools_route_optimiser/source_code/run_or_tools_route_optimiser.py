"""E4 proposed method: the app's OR-Tools route optimiser, used unchanged.

Calls backend.routing.phase_b.optimizers.proposed, the same function the routing worker uses
(Google OR-Tools CP-SAT in backend/routing/optimizers/cp_sat.py). It serves as many pickups as
possible, then picks the shortest total road distance.
Run from the repository root: python experiments/e4/or_tools_route_optimiser/source_code/run_or_tools_route_optimiser.py
"""
import sys
from pathlib import Path
HERE = Path(__file__).resolve()
sys.path.insert(0, str(HERE.parents[2] / 'test_harness'))
from e4_shared import run_and_save  # noqa: E402

if __name__ == '__main__':
    run_and_save('or_tools_route_optimiser', HERE.parents[1] / 'result')
