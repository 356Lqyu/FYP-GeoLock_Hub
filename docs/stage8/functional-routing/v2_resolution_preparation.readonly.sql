-- PREPARATION ONLY: separately approved native owner-export connection required.
-- No business RPCs. Synthetic DEV records are not physical custody evidence.
\set ON_ERROR_STOP on
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout='15s';
SET LOCAL lock_timeout='2s';
SET LOCAL idle_in_transaction_session_timeout='60s';
SELECT jsonb_build_object('section','identity','observed_at',statement_timestamp(),
 'database',current_database(),'session_user',session_user,'current_user',current_user,
 'read_only',current_setting('transaction_read_only'),
 'ssl',(SELECT ssl FROM pg_catalog.pg_stat_ssl WHERE pid=pg_backend_pid()));
SELECT current_database()='postgres' AND session_user='postgres' AND current_user='postgres'
 AND current_setting('transaction_read_only')='on'
 AND coalesce((SELECT ssl FROM pg_catalog.pg_stat_ssl WHERE pid=pg_backend_pid()),false)
 AS approved_identity \gset
\if :approved_identity
\else
\echo IDENTITY_OR_READONLY_OR_TLS_GUARD_FAILED
ROLLBACK;
\quit 3
\endif

SELECT jsonb_build_object('section','v2_binding','binding',to_jsonb(b),
 'route_status',r.route_status,'vehicle_label',v.vehicle_label,
 'vehicle_version_current',v.vehicle_version,'vehicle_active',v.active_flag)
FROM routing_private.bindings b JOIN public.pickup_routes r USING(route_id)
JOIN public.vehicles v ON v.vehicle_id=b.vehicle_id
WHERE b.route_id='db1b455e-92d0-4d58-9fa1-5de07d7ab0f9';

SELECT jsonb_build_object('section','v2_item','ordinal',i.ordinal,'task_id',t.task_id,
 'claim_id',c.claim_id,'ngo_id',c.ngo_user_id,'claim_status',c.claim_status,
 'lease_id',le.lease_id,'lease_status',le.lease_status,'lease_expires_at',le.expires_at,
 'task_status',t.task_status,'listing_id',l.listing_id,'listing_status',l.listing_status,
 'listing_expires_at',l.listing_expires_at,'source_type',l.source_type,
 'donation_id',d.donation_id,'title',d.title,'donation_status',d.donation_status,
 'availability_start',d.availability_start,'availability_end',d.availability_end,
 'source_actor',d.donor_user_id,'source_actor_role',u.role,
 'consumed_at',i.consumed_at,'collected_at',i.collected_at,'released_at',i.released_at,
 'assignment',(SELECT to_jsonb(a) FROM public.active_task_route_assignments a WHERE a.task_id=t.task_id),
 'listing_currently_unexpired',l.listing_expires_at IS NULL OR l.listing_expires_at>statement_timestamp(),
 'donation_window_not_ended',d.availability_end IS NULL OR d.availability_end>statement_timestamp())
FROM routing_private.items i JOIN public.pickup_tasks t USING(task_id)
JOIN public.donation_claims c USING(claim_id) JOIN public.claim_leases le USING(claim_id)
JOIN public.listings l ON l.listing_id=t.listing_id
LEFT JOIN public.donations d ON d.donation_id=l.donation_id
LEFT JOIN public.user_profiles u ON u.user_id=d.donor_user_id
WHERE i.route_id='db1b455e-92d0-4d58-9fa1-5de07d7ab0f9' ORDER BY i.ordinal;

SELECT jsonb_build_object('section','claim_cases','case',to_jsonb(rc))
FROM public.claim_reconciliation_cases rc
WHERE rc.claim_id IN(SELECT t.claim_id FROM routing_private.items i JOIN public.pickup_tasks t USING(task_id)
 WHERE i.route_id='db1b455e-92d0-4d58-9fa1-5de07d7ab0f9') ORDER BY rc.case_id LIMIT 10;
SELECT jsonb_build_object('section','participant_statement','case_id',e.case_id,
 'request_id',e.request_id,'actor_user_id',e.actor_user_id,'actor_role',u.role,
 'handover_confirmed',e.handover_confirmed,'recorded_at',coalesce(to_jsonb(e)->'created_at',to_jsonb(e)->'submitted_at',to_jsonb(e)->'occurred_at'),
 'response',e.response)
FROM public.claim_reconciliation_evidence e JOIN public.claim_reconciliation_cases rc USING(case_id)
LEFT JOIN public.user_profiles u ON u.user_id=e.actor_user_id
WHERE rc.claim_id IN(SELECT t.claim_id FROM routing_private.items i JOIN public.pickup_tasks t USING(task_id)
 WHERE i.route_id='db1b455e-92d0-4d58-9fa1-5de07d7ab0f9') ORDER BY e.case_id,e.request_id LIMIT 30;

SELECT jsonb_build_object('section','recovery_and_resolution_audit','event',to_jsonb(x)) FROM (
 SELECT a.event_id,a.occurred_at,a.entity_id,a.event_type,a.actor_user_id,a.actor_role,
 a.claim_id,a.lease_id,a.outcome,a.reason_code,a.resulting_state
 FROM public.audit_events a WHERE a.entity_id='db1b455e-92d0-4d58-9fa1-5de07d7ab0f9'
 OR a.claim_id IN(SELECT t.claim_id FROM routing_private.items i JOIN public.pickup_tasks t USING(task_id)
 WHERE i.route_id='db1b455e-92d0-4d58-9fa1-5de07d7ab0f9')
 ORDER BY a.occurred_at DESC,a.event_id LIMIT 100) x;

