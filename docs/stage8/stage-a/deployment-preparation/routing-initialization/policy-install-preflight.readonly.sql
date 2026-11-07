-- PREPARED ONLY. Scoped graph-login identity/permission check; no write RPC.
\set ON_ERROR_STOP on
BEGIN READ ONLY;
SET LOCAL statement_timeout='10s';
SET LOCAL ROLE geolock_graph_worker;
SELECT session_user, current_user, current_database(),
 current_setting('transaction_read_only') AS read_only,
 (SELECT ssl FROM pg_stat_ssl WHERE pid=pg_backend_pid()) AS ssl,
 session_user='geolock_graph_login' AND current_user='geolock_graph_worker'
 AND current_database()='postgres'
 AND pg_has_role(session_user,'geolock_graph_worker','MEMBER')
 AND NOT pg_has_role(session_user,'geolock_planner','MEMBER')
 AND NOT pg_has_role(session_user,'geolock_validator','MEMBER')
 AND NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname=session_user AND
 (rolsuper OR rolbypassrls OR rolcreaterole OR rolcreatedb)) AS identity_matches;
SELECT p.oid::regprocedure AS signature, p.proargnames,
 pg_get_userbyid(p.proowner) AS owner, p.prosecdef, p.provolatile, p.proconfig,
 md5(replace(p.prosrc,E'\r\n',E'\n')) AS normalized_source_md5,
 has_function_privilege(current_user,p.oid,'EXECUTE') AS can_execute
FROM pg_proc p WHERE p.oid='public.install_routing_policy(uuid,jsonb)'::regprocedure;
ROLLBACK;
