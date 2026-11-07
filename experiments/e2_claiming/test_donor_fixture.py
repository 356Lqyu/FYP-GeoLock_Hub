import unittest
from unittest.mock import patch

from experiments.e2_claiming import e2_runner


class FakeCursor:
    def __init__(self, verification=(True, True, True, True, True)):
        self.statements = []
        self.verification = verification

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False

    def execute(self, sql, params=None):
        self.statements.append((" ".join(sql.split()), params))

    def fetchone(self):
        return self.verification


class FakeConnection:
    def __init__(self, cursor):
        self.fake_cursor = cursor

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False

    def cursor(self):
        return self.fake_cursor


class SyntheticDonorFixtureTests(unittest.TestCase):
    def test_initializes_auth_user_then_role_profile_then_donor_profile(self):
        cursor = FakeCursor()
        with patch.object(e2_runner.psycopg, "connect", return_value=FakeConnection(cursor)):
            e2_runner.ensure_synthetic_donor({"port": 55432}, "geolock_e2_atomic", "unit-run")

        sql = [statement for statement, _ in cursor.statements]
        self.assertIn("INSERT INTO auth.users", sql[0])
        self.assertIn("ON CONFLICT(id) DO NOTHING", sql[0])
        self.assertIn("INSERT INTO public.user_profiles", sql[1])
        self.assertIn("'DONOR'", sql[1])
        self.assertIn("INSERT INTO public.donor_profiles", sql[2])
        self.assertIn("'DONOR'", sql[2])
        self.assertIn("SELECT EXISTS(SELECT 1 FROM auth.users", sql[3])
        self.assertIn("user_id", sql[3])
        self.assertEqual(cursor.statements[0][1][0], e2_runner.DONOR)
        self.assertEqual(cursor.statements[1][1][0], e2_runner.DONOR)
        self.assertEqual(cursor.statements[2][1][0], e2_runner.DONOR)

    def test_rejects_missing_or_role_inconsistent_donor_rows(self):
        cursor = FakeCursor(verification=(True, False, False, True, True))
        with patch.object(e2_runner.psycopg, "connect", return_value=FakeConnection(cursor)):
            with self.assertRaisesRegex(RuntimeError, "Synthetic donor fixture is inconsistent"):
                e2_runner.ensure_synthetic_donor({"port": 55432}, "geolock_e2_nonatomic", "unit-run")

    def test_setup_seeds_donor_in_both_isolated_databases(self):
        calls = []
        with patch.object(e2_runner, "ensure_synthetic_donor",
                          side_effect=lambda _meta, db, run_id: calls.append((db, run_id))):
            e2_runner.initialize_synthetic_donors({"port": 55432}, "unit-run")
        self.assertEqual(calls, [
            ("geolock_e2_atomic", "unit-run"),
            ("geolock_e2_nonatomic", "unit-run"),
        ])

    def test_listing_creation_initializes_donor_before_any_database_write(self):
        class DonorReady(Exception):
            pass

        order = []
        def ensure(*_args):
            order.append("donor")
            raise DonorReady()
        def connect(*_args, **_kwargs):
            order.append("database_write")
            raise AssertionError("Database access happened before donor fixture setup")

        with patch.object(e2_runner, "ensure_synthetic_donor", side_effect=ensure), \
             patch.object(e2_runner.psycopg, "connect", side_effect=connect):
            with self.assertRaises(DonorReady):
                e2_runner.create_listing({"port": 55432}, "geolock_e2_atomic",
                                         "unit-run", "protected", "scenario")
        self.assertEqual(order, ["donor"])


if __name__ == "__main__":
    unittest.main()
