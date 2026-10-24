-- Read-only readiness check for
-- 20261022_role_onboarding_and_profile_management.sql.
-- Run only in the isolated DEV project after selecting the project explicitly.

select
  current_database() as database_name,
  current_user as executing_role,
  to_regprocedure('public.register_role_profile(text,text,text,text,text,text,double precision,double precision,text)') is not null as registration_signature_present,
  to_regprocedure('public.get_my_profile()') is not null as profile_read_present,
  to_regprocedure('public.register_community_hub(text,text,double precision,double precision,numeric,text)') is not null as hub_registration_signature_present,
  to_regprocedure('public.claim_listing(uuid,uuid)') is not null as claim_signature_present,
  to_regprocedure('public.geolock_resolve_road_node(double precision,double precision)') is not null as road_resolver_present,
  to_regprocedure('public.geolock_refresh_ngo_road_eligibility(uuid)') is not null as ngo_eligibility_refresh_present;

select p.oid::regprocedure as signature,
       pg_get_function_result(p.oid) as return_type,
       p.prosecdef as security_definer,
       p.provolatile as volatility,
       p.proconfig as function_settings,
       pg_get_userbyid(p.proowner) as owner,
       has_function_privilege('authenticated',p.oid,'EXECUTE') as authenticated_execute
  from pg_proc p
 where p.oid in (
   to_regprocedure('public.register_role_profile(text,text,text,text,text,text,double precision,double precision,text)'),
   to_regprocedure('public.get_my_profile()'),
   to_regprocedure('public.register_community_hub(text,text,double precision,double precision,numeric,text)'),
   to_regprocedure('public.claim_listing(uuid,uuid)'),
   to_regprocedure('public.geolock_resolve_road_node(double precision,double precision)'),
   to_regprocedure('public.geolock_refresh_ngo_road_eligibility(uuid)')
 )
 order by p.oid;

select table_name,column_name,is_nullable,data_type
  from information_schema.columns
 where table_schema='public'
   and (table_name,column_name) in (
     ('user_profiles','user_id'),('user_profiles','full_name'),('user_profiles','phone_number'),('user_profiles','role'),
     ('ngo_profiles','user_id'),('ngo_profiles','ngo_name'),('ngo_profiles','registration_number'),
     ('ngo_profiles','operating_address'),('ngo_profiles','latitude'),('ngo_profiles','longitude'),
     ('ngo_profiles','road_node_id'),('ngo_profiles','location_verified_at'),('ngo_profiles','active_flag'),
     ('hub_admin_profiles','user_id'),('community_hubs','admin_user_id'),('community_hubs','hub_id'),
     ('community_hubs','hub_name'),('community_hubs','created_at'),
     ('community_hubs','address_text'),('community_hubs','latitude'),('community_hubs','longitude'),
     ('community_hubs','road_node_id'),('community_hubs','capacity_kg'),('community_hubs','active_flag'),
     ('vehicles','ngo_user_id'),('vehicles','depot_road_node_id'),
     ('donation_claims','ngo_user_id'),('donation_claims','claim_status'),
     ('claim_leases','claim_id'),('claim_leases','lease_status'),
     ('audit_events','actor_user_id'),('audit_events','actor_role'),('audit_events','entity_type'),
     ('audit_events','entity_id'),('audit_events','event_type'),('audit_events','requested_state'),
     ('audit_events','resulting_state'),('audit_events','reason_code'),('audit_events','outcome'),
     ('audit_events','details')
   )
 order by table_name,ordinal_position;

select network_snapshot_id,dataset_kind,active_flag,approved_at,max_snap_distance_m
  from public.road_network_coverage
 where active_flag and dataset_kind='OPERATIONAL';

select singleton,donation_direct_min_kg,geofence_radius_m,claim_lease_minutes,
       hub_reservation_minutes,config_version
  from public.coordination_config where singleton;

select indexname,indexdef
  from pg_indexes
 where schemaname='public'
   and tablename in ('community_hubs','donation_claims','ngo_profiles')
 order by tablename,indexname;

select c.relname as table_name,c.relrowsecurity as rls_enabled
  from pg_class c
  join pg_namespace n on n.oid=c.relnamespace
 where n.nspname='public'
   and c.relname in ('user_profiles','donor_profiles','ngo_profiles','hub_admin_profiles',
                     'community_hubs','donation_claims','claim_leases','audit_events')
 order by c.relname;
