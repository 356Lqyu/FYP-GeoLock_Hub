"""Phase 2 per-task lease admission (scenario contract v2) and v1 preservation.

v1 behaviour must be byte-for-byte unchanged (E4 and old sealed snapshots).
v2 admits a claim when earliest completion + margin < lease expiry; the
solver/validator then enforce completion + margin < expiry for each stop.
"""
from copy import deepcopy
import json
from pathlib import Path
import unittest

from backend.routing import ContractError, freeze_scenario
from backend.routing.contract import PER_TASK_LEASE_ADMISSION, VERSION, VERSION_V2
from backend.routing.generate_examples import build_mixed

FIXTURES = Path(__file__).resolve().parent / "fixtures"
# cutoff 00:05Z, horizon 240, margin 10, service 10, window 00:00-05:00 in build_mixed().


def v2(p):
    p = deepcopy(p)
    p["schema_version"] = VERSION_V2
    p["configuration"]["lease_admission"] = PER_TASK_LEASE_ADMISSION
    return p


def direct(p):
    return next(t for t in p["tasks"] if t["task_id"] == "TOY-DIRECT")


class LeaseAdmissionV2Tests(unittest.TestCase):
    def setUp(self):
        self.p = build_mixed()

    def reasons(self, snapshot, tid="TOY-DIRECT"):
        return dict(snapshot.excluded_tasks).get(tid, ())

    def test_v1_short_lease_still_excluded_whole_horizon(self):
        direct(self.p)["lease_expires_at"] = "2026-10-24T02:00:00Z"  # 115 min left < 250
        s = freeze_scenario(self.p)
        self.assertIn("INSUFFICIENT_LEASE_TIME", self.reasons(s))

    def test_v2_admits_lease_below_255_minutes_when_pickup_fits(self):
        p = v2(self.p)
        direct(p)["lease_expires_at"] = "2026-10-24T02:00:00Z"
        s = freeze_scenario(p)
        self.assertIn("TOY-DIRECT", s.admitted_task_ids)
        self.assertEqual(s.to_dict()["input"]["schema_version"], VERSION_V2)

    def test_v2_lower_bound_boundary_is_strict(self):
        # earliest completion = 00:05 + 10 min service; + 10 min margin = 00:25.
        for expiry, admitted in (("2026-10-24T00:25:00Z", False), ("2026-10-24T00:25:00.000001Z", True),
                                 ("2026-10-24T00:24:59Z", False), ("2026-10-24T00:05:00Z", False)):
            p = v2(self.p)
            direct(p)["lease_expires_at"] = expiry
            s = freeze_scenario(p)
            self.assertEqual("TOY-DIRECT" in s.admitted_task_ids, admitted, expiry)
            if not admitted:
                self.assertTrue({"LEASE_TOO_SHORT_FOR_SERVICE", "LEASE_EXPIRED"} & set(self.reasons(s)), expiry)

    def test_v2_uses_window_start_for_lower_bound(self):
        p = v2(self.p)
        t = direct(p)
        t["time_window"]["start"] = "2026-10-24T01:00:00Z"
        t["lease_expires_at"] = "2026-10-24T01:20:00Z"  # 01:00+10+10 = 01:20 -> not strictly before
        self.assertIn("LEASE_TOO_SHORT_FOR_SERVICE", self.reasons(freeze_scenario(p)))
        t["lease_expires_at"] = "2026-10-24T01:21:00Z"
        self.assertIn("TOY-DIRECT", freeze_scenario(p).admitted_task_ids)

    def test_v2_listing_expiry_no_longer_whole_horizon(self):
        p = v2(self.p)
        direct(p)["listing_expires_at"] = "2026-10-24T03:00:00Z"
        self.assertNotIn("LISTING_EXPIRES_BEFORE_HORIZON", self.reasons(freeze_scenario(p)))
        q = deepcopy(self.p)
        direct(q)["listing_expires_at"] = "2026-10-24T03:00:00Z"
        self.assertIn("LISTING_EXPIRES_BEFORE_HORIZON", self.reasons(freeze_scenario(q)))

    def test_v2_keeps_every_other_admission_rule(self):
        for field, value, reason in (("task_status", "PLANNED", "TASK_NOT_CONFIRMED"),
                                     ("claim_status", "RELEASED", "INVALID_AUTHORITY"),
                                     ("has_route_assignment", True, "TASK_ALREADY_ASSIGNED")):
            p = v2(self.p)
            direct(p)[field] = value
            self.assertIn(reason, self.reasons(freeze_scenario(p)), field)

    def test_contract_versions_are_strict(self):
        p = v2(self.p)
        del p["configuration"]["lease_admission"]
        with self.assertRaises(ContractError) as e:
            freeze_scenario(p)
        self.assertEqual(e.exception.code, "INVALID_FIELDS")
        q = deepcopy(self.p)
        q["configuration"]["lease_admission"] = PER_TASK_LEASE_ADMISSION  # v1 must not accept it
        with self.assertRaises(ContractError):
            freeze_scenario(q)
        r = v2(self.p)
        r["configuration"]["lease_admission"] = "WHOLE_HORIZON"
        with self.assertRaises(ContractError):
            freeze_scenario(r)

    def test_v1_fixtures_are_unchanged(self):
        """Old sealed inputs replay under v1 with the same canonical digest."""
        for path in sorted(FIXTURES.glob("*.json")):
            payload = json.loads(path.read_text())
            self.assertEqual(payload["schema_version"], VERSION, path.name)
            first = freeze_scenario(payload)
            second = freeze_scenario(json.loads(path.read_text()))
            self.assertEqual(first.sha256, second.sha256, path.name)


if __name__ == "__main__":
    unittest.main()
