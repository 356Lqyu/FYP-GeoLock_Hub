import inspect
import re
import unittest
from pathlib import Path
from uuid import UUID

from experiments.e2_claiming import e2_runner


ROOT = Path(__file__).resolve().parents[2]
DONATION_MIGRATION = ROOT / "supabase/migrations/20261027_persisted_donation_lifecycle.sql"
STAGE_B_FIXTURE = ROOT / "supabase/tests/stage8_stage_b_isolated_test.py"
SCHEMA_SNAPSHOT = ROOT / "geolock-v3-public-schema.sql"


def sql_function_body(path, signature, dollar_tag="$function$"):
    source = path.read_text(encoding="utf-8")
    start = source.index(signature)
    body_start = source.index("AS " + dollar_tag, start) + len("AS " + dollar_tag)
    body_end = source.index(dollar_tag + ";", body_start)
    return source[body_start:body_end]


class DonationItemFixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.donation_body = sql_function_body(
            DONATION_MIGRATION,
            "CREATE OR REPLACE FUNCTION public.create_and_validate_donation")
        stage_b = STAGE_B_FIXTURE.read_text(encoding="utf-8")
        category = re.search(
            r"INSERT INTO public\.donation_categories\(category_id,category_name,active_flag\)\s*"
            r"VALUES\('([^']+)'\s*,\s*'[^']+'\s*,\s*true\)", stage_b, re.I)
        if not category:
            raise AssertionError("Stage B active synthetic category seed was not found")
        cls.active_fixture_category = category.group(1)

    def test_fixture_satisfies_actual_sql_json_and_item_predicate(self):
        item = e2_runner.build_donation_item_fixture()
        body = self.donation_body
        required = {"category_id", "quantity", "unit_weight_kg", "item_name"}
        self.assertTrue(required.issubset(item))
        self.assertIn("v_category:=(v_item->>'category_id')::uuid", body)
        self.assertIn("v_qty:=(v_item->>'quantity')::integer", body)
        self.assertIn("v_unit:=(v_item->>'unit_weight_kg')::numeric", body)
        self.assertIn("nullif(btrim(v_item->>'item_name'),'') is null", body)
        self.assertIn("where category_id=v_category and active_flag", body)
        self.assertIn("jsonb_typeof(p_items) is distinct from 'array'", body)
        self.assertIn("jsonb_array_length(p_items)=0", body)

        UUID(item["category_id"])
        self.assertEqual(item["category_id"], self.active_fixture_category)
        self.assertIs(type(item["quantity"]), int)
        self.assertGreater(item["quantity"], 0)
        self.assertIsInstance(item["unit_weight_kg"], (int, float))
        self.assertGreater(item["unit_weight_kg"], 0)
        self.assertIsInstance(item["item_name"], str)
        self.assertTrue(item["item_name"].strip())

        # The actual lifecycle schema config fixes direct-pickup at 10 kg.
        schema = SCHEMA_SNAPSHOT.read_text(encoding="utf-8")
        self.assertRegex(schema, r"donation_direct_min_kg numeric\(12,3\) DEFAULT 10\.000")
        self.assertIn("v_path:=case when v_weight>=v_threshold then 'DIRECT_PICKUP'", body)
        self.assertEqual(item["quantity"] * item["unit_weight_kg"], 20)
        self.assertGreaterEqual(item["quantity"] * item["unit_weight_kg"], 10)

    def test_same_fixture_builder_serves_both_claim_conditions_and_lease_trials(self):
        listing_source = inspect.getsource(e2_runner.create_listing)
        contention_source = inspect.getsource(e2_runner.run_contention_trial)
        lease_source = inspect.getsource(e2_runner.run_lease_trial)
        self.assertIn("items = [build_donation_item_fixture()]", listing_source)
        self.assertIn("create_listing(meta, DATABASES[condition]", contention_source)
        self.assertIn("create_listing(meta, db, run_id, condition, scenario)", lease_source)
        self.assertIn('condition = "protected"', lease_source)

    def test_each_trial_gets_a_distinct_donation_request(self):
        one = e2_runner.fixture_uuid("review7", "donation-create", "review7-C2-T001")
        two = e2_runner.fixture_uuid("review7", "donation-create", "review7-C2-T002")
        self.assertNotEqual(one, two)
        self.assertIn('req = fixture_uuid(run_id, "donation-create", scenario_id)',
                      inspect.getsource(e2_runner.create_listing))


if __name__ == "__main__":
    unittest.main()
