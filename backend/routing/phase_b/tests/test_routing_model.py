"""Actual RoutingModel calls, synthetic frozen cases, independent validation."""
from copy import deepcopy
from dataclasses import asdict
import unittest
from unittest.mock import patch
from ortools.constraint_solver import pywrapcp
from backend.routing.contract import freeze_scenario
from backend.routing.generate_examples import build_mixed
from backend.routing.phase_b import validate_plan,METHODS,routing_model_proposed as proposed
from backend.routing.phase_b.scenarios import edge_payloads
from backend.routing.phase_b.models import ExecutionConfig


class RoutingModelTests(unittest.TestCase):
    def solve(self,payload=None,seconds=.1):
        p=deepcopy(payload or build_mixed());p['solver']['time_limit_seconds']=seconds
        s=freeze_scenario(p);plan=proposed(s);validation=validate_plan(s,plan)
        self.assertTrue(validation.valid,validation.violations)
        self.assertFalse(plan.dispatch_authority_issued)
        return s,plan,validation

    def test_actual_native_routing_model_and_supported_profile(self):
        calls=[];original=pywrapcp.RoutingModel.SolveWithParameters
        def spy(model,p):
            calls.append((p.first_solution_strategy,p.local_search_metaheuristic,p.use_cp,p.use_cp_sat,p.time_limit.ToMilliseconds()))
            return original(model,p)
        budget_seconds = 1
        with patch.object(pywrapcp.RoutingModel, 'SolveWithParameters', spy):
            _, plan, _ = self.solve(seconds=budget_seconds)
        diagnostic = (
            f"plan status={plan.status}, native statuses={plan.solver_statuses}, "
            f"native search parameters={calls}"
        )
        self.assertTrue(calls, diagnostic)
        self.assertTrue(all(c[2:4] == (3, 2) for c in calls), diagnostic)
        self.assertTrue(all(c[4] <= budget_seconds * 1000 for c in calls), diagnostic)
        self.assertTrue(plan.feasible, diagnostic)
        self.assertTrue(all(s.startswith('ROUTING_MODEL:') for s in plan.solver_statuses), diagnostic)

    def test_single_task(self):
        p=build_mixed();p['tasks']=p['tasks'][:1];p['vehicles']=p['vehicles'][:1]
        _,plan,v=self.solve(p);self.assertEqual(v.metrics['served_count'],1);self.assertTrue(plan.feasible)

    def test_multiple_tasks_and_depot_return(self):
        s,p,v=self.solve();self.assertEqual(v.metrics['served_count'],2)
        self.assertTrue(all(r.start_node_id==r.end_node_id==s.to_dict()['input']['depot']['road_node_id'] for r in p.routes))

    def test_multiple_vehicle_cost_tradeoff(self):
        _,p,v=self.solve(edge_payloads()['cost_tradeoff']);self.assertTrue(p.feasible)
        self.assertEqual(v.metrics['served_count'],2);self.assertLess(v.metrics['total_cost'],111)

    def test_capacity_and_duration_and_window_infeasibility(self):
        for name in ('capacity_infeasible','duration_infeasible','window_infeasible'):
            with self.subTest(case=name):
                _,p,_=self.solve(edge_payloads()[name]);self.assertFalse(p.feasible)
                self.assertIn(p.status,('INFEASIBLE','OPTIMISATION_TIMEOUT'))

    def test_waiting_and_ten_minute_service(self):
        _,_,v=self.solve(edge_payloads()['waiting']);self.assertEqual(v.metrics['total_route_minutes'],45)
        self.assertEqual(v.metrics['service_minutes'],10)

    def test_exact_duration_boundary(self):
        _,p,v=self.solve(edge_payloads()['exact_duration']);self.assertTrue(p.feasible)
        self.assertEqual(v.metrics['total_route_minutes'],19)

    def test_directed_no_return_is_not_faked(self):
        _,p,_=self.solve(edge_payloads()['no_return_arc']);self.assertFalse(p.feasible)

    def test_unreachable_optional_accounted_for(self):
        s,p,v=self.solve(edge_payloads()['unreachable_optional'])
        self.assertEqual(p.unserved_tasks,('TOY-HUB-TASK',));self.assertEqual(v.metrics['served_count'],1)

    def test_timeout_is_not_infeasibility_proof(self):
        _,p,_=self.solve(seconds=.000001);self.assertEqual(p.status,'OPTIMISATION_TIMEOUT')
        self.assertFalse(p.infeasibility_proven);self.assertIsNone(p.optimality_gap)

    def test_fixed_fixture_replay_and_input_digests(self):
        s,a,_=self.solve();_,b,_=self.solve()
        self.assertEqual(a.routes,b.routes);self.assertEqual(a.snapshot_sha256,s.sha256)
        self.assertEqual(a.matrix_sha256,s.matrix_sha256)

    def test_no_unproven_secondary_optimality_or_gap(self):
        _,p,_=self.solve();self.assertFalse(p.secondary_optimal);self.assertIsNone(p.optimality_gap)

    def test_cp_specific_budget_is_not_translated(self):
        p=build_mixed();p['solver']['time_limit_seconds']=.1;s=freeze_scenario(p)
        result=proposed(s,ExecutionConfig(deterministic_seconds_per_pass=0))
        self.assertTrue(result.feasible);self.assertTrue(result.solver_statuses[0].startswith('ROUTING_MODEL:'))

    def test_routing_model_remains_available_but_is_not_active_proposed_method(self):
        from backend.routing.phase_b.optimizers import distance_only,proposed as cp_sat_proposed
        self.assertIs(METHODS['distance_only'],distance_only)
        self.assertIs(METHODS['proposed'],cp_sat_proposed)
        self.assertIsNot(METHODS['proposed'],proposed)

    def test_legacy_routing_model_cost_precision_is_still_checked(self):
        p=build_mixed();p['solver']['time_limit_seconds']=.1
        with self.assertRaisesRegex(ValueError,'UNSUPPORTED_PRECISION'):
            proposed(freeze_scenario(p),ExecutionConfig(distance_cost_weight=.00000001))

    def test_independent_validator_rejects_tampered_plan(self):
        from dataclasses import replace
        s,p,_=self.solve();r=p.routes[0];stop=replace(r.stops[0],arrival_us=r.stops[0].arrival_us+1)
        tampered=replace(p,routes=(replace(r,stops=(stop,)+r.stops[1:]),)+p.routes[1:])
        self.assertFalse(validate_plan(s,tampered).valid)


if __name__=='__main__':unittest.main(verbosity=2)
