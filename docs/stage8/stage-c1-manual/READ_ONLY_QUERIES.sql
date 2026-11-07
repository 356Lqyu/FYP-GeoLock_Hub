-- GeoLock Hub Stage C.1 manual inspection queries.
-- User-run only in Supabase Dashboard SQL Editor against approved DEV ref.
-- Each numbered query is an independent, read-only SELECT. No RPC execution,
-- DDL, DML, grants, migration operations, or personal application records.

-- QUERY 1 — PostgreSQL, installed extensions, and pgRouting overloads.
-- This is the first query to run. It verifies basic platform identity/version.
SELECT current_setting('server_version') AS postgres_version,
       current_setting('server_version_num') AS postgres_version_num,
       current_database() AS database_name,
       current_user AS sql_editor_role,
       coalesce(
         (SELECT jsonb_agg(jsonb_build_object(
                    'extension',e.extname,'version',e.extversion,'schema',n.nspname)
          ORDER BY e.extname)
          FROM pg_extension e JOIN pg_namespace n ON n.oid=e.extnamespace
          WHERE e.extname IN ('postgis','pgrouting')),
         '[]'::jsonb) AS spatial_extensions,
       coalesce(
         (SELECT jsonb_agg(jsonb_build_object(
                    'signature',p.oid::regprocedure::text,
                    'result',pg_get_function_result(p.oid),
                    'volatility',p.provolatile)
          ORDER BY p.oid::regprocedure::text)
          FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
          WHERE n.nspname='extensions' AND p.proname ILIKE 'pgr_dijkstraCost'),
         '[]'::jsonb) AS pgrouting_cost_overloads;

-- QUERY 2a — migration ledger presence and available columns. Run Query 2b
-- only if the ledger is present and exposes version/name (or adapt nothing;
-- report the schema difference and stop for review).
SELECT to_regclass('supabase_migrations.schema_migrations') AS ledger_relation,
       EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='supabase_migrations'
                 AND table_name='schema_migrations' AND column_name='version') AS has_version,
       EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='supabase_migrations'
                 AND table_name='schema_migrations' AND column_name='name') AS has_name;

-- QUERY 2b — applied migration versions only; no migration SQL or user data.
-- Conditional: run only after Query 2a confirms relation, version and name.
SELECT version, name
FROM supabase_migrations.schema_migrations
ORDER BY version, name;

-- QUERY 3 — Stage C.1 fleet schema and seal metadata. Does not call any
-- application RPC. Run Query 4 only if function_present is true.
SELECT n.oid::regnamespace AS fleet_schema,
       obj_description(n.oid,'pg_namespace') AS installation_seal_comment,
       to_regprocedure('fleet_private.installation_fingerprint()') IS NOT NULL
         AS function_present,
       p.proowner::regrole AS function_owner,
       p.prosecdef AS security_definer,
       p.provolatile AS volatility,
       p.proconfig AS function_configuration,
       p.proacl::text AS function_acl,
       md5(replace(p.prosrc,E'\r\n',E'\n')) AS function_body_md5
FROM (SELECT to_regnamespace('fleet_private') AS oid) s
LEFT JOIN pg_namespace n ON n.oid=s.oid
LEFT JOIN pg_proc p ON p.oid=to_regprocedure('fleet_private.installation_fingerprint()');

-- QUERY 4 — compute the C.1 fingerprint and compare to the namespace seal.
-- Run ONLY if Query 3 confirms the function exists. Its reviewed local body
-- is STABLE SECURITY DEFINER and catalog-reading; this is not an app RPC.
SELECT fleet_private.installation_fingerprint() AS computed_fingerprint,
       obj_description('fleet_private'::regnamespace,'pg_namespace') AS seal_comment,
       obj_description('fleet_private'::regnamespace,'pg_namespace')
         = 'geolock-stage8-c1-v2:'||fleet_private.installation_fingerprint() AS seal_matches;

