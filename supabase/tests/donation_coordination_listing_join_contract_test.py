"""Offline contract checks for the donor coordination RPC join correction."""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
MIGRATION = (
    ROOT
    / "supabase/migrations/20261108140000_fix_get_my_donation_coordination_listing_join.sql"
)


class DonationCoordinationListingJoinContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        sql = MIGRATION.read_text(encoding="utf-8")
        cls.function = sql.split(
            "CREATE OR REPLACE FUNCTION public.get_my_donation_coordination(", 1
        )[1].split("$function$;", 1)[0]
        cls.normalized = re.sub(r"\s+", " ", cls.function)

    def test_case_claim_listing_and_donation_bindings_are_explicit(self):
        self.assertIn(
            "JOIN public.donation_claims c ON c.claim_id = rc.claim_id "
            "AND c.listing_id = rc.listing_id",
            self.normalized,
        )
        self.assertIn(
            "JOIN public.listings l ON l.listing_id = c.listing_id "
            "AND l.listing_id = rc.listing_id",
            self.normalized,
        )
        self.assertIn("WHERE l.donation_id = p_donation", self.normalized)
        self.assertIn("AND l.source_type = rc.source_type", self.normalized)

    def test_nullable_case_donation_preserves_binding_and_rejects_conflict(self):
        self.assertIn("rc.donation_id IS NULL", self.normalized)
        self.assertIn("l.donation_id = rc.donation_id", self.normalized)

        requested_donation = "donation-a"
        listing_donation = "donation-a"
        allowed = lambda case_donation: (
            listing_donation == requested_donation
            and (case_donation is None or listing_donation == case_donation)
        )

        self.assertTrue(allowed(None))
        self.assertTrue(allowed("donation-a"))
        self.assertFalse(allowed("donation-b"))

    def test_function_contract_and_security_remain_in_the_replacement(self):
        self.assertTrue(self.normalized.startswith("p_donation uuid) RETURNS jsonb"))
        self.assertIn("STABLE SECURITY DEFINER", self.normalized)
        self.assertIn("SET search_path TO 'pg_catalog', 'pg_temp'", self.normalized)
        self.assertIn("auth.uid() IS NULL", self.normalized)
        self.assertIn("DONATION_OWNER_REQUIRED", self.normalized)
        self.assertIn("'donation_id', p_donation", self.normalized)
        self.assertIn("'contexts'", self.normalized)
        self.assertIn("jsonb_agg(public.get_my_claim_coordination(x.claim_id))", self.normalized)
        self.assertIn("ORDER BY (rc.resolved_at IS NULL) DESC, rc.opened_at DESC", self.normalized)
        self.assertIn("LIMIT 10", self.normalized)

    def test_replacement_reader_contains_no_state_transition_statements(self):
        self.assertNotRegex(
            self.function,
            r"(?i)\b(?:INSERT\s+INTO|UPDATE|DELETE\s+FROM|TRUNCATE)\b",
        )
        self.assertNotIn("submit_claim_reconciliation", self.normalized)


if __name__ == "__main__":
    unittest.main(verbosity=2)
