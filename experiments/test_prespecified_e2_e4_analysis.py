import unittest
import math

from experiments.analyze_prespecified_e2_e4 import (
    binomial_two_sided,
    holm,
    mcnemar,
    paired_continuous,
    wilcoxon_pratt_exact,
    wilson,
)


class PrespecifiedStatisticsTests(unittest.TestCase):
    def test_mcnemar_exact_extreme_and_no_discordance(self):
        self.assertEqual(mcnemar([False] * 8, [True] * 8)["p_exact_two_sided"], 2 / 256)
        self.assertEqual(mcnemar([True, False], [True, False])["p_exact_two_sided"], 1.0)

    def test_wilcoxon_pratt_handles_zero_and_tied_differences(self):
        result = wilcoxon_pratt_exact([0, 1, 1, -1])
        self.assertEqual(result["n_pairs"], 4)
        self.assertEqual(result["nonzero_pairs"], 3)
        self.assertGreaterEqual(result["p_exact_two_sided"], 0)
        self.assertLessEqual(result["p_exact_two_sided"], 1)

    def test_hodges_lehmann_and_paired_bootstrap_are_reproducible(self):
        result = paired_continuous([1, 2, 4], [2, 4, 7], seed=20260915)
        self.assertEqual(result["hodges_lehmann_paired_location"], 2)
        self.assertLessEqual(result["hl_bootstrap_95_ci_low"], result["hl_bootstrap_95_ci_high"])
        self.assertEqual(result["p_exact_two_sided"], 0.25)

    def test_wilson_and_holm_boundaries(self):
        lo, hi = wilson(0, 10)
        self.assertEqual(lo, 0)
        self.assertGreater(hi, 0)
        empty = wilson(0, 0)
        self.assertTrue(all(math.isnan(v) for v in empty))
        adjusted = holm([0.01, 0.04, 0.03])
        self.assertEqual(adjusted, [0.03, 0.06, 0.06])

    def test_exact_binomial_edge_cases(self):
        self.assertEqual(binomial_two_sided(0, 0), 1.0)
        self.assertEqual(binomial_two_sided(0, 10), 2 / 1024)


if __name__ == "__main__":
    unittest.main()
