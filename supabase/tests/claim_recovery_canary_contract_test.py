"""Stage 3G offline canary artifact checks; no database connections."""
from pathlib import Path
import re
import unittest

ROOT=Path(__file__).resolve().parents[2]/'supabase/tests'
ACT=(ROOT/'review-only/claim_recovery_canary_activation.sql').read_text(encoding='utf-8')
PAUSE=(ROOT/'review-only/claim_recovery_pause.sql').read_text(encoding='utf-8')
MON=(ROOT/'claim_recovery_canary_monitoring.sql').read_text(encoding='utf-8')
READY=(ROOT/'claim_recovery_automatic_readiness.sql').read_text(encoding='utf-8')


class CanaryContracts(unittest.TestCase):
    def test_approved_fingerprint_and_preserved_security(self):
        self.assertIn('5ff6d8719db9681aae6f444b89dfbaee',ACT)
        self.assertNotIn('805c8b8eb070dc8c3ee50d5699ed033d',ACT)
        for fragment in ("p.proowner='postgres'::regrole AND p.prosecdef",
            "search_path=pg_catalog, public, extensions, pg_temp",
            "{postgres=X/postgres,service_role=X/postgres}","p_limit integer DEFAULT 100"):
            self.assertIn(fragment,ACT)

    def test_exact_canary_configuration_and_no_direct_recovery_call(self):
        self.assertIn("PERFORM cron.alter_job(3,schedule := '* * * * *'",ACT)
        self.assertIn("set lock_timeout = ''5s''; set statement_timeout = ''50s''; select public.recover_expired_claims(1);",ACT)
        self.assertNotRegex(ACT,r'(?im)^\s*(perform|select) public\.recover_expired_claims\(')
        self.assertNotRegex(ACT,r'(?i)cron\.(schedule|unschedule)\(')

    def test_noop_and_supervision_guards(self):
        for fragment in ('INITIAL_NOOP_CANARY_REQUIRES_EMPTY_BACKLOG',
            'INITIAL_CANARY_REQUIRES_NO_UNRESOLVED_CASES','COORDINATION_REVIEW_REQUIRED',
            'RECENT_HEALTHY_ELIGIBILITY_WORKERS_REQUIRED','CONCURRENT_TRANSACTION_REVIEW_REQUIRED',
            'CANARY_CRON_POSTCONDITION_FAILED','v_eligibility_jobs'):
            self.assertIn(fragment,ACT)
        self.assertIn('Never leave this canary unattended',ACT)

    def test_scripts_atomic_and_pause_is_targeted(self):
        for sql in (ACT,PAUSE):
            self.assertRegex(sql,r'(?m)^BEGIN;')
            self.assertRegex(sql,r'(?m)^COMMIT;')
            self.assertNotRegex(sql,r'(?i)create\s+(temp|temporary)\b')
        self.assertIn('PERFORM cron.alter_job(3,active := false)',PAUSE)
        self.assertNotRegex(PAUSE,r'pg_(cancel|terminate)_backend\s*\(')

    def test_monitoring_and_readiness_select_only(self):
        for sql in (MON,READY):
            # Remove comments and SQL literals before checking executable tokens.
            code=re.sub(r'--[^\n]*','',sql)
            code=re.sub(r"'(?:''|[^'])*'", "''", code)
            self.assertNotRegex(code,r'(?i)\b(insert|update|delete|create|alter|drop|truncate|call|do|grant|revoke)\b')
            self.assertNotRegex(code,r'(?i)recover_expired_claims\s*\(')
        self.assertIn('rc.listing_id=l.listing_id',READY)
        self.assertIn('x.lease_id=a.lease_id',MON)
        self.assertIn('NOT the number of recovered claims',MON)


if __name__=='__main__':
    unittest.main()
