"""Offline synthetic checks only: no credentials, DB driver or network."""
import copy
import hashlib
import importlib.util
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
PREP = ROOT / 'docs/stage8/stage-a/deployment-preparation'
spec = importlib.util.spec_from_file_location('backup_verify', PREP / 'backup_current_verify.py')
v = importlib.util.module_from_spec(spec)
spec.loader.exec_module(v)


class ArchiveScope(unittest.TestCase):
    def fixture(self, purpose=v.PURPOSES[1]):
        tables = v.ROUTE_TABLES if purpose == v.PURPOSES[1] else v.TABLES
        records, sections = {}, []
        for table in tables:
            keys = v.KEYS[table]
            keys = keys if isinstance(keys, tuple) else (keys,)
            row = {key: key + '-synthetic' for key in keys}
            row['body' if table == 'policies' else 'digest'] = '{}'
            records[table] = [row]
            sections.append('COPY routing_private.' + table + ' (' + ', '.join(row) + ') FROM stdin;\n'
                            + '\t'.join(row.values()) + '\n\\.\n')
        body = ' SELECT 1; '
        inventory = dict(capture_purpose=purpose, recovery_records=records, functions=[dict(
            name='public.synthetic', signature='public.synthetic()',
            body_md5=hashlib.md5(body.encode()).hexdigest())])
        return inventory, 'CREATE FUNCTION public.synthetic() RETURNS integer LANGUAGE sql AS $$' + body + '$$;', ''.join(sections)

    def test_old_six_table_mode(self):
        args = self.fixture(v.PURPOSES[0])
        self.assertEqual(len(v.verify(*args)['routing_record_counts']), 6)

    def test_new_nine_table_mode(self):
        self.assertEqual(len(v.verify(*self.fixture(), purpose=v.PURPOSES[1])['routing_record_counts']), 9)

    def test_wrong_purpose(self):
        with self.assertRaises(ValueError): v.verify(*self.fixture())

    def test_missing_copy(self):
        inv, schema, data = self.fixture()
        with self.assertRaises(ValueError): v.verify(inv, schema, data.split('COPY routing_private.requests')[0], v.PURPOSES[1])

    def test_duplicate_composite_key(self):
        inv, schema, data = self.fixture()
        row = 'route_id-synthetic\ttask_id-synthetic\t{}\n'
        data = data.replace(row, row + row)
        with self.assertRaises(ValueError): v.verify(inv, schema, data, v.PURPOSES[1])

    def test_policy_body_mismatch(self):
        inv, schema, data = self.fixture()
        inv['recovery_records']['policies'][0]['body'] = '{"changed":true}'
        with self.assertRaises(ValueError): v.verify(inv, schema, data, v.PURPOSES[1])

    def test_function_body_mismatch(self):
        inv, schema, data = self.fixture()
        with self.assertRaises(ValueError): v.verify(inv, schema.replace('SELECT 1', 'SELECT 2'), data, v.PURPOSES[1])

    def test_truncated_copy(self):
        inv, schema, data = self.fixture()
        with self.assertRaises(ValueError): v.verify(inv, schema, data[:-3], v.PURPOSES[1])


class ReadonlyAddendum(unittest.TestCase):
    def test_command_disclosure_whitelist(self):
        sql = (ROOT / 'docs/stage8/functional-routing/route_resolution_dev_addendum.readonly.sql').read_text()
        body = sql.split('$pattern$')[1]
        # Synthetic disclosure cases only; this is not a PostgreSQL execution test.
        supported = lambda s: bool(re.fullmatch(body, s, re.I) or re.fullmatch(r'\s*begin\s*;' + body + r'commit\s*;?\s*', s, re.I))
        for cmd in ['SELECT public.recover_expired_claims(1);',
                    "SET lock_timeout='2s'; SET statement_timeout='30s'; SELECT public.recover_expired_claims(1);",
                    "BEGIN; SET LOCAL lock_timeout='2s'; SELECT public.recover_expired_claims(); COMMIT;"]:
            self.assertTrue(supported(cmd))
        for cmd in ['SELECT public.recover_expired_claims(1); DELETE FROM public.claims;',
                    'SELECT private_secret;', 'BEGIN; SELECT public.recover_expired_claims(1);']:
            self.assertFalse(supported(cmd))

    def test_bounded_readonly_script(self):
        sql = (ROOT / 'docs/stage8/functional-routing/route_resolution_dev_addendum.readonly.sql').read_text()
        self.assertIn('REPEATABLE READ READ ONLY', sql)
        self.assertTrue(sql.strip().endswith('ROLLBACK;'))
        self.assertIn("lower(split_part(setting,'=',1))='timezone'", sql)
        self.assertIn('LIMIT 3', sql)
        self.assertNotIn("current_setting('default_transaction_read_only')='on'", sql)

    def test_pinned_baseline(self):
        import json
        b = json.loads((PREP / 'route_resolution_backup_baseline.json').read_text())
        self.assertEqual(len(b['functions']), 143)
        migration = ROOT / 'docs/stage8/stage-a/forward-migrations/20261106_route_interruption_resolution.sql'
        self.assertEqual(hashlib.sha256(migration.read_bytes()).hexdigest(), b['migration_sha256'])


if __name__ == '__main__': unittest.main()
