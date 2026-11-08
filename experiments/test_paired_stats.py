import unittest

from experiments.paired_stats import paired_bootstrap


class PairedBootstrapTests(unittest.TestCase):
    def test_is_deterministic_and_preserves_mean_difference(self):
        a = paired_bootstrap([1, 2, 3, 4], seed=7, replicates=1000)
        b = paired_bootstrap([1, 2, 3, 4], seed=7, replicates=1000)
        self.assertEqual(a, b)
        self.assertEqual(a['mean_difference'], 2.5)
        self.assertLessEqual(a['ci_low'], a['mean_difference'])
        self.assertGreaterEqual(a['ci_high'], a['mean_difference'])

    def test_empty_pairs_are_reported_not_silently_dropped(self):
        result = paired_bootstrap([])
        self.assertIsNone(result['mean_difference'])
        self.assertEqual(result['replicates'], 0)


if __name__ == '__main__':
    unittest.main()
