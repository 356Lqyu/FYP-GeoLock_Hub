-- Stage 3H SELECT ONLY. DEV rcgyuwiidqvrgbxswhqj ONLY.
-- Historical window: 2026-10-22 19:44 through 19:55 UTC, inclusive minutes.
-- The exact pause COMMIT timestamp is not stored in cron.job.
-- No recovery invocation, cron mutation, validator RPC, DDL or DML.
SELECT statement_timestamp() AS observed_at,current_database(),current_user,
       current_setting('transaction_read_only') AS read_only;

SELECT jobid,jobname,schedule,command,username,database,nodename,nodeport,active
FROM cron.job WHERE jobid IN(1,2,3) ORDER BY jobid;
SELECT count(*) AS total_job3_runs,
       count(*) FILTER(WHERE status='succeeded') AS succeeded,
       count(*) FILTER(WHERE status='failed') AS failed,
       count(*) FILTER(WHERE status NOT IN('succeeded','failed')) AS other_status,
       count(*) FILTER(WHERE end_time IS NULL) AS unfinished,
       count(*) FILTER(WHERE start_time<'2026-10-22 19:44:00+00'::timestamptz
         OR start_time>='2026-10-22 19:56:00+00'::timestamptz) AS outside_reported_window,
       min(start_time) AS first_start,max(start_time) AS last_start,max(end_time) AS last_end,
       min(end_time-start_time) AS minimum_duration,
       max(end_time-start_time) AS maximum_duration
FROM cron.job_run_details WHERE jobid=3;
SELECT m.minute,count(r.runid) AS executions,
       count(r.runid) FILTER(WHERE r.status='succeeded') AS succeeded
FROM generate_series('2026-10-22 19:44:00+00'::timestamptz,
  '2026-10-22 19:55:00+00'::timestamptz,interval '1 minute') AS m(minute)
LEFT JOIN cron.job_run_details r ON r.jobid=3
  AND r.start_time>=m.minute AND r.start_time<m.minute+interval '1 minute'
GROUP BY m.minute ORDER BY m.minute;
SELECT jobid,runid,job_pid,status,start_time,end_time,command,return_message
FROM cron.job_run_details WHERE jobid=3 ORDER BY runid;
SELECT jobid,status,count(*) AS runs,max(start_time) AS latest_start,max(end_time) AS latest_end
FROM cron.job_run_details WHERE jobid IN(1,2)
  AND start_time>=statement_timestamp()-interval '1 hour'
GROUP BY jobid,status ORDER BY jobid,status;
SELECT * FROM cron.job_run_details WHERE jobid IN(1,2,3) AND end_time IS NULL;

SELECT pg_get_function_arguments(p.oid) AS arguments,pg_get_function_result(p.oid) AS result,
       pg_get_userbyid(p.proowner) AS owner,p.prosecdef,p.proconfig,p.proacl,
       md5(replace(p.prosrc,E'\r\n',E'\n')) AS body_fingerprint,
       md5(replace(p.prosrc,E'\r\n',E'\n'))='5ff6d8719db9681aae6f444b89dfbaee' AS approved_body,
       has_function_privilege('anon',p.oid,'EXECUTE') AS anon_execute,
       has_function_privilege('authenticated',p.oid,'EXECUTE') AS authenticated_execute,
       has_function_privilege('service_role',p.oid,'EXECUTE') AS service_execute
FROM pg_proc p WHERE p.oid='public.recover_expired_claims(integer)'::regprocedure;

SELECT donation_status,collection_path,count(*) FROM public.donations GROUP BY 1,2 ORDER BY 1,2;
SELECT c.claim_status,le.lease_status,t.task_status,count(*)
FROM public.donation_claims c LEFT JOIN public.claim_leases le USING(claim_id)
LEFT JOIN public.pickup_tasks t USING(claim_id) GROUP BY 1,2,3 ORDER BY 1,2,3;
SELECT * FROM public.claim_reconciliation_cases WHERE case_status IN('OPEN','MANUAL_REVIEW');
SELECT c.claim_id,le.lease_id,le.expires_at
FROM public.donation_claims c JOIN public.claim_leases le USING(claim_id)
WHERE c.claim_status='ACTIVE' AND le.lease_status='ACTIVE' AND le.expires_at<=statement_timestamp();

