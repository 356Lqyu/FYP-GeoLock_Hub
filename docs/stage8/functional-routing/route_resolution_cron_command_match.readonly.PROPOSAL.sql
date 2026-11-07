-- PROPOSAL ONLY: requires separate approval for ONE DEV read-only execution.
-- No recovery call is executed. The known command below is a TEXT comparison.
\set ON_ERROR_STOP on
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout='15s';
SET LOCAL lock_timeout='2s';
SET LOCAL search_path=pg_catalog,public,pg_temp;
SELECT jsonb_build_object('section','identity','observed_at',statement_timestamp(),
 'database',current_database(),'session_user',session_user,'current_user',current_user,
 'read_only',current_setting('transaction_read_only'),
 'ssl',(SELECT ssl FROM pg_stat_ssl WHERE pid=pg_backend_pid()));
SELECT 1/CASE WHEN current_database()='postgres' AND current_user='postgres' AND session_user='postgres'
 AND current_setting('transaction_read_only')='on'
 AND coalesce((SELECT ssl FROM pg_stat_ssl WHERE pid=pg_backend_pid()),false) THEN 1 ELSE 0 END AS identity_guard;
WITH expected(command) AS (VALUES ($known$set lock_timeout = '5s'; set statement_timeout = '50s'; select public.recover_expired_claims(1); -- STAGE3I_ONE_USE_8b4a48ed-97e4-41a9-aa1f-b588ae850b4f$known$)),
 observed AS (SELECT j.jobid,j.jobname,j.active,j.schedule,j.database,j.username,
  j.command=e.command AS exact_known_command_match
  FROM cron.job j CROSS JOIN expected e WHERE j.jobid=3)
SELECT jsonb_build_object('section','cron_known_command_match','job_count',(SELECT count(*) FROM observed),
 'job',(SELECT jsonb_build_object('jobid',jobid,'jobname',jobname,'active',active,'schedule',schedule,
  'database',database,'username',username,'exact_known_command_match',exact_known_command_match,
  'batch_limit',CASE WHEN exact_known_command_match THEN 1 END,
  'lock_timeout',CASE WHEN exact_known_command_match THEN '5s' END,
  'statement_timeout',CASE WHEN exact_known_command_match THEN '50s' END,
  'wrapper',CASE WHEN exact_known_command_match THEN 'NO_EXPLICIT_BEGIN_COMMIT' END,
  'trailing_comment_only',CASE WHEN exact_known_command_match THEN true END) FROM observed));
ROLLBACK;
