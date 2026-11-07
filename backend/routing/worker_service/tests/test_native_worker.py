"""Native runtime adapter and catalog-only gate; synthetic secrets/connections."""
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import Mock,patch

from psycopg import pq
from psycopg.conninfo import make_conninfo
from backend.routing.worker_service.native_worker import NativeRpcFactory,check_connection
from backend.routing.worker_service.native_service_connection import approved_profile,byte_conninfo
from backend.routing.worker_service.server import application_from_env
from backend.routing.worker_service.transport import RPCS


def dsn(role):
    profile=approved_profile()
    logins={'geolock_graph_worker':'geolock_graph_login','geolock_planner':'geolock_planner_login','geolock_validator':'geolock_validator_login'}
    params={k:profile[k] for k in ('host','port','dbname','sslmode','sslrootcert')}
    params['user']=logins[role]+'.rcgyuwiidqvrgbxswhqj'
    return make_conninfo(**params)


class NativeWorkerTests(unittest.TestCase):
    def test_original_non_utf8_bytes_and_role_tls_survive_libpq_parse(self):
        for role in RPCS:
            raw=b"SYNTHETIC \x82\xe9'\\ %20"
            options={p.keyword:p.val for p in pq.Conninfo.parse(byte_conninfo(raw,role=role,read_only=False))}
            self.assertEqual(options[b'password'],raw)
            self.assertEqual(options[b'sslmode'],b'verify-full')
            self.assertEqual(options[b'options'],b'')
            self.assertEqual(options[b'hostaddr'],b'')
            self.assertEqual(options[b'port'],b'5432')
            self.assertTrue(options[b'user'].startswith(b'geolock_'))
            self.assertEqual({p.keyword:p.val for p in pq.Conninfo.parse(byte_conninfo(raw,role=role,read_only=True))}[b'options'],b'-c default_transaction_read_only=on')

    def test_role_factory_collects_before_requests_keeps_bytes_until_shutdown(self):
        secret=bytearray(b'SYNTHETIC \x82\xe9');reader=Mock(return_value=secret);connections=[]
        def connect(copy,**kwargs):
            self.assertEqual(copy,b'SYNTHETIC \x82\xe9');self.assertFalse(kwargs['read_only'])
            copy[:]=b'\0'*len(copy);conn=Mock();connections.append(conn);return conn
        factory=NativeRpcFactory(reader=reader,connector=connect)
        rpc=factory(dsn('geolock_planner'),'geolock_planner')
        reader.assert_called_once();self.assertEqual(connections,[])
        self.assertIs(rpc._connection(),connections[0]);self.assertIs(rpc._connection(),connections[1])
        self.assertEqual(secret,b'SYNTHETIC \x82\xe9')
        factory.close();self.assertTrue(all(b==0 for b in secret))
        with self.assertRaises(RuntimeError):rpc._connection()

    def test_target_role_password_dsn_or_tls_drift_rejected_before_prompt(self):
        reader=Mock();factory=NativeRpcFactory(reader=reader)
        for bad in [dsn('geolock_planner')+' password=SYNTHETIC',dsn('geolock_validator'),dsn('geolock_planner').replace('verify-full','require')]:
            with self.assertRaises(ValueError):factory(bad,'geolock_planner')
        reader.assert_not_called()

    def connection(self,role='geolock_planner',ro='on'):
        conn=Mock();identity=dict(session_user='geolock_planner_login',current_user=role,database='postgres',read_only=ro,ssl=True,tls_version='TLSv1.3')
        observations=0
        def execute(sql,params=None):
            nonlocal observations
            row=Mock()
            if 'jsonb_build_object' in sql:
                observations+=1
                row.fetchone.return_value=(dict(identity,current_user=identity['session_user']) if observations==1 else dict(identity,ssl=None,tls_version=None),)
            elif 'NOT r.rolsuper' in sql:row.fetchone.return_value=(True,)
            elif 'has_function_privilege' in sql:
                name=params[0].split('.')[1].split('(')[0]
                row.fetchone.return_value=(name in RPCS[role],)
            return row
        conn.execute.side_effect=execute
        return conn

    def test_readonly_actual_rpc_connection_rollback_close_and_permission_matrix(self):
        rpc=Mock();rpc.role='geolock_planner';conn=self.connection();rpc._connection.return_value=conn
        report=check_connection(rpc)
        self.assertEqual(report['status'],'PASS');self.assertTrue(report['rollback']);self.assertTrue(report['connection_closed'])
        self.assertTrue(report['login_identity']['ssl']);self.assertIsNone(report['identity']['ssl'])
        self.assertEqual(len(report['permissions']),8)
        rpc._connection.assert_called_once();rpc.call.assert_not_called();conn.commit.assert_not_called()
        commands=[call.args[0] for call in conn.execute.call_args_list]
        self.assertEqual(commands[0],'BEGIN READ ONLY')
        self.assertFalse(any('public.read_' in c for c in commands))
        conn.close.assert_called_once()

    def test_readwrite_or_permission_drift_is_fail_closed(self):
        for readonly in ['off','on']:
            rpc=Mock();rpc.role='geolock_planner';conn=self.connection(ro=readonly)
            if readonly=='on':
                original=conn.execute.side_effect
                def execute(sql,params=None):
                    row=original(sql,params)
                    if 'has_function_privilege' in sql:row.fetchone.return_value=(True,)
                    return row
                conn.execute.side_effect=execute
            rpc._connection.return_value=conn
            self.assertEqual(check_connection(rpc)['status'],'FAIL')
            conn.rollback.assert_called();conn.close.assert_called_once();conn.commit.assert_not_called()

    def test_connection_exception_redacted_and_not_retried(self):
        rpc=Mock();rpc.role='geolock_validator';rpc._connection.side_effect=RuntimeError('SYNTHETIC_SECRET_DO_NOT_LOG')
        report=check_connection(rpc)
        self.assertEqual(report['status'],'FAIL');self.assertNotIn('SYNTHETIC_SECRET',json.dumps(report));rpc._connection.assert_called_once()

    def test_rollback_failure_still_closes_and_cannot_pass(self):
        rpc=Mock();rpc.role='geolock_planner';conn=self.connection()
        conn.rollback.side_effect=RuntimeError('SYNTHETIC_SECRET')
        rpc._connection.return_value=conn
        report=check_connection(rpc)
        self.assertEqual(report['status'],'FAIL');conn.close.assert_called_once()
        self.assertNotIn('SYNTHETIC_SECRET',json.dumps(report))

    def test_disabled_app_never_collects_or_connects(self):
        factory=Mock();self.assertFalse(application_from_env('planner',{},rpc_factory=factory).active)
        factory.assert_not_called()

    def test_launcher_selects_native_entry_and_no_database_password_reveal(self):
        root=Path(__file__).resolve().parents[4]
        text=(root/'backend/routing/worker_service/windows/Start-Worker.ps1').read_text()
        self.assertIn('worker_service.native_worker',text)
        for field in ['GraphPassword','PlannerPassword','ValidatorPassword']:self.assertNotIn('$config.'+field,text)
        self.assertNotIn("' password='",text)

    @unittest.skipUnless(sys.platform=='win32','Installed native Windows libpq')
    def test_actual_native_entrypoint_check_config_is_disabled_and_no_prompt(self):
        env={k:v for k,v in os.environ.items() if not k.upper().startswith(('PG','GEOLOCK_','PSYCOPG_'))}
        result=subprocess.run([sys.executable,'-B','-m','backend.routing.worker_service.native_worker','--mode','validator','--check-config'],
            env=env,capture_output=True,text=True,check=True,timeout=10)
        self.assertEqual(json.loads(result.stdout)['status'],'DISABLED')
