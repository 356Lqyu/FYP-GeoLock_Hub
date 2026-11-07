"""Regression tests for timeout reporting; policy tests do not activate policy."""
from copy import deepcopy
from dataclasses import asdict
from pathlib import Path
import unittest
from unittest.mock import patch
from backend.routing.contract import freeze_scenario
from backend.routing.generate_examples import build_mixed
from backend.routing.phase_b import proposed,validate_plan
from backend.routing.phase_b.problem import Problem
from backend.routing.phase_b import routing_model
from backend.routing.diagnostics.policy_proposal import classify
from backend.routing.diagnostics.reproducibility import fixtures,sha,canonical

class ReproducibilityTests(unittest.TestCase):
    def one(self):
        p=build_mixed();p['tasks']=p['tasks'][:1];p['vehicles']=p['vehicles'][:1];p['solver']['time_limit_seconds']=.1
        return freeze_scenario(p)
    def test_postprocessing_cannot_retroactively_create_timeout(self):
        from ortools.constraint_solver import pywrapcp
        now=[0.0];original=Problem.schedule
        def slow_reporting(problem,*args):
            route=original(problem,*args);now[0]=100.0;return route
        snapshot=self.one()
        with patch.object(routing_model,'perf_counter',lambda:now[0]),patch.object(Problem,'schedule',slow_reporting),patch.object(pywrapcp.RoutingModel,'CheckLimit',return_value=False):
            plan=routing_model.proposed(snapshot)
        self.assertFalse(plan.timeout);self.assertTrue(validate_plan(snapshot,plan).feasible)
    def test_native_limit_is_reported_even_before_python_deadline(self):
        from ortools.constraint_solver import pywrapcp
        with patch.object(routing_model,'perf_counter',return_value=0.0),patch.object(pywrapcp.RoutingModel,'CheckLimit',return_value=True):
            plan=routing_model.proposed(self.one())
        self.assertTrue(plan.timeout);self.assertFalse(plan.infeasibility_proven)
    def test_primary_one_solution_stop_is_not_a_time_limit(self):
        from ortools.constraint_solver import pywrapcp
        # Controlled native-limit metadata: coverage stop true, secondary false.
        with patch.object(pywrapcp.RoutingModel,'CheckLimit',side_effect=[True,False]):
            plan=routing_model.proposed(self.one())
        self.assertFalse(plan.timeout);self.assertTrue(plan.feasible)
    def test_ordering_permutations_preserve_route_and_metrics(self):
        p=build_mixed();p['solver']['time_limit_seconds']=.1
        a=freeze_scenario(p);q=deepcopy(p);q['tasks'].reverse();q['vehicles'].reverse();b=freeze_scenario(q)
        pa,pb=proposed(a),proposed(b)
        self.assertEqual(pa.routes,pb.routes)
        self.assertEqual(validate_plan(a,pa).metrics,validate_plan(b,pb).metrics)
    def test_diagnostic_fixtures_preserve_approved_profile(self):
        cases=fixtures();self.assertEqual(len(cases),8)
        for name,p in cases.items():
            with self.subTest(name=name):
                freeze_scenario(p)
                self.assertEqual(p['solver']['time_limit_seconds'],30)
                self.assertEqual(p['solver']['workers'],1)
                self.assertEqual(p['solver']['first_solution'],'PATH_CHEAPEST_ARC')
                self.assertEqual(p['solver']['local_search'],'GUIDED_LOCAL_SEARCH')
                self.assertTrue(all(t['service_minutes']==10 for t in p['tasks']))
                self.assertTrue(all(v['max_route_minutes']==240 for v in p['vehicles']))
    def test_canonical_hash_is_stable_for_dictionary_order(self):
        self.assertEqual(sha({'a':1,'b':2}),sha({'b':2,'a':1}))
    def test_runtime_is_part_of_unchanged_raw_candidate_hash(self):
        a={'plan':{'routes':[],'runtime_seconds':1}};b=deepcopy(a);b['plan']['runtime_seconds']=2
        self.assertNotEqual(sha(a),sha(b))
    def record(self):
        return dict(snapshot_sha256='s',matrix_sha256='m',solver_version='v',python='p',platform='o',hash_seed='0',
            routes_sha256='r',metrics_sha256='t',candidate_canonical_json='c',validation=dict(valid=True,feasible=True))
    def test_inactive_policy_reports_equal_metric_route_variation(self):
        a=self.record();b=deepcopy(a);b['routes_sha256']='other'
        result=classify(a,b)
        self.assertEqual(result['diagnostic_class'],'DIFFERENT_VALID_SOLUTIONS_EQUAL_METRICS')
        self.assertFalse(result['activated']);self.assertFalse(result['grants_authority'])
    def test_inactive_policy_rejects_invalid_and_mismatched_inputs(self):
        a=self.record();b=deepcopy(a);b['validation']['valid']=False
        self.assertEqual(classify(a,b)['diagnostic_class'],'INVALID_REJECT')
        b=self.record();b['matrix_sha256']='other'
        self.assertEqual(classify(a,b)['diagnostic_class'],'NOT_COMPARABLE')
    def test_inactive_policy_does_not_hide_variable_metrics(self):
        a=self.record();b=deepcopy(a);b['metrics_sha256']='different'
        self.assertEqual(classify(a,b)['diagnostic_class'],'VARIABLE_VALID_METRICS_REPORT_DISTRIBUTION')
    def test_inactive_policy_does_not_compare_different_execution_weights(self):
        a=self.record();b=deepcopy(a)
        a['candidate']={'plan':{'config':{'fixed_cost_weight':1}}}
        b['candidate']={'plan':{'config':{'fixed_cost_weight':2}}}
        self.assertEqual(classify(a,b)['diagnostic_class'],'NOT_COMPARABLE')
    def test_original_guard_file_remains_byte_for_byte(self):
        root=Path(__file__).resolve().parents[4]
        self.assertEqual((root/'backend/routing/phase_b/benchmark.py').read_bytes(),(root/'results/stage-b3/pre-correction/benchmark.py').read_bytes())

if __name__=='__main__':unittest.main(verbosity=2)
