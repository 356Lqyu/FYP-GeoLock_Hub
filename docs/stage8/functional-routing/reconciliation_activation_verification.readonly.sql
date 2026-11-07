-- Installer/operator-run SELECT-only verification; no configuration changes.
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout='15s';
SET LOCAL lock_timeout='2s';
SET LOCAL idle_in_transaction_session_timeout='60s';
SELECT current_database(),current_user,session_user,
 current_setting('transaction_read_only') AS read_only,
 (SELECT ssl FROM pg_stat_ssl WHERE pid=pg_backend_pid()) AS ssl;
SELECT enabled FROM resolution_private.config WHERE singleton;
SELECT rolname,rolcanlogin,rolinherit,rolsuper,rolcreatedb,rolcreaterole,
 rolreplication,rolbypassrls,rolconnlimit FROM pg_roles
 WHERE rolname IN('geolock_route_resolver','geolock_resolution_operator_login');
SELECT roleid::regrole AS granted_role,member::regrole AS member,
 admin_option,inherit_option,set_option FROM pg_auth_members
 WHERE roleid='geolock_route_resolver'::regrole;
SELECT login_name,operator_label,active FROM resolution_private.operators;
SELECT r.rolname,
 has_function_privilege(r.oid,'public.finalize_route_resolution(uuid,bigint,uuid)','EXECUTE') AS finalizer,
 has_function_privilege(r.oid,'public.register_route_test_provenance(uuid,text,uuid,uuid,uuid[],uuid)','EXECUTE') AS provenance,
 has_function_privilege(r.oid,'public.get_my_route_resolution_receipt(uuid)','EXECUTE') AS receipts,
 has_table_privilege(r.oid,'resolution_private.operators','INSERT,UPDATE,DELETE') AS direct_operator_write,
 has_table_privilege(r.oid,'resolution_private.config','UPDATE') AS direct_config_write
 FROM pg_roles r WHERE rolname IN('anon','authenticated','service_role','geolock_route_resolver','geolock_resolution_operator_login');
SELECT r.route_id,r.route_status,b.started_at,b.closed_at,
 (SELECT count(*) FROM public.active_task_route_assignments a WHERE a.route_id=r.route_id) AS assignments
 FROM public.pickup_routes r JOIN routing_private.bindings b USING(route_id)
 WHERE r.route_id IN('db1b455e-92d0-4d58-9fa1-5de07d7ab0f9','7dd2d00a-ff03-4021-994f-155bbfc8e12c');
SELECT count(*) AS new_resolution_cases FROM resolution_private.cases;
SELECT count(*) AS new_resolution_evidence FROM resolution_private.evidence;
ROLLBACK;
