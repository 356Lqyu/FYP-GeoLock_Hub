"""Offline harness safety tests and assertions over freshly captured MCP catalogs.

No HTTP, Auth session, SQL execution, or live identity is used by these tests.
"""
from datetime import datetime, timedelta, timezone
import importlib.util
import json
from pathlib import Path
import re
import tempfile
import unittest

import rpc_harness as h

ROOT=Path(__file__).resolve().parents[4]
DEPLOYMENT=h.HERE.parent/'deployment'
spec=importlib.util.spec_from_file_location('c1_verify',DEPLOYMENT/'verify_results.py')
v=importlib.util.module_from_spec(spec); spec.loader.exec_module(v)


class SafetyTests(unittest.TestCase):
    def receipt(self,**changes):
        data=dict(project_ref=h.PROJECT,batch_b_authorized=True,run_id='a355f381-82b7-4570-b58d-6c03136a7d9c',
                  expires_at=(datetime.now(timezone.utc)+timedelta(hours=1)).isoformat(),
                  max_vehicles=5,max_routes=12,recovery_ready=True)
        data.update(changes)
        return data

    def read_receipt(self,data):
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'receipt.json'; path.write_text(json.dumps(data),encoding='utf-8')
            return h.approval(path)

    def test_approval_required(self):
        with self.assertRaises(AssertionError): self.read_receipt(self.receipt(batch_b_authorized=False))

    def test_wrong_project_refused(self):
        with self.assertRaises(AssertionError): self.read_receipt(self.receipt(project_ref='other'))

    def test_expired_receipt_refused(self):
        with self.assertRaises(AssertionError): self.read_receipt(self.receipt(expires_at=(datetime.now(timezone.utc)-timedelta(seconds=1)).isoformat()))

    def test_unbounded_receipt_refused(self):
        with self.assertRaises(AssertionError): self.read_receipt(self.receipt(expires_at=(datetime.now(timezone.utc)+timedelta(days=2)).isoformat()))

    def test_fixture_budget_cannot_expand(self):
        with self.assertRaises(AssertionError): self.read_receipt(self.receipt(max_vehicles=99))

    def test_recovery_ready_required(self):
        with self.assertRaises(AssertionError): self.read_receipt(self.receipt(recovery_ready=False))

    def test_valid_receipt_loads(self):
        self.assertEqual(self.read_receipt(self.receipt())['project_ref'],h.PROJECT)

    def test_client_default_gate_closed(self):
        with self.assertRaises(AssertionError): h.Client({},'unit-test-key','unit-test-key')

    def test_origin_and_path_pinned_before_any_network(self):
        client=h.Client(self.receipt(),'unit-test-key','unit-test-key')
        for path in ('https://other.supabase.co/x','//other/x','/rest/v1/rpc/start_pickup','/rest/v1/rpc/../start_pickup','/auth/v1/admin/users'):
            with self.assertRaises(AssertionError): client.request('anon','POST',path,{})
        self.assertEqual(client.count,0)

    def test_request_budget_enforced_before_network(self):
        client=h.Client(self.receipt(),'unit-test-key','unit-test-key'); client.count=1200
        with self.assertRaises(AssertionError): client.rpc('anon','list_my_vehicles')

    def test_redirect_refused(self):
        with self.assertRaises(RuntimeError): h.NoRedirect().redirect_request(None,None,302,'',{},'https://elsewhere')

    def test_rpc_allowlist(self):
        client=h.Client(self.receipt(),'unit-test-key','unit-test-key')
        with self.assertRaises(AssertionError): client.rpc('anon','claim_listing')

    def test_nonfinite_json_refused_locally(self):
        client=h.Client(self.receipt(),'unit-test-key','unit-test-key')
        with self.assertRaises(ValueError): client.rpc('anon','register_my_vehicle',{'p_capacity_kg':float('nan')})

    def test_solver_success_not_reused_as_rpc_evidence(self):
        with self.assertRaises(AssertionError): h.expect((200,{'registration_payload':[]}))
        with self.assertRaises(AssertionError): h.expect((200,{}),'DENIED')

    def test_error_messages_checked(self):
        self.assertEqual(h.expect((400,{'message':'VEHICLE_NOT_FOUND'}),'VEHICLE_NOT_FOUND')['message'],'VEHICLE_NOT_FOUND')
        with self.assertRaises(AssertionError): h.expect((400,{'message':'wrong'}),'VEHICLE_NOT_FOUND')

    def test_synthetic_values_explicit(self):
        data=h.payload('unit-test-run')
        self.assertTrue(data['p_label'].startswith('C1TEST:'))
        self.assertFalse(data['p_available'])
        self.assertNotIn('p_ngo_user_id',data)


class LiveCatalogEvidenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.before=json.loads((DEPLOYMENT/'supervised-preflight-2026-10-24.json').read_text(encoding='utf-8'))
        cls.after=json.loads((h.HERE/'batch-a-live-catalog.json').read_text(encoding='utf-8'))
        cls.rows={x['check_id']:x['rows'] for x in cls.after['results']}

    def test_complete_32_check_comparison(self):
        self.assertEqual(v.compare(self.before,self.after,v.check_package()),[])

    def test_712_exact_protected_fingerprints(self):
        original=next(x['rows'] for x in self.before['results'] if x['check_id']=='L01_protected_object_fingerprints')
        actual=self.rows['L01_protected_object_fingerprints']
        self.assertEqual(len(actual),712); self.assertEqual(original,actual)

    def test_seal_true(self):
        self.assertEqual(len(self.rows['V08_snapshot_seal']),1)
        self.assertIs(self.rows['V08_snapshot_seal'][0]['pass'],True)

    def test_zero_fleet_route_counts(self):
        self.assertTrue(all(value==0 for value in self.rows['C06_counts'][0].values()))

    def test_rpc_and_private_permissions(self):
        for name in ('V02_table_permission_assertions','V03_column_permission_assertions','V04_rpc_assertions','V05_private_permissions','V11_private_function_assertions'):
            self.assertTrue(self.rows[name]); self.assertTrue(all(row['pass'] is True for row in self.rows[name]))

    def test_integrity_and_triggers(self):
        self.assertEqual(self.rows['V07_integrity_rows'],[])
        self.assertTrue(all(row['pass'] is True for row in self.rows['V09_trigger_assertions']))

    def test_all_14_installed_function_bodies_match_reviewed_migration(self):
        sql=(h.HERE.parent/'proposed_migration_v2.sql').read_text(encoding='utf-8')
        rows=self.rows['C11_fleet_objects']
        self.assertEqual(len(rows),14)
        for row in rows:
            name=re.escape(row['nspname']+'.'+row['proname'])
            expected=re.search(r'CREATE OR REPLACE FUNCTION '+name+r'\(.*?AS \$f\$(.*?)\$f\$;',sql,re.S).group(1)
            actual=re.search(r'AS \$function\$(.*?)\$function\$',row['definition'],re.S).group(1).replace('\r\n','\n')
            self.assertEqual(actual,expected,row['proname'])


if __name__=='__main__': unittest.main(verbosity=2)
