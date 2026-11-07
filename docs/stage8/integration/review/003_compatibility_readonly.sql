-- SELECT-only manual review. No migration, custom RPC or worker is invoked.
-- FIRST select DEV rcgyuwiidqvrgbxswhqj in the Supabase dashboard.
-- The database name/session user below do NOT prove project identity.
-- Run sections separately and export results. Do not deploy 003 from these results alone.

-- Q01: Session context (not project-identity proof).
SELECT current_database(), session_user, current_user,
       current_setting('server_version') AS server_version,
       current_setting('transaction_isolation') AS isolation;

-- Q02: Exact 003 pg_get_functiondef pins and latest repository prosrc MD5s.
-- Body MD5 comparison normalizes CRLF only; it is NOT a replacement for 003's
-- exact full-definition SHA-256, signatures, owner, security and ACL review.
WITH expected(signature, expected_003_sha256, latest_repository_body_md5) AS (
 VALUES
 ('public.start_pickup(uuid)',
  'a87e59bd4c790bc593f76da42bff47e8864c2f27affffc623d6f7161a63a84a7',
  'd374a029251fd2ba3786d6c5f6a03ca6'),
 ('public.complete_pickup(uuid,boolean)',
  'de1f32f68ced1b9ffae70983cd7988c8e140509ef7aa9bf8c69a23dca512f4a0',
  '13b97b3cf16e6b8750b8289a22acfcb3'),
 ('public.claim_listing(uuid,uuid)',NULL,'a883341a6dd72ccb08991a7f89dffa9a'),
 ('public.cancel_claim(uuid,uuid)',NULL,'5c94a13f00460fdfb8228864d3eaf75e'),
 ('public.submit_claim_reconciliation(uuid,boolean,uuid)',NULL,'9e0cdc7d246309222f7ac88d54cb4b96'),
 ('public.recover_expired_claims(integer)',NULL,'5ff6d8719db9681aae6f444b89dfbaee'),
 ('public.geolock_lock_listing_donations(uuid,text[])',NULL,'90816e7c6db3606dc8b6451a899d8036'),
 ('public.geolock_transition_listing_donations(uuid,text,text)',NULL,'c7f2124b18d75e5af2d7785daeeaa890'),
 ('public.enforce_donation_transition()',NULL,'c0cbbe68574ea42fafe9d2f60d08cff1')
)
SELECT e.signature, p.oid IS NOT NULL AS present,
       pg_get_function_arguments(p.oid) AS arguments,
       pg_get_function_result(p.oid) AS result,
       pg_get_userbyid(p.proowner) AS owner, p.prosecdef AS security_definer,
       p.proconfig AS settings, p.proacl::text AS explicit_acl,
       encode(sha256(convert_to(pg_get_functiondef(p.oid),'UTF8')),'hex') AS actual_full_sha256,
       e.expected_003_sha256,
       CASE WHEN e.expected_003_sha256 IS NOT NULL THEN
         encode(sha256(convert_to(pg_get_functiondef(p.oid),'UTF8')),'hex')=e.expected_003_sha256
       END AS exact_003_pin_matches,
       md5(replace(p.prosrc,E'\r\n',E'\n')) AS actual_body_md5_lf,
       e.latest_repository_body_md5,
       md5(replace(p.prosrc,E'\r\n',E'\n'))=e.latest_repository_body_md5 AS latest_repo_body_matches
FROM expected e LEFT JOIN pg_proc p ON p.oid=to_regprocedure(e.signature)
ORDER BY e.signature;

-- Q03: Actual overloads, owners, definitions and ACLs, including existing 003
-- objects. Before first installation, 003-only functions should be absent.
SELECT n.nspname AS schema_name, p.oid::regprocedure AS signature,
       pg_get_userbyid(p.proowner) AS owner, p.prosecdef, p.proconfig,
       p.proacl::text AS explicit_acl, pg_get_functiondef(p.oid) AS definition
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE (n.nspname='public' AND p.proname IN
 ('claim_listing','start_pickup','complete_pickup','cancel_claim',
  'submit_claim_reconciliation','recover_expired_claims',
  'geolock_lock_listing_donations','geolock_transition_listing_donations',
  'enforce_donation_transition','authorize_my_routing_candidate',
  'close_my_collected_route','cancel_my_unstarted_route',
  'get_my_routing_overview','get_my_authorized_route'))
 OR (n.nspname='routing_private' AND p.proname IN
 ('actor_lock','lock_sources','task_window','admissible','lock_route',
  'close_collected','task_guard','check_remaining','legacy_start_pickup','legacy_complete_pickup'))
ORDER BY n.nspname,p.proname,p.oid;

-- Q04: Relation prerequisites. Stop dependent sections if a relation is absent.
WITH names(name) AS (VALUES
 ('public.vehicles'),('public.pickup_tasks'),('public.pickup_routes'),
 ('public.pickup_route_stops'),('public.active_task_route_assignments'),
 ('public.donations'),('public.donation_claims'),('public.claim_leases'),
 ('public.claim_reconciliation_cases'),('public.claim_reconciliation_evidence'),
 ('routing_private.policies'),('routing_private.graphs'),('routing_private.matrices'),
 ('routing_private.snapshots'),('routing_private.candidates'),('routing_private.validations'),
 ('routing_private.requests'),('routing_private.bindings'),('routing_private.items'),
 ('routing_private.cancelled_stop_history'),('routing_private.legacy_inflight'),('cron.job'))
SELECT name,to_regclass(name) AS relation FROM names ORDER BY name;

-- Q05: All user triggers on lifecycle, route, fleet and graph tables.
SELECT t.tgrelid::regclass AS relation,t.tgname,t.tgenabled,
       t.tgfoid::regprocedure AS function_signature,
       pg_get_triggerdef(t.oid) AS definition
FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid
JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE NOT t.tgisinternal AND
 ((n.nspname='public' AND c.relname IN
 ('donations','donation_claims','claim_leases','pickup_tasks','pickup_routes',
  'pickup_route_stops','active_task_route_assignments','vehicles',
  'road_network_nodes','road_network_edges','road_network_coverage'))
 OR n.nspname IN ('routing_private','fleet_private'))
ORDER BY n.nspname,c.relname,t.tgname;

-- Q06: Current columns/defaults and CHECK/FK/unique constraints.
SELECT table_schema,table_name,column_name,data_type,is_nullable,column_default
FROM information_schema.columns
WHERE (table_schema='routing_private') OR (table_schema='public' AND table_name IN
 ('pickup_tasks','pickup_routes','pickup_route_stops','active_task_route_assignments','vehicles'))
ORDER BY table_schema,table_name,ordinal_position;

SELECT n.nspname,c.relname,k.conname,pg_get_constraintdef(k.oid) AS definition
FROM pg_constraint k JOIN pg_class c ON c.oid=k.conrelid
JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname='routing_private' OR (n.nspname='public' AND c.relname IN
 ('donations','donation_claims','claim_leases','pickup_tasks','pickup_routes',
  'pickup_route_stops','active_task_route_assignments','vehicles'))
ORDER BY n.nspname,c.relname,k.conname;

-- Q07: Effective EXECUTE permissions, including inherited/PUBLIC grants.
SELECT n.nspname,p.oid::regprocedure AS signature,r.rolname,
       has_function_privilege(r.oid,p.oid,'EXECUTE') AS can_execute
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
CROSS JOIN pg_roles r
WHERE r.rolname IN ('anon','authenticated','service_role',
 'geolock_graph_worker','geolock_planner','geolock_validator')
AND ((n.nspname='routing_private') OR (n.nspname='public' AND p.proname IN
 ('start_pickup','complete_pickup','submit_claim_reconciliation','recover_expired_claims',
  'authorize_my_routing_candidate','close_my_collected_route','cancel_my_unstarted_route',
  'get_my_routing_overview','get_my_authorized_route')))
ORDER BY n.nspname,p.oid::regprocedure::text,r.rolname;

-- Q08-Q12 require the relations in Q04 to exist. Counts are actual, not estimates.
SELECT 'vehicles' AS relation,count(*) AS rows FROM public.vehicles
UNION ALL SELECT 'routes',count(*) FROM public.pickup_routes
UNION ALL SELECT 'stops',count(*) FROM public.pickup_route_stops
UNION ALL SELECT 'assignments',count(*) FROM public.active_task_route_assignments
UNION ALL SELECT 'graphs',count(*) FROM routing_private.graphs
UNION ALL SELECT 'policies',count(*) FROM routing_private.policies
UNION ALL SELECT 'snapshots',count(*) FROM routing_private.snapshots
UNION ALL SELECT 'candidates',count(*) FROM routing_private.candidates
UNION ALL SELECT 'validations',count(*) FROM routing_private.validations
UNION ALL SELECT 'bindings',count(*) FROM routing_private.bindings
UNION ALL SELECT 'items',count(*) FROM routing_private.items
UNION ALL SELECT 'legacy_inflight',count(*) FROM routing_private.legacy_inflight;

SELECT graph_id,coverage_snapshot,content_digest,speed_profile,node_count,edge_count,
       precision_policy,float_output_profile,created_at
FROM routing_private.graphs ORDER BY created_at;
SELECT policy_id,digest,body,created_at FROM routing_private.policies ORDER BY created_at;

-- Q10: Current status distribution and cases potentially affected by cutover.
SELECT task_status,count(*) FROM public.pickup_tasks GROUP BY task_status;
SELECT route_status,count(*) FROM public.pickup_routes GROUP BY route_status;
SELECT case_status,count(*) FROM public.claim_reconciliation_cases GROUP BY case_status;
WITH states AS (
 SELECT t.task_status,c.claim_status,le.lease_status,
       EXISTS(SELECT 1 FROM public.active_task_route_assignments a WHERE a.task_id=t.task_id) AS has_assignment,
       EXISTS(SELECT 1 FROM public.pickup_route_stops s WHERE s.task_id=t.task_id) AS has_stop
 FROM public.pickup_tasks t JOIN public.donation_claims c USING(claim_id)
 JOIN public.claim_leases le USING(claim_id)
)
SELECT task_status,claim_status,lease_status,has_assignment,has_stop,count(*)
FROM states GROUP BY task_status,claim_status,lease_status,has_assignment,has_stop;

-- Q11: Scoped installation/hold indexes and table security.
SELECT schemaname,tablename,indexname,indexdef FROM pg_indexes
WHERE schemaname='routing_private' OR (schemaname='public' AND tablename IN
 ('pickup_tasks','pickup_routes','pickup_route_stops','active_task_route_assignments','vehicles'))
ORDER BY schemaname,tablename,indexname;
SELECT n.nspname,c.relname,c.relrowsecurity,c.relforcerowsecurity,c.relacl
FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE c.relkind IN ('r','p') AND (n.nspname='routing_private' OR
 (n.nspname='public' AND c.relname IN ('vehicles','pickup_tasks','pickup_routes',
  'pickup_route_stops','active_task_route_assignments')))
ORDER BY n.nspname,c.relname;

-- Q12: Optional, ONLY if cron.job exists. Do not call the recovery RPC.
SELECT jobid,jobname,schedule,active,username,database
FROM cron.job WHERE command ~* '\mrecover_expired_claims\M' ORDER BY jobid;
