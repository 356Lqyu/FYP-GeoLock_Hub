-- Manual SELECT-only checks; DEV rcgyuwiidqvrgbxswhqj only.
-- Before any deployment, export these results plus review/003_compatibility_readonly.sql.
-- Current database/session names alone do not prove project identity.
SELECT current_database(),session_user,current_user,current_setting('transaction_isolation');

SELECT p.oid::regprocedure AS signature,pg_get_userbyid(p.proowner) AS owner,
 p.prosecdef,p.proconfig,p.proacl,
 md5(replace(p.prosrc,E'\r\n',E'\n')) AS normalized_body_md5,
 pg_get_functiondef(p.oid) AS definition
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE (n.nspname='public' AND p.proname IN
 ('submit_claim_reconciliation','recover_expired_claims','start_pickup','complete_pickup'))
OR (n.nspname='routing_private' AND p.proname IN
 ('task_guard','reconciliation_participant','lock_reconciliation_scope',
 'permit_reconciled_collection','finish_reconciled_collection'))
ORDER BY n.nspname,p.proname;

-- Existing guard must remain enabled with body MD5 ab3101347fdbd148116c634e6c6132ad.
-- Recovery must remain unchanged: baseline MD5 5ff6d8719db9681aae6f444b89dfbaee.
-- Original reconciliation baseline: 9e0cdc7d246309222f7ac88d54cb4b96.
-- Revised reconciliation: ae348bb136954224e40a9361872a8eab.
SELECT tgname,tgenabled,pg_get_triggerdef(oid) FROM pg_trigger
WHERE tgrelid='public.pickup_tasks'::regclass AND NOT tgisinternal;

SELECT p.oid::regprocedure AS signature,r.rolname,
 has_function_privilege(r.oid,p.oid,'EXECUTE') AS can_execute
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace CROSS JOIN pg_roles r
WHERE n.nspname='routing_private' AND p.proname IN
 ('reconciliation_participant','lock_reconciliation_scope','permit_reconciled_collection','finish_reconciled_collection')
AND r.rolname IN ('anon','authenticated','service_role','geolock_graph_worker','geolock_planner','geolock_validator');
-- Every can_execute value above must be false for the private helpers.

SELECT r.rolname,n.name,
 has_table_privilege(r.oid,n.name,'INSERT,UPDATE,DELETE') AS any_direct_write_grant
FROM pg_roles r CROSS JOIN (VALUES('routing_private.items'),('routing_private.legacy_inflight'),
 ('public.claim_reconciliation_evidence'),('public.claim_reconciliation_cases')) n(name)
WHERE r.rolname IN ('anon','authenticated','service_role') ORDER BY r.rolname,n.name;
SELECT schemaname,tablename,policyname,roles,cmd,qual,with_check FROM pg_policies
WHERE tablename IN ('claim_reconciliation_evidence','claim_reconciliation_cases','items','legacy_inflight');
-- Public evidence-table grants must be assessed WITH actual enabled RLS/policies;
-- a table grant alone does not prove direct client evidence forgery is possible.
SELECT c.oid::regclass,c.relrowsecurity,c.relforcerowsecurity,c.relacl
FROM pg_class c WHERE c.oid IN ('public.claim_reconciliation_evidence'::regclass,
 'public.claim_reconciliation_cases'::regclass,'routing_private.items'::regclass,
 'routing_private.legacy_inflight'::regclass);

SELECT 'tasks' AS relation,count(*) FROM public.pickup_tasks
UNION ALL SELECT 'items',count(*) FROM routing_private.items
UNION ALL SELECT 'bindings',count(*) FROM routing_private.bindings
UNION ALL SELECT 'assignments',count(*) FROM public.active_task_route_assignments
UNION ALL SELECT 'cases',count(*) FROM public.claim_reconciliation_cases
UNION ALL SELECT 'evidence',count(*) FROM public.claim_reconciliation_evidence;
-- Installation alone must not change these counts or lifecycle/route records.
SELECT count(*) AS collected_task_without_item_bookkeeping
FROM routing_private.items i JOIN public.pickup_tasks t USING(task_id)
WHERE i.released_at IS NULL AND t.task_status='COLLECTED' AND i.collected_at IS NULL;
SELECT count(*) AS unresolved_task_with_collected_marker
FROM routing_private.items i JOIN public.pickup_tasks t USING(task_id)
WHERE i.released_at IS NULL AND i.collected_at IS NOT NULL AND t.task_status<>'COLLECTED';
-- Record any pre-existing discrepancy; this proposal performs no data repair.
