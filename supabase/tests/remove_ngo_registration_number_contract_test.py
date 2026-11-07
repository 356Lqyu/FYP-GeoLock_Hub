"""Source-contract tests for the forward NGO registration-number removal."""
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
MIGRATION = ROOT / "supabase/migrations/20261103_remove_ngo_registration_number.sql"
AUTH_PAGES = ROOT / "frontend/geolock_hub_app/lib/auth/auth_pages.dart"
AUTH_CONTROLLER = ROOT / "frontend/geolock_hub_app/lib/auth/auth_controller.dart"
PROFILE_PAGE = ROOT / "frontend/geolock_hub_app/lib/dashboard_pages.dart"
REGISTRATION_WIDGET_TEST = ROOT / "frontend/geolock_hub_app/test/road_routing_test.dart"


class RemoveNgoRegistrationNumberContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sql = MIGRATION.read_text(encoding="utf-8")
        cls.auth_pages = AUTH_PAGES.read_text(encoding="utf-8")
        cls.auth_controller = AUTH_CONTROLLER.read_text(encoding="utf-8")
        cls.profile_page = PROFILE_PAGE.read_text(encoding="utf-8")
        cls.widget_test = REGISTRATION_WIDGET_TEST.read_text(encoding="utf-8")

    def test_migration_is_guarded_forward_only_and_drops_column_without_cascade(self):
        self.assertIn("BEGIN;", self.sql)
        self.assertIn("LOCK TABLE public.ngo_profiles IN ACCESS EXCLUSIVE MODE", self.sql)
        self.assertIn("NGO_REGISTRATION_VALUES_REQUIRE_APPROVED_BACKUP", self.sql)
        self.assertIn("DROP CONSTRAINT ngo_profiles_registration_number_key", self.sql)
        self.assertIn("DROP COLUMN registration_number RESTRICT", self.sql)
        self.assertNotRegex(self.sql, r"(?i)\bCASCADE\b")
        self.assertGreaterEqual(self.sql.count("COMMIT;"), 1)

    def test_registration_replaces_signature_and_preserves_role_security(self):
        new_signature = (
            "public.register_role_profile(text,text,text,text,text,"
            "double precision,double precision,text)"
        )
        self.assertIn("DROP FUNCTION public.register_role_profile(", self.sql)
        self.assertIn("CREATE FUNCTION public.register_role_profile(", self.sql)
        registration = self.sql.split("CREATE FUNCTION public.register_role_profile(", 1)[1]
        registration = registration.split("$function$;", 1)[0]
        self.assertNotIn("p_registration_number", registration)
        self.assertIn("p_role NOT IN ('DONOR','NGO','HUB_ADMIN')", registration)
        self.assertIn("auth.uid()", registration)
        self.assertIn("ROLE_ALREADY_REGISTERED", registration)
        self.assertIn("NGO_NAME_REQUIRED", registration)
        self.assertIn("INSERT INTO public.donor_profiles(user_id)", registration)
        self.assertIn("INSERT INTO public.ngo_profiles(user_id,ngo_name)", registration)
        new_args = re.search(
            r"CREATE FUNCTION public\.register_role_profile\((.*?)\)\s*RETURNS",
            self.sql,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(new_args)
        self.assertEqual(
            re.findall(r"\b(p_[a-z_]+)\s+(?:text|double precision)", new_args.group(1)),
            [
                "p_full_name",
                "p_role",
                "p_phone",
                "p_ngo_name",
                "p_operating_address",
                "p_latitude",
                "p_longitude",
                "p_road_node_id",
            ],
        )
        self.assertIn(f"to_regprocedure('{new_signature}') IS NOT NULL", self.sql)
        self.assertIn("TO authenticated, service_role", self.sql)
        self.assertIn("FROM PUBLIC, anon", self.sql)

    def test_profile_read_and_update_remove_field_but_keep_location_and_auth(self):
        profile_read = self.sql.split("CREATE OR REPLACE FUNCTION public.get_my_profile()", 1)[1]
        profile_read = profile_read.split("$function$;", 1)[0]
        self.assertNotIn("registration_number", profile_read)
        self.assertIn("auth.uid()", profile_read)
        self.assertIn("ngo_location_setup_required", profile_read)
        self.assertIn("location_status", profile_read)
        self.assertIn("hub_setup_required", profile_read)

        update = self.sql.split("CREATE FUNCTION public.update_my_profile(", 1)[1]
        update = update.split("$function$;", 1)[0]
        self.assertNotIn("p_registration_number", update)
        self.assertIn("NGO_NAME_REQUIRED", update)
        self.assertIn("UPDATE public.ngo_profiles SET ngo_name", update)
        self.assertIn("REVOKE ALL ON FUNCTION public.update_my_profile(text,text,text) FROM PUBLIC, anon", self.sql)
        self.assertIn("TO authenticated, service_role", self.sql)

    def test_flutter_has_no_registration_number_field_or_rpc_parameter(self):
        for source in (self.auth_pages, self.auth_controller, self.profile_page):
            self.assertNotIn("registration_number", source)
            self.assertNotIn("p_registration_number", source)
            self.assertNotRegex(source, r"(?i)registration\s*/\s*reference\s+number")
        self.assertIn("'ngo_name': ngoName.text.trim()", self.auth_pages)
        self.assertIn("'p_ngo_name': role == 'NGO' ? pending['ngo_name'] : null", self.auth_controller)
        self.assertIn("'p_ngo_name': widget.role == 'NGO' ? values[2].trim() : null", self.profile_page)
        self.assertIn("find.textContaining('Registration'), findsNothing", self.widget_test)


if __name__ == "__main__":
    unittest.main()
