-- Stage 3F postdeploy. Run ONLY after separately approved deployment; expect new body 5ff6... .
SELECT EXISTS(SELECT 1 FROM pg_proc p
 WHERE p.oid='public.recover_expired_claims(integer)'::regprocedure
   AND md5(replace(p.prosrc,E'\r\n',E'\n'))='5ff6d8719db9681aae6f444b89dfbaee'
   AND p.proowner='postgres'::regrole AND p.prosecdef
   AND p.proconfig=ARRAY['search_path=pg_catalog, public, extensions, pg_temp']
   AND p.proacl='{postgres=X/postgres,service_role=X/postgres}'::aclitem[]
   AND pg_get_function_arguments(p.oid)='p_limit integer DEFAULT 100'
   AND pg_get_function_result(p.oid)='integer') AS expected_new_source_and_security;

-- SELECT-ONLY. DEV rcgyuwiidqvrgbxswhqj only; no recovery call or cron writes.
SELECT statement_timestamp() AS observed_at,current_database(),current_user,session_user,
       current_setting('transaction_read_only') AS read_only,auth.uid() AS jwt_subject;

SELECT pg_get_functiondef(p.oid) AS deployed_definition,
       md5(replace(p.prosrc,E'\r\n',E'\n')) AS normalized_source_md5,
       pg_get_function_arguments(p.oid) AS arguments,pg_get_function_result(p.oid) AS result,
       pg_get_userbyid(p.proowner) AS owner,p.prosecdef,p.proconfig,p.proacl,
       has_function_privilege('anon',p.oid,'EXECUTE') AS anon_execute,
       has_function_privilege('authenticated',p.oid,'EXECUTE') AS authenticated_execute,
       has_function_privilege('service_role',p.oid,'EXECUTE') AS service_execute
FROM pg_proc p WHERE p.oid='public.recover_expired_claims(integer)'::regprocedure;

SELECT jobid,jobname,schedule,command,username,database,active FROM cron.job ORDER BY jobid;
SELECT count(*) AS recovery_runs FROM cron.job_run_details WHERE jobid=3;
SELECT DISTINCT ON(jobid) jobid,status,start_time,end_time,return_message
FROM cron.job_run_details WHERE jobid IN(1,2,3) ORDER BY jobid,runid DESC;
SELECT * FROM cron.job_run_details WHERE jobid IN(1,2,3) AND end_time IS NULL;

SELECT c.claim_id,c.claim_status,le.lease_status,le.expires_at,
       l.listing_id,l.source_type,l.listing_status,l.listing_expires_at,
       t.task_id,t.task_status,rc.case_id,rc.case_status
FROM public.donation_claims c JOIN public.claim_leases le USING(claim_id)
JOIN public.listings l ON l.listing_id=c.listing_id
LEFT JOIN public.pickup_tasks t USING(claim_id)
LEFT JOIN public.claim_reconciliation_cases rc USING(claim_id)
WHERE (c.claim_status='ACTIVE' AND le.lease_status='ACTIVE' AND le.expires_at<=statement_timestamp())
   OR rc.case_status IN('OPEN','MANUAL_REVIEW')
ORDER BY le.expires_at,c.claim_id;
-- The fix fences unresolved evidence for either the same claim OR same listing.
-- Cross-record historical cases are surfaced for manual review; never auto-close.
SELECT rc.case_id,rc.case_status,rc.claim_id AS case_claim,rc.listing_id,
       c.claim_status AS case_claim_status,other.claim_id AS other_unresolved_claim
FROM public.claim_reconciliation_cases rc
JOIN public.donation_claims c ON c.claim_id=rc.claim_id
LEFT JOIN public.donation_claims other ON other.listing_id=rc.listing_id
  AND other.claim_id<>rc.claim_id AND other.claim_status IN('ACTIVE','RECONCILIATION_REQUIRED')
WHERE rc.case_status IN('OPEN','MANUAL_REVIEW');

SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.claim_id),'[]') AS preserved_claim_snapshot
FROM (
 SELECT c.claim_id,to_jsonb(c) AS claim,to_jsonb(le) AS lease,to_jsonb(t) AS task,
        to_jsonb(l) AS listing,to_jsonb(d) AS donation,
        (SELECT jsonb_agg(to_jsonb(a) ORDER BY a.occurred_at,a.event_id)
         FROM public.audit_events a WHERE a.claim_id=c.claim_id) AS audits,
        (SELECT jsonb_agg(to_jsonb(j) ORDER BY j.eligibility_generation)
         FROM public.listing_eligibility_refresh_jobs j WHERE j.listing_id=l.listing_id) AS refresh
 FROM public.donation_claims c JOIN public.claim_leases le USING(claim_id)
 JOIN public.pickup_tasks t USING(claim_id) JOIN public.listings l ON l.listing_id=c.listing_id
 JOIN public.donations d ON d.donation_id=l.donation_id
 WHERE c.claim_id IN('323ca3b3-7d7f-438e-8ed7-415f61b3a567',
   'aa3cd6d2-e5b3-4369-a41f-ec9a0eaae716','9a2ab42b-52c6-4c3a-99fb-b5c95d41e63f')
) x;

