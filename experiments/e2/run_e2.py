"""Run all of E2: baseline 1, baseline 2, the proposed method, then the comparison.
Each condition rebuilds the experiment database first, so no condition sees another one's data.
Run from the repository root: python experiments/e2/run_e2.py
"""
import subprocess
import sys
from pathlib import Path

E2 = Path(__file__).resolve().parent

STEPS = ['baseline/source_code/run_non_atomic_claim.py',
         'baseline/source_code/run_protected_claim_without_lease_recovery.py',
         'protected_claim_with_lease_recovery/source_code/run_protected_claim_with_lease_recovery.py',
         'experiment_result/source_code/e2_compare.py']

if __name__ == '__main__':
    for step in STEPS:
        subprocess.run([sys.executable, str(E2 / step)], check=True)