-- QUERY 5 — routing_private schema, selected routing functions, owner/security,
-- search_path/configuration and function ACLs. Full definitions support
-- manual comparison to Stage A artifacts where there is no post-image hash.
SELECT n.nspname AS schema_name, n.nspowner::regrole AS schema_owner,
       p.oid::regprocedure::text AS signature,
       p.proowner::regrole AS function_owner,
       p.prosecdef AS security_definer,
       p.provolatile AS volatility,
       p.proconfig AS function_configuration,
       pg_get_function_result(p.oid) AS result_type,
       md5(replace(p.prosrc,E'\r\n',E'\n')) AS body_md5,
       p.proacl::text AS function_acl,
       pg_get_functiondef(p.oid) AS definition
FROM (SELECT to_regnamespace('routing_private') AS schema_oid) s
LEFT JOIN pg_namespace n ON n.oid=s.schema_oid
LEFT JOIN pg_proc p ON p.pronamespace=n.oid
ORDER BY p.oid::regprocedure::text;

-- QUERY 6 — assign_task_to_route fingerprint and security contract. Stage A
-- 001 expects the pre-publication SHA-256; Stage A 002 replaces direct
-- assignment with a fail-closed compatibility function. The actual definition
-- must be interpreted according to the observed Stage A phase.
SELECT p.oid::regprocedure::text AS signature,
       pg_get_function_identity_arguments(p.oid) AS identity_arguments,
       pg_get_function_result(p.oid) AS result_type,
       p.proowner::regrole AS function_owner,
       p.prosecdef AS security_definer,
       p.provolatile AS volatility,
       p.proconfig AS function_configuration,
       md5(replace(p.prosrc,E'\r\n',E'\n')) AS body_md5,
       encode(sha256(convert_to(pg_get_functiondef(p.oid),'UTF8')),'hex') AS definition_sha256,
       p.proacl::text AS function_acl,
       pg_get_functiondef(p.oid) AS definition
FROM pg_proc p
WHERE p.oid=to_regprocedure('public.assign_task_to_route(uuid,uuid,integer)');

-- QUERY 7 — Stage A 001/003 source and policy prerequisites. Results are
-- repository preconditions; after an authorized Stage A install, some
-- functions have intentionally changed and must be compared to the artifact.
WITH expected(signature,body_md5,expected_config,expected_result,expected_security) AS (
 VALUES
 ('public.start_pickup(uuid)','e89b650c83713b04e8310f4c372f10f4',ARRAY['search_path=public, extensions, pg_temp']::text[],'void',true),
 ('public.complete_pickup(uuid,boolean)','ae1b885377292281da17951cb18afd55',ARRAY['search_path=public, extensions, pg_temp']::text[],'void',true),
 ('public.submit_claim_reconciliation(uuid,boolean,uuid)','246a33d552da2ac4e229fa79c357d194',ARRAY['search_path=pg_catalog, public, pg_temp']::text[],'jsonb',true),
 ('public.recover_expired_claims(integer)','89e01f42d5ec23bfcbcdc47c1f4fd4e5',ARRAY['search_path=pg_catalog, public, extensions, pg_temp']::text[],'integer',true),
 ('public.claim_listing(uuid,uuid)','2c1f60c876797c61b44b3cb43591bab8',ARRAY['search_path=pg_catalog, public, extensions, pg_temp']::text[],'jsonb',true),
 ('public.geolock_transition_listing_donations(uuid,text,text,uuid,uuid,text)','67f27a85fb9129c9017bb0e9178f8ba1',ARRAY['search_path=pg_catalog, public, pg_temp']::text[],'void',false)
)
SELECT e.signature,e.body_md5 AS expected_pre_md5,
       p.proowner::regrole AS function_owner,p.prosecdef AS security_definer,
       p.proconfig AS function_configuration, p.provolatile,
       pg_get_function_result(p.oid) AS result_type,
       md5(replace(p.prosrc,E'\r\n',E'\n')) AS actual_body_md5,
       p.proacl::text AS function_acl,
       (p.oid IS NOT NULL AND p.proowner='postgres'::regrole
         AND p.prosecdef=e.expected_security AND p.provolatile='v'
         AND p.proconfig IS NOT DISTINCT FROM e.expected_config
         AND pg_get_function_result(p.oid)=e.expected_result
         AND md5(replace(p.prosrc,E'\r\n',E'\n'))=e.body_md5) AS matches_stage_a_precondition
