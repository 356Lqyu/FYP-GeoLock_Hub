-- SUPERSEDED HISTORICAL DRAFT. Use export_current_dev.py for hex-preserving export/receipt.
-- Not sufficient for the new storage-equivalence verifier. Retained without execution.
-- Run from a NEW empty local export directory, using approved read-only export profile.
-- Client-side files only; no server file reads/writes, no database modifications.
\set ON_ERROR_STOP on
BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout='60s';
SET LOCAL extra_float_digits=0;
SELECT statement_timestamp(),current_database(),current_user,session_user,
 current_setting('transaction_read_only'),current_setting('extra_float_digits');
SELECT ssl,version,cipher FROM pg_stat_ssl WHERE pid=pg_backend_pid();
\copy (SELECT osm_node_id,network_snapshot_id,latitude,longitude,component_id,CASE WHEN active_flag THEN 'true' ELSE 'false' END AS active_flag FROM public.road_network_nodes ORDER BY osm_node_id) TO 'road_network_nodes.csv' WITH (FORMAT csv,HEADER true)
\copy (SELECT source_node,target_node,road_km::text AS road_km,travel_minutes::text AS travel_minutes FROM public.road_network_edges ORDER BY edge_id) TO 'road_network_edges.csv' WITH (FORMAT csv,HEADER true)
ROLLBACK;
