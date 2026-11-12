"""Offline regressions for E4-only admission and exact-task matching."""
import csv
import hashlib
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(HERE))
import e4_shared  # noqa: E402

COMPARE_PATH = ROOT / 'experiments/e4/experiment_result/source_code/e4_compare.py'
spec = importlib.util.spec_from_file_location('e4_compare_under_test', COMPARE_PATH)
compare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(compare)


class E4AdmissionTests(unittest.TestCase):
    def test_all_frozen_snapshots_admit_five_tasks_without_listing_expiry(self):
        adapter = e4_shared.Adapter()
        original_expiries = {key: row['listing_expires_at'] for key, row in adapter.data.listings.items()}
        seen = set()
        # The adapter only reads OR-Tools' version for frozen metadata. Stub
        # that package here so admission tests do not require a solver install.
        with patch.dict(sys.modules, {'ortools': SimpleNamespace(__version__='offline-test')}):
            for scenario in adapter.scenarios:
                shared, frozen = adapter.convert(scenario)
                task_ids = {task['task_id'] for task in shared['tasks']}
                self.assertEqual(len(task_ids), 5, scenario['scenario_id'])
                self.assertEqual(task_ids, set(frozen.admitted_task_ids))
                self.assertFalse(frozen.excluded_tasks)
                seen.update(task_ids)
                for task in frozen.to_dict()['input']['tasks']:
                    self.assertIsNone(task['listing_expires_at'])
                    self.assertEqual(task['task_status'], 'CONFIRMED')
                    self.assertEqual(task['claim_status'], 'ACTIVE')
                    self.assertEqual(task['lease_status'], 'ACTIVE')
                    self.assertEqual(task['ngo_id'], task['claim_ngo_id'])
                    self.assertIsNotNone(task['lease_expires_at'])
                    self.assertEqual(task['time_window']['provenance'],
                                     'Explicit baseline-equivalent routing horizon; donor availability NOT evaluated')
                    self.assertGreater(task['weight_kg'], 0)
                payload = frozen.to_dict()['input']
                self.assertEqual(payload['configuration']['planning_horizon_minutes'], 240)
                self.assertEqual(payload['route_start_location_id'], payload['route_end_location_id'])
                self.assertTrue(all(vehicle['capacity_kg'] > 0 and vehicle['max_route_minutes'] == 240
                                    for vehicle in payload['vehicles']))
                self.assertEqual(payload['matrix']['network_snapshot_id'], 'OSM-DIRECTED-v3.3')
                self.assertTrue(all(status in ('AVAILABLE', 'UNREACHABLE')
                                    for row in payload['matrix']['arc_status'] for status in row))
        self.assertEqual(len(adapter.scenarios), 100)
        self.assertEqual(len(seen), 500)
        self.assertEqual(original_expiries,
                         {key: row['listing_expires_at'] for key, row in adapter.data.listings.items()})


