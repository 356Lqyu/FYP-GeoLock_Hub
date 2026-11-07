from copy import deepcopy
from dataclasses import replace
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from backend.routing.contract import freeze_scenario, load_scenario
from backend.routing.generate_examples import build_mixed, EXAMPLES
from backend.routing.phase_b import METHODS, fcfs, nearest_neighbour, distance_only, proposed, validate_plan
from backend.routing.phase_b.benchmark import check_phase_a, run_benchmark, semantic
from backend.routing.phase_b.models import ExecutionConfig
from backend.routing.phase_b.scenarios import scenarios, edge_payloads
from backend.routing.phase_b.optimizers import proposed as cp_sat_proposed


class AlgorithmsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Explicit short UNIT-test profile; frozen input files and the report's
        # 30-second production profile are not edited.
        cls.cases = {}
        for name,snapshot in scenarios().items():
            payload=snapshot.to_dict()['input']
            payload['solver']['time_limit_seconds']=.2
            cls.cases[name]=freeze_scenario(payload)

    def case(self, name):
        return self.cases[name]

    def test_phase_a_preserved_byte_for_byte(self):
        self.assertEqual(check_phase_a(), 17)

    def test_all_21_cases_all_four_methods_independently_validate(self):
        self.assertEqual(len(self.cases), 21)
        for name, s in self.cases.items():
            before = s.canonical_json
            for method, solve in METHODS.items():
                with self.subTest(scenario=name, method=method):
                    p = solve(s)
                    v = validate_plan(s, p)
                    self.assertTrue(v.valid, v.violations)
                    self.assertFalse(p.dispatch_authority_issued)
                    self.assertEqual(p.snapshot_sha256, s.sha256)
                    self.assertEqual(s.canonical_json, before)
                    self.assertEqual(set(v.metrics["served_tasks"]) | set(p.unserved_tasks), set(s.admitted_task_ids))
                    self.assertEqual(v.metrics["capacity_violations"], 0)
                    if v.mandatory_unserved:
                        self.assertFalse(p.feasible)

    def test_mixed_optimizers_reduce_distance_without_losing_coverage(self):
        s = self.case("phase_a/mixed")
        distances = {}
        for name, solve in METHODS.items():
            p = solve(s)
            v = validate_plan(s, p)
            self.assertEqual(v.metrics["served_count"], 2)
            distances[name] = v.metrics["total_travel_km"]
        self.assertEqual(distances, {"fcfs": 15.5, "nearest_neighbour": 15.5, "distance_only": 11, "proposed": 11})

    def test_primary_coverage_recovers_urgent_task(self):
        s = self.case("phase_b/urgent_hub_optional")
        for solve in (fcfs, nearest_neighbour):
            self.assertEqual(len(solve(s).unserved_tasks), 1)
        for solve in (distance_only, proposed):
            p = solve(s)
            self.assertEqual(p.unserved_tasks, ())
            self.assertTrue(p.coverage_optimal)
            self.assertTrue(validate_plan(s, p).feasible)

    def test_primary_coverage_is_not_a_finite_cost_penalty(self):
        s = self.case("phase_b/primary_over_cost")
        p = proposed(s)
        self.assertEqual(p.unserved_tasks, ())
        self.assertTrue(p.coverage_optimal)
        self.assertGreater(validate_plan(s, p).metrics["total_cost"], 1_000_000)

    def test_proposed_uses_pickup_task_count_then_raw_directed_distance(self):
        s = self.case("phase_b/cost_tradeoff")
        d = validate_plan(s, distance_only(s)).metrics
        c = validate_plan(s, proposed(s)).metrics
        self.assertEqual((d["total_travel_km"], d["total_cost"]), (11, 111))
        self.assertEqual((c["total_travel_km"], c["total_cost"]), (11, 111))
        self.assertEqual(c["served_pickup_task_count"], 2)
        self.assertEqual(proposed(s).optimization_objective, "MAX_PICKUP_TASKS_THEN_MIN_DIRECTED_ROAD_KM")

    def test_hub_batch_counts_as_one_pickup_task_not_member_donations(self):
        payload = build_mixed()
        payload["vehicles"] = payload["vehicles"][:1]
        payload["vehicles"][0]["capacity_kg"] = 30  # either task, never both
        for task in payload["tasks"]:
            task["mandatory"] = False
        payload["solver"]["time_limit_seconds"] = .2
        s = freeze_scenario(payload)
        plan = proposed(s)
        checked = validate_plan(s, plan)
        self.assertEqual(len(payload["tasks"][1]["donations"]), 3)
        self.assertEqual(plan.pickup_task_objective_value, 1)
        self.assertEqual(checked.metrics["served_pickup_task_count"], 1)
        # Equal one-task coverage is broken by raw road distance; the closer
        # direct pickup wins despite the hub batch representing three donations.
        self.assertEqual(checked.metrics["served_tasks"], ["TOY-DIRECT"])

    def test_legacy_cost_weights_do_not_change_proposed_objective(self):
        s = self.case("phase_b/cost_tradeoff")
        a = proposed(s)
        b = proposed(s, ExecutionConfig(fixed_cost_weight=0, distance_cost_weight=1))
        self.assertEqual(a.snapshot_sha256, b.snapshot_sha256)
        self.assertEqual(a.routes, b.routes)
        self.assertEqual(validate_plan(s, b).metrics["total_travel_km"], 11)

    def test_preserved_cp_sat_optimizers_prove_mandatory_infeasibility(self):
        for name in ("capacity_infeasible", "duration_infeasible", "window_infeasible", "unreachable_forbid", "no_return_arc"):
            for solve in (distance_only, cp_sat_proposed):
                with self.subTest(name=name, method=solve.__name__):
                    s = self.case("phase_b/"+name)
                    p = solve(s)
                    self.assertEqual(p.status, "INFEASIBLE")
                    self.assertTrue(p.infeasibility_proven)
                    self.assertFalse(p.feasible)
                    self.assertIsNone(p.optimality_gap)
                    self.assertTrue(validate_plan(s, p).valid)

    def test_heuristic_infeasibility_is_not_an_impossibility_proof(self):
        s = self.case("phase_b/capacity_infeasible")
        p = fcfs(s)
        self.assertFalse(p.feasible)
        self.assertFalse(p.infeasibility_proven)
        self.assertEqual(p.status, "INFEASIBLE")
        self.assertGreater(len(p.routes), 0)

    def test_forbidden_optional_task_is_explicitly_unserved(self):
        s = self.case("phase_b/unreachable_optional")
        for solve in METHODS.values():
            p = solve(s)
            v = validate_plan(s, p)
            self.assertEqual(p.status, "PARTIAL")
            self.assertEqual(p.unserved_tasks, ("TOY-HUB-TASK",))
            self.assertEqual(v.metrics["served_tasks"], ["TOY-DIRECT"])

    def test_missing_and_unreachable_fail_scenario_do_not_enter_solver(self):
        for name in ("missing_edge", "unreachable"):
            for solve in METHODS.values():
                p = solve(self.case("phase_a/"+name))
                self.assertEqual(p.status, "ROUTE_UNAVAILABLE")
                self.assertEqual(p.routes, ())
                self.assertEqual(p.solver_statuses, ())

    def test_excluded_authority_is_not_called_unserved(self):
        s = self.case("phase_a/reconciliation")
        for solve in METHODS.values():
            p = solve(s)
            self.assertEqual(p.unserved_tasks, ())
            self.assertEqual(p.status, "NO_VALID_TASKS")

    def test_waiting_and_service_included_in_return_duration(self):
        s = self.case("phase_b/waiting")
        for solve in METHODS.values():
            v = validate_plan(s, solve(s))
            self.assertEqual(v.metrics["total_route_minutes"], 45)
            self.assertEqual(v.metrics["waiting_minutes"], 26)
            self.assertEqual(v.metrics["service_minutes"], 10)

    def test_exact_duration_boundary_is_allowed(self):
        s = self.case("phase_b/exact_duration")
        for solve in METHODS.values():
            v = validate_plan(s, solve(s))
            self.assertTrue(v.feasible)
            self.assertEqual(v.metrics["total_route_minutes"], 19)

    def test_colocated_tasks_remain_distinct_services(self):
        s = self.case("phase_b/colocated_tasks")
        for solve in (distance_only, proposed):
            p = solve(s)
            v = validate_plan(s, p)
            self.assertEqual(v.metrics["served_count"], 2)
            self.assertEqual(v.metrics["service_minutes"], 20)
            self.assertEqual(v.metrics["total_travel_km"], 4.5)

    def test_fcfs_orders_actual_instants_not_timestamp_strings(self):
        p = self.case("phase_a/mixed").to_dict()["input"]
        p["tasks"][0]["created_at"] = "2026-10-24T08:01:00+08:00"
        p["tasks"][1]["created_at"] = "2026-10-24T00:02:00Z"
        s = freeze_scenario(p)
        self.assertEqual(fcfs(s).routes[0].stops[0].task_id, "TOY-DIRECT")

    def test_fixed_vehicle_order_and_nearest_tie_are_reproducible(self):
        s = self.case("phase_a/mixed")
        for solve in METHODS.values():
            self.assertEqual(semantic(solve(s)), semantic(solve(s)))

    def test_cp_sat_baseline_gap_only_after_primary_proof_and_secondary_incumbent(self):
        s = self.case("phase_a/mixed")
        for solve in (distance_only, cp_sat_proposed):
            p = solve(s)
            self.assertTrue(p.coverage_optimal)
            self.assertTrue(p.secondary_optimal)
            self.assertEqual(p.optimality_gap, 0)
            self.assertEqual(p.gap_scope, "FIXED_PICKUP_TASK_COUNT_DIRECTED_DISTANCE")
            self.assertIsNotNone(p.secondary_bound_scaled)
            self.assertEqual(p.optimization_status, "OPTIMAL")
        self.assertIsNone(fcfs(s).optimality_gap)

    def test_zero_work_budget_returns_timeout_not_infeasibility(self):
        s = self.case("phase_a/mixed")
        p = cp_sat_proposed(s, ExecutionConfig(deterministic_seconds_per_pass=0))
        self.assertEqual(p.status, "OPTIMISATION_TIMEOUT")
        self.assertTrue(p.timeout)
        self.assertFalse(p.infeasibility_proven)
        self.assertFalse(p.coverage_optimal)
        self.assertIsNone(p.optimality_gap)
        self.assertEqual(p.optimization_status, "NO_FEASIBLE_SOLUTION")
        self.assertTrue(validate_plan(s, p).valid)

    def test_feasible_unproven_coverage_still_runs_distance_stage(self):
        from ortools.sat.python import cp_model
        original = cp_model.CpSolver.solve
        calls = []

        def incumbent_then_feasible(solver, model, *args, **kwargs):
            status = original(solver, model, *args, **kwargs)
            calls.append(status)
            if len(calls) == 1 and status == cp_model.OPTIMAL:
                return cp_model.FEASIBLE
            return status

        with patch.object(cp_model.CpSolver, "solve", incumbent_then_feasible):
            plan = cp_sat_proposed(self.case("phase_a/mixed"))
        self.assertEqual(len(plan.solver_statuses), 2)
        self.assertEqual(plan.solver_statuses[0], "FEASIBLE")
        self.assertTrue(plan.secondary_optimal)
        self.assertFalse(plan.coverage_optimal)
        self.assertEqual(plan.optimization_status, "FEASIBLE_UNPROVEN")
        self.assertTrue(plan.feasible)
        self.assertTrue(validate_plan(self.case("phase_a/mixed"), plan).valid)

    def test_secondary_timeout_keeps_independently_valid_primary_incumbent(self):
        from ortools.sat.python import cp_model
        original = cp_model.CpSolver.solve
        calls = []

        def limited(solver, model, *args, **kwargs):
            calls.append(1)
            if len(calls) == 2:
                solver.parameters.max_deterministic_time = 0
            return original(solver, model, *args, **kwargs)

        s = self.case("phase_a/mixed")
        with patch.object(cp_model.CpSolver, "solve", limited):
            p = cp_sat_proposed(s)
        self.assertTrue(p.coverage_optimal)
        self.assertFalse(p.secondary_optimal)
        self.assertTrue(p.timeout)
        self.assertEqual(p.optimization_status, "FEASIBLE_UNPROVEN")
        self.assertEqual(p.unserved_tasks, ())
        self.assertIsNone(p.optimality_gap)
        self.assertTrue(validate_plan(s, p).feasible)

    def test_unsupported_precision_is_rejected_without_rounding(self):
        p = build_mixed()
        p["tasks"][0]["service_minutes"] = 1e-10
        s = freeze_scenario(p)
        for solve in METHODS.values():
            with self.assertRaisesRegex(ValueError, "UNSUPPORTED_PRECISION"):
                solve(s)

    def test_explicit_solver_version_mismatch_rejected(self):
        p = build_mixed()
        p["solver"]["version"] = "wrong-version"
        with self.assertRaisesRegex(ValueError, "SOLVER_VERSION_MISMATCH"):
            proposed(freeze_scenario(p))

    def test_secondary_objective_matches_independent_components_and_bound(self):
        s = self.case("phase_b/cost_tradeoff")
        p = cp_sat_proposed(s)
        v = validate_plan(s, p)
        self.assertEqual(p.secondary_objective_scaled, v.metrics["total_travel_distance_scaled"])
        self.assertEqual(p.secondary_bound_scaled, p.secondary_objective_scaled)

    def test_legacy_cost_weight_precision_does_not_affect_distance_objective(self):
        s = self.case("phase_b/cost_tradeoff")
        ordinary = proposed(s)
        weighted = proposed(s, ExecutionConfig(distance_cost_weight=0.00000001))
        self.assertEqual(ordinary.routes, weighted.routes)
        self.assertEqual(ordinary.secondary_objective_scaled, weighted.secondary_objective_scaled)

    def test_submicrosecond_timestamp_is_rejected_without_truncation(self):
        payload = build_mixed()
        payload["cutoff"] = "2026-10-24T00:05:00.0000001Z"
        s = freeze_scenario(payload)  # Phase A remains unchanged.
        for solve in METHODS.values():
            with self.assertRaisesRegex(ValueError, "UNSUPPORTED_TIMESTAMP_PRECISION"):
                solve(s)

    def test_execution_config_rejects_invalid_cost_weights(self):
        for changes in ({"fixed_cost_weight": -1}, {"distance_cost_weight": float("nan")},
                        {"fixed_cost_weight": True}, {"fixed_cost_weight": 0, "distance_cost_weight": 0}):
            with self.assertRaises(ValueError):
                ExecutionConfig(**changes)

    def test_preserved_cp_sat_benchmark_records_same_snapshot_and_repeated_results(self):
        # Preserve the historical deterministic CP-SAT benchmark guarantee.
        # Wall-clock RoutingModel GLS is separately tested and must still pass
        # the unchanged NONREPRODUCIBLE_RESULT guard before a formal run.
        from backend.routing.phase_b import benchmark
        selected = {k: self.cases[k] for k in ("phase_a/mixed", "phase_b/cost_tradeoff")}
        methods=dict(METHODS,proposed=cp_sat_proposed)
        with tempfile.TemporaryDirectory() as folder, patch.object(benchmark,'METHODS',methods):
            manifest, rows = run_benchmark(folder, repeats=2, selected=selected)
            self.assertEqual(manifest["execution_count"], 16)
            self.assertEqual(manifest["phase_a_files_preserved"], 17)
            for case in selected:
                self.assertEqual(len({r["snapshot_sha256"] for r in rows if r["scenario"] == case}), 1)
            for file in ("manifest.json", "snapshots.json", "results.json", "comparison.json", "comparison.csv", "comparison.md"):
                self.assertTrue((Path(folder)/file).is_file())
            other, _ = run_benchmark(folder, repeats=2, selected=selected)
            self.assertEqual(manifest["non_timing_results_sha256"], other["non_timing_results_sha256"])


if __name__ == "__main__":
    unittest.main()
