"""Local text/structure checks only. No SQL execution, subprocess or network."""
from pathlib import Path
import unittest
from isolated_psql_sqlfile import statement_heads

ROOT=Path(__file__).resolve().parents[2]
FOLDER=ROOT/'docs/stage8/integration/reconciliation'

class RecoveryProposalTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sql=(FOLDER/'exact_two_recovery_transaction_proposal.sql').read_text()

    def test_single_transaction_and_no_suppressed_errors(self):
        heads=statement_heads(self.sql)
        self.assertEqual([h[0] for h in heads],['BEGIN','SET','SET','SET','SET','LOCK','DO','COMMIT'])
        self.assertNotIn('EXCEPTION WHEN',self.sql.upper())

    def test_guards_before_only_recovery_invocation(self):
        call='n:=public.recover_expired_claims(2);'
        self.assertEqual(self.sql.count(call),1)
        for marker in ('QUEUE_NOT_EXACTLY_TWO_TARGETS','TARGET_STATE_OR_EXPIRY_CHANGED',
                       'DIRECT_CUSTODY_MISMATCH','ROUTING_REFERENCE_REQUIRES_REVIEW',
                       'RECOVERY_SOURCE_OR_SECURITY_DRIFT','HISTORICAL_STATE_CHANGED'):
            self.assertLess(self.sql.index(marker),self.sql.index(call))

    def test_queue_and_row_locks(self):
        self.assertIn('IN SHARE ROW EXCLUSIVE MODE NOWAIT',self.sql)
        self.assertIn('FOR UPDATE OF c0 NOWAIT',self.sql)
        self.assertIn('AND NOT(c0.claim_id=ANY(ids))',self.sql)
        self.assertIn('SET LOCAL statement_timeout=',self.sql)
        self.assertIn('SET LOCAL lock_timeout=',self.sql)

    def test_required_postconditions_and_history(self):
        for value in ("c0.claim_status='RELEASED'","le0.lease_status='RELEASED'", "t0.task_status='STALE'",
                      "l0.listing_status='AVAILABLE'","d0.donation_status='AVAILABLE'",
                      'historical_before IS DISTINCT FROM historical_after','RECOVERY_AUDIT_MISMATCH'):
            self.assertIn(value,self.sql)

    def test_no_direct_data_or_schema_edits(self):
        # DO body is deliberately not executed; inspect line-leading SQL mutations too.
        import re
        self.assertIsNone(re.search(r'^\s*(INSERT|UPDATE|DELETE|TRUNCATE|CREATE|ALTER|DROP|GRANT|REVOKE)\b',self.sql,re.M|re.I))

    def test_custody_helper_audit_events_preserved(self):
        self.assertIn("e->>'event_type'='DONATION_STATUS_CHANGED'",self.sql)
        self.assertIn("e->>'event_type'='LEASE_RECOVERY'",self.sql)
        self.assertIn('jsonb_array_length(new_audits)<>4',self.sql)
        self.assertIn('UNEXPECTED_POST_RECOVERY_ROUTING_REFERENCE',self.sql)

    def test_audit_history_streamed_and_new_payloads_bounded(self):
        self.assertNotIn('old_audits',self.sql)
        self.assertIn('audit_digest_before:=sha256(',self.sql)
        self.assertIn('audit_count_before<>audit_count_after',self.sql)
        self.assertIn('WHERE a.xmin<>audit_xid',self.sql)
        self.assertLess(self.sql.index("IF (SELECT count(*) FROM public.audit_events a WHERE a.xmin=audit_xid)<>4"),
                        self.sql.index('SELECT jsonb_agg(to_jsonb(a) ORDER BY a.event_id) INTO new_audits'))

    def test_listing_expiry_rechecked_in_postcondition(self):
        self.assertIn('AND (l0.listing_expires_at IS NULL OR l0.listing_expires_at>clock_timestamp())',self.sql)

    def test_postflight_select_only(self):
        text=(FOLDER/'exact_two_recovery_postflight_readonly.sql').read_text()
        self.assertTrue(all(h[0] in ('SELECT','WITH') for h in statement_heads(text)))
        self.assertNotIn('public.recover_expired_claims(',text)

if __name__=='__main__':unittest.main(verbosity=2)
