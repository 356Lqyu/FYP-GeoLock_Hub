-- PREPARED SELECT ONLY; not executed. Verify DEV endpoint out of band first.
-- This is source evidence, not full permission, fixture or runtime acceptance.
SELECT e.signature,CASE WHEN p.oid IS NULL THEN 'FAIL'
 WHEN md5(replace(p.prosrc,E'\r\n',E'\n'))=e.body_md5 AND p.proowner='postgres'::regrole
 AND p.prosecdef THEN 'PASS' ELSE 'FAIL' END AS status,
 md5(replace(p.prosrc,E'\r\n',E'\n')) AS actual_body_md5,p.proconfig,p.proacl
FROM (VALUES
('public.claim_listing(uuid,uuid)','2c1f60c876797c61b44b3cb43591bab8'),
('public.recover_expired_claims(integer)','89e01f42d5ec23bfcbcdc47c1f4fd4e5'),
('public.start_pickup(uuid)','cb306433867538804b67aa1a242867b4'),
('public.complete_pickup(uuid,boolean)','26f0cd8cebe783c65b45e05649693860'),
('public.submit_claim_reconciliation(uuid,boolean,uuid)','8cd1c3c183bb1af41bebc9094556a905'),
('routing_private.legacy_start_pickup(uuid)','e89b650c83713b04e8310f4c372f10f4'),
('routing_private.legacy_complete_pickup(uuid,boolean)','ae1b885377292281da17951cb18afd55')) e(signature,body_md5)
LEFT JOIN pg_proc p ON p.oid=to_regprocedure(e.signature) ORDER BY e.signature;
SELECT 'routing_task_authority' AS check_name,CASE WHEN EXISTS(
 SELECT 1 FROM pg_trigger WHERE tgrelid=to_regclass('public.pickup_tasks')
 AND tgname='routing_task_authority' AND tgenabled='O'
 AND tgfoid=to_regprocedure('routing_private.task_guard()')) THEN 'PASS' ELSE 'FAIL' END AS status;
SELECT 'public_direct_writes' AS check_name,r.rolname,t.oid::regclass AS relation,
 CASE WHEN has_table_privilege(r.oid,t.oid,'INSERT,UPDATE,DELETE,TRUNCATE')
 OR has_any_column_privilege(r.oid,t.oid,'INSERT,UPDATE') THEN 'FAIL' ELSE 'PASS' END AS status
FROM pg_roles r CROSS JOIN pg_class t JOIN pg_namespace n ON n.oid=t.relnamespace
WHERE r.rolname IN ('anon','authenticated') AND n.nspname='public'
AND t.relname IN ('pickup_tasks','pickup_routes','pickup_route_stops','active_task_route_assignments');
-- Missing/extra relations, all function ACLs, role memberships, C1 seal,
-- protected-object delta and historical snapshots require the full reviewed pre/post comparison.
