"""E2 Baseline 1: Non-Atomic Claim.
Rebuilds the experiment database, then runs this condition. The test logic is in test_harness/e2_harness.py.
Run from the repository root: python experiments/e2/baseline/source_code/run_non_atomic_claim.py
"""
import sys
from pathlib import Path

HERE = Path(__file__).resolve()
sys.path.insert(0, str(HERE.parents[2] / 'test_harness'))
from e2_harness import main  # noqa: E402

if __name__ == '__main__':
    main('non_atomic_claim', HERE.parents[1] / '1_non_atomic_claim')
