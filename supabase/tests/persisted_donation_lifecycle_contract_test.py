"""Offline source contracts only. Never connects to PostgreSQL or Supabase."""
from pathlib import Path
import re
import json
import unittest

from cancel_claim_audit_contract_test import AUDIT_COLUMNS, split_values
from claim_recovery_reconciliation_audit_contract_test import body, compact

ROOT = Path(__file__).resolve().parents[2]
SQL = (ROOT / "supabase/migrations/20261027_persisted_donation_lifecycle.sql").read_text()


class PersistedDonationLifecycleContracts(unittest.TestCase):
    def test_existing_function_signatures_security_settings_and_results_are_preserved(self):
        captured = json.loads((ROOT / "supabase/tests/fixtures/persisted_lifecycle_function_headers.json").read_text())
        normalize = lambda text: re.sub(r"\s+", "", text).lower()
        for name, expected in captured["headers"].items():
            actual = re.search(
                r"(CREATE OR REPLACE FUNCTION public\." + name +
                r"\(.*?)(?=AS\s+\$function\$)", SQL, re.I | re.S).group(1)
            self.assertEqual(normalize(actual), normalize(expected), name)

    def test_final_vocabulary_and_transaction_boundary(self):
        check = re.search(r"add constraint donations_donation_status_check\s*check\((.*?)\);",
                          SQL, re.S).group(1)
        self.assertEqual(set(re.findall(r"'([A-Z_]+)'", check)), {
            "SUBMITTED", "AVAILABLE", "HUB_ASSIGNED", "AT_HUB", "BATCHED",
            "CLAIMED", "PICKUP_IN_PROGRESS", "COLLECTED", "CANCELLED",
        })
        self.assertIn("begin;", SQL)
        self.assertTrue(SQL.rstrip().endswith("commit;"))
        self.assertIn("in share row exclusive mode", SQL)
        self.assertIn("set local lock_timeout = '5s'", SQL)
        self.assertNotIn("disable trigger", SQL.lower())
        # The only transition exemption is inside the maintenance transaction.
        self.assertLess(SQL.index("lock table"), SQL.index("drop trigger trg_donation_transition"))
        self.assertLess(SQL.index("create trigger trg_donation_transition"), SQL.index("commit;"))

    def test_creation_keeps_uncommitted_item_insertion_staging(self):
        create = body(SQL, "create_and_validate_donation")
        self.assertLess(create.index("'SUBMITTED'"), create.index("insert into public.donation_items"))
        self.assertIn("then 'AVAILABLE' else 'SUBMITTED'", create)
        self.assertLess(create.index("insert into public.donation_items"), create.index("update public.donations"))
        self.assertNotIn("function public.guard_donation_items", SQL)
        self.assertNotIn("function public.create_donation_with_images", SQL)
        self.assertNotIn("function public.require_donation_photo_before_commit", SQL)
        validator = body(SQL, "geolock_assert_donation_lifecycle")
        self.assertIn("DONATION_FINALIZATION_REQUIRED", validator)
        self.assertIn("v_d.donation_status in ('SUBMITTED','HUB_ASSIGNED','AT_HUB','BATCHED')", validator)
        self.assertIn("deferrable initially deferred", SQL)
        self.assertIn("geolock_assert_donation_lifecycle(new.donation_id)", SQL)

    def test_direct_and_hub_transitions_and_forbidden_skips(self):
        guard = compact(body(SQL, "enforce_donation_transition"))
        for previous, following in [
            ("SUBMITTED", "AVAILABLE"), ("SUBMITTED", "HUB_ASSIGNED"),
            ("AVAILABLE", "CLAIMED"), ("HUB_ASSIGNED", "AT_HUB"),
            ("AT_HUB", "BATCHED"), ("BATCHED", "CLAIMED"),
            ("CLAIMED", "PICKUP_IN_PROGRESS"), ("CLAIMED", "AVAILABLE"),
            ("CLAIMED", "BATCHED"), ("PICKUP_IN_PROGRESS", "COLLECTED"),
        ]:
            self.assertIn(f"old.donation_status='{previous}' and new.donation_status='{following}'", guard)
        self.assertNotIn("old.donation_status='AVAILABLE' and new.donation_status='PICKUP_IN_PROGRESS'", guard)
        self.assertNotIn("old.donation_status='BATCHED' and new.donation_status='PICKUP_IN_PROGRESS'", guard)
        self.assertNotIn("READY_FOR_PICKUP", guard)

    def test_claim_atomically_transitions_complete_set_after_task_creation(self):
        claim = body(SQL, "claim_listing")
        self.assertIn("v_req.outcome is not null", claim)
        self.assertIn("IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD", claim)
        self.assertIn("geolock_ngo_listing_road_check", claim)
        self.assertIn("geolock_lock_listing_donations(p_listing", claim)
        for write in ("insert into public.donation_claims", "insert into public.claim_leases",
                      "update public.listings", "insert into public.pickup_tasks"):
            self.assertLess(claim.index(write), claim.index("perform public.geolock_transition_listing_donations"))
        self.assertIn("then 'AVAILABLE' else 'BATCHED' end,'CLAIMED'", claim)
        self.assertNotIn("exception when", claim.lower())

    def test_batch_locks_inventory_membership_and_exact_count(self):
        lock = body(SQL, "geolock_lock_listing_donations")
        for contract in ("public.hub_batches where batch_id=v_l.batch_id for update",
                         "membership_status='ACTIVE' order by m.donation_id",
                         "where donation_id=v_id for update", "hi.hub_id=v_b.hub_id",
                         "hi.inventory_status='BATCHED'", "v_count>0",
                         "v_count=v_b.batch_donation_count", "dona" + "tion_status=any(p_states)"):
            self.assertIn(contract, lock)
        self.assertLess(lock.index("public.hub_batches"), lock.index("for v_id in"))
        move = body(SQL, "geolock_transition_listing_donations")
        self.assertIn("geolock_lock_listing_donations(p_listing,array[p_from])", move)
        self.assertIn("order by d.donation_id", move)
        self.assertIn("LISTING_DONATION_SET_CHANGED", move)
        self.assertNotIn("exception when", move.lower())

    def test_start_and_complete_cannot_skip_claimed_or_update_partial_batch(self):
        start, finish = body(SQL, "start_pickup"), body(SQL, "complete_pickup")
        self.assertIn("geolock_transition_listing_donations(v_l.listing_id,'CLAIMED','PICKUP_IN_PROGRESS')", start)
        self.assertIn("geolock_transition_listing_donations(v_l.listing_id,'PICKUP_IN_PROGRESS','COLLECTED')", finish)
        self.assertIn("HANDOVER_NOT_CONFIRMED", finish)
        self.assertIn("task_status='DISPATCHED'", start)
        self.assertIn("task_status='DISPATCHED'", finish)
        self.assertIn("inventory_status='COLLECTED'", finish)
        self.assertIn("batch_status='COLLECTED'", finish)

    def test_cancellation_recovery_and_reconciliation_release_to_path_specific_state(self):
        for name in ("cancel_claim", "recover_expired_claims", "submit_claim_reconciliation"):
            routine = body(SQL, name)
            self.assertIn("geolock_transition_listing_donations(v_l.listing_id,'CLAIMED'", routine)
            self.assertIn("then 'AVAILABLE' else 'BATCHED' end", routine)
            self.assertIn("public.active_task_route_assignments", routine)
            self.assertIn("public.pickup_route_stops", routine)
            self.assertNotIn("READY_FOR_PICKUP", routine)
            self.assertNotIn("exception when", routine.lower())
        recovery = body(SQL, "recover_expired_claims")
        self.assertIn("for update of c skip locked", recovery)
        self.assertIn("v_l.listing_expires_at<=clock_timestamp()", recovery)
        self.assertIn("HANDOVER_OR_ROUTE_ACTIVITY_UNCERTAIN", recovery)
        self.assertIn("RECONCILIATION_REQUIRED", recovery)

    def test_pickup_cancel_recovery_reconciliation_race_lock_prefix(self):
        for name, lease, claim in (
            ("start_pickup", "v_lease", "p_claim"),
            ("complete_pickup", "v_lease", "p_claim"),
            ("cancel_claim", "v_le", "p_claim"),
            ("submit_claim_reconciliation", "v_le", "p_claim"),
        ):
            routine = body(SQL, name)
            positions = [re.search(r"(?:from|update) public\." + table, routine).start()
                         for table in ("donation_claims", "claim_leases", "listings", "pickup_tasks")]
            self.assertEqual(positions, sorted(positions), name)
        self.assertIn("for update of c skip locked", body(SQL, "recover_expired_claims"))
        # Claim-vs-cancel-donation both acquire listing before donation locks.
        donor_cancel = body(SQL, "cancel_donation")
        self.assertLess(donor_cancel.index("from public.listings l where"),
                        donor_cancel.index("into v_owner,v_path,v_previous"))

    def test_resolved_reconciliation_replays_only_after_participant_payload_validation(self):
        recon = body(SQL, "submit_claim_reconciliation")
        participant = recon.index("RECONCILIATION_PARTICIPANT_ONLY")
        payload = recon.index("v_prior.case_id<>v_case.case_id")
        replay = recon.index("if v_prior.response is not null then return v_prior.response")
        state = recon.index("RECONCILIATION_STATE_MISMATCH")
        self.assertLess(participant, payload)
        self.assertLess(payload, replay)
        self.assertLess(replay, state)
        self.assertIn("EVIDENCE_ALREADY_SUBMITTED", recon)
        self.assertIn("set response=v_result where request_id=p_request", recon)
        self.assertIn("'reconciliation_status',v_result->>'outcome'", recon)

    def test_backfill_requires_real_claim_lease_task_evidence(self):
        preflight = SQL.split("$preflight$;")[0]
        for evidence in ("LIFECYCLE_BACKFILL_AMBIGUOUS_DIRECT_EVIDENCE",
                         "LIFECYCLE_BACKFILL_AMBIGUOUS_BATCH_EVIDENCE",
                         "LIFECYCLE_BACKFILL_INCOMPLETE_BATCH",
                         "le.lease_status=c.claim_status",
                         "t.task_status in ('CONFIRMED','PLANNED')"):
            self.assertIn(evidence, preflight)
        self.assertIn("then 'AVAILABLE' else 'CLAIMED' end", SQL)
        self.assertIn("d.donation_status='BATCHED' and l.listing_status='CLAIMED'", SQL)
        self.assertIn("geolock_assert_donation_lifecycle(v_id)", SQL)
        self.assertNotIn("update public.audit_events", SQL.lower())
        self.assertNotIn("delete from public.audit_events", SQL.lower())

    def test_photo_discovery_keep_current_async_fail_closed_guards_and_claim_branches(self):
        photos = body(SQL, "can_read_geolock_donation_image")
        for contract in ("auth.uid() is not null", "d.donor_user_id=auth.uid()",
                         "d.donation_status='AVAILABLE'", "l.listing_status='AVAILABLE'",
                         "le.expires_at>clock_timestamp()", "h.admin_user_id=auth.uid()",
                         "c.claim_status in ('COMPLETED','RECONCILIATION_REQUIRED')"):
            self.assertIn(contract, photos)
        self.assertEqual(photos.count("geolock_road_eligible_km"), 4)
        for name in ("discover_eligible_listing_cards", "discover_eligible_listings",
                     "get_eligible_listing_constituents"):
            self.assertIn("'AVAILABLE'", body(SQL, name))
            self.assertNotIn("READY_FOR_PICKUP", body(SQL, name))
        # These deployed helpers retain both readiness gates and directed 20km checks.
        for untouched in ("geolock_road_eligible_km", "geolock_ngo_listing_road_check",
                          "process_listing_eligibility_refresh_jobs", "process_ngo_eligibility_refresh_jobs",
                          "geolock_road_costs", "geolock_resolve_road_node"):
            self.assertNotRegex(SQL, r"function public\." + untouched + r"\(")
        self.assertNotIn("storage.buckets", SQL)
        self.assertNotIn("create policy", SQL.lower())

    def test_no_unnecessary_hub_routing_or_security_changes(self):
        for untouched in ("reserve_hub_capacity", "confirm_hub_receipt",
                          "publish_whole_donation_batch", "guard_batch_immutability"):
            self.assertNotRegex(SQL, r"function public\." + untouched + r"\(")
        self.assertNotIn("grant ", SQL.lower())
        self.assertNotIn("alter policy", SQL.lower())
        self.assertNotIn("disable row level security", SQL.lower())
        for helper, arguments in (
            ("geolock_lock_listing_donations", "uuid,text[]"),
            ("geolock_transition_listing_donations", "uuid,text,text"),
            ("geolock_assert_donation_lifecycle", "uuid"),
            ("geolock_validate_donation_at_commit", ""),
        ):
            self.assertIn(f"revoke all on function public.{helper}({arguments})", SQL)
        self.assertEqual(SQL.count("from public,anon,authenticated,service_role;"), 4)

    def test_audit_columns_and_reader_are_compatible_with_existing_schema(self):
        reader = body(SQL, "get_authorized_audit_events")
        self.assertNotIn("a.donation_id", reader)
        self.assertNotIn("a.listing_id", reader)
        self.assertIn("a.details->>'donation_id'", reader)
        self.assertIn("AUDIT_NOT_FOUND_OR_FORBIDDEN", reader)
        for columns, values in re.findall(
                r"insert into public\.audit_events\(([^()]*)\)\s*values\((.*?)\);",
                SQL, re.I | re.S):
            names = [x.strip() for x in columns.split(",")]
            entries = split_values(values)
            self.assertTrue(set(names).issubset(AUDIT_COLUMNS), names)
            self.assertEqual(len(names), len(entries))
        # No request table, recorded responses or existing audit rows are rewritten.
        self.assertNotRegex(SQL.lower(), r"delete from public\.(claim_requests|claim_reconciliation_evidence)")


if __name__ == "__main__":
    unittest.main()