SELECT count(*) AS unrelated_function_count,
md5(string_agg(n.nspname||'.'||p.proname||'('||pg_get_function_identity_arguments(p.oid)||')'||
replace(pg_get_functiondef(p.oid),E'\r\n',E'\n')||pg_get_userbyid(p.proowner)||coalesce(p.proacl::text,'<NULL>'),
E'\n' ORDER BY p.proname,pg_get_function_identity_arguments(p.oid))) AS unrelated_functions_fingerprint
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public' AND p.oid<>'public.recover_expired_claims(integer)'::regprocedure;
-- Reviewed baseline: 85 unrelated public functions, fingerprint
-- 6991083a881075cdf0e75d0c266396f0. Compare PRE and POST snapshots.
-- A difference may be concurrent legitimate teammate work; investigate before
-- attributing a change to this migration or overwriting any deployed source.

SELECT pid,usename,application_name,state,xact_start,wait_event_type,wait_event,
       pg_blocking_pids(pid) AS blockers,query
FROM pg_stat_activity WHERE pid<>pg_backend_pid() AND backend_type='client backend'
  AND xact_start IS NOT NULL;
SELECT pid,relation::regclass AS relation,mode,granted FROM pg_locks
WHERE pid<>pg_backend_pid() AND relation IN(
 'public.donation_claims'::regclass,'public.claim_leases'::regclass,'public.listings'::regclass,
 'public.pickup_tasks'::regclass,'public.donations'::regclass,'public.claim_reconciliation_cases'::regclass);

