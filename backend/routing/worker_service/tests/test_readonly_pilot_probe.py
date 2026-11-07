"""Read-only probe boundaries; no network or credentials."""
import unittest
from unittest.mock import Mock, MagicMock, patch
import json
import psycopg

from backend.routing.worker_service.errors import WorkerError
from backend.routing.worker_service.readonly_pilot_probe import ReadOnlyGraphRpc, GRAPH, DIGEST
from backend.routing.worker_service.transport import RoleRpc
from backend.routing.worker_service.probe_diagnostics import safe_failure


class ReadOnlyProbeTests(unittest.TestCase):
    def test_actual_readwrite_transaction_is_closed_before_any_graph_rpc(self):
        conn=MagicMock();conn.execute.return_value.fetchone.return_value=('off',)
        rpc=ReadOnlyGraphRpc('', 'geolock_graph_worker',connect=lambda:conn)
        with self.assertRaises(WorkerError):rpc.call('read_frozen_routing_graph',GRAPH,None,None)
        conn.cursor.assert_not_called()
        conn.close.assert_called_once()
        self.assertEqual(rpc.failure['failed_operation'],'verify_transaction_read_only')
        self.assertEqual(rpc.failure['failure_domain'],'WORKER_CONTRACT_REJECTION')

    def test_authentication_exception_is_reported_before_generic_translation(self):
        def fail():
            raise psycopg.OperationalError('FATAL: password authentication failed synthetic-secret-DO-NOT-RETAIN')
        rpc=ReadOnlyGraphRpc('', 'geolock_graph_worker',connect=fail)
        with self.assertRaises(WorkerError) as result:
            rpc.call('read_frozen_routing_graph',GRAPH,None,None)
        self.assertEqual(result.exception.code,'READ_ONLY_PROBE_OPERATION_FAILED')
        self.assertFalse(result.exception.retryable)
        self.assertEqual(rpc.failure['failed_operation'],'connect')
        self.assertIn('AUTH_REJECTION_MARKER',rpc.failure['markers'])
        self.assertIsNone(rpc.failure['sqlstate'])
        self.assertNotIn('synthetic-secret',json.dumps(rpc.failure))

    def test_fetch_application_exception_is_not_mislabeled_authentication(self):
        conn=MagicMock(); conn.__enter__.return_value=conn
        conn.execute.return_value.fetchone.return_value=('on',)
        cur=conn.cursor.return_value.__enter__.return_value
        cur.fetchone.side_effect=[(True,),None]
        rpc=ReadOnlyGraphRpc('', 'geolock_graph_worker',connect=lambda:conn)
        with self.assertRaises(WorkerError): rpc.call('read_frozen_routing_graph',GRAPH,None,None)
        self.assertEqual(rpc.failure['failed_operation'],'fetch_result')
        self.assertEqual(rpc.failure['failure_domain'],'LOCAL_APPLICATION_EXCEPTION')
        self.assertEqual(rpc.failure['markers'],[])

    def test_readonly_setup_exception_is_preserved_and_connection_closed(self):
        conn=Mock(); conn.execute.side_effect=psycopg.OperationalError('synthetic connection is closed')
        rpc=ReadOnlyGraphRpc('', 'geolock_graph_worker',connect=lambda:conn)
        with self.assertRaises(WorkerError): rpc.call('read_frozen_routing_graph',GRAPH,None,None)
        self.assertEqual(rpc.failure['failed_operation'],'set_transaction_read_only')
        conn.close.assert_called_once()

    def test_write_worker_unknown_outcome_contract_unchanged(self):
        def fail(): raise psycopg.OperationalError('synthetic disconnect')
        rpc=RoleRpc('', 'geolock_graph_worker',connect=fail)
        with self.assertRaises(WorkerError) as result: rpc.call('store_routing_matrix',GRAPH,GRAPH,{})
        self.assertEqual(result.exception.code,'RPC_OUTCOME_UNKNOWN_RETRY_SAME_REQUEST')
        self.assertTrue(result.exception.retryable)

    def test_safe_sql_error_categories_and_secret_redaction(self):
        for state,domain in [('28P01','STRUCTURED_AUTHORIZATION_REJECTION'),
            ('42501','SQL_PERMISSION_REJECTION'),('57014','SQL_CANCELLATION_OR_LOCK_TIMEOUT'),
            ('25001','SQL_TRANSACTION_STATE_REJECTION'),('42883','SQL_ERROR')]:
            error=Exception('postgres://synthetic:never-save-password@example.invalid')
            error.sqlstate=state
            result=safe_failure(error,'execute_rpc')
            self.assertEqual(result['failure_domain'],domain)
            self.assertEqual(result['sqlstate'],state)
            self.assertNotIn('never-save-password',json.dumps(result))
            self.assertNotIn('example.invalid',json.dumps(result))

    def test_tls_marker_does_not_claim_authentication(self):
        result=safe_failure(psycopg.OperationalError('certificate verify failed private-dsn-secret'),'connect')
        self.assertEqual(result['markers'],['TLS_FAILURE_MARKER'])
        self.assertNotIn('private-dsn-secret',json.dumps(result))

    def test_transaction_is_readonly_before_role_rpc(self):
        connection=Mock()
        connection.execute.return_value.fetchone.return_value=('on',)
        with patch.object(RoleRpc,'_connection',return_value=connection):
            self.assertIs(ReadOnlyGraphRpc('', 'geolock_graph_worker')._connection(),connection)
        self.assertEqual([c.args for c in connection.execute.call_args_list],
                         [('SET TRANSACTION READ ONLY',),("SELECT current_setting('transaction_read_only')",)])

    def test_mutating_rpc_and_wrong_graph_are_rejected_before_connection(self):
        with patch.object(RoleRpc,'call') as call:
            rpc=ReadOnlyGraphRpc('', 'geolock_graph_worker')
            for name,args in [('store_routing_matrix',(GRAPH,GRAPH,{})),('read_frozen_routing_graph',('wrong',None,None))]:
                with self.assertRaises(WorkerError): rpc.call(name,*args)
            call.assert_not_called()

    def test_only_pinned_manifest_is_accepted(self):
        manifest=dict(graph_id=GRAPH,content_digest=DIGEST,coverage_snapshot='OSM-OPS-20261018',node_count=926414,edge_count=2145828)
        rpc=ReadOnlyGraphRpc('', 'geolock_graph_worker')
        with patch.object(RoleRpc,'call',return_value={'graph':manifest}):
            self.assertEqual(rpc.call('read_frozen_routing_graph',GRAPH,None,None)['graph'],manifest)
            manifest['content_digest']='0'*64
            with self.assertRaises(WorkerError): rpc.call('read_frozen_routing_graph',GRAPH,None,None)
