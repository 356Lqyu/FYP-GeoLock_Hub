\set ON_ERROR_STOP on
-- No ANALYZE option: EXPLAIN plans only; no graph export, query execution or DDL.
BEGIN READ ONLY;
SET LOCAL statement_timeout='10s';
SET LOCAL lock_timeout='2s';
SELECT session_user,current_user,current_database(),current_setting('transaction_read_only') AS read_only;
SELECT schemaname,tablename,indexname,indexdef
FROM pg_indexes
WHERE schemaname='public' AND tablename IN ('road_network_nodes','road_network_edges')
ORDER BY tablename,indexname;
-- Confirm the installed RPC source hash and owner without executing it.
SELECT p.oid::regprocedure AS signature,pg_get_userbyid(p.proowner) AS owner,
       p.prosecdef,p.proconfig,md5(pg_get_functiondef(p.oid)) AS definition_md5
FROM pg_proc p WHERE p.oid='public.read_frozen_routing_graph(uuid,bigint,integer)'::regprocedure;
-- Same inner edge SELECT, frozen at the last completed cursor from the failure.
-- FORMAT JSON planning only, not EXPLAIN ANALYZE. Upper RPC jsonb aggregation
-- and SECURITY DEFINER plan caching are not measured by these inner plans.
EXPLAIN (FORMAT JSON)
SELECT edge_id,source_node,target_node,road_km,travel_minutes
FROM public.road_network_edges
WHERE edge_id>1410000 ORDER BY edge_id LIMIT 10000;
-- PostgreSQL17 can display generic parameter plans without PREPARE or execution.
EXPLAIN (GENERIC_PLAN,FORMAT JSON)
SELECT edge_id,source_node,target_node,road_km,travel_minutes
FROM public.road_network_edges
WHERE ($1::integer IS NULL OR edge_id>$1::integer)
ORDER BY edge_id LIMIT 10000;
EXPLAIN (FORMAT JSON)
SELECT osm_node_id,network_snapshot_id,active_flag
FROM public.road_network_nodes
WHERE osm_node_id>14297239934 ORDER BY osm_node_id LIMIT 10000;
ROLLBACK;
