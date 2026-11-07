import unittest
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
MIGRATION = ROOT / "supabase/migrations/20261031_claim_audit_and_failure_capture.sql"
SCHEMA = ROOT / "geolock-v3-public-schema.sql"
STAGE_B = ROOT / "supabase/tests/stage8_stage_b_isolated_test.py"


def function_body(source, signature, tag="$function$"):
    match = re.search(re.escape(signature) + r".*?\bAS\s+" + re.escape(tag)
                      + r"(.*?)" + re.escape(tag) + r";", source, re.I | re.S)
    if not match:
        raise AssertionError(f"SQL function body not found: {signature}")
    return match.group(1)


class SystemAuditContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.migration = MIGRATION.read_text(encoding="utf-8")
        cls.schema = SCHEMA.read_text(encoding="utf-8")
        cls.stage_b = STAGE_B.read_text(encoding="utf-8")

    def test_audit_actor_is_nullable_but_foreign_key_remains(self):
        table_start = self.schema.index("CREATE TABLE public.audit_events (")
        table_end = self.schema.index("\n);", table_start)
        audit_table = self.schema[table_start:table_end]
        self.assertRegex(audit_table, r"actor_user_id uuid,")
        self.assertNotRegex(audit_table, r"actor_user_id uuid NOT NULL")
        self.assertIn("FOREIGN KEY (actor_user_id) REFERENCES auth.users(id)", self.schema)

    def test_transition_audit_maps_null_auth_uid_to_system_role(self):
        helper = function_body(
            self.migration,
            "CREATE OR REPLACE FUNCTION public.geolock_transition_listing_donations(")
        self.assertIn("values(auth.uid(),case when auth.uid() is null then 'SYSTEM'", helper)
        self.assertIn("else (select role from public.user_profiles where user_id=auth.uid()) end", helper)
        self.assertIn("insert into public.audit_events(actor_user_id,actor_role", helper)

    def test_recovery_audit_is_system_attributed_without_user_actor(self):
        recovery = function_body(
            self.migration,
            "CREATE OR REPLACE FUNCTION public.recover_expired_claims(")
        self.assertIn("insert into public.audit_events(actor_role,entity_type,entity_id,event_type", recovery)
        self.assertIn("values('SYSTEM','CLAIM'", recovery)
        self.assertNotIn("insert into public.audit_events(actor_user_id,actor_role", recovery)

    def test_isolated_auth_uid_double_treats_empty_subject_as_null(self):
        self.assertIn(
            "SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid",
            self.stage_b)


if __name__ == "__main__":
    unittest.main()
