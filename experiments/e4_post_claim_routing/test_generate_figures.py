import csv
import json
import tempfile
import unittest
from pathlib import Path

from experiments.e4_post_claim_routing.generate_figures import (
    collect_data,
    matched_savings_geometry,
    matched_task_savings_page,
)


class FigureInputTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.run = Path(self.temp.name)
        (self.run / "statistical_analysis").mkdir()
        (self.run / "raw").mkdir()
        (self.run / "completion.json").write_text(json.dumps({
            "all_100_completed": True, "scenarios": 100, "evaluations": 300,
            "errors": 0, "source_unchanged": True,
        }))
        (self.run / "verification.json").write_text(json.dumps({
            "saved_routes_independently_revalidated": 300,
            "additional_admission_exclusions": 0,
        }))
        (self.run / "manifest.json").write_text(json.dumps({"status": "COMPLETE"}))
        summary = []
        for method in ("nearest_next", "fcfs", "proposed"):
            summary.append({
                "method": method, "scenarios": 100, "valid_tasks": 500,
                "successful_plans": 100, "failed_or_invalid": 0,
                "feasibility_pass": 100, "timeouts": 0,
                "capacity_violations": 0, "window_violations": 0,
                "duration_violations": 0, "served_tasks": 450,
                "task_weighted_coverage_pct": 90.0, "distance_km": 4000.0,
            })
        with (self.run / "summary_statistics.csv").open("w", newline="", encoding="utf-8") as stream:
            writer = csv.DictWriter(stream, fieldnames=list(summary[0]))
            writer.writeheader()
            writer.writerows(summary)
        rows = []
        rows_data = {
            "nearest_next": (-5.0, -7.0, -3.0, 85),
            "fcfs": (-11.375, -13.25, -9.4, 80),
        }
        for method, (estimate, low, high, n) in rows_data.items():
            rows.append({
                "baseline": method,
                "metric": "distance_km_identical_served_task_set",
                "analysis_scope": "identical_served_task_sets_only",
                "matched_scenarios": n,
                "n_pairs": n,
                "hodges_lehmann_paired_location": estimate,
                "hl_bootstrap_95_ci_low": low,
                "hl_bootstrap_95_ci_high": high,
                "p_holm_e4_secondary": 0.01,
            })
        with (self.run / "statistical_analysis" / "paired_tests.csv").open("w", newline="", encoding="utf-8") as stream:
            writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
            writer.writeheader()
            writer.writerows(rows)
        with (self.run / "results_per_scenario.csv").open("w", newline="", encoding="utf-8") as stream:
            writer = csv.DictWriter(stream, fieldnames=("scenario_id", "method"))
            writer.writeheader()
            writer.writerows({"scenario_id": f"S{i:03d}", "method": method} for method in ("nearest_next", "fcfs", "proposed") for i in range(100))

    def test_collects_figure_values_only_after_validation_gates(self):
        data = collect_data(self.run)
        self.assertEqual(data["summary"]["proposed"]["served_tasks"], "450")
        self.assertEqual(data["paired_savings"]["nearest_next"]["estimate"], 5.0)
        self.assertEqual(data["paired_savings"]["nearest_next"]["low"], 3.0)
        self.assertEqual(data["paired_savings"]["nearest_next"]["high"], 7.0)
        self.assertEqual(data["paired_savings"]["nearest_next"]["n"], 85)
        self.assertEqual(data["paired_savings"]["fcfs"]["estimate"], 11.375)
        self.assertEqual(data["paired_savings"]["fcfs"]["low"], 9.4)
        self.assertEqual(data["paired_savings"]["fcfs"]["high"], 13.25)
        self.assertEqual(data["paired_savings"]["fcfs"]["n"], 80)

    def test_compact_chart_maps_saved_estimates_and_intervals_to_axis(self):
        data = collect_data(self.run)
        geometry = matched_savings_geometry(data)
        axis_left, axis_width, axis_max = 168.0, 244.0, 15.0
        self.assertAlmostEqual(geometry["nearest_next"]["low"], axis_left + 3.0 / axis_max * axis_width)
        self.assertAlmostEqual(geometry["nearest_next"]["estimate"], axis_left + 5.0 / axis_max * axis_width)
        self.assertAlmostEqual(geometry["nearest_next"]["high"], axis_left + 7.0 / axis_max * axis_width)
        self.assertAlmostEqual(geometry["fcfs"]["low"], axis_left + 9.4 / axis_max * axis_width)
        self.assertAlmostEqual(geometry["fcfs"]["estimate"], axis_left + 11.375 / axis_max * axis_width)
        self.assertAlmostEqual(geometry["fcfs"]["high"], axis_left + 13.25 / axis_max * axis_width)
        commands = "\n".join(matched_task_savings_page(data).commands)
        for expected in (
            "E4: road-distance savings for identical served tasks",
            "Nearest-Next", "85 matched snapshots", "FCFS", "80 matched snapshots",
            r"Matched-task road-distance savings \(km\)", "Positive values favour CP-SAT.",
            "5.00", "11.38",
        ):
            self.assertIn(expected, commands)

    def test_rejects_incomplete_route_validation(self):
        (self.run / "verification.json").write_text(json.dumps({
            "saved_routes_independently_revalidated": 299,
            "additional_admission_exclusions": 0,
        }))
        with self.assertRaisesRegex(ValueError, "independent post-run validation"):
            collect_data(self.run)

    def test_rejects_mismatched_method_scenarios(self):
        path = self.run / "results_per_scenario.csv"
        with path.open("w", newline="", encoding="utf-8") as stream:
            writer = csv.DictWriter(stream, fieldnames=("scenario_id", "method"))
            writer.writeheader()
            writer.writerows(
                {"scenario_id": ("S100" if method == "proposed" and i == 99 else f"S{i:03d}"), "method": method}
                for method in ("nearest_next", "fcfs", "proposed") for i in range(100)
            )
        with self.assertRaisesRegex(ValueError, "same 100 scenario IDs"):
            collect_data(self.run)


if __name__ == "__main__":
    unittest.main()