SELECT jsonb_build_object('section','deployed_function','signature',p.oid::regprocedure::text,
 'owner',p.proowner::regrole::text,'security_definer',p.prosecdef,'volatility',p.provolatile,
 'settings',p.proconfig,'acl',p.proacl::text,'body_md5',md5(replace(p.prosrc,E'\r\n',E'\n')),
 'definition',pg_get_functiondef(p.oid),
 'authenticated_execute',has_function_privilege('authenticated',p.oid,'EXECUTE'),
 'service_role_execute',has_function_privilege('service_role',p.oid,'EXECUTE'))
FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace
WHERE (n.nspname='public' AND p.proname IN('recover_expired_claims','submit_claim_reconciliation',
 'get_my_reconciliation_cases','get_my_authorized_route','close_my_collected_route','cancel_my_unstarted_route',
 'complete_pickup','enforce_donation_transition',
 'report_my_route_interruption','submit_route_resolution_evidence','report_route_resolution_incident',
 'get_my_route_resolution','list_my_route_resolution_cases','get_my_route_resolution_receipt',
 'get_route_resolution_for_operator','finalize_route_resolution','register_route_test_provenance'))
 OR (n.nspname='routing_private' AND p.proname IN('lock_reconciliation_scope','permit_reconciled_collection',
 'finish_reconciled_collection','close_collected','task_guard'))
 OR (n.nspname='fleet_private' AND p.proname='route_vehicle_guard')
 OR n.nspname='resolution_private' ORDER BY n.nspname,p.proname LIMIT 100;

SELECT jsonb_build_object('section','resolver_roles','role',r.rolname,'can_login',r.rolcanlogin,
 'superuser',r.rolsuper,'bypassrls',r.rolbypassrls,'create_role',r.rolcreaterole,
 'create_database',r.rolcreatedb,'inherits',r.rolinherit)
FROM pg_catalog.pg_roles r WHERE r.rolname='geolock_route_resolver'
 OR EXISTS(SELECT 1 FROM pg_catalog.pg_roles resolver WHERE resolver.rolname='geolock_route_resolver'
 AND pg_has_role(r.oid,resolver.oid,'MEMBER')) ORDER BY r.rolname LIMIT 30;
SELECT jsonb_build_object('section','installed_resolution_capability',
 'schema_present',to_regnamespace('resolution_private') IS NOT NULL,
 'config_present',to_regclass('resolution_private.config') IS NOT NULL,
 'report_rpc',to_regprocedure('public.report_my_route_interruption(uuid,text,uuid)') IS NOT NULL,
 'finalizer_rpc',to_regprocedure('public.finalize_route_resolution(uuid,bigint,uuid)') IS NOT NULL);
SELECT to_regclass('resolution_private.config') IS NOT NULL AS config_present \gset
\if :config_present
SELECT jsonb_build_object('section','resolution_gate','config',to_jsonb(c)) FROM resolution_private.config c;
\endif
SELECT to_regclass('resolution_private.operators') IS NOT NULL AS operators_present \gset
\if :operators_present
SELECT jsonb_build_object('section','resolver_operator','operator',to_jsonb(o)) FROM resolution_private.operators o LIMIT 30;
\endif
SELECT to_regclass('resolution_private.cases') IS NOT NULL AS cases_present \gset
\if :cases_present
SELECT jsonb_build_object('section','route_resolution_case','case',to_jsonb(c))
FROM resolution_private.cases c WHERE c.route_id='db1b455e-92d0-4d58-9fa1-5de07d7ab0f9';
\endif
SELECT to_regclass('resolution_private.evidence') IS NOT NULL AND to_regclass('resolution_private.cases') IS NOT NULL AS evidence_present \gset
\if :evidence_present
SELECT jsonb_build_object('section','route_resolution_statement','evidence',to_jsonb(e))
FROM resolution_private.evidence e JOIN resolution_private.cases c USING(case_id)
WHERE c.route_id='db1b455e-92d0-4d58-9fa1-5de07d7ab0f9' ORDER BY e.version LIMIT 50;
\endif
SELECT to_regclass('resolution_private.test_runs') IS NOT NULL AS registry_present \gset
\if :registry_present
SELECT jsonb_build_object('section','existing_synthetic_registry','run',to_jsonb(tr))
FROM resolution_private.test_runs tr
WHERE tr.fixture_claim_ids && ARRAY['73f345b8-c293-454e-8bea-16d91019fc3c','7d5838a7-efd7-406e-9af7-5f71ea91b92c','305d3708-43ca-4776-af9f-ee5afe67e9b8']::uuid[]
LIMIT 10;
\endif

-- Preservation snapshot only. Never call closure or execution functions.
SELECT jsonb_build_object('section','v3_preservation','route_id',r.route_id,'route_status',r.route_status,
 'closed_at',b.closed_at,'candidate_id',b.candidate_id,
 'active_assignment_count',(SELECT count(*) FROM public.active_task_route_assignments a WHERE a.route_id=r.route_id))
FROM public.pickup_routes r JOIN routing_private.bindings b USING(route_id)
WHERE r.route_id='7dd2d00a-ff03-4021-994f-155bbfc8e12c';
ROLLBACK;
