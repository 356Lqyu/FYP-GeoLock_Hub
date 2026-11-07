"""Static package checks complement actual isolated PostgreSQL execution."""
from pathlib import Path
import importlib.util
import json
import unittest

ROOT=Path(__file__).resolve().parents[4]
HERE=ROOT/'docs/stage8/integration'


class PackageTests(unittest.TestCase):
    def test_manifest_matches_and_c1_is_unchanged(self):
        spec=importlib.util.spec_from_file_location('review_package',HERE/'review_package.py')
        module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        self.assertEqual(module.build_manifest(),json.loads((HERE/'package-manifest.json').read_text()))

    def test_only_three_existing_public_functions_are_replaced(self):
        import re
        sql='\n'.join(p.read_text() for p in HERE.glob('00*.sql'))
        self.assertEqual(set(re.findall(r'CREATE OR REPLACE FUNCTION public\.(\w+)',sql)),{'start_pickup','complete_pickup','assign_task_to_route'})

    def test_permit_is_internal_not_a_caller_guc(self):
        sql=(HERE/'003_pickup_enforcement_proposal.sql').read_text()
        self.assertIn('dispatch_xid=pg_current_xact_id()',sql)
        self.assertNotIn('set_config(',sql)
        self.assertIn('LOCK TABLE public.pickup_tasks IN SHARE ROW EXCLUSIVE MODE',sql)

    def test_publication_cannot_activate_before_cutover(self):
        self.assertIn('DISPATCH_CUTOVER_REQUIRED_BEFORE_AUTHORIZATION',(HERE/'002_publication_proposal.sql').read_text())
