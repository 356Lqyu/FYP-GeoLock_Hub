-- Read-only readiness check for
-- 20261021_auto_validate_ngo_registration_location.sql.
-- Historical review only. The newer 20261022 role-onboarding design moves NGO
-- location validation to set_ngo_operating_location(); use
-- role_onboarding_readiness.sql for that final design. Do not use this script
-- as the readiness gate for 20261022.
-- Run only in isolated DEV rcgyuwiidqvrgbxswhqj. Every statement is SELECT-only.
-- Compare the CURRENT baseline grants with the documented POST-migration
-- expectations below; this script does not change grants or other objects.

-- 1. Current function contracts, owners, settings, and dependency privileges.
with expected(function_name, signature, result_type, volatility,
              search_path, expected_owner) as (
  values
    ('register_role_profile',
     'public.register_role_profile(text,text,text,text,text,text,double precision,double precision,text)',
     'uuid', 'v', 'search_path=pg_catalog, public, extensions, pg_temp', 'postgres'),
    ('geolock_resolve_road_node',
     'public.geolock_resolve_road_node(double precision,double precision)',
     'TABLE(node_id text, snap_distance_m double precision, snapshot_id text)',
     's', 'search_path=public, extensions, pg_temp', 'postgres'),
    ('geolock_refresh_ngo_road_eligibility',
     'public.geolock_refresh_ngo_road_eligibility(uuid)',
     'void', 'v', 'search_path=public, extensions, pg_temp', 'postgres'),
    ('geolock_app_capabilities',
     'public.geolock_app_capabilities()',
     'jsonb', 's', 'search_path=pg_catalog, public, pg_temp', 'postgres')
), resolved as (
  select e.*, to_regprocedure(e.signature) as function_oid
  from expected e
)
select e.function_name, e.signature, e.function_oid is not null as exists,
       pg_get_userbyid(p.proowner) as actual_owner,
       e.expected_owner,
       pg_get_function_result(p.oid) as actual_result,
       p.provolatile as actual_volatility,
       p.prosecdef as security_definer,
       p.proconfig as actual_settings,
       (pg_get_function_result(p.oid) = e.result_type) as result_matches,
       (p.provolatile::text = e.volatility) as volatility_matches,
       (pg_get_userbyid(p.proowner) = e.expected_owner) as owner_matches,
       coalesce(p.prosecdef, false) as security_definer_matches,
       coalesce(p.proconfig @> array[e.search_path]::text[], false) as search_path_matches
from resolved e
left join pg_proc p on p.oid = e.function_oid
order by e.function_name;

-- The registration SECURITY DEFINER owner must be able to call protected
-- dependencies. Expected: both true for postgres; authenticated does not need
-- direct EXECUTE on the resolver or cache refresher.
select pg_get_userbyid(reg.proowner) as registration_owner,
       has_function_privilege(reg.proowner, resolver.oid, 'EXECUTE') as owner_can_execute_resolver,
       has_function_privilege(reg.proowner, refresh.oid, 'EXECUTE') as owner_can_execute_refresh
from pg_proc reg
join pg_proc resolver on resolver.oid = to_regprocedure(
  'public.geolock_resolve_road_node(double precision,double precision)')
join pg_proc refresh on refresh.oid = to_regprocedure(
  'public.geolock_refresh_ngo_road_eligibility(uuid)')
where reg.oid = to_regprocedure(
  'public.register_role_profile(text,text,text,text,text,text,double precision,double precision,text)');

