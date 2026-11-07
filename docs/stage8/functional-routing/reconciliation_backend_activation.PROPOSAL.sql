-- REVIEW ONLY. Separate bounded GLOBAL activation approval required.
-- Verify native resolver login/TLS/membership/mapping beforehand.
-- No report, evidence, provenance enrollment or finalization is performed here.
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='30s';
SET LOCAL search_path=pg_catalog,pg_temp;
DO $$ BEGIN
 IF current_database()<>'postgres' OR current_user<>'postgres' OR session_user<>'postgres'
 THEN RAISE EXCEPTION 'POSTGRES_DEV_INSTALLER_REQUIRED'; END IF;
 IF (SELECT enabled FROM resolution_private.config WHERE singleton) IS DISTINCT FROM false
 THEN RAISE EXCEPTION 'EXPECTED_DISABLED_CONFIG'; END IF;
 IF (SELECT md5(replace(prosrc,E'\r\n',E'\n')) FROM pg_proc WHERE oid=to_regprocedure('public.submit_route_resolution_evidence(uuid,uuid,text,bigint,uuid)'))
 IS DISTINCT FROM '7122f77ea8ed84d28bc08fbf77192d40'
 OR (SELECT md5(replace(prosrc,E'\r\n',E'\n')) FROM pg_proc WHERE oid=to_regprocedure('public.get_my_donation_route_resolution(uuid)'))
 IS DISTINCT FROM '22adbedf71a449f47fccc7cf73ff092f'
 THEN RAISE EXCEPTION 'RECONCILIATION_FUNCTION_DRIFT'; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='geolock_route_resolver'
 AND NOT rolcanlogin AND NOT rolsuper AND NOT rolcreatedb AND NOT rolcreaterole AND NOT rolbypassrls)
 THEN RAISE EXCEPTION 'SAFE_RESOLVER_GROUP_REQUIRED'; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='geolock_resolution_operator_login'
 AND rolcanlogin AND NOT rolinherit AND NOT rolsuper AND NOT rolcreatedb
 AND NOT rolcreaterole AND NOT rolbypassrls)
 OR NOT pg_has_role('geolock_resolution_operator_login','geolock_route_resolver','MEMBER')
 OR NOT EXISTS(SELECT 1 FROM resolution_private.operators
 WHERE login_name='geolock_resolution_operator_login' AND active)
 THEN RAISE EXCEPTION 'APPROVED_NATIVE_OPERATOR_REQUIRED'; END IF;
 IF EXISTS(SELECT 1 FROM resolution_private.cases)
 THEN RAISE EXCEPTION 'UNEXPECTED_EXISTING_RESOLUTION_CASE'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.pickup_routes r JOIN routing_private.bindings b USING(route_id)
 WHERE r.route_id='db1b455e-92d0-4d58-9fa1-5de07d7ab0f9'
 AND r.route_status='IN_PROGRESS' AND b.closed_at IS NULL)
 OR (SELECT count(*) FROM public.active_task_route_assignments
 WHERE route_id='db1b455e-92d0-4d58-9fa1-5de07d7ab0f9')<>3
 THEN RAISE EXCEPTION 'V2_PRESERVATION_MISMATCH'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.pickup_routes r JOIN routing_private.bindings b USING(route_id)
 WHERE r.route_id='7dd2d00a-ff03-4021-994f-155bbfc8e12c'
 AND r.route_status='COMPLETED' AND b.closed_at IS NOT NULL)
 OR EXISTS(SELECT 1 FROM public.active_task_route_assignments
 WHERE route_id='7dd2d00a-ff03-4021-994f-155bbfc8e12c')
 THEN RAISE EXCEPTION 'V3_PRESERVATION_MISMATCH'; END IF;
END $$;
UPDATE resolution_private.config SET enabled=true WHERE singleton RETURNING enabled;
COMMIT;
