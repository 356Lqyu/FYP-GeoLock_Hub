"""Offline diagnostic regressions with synthetic connections; no DEV access."""
import json
from pathlib import Path
import unittest
from unittest.mock import Mock

import psycopg

from backend.routing.worker_service.connection_diagnostic import (
    diagnose, GRAPH, DIGEST, AFTER_NODE, AFTER_EDGE, NODE_IDS, EDGE_IDS,
    IDENTITY_SQL, PERMISSIONS_SQL)

DSN="host=aws-0-ap-northeast-2.pooler.supabase.com port=5432 dbname=postgres user=geolock_graph_login.rcgyuwiidqvrgbxswhqj sslmode=verify-full sslrootcert='C:/Users/User/Downloads/prod-ca-2021.crt' password='SYNTHETIC_NOT_A_REAL_PASSWORD'"


class DiagnosticTests(unittest.TestCase):
    def setup_connection(self):
        report=dict(status='INCOMPLETE',observed_graph=None)
        identity=dict(session_user='geolock_graph_login',current_user='geolock_graph_login',database='postgres',read_only='on',ssl=True,tls_version='TLSv1.3')
        permissions=dict(current_user='geolock_graph_worker',read_only='on',can_read_graph=True,safe_login=True,memberships=['geolock_graph_worker'],can_store_matrix=True)
        manifest=dict(graph_id=GRAPH,content_digest=DIGEST,coverage_snapshot='OSM-OPS-20261018',node_count=926414,edge_count=2145828,precision_policy='EXACT_MAX_6_DECIMALS',float_output_profile='PG_REAL_OUTPUT_0')
        page=dict(graph=manifest,nodes=[dict(osm_node_id=n,network_snapshot_id='OSM-OPS-20261018',active_flag=True) for n in NODE_IDS],
                  edges=[dict(edge_id=e,source_node=NODE_IDS[0],target_node=NODE_IDS[1],road_km=1,travel_minutes=1) for e in EDGE_IDS])
        conn=Mock()
        def execute(sql,params=None):
            value=identity if sql==IDENTITY_SQL else permissions if sql==PERMISSIONS_SQL else page if sql.startswith('SELECT public.read_frozen') else None
            cursor=Mock();cursor.fetchone.return_value=(value,);return cursor
        conn.execute.side_effect=execute
        return report,conn,identity,permissions,page

    def test_success_observes_manifest_and_only_three_records_each(self):
        report,conn,_,_,page=self.setup_connection()
        self.assertEqual(diagnose(DSN,report,connect=lambda:conn),0)
        self.assertEqual(report['observed_graph']['content_digest'],DIGEST)
        self.assertEqual(report['observed_sample'],dict(nodes=page['nodes'],edges=page['edges']))
        calls=conn.execute.call_args_list
        self.assertEqual(calls[0].args,('BEGIN READ ONLY',))
        self.assertEqual(calls[-1].args,('ROLLBACK',))
        rpc_calls=[c for c in calls if c.args[0].startswith('SELECT public.')]
        self.assertEqual(len(rpc_calls),1)
        self.assertEqual(rpc_calls[0].args[1],(GRAPH,AFTER_NODE,AFTER_EDGE))
        self.assertTrue(report['rollback_completed']);conn.close.assert_called_once()

    def test_mismatch_preserves_actual_observation_instead_of_pinned_digest(self):
        report,conn,_,_,page=self.setup_connection();page['graph']['content_digest']='0'*64
        self.assertEqual(diagnose(DSN,report,connect=lambda:conn),1)
        self.assertEqual(report['observed_graph']['content_digest'],'0'*64)
        self.assertEqual(report['failure']['failed_operation'],'validate_manifest_and_sample')
        self.assertTrue(report['rollback_completed'])

    def test_auth_failure_stops_after_single_connect_and_sanitizes(self):
        connect=Mock(side_effect=psycopg.OperationalError('FATAL: password authentication failed SYNTHETIC_SECRET_NEVER_LOG'))
        report={'status':'INCOMPLETE','observed_graph':None}
        self.assertEqual(diagnose(DSN,report,connect=connect),1)
        connect.assert_called_once()
        self.assertEqual(report['failure']['failed_operation'],'connect')
        self.assertIn('AUTH_REJECTION_MARKER',report['failure']['markers'])
        self.assertNotIn('SYNTHETIC_SECRET',json.dumps(report))
        self.assertIsNone(report['observed_graph'])

    def test_tls_observation_failure_rolls_back_before_role_or_rpc(self):
        report,conn,identity,_,_=self.setup_connection();identity['ssl']=False
        self.assertEqual(diagnose(DSN,report,connect=lambda:conn),1)
        self.assertEqual(report['failure']['failed_operation'],'identity_and_tls')
        self.assertFalse(any(c.args[0].startswith('SET LOCAL ROLE') for c in conn.execute.call_args_list))
        self.assertTrue(report['rollback_completed'])

    def test_permission_sqlstate_and_phase_retained(self):
        report,conn,_,_,_=self.setup_connection()
        original=conn.execute.side_effect
        def execute(sql,params=None):
            if sql.startswith('SET LOCAL ROLE'): raise psycopg.errors.InsufficientPrivilege('SYNTHETIC_SECRET_NEVER_LOG')
            return original(sql,params)
        conn.execute.side_effect=execute
        self.assertEqual(diagnose(DSN,report,connect=lambda:conn),1)
        self.assertEqual(report['failure']['sqlstate'],'42501')
        self.assertEqual(report['failure']['failed_operation'],'set_role')
        self.assertNotIn('SYNTHETIC_SECRET',json.dumps(report))

    def test_no_verify_full_or_wrong_login_never_connects(self):
        for dsn in (DSN.replace('verify-full','require'),DSN.replace('geolock_graph_login.','geolock_planner_login.')):
            connect=Mock();report={'status':'INCOMPLETE'}
            self.assertEqual(diagnose(dsn,report,connect=connect),1)
            connect.assert_not_called()

    def test_no_full_load_matrix_or_state_mutation_imports(self):
        from backend.routing.worker_service import connection_diagnostic
        text=Path(connection_diagnostic.__file__).read_text()
        self.assertNotIn('import GraphCache',text)
        self.assertNotIn('build_matrix(',text)
        self.assertNotIn('SELECT public.store_routing_matrix(',text)
