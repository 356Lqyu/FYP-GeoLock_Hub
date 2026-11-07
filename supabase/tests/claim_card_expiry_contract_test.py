"""Offline source contracts; no database/network access."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
MIGRATION = ROOT / 'supabase/migrations/20261028_claim_card_expiry_and_paused_recovery.sql'
SQL = MIGRATION.read_text(encoding='utf-8')
BODY = SQL.split('as $claim_cards_v2$')[1].split('$claim_cards_v2$;')[0]
CRON = SQL.split('do $recovery_cron$')[1].split('$recovery_cron$;')[0]


class ClaimCardExpiryContracts(unittest.TestCase):
    def test_versioned_addition_does_not_replace_existing_functions(self):
        self.assertEqual(re.findall(r'create function public\.(\w+)', SQL, re.I),
                         ['get_my_claim_cards_v2'])
        self.assertNotRegex(SQL.lower(), r'create or replace|drop function|alter table|create trigger')
        self.assertNotRegex(SQL.lower(), r'(update|insert into|delete from) public\.')
        self.assertNotIn('perform public.recover_expired_claims', SQL.lower())

    def test_original_card_contract_and_security_are_delegated(self):
        for column in ('claim_id uuid', 'listing_id uuid', 'claim_status text',
                       'claimed_at timestamptz', 'lease_id uuid', 'lease_status text',
                       'lease_expires_at timestamptz', 'task_status text',
                       'source_type text', 'listing_weight_kg numeric',
                       'title text', 'primary_image_path text'):
            self.assertIn(column, SQL)
        self.assertIn('from public.get_my_claim_cards() c', BODY)
        self.assertIn('order by c.claimed_at desc', BODY)
        self.assertIn('auth.uid() is null', BODY)
        self.assertIn('n.user_id=auth.uid() and n.active_flag', BODY)
        self.assertIn('security definer', SQL)
        self.assertIn("set search_path to 'pg_catalog', 'public', 'pg_temp'", SQL)
        self.assertIn('owner to postgres', SQL)
        self.assertIn('from public,anon,authenticated,service_role', SQL)
        self.assertIn('to authenticated,service_role;', SQL)
        self.assertIn('CLAIM_CARDS_V2_UNEXPECTED_EXECUTE_ACL', SQL)

    def test_authoritative_time_and_nonterminal_expiry_are_separate(self):
        self.assertEqual(BODY.count('statement_timestamp()'), 1)
        self.assertIn('v_now constant timestamptz := statement_timestamp()', BODY)
        self.assertIn('c.lease_expires_at <= v_now', BODY)
        self.assertIn("c.claim_status='ACTIVE' and c.lease_status='ACTIVE'", BODY)
        self.assertIn('and c.lease_expires_at <= v_now,false)', BODY)
        self.assertNotIn('clock_timestamp', BODY)
        self.assertNotRegex(BODY.lower(), r'\b(update|insert|delete|perform|execute)\b')

    def test_recovery_job_is_bounded_protected_and_paused(self):
        self.assertIn("current_user <> 'postgres' or session_user <> 'postgres'", SQL)
        self.assertIn('claim_lease_minutes=360', SQL)
        self.assertIn('RECOVERY_MUST_REMAIN_PROTECTED', SQL)
        self.assertIn("v_schedule constant text := '* * * * *'", CRON)
        self.assertIn('public.recover_expired_claims(100)', CRON)
        self.assertIn("lock_timeout = ''5s''", CRON)
        self.assertIn("statement_timeout = ''50s''", CRON)
        self.assertIn('cron.alter_job(v_job_id,active := false)', CRON)
        self.assertNotIn('active := true', SQL)
        self.assertIn("v_job.username is distinct from 'postgres'", CRON)
        self.assertIn('v_job.database is distinct from current_database()', CRON)

    def test_duplicate_and_mismatched_jobs_fail_closed(self):
        for marker in ('OTHER_CLAIM_RECOVERY_JOB_REVIEW_REQUIRED',
                       'DUPLICATE_CLAIM_RECOVERY_JOBS',
                       'EXISTING_CLAIM_RECOVERY_JOB_MISMATCH',
                       'CLAIM_RECOVERY_JOB_POSTCONDITION_FAILED'):
            self.assertIn(marker, CRON)
        self.assertIn("j.command ~* '\\mrecover_expired_claims\\M'", CRON)
        self.assertNotIn('cron.unschedule', SQL)
        self.assertNotIn('exception when', SQL.lower())
        self.assertNotIn('eligibility-refresh', SQL)

    def test_atomic_complete_artifact_without_temporary_acl_relation(self):
        self.assertRegex(SQL, r'(?m)^begin;$')
        self.assertTrue(SQL.rstrip().endswith('commit;'))
        for tag in ('$preflight$', '$claim_cards_v2$', '$rpc_acl$', '$recovery_cron$'):
            self.assertEqual(SQL.count(tag), 2, tag)
        self.assertNotIn('temporary table', SQL.lower())
        self.assertIn("notify pgrst, 'reload schema';", SQL)


if __name__ == '__main__':
    unittest.main()
