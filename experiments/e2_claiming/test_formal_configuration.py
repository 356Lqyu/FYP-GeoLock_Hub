import unittest

from experiments.e2_claiming.e2_runner import (
    CONTENTION_LEVELS,
    validate_contention_trial_count,
    validate_lease_trial_count,
)


class FormalConfigurationTests(unittest.TestCase):
    def test_selected_contention_configuration_is_supported_at_all_required_levels(self):
        validate_contention_trial_count(20)
        self.assertEqual(CONTENTION_LEVELS, (2, 5, 10))
        self.assertEqual(len(CONTENTION_LEVELS) * 20, 60)

    def test_selected_lease_configuration_is_supported(self):
        validate_lease_trial_count(30)
        self.assertEqual(60 + 60 + 30, 150)

    def test_configurable_counts_remain_bounded(self):
        for invalid in (0, 51):
            with self.subTest(kind="contention", count=invalid), self.assertRaises(RuntimeError):
                validate_contention_trial_count(invalid)
        for invalid in (0, 101):
            with self.subTest(kind="lease", count=invalid), self.assertRaises(RuntimeError):
                validate_lease_trial_count(invalid)


if __name__ == "__main__":
    unittest.main()
