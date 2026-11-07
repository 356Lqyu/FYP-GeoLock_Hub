"""Offline native libpq service adapter tests. No credentials/network."""
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import Mock,patch

import psycopg
from psycopg import pq
from backend.routing.worker_service.native_service_connection import (
    byte_conninfo,connect_native,approved_profile,PROFILE,SERVICE)


class NativeServiceTests(unittest.TestCase):
    def test_libpq_parses_original_bytes_without_unicode_or_uri_conversion(self):
        for password in (b'synthetic ASCII',b"synthetic'quote\\tail",b'synthetic \x82\xe9\xc3',b'synthetic%20value'):
            options={v.keyword:v.val for v in pq.Conninfo.parse(byte_conninfo(password))}
            self.assertEqual(options[b'password'],password)
            self.assertEqual(options[b'service'],SERVICE.encode('ascii'))
            self.assertEqual(options[b'options'],b'-c default_transaction_read_only=on')

    def test_empty_nul_or_unicode_input_is_rejected_not_reencoded(self):
        for password in (b'',b'synthetic\0suffix','synthetic Unicode'):
            with self.assertRaises(ValueError):byte_conninfo(password)

    def test_approved_service_tls_and_graph_identity_remain_pinned(self):
        profile=approved_profile()
        self.assertEqual(profile['sslmode'],'verify-full')
        self.assertEqual(profile['user'],'geolock_graph_login.rcgyuwiidqvrgbxswhqj')
        self.assertEqual(profile['port'],'5432')
        self.assertNotIn('password',profile)
        self.assertNotIn('passfile',profile)

    def test_success_wraps_same_libpq_connection_and_clears_input(self):
        password=bytearray(b'synthetic \x82 quote\'')
        pg=Mock();pg.status=pq.ConnStatus.OK
        connector=Mock(return_value=pg);wrapper=Mock(return_value=object())
        with patch.dict(os.environ,{},clear=False):
            result=connect_native(password,connector=connector,wrapper=wrapper)
            self.assertEqual(os.environ['PGSERVICEFILE'],str(PROFILE))
        self.assertIs(result,wrapper.return_value)
        self.assertEqual(pg.nonblocking,1)
        wrapper.assert_called_once_with(pg)
        pg.finish.assert_not_called()
        self.assertTrue(all(b==0 for b in password))

    def test_failed_authentication_closes_libpq_and_clears_input(self):
        password=bytearray(b'SYNTHETIC_ONLY')
        pg=Mock();pg.status=pq.ConnStatus.BAD
        pg.get_error_message.return_value='FATAL: password authentication failed'
        wrapper=Mock()
        with patch.dict(os.environ,{},clear=False):
            with self.assertRaises(psycopg.OperationalError):
                connect_native(password,connector=Mock(return_value=pg),wrapper=wrapper)
        pg.finish.assert_called_once();wrapper.assert_not_called()
        self.assertTrue(all(b==0 for b in password))

    @unittest.skipUnless(sys.platform=='win32','Installed Windows native client')
    def test_native_service_client_check_is_offline(self):
        env={k:v for k,v in os.environ.items() if not k.startswith(('PG','GEOLOCK_','PSYCOPG_'))}
        result=subprocess.run([sys.executable,'-B','-m','backend.routing.worker_service.native_service_diagnostic','--check-local'],
                              env=env,capture_output=True,text=True,check=True)
        report=json.loads(result.stdout)
        self.assertEqual(report['status'],'NATIVE_SERVICE_READY / NOT CONNECTED')
        self.assertEqual(report['client']['libpq_version'],170011)

    def test_launcher_mode_has_no_powershell_password_or_dsn(self):
        root=Path(__file__).resolve().parents[4]
        text=(root/'docs/stage8/functional-routing/run_readonly_graph_probe.ps1').read_text()
        native=text.split('if ($NativeServiceDiagnostic) {\n        #',1)[1].split('} elseif',1)[0]
        self.assertIn('native_service_diagnostic',native)
        self.assertNotIn('Read-Host',native)
        self.assertNotIn('GEOLOCK_GRAPH_DSN',native)
