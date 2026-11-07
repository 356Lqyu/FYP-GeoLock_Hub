-- PROPOSED POST-DEPLOYMENT CHECKS ONLY. SELECT-only. Not authenticated proof.
-- Confirm DEV URL rcgyuwiidqvrgbxswhqj out of band before executing.
SELECT obj_description('fleet_private'::regnamespace,'pg_namespace')=
 'geolock-stage8-c1-v2:'||fleet_private.installation_fingerprint() AS c1_seal_valid;
SELECT (SELECT count(*) FROM public.vehicles) AS vehicles,(SELECT count(*) FROM public.pickup_routes) AS routes,
 (SELECT count(*) FROM public.pickup_route_stops) AS stops,(SELECT count(*) FROM public.active_task_route_assignments) AS assignments;
SELECT task_status,count(*) FROM public.pickup_tasks GROUP BY task_status ORDER BY task_status;
SELECT rolname,rolcanlogin,rolsuper,rolcreaterole,rolcreatedb,rolbypassrls
 FROM pg_roles WHERE rolname IN ('geolock_graph_worker','geolock_planner','geolock_validator');
SELECT r.rolname, m.rolname AS member_role, am.admin_option
 FROM pg_auth_members am JOIN pg_roles r ON r.oid=am.roleid JOIN pg_roles m ON m.oid=am.member
 WHERE r.rolname IN ('geolock_graph_worker','geolock_planner','geolock_validator');
SELECT c.relname,c.relrowsecurity,c.relowner::regrole,c.relacl FROM pg_class c
 JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='routing_private' AND c.relkind='r' ORDER BY c.relname;
SELECT n.nspname,p.proname,pg_get_function_identity_arguments(p.oid) AS signature,p.prosecdef,
 p.proowner::regrole,p.proconfig,p.proacl FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
 WHERE n.nspname='routing_private' OR (n.nspname='public' AND p.proname IN (
 'install_routing_policy','freeze_routing_graph','store_routing_matrix','begin_my_routing_snapshot','seal_routing_snapshot',
 'submit_routing_candidate','read_routing_work_item','attest_routing_candidate','read_frozen_routing_graph',
 'read_routing_snapshot_bundle','read_pending_routing_snapshot','authorize_my_routing_candidate',
 'cancel_my_unstarted_route','close_my_collected_route','start_pickup','complete_pickup','assign_task_to_route')) ORDER BY 1,2;
SELECT r.role,t.tbl,has_table_privilege(r.role,'public.'||t.tbl,'INSERT,UPDATE,DELETE,TRUNCATE') AS any_table_write,
 has_any_column_privilege(r.role,'public.'||t.tbl,'INSERT,UPDATE') AS any_column_write
 FROM (VALUES('anon'),('authenticated')) r(role)
 CROSS JOIN (VALUES('pickup_routes'),('pickup_route_stops'),('active_task_route_assignments'),('pickup_tasks')) t(tbl);
SELECT t.tgrelid::regclass,t.tgname,t.tgenabled,pg_get_triggerdef(t.oid)
 FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace
 WHERE NOT t.tgisinternal AND (n.nspname='routing_private' OR t.tgname LIKE 'routing_%') ORDER BY 1,2;
SELECT * FROM routing_private.bindings b WHERE b.closed_at IS NULL AND NOT EXISTS(
 SELECT 1 FROM public.pickup_routes r WHERE r.route_id=b.route_id AND r.vehicle_id=b.vehicle_id AND r.ngo_user_id=b.ngo_id
 AND r.route_status IN ('AUTHORISED','IN_PROGRESS'));
SELECT * FROM routing_private.items i WHERE released_at IS NULL AND NOT EXISTS(
 SELECT 1 FROM public.active_task_route_assignments a WHERE a.route_id=i.route_id AND a.task_id=i.task_id);
-- Also compare protected_object_snapshot.sql against the PRE-deployment capture
-- using the explicitly reviewed differences in README.md, not a blind new seal.
