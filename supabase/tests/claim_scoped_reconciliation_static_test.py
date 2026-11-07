"""Static contracts for the local claim-scoped reconciliation migration."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
MIGRATION = ROOT / 'docs/stage8/stage-a/forward-migrations/20261109_claim_scoped_reconciliation.sql'


class ClaimScopedContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sql = MIGRATION.read_text(encoding='utf-8')
        cls.repo = (ROOT / 'frontend/geolock_hub_app/lib/routing/route_resolution_repository.dart').read_text(encoding='utf-8')
        cls.route_ui = (ROOT / 'frontend/geolock_hub_app/lib/routing/route_resolution_page.dart').read_text(encoding='utf-8')
        cls.ngo_ui = (ROOT / 'frontend/geolock_hub_app/lib/routing/ngo_routes_page.dart').read_text(encoding='utf-8')
        cls.donor_ui = (ROOT / 'frontend/geolock_hub_app/lib/donation_pages.dart').read_text(encoding='utf-8')

    def test_migration_is_forward_only_transactional_and_requires_stage8_baseline(self):
        self.assertTrue(self.sql.lstrip().startswith('-- GeoLock Hub forward migration'))
        self.assertEqual(len(re.findall(r'^BEGIN;', self.sql, re.M)), 1)
        self.assertEqual(len(re.findall(r'^COMMIT;', self.sql, re.M)), 1)
        self.assertIn('CLAIM_SCOPED_ROUTING_BASELINE_MISSING', self.sql)
        self.assertIn('PICKUP_TASK_AUTHORITY_GUARD_MISSING', self.sql)
        self.assertNotRegex(self.sql, r'(?i)\b(DROP TABLE|TRUNCATE)\b')
        self.assertNotRegex(self.sql, r'(?i)DELETE\s+FROM\s+(?:resolution_private|public\.claim_reconciliation)_')

    def test_route_assignment_is_not_custody_and_route_stop_is_guarded(self):
        self.assertIn('release_expired_unstarted_stop', self.sql)
        self.assertIn('consumed_at IS NOT NULL OR i.collected_at IS NOT NULL', self.sql)
        self.assertIn("v_t.task_status NOT IN ('CONFIRMED','PLANNED')", self.sql)
        self.assertIn('RECOVERY_SAFE_ROUTE_RELEASE_SOURCE_DRIFT', self.sql)
        self.assertIn('deferred_release_permits', self.sql)
        self.assertIn('check_remaining(p_route,next_id,clock_timestamp())', self.sql)
        self.assertIn("EXCEPTION WHEN SQLSTATE 'P0001'", self.sql)
        helper = self.sql.split('CREATE OR REPLACE FUNCTION routing_private.release_expired_unstarted_stop(', 1)[1].split('END $$;', 1)[0]
        self.assertIn('AND x.task_id<>p_task', helper)
        self.assertIn("t.task_status='DISPATCHED'", helper)
        self.assertIn("t.task_status='PLANNED' AND c.claim_status='ACTIVE'", helper)
        self.assertIn("le.lease_status='ACTIVE' AND le.expires_at<=clock_timestamp()", helper)
        self.assertIn('x.task_id<>p_task', helper)
        self.assertIn('check_remaining will revalidate', helper)
        self.assertIn('INSERT INTO routing_private.deferred_stops', helper)
        feasibility = helper[helper.index('IF next_id IS NULL OR EXISTS('):helper.index('INSERT INTO routing_private.deferred_release_permits')]
        self.assertLess(feasibility.index('INSERT INTO routing_private.deferred_stops'), feasibility.index('PERFORM routing_private.check_remaining'))
        self.assertIn("'REMAINING_ROUTE_INFEASIBLE'", feasibility)
        self.assertIn('IF SQLERRM NOT IN (', feasibility)
        self.assertIn(') THEN RAISE; END IF;', feasibility)
        self.assertEqual(feasibility.count("EXCEPTION WHEN SQLSTATE 'P0001'"), 1)
        self.assertNotRegex(helper, r'(?is)END IF;\s*EXCEPTION WHEN SQLSTATE')
        self.assertNotIn('EXCEPTION WHEN OTHERS THEN\n RETURN false;', self.sql)

    def test_source_patches_normalize_crlf_without_dropping_drift_guards(self):
        self.assertEqual(self.sql.count("src:=replace(src,chr(13)||chr(10),chr(10));"), 4)
        self.assertIn("""old:='for update of c skip locked'
   || chr(10)
   || repeat(chr(32),4)
   || 'limit greatest(1,least(coalesce(p_limit,100),1000))';""", self.sql)
        self.assertIn("""old:='select c.* into v_c from public.donation_claims c where c.claim_id=v_rec.claim_id;'
  || chr(10)
  || repeat(chr(32),4)
  || '-- Current row lock was obtained on claim above; follow V3 writer order.';""", self.sql)
        self.assertIn("repeat(chr(32),6)", self.sql)
        self.assertIn("repeat(chr(32),8)", self.sql)
        self.assertIn("repeat(chr(32),10)", self.sql)
        self.assertIn("|| 'where s.task_id=v_t.task_id)';", self.sql)
        old_literals = re.findall(r"(?ms)^\s*old:=\$old\$(.*?)\$old\$;", self.sql)
        self.assertFalse(
            any('\n' in old for old in old_literals),
            'multiline old anchors must construct line breaks and indentation explicitly',
        )
        for guard in (
            'RECOVERY_CANDIDATE_LOCK_SOURCE_DRIFT',
            'RECOVERY_ROUTE_LOCK_SOURCE_DRIFT',
            'RECOVERY_ROUTE_ACTIVITY_SOURCE_DRIFT',
            'RECOVERY_SAFE_ROUTE_RELEASE_SOURCE_DRIFT',
            'RECOVERY_ROUTE_RELEASE_FINALIZE_SOURCE_DRIFT',
            'RECOVERY_LISTING_EXPIRY_SOURCE_DRIFT',
            'RECOVERY_REASON_SOURCE_DRIFT',
            'RECOVERY_LOCAL_DECLARATION_SOURCE_DRIFT',
            'DEFER_OTHER_DISPATCH_SOURCE_DRIFT',
            'ROUTE_READ_DEFER_GUARD_SOURCE_DRIFT',
            'LEGACY_ROUTE_REPORT_SOURCE_DRIFT',
        ):
            self.assertIn(guard, self.sql)
        self.assertIn('CRLF', self.sql)
        self.assertEqual(
            self.sql.count("position(old IN src)=0 OR (length(src)-length(replace(src,old,'')))/length(old)<>1"),
            11,
            'every ordinary source replacement must require exactly one anchor',
        )
        self.assertNotRegex(self.sql, r"IF position\(old IN src\)=0 THEN RAISE EXCEPTION")

    def test_dispatched_uncertainty_and_legacy_case_holds_are_preserved(self):
        self.assertIn('MANUAL_REVIEW', self.sql)
        self.assertIn('resolution_private.cases', self.sql)
        self.assertIn('NEW_ROUTE_INTERRUPTION_REPORTS_RETIRED', self.sql)
        self.assertIn('public.submit_claim_reconciliation', self.sql)
        self.assertNotIn('CREATE OR REPLACE FUNCTION public.close_my_resolved_route', self.sql)

    def test_ui_uses_claim_flow_and_keeps_legacy_case_reader(self):
        self.assertNotIn("'Report cannot continue'", self.route_ui)
        self.assertNotIn("'Route interruption'", self.ngo_ui)
        self.assertIn('Open legacy route case', self.donor_ui)
        self.assertIn('submit_claim_reconciliation', self.donor_ui)
        self.assertIn('submit_route_resolution_evidence', self.repo)
        self.assertIn('report_my_route_interruption', self.repo)  # receipt compatibility only


if __name__ == '__main__':
    unittest.main(verbosity=2)
