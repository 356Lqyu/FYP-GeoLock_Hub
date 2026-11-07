-- SELECT-ONLY. DEV rcgyuwiidqvrgbxswhqj only. No RPC recovery or cron mutation.
SELECT statement_timestamp() AS observed_at,current_database(),current_user,
       current_setting('transaction_read_only') AS read_only;

SELECT p.oid::regprocedure AS identity,pg_get_function_arguments(p.oid) AS arguments,
       pg_get_function_result(p.oid) AS result,pg_get_userbyid(p.proowner) AS owner,
       p.prosecdef,p.proconfig,p.proacl,
       md5(replace(p.prosrc,E'\r\n',E'\n')) AS source_md5,
       has_function_privilege('anon',p.oid,'EXECUTE') AS anon_execute,
       has_function_privilege('authenticated',p.oid,'EXECUTE') AS authenticated_execute,
       has_function_privilege('service_role',p.oid,'EXECUTE') AS service_execute
FROM pg_proc p WHERE p.oid='public.recover_expired_claims(integer)'::regprocedure;
-- Stage 3G approved deployed body: 5ff6d8719db9681aae6f444b89dfbaee.
-- Hash prosrc with CRLF -> LF only, not whitespace-collapsed pg_get_functiondef.
-- A matching hash alone is not activation approval.
SELECT md5(replace(p.prosrc,E'\r\n',E'\n'))='5ff6d8719db9681aae6f444b89dfbaee'
       AS approved_stage3f_body
FROM pg_proc p WHERE p.oid='public.recover_expired_claims(integer)'::regprocedure;

SELECT jobid,jobname,schedule,command,username,database,active
FROM cron.job ORDER BY jobid;
SELECT count(*) AS recovery_schedules FROM cron.job
WHERE command ~* '\mrecover_expired_claims\M';
SELECT name,setting FROM pg_settings WHERE name LIKE 'cron.%' ORDER BY name;

SELECT jobid,runid,status,start_time,end_time,return_message
FROM cron.job_run_details WHERE jobid IN(1,2,3)
ORDER BY runid DESC LIMIT 60;
SELECT jobid,status,count(*),max(start_time) AS latest_start
FROM cron.job_run_details WHERE start_time>=statement_timestamp()-interval '1 hour'
  AND jobid IN(1,2,3) GROUP BY jobid,status ORDER BY jobid,status;
SELECT * FROM cron.job_run_details WHERE jobid IN(1,2,3) AND end_time IS NULL;

-- Alert on any retained ACTIVE/ACTIVE deadline overdue >5 minutes; inspect all
-- overdue rows during rollout. Age is a proposed operational threshold, not SQL policy.
SELECT c.claim_id,c.claim_status,le.lease_status,le.expires_at,
       statement_timestamp()-le.expires_at AS overdue_for,
       l.listing_id,l.source_type,l.listing_status,l.listing_expires_at,
       t.task_id,t.task_status,
       (SELECT count(*) FROM public.active_task_route_assignments a WHERE a.task_id=t.task_id) AS assignments,
       (SELECT count(*) FROM public.pickup_route_stops s WHERE s.task_id=t.task_id) AS stops,
       (SELECT count(*) FROM public.claim_reconciliation_cases rc
          WHERE (rc.claim_id=c.claim_id OR rc.listing_id=l.listing_id)
            AND rc.case_status IN('OPEN','MANUAL_REVIEW')) AS unresolved_cases
FROM public.donation_claims c JOIN public.claim_leases le USING(claim_id)
LEFT JOIN public.listings l ON l.listing_id=c.listing_id
LEFT JOIN public.pickup_tasks t USING(claim_id)
WHERE c.claim_status='ACTIVE' AND le.lease_status='ACTIVE'
  AND le.expires_at<=statement_timestamp() ORDER BY le.expires_at,c.claim_id;

