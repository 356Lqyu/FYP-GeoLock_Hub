"""Input preparation/safety tests only; never executes routing experiments."""
from copy import deepcopy
from dataclasses import replace
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from .adapter import Adapter, check_settings
from .runner import baseline_plan, execution_gate, preflight, run
from ..phase_b import validate_plan
from ..phase_b.models import ExecutionConfig
from ..phase_b.problem import Problem


class AdapterTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.settings = json.loads(Path(__file__).with_name('proposed_settings.json').read_text())
        cls.adapter = Adapter(cls.settings)
        cls.pairs = [cls.adapter.convert(s) for s in cls.adapter.scenarios]

    def test_integrity_all_csv_and_archive_files(self):
        report = self.adapter.integrity
        self.assertEqual(len(report['csv']), 15)
        self.assertTrue(all(r['pass_check'] for r in report['csv'].values()))
        self.assertEqual(sum(r['files'] for r in report['archives'].values()), 84)

    def test_all_100_scenarios_convert_without_solving(self):
        self.assertEqual(len(self.pairs), 100)
        self.assertEqual(sum(len(f.admitted_task_ids) for _, f in self.pairs), 499)

    def test_identical_admission_for_both_interfaces(self):
        for shared, frozen in self.pairs:
            self.assertEqual({t['task_id'] for t in shared['tasks']}, set(frozen.admitted_task_ids))
            for v in frozen.to_dict()['input']['vehicles']:
                raw = next(x for x in shared['fleet'] if x['vehicle_id']==v['vehicle_id'])
                self.assertEqual(raw['capacity_kg'], v['capacity_kg'])
                self.assertEqual(raw['depot_road_node_id'], frozen.to_dict()['input']['depot']['road_node_id'])

    def test_matrix_costs_direction_and_unavailability_preserved(self):
        unavailable = 0
        for _, frozen in self.pairs:
            m = frozen.to_dict()['input']['matrix']
            for i,a in enumerate(m['node_order']):
                for j,b in enumerate(m['node_order']):
                    raw = self.adapter.data.matrix[a,b]
                    if raw['route_available_flag']=='1':
                        self.assertEqual(m['distance_km'][i][j], float(raw['road_distance_km']))
                        self.assertEqual(m['travel_minutes'][i][j], float(raw['travel_time_min']))
                    else:
                        unavailable += 1
                        self.assertEqual(m['arc_status'][i][j], 'UNREACHABLE')
                        self.assertIsNone(m['distance_km'][i][j])
        self.assertGreater(unavailable, 0)

    def test_expiry_difference_is_explicit_and_sealed(self):
        excluded = [(s['scenario_id'], f.excluded_tasks) for s,f in self.pairs if f.excluded_tasks]
        self.assertEqual(excluded, [('SCN-ROUTE_PLANNING-0066', (('TASK-LST000005', ('LISTING_EXPIRES_BEFORE_HORIZON',)),))])
        for s,_ in self.pairs:
            unsealed = dict(s); seal = unsealed.pop('snapshot_id')
            self.assertEqual(seal, self.adapter.base.digest(unsealed))

    def test_reject_policy_blocks_admission_mismatch(self):
        old = self.adapter.settings['listing_expiry_policy']
        try:
            self.adapter.settings['listing_expiry_policy'] = 'REJECT_DIFFERENCES'
            with self.assertRaisesRegex(ValueError, 'ADMISSION_DIFFERS'):
                self.adapter.convert(self.adapter.scenarios[65])
        finally:
            self.adapter.settings['listing_expiry_policy'] = old

    def test_no_operational_provenance_or_mutable_frozen_copy(self):
        _, frozen = self.pairs[0]
        p = frozen.to_dict()['input']
        self.assertIsNone(p['source']['project_ref'])
        self.assertEqual(p['matrix']['matrix_id'], 'OSM-DIRECTED-v3.2')
        p['tasks'].clear()
        self.assertTrue(frozen.admitted_task_ids)

    def test_policy_rejects_unsupported_changes(self):
        for field,value in [('mandatory',True),('currency','RM'),('lease_minutes',240),
                            ('availability_policy','DONOR_WINDOWS'),('fixed_cost',float('nan'))]:
            s = deepcopy(self.settings); s[field]=value
            with self.assertRaises(ValueError):check_settings(s)

    def test_approval_gate_prevents_results_directory(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d)/'never-created'
            with self.assertRaisesRegex(ValueError, 'EXPERIMENT_NOT_APPROVED'):
                run(self.adapter, path, execute=True)
            self.assertFalse(path.exists())
        with self.assertRaises(ValueError):execution_gate(dict(self.settings,approved=True),False)

    def test_independent_validator_rejects_bad_unserved_accounting(self):
        _, frozen = self.pairs[0]
        # Explicit empty test plan, not an algorithm run or experiment result.
        plan = Problem(frozen).finish('INPUT_TEST_ONLY', (), ExecutionConfig())
        self.assertTrue(validate_plan(frozen, plan).valid)
        self.assertFalse(validate_plan(frozen, replace(plan, unserved_tasks=())).valid)

    def test_preflight_is_not_solver_evidence(self):
        with patch.object(self.adapter.modules['fcfs'], 'plan_routes', side_effect=AssertionError('Experiment called')), \
             patch.object(self.adapter.modules['nearest_next'], 'plan_routes', side_effect=AssertionError('Experiment called')), \
             patch('backend.routing.benchmark_v32.runner.proposed', side_effect=AssertionError('Solver called')):
            result = preflight(self.adapter)
        self.assertFalse(result['experiment_executed'])
        self.assertEqual(result['scenario_count'],100)

    def test_missing_arc_fails_without_distance_fallback(self):
        _, frozen = self.pairs[0]
        nodes = frozen.to_dict()['input']['matrix']['node_order']
        key = (nodes[0], nodes[1])
        removed = self.adapter.data.matrix.pop(key)
        try:
            with self.assertRaisesRegex(ValueError, 'MISSING_MATRIX_PAIR'):
                self.adapter.convert(self.adapter.scenarios[0])
        finally:
            self.adapter.data.matrix[key] = removed


if __name__ == '__main__':
    unittest.main()