FROM expected e LEFT JOIN pg_proc p ON p.oid=to_regprocedure(e.signature)
ORDER BY e.signature;

SELECT singleton,claim_lease_minutes,donation_direct_min_kg,geofence_radius_m,config_version
FROM public.coordination_config ORDER BY singleton;

-- QUERY 8 — Stage B.2 spatial helper status and metadata. Expected pre/post
-- hashes are pinned from the reviewed migration and local B.2 catalog evidence.
WITH expected(signature,pre_md5,post_md5,result_type,volatility) AS (
 VALUES
 ('public.geolock_resolve_road_node(double precision,double precision)',
  '9701683fdcfeb2486c887860c6470262','3e2ae3b624e0276110b5029231671df0',
  'TABLE(node_id text, snap_distance_m double precision, snapshot_id text)','s'),
 ('public.geolock_road_costs(bigint[],bigint[],double precision,double precision,double precision)',
  '828217e0b8faeeb3d32fa726b3e06a2a','53bac7e143510f560006bb641024c1a3',
  'TABLE(source_node bigint, target_node bigint, road_km double precision)','v')
)
SELECT e.signature,e.pre_md5,e.post_md5,
       p.proowner::regrole AS function_owner,p.prosecdef AS security_definer,
       p.proconfig AS function_configuration,p.provolatile,
       pg_get_function_result(p.oid) AS result_type,
       md5(replace(p.prosrc,E'\r\n',E'\n')) AS actual_body_md5,
       p.proacl::text AS function_acl,
       CASE WHEN p.oid IS NULL THEN 'MISSING'
            WHEN md5(replace(p.prosrc,E'\r\n',E'\n'))=e.pre_md5 THEN 'PRE-CORRECTION'
            WHEN md5(replace(p.prosrc,E'\r\n',E'\n'))=e.post_md5 THEN 'REVIEWED B.2 BODY'
            ELSE 'MISMATCH / REVIEW REQUIRED' END AS body_status,
       (p.oid IS NOT NULL AND p.proowner='postgres'::regrole AND p.prosecdef
         AND p.proconfig=ARRAY['search_path=public, extensions, pg_temp']
         AND p.provolatile=e.volatility
         AND pg_get_function_result(p.oid)=e.result_type) AS metadata_matches
FROM expected e LEFT JOIN pg_proc p ON p.oid=to_regprocedure(e.signature)
ORDER BY e.signature;

SELECT e.extname,e.extversion,n.nspname AS extension_schema
FROM pg_extension e JOIN pg_namespace n ON n.oid=e.extnamespace
WHERE e.extname IN ('postgis','pgrouting') ORDER BY e.extname;

SELECT p.oid::regprocedure::text AS pgrouting_cost_overload,
       pg_get_function_result(p.oid) AS result_type,p.provolatile
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='extensions' AND p.proname ILIKE 'pgr_dijkstraCost'
ORDER BY p.oid::regprocedure::text;