-- Fail pre-activation if an ACTIVE pair already has unresolved review evidence.
SELECT c.claim_id,c.claim_status,le.lease_status,rc.case_id,rc.case_status
FROM public.claim_reconciliation_cases rc JOIN public.donation_claims c USING(claim_id)
LEFT JOIN public.claim_leases le USING(claim_id)
WHERE rc.case_status IN('OPEN','MANUAL_REVIEW') AND c.claim_status='ACTIVE';

-- Missing or inconsistent coordination is not automatically repaired by this worker.
SELECT c.claim_id,c.claim_status,le.lease_status,t.task_status,l.listing_status
FROM public.donation_claims c LEFT JOIN public.claim_leases le USING(claim_id)
LEFT JOIN public.pickup_tasks t USING(claim_id)
LEFT JOIN public.listings l ON l.listing_id=c.listing_id
WHERE c.claim_status IN('ACTIVE','RECONCILIATION_REQUIRED')
  AND (le.lease_id IS NULL OR t.task_id IS NULL OR l.listing_id IS NULL
       OR le.expires_at IS NULL OR le.lease_status IS DISTINCT FROM c.claim_status
       OR l.listing_status IS DISTINCT FROM 'CLAIMED');

SELECT rc.case_id,rc.claim_id,rc.case_status,rc.opened_at,rc.resolved_at,
       statement_timestamp()-rc.opened_at AS open_for,rc.resolution_reason
FROM public.claim_reconciliation_cases rc WHERE rc.case_status IN('OPEN','MANUAL_REVIEW')
ORDER BY rc.opened_at;
-- During DEV rollout, inspect every new case promptly. Escalate unresolved cases
-- older than one hour to a named human owner; never auto-close them by age.

SELECT occurred_at,event_type,claim_id,lease_id,previous_state,requested_state,
       resulting_state,reason_code,outcome,details
FROM public.audit_events WHERE event_type='LEASE_RECOVERY'
ORDER BY occurred_at DESC,event_id DESC LIMIT 100;
SELECT a.claim_id,count(*) AS recovery_events FROM public.audit_events a
WHERE a.event_type='LEASE_RECOVERY' GROUP BY a.claim_id HAVING count(*)>1;

SELECT c.claim_id,c.claim_status,le.lease_status,t.task_status,l.listing_status,
       d.donation_id,d.donation_status,l.listing_version,l.eligibility_generation
FROM public.audit_events a JOIN public.donation_claims c ON c.claim_id=a.claim_id
JOIN public.claim_leases le ON le.lease_id=a.lease_id
JOIN public.pickup_tasks t ON t.claim_id=c.claim_id
JOIN public.listings l ON l.listing_id=c.listing_id
LEFT JOIN public.donations d ON d.donation_id=l.donation_id
WHERE a.event_type='LEASE_RECOVERY' AND a.reason_code='EXPIRED_SAFE_RELEASE'
ORDER BY a.occurred_at DESC;
-- Shared listing/donation may legitimately have a NEW claim after reopening.
-- Evaluate current ownership and later audits; historical RELEASED rows remain terminal.

SELECT listing_id,eligibility_generation,job_status,attempt_count,requested_at,
       completed_at,last_error_code
FROM public.listing_eligibility_refresh_jobs
ORDER BY requested_at DESC LIMIT 100;

SELECT pid,usename,application_name,state,xact_start,wait_event_type,wait_event,
       pg_blocking_pids(pid) AS blockers,query
FROM pg_stat_activity WHERE pid<>pg_backend_pid() AND backend_type='client backend'
  AND xact_start IS NOT NULL;
SELECT pid,relation::regclass AS relation,mode,granted FROM pg_locks
WHERE pid<>pg_backend_pid() AND relation IN('public.donation_claims'::regclass,
 'public.claim_leases'::regclass,'public.listings'::regclass,'public.pickup_tasks'::regclass,
 'public.donations'::regclass,'public.hub_batches'::regclass,'public.hub_inventory'::regclass)
ORDER BY pid,relation,mode;
