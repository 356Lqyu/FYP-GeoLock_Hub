"""Run the NGO field-removal migration and role RPCs in disposable local PG17."""
from pathlib import Path
import os
import re
import shutil
import socket
import subprocess
import tempfile
import unittest
import uuid

import psycopg


ROOT = Path(__file__).resolve().parents[2]
MIGRATION = ROOT / "supabase/migrations/20261103_remove_ngo_registration_number.sql"
BASELINE = ROOT / "supabase/migrations/20261022_role_onboarding_and_profile_management.sql"
DEFAULT_PG_BIN = Path(r"C:\Program Files\PostgreSQL\17\bin")
PG_BIN = Path(os.environ.get("GEOLOCK_PG_BIN", DEFAULT_PG_BIN))
FUNCTION_PATTERN = re.compile(
    r"CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION\s+public\."
    r"(register_role_profile|get_my_profile|update_my_profile)\s*"
    r"\((.*?)\)\s*(.*?)\bAS\s+(\$\w*\$)(.*?)\4\s*;",
    re.IGNORECASE | re.DOTALL,
)


def baseline_profile_functions():
    sql = BASELINE.read_text(encoding="utf-8")
    matches = {match.group(1).lower(): match.group(0) for match in FUNCTION_PATTERN.finditer(sql)}
    if set(matches) != {"register_role_profile", "get_my_profile", "update_my_profile"}:
        raise RuntimeError("EXACT_BASELINE_PROFILE_FUNCTIONS_REQUIRED")
    return matches


class NgoRegistrationNumberRemovalPostgresTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        for executable in ("initdb.exe", "pg_ctl.exe", "psql.exe"):
            if not (PG_BIN / executable).is_file():
                raise unittest.SkipTest(f"PostgreSQL 17 executable missing: {PG_BIN / executable}")
        cls.old_functions = baseline_profile_functions()

    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="geolock-ngo-ref-removal-")).resolve()
        self.assertEqual(self.root.parent, Path(tempfile.gettempdir()).resolve())
        self.marker = uuid.uuid4().hex
        (self.root / ".geolock-test-owner").write_text(self.marker, encoding="ascii")
        self.addCleanup(self._safe_cleanup)
        self.data = self.root / "data"
        self.log = self.root / "postgres.log"
        self.port = self._free_port()
        self.started = False
        self.env = os.environ.copy()
        self.env["PATH"] = str(PG_BIN) + os.pathsep + self.env.get("PATH", "")
        self.started = True
        self._run(
            [
                str(PG_BIN / "initdb.exe"),
                "-D",
                str(self.data),
                "-U",
                "postgres",
                "--no-locale",
                "--encoding=UTF8",
                "--auth-local=trust",
                "--auth-host=trust",
            ],
            timeout=60,
        )
        self._run(
            [
                str(PG_BIN / "pg_ctl.exe"),
                "-D",
                str(self.data),
                "-l",
                str(self.log),
                "-o",
                f"-h 127.0.0.1 -p {self.port} -c listen_addresses=127.0.0.1",
                "-w",
                "start",
            ],
            timeout=60,
        )
        self.conninfo = f"host=127.0.0.1 port={self.port} dbname=postgres user=postgres connect_timeout=3"
        self._install_baseline()
        self._run(
            [
                str(PG_BIN / "psql.exe"),
                "-X",
                "--no-password",
                "--set=ON_ERROR_STOP=1",
                "--host=127.0.0.1",
                f"--port={self.port}",
                "--username=postgres",
                "--dbname=postgres",
                "--file",
                str(MIGRATION),
            ],
            timeout=60,
        )

    def _safe_cleanup(self):
        if self.started and (self.data / "PG_VERSION").is_file():
            status = subprocess.run(
                [str(PG_BIN / "pg_ctl.exe"), "-D", str(self.data), "status"],
                env=self.env,
                capture_output=True,
                text=True,
                timeout=15,
            )
            if status.returncode == 0:
                stop = subprocess.run(
                    [str(PG_BIN / "pg_ctl.exe"), "-D", str(self.data), "-m", "fast", "-w", "stop"],
                    env=self.env,
                    capture_output=True,
                    text=True,
                    timeout=30,
                )
                if stop.returncode != 0:
                    raise RuntimeError(f"Owned disposable PostgreSQL cluster did not stop: {stop.stderr[-500:]}")
            self.started = False
        resolved = self.root.resolve()
        self.assertEqual(resolved.parent, Path(tempfile.gettempdir()).resolve())
        self.assertEqual((resolved / ".geolock-test-owner").read_text(encoding="ascii"), self.marker)
        shutil.rmtree(resolved)

    @staticmethod
    def _free_port():
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
            sock.bind(("127.0.0.1", 0))
            return sock.getsockname()[1]

    def _run(self, args, *, timeout):
        result = subprocess.run(
            args,
            env=self.env,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        if result.returncode != 0:
            raise AssertionError(
                f"Command failed ({result.returncode}): {Path(args[0]).name}\n"
                f"stdout:\n{result.stdout[-2500:]}\nstderr:\n{result.stderr[-2500:]}"
            )
        return result.stdout

    def _psql(self, sql, *, expect_error=None):
        args = [
            str(PG_BIN / "psql.exe"),
            "-X",
            "--no-password",
            "--set=ON_ERROR_STOP=1",
            "--host=127.0.0.1",
            f"--port={self.port}",
            "--username=postgres",
            "--dbname=postgres",
            "--command",
            sql,
        ]
        result = subprocess.run(args, env=self.env, capture_output=True, text=True, timeout=20)
        if expect_error:
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn(expect_error, result.stderr)
            return result.stderr
        if result.returncode != 0:
            self.fail(result.stderr)
        return result.stdout

    def _install_baseline(self):
        fixture = """
CREATE ROLE anon NOLOGIN;
CREATE ROLE authenticated NOLOGIN;
CREATE ROLE service_role NOLOGIN;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;
CREATE TABLE public.user_profiles(
  user_id uuid PRIMARY KEY, full_name text NOT NULL, phone_number text,
  role text NOT NULL, created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.ngo_profiles(
  user_id uuid PRIMARY KEY REFERENCES public.user_profiles(user_id),
  ngo_name text NOT NULL,
  registration_number text CONSTRAINT ngo_profiles_registration_number_key UNIQUE,
  operating_address text, latitude double precision, longitude double precision,
  road_node_id text, location_verified_at timestamptz
);
CREATE TABLE public.donor_profiles(user_id uuid PRIMARY KEY REFERENCES public.user_profiles(user_id));
CREATE TABLE public.hub_admin_profiles(user_id uuid PRIMARY KEY REFERENCES public.user_profiles(user_id));
CREATE TABLE public.community_hubs(
  hub_id uuid PRIMARY KEY, admin_user_id uuid, hub_name text, address_text text,
  latitude double precision, longitude double precision, road_node_id text,
  capacity_kg numeric, active_flag boolean, created_at timestamptz DEFAULT now()
);
CREATE TABLE public.audit_events(
  actor_user_id uuid, actor_role text, entity_type text, entity_id uuid,
  event_type text, requested_state text, resulting_state text, reason_code text,
  outcome text, details jsonb, request_id uuid
);
"""
        self._psql(fixture)
        for name in ("register_role_profile", "get_my_profile", "update_my_profile"):
            self._psql(self.old_functions[name])
        for signature in (
            "public.register_role_profile(text,text,text,text,text,text,double precision,double precision,text)",
            "public.update_my_profile(text,text,text,text)",
        ):
            self._psql(f"REVOKE ALL ON FUNCTION {signature} FROM PUBLIC, anon; GRANT EXECUTE ON FUNCTION {signature} TO authenticated, service_role;")
        self._psql(
            "INSERT INTO public.user_profiles(user_id,full_name,role) "
            "VALUES('11111111-1111-4111-8111-111111111111','Existing NGO','NGO'); "
            "INSERT INTO public.ngo_profiles(user_id,ngo_name) "
            "VALUES('11111111-1111-4111-8111-111111111111','Existing Organization');"
        )

    def test_migration_preserves_auth_roles_and_profile_contract(self):
        with psycopg.connect(self.conninfo) as conn:
            result = conn.execute(
                "SELECT to_regprocedure('public.register_role_profile(text,text,text,text,text,double precision,double precision,text)') IS NOT NULL, "
                "to_regprocedure('public.register_role_profile(text,text,text,text,text,text,double precision,double precision,text)') IS NULL, "
                "to_regprocedure('public.update_my_profile(text,text,text)') IS NOT NULL, "
                "to_regprocedure('public.update_my_profile(text,text,text,text)') IS NULL, "
                "NOT EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='ngo_profiles' AND column_name='registration_number'), "
                "has_function_privilege('authenticated','public.register_role_profile(text,text,text,text,text,double precision,double precision,text)','EXECUTE'), "
                "has_function_privilege('service_role','public.register_role_profile(text,text,text,text,text,double precision,double precision,text)','EXECUTE'), "
                "NOT has_function_privilege('anon','public.register_role_profile(text,text,text,text,text,double precision,double precision,text)','EXECUTE')"
            ).fetchone()
            self.assertEqual(result, (True, True, True, True, True, True, True, True))
            ngo_count = conn.execute("SELECT count(*) FROM public.ngo_profiles").fetchone()[0]
            self.assertEqual(ngo_count, 1)
            location_columns = conn.execute(
                "SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name='ngo_profiles' "
                "AND column_name IN ('operating_address','latitude','longitude','road_node_id','location_verified_at')"
            ).fetchone()[0]
            self.assertEqual(location_columns, 5)

            conn.execute("SET ROLE authenticated")
            ngo_id = "22222222-2222-4222-8222-222222222222"
            conn.execute("SELECT set_config('request.jwt.claim.sub', %s, false)", (ngo_id,))
            created = conn.execute(
                "SELECT public.register_role_profile(%s,%s,%s,%s,%s,%s,%s,%s)",
                ("New User", "NGO", None, "New NGO", None, None, None, None),
            ).fetchone()[0]
            self.assertEqual(str(created), ngo_id)
            profile = conn.execute("SELECT public.get_my_profile()").fetchone()[0]
            self.assertEqual(profile["ngo_name"], "New NGO")
            self.assertNotIn("registration_number", profile)
            self.assertTrue(profile["ngo_location_setup_required"])
            updated = conn.execute(
                "SELECT public.update_my_profile(%s,%s,%s)",
                ("Updated User", None, "Updated NGO"),
            ).fetchone()[0]
            self.assertTrue(updated["updated"])
            self.assertEqual(conn.execute("SELECT ngo_name FROM public.ngo_profiles WHERE user_id=%s", (ngo_id,)).fetchone()[0], "Updated NGO")

            donor_id = "33333333-3333-4333-8333-333333333333"
            conn.execute("SELECT set_config('request.jwt.claim.sub', %s, false)", (donor_id,))
            donor_created = conn.execute(
                "SELECT public.register_role_profile(%s,%s)", ("Donor User", "DONOR")
            ).fetchone()[0]
            self.assertEqual(str(donor_created), donor_id)
            self.assertEqual(
                conn.execute("SELECT role FROM public.get_my_profile() AS profile, public.user_profiles WHERE user_id=%s", (donor_id,)).fetchone()[0],
                "DONOR",
            )
            self.assertEqual(conn.execute("SELECT count(*) FROM public.donor_profiles WHERE user_id=%s", (donor_id,)).fetchone()[0], 1)

            conn.execute("SELECT set_config('request.jwt.claim.sub', '', false)")
            with self.assertRaises(psycopg.Error) as unauthenticated:
                conn.execute("SELECT public.register_role_profile('No Auth','NGO',NULL,'No Auth NGO')")
            self.assertIn("UNAUTHENTICATED", str(unauthenticated.exception))
            conn.rollback()
            conn.execute("RESET ROLE")
            old_profile = conn.execute(
                "SELECT ngo_name FROM public.ngo_profiles WHERE user_id='11111111-1111-4111-8111-111111111111'"
            ).fetchone()
            self.assertEqual(old_profile, ("Existing Organization",))

        denied = self._psql(
            "SET ROLE anon; SELECT public.register_role_profile('No','NGO',NULL,'No NGO');",
            expect_error="permission denied",
        )
        self.assertIn("register_role_profile", denied)


if __name__ == "__main__":
    unittest.main(verbosity=2)