-- QUERY 9 — Stage B.4.3 Candidate 2 claim-path functions.
WITH expected(signature,pre_md5,post_md5,expected_result,expected_security,expected_config) AS (
 VALUES
 ('public.claim_listing(uuid,uuid)','2c1f60c876797c61b44b3cb43591bab8','c8d324772b12c843fba231e7ea733914',
  'jsonb',true,ARRAY['search_path=pg_catalog, public, extensions, pg_temp']::text[]),
 ('public.geolock_lock_listing_donations(uuid,text[])','90816e7c6db3606dc8b6451a899d8036','e97a3fd80673a827465f3eaa79b65903',
  'boolean',false,ARRAY['search_path=pg_catalog, public, pg_temp']::text[])
)
SELECT e.signature,e.pre_md5,e.post_md5,
       pg_get_function_identity_arguments(p.oid) AS identity_arguments,
       pg_get_function_result(p.oid) AS result_type,
       p.proowner::regrole AS function_owner,p.prosecdef AS security_definer,
       p.proconfig AS function_configuration,p.provolatile,
       md5(replace(p.prosrc,E'\r\n',E'\n')) AS actual_body_md5,
       p.proacl::text AS function_acl,
       CASE WHEN p.oid IS NULL THEN 'MISSING'
            WHEN md5(replace(p.prosrc,E'\r\n',E'\n'))=e.pre_md5 THEN 'PRE-CORRECTION'
            WHEN md5(replace(p.prosrc,E'\r\n',E'\n'))=e.post_md5 THEN 'CANDIDATE 2 BODY'
            ELSE 'MISMATCH / REVIEW REQUIRED' END AS body_status,
       (p.oid IS NOT NULL AND p.proowner='postgres'::regrole
         AND p.prosecdef=e.expected_security
         AND p.proconfig IS NOT DISTINCT FROM e.expected_config
         AND pg_get_function_result(p.oid)=e.expected_result) AS metadata_matches
FROM expected e LEFT JOIN pg_proc p ON p.oid=to_regprocedure(e.signature)
ORDER BY e.signature;

-- QUERY 10 — Effective EXECUTE permissions for public application roles and
-- Stage A worker roles. NULL means the role or function is absent.
WITH roles(role_name) AS (VALUES
 ('anon'),('authenticated'),('service_role'),
 ('geolock_graph_worker'),('geolock_planner'),('geolock_validator')),
 funcs(signature) AS (VALUES
 ('public.claim_listing(uuid,uuid)'),
 ('public.geolock_lock_listing_donations(uuid,text[])'),
 ('public.geolock_transition_listing_donations(uuid,text,text,uuid,uuid,text)'),
 ('public.geolock_resolve_road_node(double precision,double precision)'),
 ('public.geolock_road_costs(bigint[],bigint[],double precision,double precision,double precision)'),
 ('public.assign_task_to_route(uuid,uuid,integer)'),
 ('public.start_pickup(uuid)'),('public.complete_pickup(uuid,boolean)'),
 ('public.submit_claim_reconciliation(uuid,boolean,uuid)'),
 ('public.authorize_my_routing_candidate(uuid,uuid,timestamptz)'),
 ('public.get_my_routing_overview()'),('public.get_my_authorized_route(uuid)'))
)
SELECT f.signature,r.role_name,
       CASE WHEN pr.oid IS NULL OR role.oid IS NULL THEN NULL
            ELSE has_function_privilege(role.oid,pr.oid,'EXECUTE') END AS can_execute
FROM funcs f CROSS JOIN roles r
LEFT JOIN pg_roles role ON role.rolname=r.role_name
LEFT JOIN pg_proc pr ON pr.oid=to_regprocedure(f.signature)
ORDER BY f.signature,r.role_name;

-- QUERY 10b — exact Stage A 001 worker function grants. Reports effective
-- EXECUTE for each intended worker/function pair; NULL means role/function
-- is absent. This is catalog-only and does not invoke any worker function.
WITH expected(role_name,signature) AS (VALUES
 ('geolock_graph_worker','public.install_routing_policy(uuid,jsonb)'),
 ('geolock_graph_worker','public.freeze_routing_graph(uuid,text,text,text)'),
 ('geolock_graph_worker','public.store_routing_matrix(uuid,uuid,jsonb)'),
 ('geolock_graph_worker','public.read_frozen_routing_graph(uuid,bigint,integer)'),
 ('geolock_planner','public.read_routing_snapshot_bundle(uuid)'),
 ('geolock_planner','public.read_pending_routing_snapshot(uuid)'),
 ('geolock_planner','public.seal_routing_snapshot(uuid,uuid)'),
 ('geolock_planner','public.submit_routing_candidate(uuid,uuid,jsonb)'),
 ('geolock_validator','public.read_routing_work_item(uuid)'),
 ('geolock_validator','public.attest_routing_candidate(uuid,text,jsonb)')
)
SELECT e.role_name,e.signature,
       role.oid IS NOT NULL AS role_present,
       p.oid IS NOT NULL AS function_present,
       CASE WHEN role.oid IS NULL OR p.oid IS NULL THEN NULL
            ELSE has_function_privilege(role.oid,p.oid,'EXECUTE') END AS can_execute
