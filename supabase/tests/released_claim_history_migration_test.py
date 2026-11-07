"""Source contract checks for the forward-only claim-history migration."""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
MIGRATION = ROOT / "supabase/migrations/20261104_released_claim_history_readers.sql"


def function_body(sql: str, name: str) -> str:
    match = re.search(
        rf"create\s+or\s+replace\s+function\s+public\.{name}\b.*?\bas\s+(\$function\$|\$\$)(.*?)\1",
        sql,
        flags=re.IGNORECASE | re.DOTALL,
    )
    if not match:
        raise AssertionError(f"missing function body: {name}")
    return match.group(2).lower()


def declaration(sql: str, name: str) -> str:
    match = re.search(
        rf"create\s+or\s+replace\s+function\s+public\.{name}\b(.*?)\bas\s+\$",
        sql,
        flags=re.IGNORECASE | re.DOTALL,
    )
    if not match:
        raise AssertionError(f"missing function declaration: {name}")
    return match.group(1).lower()


class ReleasedClaimHistoryMigrationTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sql = MIGRATION.read_text(encoding="utf-8")
        cls.lower = cls.sql.lower()

    def test_existing_claim_readers_keep_auth_owner_scope_and_search_path(self):
        for name in ("get_claimed_listing_detail", "get_claimed_listing_constituents"):
            body = function_body(self.sql, name)
            decl = declaration(self.sql, name)
            self.assertIn("auth.uid() is null", body)
            self.assertIn("c.claim_id=p_claim", body)
            self.assertIn("c.ngo_user_id=auth.uid()", body)
            self.assertIn("claim_not_found_or_forbidden", body)
            self.assertIn("security definer", decl)
            self.assertIn("set search_path=pg_catalog,public,pg_temp", decl)

    def test_historical_states_and_active_lease_gate_are_explicit(self):
        body = function_body(self.sql, "get_claimed_listing_constituents")
        for state in ("released", "expired", "completed", "cancelled", "reconciliation_required"):
            self.assertIn(f"'{state}'", body)
        self.assertIn("c.claim_status='active'", body)
        self.assertIn("le.lease_status='active'", body)
        self.assertIn("le.expires_at>clock_timestamp()", body)
        self.assertNotRegex(body, r"\b(insert|update|delete|truncate)\b")

    def test_detail_masks_direct_location_except_valid_active_claim(self):
        body = function_body(self.sql, "get_claimed_listing_detail")
        for field in ("pickup_address", "latitude", "longitude"):
            self.assertIn(f"'{field}'", body)
        self.assertIn("l.source_type='hub_batch'", body)
        self.assertIn("l.source_type='direct_donation'", body)
        self.assertIn("c.claim_status='active'", body)
        self.assertIn("le.lease_status='active'", body)
        self.assertIn("le.expires_at>statement_timestamp()", body)
        self.assertIn("l.listing_status='claimed'", body)
        self.assertIn("else null end", body)

    def test_new_history_rpc_is_owner_scoped_read_only_and_category_complete(self):
        body = function_body(self.sql, "get_my_historical_claim_detail")
        decl = declaration(self.sql, "get_my_historical_claim_detail")
        for state in ("released", "expired", "completed", "cancelled"):
            self.assertIn(f"'{state}'", body)
        self.assertIn("c.claim_status='active'", body)
        self.assertIn("le.expires_at<=clock_timestamp()", body)
        self.assertIn("c.ngo_user_id=auth.uid()", body)
        self.assertIn("n.user_id=auth.uid() and n.active_flag", body)
        self.assertIn("donation_items", body)
        self.assertIn("donation_categories", body)
        self.assertIn("category_name", body)
        self.assertIn("'pickup_address',case when l.source_type='hub_batch'", body)
        self.assertIn("'latitude',case when l.source_type='hub_batch'", body)
        self.assertIn("'longitude',case when l.source_type='hub_batch'", body)
        self.assertNotIn("d.pickup_address", body)
        self.assertNotIn("d.latitude", body)
        self.assertNotIn("d.longitude", body)
        self.assertNotRegex(body, r"\b(insert|update|delete|truncate)\b")
        self.assertIn("security definer", decl)
        self.assertIn("set search_path=pg_catalog,public,pg_temp", decl)

    def test_route_reader_masks_historical_direct_locations_and_keeps_contract(self):
        body = function_body(self.sql, "get_my_authorized_route_pre_deferral")
        for key in ("pickup_address", "pickup_latitude", "pickup_longitude", "pickup_road_node_id"):
            self.assertIn(f"'{key}'", body)
        self.assertIn("authorized and c.claim_status='active'", body)
        self.assertIn("le.lease_status='active'", body)
        self.assertIn("le.expires_at>clock_timestamp()", body)
        self.assertIn("l.listing_status='claimed'", body)
        self.assertIn("l.source_type='hub_batch'", body)
        self.assertIn("'can_start'", body)
        self.assertIn("'can_complete'", body)
        self.assertIn("'can_close'", body)
        self.assertIn("'can_cancel'", body)
        self.assertIn("owner to postgres", self.lower)

    def test_acl_changes_are_limited_to_new_read_only_rpc(self):
        self.assertRegex(
            self.lower,
            r"revoke all on function public\.get_my_historical_claim_detail\(uuid\) from public,anon,authenticated,service_role",
        )
        self.assertRegex(
            self.lower,
            r"grant execute on function public\.get_my_historical_claim_detail\(uuid\) to authenticated",
        )
        self.assertNotRegex(self.lower, r"grant execute on function public\.(?!get_my_historical_claim_detail)")
        self.assertNotRegex(self.lower, r"revoke .* on function public\.(?!get_my_historical_claim_detail)")
        self.assertNotRegex(self.lower, r"\b(insert|update|delete|truncate)\s+(into\s+)?public\.")
        self.assertNotIn("drop function", self.lower)


if __name__ == "__main__":
    unittest.main(verbosity=2)
