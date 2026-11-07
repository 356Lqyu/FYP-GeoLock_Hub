"""Offline interface/custody contracts. No SQL or Supabase RPCs are executed."""
from pathlib import Path
import re
import unittest

from claim_recovery_reconciliation_audit_contract_test import body, compact

ROOT = Path(__file__).resolve().parents[2]
SQL = (ROOT / "supabase/migrations/20261027_persisted_donation_lifecycle.sql").read_text()
OLD = ROOT / "supabase/migrations/20261018_donation_photo_and_availability_transition.sql"
SEVEN = "text,text,text,double precision,double precision,jsonb,text"
NINE = SEVEN + ",timestamptz,timestamptz"


class DonationCreationInterfaceContracts(unittest.TestCase):
    def test_exact_seven_argument_identity_and_no_stale_overload(self):
        match = re.search(r"CREATE OR REPLACE FUNCTION public.create_and_validate_donation\((.*?)\)\s*RETURNS uuid",
                          SQL, re.S | re.I)
        args = [arg.strip() for arg in match.group(1).split(",")]
        self.assertEqual(len(args), 7)
        self.assertEqual([arg.split()[0] for arg in args], [
            "p_title", "p_description", "p_pickup_address", "p_latitude",
            "p_longitude", "p_items", "p_pickup_road_node_id",
        ])
        self.assertIn(f"drop function public.create_and_validate_donation({NINE}) restrict;", SQL)
        self.assertIn("CREATION_RPC_OVERLOAD_REVIEW_REQUIRED", SQL)
        self.assertIn("and proname='create_and_validate_donation')<>1", SQL)
        self.assertLess(SQL.index("drop function public.create_and_validate_donation"), match.start())
        self.assertNotRegex(SQL.lower(), r"drop function[^;]*cascade\s*;")
        self.assertNotIn("p_availability", match.group(0))

    def test_creation_omits_dates_but_donor_detail_preserves_historical_values(self):
        self.assertNotIn("availability_", body(SQL, "create_and_validate_donation"))
        detail = compact(body(SQL, "get_my_donation_detail"))
        for field in ("availability_start", "availability_end"):
            self.assertIn(f"'{field}',d.{field}", detail)
        self.assertNotRegex(SQL.lower(), r"(?:drop|alter) column\s+availability_")
        self.assertNotRegex(SQL.lower(), r"set\s+availability_(?:start|end)")
        create = body(SQL, "create_and_validate_donation")
        self.assertIn("p_pickup_road_node_id,'SUBMITTED'", create)
        self.assertIn("then 'AVAILABLE' else 'SUBMITTED'", create)
        # Listing expiry remains a separate field; creation does not invent one.
        self.assertIn("pickup_road_node_id,listing_expires_at", compact(create))
        self.assertIn("p_pickup_road_node_id,null", compact(create))
        for routine in ("claim_listing", "cancel_claim", "recover_expired_claims",
                        "submit_claim_reconciliation"):
            self.assertIn("listing_expires_at", body(SQL, routine))

    def test_photo_wrapper_changes_only_the_nested_call_arity(self):
        old = body(OLD.read_text(), "create_donation_with_images")
        expected = old.replace("p_items,p_pickup_road_node_id,null,null",
                               "p_items,p_pickup_road_node_id")
        self.assertEqual(compact(body(SQL, "create_donation_with_images")), compact(expected))
        header = re.search(r"CREATE OR REPLACE FUNCTION public.create_donation_with_images\((.*?)AS \$function\$",
                           SQL, re.S | re.I).group(1)
        self.assertIn("p_request uuid", header)
        self.assertIn("p_images jsonb", header)
        self.assertIn("SECURITY DEFINER", header)
        self.assertIn("'pg_catalog', 'public', 'extensions', 'storage', 'pg_temp'", header)

    def test_new_identity_restores_captured_execute_grants_not_default_permissions(self):
        self.assertIn("create temporary table geolock_lifecycle_creation_acl on commit drop", SQL)
        self.assertIn("coalesce(proacl,acldefault('f',proowner))", SQL)
        acl = SQL.split("do $creation_acl$")[1].split("$creation_acl$;")[0]
        self.assertLess(acl.index("revoke all on function"), acl.index("grant execute on function"))
        for contract in ("aclexplode", "x.grantee<>p.proowner",
                         "pg_temp.geolock_lifecycle_creation_acl",
                         "x.privilege_type='EXECUTE'", "v_grant.is_grantable",
                         "with grant option", "v_grant.grantee=0"):
            self.assertIn(contract, acl)
        self.assertIn(f"alter function public.create_and_validate_donation({SEVEN}) owner to postgres", SQL)

    def test_flutter_has_no_donation_availability_fields_parameters_or_date_picker(self):
        lib = ROOT / "frontend/geolock_hub_app/lib"
        for filename in ("donation_pages.dart", "donation_photo_rules.dart"):
            source = (lib / filename).read_text()
            self.assertNotRegex(source, r"(?:p_)?availability_(?:start|end)|availabilityStart|availabilityEnd")
            self.assertNotIn("showDatePicker", source)
            self.assertNotIn("showTimePicker", source)
        self.assertIn("'create_donation_with_images'", (lib / "donation_pages.dart").read_text())

    def test_mixed_state_guard_is_locked_audited_and_precedes_every_resolution(self):
        recon = body(SQL, "submit_claim_reconciliation")
        lock = recon.index("geolock_lock_listing_donations")
        inspect = recon.index("array_agg(distinct d.donation_status order by d.donation_status)")
        guard = recon.index("if cardinality(v_batch_states)>1 then")
        self.assertLess(lock, inspect)
        self.assertLess(inspect, guard)
        branch = recon[guard:recon.index("elsif v_values<2 then", guard)]
        self.assertIn("case_status='MANUAL_REVIEW'", branch)
        self.assertIn("'outcome','RECONCILIATION_REQUIRED'", branch)
        self.assertIn("MIXED_BATCH_DONATION_STATES", branch)
        for forbidden in ("update public.donations", "update public.hub_inventory",
                          "update public.hub_batches", "update public.listings",
                          "update public.donation_claims", "update public.claim_leases"):
            self.assertNotIn(forbidden, branch)
        self.assertLess(guard, recon.index("case_status='RESOLVED_COLLECTED'"))
        self.assertLess(guard, recon.index("case_status='RESOLVED_RELEASED'"))
        self.assertIn("'batch_donation_states',to_jsonb(v_batch_states)", recon)
        self.assertIn("set response=v_result where request_id=p_request", recon)
        self.assertLess(recon.index("return v_prior.response"), guard)

    def test_negative_evidence_cannot_release_physical_progress_or_route_activity(self):
        recon = body(SQL, "submit_claim_reconciliation")
        release = recon[recon.index("if v_t.task_status='CONFIRMED'"):]
        before_write = release.split("update public.donation_claims")[0]
        for contract in ("d.donation_status='CLAIMED'", "d.donation_status<>'CLAIMED'",
                         "hi.inventory_status='BATCHED'", "public.active_task_route_assignments",
                         "public.pickup_route_stops", "v_l.listing_expires_at>clock_timestamp()"):
            self.assertIn(contract, before_write)
        self.assertNotIn("d.donation_status='PICKUP_IN_PROGRESS'", before_write)
        self.assertNotIn("d.donation_status='COLLECTED'", before_write)
        self.assertIn("NO_HANDOVER_AFTER_PICKUP_STARTED_REQUIRES_REVIEW", release)


if __name__ == "__main__":
    unittest.main()