FROM expected e
LEFT JOIN pg_roles role ON role.rolname=e.role_name
LEFT JOIN pg_proc p ON p.oid=to_regprocedure(e.signature)
ORDER BY e.role_name,e.signature;

-- QUERY 10c — inspect effective EXECUTE for the ten Stage A 001 worker
-- functions against application roles and every worker role. The intended
-- worker is shown per function; all other rows are unintended access checks.
-- Presence fields are separate from the privilege result. Catalog-only.
WITH expected(signature,intended_role) AS (VALUES
 ('public.install_routing_policy(uuid,jsonb)','geolock_graph_worker'),
 ('public.freeze_routing_graph(uuid,text,text,text)','geolock_graph_worker'),
 ('public.store_routing_matrix(uuid,uuid,jsonb)','geolock_graph_worker'),
 ('public.read_frozen_routing_graph(uuid,bigint,integer)','geolock_graph_worker'),
 ('public.read_routing_snapshot_bundle(uuid)','geolock_planner'),
 ('public.read_pending_routing_snapshot(uuid)','geolock_planner'),
 ('public.seal_routing_snapshot(uuid,uuid)','geolock_planner'),
 ('public.submit_routing_candidate(uuid,uuid,jsonb)','geolock_planner'),
 ('public.read_routing_work_item(uuid)','geolock_validator'),
 ('public.attest_routing_candidate(uuid,text,jsonb)','geolock_validator')
), roles(role_name) AS (VALUES
 ('anon'),('authenticated'),('service_role'),
 ('geolock_graph_worker'),('geolock_planner'),('geolock_validator')
)
SELECT e.signature,e.intended_role,r.role_name,
       role.oid IS NOT NULL AS role_present,
       p.oid IS NOT NULL AS function_present,
       CASE WHEN role.oid IS NULL OR p.oid IS NULL THEN NULL
            ELSE has_function_privilege(role.oid,p.oid,'EXECUTE') END AS can_execute,
       (r.role_name=e.intended_role) AS is_intended_grantee
FROM expected e CROSS JOIN roles r
LEFT JOIN pg_roles role ON role.rolname=r.role_name
LEFT JOIN pg_proc p ON p.oid=to_regprocedure(e.signature)
ORDER BY e.signature,r.role_name;

-- QUERY 11a — relevant table RLS state, constraints and validation.
SELECT e.schema_name,n.nspowner::regrole AS schema_owner,
       obj_description(n.oid,'pg_namespace') AS schema_comment
FROM (VALUES ('fleet_private'::text),('routing_private'::text)) e(schema_name)
LEFT JOIN pg_namespace n ON n.nspname=e.schema_name
ORDER BY e.schema_name;

SELECT n.nspname AS schema_name,c.relname AS table_name,
       c.relrowsecurity AS rls_enabled,c.relforcerowsecurity AS rls_forced,
       c.relkind
FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE (n.nspname='public' AND c.relname IN
 ('coordination_config','listings','donations','donation_claims','claim_leases',
  'claim_requests','pickup_tasks','pickup_routes','community_hubs','hub_inventory',
  'hub_reservations','hub_batches','hub_batch_members','road_network_coverage',
  'pickup_route_stops','active_task_route_assignments','road_network_nodes','road_network_edges'))
 OR (n.nspname IN ('fleet_private','routing_private') AND c.relkind IN ('r','p','v','m'))
ORDER BY 1,2;

