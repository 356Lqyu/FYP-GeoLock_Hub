-- Stage 3G SELECT ONLY. DEV rcgyuwiidqvrgbxswhqj only.
-- Run with automatic_readiness.sql before activation, every minute, and after pause.
-- Save activation COMMIT time/runid and all output externally; no DB snapshot writes.
-- Rolling 15m window covers the supervised 10m canary. For later investigation,
-- replace the window with the saved activation timestamp, never infer it from now().
SELECT statement_timestamp() AS observed_at,
  (SELECT count(*) FROM public.donation_claims c JOIN public.claim_leases le USING(claim_id)
    WHERE c.claim_status='ACTIVE' AND le.lease_status='ACTIVE'
      AND le.expires_at<=statement_timestamp()) AS overdue_pairs,
  (SELECT min(le.expires_at) FROM public.donation_claims c JOIN public.claim_leases le USING(claim_id)
    WHERE c.claim_status='ACTIVE' AND le.lease_status='ACTIVE'
      AND le.expires_at<=statement_timestamp()) AS oldest_overdue_deadline,
  (SELECT count(*) FROM public.claim_reconciliation_cases
    WHERE case_status IN('OPEN','MANUAL_REVIEW')) AS unresolved_cases,
  (SELECT count(*) FROM public.audit_events WHERE event_type='LEASE_RECOVERY') AS recovery_audits,
  (SELECT count(*) FROM cron.job_run_details WHERE jobid=3) AS recovery_runs;

-- Before: inactive / limit 100 / zero runs. During: active / limit 1.
-- After pause: inactive / limit 1. Re-activation requires a fresh review/script.
SELECT jobid,jobname,schedule,command,username,database,active
FROM cron.job WHERE jobid IN(1,2,3) ORDER BY jobid;
SELECT runid,jobid,status,start_time,end_time,
       coalesce(end_time,statement_timestamp())-start_time AS elapsed,return_message
FROM cron.job_run_details WHERE jobid=3 ORDER BY runid DESC LIMIT 30;
-- '1 row' is SQL result-row count, NOT the number of recovered claims.
-- Successful empty-backlog runs produce no new business audit, which is expected.
SELECT jobid,status,count(*) AS runs,max(start_time) AS latest_start
FROM cron.job_run_details
WHERE jobid IN(1,2,3) AND start_time>=statement_timestamp()-interval '15 minutes'
GROUP BY jobid,status ORDER BY jobid,status;
SELECT DISTINCT ON(jobid) jobid,runid,status,start_time,end_time,return_message
FROM cron.job_run_details WHERE jobid IN(1,2) ORDER BY jobid,runid DESC;
SELECT jobid,runid,status,start_time,end_time,return_message
FROM cron.job_run_details WHERE jobid IN(1,2,3) AND end_time IS NULL;

-- Target-scoped evidence: inspect every new recovery event, never global equality.
SELECT a.event_id,a.occurred_at,a.claim_id,a.lease_id,a.resulting_state,
       a.reason_code,a.outcome,a.details,c.claim_status,le.lease_status,
       t.task_status,l.listing_status,l.listing_version,l.eligibility_generation,
       (SELECT count(*) FROM public.audit_events x
         WHERE x.event_type='LEASE_RECOVERY' AND x.claim_id=a.claim_id
           AND x.lease_id=a.lease_id) AS recovery_events_for_pair,
       (SELECT count(*) FROM public.audit_events x
         WHERE x.event_type='DONATION_STATUS_CHANGED' AND x.claim_id=a.claim_id
           AND x.lease_id=a.lease_id AND x.previous_state='CLAIMED'
           AND x.resulting_state IN('AVAILABLE','BATCHED') AND x.outcome='SUCCESS') AS donation_transition_events,
       (SELECT jsonb_agg(to_jsonb(rc)) FROM public.claim_reconciliation_cases rc
         WHERE rc.claim_id=a.claim_id OR rc.listing_id=l.listing_id) AS cases,
       (SELECT jsonb_agg(to_jsonb(j) ORDER BY j.eligibility_generation)
         FROM public.listing_eligibility_refresh_jobs j WHERE j.listing_id=l.listing_id) AS refresh_jobs
