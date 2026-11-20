-- For the routing owner, after the switch to OSM-OPS-20261018-KLSEL.
--
-- The routing worker reads a frozen copy description of the road network
-- (routing_private.graphs). The graph frozen on 2026-11 for OSM-OPS-20261018
-- (926,414 nodes, 2,145,828 edges) no longer matches the tables, so the worker
-- refuses it. This freezes a new graph for the KL, Putrajaya and Selangor network.
-- Same call, guards and settings as
-- docs/stage8/stage-a/deployment-preparation/routing-initialization/freeze_routing_graph.proposed.sql,
-- only the request id and the snapshot id are new. No routing function is changed.
--
-- Run with psql as geolock_graph_login (the SQL Editor runs as postgres and is refused):
--   psql "service=geolock_graph" -f supabase/road_network/freeze_kl_selangor_graph.sql
-- Then set GEOLOCK_GRAPH_ID of the planner to the graph_id it prints, and delete the
-- old graph cache under the worker state folder (graphs/).
-- Expected counts in routing_private.graphs: 205,524 nodes and 454,178 edges.
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL ROLE geolock_graph_worker;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='120s';
DO $guard$
BEGIN
 IF session_user <> 'geolock_graph_login' OR current_user <> 'geolock_graph_worker'
 OR current_setting('transaction_read_only') <> 'off'
 OR NOT pg_has_role(session_user,'geolock_graph_worker','MEMBER')
 OR pg_has_role(session_user,'geolock_planner','MEMBER')
 OR pg_has_role(session_user,'geolock_validator','MEMBER')
 OR EXISTS(SELECT 1 FROM pg_roles WHERE rolname=session_user AND
    (rolsuper OR rolbypassrls OR rolcreaterole OR rolcreatedb))
 THEN RAISE EXCEPTION 'APPROVED_GRAPH_IDENTITY_REQUIRED'; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_proc WHERE oid='public.freeze_routing_graph(uuid,text,text,text)'::regprocedure
   AND md5(replace(prosrc,E'\r\n',E'\n'))='8e1434ea2727e30f898ddff289ac2df3' AND prosecdef AND provolatile='v'
   AND prorettype='uuid'::regtype AND pg_get_userbyid(proowner)='postgres'
   AND proconfig=ARRAY['search_path=pg_catalog, pg_temp','TimeZone=UTC','extra_float_digits=0']::text[])
 OR NOT has_function_privilege(current_user,'public.freeze_routing_graph(uuid,text,text,text)','EXECUTE')
 THEN RAISE EXCEPTION 'RPC_CONTRACT_DRIFT'; END IF;
END $guard$;
SELECT public.freeze_routing_graph('6daa90ff-c95e-427e-adf6-6a68a5cda859'::uuid, 'OSM-OPS-20261018-KLSEL'::text, 'OSM_MAXSPEED_OR_CLASS_DEFAULT_BUILD_188bde7568b4d9eb_DIST5DP_TIME4DP_NO_LIVE_TRAFFIC_PG_REAL_OUTPUT_0'::text, 'EXACT_MAX_6_DECIMALS'::text) AS graph_id;
COMMIT;
