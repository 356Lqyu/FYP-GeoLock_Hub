import re
import unittest
from pathlib import Path
from unittest.mock import patch

from experiments.e2_claiming import e2_runner


ROOT = Path(__file__).resolve().parents[2]
RPC_MIGRATION = ROOT / "supabase/migrations/20261027_persisted_donation_lifecycle.sql"


def production_rpc_body():
    source = RPC_MIGRATION.read_text(encoding="utf-8")
    start = source.index("CREATE OR REPLACE FUNCTION public.create_donation_with_images")
    body_start = source.index("AS $function$", start) + len("AS $function$")
    body_end = source.index("$function$;", body_start)
    return source[body_start:body_end]


def production_image_path_pattern(body, actor, request_id):
    match = re.search(r"v_path\s*!~\s*\((.*?)\)\s*or v_size", body, re.I | re.S)
    if not match:
        raise AssertionError("Production donation image path predicate was not found")
    literals = re.findall(r"'([^']*)'", match.group(1))
    if len(literals) != 3:
        raise AssertionError(f"Expected three SQL regex fragments, found {len(literals)}")
    return literals[0] + re.escape(actor) + literals[1] + re.escape(request_id) + literals[2]


class SyntheticDonationImageFixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.body = production_rpc_body()

    def test_generated_fixture_matches_actual_rpc_image_validation(self):
        run_id = "image-contract-run"
        condition = "protected"
        scenario = "image-contract-C2-T001"
        request_id = e2_runner.fixture_uuid(run_id, "donation-create", scenario)
        image, obj = e2_runner.build_donation_image_fixture(run_id, condition, scenario, request_id)
        images = [image]

        pattern = production_image_path_pattern(self.body, e2_runner.DONOR, request_id)
        self.assertRegex(image["storage_path"], pattern)
        self.assertIn("jsonb_typeof(p_images) is distinct from 'array'", self.body)
        count_range = re.search(
            r"jsonb_array_length\(p_images\)\s+not\s+between\s+(\d+)\s+and\s+(\d+)",
            self.body, re.I)
        self.assertIsNotNone(count_range)
        min_images, max_images = map(int, count_range.groups())
        self.assertTrue(min_images <= len(images) <= max_images)
        self.assertIn("v_path:=v_image->>'storage_path'", self.body)
        self.assertIn("v_type:=v_image->>'content_type'", self.body)
        self.assertIn("v_size:=nullif(v_image->>'size_bytes','')::integer", self.body)
        self.assertEqual(image["content_type"], e2_runner.DONATION_IMAGE_CONTENT_TYPE)
        self.assertEqual(image["size_bytes"], e2_runner.DONATION_IMAGE_SIZE_BYTES)

        size_range = re.search(r"v_size\s+not\s+between\s+(\d+)\s+and\s+(\d+)", self.body, re.I)
        self.assertIsNotNone(size_range)
        minimum, maximum = map(int, size_range.groups())
        self.assertTrue(minimum <= image["size_bytes"] <= maximum)
        allowed_types = re.search(r"v_type\s+not\s+in\s*\(([^)]*)\)", self.body, re.I)
        self.assertIsNotNone(allowed_types)
        self.assertIn(image["content_type"], re.findall(r"'([^']+)'", allowed_types.group(1)))
        self.assertIn("(v_ext in ('jpg','jpeg') and v_type<>'image/jpeg')", self.body)
        self.assertTrue(image["storage_path"].endswith(".jpg"))

        bucket = re.search(r"where o\.bucket_id='([^']+)' and o\.name=v_path", self.body, re.I)
        self.assertIsNotNone(bucket)
        self.assertEqual(obj["bucket_id"], bucket.group(1))
        self.assertEqual(obj["name"], image["storage_path"])
        self.assertIn("o.metadata->>'size'", self.body)
        self.assertIn("o.metadata->>'mimetype'", self.body)
        self.assertEqual(obj["metadata"], {
            "size": image["size_bytes"], "mimetype": image["content_type"]})
        self.assertIn("STAGED_DONATION_IMAGE_MISSING_OR_MISMATCHED_%", self.body)

    def test_image_paths_are_unique_across_trials_and_conditions(self):
        fixtures = []
        for condition in ("non-atomic", "protected"):
            for trial in (1, 2):
                scenario = f"run-C2-T{trial:03d}"
                request_id = e2_runner.fixture_uuid("run", "donation-create", scenario)
                image, _ = e2_runner.build_donation_image_fixture("run", condition, scenario, request_id)
                fixtures.append(image["storage_path"])
        self.assertEqual(len(fixtures), len(set(fixtures)))

    def test_failed_rpc_triggers_exact_staged_image_cleanup(self):
        class SimulatedRpcFailure(Exception):
            pass

        class Cursor:
            def __enter__(self): return self
            def __exit__(self, *_args): return False
            def execute(self, sql, _params=None):
                if "create_donation_with_images" in sql:
                    raise SimulatedRpcFailure("fixture RPC rejected")
            def fetchone(self): return ("unused",)

        class Connection:
            def __init__(self): self.closed = False
            def cursor(self): return Cursor()
            def close(self): self.closed = True

        paths = []
        rpc_conn = Connection()
        with patch.object(e2_runner, "ensure_synthetic_donor"), \
             patch.object(e2_runner.psycopg, "connect") as connect, \
             patch.object(e2_runner, "role_connection", return_value=rpc_conn), \
             patch.object(e2_runner, "cleanup_unattached_staged_image",
                          side_effect=lambda _meta, _db, path: paths.append(path)):
            connect.return_value.__enter__.return_value.cursor.return_value.__enter__.return_value = Cursor()
            with self.assertRaises(SimulatedRpcFailure):
                e2_runner.create_listing({"port": 55432}, "geolock_e2_nonatomic",
                                         "cleanup-run", "non-atomic", "cleanup-C2-T001")
        self.assertEqual(len(paths), 1)
        self.assertIn("/pending/", paths[0])
        self.assertTrue(rpc_conn.closed)


if __name__ == "__main__":
    unittest.main()
