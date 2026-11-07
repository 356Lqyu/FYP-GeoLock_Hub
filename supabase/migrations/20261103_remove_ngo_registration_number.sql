-- Remove the obsolete NGO registration/reference number from the deployed
-- profile API. This migration is forward-only; historical migrations remain
-- unchanged.
--
-- Apply only after the approved current-DEV backup procedure has completed.
-- The preflight also requires zero stored values while holding an exclusive
-- table lock. If a value appears after review, stop and back it up/review the
-- migration instead of deleting it.
BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';
SET LOCAL search_path = pg_catalog, public, extensions, pg_temp;

LOCK TABLE public.ngo_profiles IN ACCESS EXCLUSIVE MODE;

DO $ngo_registration_number_preflight$
DECLARE
  v_column smallint;
BEGIN
  IF current_user <> 'postgres' OR session_user <> 'postgres' THEN
    RAISE EXCEPTION 'POSTGRES_SESSION_REQUIRED';
  END IF;

  SELECT a.attnum INTO v_column
  FROM pg_attribute a
  WHERE a.attrelid = 'public.ngo_profiles'::regclass
    AND a.attname = 'registration_number'
    AND a.atttypid = 'text'::regtype
    AND NOT a.attisdropped;
  IF v_column IS NULL THEN RAISE EXCEPTION 'NGO_REGISTRATION_COLUMN_MISSING'; END IF;

  IF (SELECT count(*) FROM public.ngo_profiles WHERE registration_number IS NOT NULL) <> 0 THEN
    RAISE EXCEPTION 'NGO_REGISTRATION_VALUES_REQUIRE_APPROVED_BACKUP';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint c
    WHERE c.conrelid = 'public.ngo_profiles'::regclass
      AND c.conname = 'ngo_profiles_registration_number_key'
      AND c.contype = 'u'
      AND c.conkey = ARRAY[v_column]::smallint[]
  ) OR EXISTS (
    SELECT 1 FROM pg_constraint c
    WHERE c.conrelid = 'public.ngo_profiles'::regclass
      AND v_column = ANY(c.conkey)
      AND c.conname <> 'ngo_profiles_registration_number_key'
  ) THEN
    RAISE EXCEPTION 'NGO_REGISTRATION_CONSTRAINT_DRIFT';
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_index i
    WHERE i.indrelid = 'public.ngo_profiles'::regclass
      AND v_column = ANY(i.indkey)
      AND i.indexrelid <> (
        SELECT c.conindid FROM pg_constraint c
        WHERE c.conrelid = 'public.ngo_profiles'::regclass
          AND c.conname = 'ngo_profiles_registration_number_key'
      )
  ) THEN RAISE EXCEPTION 'NGO_REGISTRATION_INDEX_DRIFT'; END IF;

  IF EXISTS (
    SELECT 1 FROM pg_policies p
    WHERE p.schemaname = 'public'
      AND (p.tablename = 'ngo_profiles'
        OR coalesce(p.qual, '') ILIKE '%registration_number%'
        OR coalesce(p.with_check, '') ILIKE '%registration_number%')
      AND (coalesce(p.qual, '') ILIKE '%registration_number%'
        OR coalesce(p.with_check, '') ILIKE '%registration_number%')
  ) OR EXISTS (
    SELECT 1 FROM pg_views v
    WHERE v.schemaname = 'public'
      AND v.definition ILIKE '%registration_number%'
  ) OR EXISTS (
    SELECT 1 FROM pg_matviews v
    WHERE v.schemaname = 'public'
      AND v.definition ILIKE '%registration_number%'
  ) OR EXISTS (
    SELECT 1 FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE NOT t.tgisinternal
      AND n.nspname = 'public'
      AND pg_get_triggerdef(t.oid, true) ILIKE '%registration_number%'
  ) THEN RAISE EXCEPTION 'NGO_REGISTRATION_DEPENDENCY_DRIFT'; END IF;

  IF to_regprocedure('public.register_role_profile(text,text,text,text,text,text,double precision,double precision,text)') IS NULL
     OR to_regprocedure('public.register_role_profile(text,text,text,text,text,double precision,double precision,text)') IS NOT NULL
     OR to_regprocedure('public.update_my_profile(text,text,text,text)') IS NULL
     OR to_regprocedure('public.update_my_profile(text,text,text)') IS NOT NULL
     OR to_regprocedure('public.get_my_profile()') IS NULL THEN
    RAISE EXCEPTION 'NGO_PROFILE_RPC_SIGNATURE_DRIFT';
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'register_role_profile'
      AND p.oid <> to_regprocedure('public.register_role_profile(text,text,text,text,text,text,double precision,double precision,text)')
  ) OR EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'update_my_profile'
      AND p.oid <> to_regprocedure('public.update_my_profile(text,text,text,text)')
  ) THEN RAISE EXCEPTION 'NGO_PROFILE_RPC_OVERLOAD_DRIFT'; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p
    WHERE p.oid = to_regprocedure('public.register_role_profile(text,text,text,text,text,text,double precision,double precision,text)')
      AND p.proowner = 'postgres'::regrole
      AND p.prosecdef
      AND p.proconfig = ARRAY['search_path=pg_catalog, public, extensions, pg_temp']
      AND md5(replace(p.prosrc, E'\r\n', E'\n')) = '5d52973b4a89505335999dbc9303e3c0'
      AND has_function_privilege('authenticated', p.oid, 'EXECUTE')
      AND has_function_privilege('service_role', p.oid, 'EXECUTE')
      AND NOT has_function_privilege('anon', p.oid, 'EXECUTE')
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_proc p
    WHERE p.oid = to_regprocedure('public.update_my_profile(text,text,text,text)')
      AND p.proowner = 'postgres'::regrole
      AND p.prosecdef
      AND p.proconfig = ARRAY['search_path=pg_catalog, public, pg_temp']
      AND md5(replace(p.prosrc, E'\r\n', E'\n')) = '7aa35e78a13c036b734ed88483d9d10d'
      AND has_function_privilege('authenticated', p.oid, 'EXECUTE')
      AND has_function_privilege('service_role', p.oid, 'EXECUTE')
      AND NOT has_function_privilege('anon', p.oid, 'EXECUTE')
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_proc p
    WHERE p.oid = to_regprocedure('public.get_my_profile()')
      AND p.proowner = 'postgres'::regrole
      AND p.prosecdef
      AND p.provolatile = 's'
      AND p.proconfig = ARRAY['search_path=pg_catalog, public, pg_temp']
      AND md5(replace(p.prosrc, E'\r\n', E'\n')) = 'cb09e69315a568e0fec4e739e27d890e'
  ) THEN RAISE EXCEPTION 'NGO_PROFILE_RPC_SOURCE_OR_SECURITY_DRIFT'; END IF;

  IF EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE p.prosrc ILIKE '%registration_number%'
      AND NOT (n.nspname = 'public' AND p.oid IN (
        to_regprocedure('public.get_my_profile()'),
        to_regprocedure('public.register_role_profile(text,text,text,text,text,text,double precision,double precision,text)'),
        to_regprocedure('public.update_my_profile(text,text,text,text)')
      ))
  ) THEN RAISE EXCEPTION 'NGO_REGISTRATION_FUNCTION_REFERENCE_DRIFT'; END IF;
