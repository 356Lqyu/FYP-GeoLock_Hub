-- SELECT ONLY. Manually select DEV rcgyuwiidqvrgbxswhqj in SQL Editor first.
-- Never run against shared mffccmlimmbrgasgfnnq. Session names do not prove project.
-- Export each result. Do not call application functions, even inside SELECT.
-- Run parent review/003_compatibility_readonly.sql Q01-Q07 FIRST.
-- Stop if required relations/columns are absent. No automatic repairs.

-- S01: Exact additional installation guards (both matches must be true).
WITH expected(signature,body_md5,settings) AS (VALUES
 ('public.submit_claim_reconciliation(uuid,boolean,uuid)',
  '9e0cdc7d246309222f7ac88d54cb4b96',ARRAY['search_path=pg_catalog, public, pg_temp']),
 ('public.recover_expired_claims(integer)',
  '5ff6d8719db9681aae6f444b89dfbaee',ARRAY['search_path=pg_catalog, public, extensions, pg_temp']))
SELECT e.signature,p.oid IS NOT NULL AS present,
 coalesce(pg_get_userbyid(p.proowner)='postgres' AND p.prosecdef
  AND p.proconfig=e.settings AND md5(replace(p.prosrc,E'\r\n',E'\n'))=e.body_md5,false) AS installation_guard_matches,
 pg_get_function_result(p.oid) AS result,p.proconfig
FROM expected e LEFT JOIN pg_proc p ON p.oid=to_regprocedure(e.signature);
-- Reconciliation result must also be jsonb. Parent Q02 exact start/complete SHA pins must match.

-- S02: First-install collisions: expect zero rows (inspect any row; do not drop it).
SELECT n.nspname,p.oid::regprocedure AS unexpected_existing_signature
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE (n.nspname='routing_private' AND p.proname IN
 ('lock_route','close_collected','task_guard','check_remaining',
 'legacy_start_pickup','legacy_complete_pickup','reconciliation_participant',
 'lock_reconciliation_scope','permit_reconciled_collection','finish_reconciled_collection'))
 OR (n.nspname='public' AND p.proname IN
 ('close_my_collected_route','cancel_my_unstarted_route','get_my_routing_overview','get_my_authorized_route'));
SELECT tgname,tgenabled,pg_get_triggerdef(oid) FROM pg_trigger
WHERE tgrelid='public.pickup_tasks'::regclass AND tgname='routing_task_authority';
-- Expect zero triggers before first installation; expect enabled O after installation.
SELECT count(*) AS preexisting_legacy_capture_rows FROM routing_private.legacy_inflight;
-- Normally zero before first installation. Nonzero requires provenance review.

-- S03: Reconciliation/source columns, all constraints, enum states and table security.
SELECT table_schema,table_name,column_name,data_type,is_nullable,column_default
FROM information_schema.columns WHERE table_schema='public' AND table_name IN
 ('claim_reconciliation_cases','claim_reconciliation_evidence','hub_batch_members','listings')
ORDER BY table_name,ordinal_position;
SELECT c.oid::regclass AS relation,k.conname,pg_get_constraintdef(k.oid)
FROM pg_constraint k JOIN pg_class c ON c.oid=k.conrelid JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname='public' AND c.relname IN
 ('claim_reconciliation_cases','claim_reconciliation_evidence','hub_batch_members','listings')
ORDER BY c.oid::regclass::text,k.conname;
SELECT n.nspname,t.typname,e.enumlabel,e.enumsortorder FROM pg_enum e
JOIN pg_type t ON t.oid=e.enumtypid JOIN pg_namespace n ON n.oid=t.typnamespace
WHERE n.nspname='public' ORDER BY t.typname,e.enumsortorder;
SELECT c.oid::regclass AS relation,c.relrowsecurity,c.relforcerowsecurity,c.relacl,
 pg_get_userbyid(c.relowner) AS owner FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE (n.nspname='routing_private' AND c.relkind IN ('r','p')) OR
 (n.nspname='public' AND c.relname IN ('claim_reconciliation_cases','claim_reconciliation_evidence'));
SELECT schemaname,tablename,policyname,roles,cmd,qual,with_check FROM pg_policies
WHERE schemaname='routing_private' OR (schemaname='public' AND tablename IN
 ('claim_reconciliation_cases','claim_reconciliation_evidence'));
-- Check effective grants AND column grants AND RLS: table-only inspection is insufficient.
SELECT r.rolname,c.oid::regclass AS relation,
 has_table_privilege(r.oid,c.oid,'INSERT,UPDATE,DELETE,TRUNCATE,TRIGGER') AS any_sensitive_table_grant,
 has_any_column_privilege(r.oid,c.oid,'INSERT,UPDATE') AS any_column_write_grant
