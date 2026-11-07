-- Connection identity test only. No application tables, export, fixtures or writes.
\set ON_ERROR_STOP on
BEGIN READ ONLY;
SET LOCAL statement_timeout='10s';
SELECT jsonb_build_object(
 'observed_at',statement_timestamp(),'database',current_database(),
 'current_user',current_user,'session_user',session_user,
 'server_version',current_setting('server_version'),
 'read_only',current_setting('transaction_read_only'),
 'ssl',(SELECT ssl FROM pg_stat_ssl WHERE pid=pg_backend_pid()),
 'tls_version',(SELECT version FROM pg_stat_ssl WHERE pid=pg_backend_pid())) AS connection_evidence;
\conninfo
ROLLBACK;
