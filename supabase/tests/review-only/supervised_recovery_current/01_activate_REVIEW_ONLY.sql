-- REVIEW ONLY. No execution approval has been given for this file.
-- DEV rcgyuwiidqvrgbxswhqj only; human verifies the project in SQL Editor.
-- Read the README. Operator confirmation defaults to NOT_APPROVED.
-- No fixture dependency, fixed run-count baseline, recovery call or new object.
BEGIN ISOLATION LEVEL REPEATABLE READ;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='10s';
SET LOCAL idle_in_transaction_session_timeout='10s';
SET LOCAL search_path=pg_catalog,public,pg_temp;
SET LOCAL TimeZone='UTC';
-- Same permission-compatible business-lock strategy as the approved procedure.
-- NOWAIT: stop rather than wait behind a writer. No LOCK on cron.job.
-- This must precede DO/SELECT so the transaction snapshot follows the locks.
LOCK TABLE public.donation_claims,public.claim_leases,public.listings,public.pickup_tasks,public.donations,public.hub_batches,public.hub_batch_members,public.hub_inventory,public.active_task_route_assignments,public.pickup_route_stops,public.claim_reconciliation_cases,public.hub_reservations,public.hub_receipts,public.coordination_config,public.audit_events,public.listing_eligibility_refresh_jobs IN EXCLUSIVE MODE NOWAIT;
DO $supervised$
DECLARE
 v_operator constant text := 'DEV Test Operator (myself)';
 -- Replace ONLY after the user's separate final approval of this session.
 v_confirmation constant text := 'NOT_APPROVED';
 v_before jsonb; v_workers jsonb; v_at timestamptz; v_deadline timestamptz;
 v_run_id bigint; v_event_at timestamptz;
 v_command constant text := 'set lock_timeout = ''5s''; set statement_timeout = ''50s''; select public.recover_expired_claims(1);';
