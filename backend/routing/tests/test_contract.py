from copy import deepcopy
from dataclasses import FrozenInstanceError
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from backend.routing import ContractError, freeze_scenario, load_scenario
from backend.routing.generate_examples import build_mixed, examples, EXAMPLES


class InputContractTests(unittest.TestCase):
    def setUp(self):
        self.p = build_mixed()

    def reject(self, code):
        with self.assertRaises(ContractError) as caught:
            freeze_scenario(self.p)
        self.assertEqual(caught.exception.code, code)

    def exclusion(self, reason):
        snapshot = freeze_scenario(self.p)
        reasons = dict(snapshot.excluded_tasks)["TOY-DIRECT"]
        self.assertIn(reason, reasons)
        self.assertNotIn("TOY-DIRECT", snapshot.admitted_task_ids)

    def test_mixed_direct_and_hub_share_one_snapshot(self):
        s = freeze_scenario(self.p)
        self.assertEqual(s.readiness, "READY_FOR_PLANNING")
        self.assertEqual(s.admitted_task_ids, ("TOY-DIRECT", "TOY-HUB-TASK"))
        self.assertEqual(len(s.available_vehicle_ids), 2)
        self.assertFalse(s.to_dict()["dispatch_authority_issued"])

    def test_all_generated_examples_have_expected_outcome(self):
        expected = {"mixed": "READY_FOR_PLANNING", "direct_only": "READY_FOR_PLANNING",
                    "hub_only": "READY_FOR_PLANNING", "no_vehicles": "NO_FEASIBLE_PLAN",
                    "expired_claim": "NO_VALID_TASKS", "unreachable": "ROUTE_UNAVAILABLE",
                    "missing_edge": "ROUTE_UNAVAILABLE", "reconciliation": "NO_VALID_TASKS",
                    "no_tasks": "NO_VALID_TASKS"}
        for name, payload in examples().items():
            with self.subTest(name=name):
                self.assertEqual(freeze_scenario(payload).readiness, expected[name])
                self.assertEqual(json.loads((EXAMPLES/(name+".json")).read_text()), payload)

    def test_unknown_schema_version(self):
        self.p["schema_version"] = "v999"
        self.reject("INVALID_VALUE")

    def test_missing_required_field(self):
        del self.p["vehicles"][0]["capacity_kg"]
        self.reject("INVALID_FIELDS")

    def test_unexpected_field_cannot_supply_dispatch_authority(self):
        self.p["dispatch_authority_issued"] = True
        self.reject("INVALID_FIELDS")

    def test_synthetic_fixture_cannot_claim_dev_provenance(self):
        self.p["source"]["project_ref"] = "rcgyuwiidqvrgbxswhqj"
        self.reject("INVALID_PROJECT_SCOPE")

    def test_shared_project_scope_rejected(self):
        self.p["source"]["kind"] = "OPERATIONAL_SNAPSHOT"
        self.p["source"]["project_ref"] = "some-shared-project"
        self.reject("INVALID_PROJECT_SCOPE")

    def test_operational_input_cannot_use_synthetic_matrix(self):
        self.p["source"].update(kind="OPERATIONAL_SNAPSHOT", project_ref="rcgyuwiidqvrgbxswhqj")
        self.reject("MATRIX_PROVENANCE_MISMATCH")

    def test_depot_return_required(self):
        self.p["route_end_location_id"] = "TOY-HUB"
        self.reject("INVALID_DEPOT")

    def test_inactive_ngo_and_unverified_depot_rejected(self):
        self.p["ngo_active"] = False
        self.reject("INACTIVE_NGO")
        self.p = build_mixed()
        self.p["ngo_location_verified_at"] = "2026-10-25T00:00:00Z"
        self.reject("UNVERIFIED_DEPOT")

    def test_location_and_matrix_must_use_same_road_snapshot(self):
        self.p["depot"]["network_snapshot_id"] = "OLD-NETWORK"
        self.reject("ROAD_SNAPSHOT_MISMATCH")

    def test_foreign_vehicle_rejected(self):
        self.p["vehicles"][0]["ngo_id"] = "OTHER-NGO"
        self.reject("FOREIGN_VEHICLE")

    def test_wrong_vehicle_depot_rejected(self):
        self.p["vehicles"][0]["depot_location_id"] = "TOY-HUB"
        self.reject("INVALID_DEPOT")

    def test_unavailable_fleet_has_no_invented_vehicle(self):
        for v in self.p["vehicles"]:
            v["available_for_planning"] = False
        s = freeze_scenario(self.p)
        self.assertEqual(s.available_vehicle_ids, ())
        self.assertEqual(s.readiness, "NO_FEASIBLE_PLAN")

    def test_inactive_fleet_cannot_plan(self):
        for v in self.p["vehicles"]:
            v["active"] = False
        self.assertEqual(freeze_scenario(self.p).readiness, "NO_FEASIBLE_PLAN")

    def test_numeric_boolean_nan_infinity_and_negative_are_rejected(self):
        for value in (True, float("nan"), float("inf"), -1, 0, "40", 10**1000):
            with self.subTest(value=str(value)[:30]):
                self.p = build_mixed()
                self.p["vehicles"][0]["capacity_kg"] = value
                self.reject("INVALID_NUMBER")

    def test_costs_cannot_be_negative(self):
        self.p["vehicles"][0]["fixed_cost"] = -1
        self.reject("INVALID_NUMBER")

    def test_zero_explicit_cost_is_valid(self):
        self.p["vehicles"][0]["fixed_cost"] = 0
        self.p["vehicles"][0]["distance_cost_per_km"] = 0
        self.assertEqual(freeze_scenario(self.p).readiness, "READY_FOR_PLANNING")

    def test_vehicle_horizon_cannot_exceed_lease_admission_horizon(self):
        self.p["vehicles"][0]["max_route_minutes"] = 300
        self.reject("INVALID_ROUTE_HORIZON")

    def test_foreign_task_and_claim_are_excluded(self):
        for field in ("ngo_id", "claim_ngo_id"):
            with self.subTest(field=field):
                self.p = build_mixed()
                self.p["tasks"][0][field] = "OTHER-NGO"
                self.exclusion("FOREIGN_OWNER")

    def test_nonconfirmed_tasks_are_excluded(self):
        for status in ("PLANNED", "DISPATCHED", "COLLECTED", "STALE", "CANCELLED"):
            with self.subTest(status=status):
                self.p = build_mixed()
                self.p["tasks"][0]["task_status"] = status
                self.exclusion("TASK_NOT_CONFIRMED")

    def test_closed_authority_is_excluded(self):
        for key in ("claim_status", "lease_status"):
            for status in ("RELEASED", "EXPIRED", "COMPLETED", "RECONCILIATION_REQUIRED"):
                with self.subTest(key=key, status=status):
                    self.p = build_mixed()
                    self.p["tasks"][0][key] = status
                    self.exclusion("INVALID_AUTHORITY")

    def test_expiry_at_cutoff_is_expired(self):
        self.p["tasks"][0]["lease_expires_at"] = self.p["cutoff"]
        self.exclusion("LEASE_EXPIRED")

    def test_expiry_at_horizon_plus_margin_is_insufficient(self):
        self.p["tasks"][0]["lease_expires_at"] = "2026-10-24T04:15:00Z"
        self.exclusion("INSUFFICIENT_LEASE_TIME")

    def test_lease_one_second_beyond_horizon_is_admitted(self):
        self.p["tasks"][0]["lease_expires_at"] = "2026-10-24T04:15:01Z"
        self.assertIn("TOY-DIRECT", freeze_scenario(self.p).admitted_task_ids)

    def test_task_transaction_timestamp_may_precede_lease_clock_timestamp(self):
        self.p["tasks"][0]["created_at"] = "2026-10-23T23:59:59Z"
        self.assertIn("TOY-DIRECT", freeze_scenario(self.p).admitted_task_ids)

    def test_future_task_excluded(self):
        self.p["tasks"][0]["created_at"] = "2026-10-24T00:06:00Z"
        self.exclusion("AFTER_CUTOFF")

    def test_reconciliation_and_route_assignment_block_admission(self):
        for key, reason in (("reconciliation_blocked", "RECONCILIATION_REQUIRED"),
                            ("has_route_assignment", "TASK_ALREADY_ASSIGNED")):
            with self.subTest(key=key):
                self.p = build_mixed()
                self.p["tasks"][0][key] = True
                self.exclusion(reason)

    def test_wrong_donor_pickup_excluded(self):
        self.p["tasks"][0]["pickup"]["latitude"] += .1
        self.exclusion("PICKUP_LOCATION_MISMATCH")

    def test_weight_changed_from_listing_excluded(self):
        self.p["tasks"][0]["weight_kg"] = 31
        self.exclusion("WEIGHT_MISMATCH")

    def test_listing_expiry_blocks_horizon(self):
        self.p["tasks"][0]["listing_expires_at"] = "2026-10-24T01:00:00Z"
        self.exclusion("LISTING_EXPIRES_BEFORE_HORIZON")

    def test_obsolete_donation_states_rejected(self):
        for value in ("READY_FOR_PICKUP", "DRAFT", "VALIDATED", "DELIVERED"):
            with self.subTest(value=value):
                self.p = build_mixed()
                self.p["tasks"][0]["donations"][0]["donation_status"] = value
                self.reject("INVALID_VALUE")

    def test_allowed_but_unclaimed_donation_excluded(self):
        self.p["tasks"][0]["donations"][0]["donation_status"] = "AVAILABLE"
        self.exclusion("DONATION_NOT_CLAIMED")

    def test_hub_batch_must_remain_published(self):
        self.p["tasks"][1]["batch"]["batch_status"] = "CLAIMED"
        reasons = dict(freeze_scenario(self.p).excluded_tasks)["TOY-HUB-TASK"]
        self.assertIn("BATCH_NOT_READY", reasons)

    def test_hub_is_pickup_and_not_depot(self):
        self.p["tasks"][1]["authorized_pickup"] = deepcopy(self.p["depot"])
        self.reject("WRONG_HUB_PICKUP")

    def test_partial_batch_member_set_rejected(self):
        self.p["tasks"][1]["donations"].pop()
        self.reject("BATCH_MEMBER_MISMATCH")

    def test_duplicate_tasks_and_overlapping_donations_rejected(self):
        self.p["tasks"].append(deepcopy(self.p["tasks"][0]))
        self.reject("DUPLICATE_ID")
        self.p = build_mixed()
        self.p["tasks"][1]["donations"][0]["donation_id"] = self.p["tasks"][0]["donations"][0]["donation_id"]
        self.reject("DUPLICATE_ID")

    def test_missing_state_token_is_not_invented(self):
        self.p["tasks"][0]["task_state_token"] = "version1"
        self.reject("INVALID_STATE_TOKEN")

    def test_naive_time_rejected(self):
        self.p["cutoff"] = "2026-10-24T00:05:00"
        self.reject("INVALID_TIMESTAMP")

    def test_invalid_window_rejected(self):
        w = self.p["tasks"][0]["time_window"]
        w["end"] = w["start"]
        self.reject("INVALID_TIME_WINDOW")

    def test_closed_service_window_excluded(self):
        self.p["tasks"][0]["time_window"]["end"] = "2026-10-24T00:06:00Z"
        self.exclusion("TIME_WINDOW_CLOSED")

    def test_matrix_is_directed_and_not_symmetrized(self):
        s = freeze_scenario(self.p)
        m = s.to_dict()["input"]["matrix"]
        self.assertEqual(m["distance_km"][0][2], 5)
        self.assertEqual(m["distance_km"][2][0], 6)
        self.assertEqual(m["travel_minutes"][0][2], 10)

    def test_matrix_node_omission_rejected(self):
        self.p["matrix"]["node_order"][1] = "WRONG-NODE"
        self.reject("MISSING_MATRIX_NODE")

    def test_ragged_matrix_rejected(self):
        self.p["matrix"]["travel_minutes"][0].pop()
        self.reject("INVALID_MATRIX_SHAPE")

    def test_null_cannot_silently_become_zero_or_unreachable(self):
        self.p["matrix"]["distance_km"][0][1] = None
        self.reject("INVALID_NUMBER")

    def test_zero_off_diagonal_is_not_a_missing_edge_substitute(self):
        self.p["matrix"]["distance_km"][0][1] = 0
        self.reject("INVALID_NUMBER")

    def test_unavailable_distance_and_time_must_both_be_null(self):
        self.p["matrix"]["arc_status"][0][1] = "MISSING"
        self.reject("INVALID_UNAVAILABLE_ARC")

    def test_nonzero_diagonal_rejected(self):
        self.p["matrix"]["distance_km"][0][0] = 1
        self.reject("INVALID_MATRIX_DIAGONAL")

    def test_forbid_arc_preserves_failure_data_without_claiming_feasibility(self):
        self.p = examples()["unreachable"]
        self.p["matrix"]["unavailable_policy"] = "FORBID_ARC"
        s = freeze_scenario(self.p)
        self.assertEqual(s.readiness, "READY_FOR_PLANNING")
        self.assertIn(("TOY-DEPOT", "TOY-HUB", "UNREACHABLE"), s.unavailable_arcs)
        self.assertEqual(len(s.unavailable_arcs), 4)
        self.assertIsNone(s.to_dict()["input"]["matrix"]["distance_km"][0][2])

    def test_hashes_change_with_matrix_cost_window_and_version(self):
        original = freeze_scenario(self.p)
        changes = [("matrix", "version", "2"), ("configuration", "version", "changed")]
        for section, field, value in changes:
            p = deepcopy(self.p)
            p[section][field] = value
            self.assertNotEqual(freeze_scenario(p).sha256, original.sha256)
        p = deepcopy(self.p)
        p["matrix"]["travel_minutes"][0][1] += 1
        self.assertNotEqual(freeze_scenario(p).matrix_sha256, original.matrix_sha256)
        p = deepcopy(self.p)
        p["vehicles"][0]["fixed_cost"] += 1
        self.assertNotEqual(freeze_scenario(p).sha256, original.sha256)

    def test_same_frozen_input_for_four_future_consumers(self):
        original = freeze_scenario(self.p)
        hashes = []
        for _method in ("fcfs", "nearest", "distance_only", "proposed"):
            own_copy = original.to_dict()["input"]
            hashes.append(freeze_scenario(own_copy).sha256)
            own_copy["tasks"].clear()
        self.assertEqual(hashes, [original.sha256]*4)
        self.assertEqual(len(original.to_dict()["input"]["tasks"]), 2)

    def test_caller_mutations_and_record_order_do_not_change_frozen_data(self):
        frozen = freeze_scenario(self.p)
        self.p["tasks"].reverse()
        self.p["vehicles"].reverse()
        self.assertEqual(freeze_scenario(self.p).sha256, frozen.sha256)
        self.p["tasks"].clear()
        self.assertEqual(len(frozen.to_dict()["input"]["tasks"]), 2)
        with self.assertRaises(FrozenInstanceError):
            frozen.readiness = "DISPATCHED"

    def test_duplicate_json_keys_and_nonfinite_literals_rejected(self):
        for text, code in [('{"tasks":[],"tasks":[]}', "DUPLICATE_JSON_KEY"),
                           ('{"value":NaN}', "INVALID_NUMBER"),
                           ('{"value":Infinity}', "INVALID_NUMBER")]:
            with tempfile.TemporaryDirectory() as folder:
                path = Path(folder)/"input.json"
                path.write_text(text)
                with self.assertRaises(ContractError) as caught:
                    load_scenario(path)
                self.assertEqual(caught.exception.code, code)

    def test_cli_returns_typed_status_without_dispatch(self):
        for name, code, status in [("mixed", 0, "READY_FOR_PLANNING"),
                                   ("no_vehicles", 1, "NO_FEASIBLE_PLAN")]:
            result = subprocess.run([sys.executable, "-m", "backend.routing", str(EXAMPLES/(name+".json"))],
                                    capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, code, result.stderr)
            out = json.loads(result.stdout)
            self.assertEqual(out["status"], status)
            self.assertFalse(out["dispatch_authority_issued"])


if __name__ == "__main__":
    unittest.main()
