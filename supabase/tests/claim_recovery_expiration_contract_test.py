"""Offline source contracts only; no database connection."""
from pathlib import Path
import hashlib
import re
import unittest

from claim_recovery_reconciliation_audit_contract_test import body

ROOT = Path(__file__).resolve().parents[2]
BASE = (ROOT / 'supabase/migrations/20261027_persisted_donation_lifecycle.sql').read_text(encoding='utf-8')
SQL = (ROOT / 'supabase/migrations/20261029_fix_claim_recovery_listing_expiration_race.sql').read_text(encoding='utf-8')
OLD = body(BASE, 'recover_expired_claims')
NEW = body(SQL, 'recover_expired_claims')
EXPIRY = """    -- An expired listing cannot be safely reopened; retain custody for reconciliation.
    v_uncertain:=v_uncertain
      or (v_l.listing_expires_at is not null and v_l.listing_expires_at<=clock_timestamp());
"""
LOCKS = """    if v_l.listing_id is not null then
      v_uncertain:=not public.geolock_lock_listing_donations(v_l.listing_id,array['CLAIMED']) or v_uncertain;
    end if;
"""


class RecoveryExpirationContracts(unittest.TestCase):
    def test_only_post_lock_expiry_and_fail_closed_branch_change(self):
        expected = OLD.replace(EXPIRY + LOCKS, LOCKS +
            '    -- Decide listing expiry only after acquiring the donation/batch lock set.\n' + EXPIRY)
        anchor = "          case when v_l.source_type='DIRECT_DONATION' then 'AVAILABLE' else 'BATCHED' end);\n"
        expected = expected.replace(anchor + '      end if;', anchor +
            "      else\n        raise exception 'RECOVERY_LISTING_REOPEN_PRECONDITION_CHANGED';\n      end if;")
        self.assertEqual(NEW, expected)
        self.assertEqual(NEW.count('RECOVERY_LISTING_REOPEN_PRECONDITION_CHANGED'), 1)
        self.assertLess(NEW.index('geolock_lock_listing_donations'), NEW.index('v_l.listing_expires_at<=clock_timestamp()'))
        self.assertLess(NEW.index('v_l.listing_expires_at<=clock_timestamp()'), NEW.index("set lease_status='RELEASED'"))

    def test_audit_statements_are_identical(self):
        for marker in ('    select c.config_version', '    insert into public.audit_events'):
            self.assertEqual(OLD[OLD.index(marker):], NEW[NEW.index(marker):])

    def test_signature_security_and_trusted_scheduler_guard_preserved(self):
        header = re.search(r'(CREATE OR REPLACE FUNCTION public\.recover_expired_claims.*?)(?=AS \$function\$)', SQL, re.S).group(1)
        old_header = re.search(r'(CREATE OR REPLACE FUNCTION public\.recover_expired_claims.*?)(?=AS \$function\$)', BASE, re.S).group(1)
        self.assertEqual(header, old_header)
        self.assertIn("auth.role() is distinct from 'service_role' and session_user <> 'postgres'", NEW)
        self.assertNotRegex(SQL.lower(), r'\b(grant|revoke)\s+(execute|all)\b|alter function|cron\.(schedule|alter_job|unschedule)')

    def test_atomic_migration_drift_guards_and_no_unrelated_replacements(self):
        self.assertEqual(re.findall(r'CREATE OR REPLACE FUNCTION public\.(\w+)', SQL), ['recover_expired_claims'])
        for routine, marker in ((OLD, 'be8361aeb5989fa694c6760a48d4c3f3'), (NEW, '50110ff20115c4e5d46380e8e3f8b94c')):
            self.assertEqual(hashlib.md5(routine.encode()).hexdigest(), marker)
            self.assertIn(marker, SQL)
        self.assertIn('RECOVERY_SOURCE_REVIEW_REQUIRED', SQL)
        self.assertIn('RECOVERY_HEADER_OR_ACL_REVIEW_REQUIRED', SQL)
        self.assertIn('RECOVERY_REPLACEMENT_POSTCONDITION_FAILED', SQL)
        self.assertTrue(SQL.rstrip().endswith('commit;'))
        self.assertNotIn('temporary table', SQL.lower())
        for tag in ('$preflight$', '$function$', '$postflight$'):
            self.assertEqual(SQL.count(tag), 2)

    def test_locking_bounds_reconciliation_and_batch_atomicity_preserved(self):
        for required in ('for update of c skip locked', 'limit greatest(1,least(coalesce(p_limit,100),1000))',
                         "v_t.task_status<>'CONFIRMED'", 'public.active_task_route_assignments',
                         'public.pickup_route_stops', 'PICKUP_IN_PROGRESS', 'COLLECTED',
                         "hi.inventory_status<>'BATCHED'", 'on conflict(claim_id) do nothing',
                         'EXPIRED_SAFE_RELEASE', 'HANDOVER_OR_ROUTE_ACTIVITY_UNCERTAIN'):
            self.assertIn(required, NEW)
        self.assertNotIn('exception when', NEW.lower())
        self.assertNotIn('savepoint', NEW.lower())
        self.assertNotIn('claim_lease_minutes', SQL)


if __name__ == '__main__':
    unittest.main()
