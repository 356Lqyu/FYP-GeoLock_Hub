"""Source contracts only: no database connections or SQL execution."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
SQL = (ROOT / "supabase/migrations/20261024_async_listing_eligibility_refresh.sql").read_text()
OLD = (ROOT / "supabase/migrations/20261023_async_ngo_eligibility_refresh.sql").read_text()

def body(name):
    return re.search(r"function public\." + name + r"\([^;]*?as (\$[a-z_]*\$)(.*?)\1", SQL, re.S | re.I).group(2)

class ListingRefreshContracts(unittest.TestCase):
    def test_submit_trigger_has_only_atomic_invalidation_and_enqueue(self):
        trigger = body("geolock_listing_eligibility_trigger")
        self.assertIn("delete from public.ngo_listing_road_eligibility", trigger)
        self.assertIn("insert into public.listing_eligibility_refresh_jobs", trigger)
        self.assertNotIn("perform public.geolock_refresh", trigger)
        self.assertNotIn("exception when", trigger)
        # Prevent queue->listing / listing->queue inversion.
        self.assertNotIn("update public.listing_eligibility_refresh_jobs", trigger)

    def test_generation_covers_insert_coordinates_node_and_republication(self):
        prepare = body("geolock_prepare_listing_eligibility")
        for field in ("pickup_latitude", "pickup_longitude", "pickup_road_node_id"):
            self.assertIn(f"new.{field} is distinct from old.{field}", prepare)
        self.assertIn("new.listing_status='AVAILABLE' and old.listing_status<>'AVAILABLE'", prepare)
        self.assertIn("old.eligibility_generation+1", prepare)
        self.assertIn("new.eligibility_generation:=old.eligibility_generation", prepare)
        self.assertIn("v_distance>500", prepare)
        self.assertIn("new.pickup_road_node_id:=v_node", prepare)
        self.assertIn("after insert or update on public.listings", SQL)

    def test_readers_and_claims_fail_closed_independently(self):
        reader = body("geolock_road_eligible_km")
        check = body("geolock_ngo_listing_road_check")
        ready = body("geolock_listing_eligibility_ready")
        for function in (reader, check):
            self.assertIn("geolock_ngo_eligibility_ready", function)
            self.assertIn("geolock_listing_eligibility_ready", function)
        for condition in ("j.job_status='COMPLETED'", "j.eligibility_generation=l.eligibility_generation",
                          "j.expected_road_node_id=l.pickup_road_node_id",
                          "j.expected_snapshot_id=public.geolock_active_road_snapshot()"):
            self.assertIn(condition, ready)
        self.assertLess(check.index("geolock_listing_eligibility_ready"),
                        check.index("perform public.geolock_refresh_listing_road_eligibility"))
        self.assertIn("geolock_refresh_listing_road_eligibility(p_listing, p_ngo)", check)
        self.assertIn("e.geofence_radius_m=cfg.geofence_radius_m", reader)
        self.assertNotIn("function public.claim_listing", SQL)

    def test_worker_serializes_ngo_and_listing_changes(self):
        worker = body("process_listing_eligibility_refresh_jobs")
        self.assertIn("for update skip locked", worker)
        self.assertLess(worker.index("from public.road_network_coverage"),
                        worker.index("from public.ngo_profiles"))
        self.assertLess(worker.index("from public.ngo_profiles"),
                        worker.index("from public.listings where"))
        self.assertIn("order by n.user_id for share", worker)
        self.assertIn("from public.listings where listing_id=v_job.listing_id for update", worker)
        for check in ("v_listing.eligibility_generation<>v_job.eligibility_generation",
                      "v_listing.pickup_road_node_id is distinct from v_job.expected_road_node_id",
                      "v_snapshot is distinct from v_job.expected_snapshot_id",
                      "not (n.user_id=any(v_ngos))"):
            self.assertIn(check, worker)
        self.assertIn("where n.user_id=v_job.ngo_user_id for update", OLD)
        self.assertIn("exception when query_canceled", worker)
        self.assertIn("raise exception 'NGO_SET_CHANGED_RETRY'", worker)
        self.assertLess(worker.index("perform public.geolock_refresh_listing"),
                        worker.index("set job_status='COMPLETED'"))
        self.assertIn("session_user<>'postgres'", worker)

    def test_cron_timeout_and_queue_permissions(self):
        self.assertIn("set statement_timeout = ''10min''; select public.process_listing_eligibility_refresh_jobs();", SQL)
        self.assertIn("'geolock-listing-eligibility-refresh','* * * * *',v_command", SQL)
        self.assertIn("v_existing.username<>'postgres'", SQL)
        self.assertIn("revoke all on sequence public.listing_eligibility_refresh_jobs_job_id_seq", SQL)
        self.assertIn("enable row level security", SQL)
        self.assertIn("from public,anon,authenticated,service_role", SQL)

    def test_existing_available_listings_are_bootstrapped(self):
        self.assertIn("update public.listings set eligibility_generation=1 where listing_status='AVAILABLE'", SQL)
        self.assertIn("select l.listing_id,l.eligibility_generation,l.pickup_road_node_id,c.network_snapshot_id", SQL)
        # No teammate routing algorithm, donation/photo or NGO worker rewrite.
        for name in ("geolock_road_costs", "geolock_refresh_listing_road_eligibility",
                     "geolock_refresh_ngo_road_eligibility", "create_donation_with_images",
                     "create_and_validate_donation", "process_ngo_eligibility_refresh_jobs"):
            self.assertNotRegex(SQL.lower(), r"create or replace function public\." + name + r"\(")

if __name__ == "__main__":
    unittest.main()