-- SELECT equivalents of deployed lifecycle validator predicates. Expected empty.
-- No call to geolock_assert_donation_lifecycle or any stateful routine.
WITH evidence AS (
 SELECT d.*,l.listing_id,l.listing_status,b.batch_id,b.batch_status,b.batch_donation_count,b.hub_id
 FROM public.donations d
 LEFT JOIN public.hub_batch_members m ON m.donation_id=d.donation_id
   AND m.membership_status='ACTIVE' AND d.collection_path='HUB_COLLECTION'
 LEFT JOIN public.hub_batches b ON b.batch_id=m.batch_id
 LEFT JOIN public.listings l ON
   (d.collection_path='DIRECT_PICKUP' AND l.source_type='DIRECT_DONATION' AND l.donation_id=d.donation_id)
   OR (d.collection_path='HUB_COLLECTION' AND l.source_type='HUB_BATCH' AND l.batch_id=b.batch_id)
), violations AS (
 SELECT donation_id,'CLASSIFICATION_OR_FINALIZATION' AS issue FROM evidence
 WHERE collection_path IS NULL OR total_weight_kg IS NULL OR total_weight_kg<=0
   OR (collection_path='DIRECT_PICKUP') IS DISTINCT FROM (total_weight_kg>=10)
   OR (collection_path='DIRECT_PICKUP' AND donation_status IN('SUBMITTED','HUB_ASSIGNED','AT_HUB','BATCHED'))
   OR (collection_path='HUB_COLLECTION' AND donation_status='AVAILABLE')
 UNION ALL
 SELECT donation_id,'MISSING_LISTING' FROM evidence
 WHERE donation_status NOT IN('CANCELLED','SUBMITTED','HUB_ASSIGNED','AT_HUB') AND listing_id IS NULL
 UNION ALL
 SELECT e.donation_id,'HUB_BATCH_SET' FROM evidence e
 WHERE e.collection_path='HUB_COLLECTION' AND e.donation_status NOT IN('CANCELLED','SUBMITTED','HUB_ASSIGNED','AT_HUB')
   AND (e.batch_id IS NULL OR e.batch_status IS DISTINCT FROM
       (CASE WHEN e.donation_status='COLLECTED' THEN 'COLLECTED' ELSE 'PUBLISHED' END)
     OR (SELECT count(*) FROM public.hub_batch_members m
       WHERE m.batch_id=e.batch_id AND m.membership_status='ACTIVE')<>e.batch_donation_count
     OR EXISTS(SELECT 1 FROM public.hub_batch_members m JOIN public.donations md USING(donation_id)
       WHERE m.batch_id=e.batch_id AND m.membership_status='ACTIVE'
         AND (md.donation_status<>e.donation_status OR md.collection_path<>'HUB_COLLECTION'))
     OR EXISTS(SELECT 1 FROM public.hub_batch_members m
       WHERE m.batch_id=e.batch_id AND m.membership_status='ACTIVE'
         AND NOT EXISTS(SELECT 1 FROM public.hub_inventory hi
           WHERE hi.donation_id=m.donation_id AND hi.hub_id=e.hub_id
             AND hi.inventory_status=CASE WHEN e.donation_status='COLLECTED' THEN 'COLLECTED' ELSE 'BATCHED' END)))
 UNION ALL
 SELECT e.donation_id,'AVAILABLE_COORDINATION' FROM evidence e
 WHERE e.donation_status IN('AVAILABLE','BATCHED')
   AND (e.listing_status IS DISTINCT FROM 'AVAILABLE' OR EXISTS(
     SELECT 1 FROM public.donation_claims c WHERE c.listing_id=e.listing_id
       AND c.claim_status IN('ACTIVE','RECONCILIATION_REQUIRED')))
 UNION ALL
 SELECT e.donation_id,'COLLECTED_COORDINATION' FROM evidence e
 WHERE e.donation_status='COLLECTED' AND (e.listing_status IS DISTINCT FROM 'CLOSED'
   OR NOT EXISTS(SELECT 1 FROM public.donation_claims c JOIN public.claim_leases le USING(claim_id)
     JOIN public.pickup_tasks t USING(claim_id) WHERE c.listing_id=e.listing_id AND t.listing_id=e.listing_id
       AND c.claim_status='COMPLETED' AND le.lease_status='COMPLETED' AND t.task_status='COLLECTED'))
 UNION ALL
 SELECT e.donation_id,'CLAIMED_COORDINATION' FROM evidence e
 WHERE e.donation_status IN('CLAIMED','PICKUP_IN_PROGRESS')
   AND (e.listing_status IS DISTINCT FROM 'CLAIMED' OR NOT EXISTS(
     SELECT 1 FROM public.donation_claims c JOIN public.claim_leases le USING(claim_id)
     JOIN public.pickup_tasks t USING(claim_id) WHERE c.listing_id=e.listing_id AND t.listing_id=e.listing_id
       AND c.claim_status IN('ACTIVE','RECONCILIATION_REQUIRED') AND le.lease_status=c.claim_status
       AND ((e.donation_status='CLAIMED' AND t.task_status IN('CONFIRMED','PLANNED'))
         OR (e.donation_status='PICKUP_IN_PROGRESS' AND t.task_status='DISPATCHED'))))
)
SELECT * FROM violations ORDER BY donation_id,issue;

