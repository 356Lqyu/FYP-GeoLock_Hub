"""Native full-probe integration and budgets with synthetic/mock inputs only."""
import io
import json
import os
from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import MagicMock,Mock,patch

from backend.routing.worker_service.native_readonly_session import NativeReadOnlySession
from backend.routing.worker_service.readonly_pilot_probe import ReadOnlyGraphRpc,GRAPH,DIGEST,child
from backend.routing.worker_service.probe_resources import run_bounded,memory_usage
from backend.routing.worker_service.errors import WorkerError
from psycopg.pq import TransactionStatus
from backend.routing.worker_service.connection_diagnostic import IDENTITY_SQL


def connection():
    conn=MagicMock()
    conn.info.transaction_status=TransactionStatus.IDLE
    identity=dict(session_user='geolock_graph_login',current_user='geolock_graph_login',database='postgres',read_only='on',ssl=True)
    def execute(sql,*args):
        row=(identity,) if sql==IDENTITY_SQL else ('on',)
        cursor=Mock();cursor.fetchone.return_value=row;return cursor
    conn.execute.side_effect=execute
    return conn


class NativeFullProbeTests(unittest.TestCase):
    def test_driver_readonly_is_set_before_initial_select_even_if_server_default_is_off(self):
        conn=connection();original=conn.execute.side_effect
        def execute(sql,*args):
            self.assertIs(conn.autocommit,False)
            self.assertIs(conn.read_only,True)
            result=original(sql,*args)
            if sql==IDENTITY_SQL:result.fetchone.return_value[0]['default_read_only']='off'
            return result
        conn.execute.side_effect=execute
        session=NativeReadOnlySession(bytearray(b'SYNTHETIC'),connector=Mock(return_value=conn))
        session()
        self.assertEqual(session.observed_identity['read_only'],'on')
        self.assertEqual(session.observed_identity['default_read_only'],'off')
        session.close()

    def test_nonidle_connector_is_rejected_before_any_identity_query(self):
        conn=connection();conn.info.transaction_status=TransactionStatus.INTRANS
        session=NativeReadOnlySession(bytearray(b'SYNTHETIC'),connector=Mock(return_value=conn))
        with self.assertRaises(WorkerError):session()
        conn.execute.assert_not_called();conn.close.assert_called_once()

    def test_policy_drift_after_rollback_closes_session_without_reconnect(self):
        conn=connection();connector=Mock(return_value=conn)
        session=NativeReadOnlySession(bytearray(b'SYNTHETIC'),connector=connector)
        with session():pass
        conn.read_only=False
        with self.assertRaises(WorkerError):session()
        conn.close.assert_called_once();connector.assert_called_once()
        self.assertEqual(session.failure_phase,'verify_borrow_policy')

    def test_failed_initial_readonly_verification_never_lends_connection(self):
        conn=connection();original=conn.execute.side_effect
        def execute(sql,*args):
            result=original(sql,*args)
            if sql==IDENTITY_SQL:result.fetchone.return_value[0]['read_only']='off'
            return result
        conn.execute.side_effect=execute
        session=NativeReadOnlySession(bytearray(b'SYNTHETIC'),connector=Mock(return_value=conn))
        with self.assertRaises(WorkerError):session()
        self.assertEqual(session.page_rollbacks,0)
        self.assertEqual(session.failure_phase,'verify_initial_read_only_identity')
        conn.close.assert_called_once()

    def test_native_connection_reused_but_each_page_rolls_back_and_never_commits(self):
        conn=connection();connector=Mock(return_value=conn)
        password=bytearray(b'SYNTHETIC_ONLY')
        session=NativeReadOnlySession(password,connector=connector)
        manifest=dict(graph_id=GRAPH,content_digest=DIGEST,coverage_snapshot='OSM-OPS-20261018',node_count=926414,edge_count=2145828)
        page=dict(graph=manifest,nodes=[],edges=[])
        cur=conn.cursor.return_value.__enter__.return_value
        cur.fetchone.side_effect=[(True,),(page,),(True,),(page,)]
        rpc=ReadOnlyGraphRpc('', 'geolock_graph_worker',connect=session)
        for _ in range(2):rpc.call('read_frozen_routing_graph',GRAPH,None,None)
        connector.assert_called_once();self.assertTrue(all(x==0 for x in password))
        self.assertEqual(session.page_rollbacks,2)
        self.assertEqual(conn.rollback.call_count,3)
        conn.commit.assert_not_called();conn.close.assert_not_called()
        session.close();conn.close.assert_called_once()
        metrics=session.metrics()
        self.assertEqual(metrics['sql_calls']['rpc_execute'],2)
        self.assertEqual(metrics['sql_calls']['rpc_fetch_decode'],2)
        self.assertEqual(metrics['sql_calls']['page_rollback'],2)
        self.assertNotIn('SYNTHETIC',json.dumps(metrics))

    @unittest.skipUnless(sys.platform=='win32','Owned Windows process tree')
    def test_memory_limit_stops_interpreter_and_redirector(self):
        from backend.routing.worker_service.probe_resources import process_parents,is_descendant
        with TemporaryDirectory() as folder,(Path(folder)/'local-only.log').open('w') as log:
            report=Path(folder)/'pid.json'
            code="import os,json,time;from pathlib import Path;Path("+repr(str(report))+").write_text(json.dumps({'worker_pid':os.getpid()}));data=bytearray(64*1024*1024);time.sleep(10)"
            result=run_bounded([sys.executable,'-B','-c',code],log,5,max_memory_mb=48,
                worker_metadata=lambda:json.loads(report.read_text()) if report.exists() else {})
            worker=json.loads(report.read_text())['worker_pid']
        self.assertEqual(result['stop_reason'],'MEMORY LIMIT / NO READINESS PASS')
        self.assertEqual(result['monitored_worker_pid'],worker)
        parents=process_parents()
        self.assertFalse(worker in parents,'Owned interpreter must exit')
        self.assertFalse(result['launcher_pid'] in parents,'Owned launcher must exit')

    def test_native_connection_failure_zeroes_password_and_never_reconnects(self):
        connector=Mock(side_effect=RuntimeError('SYNTHETIC_SECRET'))
        password=bytearray(b'SYNTHETIC_ONLY');session=NativeReadOnlySession(password,connector=connector)
        with self.assertRaises(RuntimeError):session()
        self.assertTrue(all(x==0 for x in password))
        with self.assertRaises(WorkerError):session()
        connector.assert_called_once()

    def test_native_identity_failure_closes_connection(self):
        conn=connection();conn.execute.side_effect=None
        conn.execute.return_value.fetchone.return_value=({'session_user':'wrong','current_user':'wrong'},)
        session=NativeReadOnlySession(bytearray(b'SYNTHETIC'),connector=Mock(return_value=conn))
        with self.assertRaises(WorkerError):session()
        conn.close.assert_called_once()

    def test_graph_failure_closes_session_and_redacts_secret(self):
        session=Mock();session.metrics.return_value=dict(connection_closed=True)
        with TemporaryDirectory() as folder,patch('backend.routing.worker_service.readonly_pilot_probe.GraphCache') as cache:
            cache.return_value.load.side_effect=ValueError('SYNTHETIC_SECRET_NEVER_SAVE')
            path=Path(folder)
            self.assertEqual(child(path,True,connection_factory=session,dsn_override='offline'),1)
            report=json.loads((path/'result.json').read_text())
            self.assertEqual(report['status'],'FAILED / NO READINESS PASS')
            self.assertNotIn('SYNTHETIC_SECRET',json.dumps(report))
            self.assertTrue(report['connection_metrics']['connection_closed'])
            self.assertEqual(report['matrix_seconds'],[])
            session.close.assert_called_once()

    def test_cleanup_failure_cannot_be_a_pass(self):
        session=Mock();session.close.side_effect=RuntimeError('SYNTHETIC_SECRET')
        session.metrics.return_value=dict(connection_closed=True,cleanup_failed=True)
        with TemporaryDirectory() as folder,patch('backend.routing.worker_service.readonly_pilot_probe.GraphCache') as cache:
            cache.return_value.load.return_value=({},[],[])
            self.assertEqual(child(Path(folder),False,connection_factory=session,dsn_override='offline'),1)
            report=json.loads((Path(folder)/'result.json').read_text())
            self.assertEqual(report['error_code'],'NATIVE_SESSION_CLEANUP_FAILED')
            self.assertNotIn('SYNTHETIC_SECRET',json.dumps(report))

    def test_sampled_memory_stop_kills_only_owned_child(self):
        process=Mock();process.communicate.side_effect=[subprocess.TimeoutExpired('synthetic',.2),None]
        process.returncode=-9;process.poll.return_value=-9
        usage=dict(private_commit=5*1024**3,peak_private_commit=5*1024**3,working_set=1,peak_working_set=1)
        result=run_bounded(['synthetic-only'],io.StringIO(),600,max_memory_mb=4096,
                           popen=Mock(return_value=process),memory=Mock(return_value=usage))
        self.assertEqual(result['stop_reason'],'MEMORY LIMIT / NO READINESS PASS')
        process.kill.assert_called_once()

    def test_wall_timeout_stops_without_retry(self):
        process=Mock();process.communicate.side_effect=[subprocess.TimeoutExpired('synthetic',.2),None]
        process.returncode=-9;process.poll.return_value=-9
        popen=Mock(return_value=process)
        result=run_bounded(['synthetic-only'],io.StringIO(),1,popen=popen,clock=Mock(side_effect=[0,2,2]))
        self.assertEqual(result['stop_reason'],'TIMEOUT / NO READINESS PASS')
        popen.assert_called_once();process.kill.assert_called_once()

    @unittest.skipUnless(sys.platform=='win32','Owned Windows process counters')
    def test_monitor_targets_reported_interpreter_not_small_venv_redirector(self):
        with TemporaryDirectory() as folder,(Path(folder)/'local-only.log').open('w') as log:
            report=Path(folder)/'pid.json'
            code="import os,json,time;from pathlib import Path;Path("+repr(str(report))+").write_text(json.dumps({'worker_pid':os.getpid()}));data=bytearray(64*1024*1024);time.sleep(1)"
            result=run_bounded([sys.executable,'-B','-c',code],log,5,max_memory_mb=256,
                              worker_metadata=lambda:json.loads(report.read_text()) if report.exists() else {})
            self.assertEqual(result['monitored_worker_pid'],json.loads(report.read_text())['worker_pid'])
        self.assertEqual(result['returncode'],0)
        self.assertGreater(result['sampled_peak_private_bytes'],64*1024*1024)

    @unittest.skipUnless(sys.platform=='win32','Owned Windows process counters')
    def test_budget_monitor_with_actual_owned_local_child_and_no_network(self):
        with TemporaryDirectory() as folder,(Path(folder)/'local-only.log').open('w') as log:
            result=run_bounded([sys.executable,'-B','-c','import time; data=bytearray(16*1024*1024); time.sleep(0.6)'],
                               log,5,max_memory_mb=256)
        self.assertEqual(result['returncode'],0)
        self.assertIsNone(result['stop_reason'])
        self.assertGreater(result['sampled_peak_private_bytes'],0)

    @unittest.skipUnless(sys.platform=='win32','Owned Windows process counters')
    def test_memory_monitor_reads_only_own_process_handle(self):
        own=Mock();own._handle=-1
        counters=memory_usage(own)
        self.assertGreater(counters['working_set'],0)
        self.assertGreater(counters['private_commit'],0)

    @unittest.skipUnless(sys.platform=='win32','Windows installed native libpq')
    def test_native_full_probe_setup_is_offline(self):
        env={k:v for k,v in os.environ.items() if not k.startswith(('PG','GEOLOCK_','PSYCOPG_'))}
        result=subprocess.run([sys.executable,'-B','-m','backend.routing.worker_service.native_service_probe','--check-local'],
                              env=env,capture_output=True,text=True,check=True)
        self.assertEqual(json.loads(result.stdout)['status'],'NATIVE_FULL_PROBE_READY / NOT CONNECTED')
