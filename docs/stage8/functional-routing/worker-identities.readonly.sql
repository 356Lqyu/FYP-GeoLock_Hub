-- Native psql operator check; no mutating RPCs. Pass one fixed worker_role below.
\set ON_ERROR_STOP on
BEGIN READ ONLY;
SET LOCAL statement_timeout='10s';
SET LOCAL ROLE :"worker_role";
SELECT session_user,current_user,current_database(),current_setting('transaction_read_only') AS read_only,
 (SELECT ssl FROM pg_stat_ssl WHERE pid=pg_backend_pid()) AS ssl,
 pg_has_role(session_user,current_user,'MEMBER') AS intended_member,
 (SELECT jsonb_build_object('super',rolsuper,'bypassrls',rolbypassrls,'createdb',rolcreatedb,'createrole',rolcreaterole)
  FROM pg_roles WHERE rolname=session_user) AS attributes,
 (SELECT jsonb_agg(rolname) FROM pg_roles WHERE rolname IN ('geolock_graph_worker','geolock_planner','geolock_validator')
  AND pg_has_role(session_user,oid,'MEMBER')) AS memberships;
SELECT p.oid::regprocedure AS rpc,has_function_privilege(current_user,p.oid,'EXECUTE') AS can_execute
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public' AND p.proname IN ('read_frozen_routing_graph','store_routing_matrix',
 'read_pending_routing_snapshot','seal_routing_snapshot','read_routing_snapshot_bundle',
 'submit_routing_candidate','read_routing_work_item','attest_routing_candidate') ORDER BY 1;
ROLLBACK;