SELECT n.nspname AS schema_name,c.relname AS table_name,con.conname,
       con.contype,pg_get_constraintdef(con.oid,true) AS definition,con.convalidated
FROM pg_constraint con JOIN pg_class c ON c.oid=con.conrelid
JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE (n.nspname='public' AND c.relname IN
 ('coordination_config','listings','donations','donation_claims','claim_leases',
  'claim_requests','pickup_tasks','pickup_routes','community_hubs','hub_inventory',
  'hub_reservations','hub_batches','hub_batch_members','pickup_route_stops',
  'active_task_route_assignments','road_network_coverage','road_network_nodes','road_network_edges'))
 OR (n.nspname IN ('fleet_private','routing_private') AND c.relkind IN ('r','p'))
ORDER BY 1,2,3;

-- QUERY 11a-2 — routing_private constraint continuation. This schema-scoped
-- query avoids repeating the first public-schema page and deterministically
-- returns all constraints on private routing tables.
SELECT n.nspname AS schema_name,c.relname AS table_name,con.conname,
       con.contype,pg_get_constraintdef(con.oid,true) AS definition,
       con.convalidated
FROM pg_constraint con JOIN pg_class c ON c.oid=con.conrelid
JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname='routing_private' AND c.relkind IN ('r','p')
ORDER BY c.relname,con.conname;

-- QUERY 11a-3 — isolate routing_private UNIQUE constraints for comparison
-- with the six reviewed Stage A 001 definitions. No public constraints or
-- application data are returned.
SELECT c.relname AS table_name,con.conname,
       pg_get_constraintdef(con.oid,true) AS definition,con.convalidated
FROM pg_constraint con JOIN pg_class c ON c.oid=con.conrelid
JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname='routing_private' AND c.relkind IN ('r','p')
  AND con.contype='u'
ORDER BY c.relname,con.conname;

-- QUERY 11b — policies and triggers for the same operational surfaces.
SELECT schemaname,tablename,policyname,permissive,roles,cmd,qual,with_check
FROM pg_policies
WHERE (schemaname='public' AND tablename IN
 ('coordination_config','listings','donations','donation_claims','claim_leases',
  'claim_requests','pickup_tasks','pickup_routes','pickup_route_stops',
  'active_task_route_assignments','vehicles','community_hubs','hub_inventory',
  'hub_reservations','hub_batches','hub_batch_members','road_network_coverage',
  'road_network_nodes','road_network_edges'))
 OR schemaname IN ('fleet_private','routing_private')
ORDER BY schemaname,tablename,policyname;

SELECT n.nspname AS schema_name,c.relname AS table_name,t.tgname,
       t.tgenabled,t.tgisinternal,p.oid::regprocedure AS trigger_function,
       pg_get_triggerdef(t.oid,true) AS trigger_definition
FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid
JOIN pg_namespace n ON n.oid=c.relnamespace JOIN pg_proc p ON p.oid=t.tgfoid
WHERE (n.nspname='public' AND c.relname IN
 ('listings','donations','donation_claims','claim_leases','claim_requests',
  'pickup_tasks','pickup_routes','pickup_route_stops','active_task_route_assignments',
  'vehicles','community_hubs','hub_inventory','hub_reservations','hub_batches',
  'hub_batch_members','road_network_coverage','road_network_nodes','road_network_edges'))
 OR n.nspname IN ('fleet_private','routing_private')
ORDER BY 1,2,3;

-- QUERY 11b-2 — application-defined triggers only (exclude internal FK/system
-- triggers) to avoid display truncation and verify routing_task_authority.
SELECT n.nspname AS schema_name,c.relname AS table_name,t.tgname,
       t.tgenabled,t.tgisinternal,p.oid::regprocedure AS trigger_function,
       pg_get_triggerdef(t.oid,true) AS trigger_definition
FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid
JOIN pg_namespace n ON n.oid=c.relnamespace JOIN pg_proc p ON p.oid=t.tgfoid
WHERE NOT t.tgisinternal
  AND ((n.nspname='public' AND c.relname IN
    ('listings','donations','donation_claims','claim_leases','claim_requests',
     'pickup_tasks','pickup_routes','pickup_route_stops','active_task_route_assignments',
     'vehicles','community_hubs','hub_inventory','hub_reservations','hub_batches',
     'hub_batch_members','road_network_coverage','road_network_nodes','road_network_edges'))
    OR n.nspname IN ('fleet_private','routing_private'))
ORDER BY n.nspname,c.relname,t.tgname;

-- QUERY 11c — Stage A 003 function inventory and catalog metadata. It checks
-- exact expected signatures without invoking the functions. Body MD5 is a
-- diagnostic only; compare phase-aware definitions to the reviewed migration.
WITH expected(signature) AS (VALUES
 ('routing_private.lock_route(uuid,boolean)'),
 ('routing_private.close_collected(uuid)'),
 ('routing_private.task_guard()'),
 ('routing_private.check_remaining(uuid,uuid,timestamptz)'),
 ('routing_private.legacy_start_pickup(uuid)'),
 ('routing_private.legacy_complete_pickup(uuid,boolean)'),
 ('routing_private.reconciliation_participant(uuid)'),
 ('routing_private.lock_reconciliation_scope(uuid)'),
 ('routing_private.permit_reconciled_collection(uuid)'),
 ('routing_private.finish_reconciled_collection(uuid)'),
 ('public.close_my_collected_route(uuid,boolean)'),
 ('public.cancel_my_unstarted_route(uuid)'),
 ('public.start_pickup(uuid)'),
 ('public.complete_pickup(uuid,boolean)'),
 ('public.get_my_routing_overview()'),
 ('public.get_my_authorized_route(uuid)'),
 ('public.submit_claim_reconciliation(uuid,boolean,uuid)')
)
SELECT e.signature,
       p.oid IS NOT NULL AS function_present,
       CASE WHEN p.oid IS NULL THEN NULL ELSE p.proowner::regrole::text END AS function_owner,
       p.prosecdef AS security_definer,
       p.provolatile AS volatility,
       pg_get_function_result(p.oid) AS result_type,
       p.proconfig AS function_configuration,
       p.proacl::text AS function_acl,
       CASE WHEN p.oid IS NULL THEN NULL
            ELSE md5(replace(p.prosrc,E'\r\n',E'\n')) END AS body_md5
FROM expected e
LEFT JOIN pg_proc p ON p.oid=to_regprocedure(e.signature)
ORDER BY e.signature;