-- Domain and deferred guard still installed; catalog inspection only.
SELECT conname,convalidated,pg_get_constraintdef(oid) AS definition
FROM pg_constraint WHERE conrelid='public.donations'::regclass AND conname='donations_donation_status_check';
SELECT tgname,tgenabled,tgdeferrable,tginitdeferred
FROM pg_trigger WHERE tgrelid='public.donations'::regclass AND tgname='donations_lifecycle_at_commit';

-- Any row here requires attribution; empty now. Use fixed start, not rolling 15m.
SELECT event_id,occurred_at,event_type,claim_id,lease_id,resulting_state,reason_code,outcome,details
FROM public.audit_events WHERE occurred_at>='2026-10-22 19:44:00+00'::timestamptz ORDER BY occurred_at,event_id;
SELECT claim_id,lease_id,count(*) AS recovery_events FROM public.audit_events
WHERE event_type='LEASE_RECOVERY' GROUP BY claim_id,lease_id HAVING count(*)<>1;
SELECT c.claim_id,le.lease_id FROM public.donation_claims c
LEFT JOIN public.claim_leases le USING(claim_id)
WHERE c.close_reason='EXPIRED_SAFE_RELEASE' AND (c.claim_status IS DISTINCT FROM 'RELEASED'
  OR le.lease_status IS DISTINCT FROM 'RELEASED' OR NOT EXISTS(
    SELECT 1 FROM public.audit_events a WHERE a.event_type='LEASE_RECOVERY'
      AND a.claim_id=c.claim_id AND a.lease_id=le.lease_id AND a.reason_code='EXPIRED_SAFE_RELEASE'
      AND a.resulting_state='RELEASED' AND a.outcome='SUCCESS'));

SELECT 'NGO' AS worker,job_status,count(*) AS jobs,max(completed_at) AS latest_completed
FROM public.ngo_eligibility_refresh_jobs GROUP BY job_status
UNION ALL
SELECT 'LISTING',job_status,count(*),max(completed_at)
FROM public.listing_eligibility_refresh_jobs GROUP BY job_status ORDER BY worker,job_status;
SELECT 'NGO' AS worker,job_id,job_status,requested_at,started_at,completed_at,last_error_code
FROM public.ngo_eligibility_refresh_jobs WHERE job_status<>'COMPLETED' OR last_error_code IS NOT NULL
UNION ALL
SELECT 'LISTING',job_id,job_status,requested_at,started_at,completed_at,last_error_code
FROM public.listing_eligibility_refresh_jobs WHERE job_status<>'COMPLETED' OR last_error_code IS NOT NULL;
SELECT count(*) AS route_assignments FROM public.active_task_route_assignments;
SELECT count(*) AS route_stops FROM public.pickup_route_stops;
SELECT pid,usename,application_name,state,xact_start,wait_event_type,wait_event,
       pg_blocking_pids(pid) AS blockers,query
FROM pg_stat_activity WHERE pid<>pg_backend_pid() AND xact_start IS NOT NULL
  AND backend_type='client backend';
SELECT pid,relation::regclass AS relation,mode,granted FROM pg_locks
WHERE pid<>pg_backend_pid() AND relation IN('public.donation_claims'::regclass,
 'public.claim_leases'::regclass,'public.pickup_tasks'::regclass,'public.listings'::regclass,
 'public.donations'::regclass,'public.claim_reconciliation_cases'::regclass,
 'public.hub_batches'::regclass,'public.hub_inventory'::regclass) ORDER BY pid,relation,mode;
