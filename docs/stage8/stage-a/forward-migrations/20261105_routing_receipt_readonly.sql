-- REVIEWED LOCAL PREPARATION ONLY. DEV rcgyuwiidqvrgbxswhqj; separate approval required.
-- One forward replacement; preserves owner/ACL. No application record changes.
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='10s';
DO $guard$
BEGIN
 IF session_user<>'postgres' OR current_user<>'postgres' OR current_database()<>'postgres' THEN RAISE EXCEPTION 'POSTGRES_INSTALLER_REQUIRED'; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_proc WHERE oid='public.get_my_routing_authorization_receipt(uuid)'::regprocedure
 AND md5(replace(prosrc,E'\r\n',E'\n'))='29161768ed763f7a2ac9b34c0fe0abe7' AND provolatile='s' AND prosecdef AND proowner='postgres'::regrole
 AND proconfig=ARRAY['search_path=pg_catalog, pg_temp','TimeZone=UTC']
 AND proacl='{postgres=X/postgres,authenticated=X/postgres}'::aclitem[]
 AND pg_get_function_result(oid)='jsonb' AND pg_get_function_arguments(oid)='p_request uuid')
 THEN RAISE EXCEPTION 'RECEIPT_SOURCE_OR_SECURITY_DRIFT'; END IF;
 IF (SELECT md5(replace(prosrc,E'\r\n',E'\n')) FROM pg_proc WHERE oid='fleet_private.require_ngo()'::regprocedure)<>'15d5c2547cabd5df199e104451f5c2d6'
 THEN RAISE EXCEPTION 'NGO_GUARD_DRIFT'; END IF;
END;
$guard$;
CREATE OR REPLACE FUNCTION public.get_my_routing_authorization_receipt(p_request uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,pg_temp SET timezone='UTC' AS $receipt$
DECLARE ngo uuid:=auth.uid(); prior routing_private.requests%rowtype;
BEGIN
 IF ngo IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;
 -- Same identity/role/active conditions; receipt reads take no writer row locks.
 IF NOT EXISTS(SELECT 1 FROM public.ngo_profiles n JOIN public.user_profiles u
   ON u.user_id=n.user_id AND u.role=n.role
   WHERE n.user_id=ngo AND n.active_flag AND n.role='NGO')
 THEN RAISE EXCEPTION 'ACTIVE_NGO_PROFILE_REQUIRED'; END IF;
 IF p_request IS NULL THEN RAISE EXCEPTION 'REQUEST_REQUIRED'; END IF;
 SELECT r.* INTO prior FROM routing_private.requests r
 WHERE r.ngo_id=ngo AND r.request_id=p_request AND r.operation='AUTHORIZE';
 IF NOT FOUND THEN RETURN jsonb_build_object('contract','geolock.routing-auto-now.v1',
   'ngo_id',ngo,'request_id',p_request,'outcome','NOT_FOUND'); END IF;
 RETURN jsonb_build_object('contract','geolock.routing-auto-now.v1','ngo_id',ngo,
   'request_id',p_request,'outcome','FOUND','result',prior.result);
END;
$receipt$;

DO $postflight$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM pg_proc WHERE oid='public.get_my_routing_authorization_receipt(uuid)'::regprocedure
 AND md5(replace(prosrc,E'\r\n',E'\n'))='71203f7bc55086683d60f3d0afabbe54' AND provolatile='s' AND prosecdef AND proowner='postgres'::regrole
 AND proconfig=ARRAY['search_path=pg_catalog, pg_temp','TimeZone=UTC']
 AND proacl='{postgres=X/postgres,authenticated=X/postgres}'::aclitem[])
 THEN RAISE EXCEPTION 'RECEIPT_POSTFLIGHT_FAILED'; END IF;
 IF (SELECT md5(replace(prosrc,E'\r\n',E'\n')) FROM pg_proc WHERE oid='fleet_private.require_ngo()'::regprocedure)<>'15d5c2547cabd5df199e104451f5c2d6'
 THEN RAISE EXCEPTION 'NGO_GUARD_CHANGED'; END IF;
END;
$postflight$;
COMMIT;
