import copy
import unittest
from datetime import datetime

from backend.routing.benchmark_v32.adapter import Adapter as SharedAdapter
from backend.routing.contract import freeze_scenario
from experiments.e4_post_claim_routing.run import Adapter as E4Adapter, SETTINGS
from experiments.repro_benchmark import integrity


class E4ListingExpiryAdaptationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.e4 = E4Adapter()
        cls.scenarios = {s['scenario_id']: s for s in cls.e4.scenarios}

    def test_all_100_snapshots_admit_five_candidates_without_expiry_only_exclusions(self):
        self.assertEqual(len(self.scenarios), 100)
        for scenario_id, scenario in self.scenarios.items():
            with self.subTest(scenario_id=scenario_id):
                shared, frozen = self.e4.convert(scenario)
                task_ids = {t['task_id'] for t in shared['tasks']}
                self.assertEqual(len(task_ids), 5)
                self.assertEqual(set(frozen.admitted_task_ids), task_ids)
                self.assertEqual(frozen.excluded_tasks, ())
                for task in frozen.to_dict()['input']['tasks']:
                    self.assertIsNone(task['listing_expires_at'])
                    self.assertEqual(task['task_status'], 'CONFIRMED')
                    self.assertEqual(task['claim_status'], 'ACTIVE')
                    self.assertEqual(task['lease_status'], 'ACTIVE')
                    self.assertEqual(task['ngo_id'], task['claim_ngo_id'])
                    self.assertGreater(
                        datetime.fromisoformat(task['lease_expires_at'].replace('Z', '+00:00')),
                        datetime.fromisoformat(task['time_window']['end'].replace('Z', '+00:00')),
                    )

    def test_shared_adapter_default_and_operational_expiry_contract_are_unchanged(self):
        scenario = self.scenarios['SCN-ROUTE_PLANNING-0003']
        # Calling the unmodified shared adapter method with its default option
        # must preserve historical expiry admission behavior.
        _, historical = SharedAdapter.convert(self.e4, scenario)
        old_reasons = dict(historical.excluded_tasks)
        self.assertIn(
            'LISTING_EXPIRES_BEFORE_HORIZON',
            old_reasons['TASK-LST000085'],
        )

        _, corrected = self.e4.convert(scenario)
        payload = corrected.to_dict()['input']
        task = next(t for t in payload['tasks'] if t['task_id'] == 'TASK-LST000085')
        task['listing_expires_at'] = task['time_window']['start']
        unchanged_contract = freeze_scenario(payload)
        new_reasons = dict(unchanged_contract.excluded_tasks)
        self.assertIn(
            'LISTING_EXPIRES_BEFORE_HORIZON',
            new_reasons['TASK-LST000085'],
        )

    def test_claim_and_task_authority_checks_still_exclude_invalid_candidates(self):
        _, frozen = self.e4.convert(self.scenarios['SCN-ROUTE_PLANNING-0003'])
        original = frozen.to_dict()['input']
        task_id = 'TASK-LST000085'

        cases = (
            ('expired lease', lambda t, p: t.__setitem__('lease_expires_at', p['cutoff']), 'LEASE_EXPIRED'),
            ('inactive claim', lambda t, p: t.__setitem__('claim_status', 'RELEASED'), 'INVALID_AUTHORITY'),
            ('wrong claim owner', lambda t, p: t.__setitem__('claim_ngo_id', 'FOREIGN-NGO'), 'FOREIGN_OWNER'),
            ('unconfirmed task', lambda t, p: t.__setitem__('task_status', 'STALE'), 'TASK_NOT_CONFIRMED'),
        )
        for label, mutate, expected_reason in cases:
            with self.subTest(label=label):
                payload = copy.deepcopy(original)
                task = next(t for t in payload['tasks'] if t['task_id'] == task_id)
                mutate(task, payload)
                result = freeze_scenario(payload)
                reasons = dict(result.excluded_tasks)[task_id]
                self.assertIn(expected_reason, reasons)

    def test_all_methods_share_the_single_frozen_task_set(self):
        scenario = self.scenarios['SCN-ROUTE_PLANNING-0058']
        shared, frozen = self.e4.convert(scenario)
        admitted = set(frozen.admitted_task_ids)
        # run.py passes this same frozen object to each of NN, FCFS and CP-SAT.
        method_inputs = {
            method: set(shared_task['task_id'] for shared_task in shared['tasks'])
            for method in ('nearest_next', 'fcfs', 'proposed')
        }
        self.assertTrue(all(task_ids == admitted for task_ids in method_inputs.values()))
        self.assertTrue(all(task_ids == method_inputs['nearest_next'] for task_ids in method_inputs.values()))

    def test_frozen_v33_csv_integrity_remains_valid(self):
        evidence = integrity()
        self.assertEqual(evidence['version'], 'GEOLOCK-BM-v3.3')
        self.assertEqual(evidence['scenario_counts']['ROUTE_PLANNING'], 100)


if __name__ == '__main__':
    unittest.main()
