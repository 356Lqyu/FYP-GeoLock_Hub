"""E2 Baseline 2: Protected Claim without Lease Recovery.
Rebuilds the experiment database, then runs this condition. The test logic is in test_harness/e2_harness.py.
Run from the repository root: python experiments/e2/baseline/source_code/run_protected_claim_without_lease_recovery.py
"""
import sys
from pathlib import Path

HERE = Path(__file__).resolve()
sys.path.insert(0, str(HERE.parents[2] / 'test_harness'))
from e2_harness import main  # noqa: E402

if __name__ == '__main__':
    main('protected_claim_without_lease_recovery', HERE.parents[1] / '2_protected_claim_without_lease_recovery')