class E4MatchedTaskTests(unittest.TestCase):
    def test_figure4_values_are_derived_from_saved_comparison_metrics(self):
        metrics = {
            'primary_vs_nearest_next': {
                'distance_identical_task_set': {
                    'hl_km': -2.69625, 'ci95': [-3.77331875, -2.054], 'snapshots': 91,
                },
            },
            'descriptive_vs_fcfs': {
                'distance_identical_task_set': {
                    'hl_km': -11.3795, 'ci95': [-13.24375, -9.4615], 'snapshots': 79,
                },
            },
        }
        rows = compare.matched_task_savings_rows(metrics)
        self.assertEqual([row['snapshots'] for row in rows], [91, 79])
        self.assertEqual([round(row['estimate_km'], 2) for row in rows], [2.70, 11.38])
        self.assertEqual([(round(row['ci95_low_km'], 2), round(row['ci95_high_km'], 2))
                          for row in rows], [(2.05, 3.77), (9.46, 13.24)])

    def test_equal_counts_with_different_task_ids_are_not_matched(self):
        ids = ['s1', 's2', 's3']
        p = {sid: {'served_tasks': '2', 'independent_check_passed': 'YES'} for sid in ids}
        b = {sid: {'served_tasks': '2', 'independent_check_passed': 'YES'} for sid in ids}
        proposed = {'s1': {'a', 'b'}, 's2': {'a', 'b'}, 's3': {'a', 'c'}}
        baseline = {'s1': {'a', 'b'}, 's2': {'a', 'c'}, 's3': {'a', 'c'}}
        self.assertEqual(compare.matched_task_scenarios(p, b, ids, proposed, baseline), ['s1', 's3'])

    def test_failed_independent_validation_excludes_pair(self):
        ids = ['s1']
        p = {'s1': {'served_tasks': '1', 'independent_check_passed': 'YES'}}
        b = {'s1': {'served_tasks': '1', 'independent_check_passed': 'NO'}}
        tasks = {'s1': {'task-a'}}
        self.assertEqual(compare.matched_task_scenarios(p, b, ids, tasks, tasks), [])

    def test_route_detail_task_ids_are_reconstructed_and_counts_checked(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'routes.csv'
            with path.open('w', newline='', encoding='utf-8') as stream:
                writer = csv.DictWriter(stream, fieldnames=['scenario_id', 'vehicle_id', 'stops_in_order', 'stops'])
                writer.writeheader()
                writer.writerow(dict(scenario_id='s1', vehicle_id='v1', stops_in_order='TASK-a > TASK-b', stops=2))
            actual = compare.read_served_task_sets(path, ['s1'], {'s1': {'served_tasks': '2'}})
            self.assertEqual(actual['s1'], {'TASK-a', 'TASK-b'})
            with self.assertRaisesRegex(ValueError, 'disagree'):
                compare.read_served_task_sets(path, ['s1'], {'s1': {'served_tasks': '1'}})

    def test_methods_must_share_run_and_inputs(self):
        keys = {'optimiser': 'or_tools_route_optimiser', 'nearest_next': 'nearest_next', 'fcfs': 'fcfs'}
        manifests = {key: dict(method=method, run_id='same', settings={'x': 1},
                               input_sha256={'dataset': 'hash'}, source_sha256={'source': 'hash'},
                               environment={'python': '3.x', 'platform': 'test', 'packages': {'ortools': 'x'}})
                     for key, method in keys.items()}
        self.assertEqual(compare.validate_run_manifests(manifests), 'same')
        for field, bad in (('run_id', 'different'), ('settings', {'x': 2}),
                           ('input_sha256', {'dataset': 'different'}),
                           ('source_sha256', {'source': 'different'})):
            altered = {key: dict(value) for key, value in manifests.items()}
            altered['fcfs'][field] = bad
            with self.assertRaises(ValueError):
                compare.validate_run_manifests(altered)
        altered = {key: dict(value, environment=dict(value['environment'])) for key, value in manifests.items()}
        altered['fcfs']['environment']['platform'] = 'different'
        with self.assertRaisesRegex(ValueError, 'environment.platform'):
            compare.validate_run_manifests(altered)

    def test_saved_result_artifact_hashes_are_verified(self):
        with tempfile.TemporaryDirectory() as tmp:
            paths = {}
            manifests = {}
            for method in ('optimiser', 'nearest_next', 'fcfs'):
                path = Path(tmp) / f'{method}.csv'
                path.write_text(method, encoding='utf-8')
                digest = hashlib.sha256(path.read_bytes()).hexdigest()
                paths[method] = {'results.csv': path}
                manifests[method] = {'artifact_sha256': {'results.csv': digest}}
            compare.validate_result_artifacts(manifests, paths)
            paths['fcfs']['results.csv'].write_text('changed', encoding='utf-8')
            with self.assertRaisesRegex(ValueError, 'artifact hash mismatch'):
                compare.validate_result_artifacts(manifests, paths)


if __name__ == '__main__':
    unittest.main()
