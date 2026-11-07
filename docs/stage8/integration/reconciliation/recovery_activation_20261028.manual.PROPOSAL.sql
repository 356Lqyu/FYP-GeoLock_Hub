-- WRITES. REVIEW ONLY. Separate explicit DEV manual-recovery approval required.
-- Select rcgyuwiidqvrgbxswhqj in Dashboard; SQL cannot prove the project from db name.
-- Run the COMPLETE transaction once as SQL Editor postgres. No automatic retry.
-- Limit 1 means oldest unlocked expired claim, NOT a claim-ID filter.
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='50s';
DO $guard$
BEGIN
 IF session_user<>'postgres' OR current_user<>'postgres' OR current_database()<>'postgres'
 THEN RAISE EXCEPTION 'APPROVED_DEV_POSTGRES_SESSION_REQUIRED'; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_proc WHERE oid='public.recover_expired_claims(integer)'::regprocedure
   AND md5(replace(prosrc,E'\r\n',E'\n'))='89e01f42d5ec23bfcbcdc47c1f4fd4e5'
   AND proowner='postgres'::regrole AND prosecdef
   AND proconfig=ARRAY['search_path=pg_catalog, public, extensions, pg_temp']
   AND proacl='{postgres=X/postgres,service_role=X/postgres}'::aclitem[])
 THEN RAISE EXCEPTION 'RECOVERY_SOURCE_OR_SECURITY_DRIFT'; END IF;
 IF (SELECT count(*) FROM cron.job WHERE command ILIKE '%recover_expired_claims%')<>1
 OR NOT EXISTS(SELECT 1 FROM cron.job WHERE jobid=3 AND jobname='geolock-expired-claim-recovery'
   AND NOT active AND username='postgres' AND database='postgres' AND schedule='* * * * *'
   AND command='set lock_timeout = ''5s''; set statement_timeout = ''50s''; select public.recover_expired_claims(1); -- STAGE3I_ONE_USE_8b4a48ed-97e4-41a9-aa1f-b588ae850b4f')
 OR EXISTS(SELECT 1 FROM cron.job_run_details WHERE jobid=3 AND end_time IS NULL)
 THEN RAISE EXCEPTION 'PAUSED_IDLE_REVIEWED_RECOVERY_JOB_REQUIRED'; END IF;
END;
$guard$;
SELECT public.recover_expired_claims(p_limit => 1) AS processed_claims;
COMMIT;
-- Immediately run recovery_activation_20261028.postflight.sql.
-- An exception: ROLLBACK; inspect, never repeat blindly.
-- A lost COMMIT response: reconcile committed claims/audits before another call.
