-- REVIEW ONLY. NOT APPROVED, NOT DEPLOYED; no historical migration edits.
-- DEV rcgyuwiidqvrgbxswhqj. Requires local READ ONLY regression tests, pinned
-- source/ACL guards and separate approval before conversion into a migration.
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='10s';
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
-- Retains owner/ACL through CREATE OR REPLACE; a guarded deployment package
-- must verify postgres owner and postgres/authenticated-only EXECUTE unchanged.
-- fleet_private.require_ngo() and every authorization/pickup writer stay unchanged.
COMMIT;
