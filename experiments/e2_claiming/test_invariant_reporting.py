import csv
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from experiments.e2_claiming import report
from experiments.e2_claiming.e2_runner import at_most_one_owner_preserved


class OwnershipInvariantTests(unittest.TestCase):
    def test_non_atomic_duplicate_is_reported_as_invariant_violation(self):
        state = {"active_owners": 2}
        self.assertFalse(at_most_one_owner_preserved(state))

    def test_protected_single_owner_preserves_invariant(self):
        state = {"active_owners": 1}
        self.assertTrue(at_most_one_owner_preserved(state))

    def test_report_counts_baseline_violation_without_rejecting_duplicate_outcome(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            non_atomic = root / "non-atomic"
            protected = root / "protected"
            lease = root / "lease"
            out = root / "report"
            for folder, condition, row in (
                (non_atomic, "non-atomic", {"conflicting_committed_ownership": True,
                                             "at_most_one_owner_preserved": False}),
                (protected, "protected", {"conflicting_committed_ownership": False,
                                           "at_most_one_owner_preserved": True}),
            ):
                folder.mkdir()
                (folder / "run_info.json").write_text(json.dumps({"run_kind": "contention", "status": "COMPLETE"}))
                (folder / "trials.json").write_text(json.dumps([{
                    "concurrency": 2, "trial_number": 1, "completed": True, **row
                }]))
                requests = ([
                    {"concurrency": 2, "outcome": "ERROR", "reason_code": "CLAIM_TRANSACTION_ROLLED_BACK", "latency_ms": 10},
                    {"concurrency": 2, "outcome": "TIMEOUT", "timed_out": True, "latency_ms": 20},
                    {"concurrency": 2, "outcome": "DATABASE_ERROR", "reason_code": "DB_FAIL", "latency_ms": 30},
                    {"concurrency": 2, "outcome": "CONNECTION_ERROR", "latency_ms": 40},
                    {"concurrency": 2, "outcome": "SUCCESS", "latency_ms": 50},
                ] if condition == "non-atomic" else [
                    {"concurrency": 2, "outcome": "ERROR", "reason_code": "CLAIM_TRANSACTION_ROLLED_BACK", "latency_ms": 12},
                    {"concurrency": 2, "outcome": "SUCCESS", "latency_ms": 18},
                ])
                (folder / "requests.json").write_text(json.dumps(requests))
            lease.mkdir()
            (lease / "lease_trials.json").write_text("[]")
            with patch("sys.argv", ["report.py", "--non-atomic", str(non_atomic),
                                    "--protected", str(protected), "--lease", str(lease),
                                    "--output", str(out)]):
                report.main()
            with (out / "summary.csv").open(newline="", encoding="utf-8") as f:
                rows = {r["condition"]: r for r in csv.DictReader(f)}
            baseline = rows["NON_ATOMIC_BASELINE"]
            self.assertEqual(baseline["duplicate_trials"], "1")
            self.assertEqual(baseline["invariant_violation_trials"], "1")
            self.assertEqual(baseline["request_errors"], "4")
            self.assertEqual(baseline["timeouts"], "1")
            self.assertEqual(baseline["latency_sample_count"], "5")
            self.assertEqual(baseline["min_request_latency_ms"], "10.0")
            self.assertEqual(baseline["median_request_latency_ms"], "30.0")
            self.assertEqual(baseline["p95_request_latency_ms"], "48.0")
            self.assertEqual(baseline["max_request_latency_ms"], "50.0")
            self.assertIn("CLAIM_TRANSACTION_ROLLED_BACK", baseline["request_error_reason_counts"])
            atomic = rows["PROTECTED_ATOMIC"]
            self.assertEqual(atomic["duplicate_trials"], "0")
            self.assertEqual(atomic["invariant_preserved_trials"], "1")
            markdown = (out / "report.md").read_text(encoding="utf-8")
            self.assertIn("0/1 preserved; 1 violations", markdown)
            self.assertIn("1/1 preserved; 0 violations", markdown)
            self.assertIn("CLAIM_TRANSACTION_ROLLED_BACK", markdown)
            self.assertIn("4 / 5", markdown)


if __name__ == "__main__":
    unittest.main()
