-- Investigation query plan ONLY. NOT EXECUTED: approved read-only MCP is unavailable.
-- Not a migration. Reconnect only through the project's approved DEV inspection method.
-- Confirm the externally selected project is rcgyuwiidqvrgbxswhqj before running.
-- No routing/eligibility/application RPC is invoked; no EXPLAIN ANALYZE or traversal.
-- First run catalog inventory. Run the second block only after confirming tables exist.

BEGIN READ ONLY;
SET LOCAL statement_timeout = '5s';
SET LOCAL lock_timeout = '1s';
SELECT current_database(), current_user, session_user, version(),
       clock_timestamp() AS inspected_at, current_setting('transaction_read_only');
SELECT extname, extversion, extnamespace::regnamespace FROM pg_extension
 WHERE extname IN ('postgis','pgrouting','pg_stat_statements');
SELECT n.nspname, c.relname, c.relkind, c.relispartition, c.reltuples AS estimated_rows,
       pg_total_relation_size(c.oid) AS total_bytes
 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
 WHERE (n.nspname='public' AND c.relname IN
   ('road_network_nodes','road_network_edges','road_network_coverage','ngo_listing_road_eligibility'))
    OR (n.nspname='routing_private' AND c.relname IN ('graphs','matrices'));
SELECT table_schema,table_name,column_name,data_type,udt_name
 FROM information_schema.columns
 WHERE (table_schema='public' AND table_name IN
   ('road_network_nodes','road_network_edges','road_network_coverage','ngo_listing_road_eligibility'))
    OR (table_schema='routing_private' AND table_name IN ('graphs','matrices'))
 ORDER BY table_schema,table_name,ordinal_position;
SELECT schemaname,tablename,indexname,indexdef FROM pg_indexes
 WHERE (schemaname='public' AND tablename IN
   ('road_network_nodes','road_network_edges','road_network_coverage','ngo_listing_road_eligibility'))
    OR (schemaname='routing_private' AND tablename IN ('graphs','matrices'))
 ORDER BY schemaname,tablename,indexname;
SELECT parent.oid::regclass AS parent, child.oid::regclass AS child
 FROM pg_inherits i JOIN pg_class parent ON parent.oid=i.inhparent
 JOIN pg_class child ON child.oid=i.inhrelid
 WHERE parent.oid IN (to_regclass('public.road_network_nodes'),to_regclass('public.road_network_edges'));
SELECT n.nspname,p.oid::regprocedure AS signature,p.prosecdef,p.provolatile,p.proconfig,
       pg_get_userbyid(p.proowner) AS owner,md5(replace(p.prosrc,chr(13),'')) AS body_md5
 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
 WHERE p.proname IN ('read_frozen_routing_graph','store_routing_matrix','read_routing_snapshot_bundle',
  'geolock_road_costs','geolock_road_eligible_km','geolock_active_road_snapshot',
  'pgr_dijkstracost','pgr_dijkstracostmatrix','pgr_dijkstra');
SELECT r.rolname,p.oid::regprocedure AS signature,has_function_privilege(r.oid,p.oid,'EXECUTE') AS can_execute
 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace CROSS JOIN pg_roles r
 WHERE r.rolname IN ('anon','authenticated','service_role','geolock_graph_worker','geolock_planner','geolock_validator')
 AND p.proname IN ('read_frozen_routing_graph','store_routing_matrix','geolock_road_costs','pgr_dijkstracost');
ROLLBACK;

-- Exact counts are bounded by statement_timeout, not replaced by pg_class estimates.
-- Any timeout/permission error leaves a field UNKNOWN. Never retry without bounds.
BEGIN READ ONLY;
SET LOCAL statement_timeout = '5s';
SET LOCAL lock_timeout = '1s';
SELECT count(*) AS exact_nodes FROM public.road_network_nodes;
SELECT count(*) AS exact_edges FROM public.road_network_edges;
SELECT network_snapshot_id,count(*) AS exact_nodes
 FROM public.road_network_nodes GROUP BY network_snapshot_id;
SELECT network_snapshot_id,dataset_kind,active_flag,approved_at,node_count,edge_count
 FROM public.road_network_coverage ORDER BY network_snapshot_id LIMIT 20;
SELECT graph_id,coverage_snapshot,node_count,edge_count,content_digest,speed_profile,
       precision_policy,float_output_profile
 FROM routing_private.graphs ORDER BY created_at DESC LIMIT 20;
SELECT graph_id,count(*) AS matrices FROM routing_private.matrices GROUP BY graph_id LIMIT 20;
ROLLBACK;
