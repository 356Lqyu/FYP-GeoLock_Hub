-- REVIEW ONLY. Separate resolver-provisioning approval required. No password.
-- Proposed native login name requires operator approval before execution.
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='30s';
SET LOCAL search_path=pg_catalog,pg_temp;
DO $$ BEGIN
 IF current_database()<>'postgres' OR current_user<>'postgres' OR session_user<>'postgres'
 THEN RAISE EXCEPTION 'POSTGRES_DEV_INSTALLER_REQUIRED'; END IF;
 IF current_setting('transaction_read_only')<>'off' THEN RAISE EXCEPTION 'WRITE_TRANSACTION_REQUIRED'; END IF;
 IF (SELECT enabled FROM resolution_private.config WHERE singleton) IS DISTINCT FROM false
 THEN RAISE EXCEPTION 'DISABLED_CONFIG_REQUIRED'; END IF;
 IF (SELECT md5(replace(prosrc,E'\r\n',E'\n')) FROM pg_proc WHERE oid=to_regprocedure('public.submit_route_resolution_evidence(uuid,uuid,text,bigint,uuid)'))
 IS DISTINCT FROM '7122f77ea8ed84d28bc08fbf77192d40' THEN RAISE EXCEPTION 'WRITER_FINGERPRINT_MISMATCH'; END IF;
 IF (SELECT md5(replace(prosrc,E'\r\n',E'\n')) FROM pg_proc WHERE oid=to_regprocedure('public.get_my_donation_route_resolution(uuid)'))
 IS DISTINCT FROM '22adbedf71a449f47fccc7cf73ff092f' THEN RAISE EXCEPTION 'READER_FINGERPRINT_MISMATCH'; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='geolock_route_resolver'
 AND NOT rolcanlogin AND NOT rolsuper AND NOT rolcreatedb AND NOT rolcreaterole AND NOT rolbypassrls)
 THEN RAISE EXCEPTION 'SAFE_RESOLVER_GROUP_REQUIRED'; END IF;
 IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='geolock_resolution_operator_login')
 OR EXISTS(SELECT 1 FROM resolution_private.operators)
 THEN RAISE EXCEPTION 'EXISTING_OPERATOR_STATE_REQUIRES_REVIEW'; END IF;
END $$;

-- NULL password: no usable password credential until native \password is approved.
CREATE ROLE geolock_resolution_operator_login LOGIN NOINHERIT NOSUPERUSER
 NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 1 PASSWORD NULL;
GRANT CONNECT ON DATABASE postgres TO geolock_resolution_operator_login;
GRANT geolock_route_resolver TO geolock_resolution_operator_login
 WITH INHERIT FALSE, SET TRUE;
ALTER ROLE geolock_resolution_operator_login SET search_path=pg_catalog;
ALTER ROLE geolock_resolution_operator_login SET default_transaction_read_only=on;
ALTER ROLE geolock_resolution_operator_login SET statement_timeout='30s';
ALTER ROLE geolock_resolution_operator_login SET lock_timeout='5s';
INSERT INTO resolution_private.operators(login_name,operator_label,active)
 VALUES('geolock_resolution_operator_login','GeoLock DEV resolution operator - project owner',true);

DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM pg_roles r WHERE r.rolname IN
 ('authenticated','anon','service_role','authenticator','geolock_graph_worker','geolock_planner','geolock_validator')
 AND pg_has_role(r.oid,'geolock_route_resolver','MEMBER'))
 THEN RAISE EXCEPTION 'API_RESOLVER_MEMBERSHIP_FORBIDDEN'; END IF;
 IF has_schema_privilege('geolock_resolution_operator_login','public','CREATE')
 OR has_table_privilege('geolock_resolution_operator_login','resolution_private.operators','INSERT,UPDATE,DELETE')
 OR has_table_privilege('geolock_route_resolver','resolution_private.operators','INSERT,UPDATE,DELETE')
 THEN RAISE EXCEPTION 'UNEXPECTED_DIRECT_AUTHORITY'; END IF;
 IF (SELECT enabled FROM resolution_private.config WHERE singleton) IS DISTINCT FROM false
 THEN RAISE EXCEPTION 'FEATURE_MUST_REMAIN_DISABLED'; END IF;
END $$;
COMMIT;