-- 2. Current baseline grants and intended grants after the migration.
-- The migration explicitly removes PUBLIC/anon and grants authenticated for
-- register_role_profile and geolock_app_capabilities. Resolver/refresh remain
-- owner-only dependencies. These are observations, not a grant mutation.
select p.oid::regprocedure as function_identity,
       pg_get_userbyid(p.proowner) as owner,
       has_function_privilege('anon', p.oid, 'EXECUTE') as baseline_anon_execute,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') as baseline_authenticated_execute,
       exists (
         select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
         where a.grantee = 0 and a.privilege_type = 'EXECUTE'
       ) as baseline_public_execute,
       case when p.oid in (
         to_regprocedure('public.register_role_profile(text,text,text,text,text,text,double precision,double precision,text)'),
         to_regprocedure('public.geolock_app_capabilities()'))
         then false else has_function_privilege('anon', p.oid, 'EXECUTE')
       end as intended_post_anon_execute,
       case when p.oid in (
         to_regprocedure('public.register_role_profile(text,text,text,text,text,text,double precision,double precision,text)'),
         to_regprocedure('public.geolock_app_capabilities()'))
         then true else has_function_privilege('authenticated', p.oid, 'EXECUTE')
       end as intended_post_authenticated_execute,
       case when p.oid in (
         to_regprocedure('public.register_role_profile(text,text,text,text,text,text,double precision,double precision,text)'),
         to_regprocedure('public.geolock_app_capabilities()'))
         then false else exists (
           select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
           where a.grantee = 0 and a.privilege_type = 'EXECUTE'
         )
       end as intended_post_public_execute
from pg_proc p
where p.oid in (
  to_regprocedure('public.register_role_profile(text,text,text,text,text,text,double precision,double precision,text)'),
  to_regprocedure('public.geolock_app_capabilities()'),
  to_regprocedure('public.geolock_resolve_road_node(double precision,double precision)'),
  to_regprocedure('public.geolock_refresh_ngo_road_eligibility(uuid)')
)
order by function_identity::text;

-- 3. Required relations and relevant column type/null/default details.
select x.table_name, x.column_name, c.data_type, c.udt_name, c.is_nullable,
       c.column_default,
       (c.column_name is not null) as exists
from (values
  ('user_profiles','user_id'), ('user_profiles','full_name'),
  ('user_profiles','phone_number'), ('user_profiles','role'),
  ('donor_profiles','user_id'),
  ('ngo_profiles','user_id'), ('ngo_profiles','ngo_name'),
  ('ngo_profiles','registration_number'), ('ngo_profiles','operating_address'),
  ('ngo_profiles','latitude'), ('ngo_profiles','longitude'),
  ('ngo_profiles','road_node_id'), ('ngo_profiles','location_verified_at'),
  ('ngo_profiles','active_flag'),
  ('audit_events','actor_user_id'), ('audit_events','actor_role'),
  ('audit_events','entity_type'), ('audit_events','entity_id'),
  ('audit_events','event_type'), ('audit_events','requested_state'),
  ('audit_events','resulting_state'), ('audit_events','reason_code'),
  ('audit_events','outcome'), ('audit_events','details'),
  ('road_network_coverage','network_snapshot_id'),
  ('road_network_coverage','dataset_kind'), ('road_network_coverage','active_flag'),
  ('road_network_coverage','approved_at'), ('road_network_coverage','max_snap_distance_m'),
  ('road_network_nodes','osm_node_id'), ('road_network_nodes','network_snapshot_id'),
  ('road_network_nodes','latitude'), ('road_network_nodes','longitude'),
  ('road_network_nodes','active_flag'),
  ('ngo_listing_road_eligibility','listing_id'),
  ('ngo_listing_road_eligibility','ngo_user_id'),
  ('ngo_listing_road_eligibility','network_snapshot_id'),
  ('coordination_config','singleton'), ('coordination_config','geofence_radius_m'),
  ('coordination_config','config_version')
) as x(table_name,column_name)
left join information_schema.columns c
  on c.table_schema = 'public' and c.table_name = x.table_name
 and c.column_name = x.column_name
order by x.table_name, x.column_name;

-- Required objects, including the active-snapshot uniqueness guard.
select x.object_name, to_regclass(x.object_name) is not null as exists
from (values
  ('public.user_profiles'), ('public.donor_profiles'), ('public.ngo_profiles'),
  ('public.audit_events'), ('public.road_network_coverage'),
  ('public.road_network_nodes'), ('public.road_network_edges'),
  ('public.ngo_listing_road_eligibility'), ('public.coordination_config'),
  ('public.road_network_one_active_operational')
) as x(object_name)
order by x.object_name;

-- 4. Snapshot/config invariants. Expected active_approved_count = 1,
-- active_wrong_snap_count = 0, configured_20km_singleton_count = 1.
select count(*) filter (where active_flag and dataset_kind = 'OPERATIONAL'
                         and approved_at is not null) as active_approved_count,
       count(*) filter (where active_flag and dataset_kind = 'OPERATIONAL'
                         and approved_at is not null and max_snap_distance_m <> 500)
         as active_wrong_snap_count,
       min(max_snap_distance_m) filter (where active_flag and dataset_kind = 'OPERATIONAL'
                                         and approved_at is not null) as active_snap_limit_m
