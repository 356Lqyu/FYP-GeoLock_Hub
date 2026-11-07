"""Offline CA policy tests. OpenSSL generates temporary synthetic certificates."""
from contextlib import redirect_stdout
import hashlib
import io
import os
from pathlib import Path
import shutil
import subprocess
import sys
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import Mock, patch

from psycopg import pq
from psycopg.conninfo import conninfo_to_dict

from backend.routing.worker_service import connection_diagnostic, native_service_connection as policy
from backend.routing.worker_service.errors import WorkerError
from backend.routing.worker_service.native_worker import NativeRpcFactory


class CAPortabilityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        openssl = shutil.which('openssl')
        if openssl is None:
            raise unittest.SkipTest('OpenSSL required for synthetic certificate generation')
        temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(temp.cleanup)
        folder = Path(temp.name)
        ca = folder / 'synthetic.pem'
        subprocess.run([
            openssl, 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
            '-days', '1', '-subj', '/CN=GeoLock Synthetic Test CA',
            '-keyout', str(folder / 'synthetic.key'), '-out', str(ca),
        ], check=True, capture_output=True, timeout=30)
        cls.ca_bytes = ca.read_bytes()

    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix='geolock synthetic ')
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.ca = self.root / 'CA with spaces.pem'
        self.ca.write_bytes(self.ca_bytes)
        self.host = 'synthetic.pooler.supabase.com'
        self.profile = self.root / 'approved.conf'
        self.profile.write_bytes((
            f'[{policy.SERVICE}]\nhost={self.host}\nport=5432\ndbname=postgres\n'
            f'user={policy.ROLE_LOGINS["geolock_graph_worker"]}.{policy.PROJECT}\n'
            'sslmode=verify-full\nsslrootcert=legacy-ca.crt\noptions=\nconnect_timeout=5\n'
        ).encode())
        for p in (
            patch.object(policy, 'profile_path', return_value=self.profile),
            patch.object(policy, 'PROFILE_SHA', hashlib.sha256(self.profile.read_bytes()).hexdigest()),
            patch.object(policy, 'APPROVED_CA_SHA256', hashlib.sha256(self.ca_bytes).hexdigest()),
            patch.dict(os.environ, {'PGSERVICE': ''}),
            patch('socket.socket.connect', side_effect=AssertionError('Network is forbidden')),
            patch('psycopg.connect', side_effect=AssertionError('Database is forbidden')),
        ):
            p.start()
            self.addCleanup(p.stop)

    def test_two_paths_with_identical_ca_and_spaces(self):
        other = self.root / 'Another operator' / 'copy.pem'
        other.parent.mkdir()
        other.write_bytes(self.ca_bytes)
        for path in (self.ca, other):
            with self.subTest(path=path.name):
                settings = policy.approved_profile(path)
                self.assertEqual(Path(settings['sslrootcert']), path.resolve())
                dsn = policy.validation_dsn(path)
                self.assertEqual(conninfo_to_dict(dsn)['sslrootcert'], str(path.resolve()))

    def test_missing_modified_and_appended_ca_fail(self):
        with self.assertRaisesRegex(policy.PolicyError, 'APPROVED_CA_MISSING'):
            policy.approved_profile(self.root / 'missing.pem')
        for raw in (self.ca_bytes + b'\n', self.ca_bytes + self.ca_bytes):
            self.ca.write_bytes(raw)
            with self.assertRaisesRegex(policy.PolicyError, 'APPROVED_CA_CONTENT_MISMATCH'):
                policy.approved_profile(self.ca)

    def test_missing_pin_and_modified_profile_fail(self):
        with patch.object(policy, 'APPROVED_CA_SHA256', None):
            with self.assertRaisesRegex(policy.PolicyError, 'ADMIN_APPROVED_CA_HASH_REQUIRED'):
                policy.approved_profile(self.ca)
        self.profile.write_bytes(self.profile.read_bytes() + b'\n')
        with self.assertRaisesRegex(policy.PolicyError, 'APPROVED_SERVICE_PROFILE_DRIFT'):
            policy.approved_profile(self.ca)

    def test_wrong_host_database_login_and_tls_fail_before_prompt(self):
        graph = 'geolock_graph_worker'
        dsn = policy.validation_dsn(self.ca)
        reader = Mock(side_effect=AssertionError('Password prompt forbidden'))
        factory = NativeRpcFactory(reader=reader)
        for old, new in (
            (self.host, 'wrong.pooler.supabase.com'),
            ('dbname=postgres', 'dbname=wrong'),
            ('geolock_graph_login', 'geolock_other_login'),
            ('verify-full', 'require'),
            ('5432', '6543'),
        ):
            with self.subTest(value=new), self.assertRaises((policy.PolicyError, WorkerError)):
                factory(dsn.replace(old, new), graph)
        with self.assertRaisesRegex(policy.PolicyError, 'NATIVE_RUNTIME_CONFIG_MISMATCH'):
            factory(dsn, 'geolock_planner')
        with self.assertRaisesRegex(policy.PolicyError, 'ABSOLUTE_LOCAL_CA_PATH_REQUIRED'):
            policy.approved_profile('system')
        reader.assert_not_called()

    def test_every_native_role_and_default_graph_use_validated_ca(self):
        for role in (None, *policy.ROLE_LOGINS):
            with self.subTest(role=role):
                raw = bytearray(b'synthetic test password')
                conn = Mock(status=pq.ConnStatus.OK)
                connector = Mock(return_value=conn)
                wrapper = Mock(return_value=object())
                self.assertIs(policy.connect_native(raw, connector=connector, wrapper=wrapper,
                                                    role=role, ca_path=self.ca), wrapper.return_value)
                args = conninfo_to_dict(connector.call_args.args[0].decode())
                self.assertEqual(args['sslrootcert'], str(self.ca.resolve()))
                self.assertEqual(args['host'], self.host)
                self.assertEqual(args['sslmode'], 'verify-full')
                self.assertEqual(args['user'], policy.ROLE_LOGINS[role or 'geolock_graph_worker'] + '.' + policy.PROJECT)
                self.assertEqual(args['gssencmode'], 'disable')
                self.assertNotIn('service', args)
                self.assertFalse(any(raw))

    def test_native_factory_carries_validated_ca_and_rechecks_on_connect(self):
        connector = Mock(side_effect=policy.connect_native)
        dsn = policy.validation_dsn(self.ca)
        factory = NativeRpcFactory(reader=lambda _: bytearray(b'synthetic'), connector=connector)
        self.addCleanup(factory.close)
        rpc = factory(dsn, 'geolock_graph_worker')
        self.ca.write_bytes(b'modified after factory setup')
        with self.assertRaisesRegex(policy.PolicyError, 'APPROVED_CA_CONTENT_MISMATCH'):
            rpc._connection()
        self.assertEqual(connector.call_args.kwargs['ca_path'], str(self.ca.resolve()))

    def test_ambient_service_and_ca_override_cannot_reach_connector(self):
        connector = Mock()
        with patch.dict(os.environ, {'PGSERVICE': 'unapproved'}), self.assertRaisesRegex(
                policy.PolicyError, 'AMBIENT_POSTGRESQL_SERVICE_NOT_ALLOWED'):
            policy.connect_native(bytearray(b'synthetic'), connector=connector, ca_path=self.ca)
        with patch.object(policy, 'APPROVED_CA_SHA256', None), patch.dict(
                os.environ, {'GEOLOCK_ROUTING_CA_SHA256': hashlib.sha256(self.ca_bytes).hexdigest()}), self.assertRaisesRegex(
                policy.PolicyError, 'ADMIN_APPROVED_CA_HASH_REQUIRED'):
            policy.connect_native(bytearray(b'synthetic'), connector=connector, ca_path=self.ca)
        connector.assert_not_called()

    @unittest.skipUnless(sys.platform == 'win32', 'Native Windows libpq bootstrap')
    def test_wrong_libpq_version_fails(self):
        from backend.routing.worker_service.connection_diagnostic_native17 import configure_client
        original_import = __import__
        fake_pq = SimpleNamespace(__impl__='python', version=lambda: 170010)

        def fake_import(name, *args, **kwargs):
            if name == 'psycopg':
                return SimpleNamespace(pq=fake_pq)
            if name == 'psycopg.pq.misc':
                return SimpleNamespace(find_libpq_full_path=Mock())
            return original_import(name, *args, **kwargs)

        with patch.dict(sys.modules), patch.dict(os.environ), patch('builtins.__import__', side_effect=fake_import), patch(
                'os.add_dll_directory', return_value=Mock()) as dll, patch.object(Path, 'is_file', return_value=True):
            sys.modules.pop('psycopg', None)
            with self.assertRaisesRegex(RuntimeError, 'NATIVE_LIBPQ_VERSION_OR_PATH_MISMATCH'):
                configure_client()
        dll.return_value.close.assert_called_once()

    def test_legacy_diagnostic_uses_native_read_only_connector(self):
        dsn = policy.validation_dsn(self.ca)
        with patch('backend.routing.worker_service.password_transport_check.read_native_console_password',
                   return_value=bytearray(b'synthetic')), patch.object(
                       connection_diagnostic, 'connect_native', side_effect=RuntimeError('synthetic stop')) as connect:
            self.assertEqual(connection_diagnostic.diagnose(dsn, {}), 1)
        self.assertEqual(connect.call_args.kwargs, {
            'role': 'geolock_graph_worker', 'read_only': True, 'ca_path': str(self.ca.resolve()),
        })

    def test_validate_only_never_prompts_or_writes(self):
        before = {p.name: p.read_bytes() for p in self.root.iterdir()}
        with patch('backend.routing.worker_service.connection_diagnostic_native17.configure_client',
                   return_value=(Mock(), {})), patch('builtins.input', side_effect=AssertionError('No prompts')), patch(
                       'backend.routing.worker_service.password_transport_check.read_native_console_password',
                       side_effect=AssertionError('No passwords')), redirect_stdout(io.StringIO()):
            with patch('sys.argv', ['offline', '--ca-path', str(self.ca), '--db-host', self.host]):
                self.assertEqual(policy.main(), 0)
            with patch('sys.argv', ['offline', '--ca-path', str(self.ca), '--db-host', 'unapproved']):
                self.assertEqual(policy.main(), 1)
        self.assertEqual({p.name: p.read_bytes() for p in self.root.iterdir()}, before)


if __name__ == '__main__':
    unittest.main()
