"""Local contract checks only; these do not connect to Supabase/PostgreSQL."""
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
MIGRATION = ROOT / "supabase/migrations/20261022_role_onboarding_and_profile_management.sql"
ASYNC_MIGRATION = ROOT / "supabase/migrations/20261023_async_ngo_eligibility_refresh.sql"
AUTH_CONTROLLER = ROOT / "frontend/geolock_hub_app/lib/auth/auth_controller.dart"
AUTH_PAGES = ROOT / "frontend/geolock_hub_app/lib/auth/auth_pages.dart"
MAIN = ROOT / "frontend/geolock_hub_app/lib/main.dart"
DONATIONS = ROOT / "frontend/geolock_hub_app/lib/donation_pages.dart"
PROFILE = ROOT / "frontend/geolock_hub_app/lib/dashboard_pages.dart"


class RoleOnboardingContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sql = MIGRATION.read_text(encoding="utf-8")
        cls.async_sql = ASYNC_MIGRATION.read_text(encoding="utf-8")
        cls.auth = AUTH_CONTROLLER.read_text(encoding="utf-8")
        cls.pages = AUTH_PAGES.read_text(encoding="utf-8")
        cls.main = MAIN.read_text(encoding="utf-8")
        cls.donations = DONATIONS.read_text(encoding="utf-8")
        cls.profile = PROFILE.read_text(encoding="utf-8")

    def test_role_registration_is_immutable_and_supports_all_roles(self):
        self.assertIn("p_role not in ('DONOR','NGO','HUB_ADMIN')", self.sql)
        self.assertIn("ROLE_ALREADY_REGISTERED", self.sql)
        self.assertIn("insert into public.donor_profiles", self.sql)
        self.assertIn("insert into public.ngo_profiles(user_id,ngo_name,registration_number)", self.sql)
        self.assertIn("insert into public.hub_admin_profiles(user_id)", self.sql)
        self.assertIn("'HUB_ADMIN'", self.auth)
        self.assertNotIn("p_role = 'HUB_ADMIN'", self.sql)

    def test_signup_does_not_require_or_write_ngo_location(self):
        self.assertIn("AccountRole.hubAdmin => 'HUB_ADMIN'", self.pages)
        self.assertIn("after email verification and login", self.pages)
        self.assertNotIn("Select the NGO operating location", self.pages)
        self.assertIn("'p_operating_address': null", self.auth)
        self.assertIn("alter column operating_address drop not null", self.sql)
        self.assertIn("alter column latitude drop not null", self.sql)
        self.assertIn("alter column longitude drop not null", self.sql)

    def test_profile_read_is_fast_and_reports_onboarding(self):
        profile_read = self.sql.split("create or replace function public.get_my_profile()", 1)[1]
        profile_read = profile_read.split("-- The same NGO profile row", 1)[0]
        self.assertIn("ngo_location_setup_required", profile_read)
        self.assertIn("hub_setup_required", profile_read)
        self.assertIn("hub.road_node_id", profile_read)
        self.assertIn("h.road_node_id,h.capacity_kg", profile_read)
        self.assertIn("registration_number", profile_read)
        self.assertNotIn("geolock_road_costs", profile_read)
        self.assertNotIn("geolock_resolve_road_node", profile_read)

    def test_migration_preflight_preserves_lifecycle_configuration(self):
        self.assertIn("donation_direct_min_kg=10", self.sql)
        self.assertIn("geofence_radius_m=20000", self.sql)
        self.assertIn("claim_lease_minutes=360", self.sql)
        self.assertIn("hub_reservation_minutes=120", self.sql)

    def test_ngo_location_update_locks_snapshot_then_profile_and_refreshes(self):
        body = self.async_sql.split("create or replace function public.set_ngo_operating_location", 1)[1]
        body = body.split("-- Internal status predicate", 1)[0]
        self.assertLess(body.index("for share"), body.index("for update"))
        self.assertIn("geolock_resolve_road_node(p_latitude,p_longitude)", body)
        self.assertIn("v_snap_distance > 500", body)
        self.assertNotIn("geolock_refresh_ngo_road_eligibility(v_user)", body)
        self.assertIn("delete from public.ngo_listing_road_eligibility where ngo_user_id=v_user", body)
        self.assertIn("insert into public.ngo_eligibility_refresh_jobs", body)
        self.assertIn("location_generation=v_generation", body)
        self.assertIn("public.vehicles set depot_road_node_id=null", body)
        self.assertIn("NGO_HAS_ACTIVE_OR_UNRESOLVED_CLAIMS", body)
        self.assertIn("'RECONCILIATION_REQUIRED'", body)

    def test_refresh_consumer_is_trusted_stale_safe_and_scheduled(self):
        worker = self.async_sql.split(
            "create or replace function public.process_ngo_eligibility_refresh_jobs()", 1
        )[1]
        self.assertIn("session_user <> 'postgres'", worker)
        self.assertIn("for update skip locked", worker)
        self.assertIn("expected_snapshot_id", worker)
        self.assertIn("expected_road_node_id", worker)
        self.assertIn("location_generation", worker)
        self.assertIn("perform public.geolock_refresh_ngo_road_eligibility", worker)
        self.assertIn("cron.schedule('geolock-ngo-eligibility-refresh'", self.async_sql)
        self.assertIn("grant execute on function public.process_ngo_eligibility_refresh_jobs() to postgres", self.async_sql)

    def test_discovery_cache_is_hidden_until_refresh_finishes(self):
        helper = self.async_sql.split(
            "create or replace function public.geolock_ngo_eligibility_ready", 1
        )[1].split("-- Preserve the public return contract", 1)[0]
        self.assertIn("job_status in ('PENDING','PROCESSING')", helper)
        self.assertIn("location_generation=n.location_generation) then false", helper)
        self.assertIn("j.job_status='FAILED' and j.attempt_count<3", helper)
        self.assertIn("j.job_status='SUPERSEDED'", helper)
        cached_read = self.async_sql.split(
            "create or replace function public.geolock_road_eligible_km", 1
        )[1].split("-- One trusted database consumer", 1)[0]
        self.assertIn("geolock_ngo_eligibility_ready(p_ngo)", cached_read)
        status_rpc = self.async_sql.split(
            "create or replace function public.get_my_ngo_eligibility_refresh_status()", 1
        )[1]
        self.assertIn("location_generation=v_generation) then return 'FAILED'", status_rpc)

    def test_claim_and_location_share_the_ngo_row_lock(self):
        claim = self.sql.split("create or replace function public.claim_listing", 1)[1]
        self.assertIn("where user_id=v_actor and active_flag for share", claim)
        self.assertIn("geolock_ngo_listing_road_check(v_actor,p_listing)", claim)
        self.assertIn("claim_lease_minutes", claim)
        self.assertIn("CLAIM_ATTEMPT", claim)

    def test_hub_registration_and_updates_validate_server_side(self):
        self.assertIn("geolock_resolve_road_node(p_lat,p_lon)", self.sql)
        self.assertIn("HUB_LOCATION_NOT_ROUTABLE", self.sql)
        self.assertIn("CAPACITY_MUST_BE_50_TO_250_KG", self.sql)
        self.assertIn("p_capacity_kg,v_node,false)", self.sql)
        self.assertIn("update public.community_hubs set active_flag=true", self.sql)
        self.assertIn("public.update_my_hub", self.sql)
        self.assertIn("HUB_HAS_ACTIVE_INVENTORY_OR_COMMITMENTS", self.sql)
        self.assertIn("inventory_status in ('STORED','BATCHED','RECONCILIATION_REQUIRED')", self.sql)
        self.assertIn("reservation_status='ACTIVE'", self.sql)
        self.assertIn("batch_status in ('DRAFT','PUBLISHED','CLAIMED')", self.sql)

    def test_flutter_gates_incomplete_roles_and_uses_protected_rpc(self):
        self.assertIn("ngo_location_setup_required", self.main)
        self.assertIn("hub_setup_required", self.main)
        self.assertIn("set_ngo_operating_location", self.main)
        self.assertIn("requireRoadPreview: true", self.main)
        self.assertIn("register_community_hub", self.donations)
        self.assertIn("update_my_hub", self.donations)
        self.assertIn("update_my_profile", self.profile)
        self.assertIn("set_ngo_operating_location", self.profile)

    def test_rpc_permissions_are_authenticated_only_for_new_mutations(self):
        for signature in (
            "set_ngo_operating_location(text,double precision,double precision)",
            "update_my_profile(text,text,text,text)",
            "update_my_hub(uuid,text,text,double precision,double precision,numeric)",
        ):
            self.assertIn(
                f"revoke all on function public.{signature} from public,anon;",
                self.sql,
            )
            self.assertIn(
                f"grant execute on function public.{signature} to authenticated;",
                self.sql,
            )


if __name__ == "__main__":
    unittest.main()