from public.road_network_coverage;

select count(*) filter (where singleton and geofence_radius_m = 20000)
         as configured_20km_singleton_count,
       count(*) filter (where singleton) as singleton_row_count,
       max(geofence_radius_m) filter (where singleton) as geofence_radius_m,
       max(config_version) filter (where singleton) as config_version
from public.coordination_config;

-- 5. Constraints and indexes protecting location/profile/audit/config behavior.
select n.nspname as schema_name, t.relname as table_name, c.conname,
       c.contype, c.convalidated, pg_get_constraintdef(c.oid) as definition
from pg_constraint c
join pg_class t on t.oid = c.conrelid
join pg_namespace n on n.oid = t.relnamespace
where n.nspname = 'public'
  and t.relname in ('ngo_profiles','audit_events','road_network_coverage',
                    'road_network_nodes','ngo_listing_road_eligibility',
                    'coordination_config')
order by t.relname, c.conname;

select schemaname, tablename, indexname, indexdef
from pg_indexes
where schemaname = 'public'
  and tablename in ('road_network_coverage','ngo_profiles','audit_events',
                    'ngo_listing_road_eligibility')
order by tablename, indexname;

-- 6. Trigger enablement on rows written by registration/cache refresh, plus
-- any audit or profile guards. Expected enabled triggers should be O or A.
select n.nspname as schema_name, c.relname as table_name, t.tgname,
       t.tgenabled, pg_get_triggerdef(t.oid) as definition
from pg_trigger t
join pg_class c on c.oid = t.tgrelid
join pg_namespace n on n.oid = c.relnamespace
where not t.tgisinternal and n.nspname = 'public'
  and c.relname in ('user_profiles','donor_profiles','ngo_profiles',
                    'audit_events','ngo_listing_road_eligibility',
                    'road_network_coverage')
order by c.relname, t.tgname;

-- 7. RLS status and policies for protected tables touched/read by this path.
select n.nspname as schema_name, c.relname as table_name,
       c.relrowsecurity as rls_enabled, c.relforcerowsecurity as force_rls
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname in ('user_profiles','donor_profiles','ngo_profiles','audit_events',
                    'road_network_coverage','road_network_nodes','road_network_edges',
                    'ngo_listing_road_eligibility','coordination_config')
order by c.relname;

select schemaname, tablename, policyname, permissive, roles, cmd,
       qual, with_check
from pg_policies
where schemaname = 'public'
  and tablename in ('user_profiles','donor_profiles','ngo_profiles','audit_events',
                    'road_network_coverage','road_network_nodes','road_network_edges',
                    'ngo_listing_road_eligibility','coordination_config')
order by tablename, policyname;

-- 8. Ownership and table privileges relevant to the migration executor and
-- SECURITY DEFINER owner. Use results to confirm the deployment role can
-- replace functions and that no client table-write grant is introduced.
select c.oid::regclass as relation, pg_get_userbyid(c.relowner) as owner,
       has_table_privilege('postgres', c.oid, 'SELECT') as postgres_select,
       has_table_privilege('postgres', c.oid, 'INSERT') as postgres_insert,
       has_table_privilege('postgres', c.oid, 'UPDATE') as postgres_update,
       has_table_privilege('authenticated', c.oid, 'INSERT') as authenticated_insert,
       has_table_privilege('authenticated', c.oid, 'UPDATE') as authenticated_update,
       has_table_privilege('anon', c.oid, 'INSERT') as anon_insert,
       has_table_privilege('anon', c.oid, 'UPDATE') as anon_update
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind in ('r','p')
  and c.relname in ('user_profiles','donor_profiles','ngo_profiles','audit_events',
                    'road_network_coverage','road_network_nodes','ngo_listing_road_eligibility',
                    'coordination_config')
order by c.relname;

-- Note: this catalog script cannot prove lock behavior under concurrency. The
-- migration takes FOR SHARE on the active coverage row; repository activation
-- updates that same row, while concurrent FOR SHARE registration locks coexist.
