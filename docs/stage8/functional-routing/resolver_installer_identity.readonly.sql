\set ON_ERROR_STOP on
BEGIN READ ONLY;
SET LOCAL statement_timeout='15s';
SET LOCAL lock_timeout='2s';
SELECT jsonb_build_object('section','installer_identity','database',current_database(),
 'current_user',current_user,'session_user',session_user,
 'read_only',current_setting('transaction_read_only'),
 'ssl',(SELECT ssl FROM pg_stat_ssl WHERE pid=pg_backend_pid()),
 'tls',(SELECT version FROM pg_stat_ssl WHERE pid=pg_backend_pid()));
SELECT current_database()='postgres' AND current_user='postgres' AND session_user='postgres'
 AND current_setting('transaction_read_only')='on'
 AND coalesce((SELECT ssl FROM pg_stat_ssl WHERE pid=pg_backend_pid()),false)
 AND coalesce(nullif(current_setting('supabase.project_ref',true),''),'rcgyuwiidqvrgbxswhqj')='rcgyuwiidqvrgbxswhqj'
 AS installer_identity_ok \gset
\if :installer_identity_ok
\else
ROLLBACK;
\quit 3
\endif
ROLLBACK;