-- QUERY 11d — Stage A 003 function EXECUTE boundaries. Checks the six
-- authenticated-only public route/pickup/read functions, the reconciliation
-- function whose Stage 1 privilege is preserved, and all ten private helpers
-- against anon/authenticated/service_role and the three worker roles.
-- expected_execute is NULL for service_role on submit_claim_reconciliation:
-- Stage A 003 preserves its earlier grant boundary; report actual privilege
-- without treating that role's effective membership as a new 003 grant.
WITH expected(signature,intended_role,boundary) AS (VALUES
 ('public.close_my_collected_route(uuid,boolean)','authenticated','AUTHENTICATED_ONLY'),
 ('public.cancel_my_unstarted_route(uuid)','authenticated','AUTHENTICATED_ONLY'),
 ('public.start_pickup(uuid)','authenticated','AUTHENTICATED_ONLY'),
 ('public.complete_pickup(uuid,boolean)','authenticated','AUTHENTICATED_ONLY'),
 ('public.get_my_routing_overview()','authenticated','AUTHENTICATED_ONLY'),
 ('public.get_my_authorized_route(uuid)','authenticated','AUTHENTICATED_ONLY'),
 ('public.submit_claim_reconciliation(uuid,boolean,uuid)','authenticated','PRESERVED_STAGE1_BOUNDARY'),
 ('routing_private.lock_route(uuid,boolean)','postgres (owner)','PRIVATE_HELPER'),
 ('routing_private.close_collected(uuid)','postgres (owner)','PRIVATE_HELPER'),
 ('routing_private.task_guard()','postgres (owner)','PRIVATE_HELPER'),
 ('routing_private.check_remaining(uuid,uuid,timestamptz)','postgres (owner)','PRIVATE_HELPER'),
 ('routing_private.legacy_start_pickup(uuid)','postgres (owner)','PRIVATE_HELPER'),
 ('routing_private.legacy_complete_pickup(uuid,boolean)','postgres (owner)','PRIVATE_HELPER'),
 ('routing_private.reconciliation_participant(uuid)','postgres (owner)','PRIVATE_HELPER'),
 ('routing_private.lock_reconciliation_scope(uuid)','postgres (owner)','PRIVATE_HELPER'),
 ('routing_private.permit_reconciled_collection(uuid)','postgres (owner)','PRIVATE_HELPER'),
 ('routing_private.finish_reconciled_collection(uuid)','postgres (owner)','PRIVATE_HELPER')
), roles(role_name) AS (VALUES
 ('anon'),('authenticated'),('service_role'),
 ('geolock_graph_worker'),('geolock_planner'),('geolock_validator')
)
SELECT e.signature,e.boundary,e.intended_role,r.role_name,
       role.oid IS NOT NULL AS role_present,
       p.oid IS NOT NULL AS function_present,
       CASE WHEN role.oid IS NULL OR p.oid IS NULL THEN NULL
            ELSE has_function_privilege(role.oid,p.oid,'EXECUTE') END AS can_execute,
       CASE
         WHEN e.boundary='PRIVATE_HELPER' THEN false
         WHEN e.boundary='PRESERVED_STAGE1_BOUNDARY' AND r.role_name='service_role' THEN NULL
         ELSE r.role_name=e.intended_role
       END AS expected_execute
FROM expected e CROSS JOIN roles r
LEFT JOIN pg_roles role ON role.rolname=r.role_name
LEFT JOIN pg_proc p ON p.oid=to_regprocedure(e.signature)
ORDER BY e.signature,r.role_name;

-- QUERY 11d-2 — focused continuation for routing_private.task_guard(),
-- which was at the truncation point of Query 11d. Checks all six roles and
-- returns role/function presence separately from effective EXECUTE.
WITH roles(role_name) AS (VALUES
 ('anon'),('authenticated'),('service_role'),
 ('geolock_graph_worker'),('geolock_planner'),('geolock_validator')
), target AS (
 SELECT to_regprocedure('routing_private.task_guard()') AS function_oid
)
SELECT r.role_name,
       role.oid IS NOT NULL AS role_present,
       target.function_oid IS NOT NULL AS function_present,
       CASE WHEN role.oid IS NULL OR target.function_oid IS NULL THEN NULL
            ELSE has_function_privilege(role.oid,target.function_oid,'EXECUTE') END AS can_execute,
       false AS expected_execute_for_checked_non_owner_roles
FROM roles r CROSS JOIN target
LEFT JOIN pg_roles role ON role.rolname=r.role_name
ORDER BY r.role_name;

-- QUERY 12 — exact coordination policy and aggregate road metadata only.
SELECT singleton,claim_lease_minutes,donation_direct_min_kg,geofence_radius_m,config_version
FROM public.coordination_config ORDER BY singleton;

SELECT c.network_snapshot_id,c.dataset_kind,c.active_flag,
       c.approved_at IS NOT NULL AS approved,
       c.max_snap_distance_m,
       (SELECT count(*) FROM public.road_network_nodes n
        WHERE n.network_snapshot_id=c.network_snapshot_id AND n.active_flag) AS active_node_count,
       (SELECT count(*) FROM public.road_network_edges e
        JOIN public.road_network_nodes n ON n.osm_node_id=e.source_node
        WHERE n.network_snapshot_id=c.network_snapshot_id AND n.active_flag) AS active_edge_count
FROM public.road_network_coverage c ORDER BY c.network_snapshot_id;
