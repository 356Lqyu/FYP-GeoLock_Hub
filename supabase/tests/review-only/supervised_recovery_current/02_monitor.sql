-- SELECT ONLY, DEV rcgyuwiidqvrgbxswhqj. Poll every 5-10 seconds while supervised.
SELECT statement_timestamp() AS observed_at,jobid,jobname,active,schedule,command,username
FROM cron.job WHERE jobid IN(1,2,3) ORDER BY jobid;
SELECT runid,status,start_time,end_time,return_message
FROM cron.job_run_details WHERE jobid=3 ORDER BY runid DESC LIMIT 10;
-- Compare run IDs and audit timestamps with the activation receipt watermark.
-- "1 row" is not a processed-claim count. Empty-backlog success may emit no audit.
SELECT event_id,occurred_at,claim_id,lease_id,resulting_state,reason_code,outcome
FROM public.audit_events WHERE event_type='LEASE_RECOVERY'
ORDER BY occurred_at DESC,event_id DESC LIMIT 10;
SELECT case_id,claim_id,listing_id,case_status,opened_at
FROM public.claim_reconciliation_cases WHERE case_status IN('OPEN','MANUAL_REVIEW');
SELECT jobid,runid,status,start_time,end_time FROM cron.job_run_details
WHERE jobid IN(1,2,3) AND end_time IS NULL;
