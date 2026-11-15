"""E2 baseline entry point. Run through experiments/e2/run_e2.py for target checks and a unique run folder."""
import sys
from pathlib import Path

HERE = Path(__file__).resolve()
sys.path.insert(0, str(HERE.parents[2] / 'test_harness'))
from e2_harness import main  # noqa: E402

if __name__ == '__main__':
    main('protected_claim_without_lease_recovery', HERE.parents[1] / '2_protected_claim_without_lease_recovery')
