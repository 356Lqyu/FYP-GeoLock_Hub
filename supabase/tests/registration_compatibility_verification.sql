-- Read-only post-deployment checks for 20261017_registration_compatibility.sql.
-- Run the catalog checks as a database owner. Run the RPC checks through an
-- authenticated Supabase client, since SQL Editor does not establish auth.uid().

-- 1. Verify the V3 registration signature and the two added RPC signatures.
select
  p.oid::regprocedure as function_identity,
  pg_get_function_result(p.oid) as result_type,
  pg_get_function_identity_arguments(p.oid) as identity_arguments,
  p.prosecdef as security_definer,
  p.proconfig as function_settings
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'get_my_profile',
    'geolock_app_capabilities',
    'register_role_profile'
  )
order by p.proname;

-- 2. Verify authenticated EXECUTE and absence of anon/PUBLIC EXECUTE.
-- Each row should show authenticated_execute=true,
-- anon_execute=false, and public_execute=false.
select
  p.oid::regprocedure as function_identity,
  has_function_privilege('authenticated', p.oid, 'EXECUTE')
    as authenticated_execute,
  has_function_privilege('anon', p.oid, 'EXECUTE') as anon_execute,
  exists (
    select 1
    from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
    where a.grantee = 0
      and a.privilege_type = 'EXECUTE'
  ) as public_execute
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'get_my_profile',
    'geolock_app_capabilities',
    'register_role_profile'
  )
order by p.proname;

-- 3. Confirm the compatibility migration did not create/alter the road graph.
-- Missing tables are expected on a plain V3 deployment.
select
  to_regclass('public.road_network_nodes') as road_network_nodes,
  to_regclass('public.road_network_coverage') as road_network_coverage;

-- 4. Read-only inspection of an NGO registered after deployment. Supply the
-- test account's UUID. Both values must be NULL pending trusted verification.
-- Existing records are intentionally not rewritten by this migration.
-- select user_id, road_node_id, location_verified_at
-- from public.ngo_profiles
-- where user_id = '<NEW_TEST_NGO_AUTH_UUID>'::uuid;

-- 5. Through an authenticated Supabase client, call:
--   rpc('get_my_profile')
--   rpc('geolock_app_capabilities')
-- Expected profile fields include user_id, full_name, phone_number, role,
-- created_at, ngo_name, operating_address, latitude, longitude,
-- location_verified_at, location_status, and hub_admin.
-- A new NGO profile must report location_status=PENDING_VERIFICATION.
-- A DONOR profile must report role=DONOR and location_status=null.
-- road_node_resolution must be false unless an approved operational graph is
-- configured. NGO location registration must report UNVERIFIED.
