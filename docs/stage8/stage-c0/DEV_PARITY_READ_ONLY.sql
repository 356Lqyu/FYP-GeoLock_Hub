-- GeoLock Hub Stage C.0: OFFLINE-prepared DEV parity queries.
-- Not executed by Stage C.0. Run only after separate explicit approval.
-- Intended for psql, as a read-only database role/session where possible.
-- No application RPCs, business-row reads, writes, or credentials are included.
\set ON_ERROR_STOP on
BEGIN READ ONLY;

-- 1. Server and installed extension versions.
SELECT current_setting('server_version') AS server_version,
       current_setting('server_version_num') AS server_version_num,
       current_database() AS database_name,
       current_user AS inspection_role,
       session_user AS session_role,
       current_setting('transaction_read_only') AS transaction_read_only;
SELECT e.extname, e.extversion, n.nspname AS extension_schema
FROM pg_extension e JOIN pg_namespace n ON n.oid=e.extnamespace
WHERE e.extname IN ('postgis','pgrouting')
ORDER BY e.extname;
SELECT p.oid::regprocedure AS pg_dijkstra_signature,
       pg_get_function_result(p.oid) AS result_type,
       p.provolatile AS volatility
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='extensions' AND p.proname ILIKE 'pgr_dijkstraCost'
ORDER BY p.oid::regprocedure::text;

-- 2. Migration ledger presence and versions only; no project/user data.
SELECT to_regclass('supabase_migrations.schema_migrations') IS NOT NULL
       AS supabase_migration_ledger_present \gset
\if :supabase_migration_ledger_present
SELECT version, name
FROM supabase_migrations.schema_migrations
ORDER BY version, name;
\else
\echo 'UNKNOWN: Supabase migration ledger relation is absent or not visible; inspect approved deployment history separately.'
\endif

