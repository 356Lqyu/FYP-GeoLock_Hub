"""Offline Stage 3J regressions: real threads, mocked DB/HTTP, no network."""
import copy
import json
import os
import re
import sys
import tempfile
import threading
import types
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch

import claim_concurrency_test as common
import claim_two_actor_acceptance as suite
import claim_e2e_contract as contract

DB = ('postgresql://postgres.rcgyuwiidqvrgbxswhqj:fake@'
      'aws-0-ap-northeast-2.pooler.supabase.com:5432/postgres?sslmode=require')
LISTINGS = [str(uuid.UUID(int=i)) for i in (101, 102)]


class Connection:
    def __init__(self, mode='pass'):
        self.mode = mode
        self.closed = False
        self.unlocked = threading.Event()
        self.condition = threading.Condition()
        self.waiters = self.finished = 0
        self.answer = None

    def cursor(self):
        return self

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False

    def execute(self, sql, params=None):
        if 'pg_backend_pid()' in sql:
            self.answer = (999,)
        elif 'FOR UPDATE' in sql:
            if self.mode == 'lock_error':
                raise RuntimeError('lock timeout')
            self.answer = None if self.mode == 'missing' else (LISTINGS[0],)
        elif 'pg_blocking_pids' in sql:
            if self.mode == 'observe_error':
                raise RuntimeError('observation unavailable')
            with self.condition:
                self.condition.wait_for(lambda: self.waiters == 2, timeout=1)
                self.answer = (0 if self.mode == 'inconclusive' else 3 if self.mode == 'extra' else self.waiters,)

    def fetchone(self):
        return self.answer

    def rollback(self):
        if self.mode == 'rollback_error':
            raise RuntimeError('rollback failed')
        self.unlocked.set()

    def close(self):
        self.closed = True
        self.unlocked.set()

    def worker(self, base, key, listing, token, request, barrier):
        barrier.wait(timeout=1)
        with self.condition:
            self.waiters += 1
            self.condition.notify_all()
        if not self.unlocked.wait(1):
            raise RuntimeError('REGRESSION: executor waited before unlocking')
        with self.condition:
            self.finished += 1
            n = self.finished
        if self.mode == 'worker_error':
            raise RuntimeError('worker rejected')
        return {'outcome': 'SUCCESS' if n == 1 else 'CONFLICT'}


class DelayedLockTests(unittest.TestCase):
    def run_case(self, mode, expected=None):
        conn = Connection(mode)
        fake = types.SimpleNamespace(connect=lambda *a, **kw: conn)
        with patch.dict(sys.modules, {'psycopg': fake}), \
             patch.object(common, 'claim_attempt', side_effect=conn.worker), \
             patch.object(common, 'assert_committed_round') as verify, \
             patch.object(common, 'DELAY_OBSERVATION_TIMEOUT_SECONDS', .01):
            if expected:
                with self.assertRaisesRegex(RuntimeError, expected):
                    common.run_delayed_race('base', 'key', 'read-key', DB, LISTINGS[0], ['a', 'b'], ['a', 'b'])
                verify.assert_not_called()
            else:
                common.run_delayed_race('base', 'key', 'read-key', DB, LISTINGS[0], ['a', 'b'], ['a', 'b'])
                verify.assert_called_once()
        self.assertTrue(conn.closed)
        self.assertTrue(conn.unlocked.is_set())
        if mode not in ('missing', 'lock_error'):
            self.assertEqual(conn.finished, 2, 'Every submitted worker must drain after unlock')

    def test_unlock_before_pool_shutdown(self):
        self.run_case('pass')

    def test_inconclusive_unlocks_and_drains_without_pass(self):
        self.run_case('inconclusive', 'INCONCLUSIVE')

    def test_observation_failure_unlocks_and_drains(self):
        self.run_case('observe_error', 'observation unavailable')

    def test_worker_error_is_not_pass(self):
        self.run_case('worker_error', 'worker rejected')

    def test_rollback_error_still_closes_before_pool_shutdown(self):
        self.run_case('rollback_error', 'rollback failed')

    def test_missing_row_closes_connection(self):
        self.run_case('missing', 'disappeared')

    def test_lock_acquisition_timeout_closes_connection(self):
        self.run_case('lock_error', 'lock timeout')

    def test_unexpected_third_waiter_blocks_and_drains(self):
        self.run_case('extra', 'competing')

    def test_partial_submit_failure_unlocks_before_executor_exit(self):
        conn = Connection()
        real = common.concurrent.futures.ThreadPoolExecutor

        class FailSecondSubmit(real):
            calls = 0

            def submit(self, *args, **kwargs):
                self.calls += 1
                if self.calls == 2:
                    raise RuntimeError('submit failed')
                return super().submit(*args, **kwargs)

            def __exit__(self, *args):
                if not conn.closed:
                    raise AssertionError('Executor exit happened before blocker close')
                return super().__exit__(*args)

        with patch.dict(sys.modules, {'psycopg': types.SimpleNamespace(connect=lambda *a, **kw: conn)}), \
             patch.object(common.concurrent.futures, 'ThreadPoolExecutor', FailSecondSubmit), \
             patch.object(common.threading, 'Barrier', return_value=types.SimpleNamespace(wait=lambda **kw: None)), \
             patch.object(common, 'claim_attempt', side_effect=conn.worker):
            with self.assertRaisesRegex(RuntimeError, 'submit failed'):
                common.run_delayed_race('b', 'k', 's', DB, LISTINGS[0], ['a', 'b'], ['a', 'b'])
        self.assertTrue(conn.closed)
        self.assertEqual(conn.finished, 1)


