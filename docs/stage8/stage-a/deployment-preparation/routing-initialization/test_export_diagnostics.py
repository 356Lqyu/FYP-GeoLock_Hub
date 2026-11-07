"""Mocked control-flow tests. Never contacts DEV; no database fixtures/data."""
import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import psycopg
import export_current_dev as export
from export_diagnostics import safe_error

MARKER='NOT_A_REAL_CREDENTIAL_TEST_MARKER'

class FakeConnection:
    def __init__(self,fail=None,rollback_fail=False):
        self.statements=[]; self.fail=fail; self.rollback_fail=rollback_fail
    def __enter__(self): return self
    def __exit__(self,*args): return False
    def execute(self,sql):
        self.statements.append(sql)
        if self.fail and self.fail in sql: raise psycopg.OperationalError('server closed the connection unexpectedly '+MARKER)
        if sql=='ROLLBACK' and self.rollback_fail: raise psycopg.OperationalError('connection is closed '+MARKER)
        return self
    def fetchone(self):
        return ({'database':'postgres','current_user':'postgres','session_user':'postgres',
           'read_only':'on','ssl':True,'float_output':'0','server_version_num':170011},)

class DiagnosticTests(unittest.TestCase):
    def run_mode(self,connection=None,error=None):
        with tempfile.TemporaryDirectory(prefix='geolock-local-unit-') as temporary:
            root=Path(temporary)
            (root/'results/routing-initialization-preparation').mkdir(parents=True)
            params={'sslrootcert':'dummy-public-certificate-path'}
            with contextlib.ExitStack() as stack:
                stack.enter_context(patch.object(export,'ROOT',root))
                stack.enter_context(patch.object(export,'reference_check',return_value={}))
                stack.enter_context(patch.object(export,'approved_profile',return_value=(root/'profile',params)))
                stack.enter_context(patch.object(export,'sha',return_value='unit-test-hash'))
                stack.enter_context(patch.object(export.sys,'argv',['export_current_dev.py','--diagnose-connection']))
                stack.enter_context(patch.object(export.sys.stdin,'isatty',return_value=True))
                stack.enter_context(patch.object(export.getpass,'getpass',return_value=MARKER))
                connector=stack.enter_context(patch.object(export.psycopg,'connect',side_effect=error,return_value=connection))
                stack.enter_context(patch.object(export.subprocess,'run',side_effect=AssertionError('No verifier in diagnostic mode')))
                output=stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
                code=export.main()
            paths=list((root/'results/routing-connection-diagnostics').glob('*/receipt.json'))
            self.assertEqual(len(paths),1)
            receipt=json.loads(paths[0].read_text())
            all_text='\n'.join(p.read_text() for p in root.rglob('*') if p.is_file())
            self.assertNotIn(MARKER,all_text+output.getvalue())
            self.assertNotIn('COPY (',(paths[0].parent/'queries.sql').read_text())
            self.assertEqual(list(root.rglob('*.csv')),[])
            self.assertEqual(receipt['files'],{})
            self.assertTrue(connector.call_args.kwargs['autocommit'])
            return code,receipt

    def test_success_stops_after_identity_and_rollback(self):
        conn=FakeConnection()
        code,receipt=self.run_mode(connection=conn)
        self.assertEqual(code,0); self.assertEqual(receipt['status'],'DIAGNOSTIC_PASS')
        self.assertTrue(receipt['rollback_completed'])
        self.assertEqual(conn.statements[0],'BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY')
        self.assertEqual(conn.statements[-1],'ROLLBACK')
        self.assertEqual(len(conn.statements),7)

    def test_authentication_error_phase_and_no_message_leak(self):
        code,receipt=self.run_mode(error=psycopg.OperationalError('password authentication failed '+MARKER))
        self.assertEqual(code,1); self.assertEqual(receipt['failure']['failed_phase'],'connect')
        self.assertIn('PASSWORD_AUTHENTICATION_FAILED',receipt['failure']['classifications'])

    def test_begin_error_distinguished_from_connect(self):
        code,receipt=self.run_mode(connection=FakeConnection(fail='BEGIN'))
        self.assertEqual(code,1); self.assertEqual(receipt['failure']['failed_phase'],'snapshot_begin')

    def test_primary_failure_not_masked_by_rollback_failure(self):
        code,receipt=self.run_mode(connection=FakeConnection(fail='extra_float_digits',rollback_fail=True))
        self.assertEqual(code,1)
        self.assertEqual(receipt['failure']['failed_phase'],'set_extra_float_digits')
        self.assertEqual(receipt['rollback_error']['failed_phase'],'rollback')

    def test_tls_classification_never_returns_message(self):
        result=safe_error(psycopg.OperationalError('certificate verify failed password='+MARKER),'connect')
        self.assertEqual(result['classifications'],['TLS_CERTIFICATE_VERIFICATION_FAILED'])
        self.assertNotIn(MARKER,json.dumps(result))

    def test_unknown_failure_remains_unknown(self):
        result=safe_error(psycopg.OperationalError(MARKER),'connect')
        self.assertEqual(result['classifications'],['UNCLASSIFIED_ERROR'])

    def test_fatal_message_distinguished_from_bare_phrase(self):
        result=safe_error(psycopg.OperationalError('FATAL: password authentication failed for user '+MARKER),'connect')
        self.assertEqual(result['failure_domain'],'SERVER_OR_POOLER_STYLE_FATAL_AUTH_REJECTION')
        self.assertTrue(result['evidence_flags']['server_style_fatal_auth_message'])
        self.assertNotIn(MARKER,json.dumps(result))
        bare=safe_error(psycopg.OperationalError('password authentication failed '+MARKER),'connect')
        self.assertEqual(bare['failure_domain'],'AUTH_PHRASE_ONLY_ORIGIN_UNVERIFIED')

    def test_mixed_errors_are_not_hidden(self):
        result=safe_error(psycopg.OperationalError('SSL error: handshake failed; FATAL: password authentication failed '+MARKER),'connect')
        self.assertEqual(result['failure_domain'],'MIXED_AUTH_AND_TLS_MESSAGES')
        self.assertTrue(result['evidence_flags']['tls_failure_marker'])
        self.assertNotIn(MARKER,json.dumps(result))

    def test_circuit_breaker_is_reported_separately(self):
        result=safe_error(psycopg.OperationalError('FATAL: Circuit breaker open '+MARKER),'connect')
        self.assertEqual(result['failure_domain'],'POOLER_TEMPORARY_REJECTION')
        self.assertIn('POOLER_CIRCUIT_BREAKER_OPEN',result['classifications'])

    def test_sqlstate_authentication_evidence(self):
        class Rejection(Exception): sqlstate='28P01'
        result=safe_error(Rejection(MARKER),'connect')
        self.assertEqual(result['failure_domain'],'STRUCTURED_AUTHORIZATION_REJECTION')
        self.assertNotIn(MARKER,json.dumps(result))

if __name__=='__main__': unittest.main()