-- 3. Function source/metadata. MD5 matches repository guards over normalized
-- pg_proc.prosrc (not pg_get_functiondef). Full definitions are returned for
-- manual comparison; review output securely and do not publish credentials.
WITH expected(signature, expected_pre_md5, expected_reviewed_md5, expected_security, expected_config) AS (
  VALUES
  ('public.start_pickup(uuid)', 'e89b650c83713b04e8310f4c372f10f4', NULL::text, true, ARRAY['search_path=public, extensions, pg_temp']::text[]),
  ('public.complete_pickup(uuid,boolean)', 'ae1b885377292281da17951cb18afd55', NULL::text, true, ARRAY['search_path=public, extensions, pg_temp']::text[]),
  ('public.submit_claim_reconciliation(uuid,boolean,uuid)', '246a33d552da2ac4e229fa79c357d194', NULL::text, true, ARRAY['search_path=pg_catalog, public, pg_temp']::text[]),
  ('public.recover_expired_claims(integer)', '89e01f42d5ec23bfcbcdc47c1f4fd4e5', NULL::text, true, ARRAY['search_path=pg_catalog, public, extensions, pg_temp']::text[]),
  ('public.claim_listing(uuid,uuid)', '2c1f60c876797c61b44b3cb43591bab8', 'c8d324772b12c843fba231e7ea733914', true, ARRAY['search_path=pg_catalog, public, extensions, pg_temp']::text[]),
  ('public.geolock_transition_listing_donations(uuid,text,text,uuid,uuid,text)', '67f27a85fb9129c9017bb0e9178f8ba1', NULL::text, false, ARRAY['search_path=pg_catalog, public, pg_temp']::text[]),
  ('public.geolock_lock_listing_donations(uuid,text[])', '90816e7c6db3606dc8b6451a899d8036', 'e97a3fd80673a827465f3eaa79b65903', false, ARRAY['search_path=pg_catalog, public, pg_temp']::text[]),
  ('public.geolock_resolve_road_node(double precision,double precision)', '9701683fdcfeb2486c887860c6470262', '3e2ae3b624e0276110b5029231671df0', true, ARRAY['search_path=public, extensions, pg_temp']::text[]),
  ('public.geolock_road_costs(bigint[],bigint[],double precision,double precision,double precision)', '828217e0b8faeeb3d32fa726b3e06a2a', '53bac7e143510f560006bb641024c1a3', true, ARRAY['search_path=public, extensions, pg_temp']::text[]),
  ('public.assign_task_to_route(uuid,uuid,integer)', '047f2b5d6a4483b8cef8e3b91c9dc299', NULL::text, true, ARRAY['search_path=pg_catalog, pg_temp','TimeZone=UTC','extra_float_digits=0']::text[])
), actual AS (
  SELECT e.*, p.oid, p.proowner::regrole::text AS owner,
         p.prosecdef AS security_definer, p.proconfig,
         p.provolatile, pg_get_function_identity_arguments(p.oid) AS identity_arguments,
         pg_get_function_result(p.oid) AS result_type,
         md5(replace(p.prosrc,E'\r\n',E'\n')) AS body_md5,
         p.proacl::text AS acl, pg_get_functiondef(p.oid) AS definition
  FROM expected e LEFT JOIN pg_proc p ON p.oid=to_regprocedure(e.signature)
)
SELECT signature, expected_pre_md5, expected_reviewed_md5, body_md5,
       owner, security_definer, proconfig, provolatile,
       identity_arguments, result_type, acl,
       CASE WHEN oid IS NULL THEN 'MISMATCH'
            WHEN body_md5=expected_pre_md5 THEN 'PRE-MIGRATION SOURCE'
            WHEN expected_reviewed_md5 IS NOT NULL AND body_md5=expected_reviewed_md5 THEN 'REVIEWED FORWARD BODY'
            WHEN expected_reviewed_md5 IS NULL THEN 'NO POST-MIGRATION HASH PIN; COMPARE TO REVIEWED ARTIFACT'
            ELSE 'MISMATCH / REVIEW REQUIRED' END AS body_status,
       (owner='postgres'
        AND security_definer=expected_security
        AND proconfig IS NOT DISTINCT FROM expected_config) AS expected_owner_security_config,
       definition
FROM actual ORDER BY signature;

-- Exact assignment definition hash guard used by Stage A (SHA-256 over
-- pg_get_functiondef); this is separate from the prosrc MD5 above.
SELECT encode(sha256(convert_to(pg_get_functiondef(
         'public.assign_task_to_route(uuid,uuid,integer)'::regprocedure),'UTF8')),'hex')
       AS assign_task_definition_sha256;

-- 4. Execute privileges for reviewed public/private functions. This checks
-- effective privilege for the named roles; it does not list role membership.
WITH roles(role_name) AS (VALUES ('anon'),('authenticated'),('service_role'),
 ('geolock_graph_worker'),('geolock_planner'),('geolock_validator')),
 funcs(signature) AS (VALUES
 ('public.claim_listing(uuid,uuid)'),
 ('public.geolock_lock_listing_donations(uuid,text[])'),
 ('public.geolock_transition_listing_donations(uuid,text,text,uuid,uuid,text)'),
 ('public.geolock_resolve_road_node(double precision,double precision)'),
 ('public.geolock_road_costs(bigint[],bigint[],double precision,double precision,double precision)'),
 ('public.start_pickup(uuid)'),('public.complete_pickup(uuid,boolean)'),
 ('public.submit_claim_reconciliation(uuid,boolean,uuid)'),
 ('public.assign_task_to_route(uuid,uuid,integer)'),
 ('public.authorize_my_routing_candidate(uuid,uuid,timestamptz)'),
 ('public.get_my_routing_overview()'),('public.get_my_authorized_route(uuid)'))
)
SELECT f.signature, r.role_name,
       CASE WHEN to_regrole(r.role_name) IS NULL OR to_regprocedure(f.signature) IS NULL THEN NULL
            ELSE has_function_privilege(to_regrole(r.role_name),to_regprocedure(f.signature),'EXECUTE') END AS can_execute
