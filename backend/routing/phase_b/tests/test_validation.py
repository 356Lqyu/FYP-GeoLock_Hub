from dataclasses import replace
import unittest
from unittest.mock import patch

from backend.routing.contract import freeze_scenario, load_scenario
from backend.routing.generate_examples import EXAMPLES
from backend.routing.phase_b import fcfs, validate_plan


class IndependentValidatorTests(unittest.TestCase):
    def setUp(self):
        self.s = load_scenario(EXAMPLES/"direct_only.json")
        self.p = fcfs(self.s)
        self.route = self.p.routes[0]
        self.stop = self.route.stops[0]

    def rejects(self, plan, code, snapshot=None):
        result = validate_plan(snapshot or self.s, plan)
        self.assertFalse(result.valid)
        self.assertIn(code, {code for code, _ in result.violations}, result.violations)
        return result

    def changed_input(self, edit):
        p = self.s.to_dict()["input"]
        edit(p)
        s = freeze_scenario(p)
        return s, replace(self.p, snapshot_sha256=s.sha256, matrix_sha256=s.matrix_sha256)

    def change_stop(self, **changes):
        return replace(self.p, routes=(replace(self.route, stops=(replace(self.stop, **changes),)),))

    def test_valid_route_and_recomputed_cost_components(self):
        v = validate_plan(self.s, self.p)
        self.assertTrue(v.feasible)
        self.assertEqual(v.metrics["fixed_cost"], 5)
        self.assertEqual(v.metrics["distance_cost"], 4.5)
        self.assertEqual(v.metrics["total_cost"], 9.5)
        self.assertEqual(v.metrics["total_route_minutes"], 19)

    def test_validator_does_not_call_solver_feasibility_helper(self):
        with patch("backend.routing.phase_b.problem.Problem.schedule", side_effect=RuntimeError("must not call")):
            self.assertTrue(validate_plan(self.s, self.p).valid)

    def test_solver_optimal_status_does_not_override_invalid_route(self):
        bad = replace(self.p, routes=(self.route, self.route), solver_statuses=("OPTIMAL", "OPTIMAL"),
                      coverage_optimal=True, secondary_optimal=True)
        self.rejects(bad, "DUPLICATE_TASK")

    def test_pickup_task_objective_is_independently_recomputed(self):
        from backend.routing.phase_b.optimizers import proposed
        plan = proposed(self.s)
        self.assertEqual(validate_plan(self.s, plan).metrics["served_pickup_task_count"], 1)
        self.rejects(replace(plan, pickup_task_objective_value=2), "OPTIMIZATION_COVERAGE")

    def test_distance_objective_is_independently_recomputed(self):
        from backend.routing.phase_b.optimizers import proposed
        plan = proposed(self.s)
        self.rejects(replace(plan, secondary_objective_scaled=plan.secondary_objective_scaled + 1),
                     "OPTIMIZATION_DISTANCE")

    def test_duplicate_vehicle_is_rejected(self):
        self.rejects(replace(self.p, routes=(self.route, self.route)), "DUPLICATE_VEHICLE")

    def test_duplicate_task_within_route_rejected(self):
        self.rejects(replace(self.p, routes=(replace(self.route, stops=(self.stop, self.stop)),)), "DUPLICATE_TASK")

    def test_unknown_task_rejected(self):
        self.rejects(self.change_stop(task_id="UNAUTHORIZED-TASK"), "AUTHORITY")

    def test_foreign_ngo_rejected(self):
        bad = replace(self.p, routes=(replace(self.route, ngo_id="FOREIGN-NGO"),))
        self.rejects(bad, "AUTHORITY")

    def test_foreign_vehicle_rejected(self):
        self.rejects(replace(self.p, routes=(replace(self.route, vehicle_id="FOREIGN-VEHICLE"),)), "VEHICLE")

    def test_unavailable_vehicle_rejected_even_with_rebound_digest(self):
        s, p = self.changed_input(lambda x: x["vehicles"][0].update(available_for_planning=False))
        self.rejects(p, "AUTHORITY", s)

    def test_capacity_uses_input_weights_not_reported_load(self):
        s, p = self.changed_input(lambda x: x["vehicles"][0].update(capacity_kg=20))
        self.rejects(p, "CAPACITY", s)

    def test_load_report_is_recomputed(self):
        self.rejects(self.change_stop(cumulative_load_kg=1), "LOAD_REPORT")

    def test_nan_load_report_is_rejected(self):
        self.rejects(self.change_stop(cumulative_load_kg=float("nan")), "LOAD_REPORT")

    def test_time_window_end_checks_service_completion(self):
        def edit(x):
            x["tasks"][0]["time_window"]["end"] = "2026-10-24T00:18:00Z"
        s, p = self.changed_input(edit)
        self.rejects(p, "TIME_WINDOW", s)

    def test_time_window_start_is_checked(self):
        def edit(x):
            x["tasks"][0]["time_window"]["start"] = "2026-10-24T00:15:00Z"
        s, p = self.changed_input(edit)
        self.rejects(p, "TIME_WINDOW", s)

    def test_service_duration_cannot_be_shortened(self):
        self.rejects(self.change_stop(departure_us=self.stop.departure_us-1), "SERVICE_DURATION")

    def test_travel_arrival_cannot_be_fabricated(self):
        self.rejects(self.change_stop(arrival_us=0), "SCHEDULE")

    def test_schedule_boolean_is_not_an_integer(self):
        self.rejects(self.change_stop(service_start_us=True), "SCHEDULE")

    def test_route_duration_is_independently_recomputed(self):
        s, p = self.changed_input(lambda x: x["vehicles"][0].update(max_route_minutes=18))
        self.rejects(p, "DURATION", s)

    def test_return_time_cannot_omit_return_travel(self):
        bad = replace(self.p, routes=(replace(self.route, return_us=self.stop.departure_us),))
        self.rejects(bad, "SCHEDULE")

    def test_start_depot_location_is_checked(self):
        self.rejects(replace(self.p, routes=(replace(self.route, start_location_id="HUB"),)), "DEPOT")

    def test_end_depot_node_is_checked(self):
        self.rejects(replace(self.p, routes=(replace(self.route, end_node_id="TOY-DONOR"),)), "DEPOT")

    def test_departure_is_frozen_cutoff(self):
        self.rejects(replace(self.p, routes=(replace(self.route, departure_us=1),)), "DEPARTURE")

    def test_pickup_must_be_authorized_source(self):
        self.rejects(self.change_stop(location_id="WRONG-DONOR"), "PICKUP_LOCATION")

    def test_hub_batch_uses_selected_hub(self):
        self.s = load_scenario(EXAMPLES/"hub_only.json")
        self.p = fcfs(self.s)
        self.route, self.stop = self.p.routes[0], self.p.routes[0].stops[0]
        self.rejects(self.change_stop(location_id="WRONG-HUB"), "HUB_PICKUP")

    def test_missing_arc_is_not_a_zero_cost_shortcut(self):
        def edit(x):
            x["matrix"]["unavailable_policy"] = "FORBID_ARC"
            x["matrix"]["arc_status"][0][1] = "MISSING"
            x["matrix"]["distance_km"][0][1] = None
            x["matrix"]["travel_minutes"][0][1] = None
        s, p = self.changed_input(edit)
        self.rejects(p, "ARC_UNAVAILABLE", s)

    def test_unknown_matrix_node_rejected(self):
        self.rejects(self.change_stop(road_node_id="UNKNOWN-NODE"), "ARC_UNAVAILABLE")

    def test_unserved_complement_is_exact(self):
        self.rejects(replace(self.p, unserved_tasks=("TOY-DIRECT",), unserved_reasons=(("TOY-DIRECT", "FAKE"),)), "UNSERVED_ACCOUNTING")

    def test_unserved_reasons_required(self):
        p = replace(self.p, routes=(), unserved_tasks=("TOY-DIRECT",), unserved_reasons=(), status="INFEASIBLE", feasible=False)
        self.rejects(p, "UNSERVED_ACCOUNTING")

    def test_mandatory_omission_cannot_claim_feasibility(self):
        p = replace(self.p, routes=(), unserved_tasks=("TOY-DIRECT",),
                    unserved_reasons=(("TOY-DIRECT", "NOT_SERVED"),), status="PARTIAL", feasible=True)
        self.rejects(p, "MANDATORY")

    def test_mandatory_omission_can_be_reported_as_infeasible_candidate(self):
        p = replace(self.p, routes=(), unserved_tasks=("TOY-DIRECT",),
                    unserved_reasons=(("TOY-DIRECT", "NOT_SERVED"),), status="INFEASIBLE", feasible=False)
        v = validate_plan(self.s, p)
        self.assertTrue(v.valid)
        self.assertFalse(v.feasible)
        self.assertEqual(v.mandatory_unserved, ("TOY-DIRECT",))
        self.assertFalse(p.infeasibility_proven)

    def test_stale_plan_input_digest_is_rejected(self):
        self.rejects(replace(self.p, snapshot_sha256="0"*64), "PLAN_STALE")

    def test_stale_matrix_digest_is_rejected(self):
        self.rejects(replace(self.p, matrix_sha256="0"*64), "PLAN_STALE")

    def test_synthetic_offline_plan_cannot_grant_dispatch(self):
        self.rejects(replace(self.p, dispatch_authority_issued=True), "AUTHORITY")

    def test_nonconfirmed_source_task_cannot_be_smuggled_into_plan(self):
        s, p = self.changed_input(lambda x: x["tasks"][0].update(task_status="STALE"))
        self.rejects(p, "AUTHORITY", s)

    def test_no_empty_vehicle_trip(self):
        self.rejects(replace(self.p, routes=(replace(self.route, stops=()),)), "EMPTY_ROUTE")

    def test_partial_status_with_no_unserved_is_inconsistent(self):
        self.rejects(replace(self.p, status="PARTIAL"), "STATUS")


if __name__ == "__main__":
    unittest.main()
