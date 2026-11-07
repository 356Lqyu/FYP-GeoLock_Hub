"""Offline Stage 3F contracts. No database connections."""
from pathlib import Path
import hashlib
import re
import unittest

from claim_recovery_reconciliation_audit_contract_test import body

ROOT=Path(__file__).resolve().parents[2]
OLD=(ROOT/'supabase/migrations/20261029_fix_claim_recovery_listing_expiration_race.sql').read_text(encoding='utf-8')
SQL=(ROOT/'supabase/migrations/20261030_fix_claim_recovery_unresolved_reconciliation.sql').read_text(encoding='utf-8')
BEFORE=body(OLD,'recover_expired_claims')
AFTER=body(SQL,'recover_expired_claims')


class ReconciliationGuardContracts(unittest.TestCase):
    def test_only_uncertainty_predicate_changes(self):
        expected=BEFORE.replace('    v_uncertain := v_l.listing_id is null',
            "    -- Unresolved custody evidence for this claim or listing fences reopening.\n"
            "    v_uncertain := exists(select 1 from public.claim_reconciliation_cases rc\n"
            "        where (rc.claim_id=v_c.claim_id or rc.listing_id=v_l.listing_id)\n"
            "          and rc.case_status in ('OPEN','MANUAL_REVIEW'))\n"
            "      or v_l.listing_id is null")
        self.assertEqual(AFTER,expected)
        self.assertLess(AFTER.index('where t.claim_id=v_c.claim_id for update;'),AFTER.index("rc.case_status in ('OPEN','MANUAL_REVIEW')"))
        self.assertNotIn('exception when',AFTER.lower())

    def test_audits_lifecycle_expiry_and_batch_semantics_unchanged(self):
        marker='    if v_l.source_type=\'DIRECT_DONATION\' then'
        self.assertEqual(BEFORE[BEFORE.index(marker):],AFTER[AFTER.index(marker):])
        for required in ('for update of c skip locked','limit greatest(1,least(coalesce(p_limit,100),1000))',
            'RECOVERY_LISTING_REOPEN_PRECONDITION_CHANGED','on conflict(claim_id) do nothing',
            "'HANDOVER_OR_ROUTE_ACTIVITY_UNCERTAIN'","'EXPIRED_SAFE_RELEASE'"):
            self.assertIn(required,AFTER)

    def test_signature_security_and_owner_acl_preserved(self):
        pattern=r'(CREATE OR REPLACE FUNCTION public\.recover_expired_claims.*?)(?=AS \$function\$)'
        self.assertEqual(re.search(pattern,SQL,re.S).group(1),re.search(pattern,OLD,re.S).group(1))
        self.assertIn("auth.role() is distinct from 'service_role' and session_user <> 'postgres'",AFTER)
        outside=SQL.replace(re.search(r'CREATE OR REPLACE FUNCTION.*?\$function\$;',SQL,re.S).group(0),'')
        self.assertNotRegex(outside.lower(),r'\b(grant|revoke|alter function|update|insert into|delete from|create table|drop)\b')
        self.assertNotRegex(SQL.lower(),r'cron\.(alter_job|schedule|unschedule)\s*\(')

    def test_atomic_guards_and_expected_fingerprints(self):
        for source,expected in ((BEFORE,'50110ff20115c4e5d46380e8e3f8b94c'),(AFTER,'5ff6d8719db9681aae6f444b89dfbaee')):
            self.assertEqual(hashlib.md5(source.encode()).hexdigest(),expected)
            self.assertIn(expected,SQL)
        self.assertEqual(re.findall(r'CREATE OR REPLACE FUNCTION public\.(\w+)',SQL),['recover_expired_claims'])
        self.assertIn('PAUSED_UNUSED_RECOVERY_CRON_REQUIRED',SQL)
        self.assertIn('RECOVERY_GUARD_POSTCONDITION_FAILED',SQL)
        self.assertTrue(SQL.rstrip().endswith('COMMIT;'))
        self.assertNotRegex(SQL.lower(),r'create\s+(temp|temporary)\b')
        for tag in ('$preflight$','$function$','$postflight$'):
            self.assertEqual(SQL.count(tag),2)

    def test_previous_deployed_migration_hashes_unchanged(self):
        for name,digest in (
            ('20261027_persisted_donation_lifecycle.sql','a3a06df1cf551f6f8a92b03d85167efa0828c8f1abdd47e309d4f01d2cbfbf63'),
            ('20261028_claim_card_expiry_and_paused_recovery.sql','4e02dc1e1f34ff10e343b15ae23e0b236ff2fc8e9dcecb13ba6e32c199ee70dc'),
            ('20261029_fix_claim_recovery_listing_expiration_race.sql','064b1e4cd5b5cd38e1f77b91364af5ed99221926455d5d64ae7a4b70c1c31e7d')):
            self.assertEqual(hashlib.sha256((ROOT/'supabase/migrations'/name).read_bytes()).hexdigest(),digest)


if __name__=='__main__':
    unittest.main()
