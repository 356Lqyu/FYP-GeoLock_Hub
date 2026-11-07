"""Synthetic/offline checks only. Never invokes a PostgreSQL connection."""
import copy
import contextlib
import hashlib
import io
import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('backup_current_verify', HERE/'backup_current_verify.py')
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)


class CurrentBackupTests(unittest.TestCase):
    def setUp(self):
        self.inventory = {'capture_purpose':'PRE_AUTOMATIC_DEPARTURE_CURRENT_DEV',
                          'functions':[], 'recovery_records':{t:[] for t in verifier.TABLES}}
        self.inventory['recovery_records']['policies'] = [{'policy_id':'dummy-policy', 'body':{'mandatory':False,'solver':{'seed':42}},'digest':'dummy-digest'}]
        body='\nBEGIN\n RETURN 1;\nEND;\n'
        self.inventory['functions']=[{'name':'public.example','signature':'public.example()', 'body_md5':hashlib.md5(body.encode()).hexdigest()}]
        self.schema='CREATE FUNCTION public.example() RETURNS integer\nLANGUAGE plpgsql AS $function$'+body+'$function$;'
        self.data=self.render(self.inventory['recovery_records'])

    @staticmethod
    def render(records):
        lines=[]
        for table,rows in records.items():
            key=verifier.KEYS[table]
            columns=list(rows[0]) if rows else (list(key) if isinstance(key,tuple) else [key])
            lines.append('COPY routing_private.'+table+' ('+', '.join(columns)+') FROM stdin;')
            for row in rows:
                values=[]
                for key in columns:
                    value=row[key]
                    if value is None: values.append(r'\N');continue
                    value=json.dumps(value,ensure_ascii=False) if isinstance(value,(dict,list)) else str(value)
                    values.append(value.replace('\\','\\\\').replace('\t',r'\t').replace('\n',r'\n').replace('\r',r'\r'))
                lines.append('\t'.join(values))
            lines.append(r'\.')
        return '\n'.join(lines)+'\n'

    def test_complete_synthetic_capture(self):
        result=verifier.verify(self.inventory,self.schema,self.data)
        self.assertEqual(result['function_body_matches'],1)
        self.assertEqual(result['restore_validation'],'NOT VERIFIED')

    def test_pre_claim_scoped_purpose_requires_all_route_metadata_sections(self):
        inventory=copy.deepcopy(self.inventory)
        inventory['capture_purpose']='PRE_CLAIM_SCOPED_RECONCILIATION_CURRENT_DEV'
        for table in verifier.ROUTE_TABLES:
            inventory['recovery_records'].setdefault(table,[])
        result=verifier.verify(inventory,self.schema,self.render(inventory['recovery_records']),
                               purpose='PRE_CLAIM_SCOPED_RECONCILIATION_CURRENT_DEV')
        self.assertEqual(set(result['routing_record_counts']),set(verifier.ROUTE_TABLES))
        with self.assertRaises(ValueError):
            verifier.verify(self.inventory,self.schema,self.data,
                            purpose='PRE_CLAIM_SCOPED_RECONCILIATION_CURRENT_DEV')

    def test_original_json_and_unicode_survive_copy(self):
        body={'mandatory':False,'address':'路线 café', 'note':'tabs\tand\\slashes\nand quotes "'}
        self.inventory['recovery_records']['policies'][0]['body']=body
        result=verifier.verify(self.inventory,self.schema,self.render(self.inventory['recovery_records']))
        self.assertEqual(result['routing_record_counts']['policies'],1)

    def test_simplified_reconciliation_capture_requires_all_nine_sections(self):
        inventory=copy.deepcopy(self.inventory)
        purpose='PRE_SIMPLIFIED_RECONCILIATION_CURRENT_DEV'
        inventory['capture_purpose']=purpose
        for table in verifier.ROUTE_TABLES:
            inventory['recovery_records'].setdefault(table,[])
        result=verifier.verify(inventory,self.schema,self.render(inventory['recovery_records']),purpose=purpose)
        self.assertEqual(set(result['routing_record_counts']),set(verifier.ROUTE_TABLES))
        self.assertEqual(result['restore_validation'],'NOT VERIFIED')
        del inventory['recovery_records']['items']
        with self.assertRaises(ValueError):
            verifier.verify(inventory,self.schema,self.render(inventory['recovery_records']),purpose=purpose)

    def test_changed_policy_fails(self):
        with self.assertRaises(ValueError): verifier.verify(self.inventory,self.schema,self.data.replace('false','true'))

    def test_function_body_drift_fails(self):
        with self.assertRaises(ValueError): verifier.verify(self.inventory,self.schema.replace('RETURN 1','RETURN 2'),self.data)

    def test_missing_section_fails(self):
        with self.assertRaises(ValueError): verifier.verify(self.inventory,self.schema,self.data[:self.data.index('COPY routing_private.validations')])

    def test_duplicate_section_fails(self):
        with self.assertRaises(ValueError): verifier.copy_tables(self.data+self.data)

    def test_missing_row_fails(self):
        records=copy.deepcopy(self.inventory['recovery_records']);records['policies']=[]
        with self.assertRaises(ValueError): verifier.verify(self.inventory,self.schema,self.render(records))

    def test_null_and_literal_backslash_n_are_distinct(self):
        self.assertIsNone(verifier.copy_value(r'\N'))
        self.assertEqual(verifier.copy_value(r'\\N'),r'\N')

    def test_timestamp_storage_format(self):
        self.assertTrue(verifier.equal_value('2026-10-27T12:40:15.988752+00:00','2026-10-27 12:40:15.988752+00'))
        self.assertFalse(verifier.equal_value('2026-10-27T12:40:15.988752+00:00','2026-10-27 12:40:16+00'))

    def test_stale_capture_label_fails(self):
        self.inventory['capture_purpose']='PRE003'
        with self.assertRaises(ValueError): verifier.verify(self.inventory,self.schema,self.data)

    def test_archive_table_count_change_fails(self):
        row=self.inventory['recovery_records']['policies'][0]
        records=copy.deepcopy(self.inventory['recovery_records']); records['policies'].append(row)
        with self.assertRaises(ValueError): verifier.verify(self.inventory,self.schema,self.render(records))

    def test_readonly_native_arguments_and_guards_present(self):
        runner=(HERE/'backup_pre003.ps1').read_text()
        helper=(HERE/'backup_current_state.ps1').read_text()
        argv=(HERE/'backup_native_arguments.ps1').read_text()
        self.assertIn("Assert-CurrentInventory -Inventory $stage003Inventory",runner)
        self.assertLess(runner.index('Assert-CurrentInventory -Inventory $stage003Inventory'),runner.index("$stage003Phase = 'database export'"))
        self.assertIn("'--format','custom'",argv)
        self.assertIn("'--roles-only','--no-role-passwords'",argv)
        self.assertNotIn("'--dbname'",helper[helper.index('function Test-CurrentArchive'):])
        self.assertIn('SetAccessRuleProtection($true,$false)',helper)
        self.assertIn('check-ignore --quiet',helper)
        self.assertIn('FAILED / NOT A VERIFIED BACKUP',runner)
        self.assertIn('BACKUP_INVENTORY_FAILED:',runner)
        self.assertIn('failure_code=$stage003SafeFailureCode',runner)
        self.assertIn('Backup stopped: $stage003SafeFailureCode',runner)
        self.assertIn('PreClaimScopedReconciliation',runner)
        self.assertIn('PRE_CLAIM_SCOPED_RECONCILIATION_CURRENT_DEV',runner)

    def test_current_state_hashes_match_approved_later_migrations(self):
        helper=(HERE/'backup_current_state.ps1').read_text()
        self.assertIn('20261104_routing_automatic_departure.sql',helper)
        self.assertIn('20261108_per_stop_reconciliation.sql',helper)
        self.assertIn('e383a34bfadba383cf71ac07b0854a47',helper)
        self.assertIn('d2e9e87bda5611f0a4afe2013a8f9235',helper)
        self.assertNotIn('1c3c880e27da261a9a95a95730640196',helper)
        self.assertNotIn('5e6583e6092daf191eeca066f0b06ebe',helper)
        self.assertIn('BACKUP_INVENTORY_FAILED:',helper)
        for condition in ('TLS_SSL','TLS_VERSION','EXPORT_ROLE_BYPASSRLS','ROLE_CATALOG_SELECT',
                          'ROLE_MEMBERSHIP_CATALOG_SELECT','TABLE_SEQUENCE_SELECT_COVERAGE',
                          'FUNCTION_SIGNATURE_COUNT','FUNCTION_BODY_HASH'):
            self.assertIn(condition,helper)

    def test_failure_reporting_never_echoes_exception_contents(self):
        output=io.StringIO()
        with patch('sys.argv',['verify','--directory','synthetic-not-a-backup']), patch.object(Path,'read_text',side_effect=ValueError('DUMMY_SECRET_DO_NOT_PRINT')), contextlib.redirect_stdout(output):
            self.assertEqual(verifier.main(),1)
        self.assertNotIn('DUMMY_SECRET',output.getvalue())
        self.assertIn('FAILED',output.getvalue())


if __name__ == '__main__': unittest.main()
