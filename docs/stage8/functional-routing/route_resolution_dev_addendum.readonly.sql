-- Operator-run DEV preflight ONLY. No application RPC, DDL, DML or recovery call.
\set ON_ERROR_STOP on
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout='15s';
SET LOCAL lock_timeout='2s';
SET LOCAL search_path=pg_catalog,public,pg_temp;
SELECT jsonb_build_object('section','identity','observed_at',statement_timestamp(),
 'database',current_database(),'current_user',current_user,'session_user',session_user,
 'server_version',current_setting('server_version'),'read_only',current_setting('transaction_read_only'),
 'default_read_only',current_setting('default_transaction_read_only'),
 'ssl',(SELECT ssl FROM pg_stat_ssl WHERE pid=pg_backend_pid()),
 'tls',(SELECT version FROM pg_stat_ssl WHERE pid=pg_backend_pid()),
 'server_project_setting',current_setting('supabase.project_ref',true));
-- Client runner separately pins the TLS-verified DEV pooler/project-bearing user.
-- Check this explicit transaction's access mode, not the default for future ones.
-- default_read_only stays diagnostic; no new transaction opens before ROLLBACK.
SELECT 1/CASE WHEN current_database()='postgres' AND current_user='postgres' AND session_user='postgres'
 AND current_setting('transaction_read_only')='on'
 AND coalesce((SELECT ssl FROM pg_stat_ssl WHERE pid=pg_backend_pid()),false) THEN 1 ELSE 0 END AS identity_guard;

SELECT jsonb_build_object('section','timezone_values','functions',(
 SELECT coalesce(jsonb_agg(jsonb_build_object('signature',p.oid::regprocedure::text,'setting',setting) ORDER BY p.oid::regprocedure::text),'[]')
 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace CROSS JOIN LATERAL unnest(p.proconfig) setting
 WHERE n.nspname IN('public','routing_private','fleet_private') AND lower(split_part(setting,'=',1))='timezone'));
-- Whitelist disclosure, not execution. Accept only SET timeout(s) + recovery SELECT,
-- optionally in a balanced BEGIN/COMMIT wrapper; do not expose unknown command text.
WITH patterns AS (SELECT
 $pattern$\s*(set\s+(local\s+)?(lock_timeout|statement_timeout)\s*(=|to)\s*'[0-9]+(ms|s|min)'\s*;\s*)*select\s+public\.recover_expired_claims\s*\(\s*[0-9]*\s*\)\s*;?\s*$pattern$::text AS body),
 jobs AS (SELECT j.*, (j.command~*('^'||p.body||'$') OR j.command~*('^\s*begin\s*;'||p.body||'commit\s*;?\s*$')) AS supported
 FROM cron.job j CROSS JOIN patterns p WHERE j.jobid=3 OR j.jobname='geolock-expired-claim-recovery' ORDER BY jobid LIMIT 3)
SELECT jsonb_build_object('section','recovery_command_addendum','function_default_argument',(SELECT pg_get_expr(proargdefaults,0) FROM pg_proc WHERE oid='public.recover_expired_claims(integer)'::regprocedure),
 'jobs',(SELECT coalesce(jsonb_agg(jsonb_build_object('jobid',jobid,'jobname',jobname,'active',active,'schedule',schedule,'database',database,'username',username,
 'command_supported',supported,'command',CASE WHEN supported THEN command ELSE 'REDACTED_UNRECOGNIZED_COMMAND_REVIEW_REQUIRED' END,
 'requested_limit',CASE WHEN supported THEN (regexp_match(command,'(?i)recover_expired_claims\s*\(\s*([0-9]*)\s*\)'))[1] END,
 'lock_timeout',CASE WHEN supported THEN (regexp_match(command,$rx$(?i)lock_timeout\s*(=|to)\s*'([0-9]+(ms|s|min))'$rx$))[2] END,
 'statement_timeout',CASE WHEN supported THEN (regexp_match(command,$rx$(?i)statement_timeout\s*(=|to)\s*'([0-9]+(ms|s|min))'$rx$))[2] END,
 'wrapper',CASE WHEN NOT supported THEN 'UNKNOWN' WHEN command~*'^\s*begin\s*;' THEN 'BEGIN_COMMIT' ELSE 'NO_EXPLICIT_WRAPPER' END) ORDER BY jobid),'[]') FROM jobs));
ROLLBACK;
