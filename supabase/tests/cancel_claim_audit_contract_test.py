"""Cancellation audit schema source contracts; never connect to a database."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
MIGRATION = ROOT / "supabase/migrations/20261025_fix_cancel_claim_audit_columns.sql"
BASELINE = ROOT / "supabase/migrations/20261019_stage1_claim_recovery_and_reconciliation.sql"
AUDIT_COLUMNS = set("""
event_id actor_user_id actor_role entity_type entity_id event_type request_id
claim_id lease_id correlation_id previous_state requested_state resulting_state
reason_code outcome details software_version configuration_version occurred_at
""".split())

def body(sql):
    return re.search(r"function public\.cancel_claim\([^;]*?as\s+(\$\w*\$)(.*?)\1",
                     sql, re.I | re.S).group(2)

def compact(sql):
    return re.sub(r"\s+", " ", sql).strip()

def split_values(text):
    # SQL source splitting only: preserve quoted literals and nested expressions.
    parts, start, depth, quoted, i = [], 0, 0, False, 0
    while i < len(text):
        ch = text[i]
        if ch == "'":
            if quoted and i + 1 < len(text) and text[i + 1] == "'":
                i += 2
                continue
            quoted = not quoted
        elif not quoted:
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
            elif ch == "," and depth == 0:
                parts.append(text[start:i].strip())
                start = i + 1
        i += 1
    parts.append(text[start:].strip())
    return parts

class CancelClaimAuditContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sql = MIGRATION.read_text()
        cls.fixed = body(cls.sql)
        cls.baseline = body(BASELINE.read_text())

    def test_only_audit_projection_changes(self):
        expected = self.baseline.replace(
            "request_id,claim_id,lease_id,donation_id,listing_id,correlation_id,",
            "request_id,claim_id,lease_id,correlation_id,",
        ).replace(
            "v_l.donation_id,v_l.listing_id,p_request,",
            "p_request,",
        ).replace(
            "jsonb_build_object('listing_id',v_c.listing_id,'task_id',v_t.task_id)",
            "jsonb_build_object('donation_id',v_l.donation_id, "
            "'listing_id',v_c.listing_id,'task_id',v_t.task_id)",
        )
        self.assertEqual(compact(expected), compact(self.fixed))

    def test_all_audit_inserts_fit_the_deployed_schema_and_value_arity(self):
        inserts = re.findall(
            r"insert into public\.audit_events\((.*?)\)\s*values\((.*?)\);",
            self.fixed, re.S | re.I,
        )
        self.assertEqual(len(inserts), 2)
        for columns, values in inserts:
            names = [x.strip() for x in columns.split(",")]
            self.assertTrue(set(names).issubset(AUDIT_COLUMNS), names)
            self.assertEqual(len(names), len(split_values(values)))
        self.assertIn("'donation_id',v_l.donation_id", self.fixed)
        self.assertIn("'listing_id',v_c.listing_id", self.fixed)
        self.assertIn("'task_id',v_t.task_id", self.fixed)
        self.assertIn("'CLAIM',p_claim,'CANCEL_CLAIM'", self.fixed)

    def test_idempotency_lock_order_and_atomicity_are_preserved(self):
        for contract in (
            "v_c.ngo_user_id is distinct from v_actor",
            "on conflict(request_id) do nothing",
            "v_req.request_fingerprint is distinct from v_fingerprint",
            "if v_req.response is not null then return v_req.response",
            "update public.claim_cancellation_requests set response=v_result",
            "v_t.task_status <> 'CONFIRMED'",
            "TASK_HAS_ROUTE_ACTIVITY",
            "LEASE_EXPIRED_USE_RECOVERY",
        ):
            self.assertIn(contract, self.fixed)
        locks = [
            "where c.claim_id=p_claim for update",
            "where le.claim_id=p_claim for update",
            "where l.listing_id=v_c.listing_id for update",
            "where t.claim_id=p_claim for update",
        ]
        positions = [self.fixed.index(lock) for lock in locks]
        self.assertEqual(positions, sorted(positions))
        self.assertNotIn("exception when", self.fixed.lower())
        self.assertLess(self.fixed.index("set response=v_result"),
                        self.fixed.rindex("insert into public.audit_events"))

    def test_no_schema_permission_or_lifecycle_expansion(self):
        for forbidden in ("alter table", "create table", "create trigger",
                          "grant execute", "revoke ", "update public.audit_events",
                          "delete from public.audit_events", "update public.donations"):
            self.assertNotIn(forbidden, self.sql.lower())
        self.assertEqual(len(re.findall("CREATE OR REPLACE FUNCTION", self.sql, re.I)), 1)
        self.assertIn("SECURITY DEFINER", self.sql)
        self.assertIn("SET search_path TO 'pg_catalog', 'public', 'pg_temp'", self.sql)
        self.assertRegex(self.sql, r"\$function\$;\s*--")
        self.assertTrue(self.sql.rstrip().endswith("commit;"))

if __name__ == "__main__":
    unittest.main()

