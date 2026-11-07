-- SELECT ONLY. DEV rcgyuwiidqvrgbxswhqj ONLY. No function/cron invocation.
-- Poll from a fresh READ ONLY connection. External monitor retains run/event
-- watermarks and oldest-candidate identity; this query does not deliver alerts.
-- Detailed target audits/custody remain in ../claim_recovery_canary_monitoring.sql.
WITH overdue AS (
 SELECT c.claim_id,le.lease_id,le.expires_at,c.listing_id,l.source_type
 FROM public.donation_claims c JOIN public.claim_leases le USING(claim_id)
 JOIN public.listings l USING(listing_id)
 WHERE c.claim_status='ACTIVE' AND le.lease_status='ACTIVE'
   AND le.expires_at<=statement_timestamp()
), safe_release AS (
 SELECT c.claim_id,c.listing_id,le.lease_id,c.claim_status,le.lease_status,
   le.release_reason,t.task_status
 FROM public.donation_claims c LEFT JOIN public.claim_leases le USING(claim_id)
 LEFT JOIN public.pickup_tasks t USING(claim_id)
 WHERE c.claim_status='RELEASED' AND c.close_reason='EXPIRED_SAFE_RELEASE'
)
SELECT jsonb_build_object(
 'observed_at',statement_timestamp(),
 'jobs',(SELECT jsonb_agg(to_jsonb(j) ORDER BY jobid) FROM cron.job j WHERE jobid IN(1,2,3)),
 'recovery_schedules',(SELECT jsonb_agg(to_jsonb(j) ORDER BY jobid)
   FROM cron.job j WHERE command ~* '\mrecover_expired_claims\M'),
 'recovery_function',(SELECT jsonb_build_object('body_md5',md5(replace(prosrc,E'\r\n',E'\n')),
   'owner',pg_get_userbyid(proowner),'security_definer',prosecdef,'config',proconfig,'acl',proacl::text)
   FROM pg_proc WHERE oid=to_regprocedure('public.recover_expired_claims(integer)')),
 'latest_recovery_run',(SELECT to_jsonb(r) FROM cron.job_run_details r
   WHERE jobid=3 ORDER BY runid DESC LIMIT 1),
 'latest_recovery_failure',(SELECT to_jsonb(r) FROM cron.job_run_details r
   WHERE jobid=3 AND status='failed' ORDER BY runid DESC LIMIT 1),
 'unfinished_recovery_runs',(SELECT coalesce(jsonb_agg(jsonb_build_object('runid',runid,'status',status,
   'age_seconds',extract(epoch FROM statement_timestamp()-start_time)) ORDER BY runid),'[]'::jsonb)
   FROM cron.job_run_details WHERE jobid=3 AND end_time IS NULL),
 'eligibility_latest_success',(SELECT jsonb_agg(to_jsonb(x) ORDER BY jobid) FROM (
   SELECT jobid,max(end_time) AS ended_at FROM cron.job_run_details
   WHERE jobid IN(1,2) AND status='succeeded' GROUP BY jobid)x),
 'eligibility_latest_failure',(SELECT jsonb_agg(to_jsonb(x) ORDER BY jobid) FROM (
   SELECT DISTINCT ON(jobid) jobid,runid,start_time,end_time,return_message
   FROM cron.job_run_details WHERE jobid IN(1,2) AND status='failed' ORDER BY jobid,runid DESC)x),
 'overdue_count',(SELECT count(*) FROM overdue),
 'oldest_candidate',(SELECT to_jsonb(x) FROM (
   SELECT o.*,extract(epoch FROM statement_timestamp()-expires_at) AS overdue_seconds
   FROM overdue o ORDER BY expires_at,claim_id LIMIT 1)x),
 'latest_recovery_event',(SELECT jsonb_build_object('event_id',event_id,'occurred_at',occurred_at,
   'claim_id',claim_id,'lease_id',lease_id,'resulting_state',resulting_state,'reason_code',reason_code,'outcome',outcome)
   FROM public.audit_events WHERE event_type='LEASE_RECOVERY' ORDER BY occurred_at DESC,event_id DESC LIMIT 1),
 'unresolved_cases',(SELECT coalesce(jsonb_agg(jsonb_build_object('case_id',case_id,'claim_id',claim_id,
   'listing_id',listing_id,'status',case_status) ORDER BY case_id),'[]'::jsonb)
   FROM public.claim_reconciliation_cases WHERE case_status IN('OPEN','MANUAL_REVIEW')),
 'safe_release_integrity_alarms',(SELECT coalesce(jsonb_agg(s.claim_id),'[]'::jsonb) FROM safe_release s
   WHERE s.lease_status IS DISTINCT FROM 'RELEASED' OR s.release_reason IS DISTINCT FROM 'EXPIRED_SAFE_RELEASE'
   OR s.task_status IS DISTINCT FROM 'STALE'
   OR (SELECT count(*) FROM public.audit_events a WHERE a.claim_id=s.claim_id AND a.lease_id=s.lease_id
     AND a.event_type='LEASE_RECOVERY' AND a.resulting_state='RELEASED'
     AND a.reason_code='EXPIRED_SAFE_RELEASE' AND a.outcome='SUCCESS')<>1
   OR NOT EXISTS(SELECT 1 FROM public.audit_events a WHERE a.claim_id=s.claim_id AND a.lease_id=s.lease_id
     AND a.event_type='DONATION_STATUS_CHANGED' AND a.previous_state='CLAIMED'
     AND a.resulting_state IN('AVAILABLE','BATCHED') AND a.outcome='SUCCESS')),
 'stranded_claimed_listings',(SELECT coalesce(jsonb_agg(l.listing_id),'[]'::jsonb) FROM public.listings l
   WHERE l.listing_status='CLAIMED' AND NOT EXISTS(SELECT 1 FROM public.donation_claims c
     WHERE c.listing_id=l.listing_id AND c.claim_status IN('ACTIVE','RECONCILIATION_REQUIRED'))));
