-- Stage 3G REVIEW ONLY. Requires explicit activation approval and a present operator.
-- DEV rcgyuwiidqvrgbxswhqj only; never the shared project.
-- Supervised 10-minute initial NOOP canary; pause at the end even if healthy.
-- Operator must save preflight output, observe every run and have pause SQL ready.
-- This transaction DOES activate job 3 if manually executed; do not run for review.
-- No automatic end time is installed. Never leave this canary unattended.
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='10s';
SET LOCAL search_path=pg_catalog,public,pg_temp;
DO $canary$
DECLARE v_eligibility_jobs jsonb;
BEGIN
  IF current_database()<>'postgres' OR current_user<>'postgres'
    OR session_user<>'postgres' OR auth.uid() IS NOT NULL THEN
    RAISE EXCEPTION 'CLEAN_POSTGRES_SESSION_REQUIRED';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM pg_proc p
    WHERE p.oid='public.recover_expired_claims(integer)'::regprocedure
      AND p.proowner='postgres'::regrole AND p.prosecdef
      AND p.proconfig=ARRAY['search_path=pg_catalog, public, extensions, pg_temp']
      AND p.proacl='{postgres=X/postgres,service_role=X/postgres}'::aclitem[]
      AND pg_get_function_arguments(p.oid)='p_limit integer DEFAULT 100'
      AND pg_get_function_result(p.oid)='integer'
      AND md5(replace(p.prosrc,E'\r\n',E'\n'))='5ff6d8719db9681aae6f444b89dfbaee') THEN
    RAISE EXCEPTION 'APPROVED_CASE_GUARD_DEPLOYMENT_REQUIRED';
  END IF;
  IF (SELECT count(*) FROM cron.job WHERE command ~* '\mrecover_expired_claims\M')<>1
    OR NOT EXISTS(SELECT 1 FROM cron.job WHERE jobid=3
      AND jobname='geolock-expired-claim-recovery' AND username='postgres'
      AND database=current_database() AND schedule='* * * * *' AND NOT active
      AND command='set lock_timeout = ''5s''; set statement_timeout = ''50s''; select public.recover_expired_claims(100);')
    OR EXISTS(SELECT 1 FROM cron.job_run_details WHERE jobid=3)
    OR (SELECT count(*) FROM cron.job WHERE jobid IN(1,2) AND active)<>2 THEN
    RAISE EXCEPTION 'CRON_BASELINE_CHANGED';
  END IF;
  IF EXISTS(SELECT 1 FROM public.donation_claims c JOIN public.claim_leases le USING(claim_id)
    WHERE c.claim_status='ACTIVE' AND le.lease_status='ACTIVE'
      AND le.expires_at<=clock_timestamp()) THEN
    RAISE EXCEPTION 'INITIAL_NOOP_CANARY_REQUIRES_EMPTY_BACKLOG';
  END IF;
  IF EXISTS(SELECT 1 FROM public.claim_reconciliation_cases
    WHERE case_status IN('OPEN','MANUAL_REVIEW')) THEN
    RAISE EXCEPTION 'INITIAL_CANARY_REQUIRES_NO_UNRESOLVED_CASES';
  END IF;
  IF EXISTS(SELECT 1 FROM public.donation_claims c
    LEFT JOIN public.claim_leases le USING(claim_id)
    LEFT JOIN public.pickup_tasks t USING(claim_id)
    LEFT JOIN public.listings l ON l.listing_id=c.listing_id
    WHERE c.claim_status IN('ACTIVE','RECONCILIATION_REQUIRED')
      AND (c.claim_status='RECONCILIATION_REQUIRED' OR le.lease_id IS NULL
        OR le.expires_at IS NULL OR t.task_id IS NULL OR l.listing_id IS NULL
        OR le.lease_status IS DISTINCT FROM c.claim_status
        OR l.listing_status IS DISTINCT FROM 'CLAIMED')) THEN
    RAISE EXCEPTION 'COORDINATION_REVIEW_REQUIRED';
  END IF;
  IF EXISTS(SELECT 1 FROM cron.job_run_details
      WHERE jobid IN(1,2,3) AND end_time IS NULL)
    OR EXISTS(SELECT 1 FROM cron.job_run_details
      WHERE jobid IN(1,2) AND start_time>=statement_timestamp()-interval '10 minutes'
        AND status<>'succeeded')
    OR (SELECT count(DISTINCT jobid) FROM cron.job_run_details
      WHERE jobid IN(1,2) AND status='succeeded'
        AND end_time>=statement_timestamp()-interval '3 minutes')<>2 THEN
    RAISE EXCEPTION 'RECENT_HEALTHY_ELIGIBILITY_WORKERS_REQUIRED';
  END IF;
  IF EXISTS(SELECT 1 FROM pg_stat_activity
    WHERE pid<>pg_backend_pid() AND backend_type='client backend'
      AND xact_start IS NOT NULL) THEN
    RAISE EXCEPTION 'CONCURRENT_TRANSACTION_REVIEW_REQUIRED';
  END IF;
  SELECT jsonb_agg(to_jsonb(j) ORDER BY jobid) INTO v_eligibility_jobs
    FROM cron.job j WHERE jobid IN(1,2);
  PERFORM cron.alter_job(3,schedule := '* * * * *',
    command := 'set lock_timeout = ''5s''; set statement_timeout = ''50s''; select public.recover_expired_claims(1);',
    active := true);
  IF (SELECT jsonb_agg(to_jsonb(j) ORDER BY jobid) FROM cron.job j WHERE jobid IN(1,2))
      IS DISTINCT FROM v_eligibility_jobs
    OR NOT EXISTS(SELECT 1 FROM cron.job WHERE jobid=3 AND active
      AND jobname='geolock-expired-claim-recovery' AND username='postgres'
      AND database=current_database() AND schedule='* * * * *'
      AND command='set lock_timeout = ''5s''; set statement_timeout = ''50s''; select public.recover_expired_claims(1);') THEN
    RAISE EXCEPTION 'CANARY_CRON_POSTCONDITION_FAILED';
  END IF;
END;
$canary$;
COMMIT;
-- Record COMMIT time and job-3 runid baseline. Watch every minute; pause by +10m.
-- No recovery RPC is executed by this transaction. Future scheduler runs mutate data.