END;
$ngo_registration_number_preflight$;

DROP FUNCTION public.register_role_profile(
  text, text, text, text, text, text, double precision, double precision, text
);

CREATE FUNCTION public.register_role_profile(
  p_full_name text,
  p_role text,
  p_phone text DEFAULT NULL,
  p_ngo_name text DEFAULT NULL,
  p_operating_address text DEFAULT NULL,
  p_latitude double precision DEFAULT NULL,
  p_longitude double precision DEFAULT NULL,
  p_road_node_id text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, extensions, pg_temp
AS $function$
DECLARE
  v_user uuid := auth.uid();
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;
  IF p_role IS NULL OR p_role NOT IN ('DONOR','NGO','HUB_ADMIN') THEN
    RAISE EXCEPTION 'ROLE_NOT_SELF_SERVICE';
  END IF;
  IF nullif(btrim(p_full_name),'') IS NULL THEN RAISE EXCEPTION 'FULL_NAME_REQUIRED'; END IF;
  IF p_role='NGO' AND nullif(btrim(p_ngo_name),'') IS NULL THEN
    RAISE EXCEPTION 'NGO_NAME_REQUIRED';
  END IF;
  IF EXISTS(SELECT 1 FROM public.user_profiles u WHERE u.user_id=v_user) THEN
    RAISE EXCEPTION 'ROLE_ALREADY_REGISTERED';
  END IF;

  INSERT INTO public.user_profiles(user_id,full_name,phone_number,role)
  VALUES(v_user,btrim(p_full_name),nullif(btrim(p_phone),''),p_role);

  IF p_role='DONOR' THEN
    INSERT INTO public.donor_profiles(user_id) VALUES(v_user);
  ELSIF p_role='NGO' THEN
    -- As before, operating location is set after login through the protected
    -- set_ngo_operating_location RPC; legacy location arguments are ignored.
    INSERT INTO public.ngo_profiles(user_id,ngo_name)
    VALUES(v_user,btrim(p_ngo_name));
  ELSE
    INSERT INTO public.hub_admin_profiles(user_id) VALUES(v_user);
  END IF;

  INSERT INTO public.audit_events(
    actor_user_id,actor_role,entity_type,entity_id,event_type,
    requested_state,resulting_state,reason_code,outcome,details
  ) VALUES(
    v_user,p_role,'USER',v_user,'REGISTER_ROLE',p_role,p_role,
    CASE p_role WHEN 'NGO' THEN 'NGO_LOCATION_SETUP_REQUIRED'
                WHEN 'HUB_ADMIN' THEN 'HUB_SETUP_REQUIRED' END,
    'SUCCESS',jsonb_build_object('location_supplied_during_signup',false)
  );
  RETURN v_user;
END;
$function$;
REVOKE ALL ON FUNCTION public.register_role_profile(
  text, text, text, text, text, double precision, double precision, text
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.register_role_profile(
  text, text, text, text, text, double precision, double precision, text
) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.get_my_profile()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $function$
DECLARE
  v_user uuid := auth.uid();
  v_profile jsonb;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;

  SELECT jsonb_build_object(
    'user_id',u.user_id,
    'full_name',u.full_name,
    'phone_number',u.phone_number,
    'role',u.role,
    'created_at',u.created_at,
    'ngo_name',n.ngo_name,
    'operating_address',n.operating_address,
    'latitude',n.latitude,
    'longitude',n.longitude,
    'road_node_id',n.road_node_id,
    'location_verified_at',n.location_verified_at,
    'location_status',CASE
      WHEN u.role<>'NGO' THEN NULL
      WHEN n.user_id IS NULL OR n.location_verified_at IS NULL
        OR n.road_node_id IS NULL THEN 'SETUP_REQUIRED'
      ELSE 'VERIFIED'
    END,
    'ngo_location_setup_required',u.role='NGO' AND
      (n.user_id IS NULL OR n.location_verified_at IS NULL OR n.road_node_id IS NULL),
    'hub_admin',hadmin.user_id IS NOT NULL,
    'hub_id',hub.hub_id,
    'hub_name',hub.hub_name,
    'hub_address',hub.address_text,
    'hub_latitude',hub.latitude,
    'hub_longitude',hub.longitude,
    'hub_road_node_id',hub.road_node_id,
    'hub_capacity_kg',hub.capacity_kg,
    'hub_active',hub.active_flag,
    'hub_setup_required',u.role='HUB_ADMIN' AND
      (hub.hub_id IS NULL OR NOT hub.active_flag OR hub.road_node_id IS NULL),
    'onboarding_status',CASE
      WHEN u.role='DONOR' THEN 'COMPLETE'
      WHEN u.role='NGO' AND n.location_verified_at IS NOT NULL AND n.road_node_id IS NOT NULL THEN 'COMPLETE'
      WHEN u.role='NGO' THEN 'LOCATION_REQUIRED'
      WHEN u.role='HUB_ADMIN' AND hub.hub_id IS NOT NULL
        AND hub.active_flag AND hub.road_node_id IS NOT NULL THEN 'COMPLETE'
      ELSE 'HUB_REQUIRED'
    END
  ) INTO v_profile
  FROM public.user_profiles u
  LEFT JOIN public.ngo_profiles n ON n.user_id=u.user_id
  LEFT JOIN public.hub_admin_profiles hadmin ON hadmin.user_id=u.user_id
  LEFT JOIN LATERAL (
    SELECT h.hub_id,h.hub_name,h.address_text,h.latitude,h.longitude,
           h.road_node_id,h.capacity_kg,h.active_flag
    FROM public.community_hubs h
    WHERE h.admin_user_id=u.user_id
    ORDER BY h.active_flag DESC,h.created_at DESC,h.hub_id
    LIMIT 1
  ) hub ON true
  WHERE u.user_id=v_user;
  RETURN v_profile;
END;
$function$;

DROP FUNCTION public.update_my_profile(text,text,text,text);

CREATE FUNCTION public.update_my_profile(
  p_full_name text,
  p_phone text,
  p_ngo_name text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $function$
DECLARE
  v_user uuid := auth.uid();
  v_role text;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;
  IF nullif(btrim(p_full_name),'') IS NULL THEN RAISE EXCEPTION 'FULL_NAME_REQUIRED'; END IF;
  SELECT role INTO v_role FROM public.user_profiles WHERE user_id=v_user FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'PROFILE_NOT_FOUND'; END IF;

  UPDATE public.user_profiles
  SET full_name=btrim(p_full_name),phone_number=nullif(btrim(p_phone),'')
  WHERE user_id=v_user;

  IF v_role='NGO' THEN
    IF nullif(btrim(p_ngo_name),'') IS NULL THEN RAISE EXCEPTION 'NGO_NAME_REQUIRED'; END IF;
    UPDATE public.ngo_profiles SET ngo_name=btrim(p_ngo_name) WHERE user_id=v_user;
  END IF;

  INSERT INTO public.audit_events(actor_user_id,actor_role,entity_type,entity_id,
    event_type,request_id,requested_state,resulting_state,outcome)
  VALUES(v_user,v_role,'USER',v_user,'UPDATE_PROFILE',gen_random_uuid(),v_role,v_role,'SUCCESS');
  RETURN jsonb_build_object('user_id',v_user,'role',v_role,'updated',true);
END;
$function$;
REVOKE ALL ON FUNCTION public.update_my_profile(text,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.update_my_profile(text,text,text) TO authenticated, service_role;

ALTER TABLE public.ngo_profiles
  DROP CONSTRAINT ngo_profiles_registration_number_key;
ALTER TABLE public.ngo_profiles
  DROP COLUMN registration_number RESTRICT;

COMMIT;
