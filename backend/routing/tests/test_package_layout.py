"""Compatibility anchors for the Windows routing package layout."""
import importlib
import unittest

from backend.routing import phase_b
from backend.routing.optimizers import cp_sat
from backend.routing.worker_service.validator import validator_build


class PackageLayoutTests(unittest.TestCase):
    def test_historical_imports_share_canonical_modules(self):
        for old, current in (
            ("phase_b.baselines", "optimizers.baselines"),
            ("phase_b.models", "optimizers.models"),
            ("phase_b.problem", "optimizers.problem"),
            ("phase_c2.matrices", "planner.matrices"),
            ("phase_c2.orchestration", "planner.orchestration"),
        ):
            with self.subTest(old=old):
                self.assertIs(
                    importlib.import_module(f"backend.routing.{old}"),
                    importlib.import_module(f"backend.routing.{current}"),
                )

    def test_operational_and_e4_proposed_share_historical_entry_point(self):
        legacy = importlib.import_module("backend.routing.phase_b.optimizers")
        self.assertIs(legacy._optimise, cp_sat._optimise)
        self.assertIs(phase_b.METHODS["proposed"], legacy.proposed)
        self.assertIs(phase_b.OPERATIONAL_METHODS["proposed"], legacy.proposed)
        self.assertEqual(legacy.proposed.__module__, legacy.__name__)
        self.assertEqual(tuple(phase_b.OPERATIONAL_METHODS), (
            "fcfs", "nearest_neighbour", "proposed",
        ))

    def test_validator_fingerprint_is_unchanged_by_layout_refactor(self):
        self.assertEqual(validator_build(),
            "geolock-independent-validator:"
            "8dba5fb5e900703e580e78e104f8680b97c069f94a4e2ae2eaf162349ca792cf")


if __name__ == "__main__":
    unittest.main()
