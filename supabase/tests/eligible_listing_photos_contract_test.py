"""Local source-contract checks for protected NGO listing photo reads."""
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
MIGRATION = ROOT / "supabase/migrations/20261023_eligible_ngo_listing_details_and_photos.sql"
DONATION_PAGES = ROOT / "frontend/geolock_hub_app/lib/donation_pages.dart"
DASHBOARD = ROOT / "frontend/geolock_hub_app/lib/dashboard_pages.dart"


class EligibleListingPhotoContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sql = MIGRATION.read_text(encoding="utf-8")
        cls.donation_pages = DONATION_PAGES.read_text(encoding="utf-8")
        cls.dashboard = DASHBOARD.read_text(encoding="utf-8")
        cls.donation_helper = cls.sql.split(
            "create or replace function public.can_read_geolock_donation_image", 1
        )[1].split("create or replace function public.can_read_geolock_batch_image", 1)[0]

    def test_batch_member_photos_keep_separate_claimant_and_preclaim_access(self):
        branches = [branch for branch in self.donation_helper.split("      or exists(")
                    if "l.source_type='HUB_BATCH'" in branch]
        self.assertEqual(len(branches), 2)
        claimant, = [branch for branch in branches if "public.donation_claims" in branch]
        preclaim, = [branch for branch in branches if "public.donation_claims" not in branch]
        for branch in branches:
            for guard in (
                "m.membership_status='ACTIVE'", "b.batch_status='PUBLISHED'",
                "n.user_id=auth.uid() and n.active_flag",
                "n.location_verified_at is not null",
                "public.geolock_road_eligible_km(n.user_id,l.listing_id) is not null",
            ):
                self.assertIn(guard, branch)
        self.assertIn("c.listing_id=l.listing_id and c.ngo_user_id=auth.uid()", claimant)
        self.assertIn("left join public.claim_leases le using(claim_id)", claimant)
        self.assertIn("c.claim_status in ('COMPLETED','RECONCILIATION_REQUIRED')", claimant)
        self.assertIn("c.claim_status='ACTIVE' and le.lease_status='ACTIVE'", claimant)
        self.assertIn("le.expires_at>clock_timestamp()", claimant)
        # A valid claim must continue to authorize photos after AVAILABLE->CLAIMED.
        self.assertNotIn("l.listing_status=", claimant)
        self.assertNotIn("l.listing_expires_at", claimant)
        self.assertIn("l.listing_status='AVAILABLE'", preclaim)
        self.assertIn("l.listing_expires_at>clock_timestamp()", preclaim)

    def test_existing_owner_hub_and_direct_claim_access_is_preserved(self):
        self.assertIn("select auth.uid() is not null and exists(", self.donation_helper)
        self.assertIn("d.donor_user_id=auth.uid()", self.donation_helper)
        self.assertIn("h.admin_user_id=auth.uid()", self.donation_helper)
        self.assertIn("r.reservation_status='ACTIVE' and r.expires_at>clock_timestamp()", self.donation_helper)
        self.assertIn("public.hub_inventory hi", self.donation_helper)
        direct_claim, = [branch for branch in self.donation_helper.split("      or exists(")
                        if "l.source_type='DIRECT_DONATION'" in branch
                        and "public.donation_claims" in branch]
        self.assertIn("c.claim_status='ACTIVE' and le.lease_status='ACTIVE'", direct_claim)
        self.assertNotIn("l.listing_status='AVAILABLE'", direct_claim)

    def test_photo_fix_keeps_async_authorization_and_private_storage_unchanged(self):
        # Delegate to the current deployed helper, retaining BOTH async gates.
        async_sql = (ROOT / "supabase/migrations/20261024_async_listing_eligibility_refresh.sql").read_text()
        cached_reader = async_sql.split(
            "create or replace function public.geolock_road_eligible_km", 1
        )[1].split("create or replace function public.process_listing_eligibility_refresh_jobs", 1)[0]
        self.assertIn("public.geolock_ngo_eligibility_ready(p_ngo)", cached_reader)
        self.assertIn("public.geolock_listing_eligibility_ready(p_listing)", cached_reader)
        self.assertNotIn("create or replace function public.geolock_road_eligible_km", self.sql)
        self.assertNotIn("create or replace function public.geolock_ngo_eligibility_ready", self.sql)
        self.assertNotIn("create or replace function public.geolock_listing_eligibility_ready", self.sql)
        self.assertNotIn("storage.buckets", self.sql)
        self.assertNotIn("create policy", self.sql.lower())
        self.assertIn(".createSignedUrl(path, 900)", self.donation_pages)

    def test_discovery_photo_refs_require_authoritative_road_eligibility(self):
        cards = self.sql.split(
            "create or replace function public.discover_eligible_listing_cards()", 1
        )[1]
        self.assertIn("public.geolock_road_eligible_km(v_ngo.user_id,l.listing_id) is not null", cards)
        self.assertIn("public.can_read_geolock_donation_image(di.storage_path)", cards)
        self.assertIn("public.can_read_geolock_batch_image(bi.storage_path)", cards)
        self.assertIn("public.can_read_geolock_donation_image(member_img.storage_path)", cards)
        self.assertNotIn("null::text,l.batch_id,l.donation_id", cards)

    def test_photo_readers_allow_empty_result_without_returning_forbidden_rows(self):
        for name, end in (
            ("get_donation_images", "create or replace function public.get_batch_images"),
            ("get_batch_images", "create or replace function public.discover_eligible_listing_cards"),
        ):
            body = self.sql.split(f"create or replace function public.{name}", 1)[1]
            body = body.split(end, 1)[0]
            self.assertIn("if auth.uid() is null then raise exception 'UNAUTHENTICATED'", body)
            self.assertIn("can_read_geolock_", body)
            self.assertNotIn("NOT_FOUND_OR_FORBIDDEN", body)

    def test_details_revalidate_listing_and_home_card_has_navigation(self):
        detail = self.donation_pages.split("class _NgoListingDetailsPageState", 1)[1]
        self.assertIn("'get_eligible_listing_constituents'", detail)
        self.assertIn("_loadOptionalListingImages", detail)
        self.assertIn("catch (_) {\n      return [];", detail)
        self.assertIn("NgoListingDetailsPage(", self.dashboard)
        self.assertIn("listing: row", self.dashboard)

    def test_discover_card_navigates_to_details_without_claim_action(self):
        card = self.donation_pages.split("class EligibleListingCard", 1)[1]
        card = card.split("class MyClaimsPage", 1)[0]
        self.assertIn("onTap: onOpen", card)
        self.assertNotIn("onClaim", card)
        self.assertNotIn("onPressed:", card)
        self.assertIn("onClaimConfirmed:", self.dashboard)

    def test_detail_claim_uses_persisted_idempotency_and_confirmed_response(self):
        detail = self.donation_pages.split("class _NgoListingDetailsPageState", 1)[1]
        detail = detail.split("class ClaimPickupDetailPage", 1)[0]
        self.assertIn("_db.rpc(\n        'claim_listing'", detail)
        self.assertIn("'p_request': request", detail)
        self.assertIn("prefs.setString(key, request)", detail)
        self.assertIn("outcome == 'SUCCESS'", detail)
        self.assertIn("outcome == 'CONFLICT' || outcome == 'INELIGIBLE'", detail)
        self.assertIn("const MyClaimsPage()", detail)
        self.assertIn("widget.onClaimConfirmed?.call()", detail)
        self.assertNotIn("setState(() => _listings = _load())", self.donation_pages)
        self.assertNotIn("setState(() async", self.donation_pages)


if __name__ == "__main__":
    unittest.main()