class SafetyTests(unittest.TestCase):
    def test_actual_rpc_fixture_bodies_equal_frozen_deployed_source(self):
        catalog = json.loads((suite.PACKAGE.parent/'function_catalog.json').read_text(encoding='utf-8'))
        source = (suite.ROOT/'supabase/tests/fixtures/claim_recovery_automatic_live_rpcs.sql').read_text(encoding='utf-8')
        for name in ('claim_listing', 'start_pickup', 'complete_pickup', 'cancel_claim'):
            live = next(f['definition'] for f in catalog['functions'] if f['identity'].startswith(name+'('))
            a = re.search(r'CREATE OR REPLACE FUNCTION public\.'+name+r'\(.*?AS (\$\w*\$)(.*?)\1', source, re.S)
            b = re.search(r'AS (\$\w*\$)(.*?)\1', live, re.S)
            self.assertEqual(a[2].replace('\r\n','\n'), b[2].replace('\r\n','\n'))

    def environment(self):
        return dict(GEOLOCK_TEST_CONFIRMATION=common.CONFIRMATION,
                    GEOLOCK_TEST_SUPABASE_URL='https://' + common.DEV_PROJECT_REF + '.supabase.co',
                    GEOLOCK_TEST_PROJECT_REF=common.DEV_PROJECT_REF,
                    GEOLOCK_TEST_ALLOWED_PROJECT_REFS=common.DEV_PROJECT_REF,
                    GEOLOCK_TEST_PUBLISHABLE_KEY='public-test-only',
                    GEOLOCK_TEST_SERVICE_ROLE_KEY='private-test-only',
                    GEOLOCK_TEST_NGO_JWT_TOKENS=json.dumps(['test-a', 'test-b']),
                    GEOLOCK_TEST_LISTING_IDS=json.dumps(LISTINGS))

    def test_two_sessions_and_two_fixtures_do_not_require_ten(self):
        with patch.dict(os.environ, self.environment(), clear=True):
            result = common.safety_gate(2, 2)
        self.assertEqual(result[-2:], (['test-a', 'test-b'], LISTINGS))

    def test_original_suite_keeps_ten_session_requirement(self):
        with patch.dict(os.environ, self.environment(), clear=True):
            with self.assertRaisesRegex(RuntimeError, '10'):
                common.safety_gate()

    def test_shared_project_is_rejected_before_network(self):
        env = self.environment()
        env['GEOLOCK_TEST_SUPABASE_URL'] = 'https://' + common.BLOCKED_PROJECT_REF + '.supabase.co'
        with patch.dict(os.environ, env, clear=True):
            with self.assertRaisesRegex(RuntimeError, 'allowlist'):
                common.safety_gate(2, 2)

    def test_retained_stage3i_fixture_is_blocked(self):
        env = self.environment()
        env['GEOLOCK_TEST_LISTING_IDS'] = json.dumps([LISTINGS[0], '95d6cd51-866b-4eec-8a36-36dc24296aec'])
        with patch.dict(os.environ, env, clear=True):
            with self.assertRaisesRegex(RuntimeError, 'Retained'):
                common.safety_gate(2, 2)

    def test_execute_without_approval_stops_before_credentials(self):
        with patch.object(sys, 'argv', ['runner', '--execute', '--env-file', 'unused', '--manifest', 'unused', '--output-dir', 'unused']), \
             patch.object(common, 'load_env_file') as load:
            with self.assertRaisesRegex(RuntimeError, 'approval'):
                suite.main()
            load.assert_not_called()

    def healthy(self):
        return dict(functions=json.loads((suite.PACKAGE/'approved_functions.json').read_text(encoding='utf-8')),
                    other_functions_md5='6991083a881075cdf0e75d0c266396f0',
                    jobs=[{'jobid': 1, 'active': True}, {'jobid': 2, 'active': True}, {'jobid': 3, 'active': False}],
                    recovery_history={'total': 17, 'failed': 0, 'unfinished': 0}, healthy_eligibility_jobs=2,
                    lease_minutes=360, unresolved_cases=0, overdue_active_pairs=0, failure_contract_ok=True, active_recovery_jobs=0)

    def baseline(self):
        h = self.healthy()
        return dict(other_functions_md5=h['other_functions_md5'], recovery_history=h['recovery_history'],
                    migration_sha256=contract.hashlib.sha256(contract.MIGRATION.read_bytes()).hexdigest(),
                    function_acls={f['identity']: f.get('acl') for f in h['functions']})

    def test_approved_health_passes(self):
        suite.validate_health(self.healthy(), self.baseline())

    def test_each_health_drift_blocks(self):
        for field, value in [('functions', []), ('other_functions_md5', 'changed'),
                             ('healthy_eligibility_jobs', 1), ('lease_minutes', 60),
                             ('unresolved_cases', 1), ('overdue_active_pairs', 1), ('failure_contract_ok', False), ('active_recovery_jobs',1),
                             ('recovery_history', {'total': 18, 'failed': 0, 'unfinished': 0})]:
            s = self.healthy(); s[field] = value
            with self.subTest(field=field), self.assertRaises(RuntimeError):
                suite.validate_health(s, self.baseline())

    def test_active_recovery_cron_blocks(self):
        s = self.healthy(); s['jobs'][2]['active'] = True
        with self.assertRaises(RuntimeError):
            suite.validate_health(s, self.baseline())

    def test_auth_or_permission_error_cannot_count_as_holder_rejection(self):
        for response in [(401, {'message': 'NOT_ACTIVE_CLAIM_HOLDER', 'code': '42501'}),
                         (400, {'message': 'STALE_OR_EXPIRED_LEASE', 'code': 'P0001'})]:
            with patch.object(common, 'rpc', return_value=response), self.assertRaises(RuntimeError):
                suite.rejected_pickup('b', 'k', 't', 'claim')

    def test_exact_authoritative_holder_errors_pass(self):
        with patch.object(common, 'rpc', return_value=(400, {'message': 'NOT_ACTIVE_CLAIM_HOLDER', 'code': 'P0001'})) as rpc:
            suite.rejected_pickup('b', 'k', 't', 'claim')
            self.assertEqual(rpc.call_count, 2)

    def test_legitimate_refresh_completion_is_not_false_replay_failure(self):
        a = {'claims': ['same'], 'current_refresh_completed': False}
        b = {'claims': ['same'], 'current_refresh_completed': True}
        suite.assert_stable_unchanged(a, b)
        b['claims'] = ['changed']
        with self.assertRaises(RuntimeError):
            suite.assert_stable_unchanged(a, b)

    def test_network_unknown_outcome_journal_retains_request_without_token(self):
        with tempfile.TemporaryDirectory() as folder:
            journal = suite.Journal(Path(folder)/'private')
            with patch.object(common, 'rpc', side_effect=RuntimeError('secret-error')), \
                 patch.object(common, 'jwt_subject', return_value='actor'), suite.record_rpcs(journal):
                with self.assertRaises(RuntimeError):
                    common.rpc('base', 'key', 'secret-token', 'claim_listing', {'p_request': 'saved-uuid'})
            text = (journal.folder/'events.jsonl').read_text()
            self.assertIn('RPC_UNCONFIRMED', text)
            self.assertIn('saved-uuid', text)
            self.assertNotIn('secret', text)

    def test_two_actor_freshness_checks_both_actors_without_ten(self):
        def rows(base, service, query):
            if query.startswith('coordination_config?'):
                return [{'claim_lease_minutes': 360}]
            if query.startswith('listings?'):
                return [{'listing_status': 'AVAILABLE', 'pickup_road_node_id': 'trusted'}]
            return []
        with patch.object(common, 'jwt_subject', side_effect=['actor-a', 'actor-b']), \
             patch.object(common, 'rest_rows', side_effect=rows), \
             patch.object(common, 'rpc', return_value=(200, [{'listing_id': x} for x in LISTINGS])) as rpc:
            self.assertEqual(common.assert_fresh_fixtures('b', 's', 'k', ['a', 'b'], LISTINGS, 2),
                             ['actor-a', 'actor-b'])
            self.assertEqual(rpc.call_count, 4)
            self.assertTrue(all(c.args[3] == 'discover_eligible_listing_cards' for c in rpc.call_args_list))

    def test_default_cli_preflight_never_enters_mutation_sequence(self):
        env = self.environment()
        env.update(GEOLOCK_STAGE3J_FIXTURE_LABEL='STAGE3J-2A-test',
                   GEOLOCK_STAGE3J_DONATION_IDS=json.dumps([str(uuid.UUID(int=201)), str(uuid.UUID(int=202))]),
                   GEOLOCK_STAGE3J_OPERATOR='Offline operator', GEOLOCK_TEST_DATABASE_URL=DB)
        with tempfile.TemporaryDirectory() as folder, patch.dict(os.environ, env, clear=True), \
             patch.object(sys, 'argv', ['runner', '--env-file', 'unused', '--manifest', 'unused', '--output-dir', str(Path(folder)/'new')]), \
             patch.object(common, 'load_env_file'), patch.object(suite, 'verify_sessions', return_value=['a', 'b']), \
             patch.object(common, 'jwt_subject', side_effect=['a','b']), \
             patch.object(suite, 'sql_read', return_value=self.healthy()), \
             patch.object(suite, 'validate_fixture'), patch.object(common, 'assert_fresh_fixtures'), \
             patch.object(contract, 'load_manifest', return_value=dict(health_baseline=self.baseline(), approval_ref='offline', operator='offline')), \
             patch.object(Path, 'read_bytes', return_value=b'offline-manifest'), \
             patch.object(suite, 'run_acceptance') as execute:
            self.assertEqual(suite.main(), 0)
            execute.assert_not_called()

    def test_fixture_guard_rejects_wrong_identity_history_or_incomplete_refresh(self):
        state = dict(listing=dict(listing_id=LISTINGS[0],donation_id='donation',source_type='DIRECT_DONATION',
                                 listing_status='AVAILABLE',listing_expires_at=None,pickup_road_node_id='node',listing_weight_kg=20),
                     donation=dict(donation_id='donation',title='STAGE3J-2A-test-race',
                                   collection_path='DIRECT_PICKUP',donation_status='AVAILABLE'),
                     claims=[],cases=[],failures=[],route_count=0,photo_count=1,item_count=1,current_refresh_completed=True)
        suite.validate_fixture(state, LISTINGS[0], 'donation', 'STAGE3J-2A-test')
        for field, value in [('claims', ['old']), ('cases', ['OPEN']), ('failures', ['old']), ('route_count', 1),
                             ('photo_count', 0), ('item_count', 0), ('current_refresh_completed', False)]:
            s = copy.deepcopy(state); s[field] = value
            with self.subTest(field=field), self.assertRaises(RuntimeError):
                suite.validate_fixture(s, LISTINGS[0], 'donation', 'STAGE3J-2A-test')
        with self.assertRaises(RuntimeError):
            suite.validate_fixture(state, LISTINGS[1], 'donation', 'STAGE3J-2A-test')


if __name__ == '__main__':
    unittest.main(verbosity=2)
