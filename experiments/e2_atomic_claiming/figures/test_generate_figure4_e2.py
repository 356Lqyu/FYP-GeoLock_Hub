"""Lightweight checks for the E2 Figure 4 evidence path and CI calculation."""
import unittest
import tempfile
from pathlib import Path

from generate_figure4_e2 import (
    DEFAULT_RUN, DEFAULT_TABLE7, STANDALONE_LABEL_RIGHT, STANDALONE_LABEL_X,
    STANDALONE_PLOT_VIEW_LEFT, collect_data, generate, helvetica_text_width,
    standalone_layout, standalone_rows, wilson,
)


class Figure4E2Tests(unittest.TestCase):
    def test_wilson_boundary_intervals(self):
        low0, high0 = wilson(0, 150)
        low1, high1 = wilson(150, 150)
        self.assertEqual(low0, 0.0)
        self.assertAlmostEqual(high0, 0.0249702443680766, places=12)
        self.assertAlmostEqual(low1, 0.9750297556319235, places=12)
        self.assertEqual(high1, 1.0)

    def test_saved_e2_metrics_match_table7(self):
        data = collect_data(DEFAULT_RUN, DEFAULT_TABLE7)
        self.assertEqual(data["duplicate"]["non_atomic"]["successes"], 150)
        self.assertEqual(data["duplicate"]["no_recovery"]["successes"], 0)
        self.assertEqual(data["duplicate"]["with_recovery"]["successes"], 0)
        self.assertEqual(data["recovery"]["no_recovery"]["successes"], 0)
        self.assertEqual(data["recovery"]["with_recovery"]["successes"], 100)

    def test_all_three_figures_render_and_safe_replace(self):
        stems = (
            "figure4_e2_claim_safety_recovery",
            "figure4a_e2_duplicate_ownership",
            "figure4b_e2_expired_lease_recovery",
        )
        with tempfile.TemporaryDirectory() as temporary:
            out = Path(temporary)
            generated = generate(DEFAULT_RUN, out, DEFAULT_TABLE7)
            self.assertEqual(set(generated), set(stems))
            for stem, (png, pdf) in generated.items():
                self.assertEqual(png.name, stem + ".png")
                self.assertEqual(pdf.name, stem + ".pdf")
                self.assertGreater(png.stat().st_size, 0)
                pdf_bytes = pdf.read_bytes()
                self.assertTrue(pdf_bytes.startswith(b"%PDF-1.4"))
                self.assertNotIn(b"/Subtype /Image", pdf_bytes)
            with self.assertRaises(FileExistsError):
                generate(DEFAULT_RUN, out, DEFAULT_TABLE7)
            generate(DEFAULT_RUN, out, DEFAULT_TABLE7, replace_existing=True)

    def test_labels_and_panel_count_units(self):
        with tempfile.TemporaryDirectory() as temporary:
            generated = generate(DEFAULT_RUN, Path(temporary), DEFAULT_TABLE7)
            combined = generated["figure4_e2_claim_safety_recovery"][1].read_bytes()
            duplicate = generated["figure4a_e2_duplicate_ownership"][1].read_bytes()
            lease = generated["figure4b_e2_expired_lease_recovery"][1].read_bytes()
            for label in (b"Protected, no recovery", b"Proposed, with recovery", b"Non-atomic: not applicable"):
                self.assertIn(label, combined)
            self.assertIn(b"150/150 trials \\(100%\\)", duplicate)
            self.assertIn(b"0/150 trials \\(0%\\)", duplicate)
            self.assertIn(b"0/100 cases \\(0%\\)", lease)
            self.assertIn(b"100/100 cases \\(100%\\)", lease)
            self.assertNotIn(b"Non-atomic", lease)

    def test_standalone_label_bounding_boxes_do_not_enter_plot_viewport(self):
        data = collect_data(DEFAULT_RUN, DEFAULT_TABLE7)
        layout = standalone_layout(360)
        label_left, label_right = layout["label_column"]
        graph_left, graph_right = layout["plot_viewport"]
        axis_left, axis_right = layout["plot_axis"]
        self.assertEqual(label_left, STANDALONE_LABEL_X)
        self.assertEqual(label_right, STANDALONE_LABEL_RIGHT)
        self.assertEqual(graph_left, STANDALONE_PLOT_VIEW_LEFT)
        self.assertLess(label_right, graph_left)
        self.assertLess(graph_left, graph_right)
        axis_label = "Expired-lease recovery (%)"
        axis_size = 11.5
        axis_text_left = (axis_left + axis_right - helvetica_text_width(axis_label, axis_size)) / 2
        self.assertGreaterEqual(axis_text_left, graph_left)
        self.assertLessEqual(axis_text_left + helvetica_text_width(axis_label, axis_size), axis_right)
        for panel, count_size in (("duplicate", 10.5), ("recovery", 10.5)):
            for label, item, count_label in standalone_rows(data, panel):
                count = f"{item['successes']}/{item['n']} {count_label} ({item['rate'] * 100:.0f}%)"
                for text, size in ((label, 11.5), (count, count_size)):
                    text_right = STANDALONE_LABEL_X + helvetica_text_width(text, size)
                    self.assertLessEqual(text_right, label_right, text)
                    self.assertLess(text_right, graph_left, text)


if __name__ == "__main__":
    unittest.main()