BEGIN
 IF v_confirmation IS DISTINCT FROM 'I_CONFIRM_DEV_rcgyuwiidqvrgbxswhqj_SUPERVISE_AND_PAUSE_WITHIN_300_SECONDS'
   OR btrim(v_operator)='' THEN
   RAISE EXCEPTION 'FINAL_APPROVAL_DEV_PROJECT_AND_PRESENT_OPERATOR_REQUIRED'; END IF;
 IF current_database()<>'postgres' OR current_user<>'postgres' OR session_user<>'postgres'
   OR auth.uid() IS NOT NULL THEN
   RAISE EXCEPTION 'CLEAN_POSTGRES_SESSION_REQUIRED'; END IF;
 IF NOT pg_try_advisory_xact_lock(1936288105,3) THEN
   RAISE EXCEPTION 'RECOVERY_ACTIVATION_PROTOCOL_BUSY'; END IF;
 IF NOT has_table_privilege(current_user,'cron.job','SELECT')
   OR NOT has_function_privilege(current_user,
     'cron.alter_job(bigint,text,text,text,text,boolean)','EXECUTE') THEN
   RAISE EXCEPTION 'SUPPORTED_CRON_API_PERMISSIONS_REQUIRED'; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_proc p
   WHERE p.oid=to_regprocedure('public.recover_expired_claims(integer)')
     AND md5(replace(p.prosrc,E'\r\n',E'\n'))='5ff6d8719db9681aae6f444b89dfbaee'
     AND p.proowner='postgres'::regrole AND p.prosecdef
     AND p.proconfig=ARRAY['search_path=pg_catalog, public, extensions, pg_temp']
     AND p.proacl='{postgres=X/postgres,service_role=X/postgres}'::aclitem[]
     AND pg_get_function_arguments(p.oid)='p_limit integer DEFAULT 100'
     AND pg_get_function_result(p.oid)='integer') THEN
   RAISE EXCEPTION 'SOURCE_OR_SECURITY_DRIFT'; END IF;

 SELECT to_jsonb(j) INTO v_before FROM cron.job j WHERE jobid=3;
 IF NOT EXISTS(SELECT 1 FROM cron.job WHERE jobid=3 AND NOT active
   AND jobname='geolock-expired-claim-recovery' AND username='postgres'
   AND database=current_database() AND nodename='localhost' AND nodeport=5432
   AND schedule='* * * * *'
   AND command IN(v_command,v_command||' -- STAGE3I_ONE_USE_8b4a48ed-97e4-41a9-aa1f-b588ae850b4f'))
   OR (SELECT count(*) FROM cron.job WHERE command ~* '\mrecover_expired_claims\M')<>1 THEN
   RAISE EXCEPTION 'RECOVERY_JOB_CONFIGURATION_DRIFT'; END IF;
 -- No hard-coded 0/12/17 run count. Retained failures still require human review.
 IF EXISTS(SELECT 1 FROM cron.job_run_details WHERE jobid=3
     AND (status<>'succeeded' OR end_time IS NULL))
   OR EXISTS(SELECT 1 FROM pg_stat_activity WHERE pid<>pg_backend_pid()
     AND backend_type='client backend' AND state='active'
     AND query ~* '\mrecover_expired_claims\M') THEN
   RAISE EXCEPTION 'RECOVERY_HISTORY_OR_ACTIVE_EXECUTION_REQUIRES_REVIEW'; END IF;
 IF NOT EXISTS(SELECT 1 FROM cron.job WHERE jobid=1 AND active
     AND jobname='geolock-ngo-eligibility-refresh' AND username='postgres'
     AND command='set statement_timeout = ''10min''; select public.process_ngo_eligibility_refresh_jobs();'
     AND schedule='* * * * *' AND database=current_database())
   OR NOT EXISTS(SELECT 1 FROM cron.job WHERE jobid=2 AND active
     AND jobname='geolock-listing-eligibility-refresh' AND username='postgres'
     AND command='set statement_timeout = ''10min''; select public.process_listing_eligibility_refresh_jobs();'
     AND schedule='* * * * *' AND database=current_database())
   OR EXISTS(SELECT 1 FROM cron.job_run_details WHERE jobid IN(1,2)
     AND status='failed' AND start_time>=statement_timestamp()-interval '15 minutes')
   OR (SELECT count(DISTINCT jobid) FROM cron.job_run_details WHERE jobid IN(1,2)
     AND status='succeeded' AND end_time>=statement_timestamp()-interval '12 minutes')<>2 THEN
   RAISE EXCEPTION 'ELIGIBILITY_WORKER_HEALTH_OR_CONFIGURATION_CHANGED'; END IF;
 IF (SELECT claim_lease_minutes FROM public.coordination_config WHERE singleton) IS DISTINCT FROM 360
   OR EXISTS(SELECT 1 FROM public.claim_reconciliation_cases WHERE case_status IN('OPEN','MANUAL_REVIEW')) THEN
   RAISE EXCEPTION 'LEASE_POLICY_OR_UNRESOLVED_CASE_REQUIRES_REVIEW'; END IF;
 -- Safe default for this untargeted session: no unreviewed existing backlog.
 -- If nonempty, stop and review its IDs/custody; never waive this guard ad hoc.
 IF EXISTS(SELECT 1 FROM public.donation_claims c JOIN public.claim_leases le USING(claim_id)
   WHERE c.claim_status='ACTIVE' AND le.lease_status='ACTIVE' AND le.expires_at<=clock_timestamp()) THEN
   RAISE EXCEPTION 'OVERDUE_BACKLOG_REQUIRES_EXPLICIT_CANDIDATE_REVIEW'; END IF;
 IF EXISTS(SELECT 1 FROM public.listings l WHERE l.listing_status='CLAIMED'
   AND NOT EXISTS(SELECT 1 FROM public.donation_claims c WHERE c.listing_id=l.listing_id
     AND c.claim_status IN('ACTIVE','RECONCILIATION_REQUIRED')))
   OR EXISTS(SELECT 1 FROM public.donation_claims c
     LEFT JOIN public.claim_leases le USING(claim_id)
     LEFT JOIN public.pickup_tasks t USING(claim_id)
     WHERE c.claim_status='RELEASED' AND c.close_reason='EXPIRED_SAFE_RELEASE'
       AND (le.lease_status IS DISTINCT FROM 'RELEASED'
         OR le.release_reason IS DISTINCT FROM 'EXPIRED_SAFE_RELEASE'
         OR t.task_status IS DISTINCT FROM 'STALE'
         OR (SELECT count(*) FROM public.audit_events a WHERE a.claim_id=c.claim_id
           AND a.lease_id=le.lease_id AND a.event_type='LEASE_RECOVERY' AND a.outcome='SUCCESS'
           AND a.resulting_state='RELEASED' AND a.reason_code='EXPIRED_SAFE_RELEASE')<>1
         OR NOT EXISTS(SELECT 1 FROM public.audit_events a WHERE a.claim_id=c.claim_id
           AND a.lease_id=le.lease_id AND a.event_type='DONATION_STATUS_CHANGED'
           AND a.previous_state='CLAIMED' AND a.resulting_state IN('AVAILABLE','BATCHED')
           AND a.outcome='SUCCESS'))) THEN
   RAISE EXCEPTION 'RECOVERY_INTEGRITY_OR_AUDIT_REQUIRES_REVIEW'; END IF;

 SELECT jsonb_agg(to_jsonb(j) ORDER BY jobid) INTO v_workers FROM cron.job j WHERE jobid IN(1,2);
 SELECT max(runid) INTO v_run_id FROM cron.job_run_details WHERE jobid=3;
 SELECT max(occurred_at) INTO v_event_at FROM public.audit_events WHERE event_type='LEASE_RECOVERY';
 -- Supported no-op update obtains job 3's row lock without cron table privileges.
 -- REPEATABLE READ aborts on a conflicting update since this snapshot.
 PERFORM cron.alter_job(3,active := false);
 IF v_before IS DISTINCT FROM (SELECT to_jsonb(j) FROM cron.job j WHERE jobid=3)
   OR NOT EXISTS(SELECT 1 FROM cron.job j WHERE jobid=3
     AND j.xmin::text=(mod(pg_current_xact_id()::text::numeric,4294967296))::text)
   OR NOT EXISTS(SELECT 1 FROM pg_locks WHERE pid=pg_backend_pid()
     AND relation='cron.job'::regclass AND mode='RowExclusiveLock' AND granted) THEN
   RAISE EXCEPTION 'SUPPORTED_JOB3_ROW_LOCK_NOT_CONFIRMED'; END IF;
 v_at:=clock_timestamp();
 v_deadline:=v_at+interval '5 minutes';
 -- Change ONLY active. Preserve the entire existing command, including comments.
 PERFORM cron.alter_job(3,active := true);
 IF (v_before||jsonb_build_object('active',true)) IS DISTINCT FROM
       (SELECT to_jsonb(j) FROM cron.job j WHERE jobid=3)
   OR v_workers IS DISTINCT FROM (SELECT jsonb_agg(to_jsonb(j) ORDER BY jobid)
       FROM cron.job j WHERE jobid IN(1,2)) THEN
   RAISE EXCEPTION 'ACTIVATION_POSTCONDITION_FAILED'; END IF;
 PERFORM set_config('geolock.supervised_receipt',jsonb_build_object(
   'operator',v_operator,'project_confirmed','rcgyuwiidqvrgbxswhqj',
   'activation_statement_utc',v_at,'pause_deadline_utc',v_deadline,
   'pause_deadline_myt',to_char(v_deadline AT TIME ZONE 'Asia/Kuala_Lumpur','YYYY-MM-DD HH24:MI:SS.US'),
   'maximum_seconds',300,'previous_run_id',v_run_id,'previous_recovery_event_at',v_event_at,
   'command',v_before->>'command',
   'note','Pre-COMMIT receipt. Confirm COMMIT and active state separately. No automatic pause.')::text,true);
 IF clock_timestamp()>=v_deadline THEN RAISE EXCEPTION 'ACTIVATION_WINDOW_ELAPSED'; END IF;
END;
$supervised$;
SELECT current_setting('geolock.supervised_receipt')::jsonb AS activation_receipt;
COMMIT;
-- Save receipt AND confirm successful COMMIT. No post-COMMIT temporary cleanup.
-- Pause at first outcome/error or deadline, whichever comes first.
