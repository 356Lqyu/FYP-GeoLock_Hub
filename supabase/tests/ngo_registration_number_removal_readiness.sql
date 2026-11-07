-- Read-only postflight for 20261103_remove_ngo_registration_number.sql.
-- Run against the explicitly selected DEV project after a separately approved
-- migration deployment. This script changes no database state.

SELECT
  current_database() AS database_name,
  current_user AS executing_role,
  to_regprocedure('public.register_role_profile(text,text,text,text,text,double precision,double precision,text)') IS NOT NULL
    AS registration_without_reference_parameter_present,
  to_regprocedure('public.register_role_profile(text,text,text,text,text,text,double precision,double precision,text)') IS NULL
    AS obsolete_registration_signature_absent,
  to_regprocedure('public.update_my_profile(text,text,text)') IS NOT NULL
    AS profile_update_without_reference_parameter_present,
  to_regprocedure('public.update_my_profile(text,text,text,text)') IS NULL
    AS obsolete_profile_update_signature_absent,
  to_regprocedure('public.get_my_profile()') IS NOT NULL AS profile_read_present,
  NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='ngo_profiles'
      AND column_name='registration_number'
  ) AS profile_column_absent;

SELECT p.oid::regprocedure AS signature,
       pg_get_function_result(p.oid) AS return_type,
       p.prosecdef AS security_definer,
       p.provolatile AS volatility,
       p.proconfig AS function_settings,
       pg_get_userbyid(p.proowner) AS owner,
       has_function_privilege('authenticated',p.oid,'EXECUTE') AS authenticated_execute,
       has_function_privilege('service_role',p.oid,'EXECUTE') AS service_role_execute,
       has_function_privilege('anon',p.oid,'EXECUTE') AS anon_execute
  FROM pg_proc p
 WHERE p.oid IN (
   to_regprocedure('public.register_role_profile(text,text,text,text,text,double precision,double precision,text)'),
   to_regprocedure('public.update_my_profile(text,text,text)'),
   to_regprocedure('public.get_my_profile()')
 )
 ORDER BY p.oid;

SELECT count(*) AS ngo_profile_count
  FROM public.ngo_profiles;
