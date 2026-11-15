"""E2 proposed-method entry point. Use experiments/e2/run_e2.py for the full verified three-method run."""
import sys
from pathlib import Path

HERE = Path(__file__).resolve()
sys.path.insert(0, str(HERE.parents[2] / 'test_harness'))
from e2_harness import main  # noqa: E402

if __name__ == '__main__':
    main('protected_claim_with_lease_recovery', HERE.parents[1] / 'result')