-- For these completed recoveries expect three all_checks_pass=true rows.
-- SELECT-only DEV verification AFTER step 2.
-- Expect exactly three rows, each with all_checks_pass=true. Missing rows fail.
WITH expected(claim_id,lease_id,listing_id,donation_id,task_id,
              expected_status,expected_task,expected_version,expected_generation) AS (
 VALUES
 ('323ca3b3-7d7f-438e-8ed7-415f61b3a567'::uuid,'c845c9d7-edc8-4870-b32a-40e02d22469a'::uuid,
  '2d06b504-d2dd-4121-8840-c8bf893f8a60'::uuid,'5ab67656-bd03-4e19-942f-59a2dd4e6f11'::uuid,
  '8f0feb98-c97c-4047-91ab-251199b2d1b6'::uuid,'RELEASED','STALE',
  3,2),
 ('aa3cd6d2-e5b3-4369-a41f-ec9a0eaae716'::uuid,'364102f4-a020-44a8-8e7d-e2aa1bc3a3b7'::uuid,
  'd7953dd2-7809-4cb4-87f3-52fc3294685b'::uuid,'3c32d1ae-ea3c-452c-8a76-9e05a0ad911a'::uuid,
  'aaa3429b-4ded-4ae2-865c-784abe41466d'::uuid,'RELEASED','STALE',
  3,2),
 ('9a2ab42b-52c6-4c3a-99fb-b5c95d41e63f'::uuid,'f3a5e81d-bb3e-48c4-a317-b6987e88e0be'::uuid,
  '16e5b6a1-475d-4c5a-9460-d4834dd5640f'::uuid,'0c8f21b4-2e87-466c-bc29-dc15c78f4a04'::uuid,
  'a918031f-c786-4b5f-8823-86bc7a880a05'::uuid,'RELEASED','STALE',
  5,3)
), checks AS (
 SELECT e.claim_id,
   c.claim_id IS NOT NULL AND le.lease_id=e.lease_id
     AND l.listing_id=e.listing_id AND d.donation_id=e.donation_id
     AND t.task_id=e.task_id AND t.listing_id=e.listing_id AS identities_match,
   c.claim_status=e.expected_status AND le.lease_status=e.expected_status
     AND t.task_status=e.expected_task AS claim_lease_task_match,
   CASE WHEN e.expected_status='RELEASED' THEN
     c.close_reason='EXPIRED_SAFE_RELEASE' AND c.closed_at IS NOT NULL
     AND le.release_reason='EXPIRED_SAFE_RELEASE' AND le.closed_at IS NOT NULL
   ELSE c.closed_at IS NULL AND c.close_reason IS NULL
     AND le.closed_at IS NULL AND le.release_reason IS NULL
     AND le.expires_at<=statement_timestamp() END AS lease_outcome_match,
   l.listing_status=CASE WHEN e.expected_status='RELEASED' THEN 'AVAILABLE' ELSE 'CLAIMED' END
     AND d.donation_status=CASE WHEN e.expected_status='RELEASED' THEN 'AVAILABLE' ELSE 'CLAIMED' END
     AND l.source_type='DIRECT_DONATION' AND d.collection_path='DIRECT_PICKUP'
     AND l.listing_expires_at IS NULL
     AND l.listing_version=e.expected_version
     AND l.eligibility_generation=e.expected_generation AS lifecycle_match,
   NOT EXISTS(SELECT 1 FROM public.active_task_route_assignments a WHERE a.task_id=t.task_id)
     AND NOT EXISTS(SELECT 1 FROM public.pickup_route_stops s WHERE s.task_id=t.task_id)
     AND NOT EXISTS(SELECT 1 FROM public.claim_reconciliation_cases rc WHERE rc.claim_id=c.claim_id)
     AND NOT EXISTS(SELECT 1 FROM public.hub_inventory hi WHERE hi.donation_id=d.donation_id)
     AND NOT EXISTS(SELECT 1 FROM public.hub_batch_members m WHERE m.donation_id=d.donation_id) AS custody_clear,
   (SELECT count(*) FROM public.audit_events a WHERE a.claim_id=e.claim_id
      AND a.event_type='LEASE_RECOVERY')=CASE WHEN e.expected_status='RELEASED' THEN 1 ELSE 0 END
     AND (e.expected_status='ACTIVE' OR EXISTS(
       SELECT 1 FROM public.audit_events a WHERE a.claim_id=e.claim_id
       AND a.event_type='LEASE_RECOVERY' AND a.entity_type='CLAIM' AND a.entity_id=e.claim_id
       AND a.lease_id=e.lease_id AND a.actor_role='SYSTEM' AND a.actor_user_id IS NULL
       AND a.previous_state='ACTIVE' AND a.requested_state='RELEASED'
       AND a.resulting_state='RELEASED' AND a.reason_code='EXPIRED_SAFE_RELEASE'
       AND a.outcome='SUCCESS'
       AND a.details->>'listing_id'=e.listing_id::text
       AND a.details->>'donation_id'=e.donation_id::text
       AND a.details->>'task_id'=e.task_id::text)) AS recovery_audit_match,
   (SELECT count(*) FROM public.audit_events a WHERE a.claim_id=e.claim_id
      AND a.event_type='DONATION_STATUS_CHANGED')=CASE WHEN e.expected_status='RELEASED' THEN 1 ELSE 0 END
     AND (e.expected_status='ACTIVE' OR EXISTS(
       SELECT 1 FROM public.audit_events a WHERE a.claim_id=e.claim_id
       AND a.event_type='DONATION_STATUS_CHANGED' AND a.entity_type='DONATION'
       AND a.entity_id=e.donation_id AND a.lease_id=e.lease_id
       AND a.actor_role='SYSTEM' AND a.actor_user_id IS NULL
       AND a.previous_state='CLAIMED' AND a.requested_state='AVAILABLE'
       AND a.resulting_state='AVAILABLE' AND a.outcome='SUCCESS'
       AND a.details->>'listing_id'=e.listing_id::text)) AS donation_audit_match,
   e.expected_status='ACTIVE' OR EXISTS(
     SELECT 1 FROM public.listing_eligibility_refresh_jobs j WHERE j.listing_id=e.listing_id
       AND j.eligibility_generation=e.expected_generation
       AND j.expected_road_node_id=l.pickup_road_node_id
       AND j.job_status IN('PENDING','PROCESSING','COMPLETED')) AS refresh_enqueued
 FROM expected e LEFT JOIN public.donation_claims c ON c.claim_id=e.claim_id
 LEFT JOIN public.claim_leases le ON le.claim_id=c.claim_id
 LEFT JOIN public.pickup_tasks t ON t.claim_id=c.claim_id
 LEFT JOIN public.listings l ON l.listing_id=c.listing_id
 LEFT JOIN public.donations d ON d.donation_id=l.donation_id
)
SELECT *,coalesce(identities_match AND claim_lease_task_match AND lease_outcome_match
 AND lifecycle_match AND custody_clear AND recovery_audit_match AND donation_audit_match
 AND refresh_enqueued,false) AS all_checks_pass
FROM checks ORDER BY claim_id;
