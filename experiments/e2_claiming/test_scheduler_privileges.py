import unittest
import inspect
from unittest.mock import patch

from experiments.e2_claiming import e2_runner


class FakeCursor:
    def __init__(self, rows):
        self.rows = list(rows)
        self.statements = []

    def __enter__(self): return self
    def __exit__(self, *_args): return False

    def execute(self, sql, params=None):
        self.statements.append((" ".join(sql.split()), params))

    def fetchone(self):
        return self.rows.pop(0)


class FakeConnection:
    def __init__(self, cursor):
        self.fake_cursor = cursor

    def __enter__(self): return self
    def __exit__(self, *_args): return False
    def cursor(self): return self.fake_cursor
    def close(self): pass


class SchedulerPrivilegeTests(unittest.TestCase):
    def test_scheduler_uses_login_membership_and_service_role_context(self):
        setup_source = inspect.getsource(e2_runner.setup)
        connection_source = inspect.getsource(e2_runner.role_connection)
        self.assertIn("CREATE ROLE e2_scheduler LOGIN", setup_source)
        self.assertIn("GRANT service_role TO e2_scheduler", setup_source)
        self.assertIn('user = "e2_scheduler" if service else "e2_worker"', connection_source)
        self.assertIn('"SET ROLE service_role" if service', connection_source)
        self.assertIn('"service_role" if service else "authenticated"', connection_source)

    def test_scheduler_identity_and_effective_privileges_are_checked(self):
        row = ("e2_scheduler", "service_role", "service_role", None, True,
               True, True, True, True)
        cursor = FakeCursor([row])
        evidence = e2_runner.verify_scheduler_authority(FakeConnection(cursor), "geolock_e2_atomic")
        self.assertTrue(all(x["status"] == "PASS" for x in evidence["checks"]))
        sql = cursor.statements[0][0]
        for token in ("session_user", "current_user", "auth.role()", "pg_has_role",
                      "has_schema_privilege", "has_function_privilege"):
            self.assertIn(token, sql)

    def test_scheduler_preflight_rejects_missing_public_schema_usage(self):
        row = ("e2_scheduler", "service_role", "service_role", None, True,
               False, False, True, True)
        with self.assertRaisesRegex(RuntimeError, "Scheduler authority preflight failed"):
            e2_runner.verify_scheduler_authority(FakeConnection(FakeCursor([row])),
                                                 "geolock_e2_nonatomic")

    def test_setup_uses_only_scoped_local_service_role_schema_grant(self):
        admin_cursor = FakeCursor([(False, True)])
        admin_conn = FakeConnection(admin_cursor)
        scheduler_row = ("e2_scheduler", "service_role", "service_role", None, True,
                         True, True, True, True)
        scheduler_cursor = FakeCursor([scheduler_row])
        scheduler_conn = FakeConnection(scheduler_cursor)

        with patch.object(e2_runner.psycopg, "connect", return_value=admin_conn), \
             patch.object(e2_runner, "role_connection", return_value=scheduler_conn):
            evidence = e2_runner.prepare_scheduler_privileges(
                {"port": 55432}, "geolock_e2_atomic")

        grant_statements = [sql for sql, _ in admin_cursor.statements if sql.startswith("GRANT")]
        self.assertEqual(grant_statements, ["GRANT USAGE ON SCHEMA public TO service_role"])
        self.assertFalse(evidence["service_role_schema_usage_before_local_grant"])
        self.assertTrue(evidence["service_role_recovery_execute_before_local_grant"])
        self.assertTrue(all(x["status"] == "PASS" for x in evidence["checks"]))

    def test_service_scheduler_uses_empty_subject_and_keeps_service_role_claim(self):
        cursor = FakeCursor([])
        connection = FakeConnection(cursor)
        with patch.object(e2_runner.psycopg, "connect", return_value=connection):
            e2_runner.role_connection({"port": 55432}, "geolock_e2_atomic", None, service=True)
        self.assertIn(("SELECT set_config('request.jwt.claim.sub',%s,false)", ("",)),
                      cursor.statements)
        self.assertIn(("SELECT set_config('request.jwt.claim.role',%s,false)", ("service_role",)),
                      cursor.statements)
        recovery_source = inspect.getsource(e2_runner.call_recovery)
        self.assertIn("role_connection(meta, db, None, service=True)", recovery_source)


if __name__ == "__main__":
    unittest.main()