FROM public.audit_events a
LEFT JOIN public.donation_claims c ON c.claim_id=a.claim_id
LEFT JOIN public.claim_leases le ON le.lease_id=a.lease_id
LEFT JOIN public.pickup_tasks t ON t.claim_id=a.claim_id
LEFT JOIN public.listings l ON l.listing_id=c.listing_id
WHERE a.event_type='LEASE_RECOVERY'
  AND a.occurred_at>=statement_timestamp()-interval '15 minutes'
ORDER BY a.occurred_at,a.event_id;
-- Reclaimed listings can legitimately change again; compare snapshots and later
-- audits before attributing their present state to the recovery worker.

-- Expected empty: terminal safe release with missing/wrong recovery audit.
SELECT c.claim_id,le.lease_id,c.claim_status,le.lease_status,c.close_reason
FROM public.donation_claims c LEFT JOIN public.claim_leases le USING(claim_id)
WHERE c.claim_status='RELEASED' AND c.close_reason='EXPIRED_SAFE_RELEASE'
  AND (le.lease_status IS DISTINCT FROM 'RELEASED'
    OR le.release_reason IS DISTINCT FROM 'EXPIRED_SAFE_RELEASE'
    OR NOT EXISTS(SELECT 1 FROM public.audit_events a
      WHERE a.claim_id=c.claim_id AND a.lease_id=le.lease_id
        AND a.event_type='LEASE_RECOVERY' AND a.resulting_state='RELEASED'
        AND a.reason_code='EXPIRED_SAFE_RELEASE' AND a.outcome='SUCCESS'));

-- Current backlog and custody evidence. Pause on any unexplained retained oldest
-- candidate or a deadline >5m overdue; do not increase batch size to bypass it.
SELECT c.claim_id,c.claim_status,le.lease_status,le.expires_at,
       statement_timestamp()-le.expires_at AS overdue_for,
       l.listing_id,l.source_type,l.listing_status,l.listing_expires_at,
       d.donation_id,d.collection_path,d.donation_status,t.task_id,t.task_status,
       (SELECT jsonb_agg(to_jsonb(x)) FROM public.active_task_route_assignments x
         WHERE x.task_id=t.task_id) AS route_assignments,
       (SELECT jsonb_agg(to_jsonb(x)) FROM public.pickup_route_stops x
         WHERE x.task_id=t.task_id) AS route_stops,
       (SELECT jsonb_agg(to_jsonb(x)) FROM public.claim_reconciliation_cases x
         WHERE (x.claim_id=c.claim_id OR x.listing_id=l.listing_id)
           AND x.case_status IN('OPEN','MANUAL_REVIEW')) AS unresolved_cases,
       (SELECT jsonb_agg(jsonb_build_object('member',to_jsonb(m),'donation',to_jsonb(md),
           'inventory',to_jsonb(hi)))
         FROM public.hub_batch_members m JOIN public.donations md USING(donation_id)
         LEFT JOIN public.hub_inventory hi USING(donation_id)
         WHERE m.batch_id=l.batch_id AND m.membership_status='ACTIVE') AS hub_members
FROM public.donation_claims c JOIN public.claim_leases le USING(claim_id)
LEFT JOIN public.listings l ON l.listing_id=c.listing_id
LEFT JOIN public.donations d ON d.donation_id=l.donation_id
LEFT JOIN public.pickup_tasks t USING(claim_id)
WHERE c.claim_status='ACTIVE' AND le.lease_status='ACTIVE'
  AND le.expires_at<=statement_timestamp() ORDER BY le.expires_at,c.claim_id;

SELECT rc.* FROM public.claim_reconciliation_cases rc
WHERE rc.case_status IN('OPEN','MANUAL_REVIEW') ORDER BY rc.opened_at;
SELECT pid,usename,application_name,state,xact_start,wait_event_type,wait_event,
       pg_blocking_pids(pid) AS blockers,query
FROM pg_stat_activity WHERE pid<>pg_backend_pid() AND xact_start IS NOT NULL
  AND backend_type='client backend';
SELECT pid,relation::regclass AS relation,mode,granted FROM pg_locks
WHERE pid<>pg_backend_pid() AND relation IN('public.donation_claims'::regclass,
 'public.claim_leases'::regclass,'public.listings'::regclass,'public.pickup_tasks'::regclass,
 'public.donations'::regclass,'public.hub_batches'::regclass,'public.hub_inventory'::regclass,
 'public.claim_reconciliation_cases'::regclass) ORDER BY pid,relation,mode;
