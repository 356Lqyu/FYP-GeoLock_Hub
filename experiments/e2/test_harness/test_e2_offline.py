"""Offline regression tests for E2 orchestration and safety logic (no DB connections)."""
import importlib.util
import ast
from contextlib import nullcontext
import sys
import tempfile
import types
import unittest
import hashlib
import json
import os
import socket
import subprocess
import shutil
from unittest.mock import Mock, patch
from pathlib import Path


def load_harness():
    fake = types.ModuleType('psycopg')
    fake.Error = type('Error', (Exception,), {})
    fake.errors = types.SimpleNamespace(
        DeadlockDetected=type('DeadlockDetected', (fake.Error,), {}),
        SerializationFailure=type('SerializationFailure', (fake.Error,), {}))
    fake.__version__ = 'offline-stub'
    sys.modules['psycopg'] = fake
    path = Path(__file__).with_name('e2_harness.py')
    spec = importlib.util.spec_from_file_location('e2_harness_offline_test', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    sys.modules['e2_harness'] = module
    return module


HARNESS = load_harness()
COMPARE_PATH = Path(__file__).parents[1] / 'experiment_result' / 'source_code' / 'e2_compare.py'
COMPARE_SPEC = importlib.util.spec_from_file_location('e2_compare_offline_test', COMPARE_PATH)
COMPARE = importlib.util.module_from_spec(COMPARE_SPEC)
COMPARE_SPEC.loader.exec_module(COMPARE)
RUNNER_PATH = Path(__file__).parents[1] / 'run_e2.py'
RUNNER_SPEC = importlib.util.spec_from_file_location('run_e2_offline_test', RUNNER_PATH)
RUNNER = importlib.util.module_from_spec(RUNNER_SPEC)
RUNNER_SPEC.loader.exec_module(RUNNER)
POWERSHELL = shutil.which('pwsh') or shutil.which('powershell')


class OfflineHarnessTests(unittest.TestCase):
    def test_all_methods_have_same_contention_coverage(self):
        self.assertEqual(set(HARNESS.METHODS), {
            'non_atomic_claim', 'protected_claim_without_lease_recovery', 'protected_claim_with_lease_recovery'})
        for method in HARNESS.METHODS.values():
            self.assertIn('CLAIM_COORDINATION', method['parts'])
        self.assertFalse(HARNESS.METHODS['protected_claim_without_lease_recovery']['recovery'])
        self.assertTrue(HARNESS.METHODS['protected_claim_with_lease_recovery']['recovery'])
        counts = {n: sum(HARNESS.worker_count(f'SCN-CLAIM-{i:03d}') == n for i in range(1, 151))
                  for n in (2, 5, 10)}
        self.assertEqual(counts, {2: 50, 5: 50, 10: 50})
        self.assertEqual(sum(n * count for n, count in counts.items()), 850)

    def test_sqlstate_capture_preserves_distinct_codes(self):
        row = {'sqlstates': []}
        HARNESS.append_sqlstate(row, '40P01')
        HARNESS.append_sqlstate(row, '40001')
        HARNESS.append_sqlstate(row, '40P01')
        self.assertEqual(row['sqlstates'], ['40P01', '40001'])

    def test_rejects_remote_dsn_and_legacy_overrides_before_connecting(self):
        for dsn in ('host=example.com port=55432 dbname=geolock_e2 user=postgres',
                    'host=127.0.0.1 port=5432 dbname=geolock_e2 user=postgres',
                    'host=127.0.0.1 port=55432 dbname=geolock_e2 user=postgres hostaddr=192.0.2.1'):
            with self.assertRaisesRegex(SystemExit, 'loopback DSN'):
                HARNESS.connect(dsn)
        for name in ('GEOLOCK_E2_DSN', 'GEOLOCK_E2_CONFIG', 'GEOLOCK_E2_MODE', 'PGHOSTADDR', 'PGSERVICE'):
            with self.subTest(name=name), patch.dict('os.environ', {name: 'hosted'}, clear=True):
                with self.assertRaisesRegex(SystemExit, 'overrides are refused|Clear GEOLOCK_E2_MODE'):
                    RUNNER.main([])

    def _local_config(self, root, **overrides):
        data_dir = root / 'GeoLockHub' / 'E2' / 'cluster' / 'data'
        pg_bin = root / 'PostgreSQL' / '17' / 'bin'
        data_dir.mkdir(parents=True)
        pg_bin.mkdir(parents=True)
        for exe in ('pg_ctl.exe', 'postgres.exe', 'psql.exe', 'pg_controldata.exe'):
            (pg_bin / exe).write_bytes(b'')
        config = {'version': 1, 'mode': 'local', 'host': '127.0.0.1', 'port': 55432,
                  'dbname': 'geolock_e2', 'user': 'postgres', 'target_id': 'd' * 32,
                  'cluster_system_identifier': '7421378294610926183', 'data_dir': str(data_dir),
                  'pg_bin': str(pg_bin), 'setup_approval': HARNESS.LOCAL_SETUP_APPROVAL}
        config.update(overrides)
        return config

    def test_local_config_loads_once_and_binds_unique_cluster_target(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            config_path = root / 'GeoLockHub' / 'E2' / 'local.json'
            config_path.parent.mkdir(parents=True)
            config_path.write_text(json.dumps(self._local_config(root)), encoding='utf-8')
            with patch.dict('os.environ', {'LOCALAPPDATA': str(root), 'GEOLOCK_E2_MODE': 'local',
                                          'GEOLOCK_E2_DSN': '', 'GEOLOCK_E2_TARGET_ID': '',
                                          'GEOLOCK_E2_CONFIRM_DISPOSABLE': ''}, clear=False):
                dsn, target = HARNESS.get_target_config()
            self.assertIn('dbname=geolock_e2', dsn)
            self.assertEqual((target['host'], target['port'], target['dbname']), ('127.0.0.1', 55432, 'geolock_e2'))
            self.assertEqual(target['cluster_system_identifier'], '7421378294610926183')
            self.assertTrue(target['setup_approval_configured'])

    def test_local_config_rejects_hosted_or_existing_database_targets(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            config = self._local_config(root)
            with patch.dict('os.environ', {'LOCALAPPDATA': str(root)}, clear=False):
                for overrides in ({'host': 'example.com'}, {'dbname': 'postgres'}, {'port': 80},
                                  {'cluster_system_identifier': 'bad'},
                                  {'setup_approval': 'not-created-by-e2-setup'}):
                    with self.subTest(overrides=overrides), self.assertRaises(SystemExit):
                        HARNESS.validate_local_config({**config, **overrides})

    def test_local_cluster_identity_requires_matching_port_path_and_system_identifier(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            config = self._local_config(root)
            with patch.dict('os.environ', {'LOCALAPPDATA': str(root)}, clear=False):
                _dsn, target = HARNESS.validate_local_config(config)
            row = (55432, config['data_dir'], config['cluster_system_identifier'])
            self.assertTrue(HARNESS.validate_local_cluster_identity(row, target))
            for bad in ((55433, row[1], row[2]), (row[0], str(root / 'other-data'), row[2]),
                        (row[0], row[1], '9999999999999999999')):
                with self.subTest(actual=bad), self.assertRaises(SystemExit):
                    HARNESS.validate_local_cluster_identity(bad, target)

    def test_local_cluster_manager_only_starts_and_stops_the_configured_data_dir(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            config = self._local_config(root)
            with patch.dict('os.environ', {'LOCALAPPDATA': str(root)}, clear=False):
                _dsn, target = HARNESS.validate_local_config(config)
                responses = [subprocess.CompletedProcess([], 0, 'postgres (PostgreSQL) 17.5', ''),
                             subprocess.CompletedProcess([], 0, 'Database system identifier: 7421378294610926183', ''),
                             subprocess.CompletedProcess([], 3, '', 'stopped'),
                             subprocess.CompletedProcess([], 0, '', 'started'),
                             subprocess.CompletedProcess([], 0, '', 'stopped')]
                with patch.object(HARNESS.subprocess, 'run', side_effect=responses) as run, \
                        patch.object(HARNESS.socket, 'create_connection', side_effect=OSError('no listener')):
                    manager = HARNESS.LocalPostgresCluster(target)
                    manager.start()
                    self.assertTrue(manager.started_here)
                    manager.stop()
                self.assertEqual(run.call_args_list[2].args[0][1:3], ['-D', str(Path(config['data_dir']).resolve())])
                self.assertEqual(run.call_args_list[3].args[0][-1], 'start')
                self.assertEqual(run.call_args_list[4].args[0][-1], 'stop')

    def test_local_cluster_manager_refuses_wrong_cluster_id_or_busy_port(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            config = self._local_config(root)
            with patch.dict('os.environ', {'LOCALAPPDATA': str(root)}, clear=False):
                _dsn, target = HARNESS.validate_local_config(config)
                manager = HARNESS.LocalPostgresCluster(target)
                wrong_cluster = [subprocess.CompletedProcess([], 0, 'postgres (PostgreSQL) 17.5', ''),
                                 subprocess.CompletedProcess([], 0, 'Database system identifier: 9999999999999999999', '')]
                with patch.object(HARNESS.subprocess, 'run', side_effect=wrong_cluster) as run:
                    with self.assertRaises(SystemExit):
                        manager.start()
                self.assertEqual(run.call_count, 2)
                busy_port = [subprocess.CompletedProcess([], 0, 'postgres (PostgreSQL) 17.5', ''),
                             subprocess.CompletedProcess([], 0, 'Database system identifier: 7421378294610926183', ''),
                             subprocess.CompletedProcess([], 3, '', 'not running')]
                with patch.object(HARNESS.subprocess, 'run', side_effect=busy_port) as run, \
                        patch.object(HARNESS.socket, 'create_connection', return_value=nullcontext(object())):
                    with self.assertRaises(SystemExit):
                        manager.start()
                self.assertEqual(run.call_count, 3)

    def test_local_bootstrap_provisions_only_auth_surface_used_by_e2(self):
        sql = (Path(__file__).parents[1] / 'database' / '00_local_auth_compat.sql').read_text(encoding='utf-8').lower()
        marker = (Path(__file__).parents[1] / 'database' / '00_provision_e2_target_marker.sql').read_text(encoding='utf-8').lower()
        setup = (Path(__file__).parents[1] / 'scripts' / 'setup_local_e2.ps1').read_text(encoding='utf-8').lower()
        recovery = (Path(__file__).parents[1] / 'scripts' / 'recover_local_e2.ps1').read_text(encoding='utf-8').lower()
        process_safety = Path(__file__).with_name('e2_process_safety.ps1').read_text(encoding='utf-8').lower()
        postgres_client = Path(__file__).with_name('e2_postgres_client.ps1').read_text(encoding='utf-8').lower()
        for snippet in ('create role anon nologin', 'create role authenticated nologin',
                        'create role service_role nologin bypassrls', 'create table auth.users',
                        'create function auth.uid()', 'create function auth.role()',
                        "request.jwt.claims", 'grant execute on function auth.uid()',
                        'create extension postgis with schema extensions'):
            self.assertIn(snippet, sql)
        self.assertIn("$datadir = join-path $localroot 'cluster\\data'", setup)
        self.assertIn("$databasename = 'geolock_e2'", setup)
        self.assertIn('if (test-path -literalpath $datadir)', setup)
        self.assertIn('assert-e2localrootinventory -root $localroot', setup)
        self.assertIn('get-childitem -literalpath $root -force', postgres_client)
        self.assertLess(setup.index('$clusterstartattempted = $true'), setup.index('-w -t 45 start'))
        self.assertIn('begin;', sql)
        self.assertIn('commit;', sql)
        self.assertIn('begin;', marker)
        self.assertIn('commit;', marker)
        self.assertIn("[validateset('inspect','quarantinestalepid','complete')]", recovery)
        self.assertIn('quarantinestalepid', recovery)
        self.assertIn('expectedsystemidentifier', recovery)
        self.assertIn('approvepostgresstartforinspection', recovery)
        self.assertIn('confirmstalepid', recovery)
        self.assertIn('get-ciminstance -classname win32_process', recovery)
        self.assertIn('get-ciminstance -classname win32_service', recovery)
        self.assertIn("$servicename = 'postgresql-x64-17'", process_safety)
        self.assertIn('parentprocessid', process_safety)
        self.assertIn('serviceconfigverified', process_safety)
        self.assertIn("test_harness\\e2_process_safety.ps1", recovery)
        self.assertIn('outside the positively verified unrelated service tree', process_safety)
        self.assertIn('get-e2listenerinventory -port $port', recovery)
        self.assertIn('fullyqualifiederrorid', process_safety)
        self.assertIn('get-nettcpconnection -state listen -erroraction stop', process_safety)
        self.assertIn('$pidpath.stale.$stamp', recovery)
        self.assertIn('[io.file]::move($pidpath,$archivepath)', recovery)
        self.assertIn('database inventory', recovery)
        self.assertIn('compare-object', recovery)
        self.assertIn("pgconnect_timeout = '5'", postgres_client)
        self.assertIn('default_transaction_read_only=on', postgres_client)
        self.assertIn("'-x','-q','-a','-t'", recovery)
        self.assertIn('assert-e2serveridentity', recovery)
        self.assertIn('convertto-e2canonicalpath', process_safety)
        self.assertIn('start-e2postgresbounded', recovery)
        self.assertIn('recoverablemissinge2database', process_safety)
        self.assertIn('database and role inventory classification completed', recovery)
        self.assertNotIn('start *> $null', recovery)
        self.assertNotIn("invoke-e2native $pgctl @('-d',$datadir,'-l',$logpath", recovery)
        self.assertIn('createnew', recovery)
        self.assertNotIn('remove-item', recovery)
        self.assertNotIn('remove-item', setup)
        self.assertIn('pg_ctl.exe', setup)
        self.assertNotIn('new-service', setup)
        self.assertNotIn('stop-service', setup)
        self.assertNotRegex(recovery + process_safety, r'\$pid\b')

    @unittest.skipUnless(POWERSHELL, 'PowerShell is unavailable; run test_e2_process_safety.ps1 on Windows.')
    def test_actual_powershell_process_safety_logic_offline(self):
        test_script = Path(__file__).with_name('test_e2_process_safety.ps1')
        result = subprocess.run(
            [POWERSHELL, '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(test_script)],
            capture_output=True, text=True, timeout=30, check=False)
        self.assertEqual(result.returncode, 0, msg=result.stdout + result.stderr)
        self.assertIn('PASS: verified unrelated service descendants', result.stdout)
        self.assertIn('PASS: unknown processes', result.stdout)

    def test_rejects_unsafe_cli_before_loading_target(self):
        for args in (['--mode', 'hosted'], ['--configure-hosted'], ['--config-path', 'old.json'],
                     ['--dsn', 'remote'], ['--method', 'unknown'],
                     ['--mode', 'hosted', '--preflight-only', '--allow-start'],
                     ['--method', 'baseline1', '--preflight-only']):
            with self.subTest(args=args), patch.object(HARNESS, 'get_target_config') as load:
                with self.assertRaises(SystemExit) as exc:
                    RUNNER.main(args)
                self.assertEqual(exc.exception.code, 2)
                load.assert_not_called()

    def _hosted_config(self, root):
        ca = root / 'ca.pem'
        ca.touch()
        project = 'abcdefghijklmnopqrst'
        return dict(version=1, project=project, host='aws-0-us-west-1.pooler.supabase.com',
                    target_id='a' * 32, ca=str(ca), authorization=RUNNER.hosted.approval_phrase(project))

    def _run_local_root_guard(self, script, root):
        # Evaluate only the actual inventory call, never a PostgreSQL executable.
        command = r"""
        $ErrorActionPreference = 'Stop'
        $scriptPath = $env:E2_TEST_INVENTORY_SCRIPT
        . (Join-Path (Split-Path -Parent (Split-Path -Parent $scriptPath)) 'test_harness/e2_postgres_client.ps1')
        $LocalRoot = $env:E2_TEST_INVENTORY_ROOT
        $tree = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)
        $guard = @($tree.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -eq 'Assert-E2LocalRootInventory'
        }, $false))
        if ($guard.Count -ne 1) { throw 'Expected one local root inventory call' }
        & ([scriptblock]::Create($guard[0].Extent.Text))
        """
        return subprocess.run(
            [POWERSHELL, '-NoProfile', '-NonInteractive', '-Command', command],
            env={**os.environ, 'E2_TEST_INVENTORY_SCRIPT': str((RUNNER_PATH.parent / 'scripts' / script).resolve()),
                 'E2_TEST_INVENTORY_ROOT': str(root)},
            capture_output=True, text=True, timeout=15, check=False)

    def _register_in_temporary_profile(self, temp):
        config = self._hosted_config(temp)
        with patch.dict(os.environ, {'LOCALAPPDATA': str(temp)}), patch('builtins.print'):
            path = HARNESS.hosted_config_path()
            RUNNER.hosted.register(path, config['project'], config['host'], config['ca'],
                                   input_fn=lambda _: config['authorization'])
        return path

    @unittest.skipUnless(POWERSHELL, 'PowerShell is required to exercise the local inventory call')
    def test_hosted_enrollment_can_precede_local_setup(self):
        with tempfile.TemporaryDirectory() as temp:
            hosted = self._register_in_temporary_profile(Path(temp))
            original = hosted.read_bytes()
            result = self._run_local_root_guard('setup_local_e2.ps1', hosted.parent)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(hosted.read_bytes(), original)

    @unittest.skipUnless(POWERSHELL, 'PowerShell is required to exercise the local inventory call')
    def test_local_setup_can_precede_hosted_enrollment(self):
        with tempfile.TemporaryDirectory() as temp:
            profile = Path(temp)
            root = profile / 'GeoLockHub' / 'E2'
            result = self._run_local_root_guard('setup_local_e2.ps1', root)
            self.assertEqual(result.returncode, 0, result.stderr)
            # Represent the files left by successful local setup without starting PostgreSQL.
            (root / 'cluster' / 'data').mkdir(parents=True)
            (root / 'postgresql.log').touch()
            local_config = root / 'local.json'
            local_config.write_bytes(b'{"mode":"local"}')
            hosted = self._register_in_temporary_profile(profile)
            self.assertTrue(hosted.is_file())
            self.assertEqual(local_config.read_bytes(), b'{"mode":"local"}')

    @unittest.skipUnless(POWERSHELL, 'PowerShell is required to exercise the local inventory call')
    def test_interrupted_local_setup_recovery_accepts_hosted_enrollment(self):
        with tempfile.TemporaryDirectory() as temp:
            hosted = self._register_in_temporary_profile(Path(temp))
            (hosted.parent / 'cluster' / 'data').mkdir(parents=True)
            (hosted.parent / 'postgresql.log').touch()
            original = hosted.read_bytes()
            result = self._run_local_root_guard('recover_local_e2.ps1', hosted.parent)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(hosted.read_bytes(), original)

    @unittest.skipUnless(POWERSHELL, 'PowerShell is required to exercise the local inventory call')
    def test_local_inventory_rejects_unexpected_files_and_unsafe_hosted_entries(self):
        for name, kind in (('unexpected.json', 'file'), ('hosted.json', 'directory'),
                           ('hosted.json', 'hard link'), ('hosted.json', 'reparse point')):
            with self.subTest(name=name, kind=kind), tempfile.TemporaryDirectory() as temp:
                root = Path(temp) / 'E2'
                root.mkdir()
                entry = root / name
                if kind == 'file':
                    entry.touch()
                elif kind == 'directory':
                    entry.mkdir()
                else:
                    target = Path(temp) / 'target'
                    if kind == 'hard link':
                        target.touch()
                        os.link(target, entry)
                    else:
                        target.mkdir()
                        subprocess.run(
                            [POWERSHELL, '-NoProfile', '-NonInteractive', '-Command',
                             "New-Item -ItemType Junction -Path $env:E2_TEST_LINK -Target $env:E2_TEST_TARGET"],
                            env={**os.environ, 'E2_TEST_LINK': str(entry), 'E2_TEST_TARGET': str(target)},
                            capture_output=True, text=True, timeout=15, check=True)
                for script in ('setup_local_e2.ps1', 'recover_local_e2.ps1'):
                    result = self._run_local_root_guard(script, root)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn('unexpected or unsafe entry', result.stderr)
                    self.assertIn(name, result.stderr)

    def test_hosted_enrollment_rejects_other_targets_and_credential_fields(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            config = self._hosted_config(root)
            target = RUNNER.hosted.HostedTarget.from_config(config)
            self.assertEqual(target.username, 'postgres.abcdefghijklmnopqrst')
            for overrides in ({'host': 'example.com'}, {'host': config['host'] + ':6543'},
                              {'authorization': 'yes'}, {'password': 'ignored'}, {'target_id': 'bad'},
                              *({'project': ref, 'authorization': RUNNER.hosted.approval_phrase(ref)}
                                for ref in RUNNER.hosted.BLOCKED_PROJECTS)):
                with self.subTest(overrides=overrides), self.assertRaises(SystemExit):
                    RUNNER.hosted.HostedTarget.from_config({**config, **overrides})
            path = root / 'hosted.json'
            with patch.object(HARNESS.psycopg, 'connect', create=True) as connect, patch('builtins.print'):
                with self.assertRaises(SystemExit):
                    RUNNER.hosted.register(path, target.project, target.host, target.ca, input_fn=lambda _: 'yes')
                self.assertFalse(path.exists())
                RUNNER.hosted.register(path, target.project, target.host, target.ca,
                                       input_fn=lambda _: config['authorization'])
                self.assertNotIn('password', json.loads(path.read_text(encoding='utf-8')))
                connect.assert_not_called()

    def test_hosted_connector_pins_session_pooler_and_tls(self):
        with tempfile.TemporaryDirectory() as temp, patch.dict('os.environ', {'APPDATA': temp}, clear=True):
            target = RUNNER.hosted.HostedTarget.from_config(self._hosted_config(Path(temp)))
            connection = Mock()
            connection.pgconn.ssl_in_use = True
            with patch.object(HARNESS.psycopg, 'connect', return_value=connection, create=True) as connect:
                self.assertIs(HARNESS.connect(target), connection)
                kwargs = connect.call_args.kwargs
                self.assertEqual((kwargs['host'], kwargs['port'], kwargs['user'], kwargs['dbname'], kwargs['sslmode']),
                                 (target.host, 5432, target.username, 'postgres', 'verify-full'))
                self.assertEqual(Path(kwargs['passfile']), Path(temp) / 'postgresql/pgpass.conf')
                self.assertNotIn('password', kwargs)
                connection.pgconn.ssl_in_use = False
                with self.assertRaisesRegex(SystemExit, 'verified TLS'):
                    HARNESS.connect(target)
                connection.close.assert_called_once()

    def test_hosted_identity_binds_marker_to_enrolled_project(self):
        with tempfile.TemporaryDirectory() as temp:
            target = RUNNER.hosted.HostedTarget.from_config(self._hosted_config(Path(temp)))
            conn = Mock()
            conn.info = types.SimpleNamespace(host=target.host, user=target.username, port=5432, dbname='postgres')
            conn.pgconn.ssl_in_use = True
            for project in (target.project, 'zyxwvutsrqponmlkjihg'):
                conn.execute.side_effect = [
                    Mock(**{'fetchone.return_value': ('postgres', 'postgres', 'postgres', '17.11')}),
                    Mock(**{'fetchone.return_value': ('e2_disposable_target',)}),
                    Mock(**{'fetchall.return_value': [(True, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', project)]}),
                ]
                if project == target.project:
                    self.assertTrue(RUNNER.hosted.verify_identity(conn, target)['marker_verified'])
                else:
                    with self.assertRaisesRegex(SystemExit, 'marker does not match'):
                        RUNNER.hosted.verify_identity(conn, target)

    def test_hosted_preflight_dispatches_without_lock_and_wrong_confirmation_stops(self):
        with tempfile.TemporaryDirectory() as temp:
            target = RUNNER.hosted.HostedTarget.from_config(self._hosted_config(Path(temp)))
            with patch.object(HARNESS, 'get_target_config', return_value=(target, target)), \
                    patch.object(HARNESS, 'validate_runtime_dependencies'), \
                    patch.object(RUNNER, 'execute_run', return_value=0) as execute, \
                    patch.object(RUNNER, 'hosted_run_lock', return_value=nullcontext('held')) as lock:
                self.assertEqual(RUNNER.main(['--mode', 'hosted', '--preflight-only']), 0)
                lock.assert_not_called()
                with self.assertRaises(SystemExit):
                    RUNNER.main(['--mode', 'hosted', '--confirm-project', 'wrong'])
                lock.assert_not_called()
                self.assertEqual(RUNNER.main(['--mode', 'hosted', '--confirm-project', target.project]), 0)
                lock.assert_called_once_with(target)
                self.assertEqual(execute.call_args.kwargs['reset_conn'], 'held')

    def test_hosted_run_refuses_contested_lock_and_reset_without_lock(self):
        conn = Mock()
        conn.execute.return_value.fetchone.return_value = (False,)
        with patch.object(HARNESS, 'connect', return_value=nullcontext(conn)), \
                patch.object(RUNNER.hosted, 'verify_identity'):
            with self.assertRaisesRegex(SystemExit, 'holds the hosted project lock'):
                with RUNNER.hosted_run_lock('target'):
                    self.fail('lock contention was ignored')
            conn.execute.assert_called_once_with('select pg_try_advisory_lock(%s, %s)', RUNNER.hosted.RUN_LOCK)
        with tempfile.TemporaryDirectory() as temp:
            target = RUNNER.hosted.HostedTarget.from_config(self._hosted_config(Path(temp)))
            with patch.object(HARNESS, 'connect') as connect:
                with self.assertRaisesRegex(SystemExit, 'requires the run-lock connection'):
                    HARNESS.setup_database(target, target, {})
                connect.assert_not_called()

    def test_hosted_preflight_is_read_only_and_rejects_foreign_auth_users(self):
        with tempfile.TemporaryDirectory() as temp:
            target = RUNNER.hosted.HostedTarget.from_config(self._hosted_config(Path(temp)))
            conn = Mock()
            conn.transaction.return_value = nullcontext()
            conn.execute.return_value.fetchall.return_value = [('user-id', 'other@example.com')]
            with patch.object(HARNESS, 'connect', return_value=nullcontext(conn)), \
                    patch.object(HARNESS, 'validate_database_identity'), \
                    patch.object(HARNESS, 'inspect_reset_inventory'), \
                    patch.object(HARNESS, 'fixture_accounts', return_value={'user-id': 'e2@example.com'}), \
                    patch.object(RUNNER.hosted, 'check_compatibility'):
                with self.assertRaisesRegex(SystemExit, 'unexpected Auth users'):
                    RUNNER.preflight(target, target)
                self.assertEqual([call.args[0] for call in conn.execute.call_args_list],
                                 ['set transaction read only', 'select id::text, email from auth.users'])

    def test_hosted_session_probe_checks_both_roles_across_read_only_transactions(self):
        for second_pid in (42, 43):
            with self.subTest(second_pid=second_pid):
                conn = Mock()
                conn.transaction.side_effect = lambda: nullcontext()
                pid = 'select pg_backend_pid()'
                auth = 'select pg_backend_pid(), current_user, auth.uid()::text, auth.role()'
                answers = iter([(42,), (second_pid, 'authenticated', RUNNER.hosted.AUTH_PROBE_ACTOR, 'authenticated'),
                                (42,), (42, 'service_role', None, 'service_role')])

                def execute(sql, params=()):
                    return Mock(**{'fetchone.return_value': next(answers)}) if sql in (pid, auth) else None

                conn.execute.side_effect = execute
                if second_pid == 43:
                    with self.assertRaisesRegex(SystemExit, 'did not persist'):
                        RUNNER.hosted.check_session_contract(conn)
                else:
                    RUNNER.hosted.check_session_contract(conn)
                    self.assertEqual(conn.transaction.call_count, 4)
                    statements = [call.args[0] for call in conn.execute.call_args_list]
                    self.assertEqual(statements.count('set transaction read only'), 4)
                    self.assertEqual(statements.count('reset role'), 2)
                    self.assertIn('set session role authenticated', statements)
                    self.assertIn('set session role service_role', statements)

    def test_hosted_run_lock_recheck_refuses_lost_lock(self):
        conn = Mock()
        conn.execute.return_value.fetchone.return_value = (False,)
        with self.assertRaisesRegex(SystemExit, 'lost the project run lock'):
            RUNNER.hosted.verify_run_lock(conn)
        sql, keys = conn.execute.call_args.args
        self.assertEqual(keys, RUNNER.hosted.RUN_LOCK)
        self.assertIn('pid = pg_backend_pid()', sql)
        self.assertIn('datname = current_database()', sql)
        self.assertIn('objsubid = 2', sql)

    @unittest.skipUnless(sys.platform == 'win32', 'Windows lock')
    def test_cluster_lock_rejects_overlap_and_releases_after_exception(self):
        with tempfile.TemporaryDirectory() as temp:
            lock = Path(temp) / 'run.lock'
            with self.assertRaisesRegex(RuntimeError, 'interrupted'):
                with RUNNER.cluster_run_lock(lock):
                    with self.assertRaisesRegex(SystemExit, 'Another E2 run'):
                        with RUNNER.cluster_run_lock(lock):
                            self.fail('overlap accepted')
                    raise RuntimeError('interrupted')
            with RUNNER.cluster_run_lock(lock):
                self.assertTrue(lock.exists())

    @unittest.skipUnless(sys.platform == 'win32' and POWERSHELL, 'Windows PowerShell wrapper')
    def test_wrapper_forwards_arguments_and_exit_code(self):
        wrapper = RUNNER_PATH.with_name('run.ps1')
        with tempfile.TemporaryDirectory() as temp:
            fake = Path(temp) / 'fake python.cmd'
            fake.write_text('@echo off\necho %*\nexit /b 37\n', encoding='ascii')
            for options, expected in (
                ([], '--method all'),
                (['-Method', 'baseline1'], '--method baseline1'),
                (['-Method', 'baseline2'], '--method baseline2'),
                (['-Method', 'proposed'], '--method proposed'),
                (['-PreflightOnly', '-AllowStart'], '--method all --preflight-only --allow-start'),
                (['-Hosted', '-PreflightOnly'], '--method all --preflight-only --mode hosted'),
            ):
                with self.subTest(options=options):
                    result = subprocess.run(
                        [POWERSHELL, '-NoProfile', '-File', str(wrapper), '-Python', str(fake), *options],
                        capture_output=True, text=True, timeout=20, cwd=temp,
                    )
                    self.assertEqual(result.returncode, 37, result.stderr)
                    self.assertIn('run_e2.py', result.stdout)
                    self.assertIn(expected, result.stdout)

    def test_dispatches_full_standalone_and_preflight(self):
        from argparse import Namespace
        for choice in ('all', *RUNNER.METHODS, 'preflight'):
            with self.subTest(choice=choice), tempfile.TemporaryDirectory() as temp, \
                    patch.dict('os.environ', {}, clear=True), \
                    patch.object(RUNNER, 'preflight', return_value=({'marker_verified': True}, {})), \
                    patch.object(HARNESS, 'check_inputs', return_value={'input': 'hash'}), \
                    patch.object(HARNESS, 'run_output_path', return_value=Path(temp) / 'new') as output_path, \
                    patch.object(HARNESS, 'run_method') as run_method, \
                    patch.object(RUNNER.compare, 'main') as compare, \
                    patch.object(RUNNER, 'validate_standalone') as standalone:
                method = 'all' if choice == 'preflight' else choice
                out = Path(temp) / 'new'
                self.assertEqual(RUNNER.execute_run(Namespace(method=method, run_id='offline',
                                                             preflight_only=choice == 'preflight'), 'local', {}), 0)
                output_path.assert_called_once_with(RUNNER.E2 / 'experiment_result' / 'results', 'offline')
                expected = [] if choice == 'preflight' else (list(RUNNER.METHODS.values()) if choice == 'all'
                                                             else [RUNNER.METHODS[choice]])
                self.assertEqual([call.args[0] for call in run_method.call_args_list], expected)
                self.assertEqual(compare.call_count, int(choice == 'all'))
                self.assertEqual(standalone.call_count, int(choice in RUNNER.METHODS))
                if expected:
                    manifest = json.loads((out / 'run_manifest.json').read_text(encoding='utf-8'))
                    self.assertEqual(manifest['status'], 'completed')
                    self.assertEqual(manifest['selected_methods'], expected)
                else:
                    self.assertFalse(out.exists())

    def test_reset_inventory_fails_closed_for_unknown_objects_owner_or_dependencies(self):
        allowed = [('public', 'donations', 'r', 'postgres', False)]
        self.assertTrue(HARNESS.validate_reset_inventory(allowed, [], (), 'postgres')['approved'])
        candidates = (
            (allowed + [('public', 'customer_data', 'r', 'postgres', False)], ()),
            ([('public', 'donations', 'r', 'other_role', False)], ()),
            (allowed, [('outside_schema', 'dependent_view')]),
        )
        for relations, dependencies in candidates:
            with self.assertRaises(SystemExit):
                HARNESS.validate_reset_inventory(relations, [], dependencies, 'postgres')
        wrong_signature = [('e2_baseline', 'non_atomic_write_claim', 'uuid, text', 'f', 'postgres', False)]
        with self.assertRaises(SystemExit):
            HARNESS.validate_reset_inventory([], wrong_signature, (), 'postgres')
        with self.assertRaises(SystemExit):
            HARNESS.validate_reset_inventory([], [], (), 'postgres',
                                             [('public', 'donations', 'unreviewed_trigger', 'custom_fn', '')])
        source = Path(__file__).with_name('e2_harness.py').read_text(encoding='utf-8')
        self.assertIn('from pg_policies where schemaname=any(%s)', source)
        self.assertIn("sn.nspname not in ('auth')", source)
        self.assertIn('auth.users has non-internal triggers', source)

    def test_comparison_rejects_mixed_or_incomplete_manifests(self):
        base = {'experiment_run_id': 'run-1', 'target_identity': {'project_ref': 'abcdefghij1234567890'},
                'input_sha256': {'x': 'hash'}, 'trials': 150, 'contention_requests': 850,
                'lease_cases': 0, 'expired_lease_cases': 0, 'active_lease_cases': 0}
        manifests = {key: dict(base) for key in ('b1', 'b2', 'p')}
        manifests['b2']['lease_cases'] = manifests['p']['lease_cases'] = 125
        for key in ('b2', 'p'):
            manifests[key].update(expired_lease_cases=100, active_lease_cases=25)
        self.assertTrue(COMPARE.validate_run_manifests(manifests, 'run-1'))
        with self.assertRaises(SystemExit):
            COMPARE.validate_run_manifests({k: v for k, v in manifests.items() if k != 'p'}, 'run-1')
        for key, field, value in (('p', 'experiment_run_id', 'other'), ('p', 'target_identity', {'project_ref': 'other'}),
                                  ('b2', 'input_sha256', {'x': 'different'}), ('b1', 'trials', 149),
                                  ('p', 'lease_cases', 124), ('p', 'contention_requests', 849),
                                  ('p', 'expired_lease_cases', 99)):
            bad = {k: dict(v) for k, v in manifests.items()}
            bad[key][field] = value
            with self.subTest(field=field), self.assertRaises(SystemExit):
                COMPARE.validate_run_manifests(bad, 'run-1')

    def test_comparison_verifies_recorded_source_and_benchmark_hashes(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'src').mkdir()
            (root / 'inputs').mkdir()
            source = root / 'src' / 'runner.py'
            source.write_text('source', encoding='utf-8')
            input_csv = root / 'inputs' / 'scenarios.csv'
            input_csv.write_text('frozen', encoding='utf-8')
            source_hash = hashlib.sha256(source.read_bytes()).hexdigest()
            input_hash = hashlib.sha256(input_csv.read_bytes()).hexdigest()
            (root / 'inputs' / 'generation_manifest.json').write_text(
                json.dumps({'generated_csv_sha256': {'scenarios': input_hash}}), encoding='utf-8')
            manifest = {'source_sha256': {'src/runner.py': source_hash},
                        'benchmark_input_sha256': {'scenarios.csv': input_hash}}
            self.assertTrue(COMPARE.validate_run_provenance(manifest, root, root / 'inputs'))
            source.write_text('changed', encoding='utf-8')
            with self.assertRaises(SystemExit):
                COMPARE.validate_run_provenance(manifest, root, root / 'inputs')

    def test_runner_preserves_existing_output_and_requires_run_scoped_paths(self):
        runner = (Path(__file__).parents[1] / 'run_e2.py').read_text(encoding='utf-8')
        harness_source = Path(__file__).with_name('e2_harness.py').read_text(encoding='utf-8')
        self.assertIn('run_output_path(results_root, args.run_id)', runner)
        self.assertNotIn('shutil.rmtree', harness_source)
        self.assertIn("'experiment_run_id': args.run_id", runner)
        self.assertIn("'database' / '00_local_auth_compat.sql'", runner)
        self.assertNotIn("def configure_hosted", runner)
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / 'results'
            root.mkdir()
            self.assertEqual(HARNESS.run_output_path(root, 'new-run', expected_root=root), root / 'new-run')
            existing = root / 'existing-run'
            existing.mkdir()
            with self.assertRaises(SystemExit):
                HARNESS.run_output_path(root, 'existing-run', expected_root=root)
            with self.assertRaises(SystemExit):
                HARNESS.run_output_path(root, '../escape', expected_root=root)

    def test_reset_sql_has_marker_guards_and_no_cascade_deletes(self):
        reset = (Path(__file__).parents[1] / 'database' / '04_reset_e2_objects.sql').read_text(encoding='utf-8').lower()
        self.assertIn('app.geolock_e2_reset_target_id', reset)
        self.assertIn('marker_project_ref is distinct from expected_project_ref', reset)
        self.assertIn("locktype = 'advisory' and pid = pg_backend_pid()", reset)
        self.assertIn('lock table auth.users in share row exclusive mode', reset)
        self.assertIn('into strict marker', reset)
        self.assertIn("inet '127.0.0.1/32'", reset)
        self.assertIn("current_database() <> 'geolock_e2'", reset)
        self.assertIn('app.geolock_e2_allowed_accounts', reset)
        self.assertNotRegex(reset, r'drop\s+(table|schema|function)[^;]*\bcascade\b')
        self.assertIn('e2_reset_refused', reset)

    def test_target_identity_check_precedes_any_reset_sql(self):
        source = (Path(__file__).with_name('e2_harness.py')).read_text(encoding='utf-8')
        setup = source[source.index('def setup_database('):source.index('\n\n# Benchmark data')]
        self.assertLess(setup.index('validate_database_identity(conn'), setup.index('conn.execute((SQL / name)'))
        self.assertIn('E2_TARGET_MARKER', source)
        self.assertNotIn('POOLER_HOST_RE', source)
        self.assertIn('pg_control_system()', source)
        self.assertIn('LocalPostgresCluster', source)

    def test_retry_limit_and_transient_sqlstates_are_unchanged(self):
        self.assertEqual(HARNESS.MAX_RETRIES, 1)
        self.assertEqual(tuple(x.__name__ for x in HARNESS.TRANSIENT), ('DeadlockDetected', 'SerializationFailure'))
        source = (Path(__file__).with_name('e2_harness.py')).read_text(encoding='utf-8')
        self.assertIn("spec['call'], (item['listing_uuid'], item['request_uuid'])", source)

    def test_database_marker_must_match_before_setup(self):
        class FakeConnection:
            info = types.SimpleNamespace(host='127.0.0.1', user='postgres')
            def __init__(self, marker):
                self.marker = marker
                self.calls = 0

            def execute(self, _sql):
                self.calls += 1
                if self.calls == 1:
                    return types.SimpleNamespace(fetchone=lambda: ('geolock_e2', '127.0.0.1', 'postgres', 'PostgreSQL 17',
                                                                    True, True, 2))
                if self.calls == 2:
                    return types.SimpleNamespace(fetchone=lambda: (55432, r'C:\E2\cluster\data', '7421378294610926183'))
                return types.SimpleNamespace(fetchall=lambda: [(self.marker, None)])

        target = {'mode': 'local', 'target_id': 'b' * 32, 'host': '127.0.0.1', 'user': 'postgres',
                  'dbname': 'geolock_e2', 'port': 55432, 'data_dir': r'C:\E2\cluster\data',
                  'cluster_system_identifier': '7421378294610926183'}
        self.assertTrue(HARNESS.validate_database_identity(FakeConnection('b' * 32), target=target)['marker_verified'])
        with self.assertRaises(SystemExit):
            HARNESS.validate_database_identity(FakeConnection('b' * 32), target={**target, 'target_id': 'c' * 32})

    def test_local_mode_still_requires_its_marker(self):
        class NoMarkerConnection:
            info = types.SimpleNamespace(host='127.0.0.1', user='postgres')
            def __init__(self): self.calls = 0
            def execute(self, _sql):
                self.calls += 1
                if self.calls == 1:
                    return types.SimpleNamespace(fetchone=lambda: ('geolock_e2', '127.0.0.1', 'postgres',
                                                                    'PostgreSQL 17', True, True, 2))
                if self.calls == 2:
                    return types.SimpleNamespace(fetchone=lambda: (55432, r'C:\E2\cluster\data', '7421378294610926183'))
                raise HARNESS.psycopg.Error('marker absent')
        target = {'mode': 'local', 'target_id': 'c' * 32, 'host': '127.0.0.1', 'user': 'postgres',
                  'dbname': 'geolock_e2', 'port': 55432, 'data_dir': r'C:\E2\cluster\data',
                  'cluster_system_identifier': '7421378294610926183'}
        with self.assertRaises(SystemExit):
            HARNESS.validate_database_identity(NoMarkerConnection(), target=target)

    def test_comparison_statistics_include_wilson_and_sqlstate_counts(self):
        trials, requests = [], []
        for i in range(50):
            sid = f'SCN-CLAIM-{i + 1:03d}'
            times = (1.0, 20.0) if i < 25 else (50.3, 50.6)
            trials.append(dict(scenario_id=sid, ngos_competing='2', more_than_one_owner='NO',
                               claims_stored='1', success_answers_match_stored='YES', consistent_state='YES',
                               attempts_sent='2', attempts_in_audit_log='2', requests_per_second='10',
                               median_response_ms=str(HARNESS.med(times))))
            for j, response_ms in enumerate(times):
                requests.append(dict(scenario_id=sid, ngos_competing='2', response_ms=str(response_ms),
                                     answer='SUCCESS' if j == 0 else 'CONFLICT', sqlstate='40P01' if i == 0 and j == 0 else ''))
        result = COMPARE.contention(trials, requests)['2']
        self.assertEqual((result['trials'], result['requests'], result['success'], result['conflict']), (50, 100, 50, 50))
        self.assertAlmostEqual(result['duplicate_ci95'][0], 0.0)
        self.assertGreater(result['duplicate_ci95'][1], 0.0)
        self.assertEqual(result['sqlstate_40P01'], 1)
        self.assertEqual(HARNESS.med((50.3, 50.6)), 50.5)
        self.assertEqual(result['median_scenario_median_ms'], 30.5)
        self.assertAlmostEqual(result['median_ms'], 35.15)
        self.assertEqual(COMPARE.mcnemar_exact(10, 0), 2 / 2**10)

    def test_comparison_rejects_missing_or_duplicated_request_records(self):
        trials = {'SCN-CLAIM-001': {'ngos_competing': '2'}}
        reqs = [dict(scenario_id='SCN-CLAIM-001', request_id='a', request_number='1'),
                dict(scenario_id='SCN-CLAIM-001', request_id='b', request_number='2')]
        self.assertEqual(len(COMPARE.validate_contention_requests('test', trials, reqs)), 2)
        with self.assertRaises(SystemExit):
            COMPARE.validate_contention_requests('test', trials, reqs[:1])
        duplicate = reqs + [dict(reqs[1])]
        with self.assertRaises(SystemExit):
            COMPARE.validate_contention_requests('test', trials, duplicate)

    def test_figure_generation_keeps_four_outputs_and_uses_ci_metrics(self):
        scenario_medians = {'b1': (50.5, 70.6, 116.7), 'b2': (71.7, 82.8, 116.0),
                            'p': (84.5, 83.1, 112.7)}
        methods = {}
        for key, rate in (('b1', 1.0), ('b2', .0), ('p', .0)):
            methods[key] = {'2': {}, '5': {}, '10': {}, 'all': {}}
            for level, scenario_median in zip(('2', '5', '10'), scenario_medians[key]):
                methods[key][level] = dict(duplicate_rate=rate, duplicate_ci95=COMPARE.wilson(int(rate * 50), 50)[1:],
                                           median_ms=20.0, p95_ms=30.0,
                                           median_scenario_median_ms=scenario_median)
        lease_entry = dict(recovery_success=0.0, recovery_ci95=list(COMPARE.wilson(0, 100)[1:]), recovered=0,
                           expired_cases=100, false_release=0, active_cases=25, false_release_rate=0,
                           false_release_ci95=list(COMPARE.wilson(0, 25)[1:]), listings_with_more_than_one_active_claim=0)
        m = {'contention': methods, 'lease': {'b2': lease_entry, 'p': lease_entry},
             'geofence_check': {'by_reference': {label: {'pairs': 1, 'correct': 1} for label in
                                                ('ELIGIBLE', 'OUTSIDE_GEOFENCE', 'ROUTE_UNAVAILABLE')},
                                'direct_claims': 1, 'direct_claims_refused': 1}}
        source = COMPARE_PATH.read_text(encoding='utf-8')
        self.assertIn("low=low, high=high", source)
        self.assertIn("e2_fig1_duplicate_owners.png", source)
        self.assertIn("e2_fig2_response_time.png", source)
        self.assertIn("e2_fig3_lease_recovery.png", source)
        self.assertIn("e2_fig4_geofence_check.png", source)
        if importlib.util.find_spec('matplotlib') is not None:
            save = COMPARE.save

            def check_response_plot(plt, fig, name):
                if name == 'e2_fig2_response_time.png':
                    ax = fig.axes[0]
                    expected = [value for group in scenario_medians.values() for value in group]
                    self.assertEqual([bar.get_height() for bar in ax.patches], expected)
                    self.assertEqual([label.get_text() for label in ax.texts], [f'{v:.1f}' for v in expected])
                    self.assertEqual([label.get_text() for label in ax.get_legend().get_texts()],
                                     ['Baseline 1', 'Baseline 2', 'Proposed'])
                save(plt, fig, name)

            with tempfile.TemporaryDirectory() as temp, patch.object(COMPARE, 'OUT', Path(temp)), \
                    patch.object(COMPARE, 'save', side_effect=check_response_plot) as save_figure:
                COMPARE.figures(m)
                self.assertIn('e2_fig2_response_time.png', [call.args[2] for call in save_figure.call_args_list])
                self.assertEqual(len(list(Path(temp).glob('*.png'))), 4)
        else:
            # The offline source-level assertion above still verifies CI wiring when the
            # optional plotting package is absent from this machine.
            ast.parse(source)


if __name__ == '__main__':
    unittest.main()
