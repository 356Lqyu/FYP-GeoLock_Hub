-- SELECT-only DEV preflight/health queries. No recovery or cron writes.
-- Confirm the selected project is rcgyuwiidqvrgbxswhqj in the SQL Editor.
SELECT current_database(),current_user,session_user,
       current_setting('transaction_read_only') AS read_only,
       auth.uid() AS jwt_subject,statement_timestamp() AS observed_at;

SELECT md5(replace(p.prosrc,E'\r\n',E'\n')) AS source_md5,
       pg_get_function_arguments(p.oid) AS arguments,
       pg_get_function_result(p.oid) AS result,
       pg_get_userbyid(p.proowner) AS owner,p.prosecdef,p.proconfig,p.proacl,
       md5(replace(p.prosrc,E'\r\n',E'\n'))='50110ff20115c4e5d46380e8e3f8b94c'
       AND p.proowner='postgres'::regrole AND p.prosecdef
       AND p.proconfig=ARRAY['search_path=pg_catalog, public, extensions, pg_temp']
       AND p.proacl='{postgres=X/postgres,service_role=X/postgres}'::aclitem[]
       AND pg_get_function_arguments(p.oid)='p_limit integer DEFAULT 100'
       AND pg_get_function_result(p.oid)='integer' AS source_and_security_match
FROM pg_proc p WHERE p.oid='public.recover_expired_claims(integer)'::regprocedure;

SELECT c.claim_id,le.lease_id,le.expires_at,
       row_number() OVER(ORDER BY le.expires_at,c.claim_id) AS recovery_order
FROM public.donation_claims c JOIN public.claim_leases le USING(claim_id)
WHERE c.claim_status='ACTIVE' AND le.lease_status='ACTIVE'
  AND le.expires_at<=statement_timestamp()
ORDER BY le.expires_at,c.claim_id;

-- Include older claims sharing either remaining listing, not only candidates.
SELECT c.claim_id,c.listing_id,c.claim_status,c.claimed_at,
       le.lease_id,le.lease_status,t.task_id,t.task_status
FROM public.donation_claims c LEFT JOIN public.claim_leases le USING(claim_id)
LEFT JOIN public.pickup_tasks t USING(claim_id)
WHERE c.listing_id IN('d7953dd2-7809-4cb4-87f3-52fc3294685b',
                     '16e5b6a1-475d-4c5a-9460-d4834dd5640f')
ORDER BY c.listing_id,c.claimed_at DESC,c.claim_id DESC;

SELECT * FROM public.hub_receipts WHERE donation_id IN(
 '3c32d1ae-ea3c-452c-8a76-9e05a0ad911a','0c8f21b4-2e87-466c-bc29-dc15c78f4a04');
SELECT * FROM public.hub_reservations WHERE donation_id IN(
 '3c32d1ae-ea3c-452c-8a76-9e05a0ad911a','0c8f21b4-2e87-466c-bc29-dc15c78f4a04');

SELECT c.claim_id,to_jsonb(c) AS claim,to_jsonb(le) AS lease,
       to_jsonb(t) AS task,to_jsonb(l) AS listing,to_jsonb(d) AS donation,
       (SELECT count(*) FROM public.active_task_route_assignments a
         WHERE a.task_id=t.task_id) AS active_assignments,
       (SELECT count(*) FROM public.pickup_route_stops s WHERE s.task_id=t.task_id) AS route_stops,
       (SELECT count(*) FROM public.claim_reconciliation_cases rc
         WHERE rc.claim_id=c.claim_id) AS reconciliation_cases,
       (SELECT count(*) FROM public.hub_inventory hi WHERE hi.donation_id=d.donation_id) AS hub_inventory,
       (SELECT count(*) FROM public.hub_batch_members m WHERE m.donation_id=d.donation_id) AS batch_memberships
FROM public.donation_claims c JOIN public.claim_leases le USING(claim_id)
JOIN public.pickup_tasks t USING(claim_id)
JOIN public.listings l ON l.listing_id=c.listing_id
JOIN public.donations d ON d.donation_id=l.donation_id
WHERE c.claim_id IN(
 '323ca3b3-7d7f-438e-8ed7-415f61b3a567',
 'aa3cd6d2-e5b3-4369-a41f-ec9a0eaae716',
 '9a2ab42b-52c6-4c3a-99fb-b5c95d41e63f')
ORDER BY le.expires_at,c.claim_id;

SELECT a.* FROM public.audit_events a WHERE a.claim_id IN(
 '323ca3b3-7d7f-438e-8ed7-415f61b3a567',
 'aa3cd6d2-e5b3-4369-a41f-ec9a0eaae716',
 '9a2ab42b-52c6-4c3a-99fb-b5c95d41e63f')
ORDER BY a.occurred_at,a.event_id;

SELECT * FROM public.claim_reconciliation_cases WHERE claim_id IN(
 '323ca3b3-7d7f-438e-8ed7-415f61b3a567',
 'aa3cd6d2-e5b3-4369-a41f-ec9a0eaae716',
 '9a2ab42b-52c6-4c3a-99fb-b5c95d41e63f');

SELECT * FROM public.listing_eligibility_refresh_jobs WHERE listing_id IN(
 '2d06b504-d2dd-4121-8840-c8bf893f8a60',
 'd7953dd2-7809-4cb4-87f3-52fc3294685b',
 '16e5b6a1-475d-4c5a-9460-d4834dd5640f')
ORDER BY listing_id,eligibility_generation;

SELECT jobid,jobname,schedule,command,username,database,active FROM cron.job
WHERE jobid IN(1,2,3) ORDER BY jobid;

SELECT jobid,runid,status,start_time,end_time,return_message
FROM cron.job_run_details WHERE jobid IN(1,2,3)
ORDER BY runid DESC LIMIT 30;

SELECT count(*) AS recovery_cron_runs FROM cron.job_run_details WHERE jobid=3;

SELECT pid,usename,state,xact_start,wait_event_type,wait_event,query
FROM pg_stat_activity WHERE pid<>pg_backend_pid()
  AND backend_type='client backend' AND xact_start IS NOT NULL;

SELECT pid,relation::regclass AS relation,mode,granted
FROM pg_locks WHERE pid<>pg_backend_pid() AND relation IN(
 'public.donation_claims'::regclass,'public.claim_leases'::regclass,
 'public.listings'::regclass,'public.pickup_tasks'::regclass,'public.donations'::regclass)
ORDER BY pid,relation,mode;
