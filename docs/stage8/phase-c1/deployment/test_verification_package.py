"""Offline package/comparator tests ONLY. No SQL execution, migration or network.

The synthetic postflight fixture tests comparison logic, not actual deployment.
"""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import unittest

HERE=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('verification',HERE/'verify_results.py')
v=importlib.util.module_from_spec(spec); spec.loader.exec_module(v)


def synthetic_postflight(before):
    doc=copy.deepcopy(before); doc['phase']='postflight'
    data={r['check_id']:r['rows'] for r in doc['results']}
    additions=[('vehicle_type','text',False),('fixed_cost_rm','numeric',False),('distance_cost_rm_per_km','numeric',False),
      ('max_route_duration_min','numeric',False),('available_for_planning','boolean',True),('vehicle_version','bigint',True),
      ('updated_at','timestamp with time zone',True),('registration_request_id','uuid',False),('registration_payload','jsonb',False)]
    for name,kind,required in additions:
        data['C02_columns'].append({'attname':name,'data_type':kind,'attnotnull':required,'default_expression':None,'attacl':None})
    for name in ['vehicles_c1_fields','vehicles_c1_available_complete']:
        data['C03_constraints'].append({'table_name':'vehicles','conname':name,'contype':'c','convalidated':True,'definition':'SYNTHETIC COMPARATOR FIXTURE'})
    for kind,table,name in [('index','vehicles','vehicles_c1_registration_request'),('index','vehicles','vehicles_c1_owner_active'),
      ('index','pickup_routes','pickup_routes_c1_vehicle_busy'),('trigger','vehicles','zz_c1_vehicle_guard'),
      ('trigger','vehicles','c1_vehicle_audit'),('trigger','pickup_routes','c1_route_vehicle_guard')]:
        data['C12_triggers_indexes'].append({'kind':kind,'table_name':table,'name':name,'enabled':'true' if kind=='index' else 'O','definition':'SYNTHETIC'})
    for row in data['C05_effective_privileges']:
        row['allowed']=row['rolname']=='service_role' and row['privilege'] in ['SELECT','INSERT','UPDATE']
    for row in data['C04_acl_rls']:
        if row['relname']=='vehicles':
            row['acl']=[r for r in row['acl'] if r['grantee']=='postgres']+[
                {'grantee':'service_role','privilege':p,'grant_option':False} for p in ['SELECT','INSERT','UPDATE']]
        else:
            row['acl']=[r for r in row['acl'] if not(r['grantee'] in ['PUBLIC','anon','authenticated','service_role'] and r['privilege']=='TRUNCATE')]
    data['C11_fleet_objects']=[{'nspname':ns,'proname':name,
      'proacl':['postgres=X/postgres']+(['authenticated=X/postgres'] if ns=='public' else [])}
      for ns,names in [('public',v.PUBLIC),('fleet_private',v.PRIVATE)] for name in sorted(names)]
    sizes={'V01_expected_columns':9,'V02_table_permission_assertions':24,'V03_column_permission_assertions':120,
      'V04_rpc_assertions':15,'V05_private_permissions':27,'V06_route_truncate':3,'V08_snapshot_seal':1,
      'V09_trigger_assertions':4,'V10_constraint_assertions':2,'V11_private_function_assertions':9}
    for check_id,count in sizes.items(): data[check_id]=[{'pass':True} for _ in range(count)]
    data['V07_integrity_rows']=[]
    data['C20_private_schema']=[{'nspname':'fleet_private','owner':'postgres','marker':'SYNTHETIC'}]
    doc['results']=[{'check_id':k,'rows':r} for k,r in data.items()]
    return doc


class PackageTests(unittest.TestCase):
    def setUp(self):
        self.manifest=v.check_package()
        self.before=json.loads((HERE/'captured-dev-preflight.json').read_text(encoding='utf-8'))
        self.after=synthetic_postflight(self.before)

    def result(self,name):
        return next(x['rows'] for x in self.after['results'] if x['check_id']==name)

    def test_package_hashes_and_reviewed_migration(self):
        self.assertEqual(self.manifest['migration_sha256'],v.SHA)
        self.assertFalse(self.manifest['execution_authorized'])

    def test_generated_checks_only_select_statements(self):
        for name in self.manifest['files']:
            sql=(HERE/name).read_text(encoding='utf-8')
            stripped=re.sub(r"'(?:''|[^'])*'",'STRING',sql)
            stripped=re.sub(r'--[^\n]*','',stripped)
            statements=[x.strip() for x in stripped.split(';') if x.strip()]
            self.assertTrue(statements)
            for statement in statements:
                self.assertTrue(statement.upper().startswith('SELECT '),name)
                self.assertIsNone(re.search(r'\b(INSERT|UPDATE|DELETE|ALTER|DROP|CREATE|GRANT|REVOKE|TRUNCATE|DO|CALL|BEGIN|COMMIT)\b',statement,re.I),name)

    def test_preflight_capture_complete(self):
        self.assertEqual(set(v.indexed(self.before,'preflight')),set(self.manifest['preflight_checks']))
        self.assertEqual(len(v.indexed(self.before,'preflight')['L01_protected_object_fingerprints']),712)

    def test_synthetic_expected_delta_passes_comparator_only(self):
        self.assertEqual(v.compare(self.before,self.after,self.manifest),[])

    def test_missing_and_duplicate_checks_fail(self):
        self.after['results'].pop()
        self.assertTrue(v.compare(self.before,self.after,self.manifest))
        self.before['results'].append(self.before['results'][0])
        with self.assertRaises(ValueError): v.indexed(self.before,'preflight')

    def test_protected_lifecycle_drift_detected(self):
        self.result('L01_protected_object_fingerprints')[0]['sha256']='changed'
        self.assertTrue(v.compare(self.before,self.after,self.manifest))

    def test_record_loss_detected(self):
        self.result('C06_counts')[0]['vehicles']=1
        self.assertTrue(v.compare(self.before,self.after,self.manifest))

    def test_permission_and_runtime_assertion_failure_detected(self):
        self.result('V02_table_permission_assertions')[0]['pass']=False
        self.assertTrue(v.compare(self.before,self.after,self.manifest))

    def test_extra_helper_grant_detected(self):
        self.result('C11_fleet_objects')[0]['proacl'].append('anon=X/postgres')
        self.assertTrue(v.compare(self.before,self.after,self.manifest))

    def test_source_context_change_detected(self):
        self.result('C01_context')[0]['search_path']='different'
        self.assertTrue(v.compare(self.before,self.after,self.manifest))

    def test_wrong_project_rejected(self):
        self.after['project_ref']='shared-project-forbidden'
        with self.assertRaises(ValueError): v.compare(self.before,self.after,self.manifest)

    def test_invalid_index_detected(self):
        next(r for r in self.result('C12_triggers_indexes') if r['name']=='vehicles_c1_owner_active')['enabled']='false'
        self.assertTrue(v.compare(self.before,self.after,self.manifest))


if __name__=='__main__': unittest.main(verbosity=2)