FROM funcs f CROSS JOIN roles r ORDER BY f.signature,r.role_name;

-- 5. Relevant tables, RLS flags, constraints, policies, and triggers.
SELECT n.nspname AS schema_name, c.relname AS table_name,
       c.relrowsecurity AS rls_enabled, c.relforcerowsecurity AS rls_forced,
       c.relkind
FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE (n.nspname='public' AND c.relname IN
 ('coordination_config','listings','donations','donation_claims','claim_leases',
  'claim_requests','pickup_tasks','pickup_routes','route_assignments','community_hubs',
  'hub_inventory','hub_reservations','hub_batches','hub_batch_members',
  'road_network_coverage','road_network_nodes','road_network_edges'))
 OR (n.nspname='routing_private' AND c.relkind IN ('r','p'))
ORDER BY 1,2;

SELECT n.nspname AS schema_name, c.relname AS table_name, con.conname,
       con.contype, pg_get_constraintdef(con.oid,true) AS definition,
       con.convalidated
FROM pg_constraint con JOIN pg_class c ON c.oid=con.conrelid
JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE (n.nspname='public' AND c.relname IN
 ('coordination_config','listings','donations','donation_claims','claim_leases',
  'claim_requests','pickup_tasks','pickup_routes','community_hubs',
  'hub_inventory','hub_reservations','hub_batches','hub_batch_members'))
 OR (n.nspname='routing_private' AND c.relkind IN ('r','p'))
ORDER BY 1,2,3;

SELECT schemaname, tablename, policyname, permissive, roles, cmd, qual, with_check
FROM pg_policies
WHERE (schemaname='public' AND tablename IN
 ('coordination_config','listings','donations','donation_claims','claim_leases',
  'claim_requests','pickup_tasks','pickup_routes','route_assignments','community_hubs',
  'hub_inventory','hub_reservations','hub_batches','hub_batch_members',
  'road_network_coverage','road_network_nodes','road_network_edges'))
 OR schemaname IN ('routing_private','fleet_private')
ORDER BY schemaname,tablename,policyname;

SELECT n.nspname AS schema_name, c.relname AS table_name, t.tgname,
       t.tgenabled, t.tgisinternal, p.oid::regprocedure AS trigger_function,
       pg_get_triggerdef(t.oid,true) AS definition
FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid
JOIN pg_namespace n ON n.oid=c.relnamespace JOIN pg_proc p ON p.oid=t.tgfoid
WHERE (n.nspname='public' AND c.relname IN
 ('listings','donations','donation_claims','claim_leases','claim_requests',
  'pickup_tasks','pickup_routes','community_hubs','hub_inventory','hub_reservations',
  'hub_batches','hub_batch_members','road_network_coverage','road_network_nodes','road_network_edges'))
 OR n.nspname='routing_private'
ORDER BY 1,2,3;

-- 6. Coordination configuration: policy values only, no actor or donation rows.
SELECT singleton, claim_lease_minutes, donation_direct_min_kg, geofence_radius_m,
       config_version
FROM public.coordination_config ORDER BY singleton;

-- Road snapshot inventory summary only; no coordinates or personal data.
SELECT network_snapshot_id, dataset_kind, active_flag, approved_at IS NOT NULL AS approved,
       max_snap_distance_m,
       (SELECT count(*) FROM public.road_network_nodes n
        WHERE n.network_snapshot_id=c.network_snapshot_id AND n.active_flag) AS active_node_count,
       (SELECT count(*) FROM public.road_network_edges e
        JOIN public.road_network_nodes n ON n.osm_node_id=e.source_node
        WHERE n.network_snapshot_id=c.network_snapshot_id AND n.active_flag) AS active_edge_count
FROM public.road_network_coverage c ORDER BY network_snapshot_id;

ROLLBACK;