FROM pg_roles r CROSS JOIN pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE r.rolname IN ('anon','authenticated','service_role','geolock_graph_worker','geolock_planner','geolock_validator')
AND ((n.nspname='routing_private' AND c.relkind IN ('r','p')) OR
 (n.nspname='public' AND c.relname IN ('claim_reconciliation_cases','claim_reconciliation_evidence')))
ORDER BY r.rolname,c.oid::regclass::text;

-- S04: Cutover inventory: IDs only, no participant personal data. Review EVERY row.
-- LEFT joins retain broken/orphan states that the parent inner-join inventory hides.
SELECT t.task_id,t.claim_id,t.task_status,c.claim_status,le.lease_status,le.expires_at,
 l.source_type,l.listing_status,
 CASE WHEN t.task_status='DISPATCHED' THEN 'CAPTURED_FOR_LEGACY_COMPLETION; CHECK_CUSTODY_AND_LEASE'
 WHEN t.task_status IN ('CONFIRMED','PLANNED') AND NOT EXISTS
 (SELECT 1 FROM routing_private.items i WHERE i.task_id=t.task_id AND i.released_at IS NULL)
 THEN 'START_BLOCKED_UNTIL_DATABASE_ROUTE_AUTHORIZATION'
 ELSE 'REVIEW_EXISTING_BINDING_OR_RECONCILIATION' END AS cutover_effect,
 (SELECT count(*) FROM routing_private.items i WHERE i.task_id=t.task_id AND i.released_at IS NULL) AS open_items,
 (SELECT count(*) FROM public.active_task_route_assignments a WHERE a.task_id=t.task_id) AS assignments,
 (SELECT count(*) FROM public.pickup_route_stops s WHERE s.task_id=t.task_id) AS stops
FROM public.pickup_tasks t LEFT JOIN public.donation_claims c ON c.claim_id=t.claim_id
LEFT JOIN public.claim_leases le ON le.claim_id=t.claim_id LEFT JOIN public.listings l ON l.listing_id=t.listing_id
WHERE t.task_status IN ('CONFIRMED','PLANNED','DISPATCHED','STALE')
ORDER BY t.task_status,t.task_id;
SELECT c.claim_id,c.claim_status,le.lease_status,t.task_status,rc.case_status
FROM public.donation_claims c LEFT JOIN public.claim_leases le ON le.claim_id=c.claim_id
LEFT JOIN public.pickup_tasks t ON t.claim_id=c.claim_id
LEFT JOIN public.claim_reconciliation_cases rc ON rc.claim_id=c.claim_id
WHERE c.claim_status IN ('ACTIVE','RECONCILIATION_REQUIRED') OR rc.case_status IN ('OPEN','MANUAL_REVIEW');

-- S05: All route holds, including abandoned/terminal routes and legacy assignments.
SELECT r.route_id,r.route_status,r.vehicle_id,b.started_at,b.closed_at,
 (b.route_id IS NOT NULL) AS managed,
 (SELECT count(*) FROM public.active_task_route_assignments a WHERE a.route_id=r.route_id) AS assignments,
 (SELECT count(*) FROM public.pickup_route_stops s WHERE s.route_id=r.route_id) AS stops,
 (SELECT count(*) FROM routing_private.items i WHERE i.route_id=r.route_id AND i.released_at IS NULL) AS held_items
FROM public.pickup_routes r LEFT JOIN routing_private.bindings b ON b.route_id=r.route_id ORDER BY r.route_id;
SELECT i.route_id,i.task_id,t.task_status,i.consumed_at,i.collected_at,i.released_at,b.closed_at
FROM routing_private.items i LEFT JOIN public.pickup_tasks t ON t.task_id=i.task_id
LEFT JOIN routing_private.bindings b ON b.route_id=i.route_id
WHERE t.task_id IS NULL OR b.route_id IS NULL
 OR (i.released_at IS NULL AND b.closed_at IS NOT NULL)
 OR (i.released_at IS NULL AND ((t.task_status='COLLECTED')<>(i.collected_at IS NOT NULL)));
-- Expected zero anomalies. Existing public routes without bindings do not gain managed closure.

