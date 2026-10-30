-- Read-only preflight for 20261023_async_ngo_eligibility_refresh.sql.
-- Run only in isolated DEV. This script does not invoke any RPC or write data.

select current_database() as database_name,
       current_user as executing_role,
       to_regprocedure('cron.schedule(text,text,text)') is not null as cron_schedule_available,
       to_regprocedure('public.set_ngo_operating_location(text,double precision,double precision)') is not null as location_rpc_present,
       to_regprocedure('public.geolock_refresh_ngo_road_eligibility(uuid)') is not null as full_ngo_refresh_present,
       to_regprocedure('public.geolock_refresh_listing_road_eligibility(uuid,uuid)') is not null as listing_refresh_present,
       to_regprocedure('public.geolock_road_eligible_km(uuid,uuid)') is not null as cached_eligibility_reader_present;

select p.oid::regprocedure as signature,
       pg_get_function_result(p.oid) as return_type,
       p.prosecdef as security_definer,
       p.proconfig as function_settings,
       pg_get_userbyid(p.proowner) as owner,
       has_function_privilege('authenticated',p.oid,'EXECUTE') as authenticated_execute,
       has_function_privilege('anon',p.oid,'EXECUTE') as anon_execute,
       has_function_privilege('postgres',p.oid,'EXECUTE') as postgres_execute
  from pg_proc p
 where p.oid in (
   to_regprocedure('public.set_ngo_operating_location(text,double precision,double precision)'),
   to_regprocedure('public.process_ngo_eligibility_refresh_jobs()'),
   to_regprocedure('public.get_my_ngo_eligibility_refresh_status()'),
   to_regprocedure('public.geolock_ngo_eligibility_ready(uuid)'),
   to_regprocedure('public.geolock_road_eligible_km(uuid,uuid)')
 ) order by p.oid;

select table_name,column_name,is_nullable,data_type
  from information_schema.columns
 where table_schema='public'
   and (table_name,column_name) in (
     ('ngo_profiles','location_generation'),
     ('ngo_profiles','road_node_id'),
     ('ngo_profiles','location_verified_at'),
     ('ngo_eligibility_refresh_jobs','ngo_user_id'),
     ('ngo_eligibility_refresh_jobs','location_generation'),
     ('ngo_eligibility_refresh_jobs','expected_road_node_id'),
     ('ngo_eligibility_refresh_jobs','expected_snapshot_id'),
     ('ngo_eligibility_refresh_jobs','job_status'),
     ('ngo_eligibility_refresh_jobs','attempt_count')
   ) order by table_name,ordinal_position;

select jobid,jobname,schedule,command,username,active
  from cron.job
 where jobname='geolock-ngo-eligibility-refresh';

-- The cron command sets the session timeout before starting the worker SELECT.
select jobid,
       command = 'set statement_timeout = ''10min''; select public.process_ngo_eligibility_refresh_jobs();'
         as timeout_configured_before_worker,
       username = 'postgres' as trusted_execution_role,
       schedule = '* * * * *' as expected_schedule,
       active
  from cron.job
 where jobname='geolock-ngo-eligibility-refresh';

-- Application roles must have no effective sequence privileges. The trusted
-- owner retains access needed by the identity column and SECURITY DEFINER worker.
with seq as (
  select to_regclass('public.ngo_eligibility_refresh_jobs_job_id_seq')::oid as oid
)
select oid::regclass as queue_identity_sequence,
       case when oid is null then null else has_sequence_privilege('anon',oid,'USAGE') end as anon_usage,
       case when oid is null then null else has_sequence_privilege('anon',oid,'SELECT') end as anon_select,
       case when oid is null then null else has_sequence_privilege('anon',oid,'UPDATE') end as anon_update,
       case when oid is null then null else has_sequence_privilege('authenticated',oid,'USAGE') end as authenticated_usage,
       case when oid is null then null else has_sequence_privilege('authenticated',oid,'SELECT') end as authenticated_select,
       case when oid is null then null else has_sequence_privilege('authenticated',oid,'UPDATE') end as authenticated_update,
       case when oid is null then null else has_sequence_privilege('service_role',oid,'USAGE') end as service_role_usage,
       case when oid is null then null else has_sequence_privilege('service_role',oid,'SELECT') end as service_role_select,
       case when oid is null then null else has_sequence_privilege('service_role',oid,'UPDATE') end as service_role_update,
       case when oid is null then null else has_sequence_privilege('postgres',oid,'USAGE') end as postgres_usage,
       case when oid is null then null else has_sequence_privilege('postgres',oid,'SELECT') end as postgres_select,
       case when oid is null then null else has_sequence_privilege('postgres',oid,'UPDATE') end as postgres_update
  from seq;

select network_snapshot_id,dataset_kind,active_flag,approved_at,max_snap_distance_m
  from public.road_network_coverage
 where active_flag and dataset_kind='OPERATIONAL';
