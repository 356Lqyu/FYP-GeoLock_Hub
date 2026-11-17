"""Canonical bindings and byte-sensitive validator build coverage."""
import hashlib
from pathlib import Path
import unittest
from unittest.mock import patch

from backend.routing.integration import worker
from backend.routing.optimizers import cp_sat, methods, models
from backend.routing.planner import matrices, orchestration
from backend.routing.validator import validate_plan, validate_work_item
from backend.routing.worker_service.validator import validator_build


class PackageLayoutTests(unittest.TestCase):
    def test_worker_and_planner_share_canonical_bindings(self):
        self.assertIs(worker.prepare_input, orchestration.prepare_input)
        self.assertIs(worker.evaluate, orchestration.evaluate)
        self.assertIs(worker.digest, matrices.digest)
        self.assertIs(worker.require, matrices.require)
        self.assertIs(worker.Plan, models.Plan)
        self.assertIs(worker.validate_work_item, validate_work_item)
        self.assertIs(orchestration.validate_plan, validate_plan)

    def test_operational_and_research_methods_share_canonical_entry_point(self):
        self.assertIs(methods._optimise, cp_sat._optimise)
        self.assertIs(methods.METHODS["proposed"], methods.proposed)
        self.assertIs(methods.OPERATIONAL_METHODS["proposed"], methods.proposed)
        self.assertIs(orchestration.OPERATIONAL_METHODS, methods.OPERATIONAL_METHODS)
        self.assertEqual(tuple(methods.OPERATIONAL_METHODS), (
            "fcfs", "nearest_neighbour", "proposed",
        ))
        self.assertEqual(tuple(methods.METHODS), (
            "fcfs", "nearest_neighbour", "distance_only", "proposed",
        ))

    def test_validator_fingerprint_uses_canonical_source_bytes(self):
        root = Path(__file__).resolve().parents[1]
        paths = [root / name for name in (
            "contract.py", "validator/validation.py", "integration/worker.py",
        )]
        expected = hashlib.sha256(b"".join(p.read_bytes() for p in paths)).hexdigest()
        self.assertEqual(validator_build(), "geolock-independent-validator:" + expected)

        # A checkout's line endings are intentionally included in the identity.
        for ending in (b"\n", b"\r\n"):
            with self.subTest(ending=ending):
                payloads = [b"contract" + ending, b"validation" + ending, b"worker" + ending]
                with patch.object(Path, "read_bytes", autospec=True, side_effect=payloads) as read:
                    actual = validator_build()
                self.assertEqual([call.args[0] for call in read.call_args_list], paths)
                digest = hashlib.sha256(b"".join(payloads)).hexdigest()
                self.assertEqual(actual, "geolock-independent-validator:" + digest)


if __name__ == "__main__":
    unittest.main()