-- S06: Dependencies and alternate SECURITY DEFINER entry points: manual source review.
SELECT p.oid::regprocedure AS signature,pg_get_userbyid(p.proowner) AS owner,p.prosecdef,p.proconfig,p.proacl,
 pg_get_functiondef(p.oid) AS definition
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname IN ('public','routing_private','fleet_private') AND p.prokind='f'
AND p.prosrc ~* '(pickup_tasks|claim_reconciliation_evidence|claim_reconciliation_cases|legacy_inflight|routing_private[.]items)'
ORDER BY p.oid::regprocedure::text;
-- Text scan is not exhaustive: dynamic SQL/external callers and PL/pgSQL dependency gaps require review.
SELECT d.classid::regclass,d.objid,d.deptype,pg_describe_object(d.classid,d.objid,d.objsubid) AS dependent
FROM pg_depend d WHERE d.refclassid='pg_proc'::regclass AND d.refobjid IN
 (to_regprocedure('public.start_pickup(uuid)'),to_regprocedure('public.complete_pickup(uuid,boolean)'),
 to_regprocedure('public.submit_claim_reconciliation(uuid,boolean,uuid)'));

-- S07: Role escalation and effective function grants (no credentials are selected).
SELECT rolname,rolsuper,rolinherit,rolcreaterole,rolcreatedb,rolcanlogin,rolbypassrls
FROM pg_roles WHERE rolname IN ('anon','authenticated','service_role','geolock_graph_worker','geolock_planner','geolock_validator');
SELECT member.rolname AS member,parent.rolname AS granted_role,m.admin_option
FROM pg_auth_members m JOIN pg_roles member ON member.oid=m.member JOIN pg_roles parent ON parent.oid=m.roleid
WHERE member.rolname IN ('anon','authenticated','service_role','geolock_graph_worker','geolock_planner','geolock_validator')
 OR parent.rolname IN ('geolock_graph_worker','geolock_planner','geolock_validator');
SELECT p.oid::regprocedure AS signature,r.rolname,has_function_privilege(r.oid,p.oid,'EXECUTE') AS can_execute
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace CROSS JOIN pg_roles r
WHERE r.rolname IN ('anon','authenticated','service_role','geolock_graph_worker','geolock_planner','geolock_validator')
AND n.nspname='public' AND p.proname IN ('claim_listing','cancel_claim','submit_claim_reconciliation',
 'recover_expired_claims','start_pickup','complete_pickup','begin_my_routing_snapshot','authorize_my_routing_candidate')
ORDER BY p.oid::regprocedure::text,r.rolname;
SELECT r.rolname,n.nspname,has_schema_privilege(r.oid,n.oid,'USAGE') AS can_use,
 has_schema_privilege(r.oid,n.oid,'CREATE') AS can_create
FROM pg_roles r CROSS JOIN pg_namespace n
WHERE r.rolname IN ('anon','authenticated','service_role','geolock_graph_worker','geolock_planner','geolock_validator')
AND n.nspname IN ('public','routing_private','fleet_private');

-- S08: Operational dependencies, separate from installation guards. No application RPCs called.
SELECT graph_id,coverage_snapshot,content_digest,speed_profile,node_count,edge_count,precision_policy,float_output_profile
FROM routing_private.graphs ORDER BY created_at;
SELECT policy_id,digest,body FROM routing_private.policies ORDER BY created_at;
SELECT task_status,count(*) FROM public.pickup_tasks GROUP BY task_status;
SELECT donation_status,count(*) FROM public.donations GROUP BY donation_status;
SELECT listing_status,count(*) FROM public.listings GROUP BY listing_status;
SELECT claim_status,count(*) FROM public.donation_claims GROUP BY claim_status;
SELECT lease_status,count(*) FROM public.claim_leases GROUP BY lease_status;
-- Graph existence does not prove approval/provenance or configured worker UUID/enablement.
-- Parent Q12 only if cron.job exists: record actual recovery schedule, never invoke recovery.

-- S09: Export all 001/002 worker APIs and private prerequisites for source comparison.
SELECT n.nspname,p.oid::regprocedure AS signature,pg_get_userbyid(p.proowner) AS owner,
 p.prosecdef,p.proconfig,p.proacl,md5(replace(p.prosrc,E'\r\n',E'\n')) AS body_md5,
 pg_get_functiondef(p.oid) AS definition
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE p.prokind='f' AND (n.nspname IN ('routing_private','fleet_private') OR
 (n.nspname='public' AND p.proname IN ('install_routing_policy','freeze_routing_graph',
 'store_routing_matrix','begin_my_routing_snapshot','seal_routing_snapshot',
 'submit_routing_candidate','read_routing_work_item','attest_routing_candidate',
 'read_frozen_routing_graph','read_routing_snapshot_bundle','read_pending_routing_snapshot',
 'authorize_my_routing_candidate','assign_task_to_route')))
ORDER BY n.nspname,p.oid::regprocedure::text;
