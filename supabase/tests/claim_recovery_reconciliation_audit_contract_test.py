"""Audit-only source contracts. No database connections or SQL execution."""
from pathlib import Path
import re
import unittest

from cancel_claim_audit_contract_test import AUDIT_COLUMNS, compact, split_values

ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "supabase/migrations/20261026_fix_claim_recovery_reconciliation_audit_columns.sql"
BASELINE = ROOT / "supabase/migrations/20261019_stage1_claim_recovery_and_reconciliation.sql"

def body(sql, name):
    return re.search(r"function public\." + name + r"\([^;]*?as\s+(\$\w*\$)(.*?)\1",
                     sql, re.I | re.S).group(2)

def without_comments(sql):
    return re.sub(r"--[^\n]*", "", sql)

class ClaimRecoveryAuditContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sql = PATCH.read_text()
        cls.baseline = BASELINE.read_text()
        cls.recovery = body(cls.sql, "recover_expired_claims")
        cls.recon = body(cls.sql, "submit_claim_reconciliation")

    def test_recovery_body_diff_is_only_audit_columns_values_and_details(self):
        expected = body(self.baseline, "recover_expired_claims").replace(
            "      donation_id,listing_id,\n", ""
        ).replace(
            "      v_l.donation_id,v_l.listing_id,\n", ""
        ).replace(
            "jsonb_build_object('listing_id',v_l.listing_id,'task_id',v_t.task_id)",
            "jsonb_build_object('donation_id',v_l.donation_id, "
            "'listing_id',v_l.listing_id,'task_id',v_t.task_id)",
        )
        self.assertEqual(compact(expected), compact(self.recovery))

    def test_reconciliation_body_diff_is_only_audit_projection(self):
        original = body(self.baseline, "submit_claim_reconciliation")
        self.assertEqual(original.count("lease_id,donation_id,listing_id,correlation_id"), 3)
        expected = original.replace(
            "request_id,claim_id,lease_id,donation_id,listing_id,correlation_id,",
            "request_id,claim_id,lease_id,correlation_id,",
        ).replace(
            "v_le.lease_id,v_l.donation_id,v_l.listing_id,p_request,",
            "v_le.lease_id,p_request,",
        ).replace(
            "jsonb_build_object('case_id',v_case.case_id",
            "jsonb_build_object('donation_id',v_l.donation_id, "
            "'listing_id',v_l.listing_id,'case_id',v_case.case_id",
        ).replace(
            "v_result->>'reason_code',v_result->>'outcome',",
            "v_result->>'reason_code','SUCCESS',",
        ).replace(
            "'handover_confirmed',p_handover_confirmed));",
            "'handover_confirmed',p_handover_confirmed, "
            "'reconciliation_status',v_result->>'outcome'));",
        )
        self.assertEqual(compact(without_comments(expected)),
                         compact(without_comments(self.recon)))

    def test_all_four_audit_inserts_match_live_columns_and_value_counts(self):
        for routine, expected_count in ((self.recovery, 1), (self.recon, 3)):
            inserts = re.findall(
                r"insert into public\.audit_events\((.*?)\)\s*values\((.*?)\);",
                routine, re.S | re.I,
            )
            self.assertEqual(len(inserts), expected_count)
            for columns, values in inserts:
                names = [x.strip() for x in columns.split(",")]
                entries = split_values(values)
                self.assertTrue(set(names).issubset(AUDIT_COLUMNS), names)
                self.assertEqual(len(names), len(entries))
                audit = dict(zip(names, entries))
                self.assertIn("'donation_id',v_l.donation_id", audit["details"])
                self.assertIn("'listing_id',v_l.listing_id", audit["details"])
                self.assertIn("claim_id", audit)
                self.assertIn("lease_id", audit)
                self.assertIn("correlation_id", audit)
                if routine == self.recon:
                    self.assertEqual(audit["request_id"], "p_request")
                    self.assertIn("'case_id',v_case.case_id", audit["details"])
        self.assertIn("'task_id',v_t.task_id", self.recovery)
        self.assertIn("'handover_confirmed',p_handover_confirmed", self.recon)

    def test_recovery_preserves_scheduler_guard_locking_and_safe_release(self):
        for contract in (
            "auth.role() is distinct from 'service_role' and session_user <> 'postgres'",
            "for update of c skip locked",
            "limit greatest(1,least(coalesce(p_limit,100),1000))",
            "v_t.task_status<>'CONFIRMED'",
            "public.active_task_route_assignments",
            "EXPIRED_SAFE_RELEASE",
            "HANDOVER_OR_ROUTE_ACTIVITY_UNCERTAIN",
            "on conflict(claim_id) do nothing",
            "insert into public.claim_reconciliation_cases(claim_id,listing_id,donation_id,source_type,case_status)",
        ):
            self.assertIn(contract, self.recovery)
        self.assertNotIn("exception when", self.recovery.lower())

    def test_reconciliation_preserves_participants_replay_and_lifecycle(self):
        for contract in (
            "RECONCILIATION_PARTICIPANT_ONLY", "v_role='NGO'", "v_role='DONOR'",
            "v_role='HUB_ADMIN'", "e.request_id=p_request",
            "if v_prior.response is not null then return v_prior.response",
            "v_prior.handover_confirmed<>p_handover_confirmed",
            "EVIDENCE_ALREADY_SUBMITTED", "PARTY_EVIDENCE_CONFLICT",
            "NO_HANDOVER_CONFIRMED_AFTER_PICKUP_STARTED",
            "RECONCILED_HANDOVER_CONFIRMED", "RECONCILED_NO_HANDOVER",
            "update public.claim_reconciliation_evidence set response=v_result",
        ):
            self.assertIn(contract, self.recon)
        locks = ["where c.claim_id=p_claim for update", "where le.claim_id=p_claim for update",
                 "where l.listing_id=v_c.listing_id for update", "where t.claim_id=p_claim for update"]
        positions = [self.recon.index(lock) for lock in locks]
        self.assertEqual(positions, sorted(positions))
        self.assertNotIn("exception when", self.recon.lower())

    def test_audit_outcomes_describe_operation_and_preserve_workflow_status(self):
        inserts = re.findall(
            r"insert into public\.audit_events\((.*?)\)\s*values\((.*?)\);",
            self.recon, re.S | re.I,
        )
        audits = [dict(zip([name.strip() for name in columns.split(",")],
                           split_values(values))) for columns, values in inserts]
        # Both early rejection events stay REJECTED; accepted evidence succeeds
        # even when its authoritative workflow result is awaiting/reconciliation.
        self.assertEqual([audit["outcome"] for audit in audits],
                         ["'REJECTED'", "'REJECTED'", "'SUCCESS'"])
        self.assertIn("'reconciliation_status',v_result->>'outcome'",
                      audits[-1]["details"])
        self.assertIn("'outcome','AWAITING_COUNTERPART'", self.recon)
        self.assertIn("'outcome','RECONCILIATION_REQUIRED'", self.recon)
        self.assertIn("set response=v_result where request_id=p_request", self.recon)
        self.assertIn("return v_result;", self.recon)

    def test_no_schema_acl_or_workflow_status_changes(self):
        for forbidden in ("alter table", "create table", "create trigger", "grant execute",
                          "revoke ", "update public.audit_events", "delete from public.audit_events",
                          "workflow_status"):
            self.assertNotIn(forbidden, self.sql.lower())
        self.assertEqual(len(re.findall("CREATE OR REPLACE FUNCTION", self.sql, re.I)), 2)
        self.assertEqual(len(re.findall(r"\$function\$;", self.sql)), 2)
        self.assertTrue(self.sql.rstrip().endswith("commit;"))

if __name__ == "__main__":
    unittest.main()

