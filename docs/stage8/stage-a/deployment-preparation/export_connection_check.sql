-- Operator-run connection check only. DEV rcgyuwiidqvrgbxswhqj.
-- Run through the supplied session-pooler profile with verify-full TLS.
-- No application function invocation, credentials, grants, or database writes.
BEGIN READ ONLY;
SET LOCAL statement_timeout='30s';

SELECT current_database() AS database_name,current_user,session_user,
       current_setting('server_version') AS server_version,
       current_setting('transaction_read_only') AS read_only,
       clock_timestamp() AS observed_at;

-- This observes the server-side connection leg. Client-to-pooler certificate
-- verification is enforced by libpq's verified service profile, not this view.
SELECT ssl,version AS tls_version,cipher
FROM pg_stat_ssl WHERE pid=pg_backend_pid();

SELECT rolname,rolsuper,rolbypassrls
FROM pg_roles WHERE rolname=current_user;

-- Zero inaccessible relations/sequences is required for complete scope.
-- No table records or secrets are returned.
WITH inspected AS (
 SELECT c.*,n.nspname,r.rolsuper,r.rolbypassrls
 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
 CROSS JOIN pg_roles r
 WHERE r.rolname=current_user AND c.relkind IN ('r','p','m','S')
 AND n.nspname NOT IN ('pg_catalog','information_schema')
 AND n.nspname NOT LIKE 'pg_toast%' AND n.nspname NOT LIKE 'pg_temp%'
)
SELECT nspname AS schema_name,count(*) AS relation_count,
 count(*) FILTER (WHERE CASE WHEN relkind='S' THEN false ELSE NOT has_table_privilege(current_user,oid,'SELECT') END) AS tables_without_select,
 count(*) FILTER (WHERE CASE WHEN relkind='S' THEN NOT has_sequence_privilege(current_user,oid,'SELECT') ELSE false END) AS sequences_without_select,
 count(*) FILTER (WHERE relrowsecurity AND NOT (rolsuper OR rolbypassrls
   OR (pg_has_role(current_user,relowner,'USAGE') AND NOT relforcerowsecurity))) AS rls_requires_review
FROM inspected GROUP BY nspname ORDER BY nspname;

-- Catalog privileges are evidence, not proof pg_dump/pg_dumpall will succeed.
SELECT has_table_privilege(current_user,'pg_catalog.pg_roles','SELECT') AS can_read_roles,
       has_table_privilege(current_user,'pg_catalog.pg_auth_members','SELECT') AS can_read_memberships,
       (SELECT count(*) FROM pg_largeobject_metadata) AS large_object_count;
ROLLBACK;
