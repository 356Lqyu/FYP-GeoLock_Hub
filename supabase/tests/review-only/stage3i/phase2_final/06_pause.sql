-- Stage 3I REVIEW ONLY. DEV rcgyuwiidqvrgbxswhqj only. Not executed.
-- REVIEW ONLY. Run only after explicit approval in DEV rcgyuwiidqvrgbxswhqj.
-- Pausing does not undo committed recoveries. Verify any in-flight run afterward.
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='10s';
DO $pause$
BEGIN
  IF current_user<>'postgres' OR session_user<>'postgres'
    OR NOT EXISTS(SELECT 1 FROM cron.job WHERE jobid=3
      AND jobname='geolock-expired-claim-recovery' AND username='postgres') THEN
    RAISE EXCEPTION 'VERIFIED_POSTGRES_RECOVERY_JOB_REQUIRED';
  END IF;
  PERFORM cron.alter_job(3,active := false);
  IF NOT EXISTS(SELECT 1 FROM cron.job WHERE jobid=3 AND NOT active) THEN
    RAISE EXCEPTION 'RECOVERY_CRON_PAUSE_FAILED';
  END IF;
END;
$pause$;
COMMIT;
-- Then inspect cron.job_run_details and pg_stat_activity using readiness SQL.
-- Any cancellation must target a separately verified live job-3 backend PID;
-- do not cancel jobs 1/2 or broad postgres sessions. No cancellation is included.
