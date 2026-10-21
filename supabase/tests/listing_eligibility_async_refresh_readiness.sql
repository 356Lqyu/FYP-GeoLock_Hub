-- READ ONLY. Preflight for manual DEV deployment; no RPCs are invoked.
select current_user,current_setting('transaction_read_only') as read_only,
       current_database(),current_setting('server_version_num') as server_version_num;
select p.oid::regprocedure as signature,pg_get_function_result(p.oid) as result,
       pg_get_userbyid(p.proowner) as owner,p.prosecdef,p.proconfig,
       has_function_privilege('postgres',p.oid,'EXECUTE') as postgres_execute,
       pg_get_functiondef(p.oid) as definition
 from pg_proc p where p.oid in (
 to_regprocedure('public.create_donation_with_images(uuid,text,text,text,double precision,double precision,jsonb,text,jsonb)'),
 to_regprocedure('public.geolock_refresh_listing_road_eligibility(uuid,uuid)'),
 to_regprocedure('public.geolock_refresh_ngo_road_eligibility(uuid)'),
 to_regprocedure('public.process_ngo_eligibility_refresh_jobs()'),
 to_regprocedure('public.set_ngo_operating_location(text,double precision,double precision)'),
 to_regprocedure('public.geolock_ngo_listing_road_check(uuid,uuid)'),
 to_regprocedure('public.geolock_road_eligible_km(uuid,uuid)'),
 to_regprocedure('public.geolock_ngo_eligibility_ready(uuid)'),
 to_regprocedure('public.claim_listing(uuid,uuid)'),
 to_regprocedure('public.geolock_resolve_road_node(double precision,double precision)'),
 to_regprocedure('cron.schedule(text,text,text)'));
-- Review NGO worker FOR UPDATE and setter cache deletion; claim NGO-before-listing
-- locking; directed routing; trusted resolver; all owners must be postgres except cron.
select table_name,column_name,data_type,is_nullable from information_schema.columns
 where table_schema='public' and table_name in
 ('listings','ngo_profiles','ngo_listing_road_eligibility','ngo_eligibility_refresh_jobs')
 order by table_name,ordinal_position;
select c.conrelid::regclass as relation,c.conname,pg_get_constraintdef(c.oid)
 from pg_constraint c where c.conrelid in ('public.listings'::regclass,
 'public.ngo_profiles'::regclass,'public.ngo_listing_road_eligibility'::regclass);
select t.tgrelid::regclass as relation,t.tgname,t.tgenabled,pg_get_triggerdef(t.oid)
 from pg_trigger t where not t.tgisinternal
 and t.tgrelid in ('public.listings'::regclass,'public.ngo_profiles'::regclass);
select network_snapshot_id,max_snap_distance_m,approved_at
 from public.road_network_coverage where active_flag and dataset_kind='OPERATIONAL';
select donation_direct_min_kg,geofence_radius_m from public.coordination_config where singleton;
-- Must be zero: bootstrap intentionally fails rather than quietly skipping rows.
select count(*) as available_listings_missing_node from public.listings
 where listing_status='AVAILABLE' and pickup_road_node_id is null;
-- New names must be absent before deployment.
select to_regclass('public.listing_eligibility_refresh_jobs') as queue,
       to_regclass('public.listing_eligibility_refresh_jobs_job_id_seq') as identity_sequence,
       to_regprocedure('public.process_listing_eligibility_refresh_jobs()') as worker,
       to_regprocedure('public.geolock_listing_eligibility_ready(uuid)') as readiness_helper;
select extname,extversion,extnamespace::regnamespace from pg_extension where extname='pg_cron';
select jobname,schedule,command,username,active from cron.job
 where jobname in ('geolock-ngo-eligibility-refresh','geolock-listing-eligibility-refresh');
select pg_get_userbyid(defaclrole) as owner,defaclnamespace::regnamespace,
       defaclobjtype,defaclacl from pg_default_acl
 where defaclrole='postgres'::regrole;
-- Effective inherited grants must not bypass explicit queue/sequence revokes.
select pg_get_userbyid(roleid) as inherited_role,pg_get_userbyid(member) as member
 from pg_auth_members where member in ('anon'::regrole,'authenticated'::regrole,'service_role'::regrole);
select n.nspname,c.relname,pg_get_userbyid(c.relowner) as owner,c.relrowsecurity,c.relacl
 from pg_class c join pg_namespace n on n.oid=c.relnamespace
 where n.nspname='public' and c.relname in
 ('listings','ngo_listing_road_eligibility','ngo_eligibility_refresh_jobs');
select tablename,policyname,roles,cmd,qual,with_check from pg_policies
 where schemaname='public' and tablename in ('listings','ngo_listing_road_eligibility');

