-- V2 FINAL REVIEW ONLY. Not in supabase/migrations. Do not apply without approval.
-- C1 only: extend existing vehicles; no default capacities, no registration changes.
BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';
LOCK TABLE public.vehicles, public.pickup_routes IN ACCESS EXCLUSIVE MODE;
DO $preflight$
BEGIN
  IF current_user <> 'postgres' THEN RAISE EXCEPTION 'POSTGRES_OWNER_REQUIRED'; END IF;
  IF EXISTS(SELECT 1 FROM pg_catalog.pg_namespace WHERE nspname='fleet_private'
    AND (nspowner<>'postgres'::regrole OR coalesce(obj_description(oid,'pg_namespace'),'') NOT LIKE 'geolock-stage8-c1-v2:%'))
  THEN RAISE EXCEPTION 'UNREVIEWED_FLEET_SCHEMA'; END IF;
  IF EXISTS(SELECT 1 FROM pg_catalog.pg_namespace WHERE nspname='fleet_private') THEN
    IF to_regprocedure('fleet_private.installation_fingerprint()') IS NULL THEN
      RAISE EXCEPTION 'FLEET_SCHEMA_DRIFT'; END IF;
    IF (SELECT obj_description(oid,'pg_namespace') FROM pg_catalog.pg_namespace WHERE nspname='fleet_private')
      IS DISTINCT FROM 'geolock-stage8-c1-v2:'||fleet_private.installation_fingerprint()
    THEN RAISE EXCEPTION 'FLEET_SCHEMA_DRIFT'; END IF;
  END IF;
  IF NOT EXISTS(SELECT 1 FROM pg_catalog.pg_namespace WHERE nspname='fleet_private') AND EXISTS(
    SELECT 1 FROM pg_catalog.pg_proc WHERE pronamespace='public'::regnamespace
      AND proname IN ('register_my_vehicle','list_my_vehicles','update_my_vehicle',
        'set_my_vehicle_availability','deactivate_my_vehicle'))
  THEN RAISE EXCEPTION 'PUBLIC_FLEET_RPC_NAME_COLLISION'; END IF;
  IF NOT EXISTS(SELECT 1 FROM pg_catalog.pg_namespace WHERE nspname='fleet_private') AND (
    EXISTS(SELECT 1 FROM pg_catalog.pg_attribute WHERE attrelid='public.vehicles'::regclass AND NOT attisdropped
      AND attname IN ('vehicle_type','fixed_cost_rm','distance_cost_rm_per_km','max_route_duration_min',
        'available_for_planning','vehicle_version','updated_at','registration_request_id','registration_payload'))
    OR EXISTS(SELECT 1 FROM pg_catalog.pg_constraint WHERE conrelid='public.vehicles'::regclass
      AND conname IN ('vehicles_c1_fields','vehicles_c1_available_complete'))
    OR EXISTS(SELECT 1 FROM pg_catalog.pg_class WHERE relnamespace='public'::regnamespace
      AND relname IN ('vehicles_c1_registration_request','vehicles_c1_owner_active','pickup_routes_c1_vehicle_busy')))
  THEN RAISE EXCEPTION 'UNREVIEWED_PARTIAL_FLEET_INSTALL'; END IF;
  IF EXISTS (SELECT 1 FROM pg_catalog.pg_policies WHERE schemaname='public' AND tablename='vehicles')
  THEN RAISE EXCEPTION 'UNREVIEWED_VEHICLE_POLICIES'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_trigger
    WHERE tgrelid='public.vehicles'::regclass AND tgname='trg_vehicle_depot_node' AND NOT tgisinternal
      AND tgfoid='public.geolock_assign_vehicle_depot()'::regprocedure AND tgenabled='O')
  THEN RAISE EXCEPTION 'EXPECTED_DEPOT_TRIGGER_MISSING'; END IF;
  IF EXISTS(SELECT 1 FROM public.pickup_routes WHERE route_status IN ('DRAFT','VALIDATED','AUTHORISED','IN_PROGRESS'))
    AND NOT EXISTS(SELECT 1 FROM pg_catalog.pg_trigger WHERE tgrelid='public.vehicles'::regclass AND tgname='zz_c1_vehicle_guard')
  THEN RAISE EXCEPTION 'EXISTING_ACTIVE_ROUTES_REQUIRE_CUTOVER_REVIEW'; END IF;
  IF EXISTS(SELECT 1 FROM pg_catalog.pg_attribute a JOIN pg_catalog.pg_class c ON c.oid=a.attrelid
    JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE NOT a.attisdropped
    AND a.attname IN ('vehicle_id','reserved_vehicle_id') AND c.relkind IN ('r','p','v')
    AND n.nspname NOT IN ('pg_catalog','information_schema')
    AND NOT(n.nspname='public' AND c.relname IN ('vehicles','pickup_routes')))
  THEN RAISE EXCEPTION 'NEW_VEHICLE_DEPENDENCY_REQUIRES_REVIEW'; END IF;
END $preflight$;

CREATE SCHEMA IF NOT EXISTS fleet_private AUTHORIZATION postgres;
COMMENT ON SCHEMA fleet_private IS 'geolock-stage8-c1-v2';
REVOKE ALL ON SCHEMA fleet_private FROM PUBLIC, anon, authenticated, service_role;
-- Explicit ACLs on every function below also defeat existing public default grants.
ALTER TABLE public.vehicles
  ADD COLUMN IF NOT EXISTS vehicle_type text,
  ADD COLUMN IF NOT EXISTS fixed_cost_rm numeric,
  ADD COLUMN IF NOT EXISTS distance_cost_rm_per_km numeric,
  ADD COLUMN IF NOT EXISTS max_route_duration_min numeric,
  ADD COLUMN IF NOT EXISTS available_for_planning boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS vehicle_version bigint NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  ADD COLUMN IF NOT EXISTS registration_request_id uuid,
  ADD COLUMN IF NOT EXISTS registration_payload jsonb;
DO $column_shapes$
DECLARE r record; v_shape record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('vehicle_type','text',false),('fixed_cost_rm','numeric',false),
    ('distance_cost_rm_per_km','numeric',false),('max_route_duration_min','numeric',false),
    ('available_for_planning','boolean',true),('vehicle_version','bigint',true),
    ('updated_at','timestamp with time zone',true),('registration_request_id','uuid',false),
    ('registration_payload','jsonb',false)) AS expected(name,type_name,required)
  LOOP
    SELECT format_type(atttypid,atttypmod) AS type_name,attnotnull INTO v_shape
      FROM pg_catalog.pg_attribute WHERE attrelid='public.vehicles'::regclass AND attname=r.name AND NOT attisdropped;
    IF NOT FOUND OR v_shape.type_name IS DISTINCT FROM r.type_name OR v_shape.attnotnull IS DISTINCT FROM r.required
    THEN RAISE EXCEPTION 'FLEET_COLUMN_SHAPE_MISMATCH: %',r.name; END IF;
  END LOOP;
  IF (SELECT pg_get_expr(d.adbin,d.adrelid) FROM pg_catalog.pg_attrdef d
    JOIN pg_catalog.pg_attribute a ON a.attrelid=d.adrelid AND a.attnum=d.adnum
    WHERE a.attrelid='public.vehicles'::regclass AND a.attname='available_for_planning') IS DISTINCT FROM 'false'
  THEN RAISE EXCEPTION 'FLEET_AVAILABILITY_DEFAULT_MISMATCH'; END IF;
END $column_shapes$;
-- New operational fields are nullable for legacy rows. No guessed cost/type/duration.
DO $constraints$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint WHERE conrelid='public.vehicles'::regclass AND conname='vehicles_c1_fields') THEN
    ALTER TABLE public.vehicles ADD CONSTRAINT vehicles_c1_fields CHECK (
      (vehicle_type IS NULL OR (length(btrim(vehicle_type)) BETWEEN 1 AND 80))
      AND payload_capacity_kg NOT IN ('NaN'::numeric,'Infinity'::numeric,'-Infinity'::numeric)
      AND (fixed_cost_rm IS NULL OR (fixed_cost_rm >= 0 AND fixed_cost_rm < 'Infinity'::numeric AND scale(fixed_cost_rm)<=2))
      AND (distance_cost_rm_per_km IS NULL OR (distance_cost_rm_per_km>=0 AND distance_cost_rm_per_km<'Infinity'::numeric AND scale(distance_cost_rm_per_km)<=4))
      AND (max_route_duration_min IS NULL OR (max_route_duration_min>0 AND max_route_duration_min<'Infinity'::numeric AND scale(max_route_duration_min)<=3))
      AND vehicle_version>0);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint WHERE conrelid='public.vehicles'::regclass AND conname='vehicles_c1_available_complete') THEN
    ALTER TABLE public.vehicles ADD CONSTRAINT vehicles_c1_available_complete CHECK (
      NOT available_for_planning OR (active_flag AND vehicle_type IS NOT NULL
        AND fixed_cost_rm IS NOT NULL AND distance_cost_rm_per_km IS NOT NULL
        AND max_route_duration_min IS NOT NULL AND depot_road_node_id IS NOT NULL));
  END IF;
END $constraints$;
CREATE UNIQUE INDEX IF NOT EXISTS vehicles_c1_registration_request
  ON public.vehicles(ngo_user_id,registration_request_id) WHERE registration_request_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS vehicles_c1_owner_active ON public.vehicles(ngo_user_id,active_flag,vehicle_id);
CREATE INDEX IF NOT EXISTS pickup_routes_c1_vehicle_busy ON public.pickup_routes(vehicle_id)
  WHERE route_status IN ('DRAFT','VALIDATED','AUTHORISED','IN_PROGRESS');
ALTER TABLE public.vehicles ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.vehicles FROM PUBLIC,anon,authenticated;
DO $column_acl$
DECLARE v_columns text;
BEGIN
  SELECT string_agg(quote_ident(attname),', ' ORDER BY attnum) INTO v_columns
    FROM pg_catalog.pg_attribute WHERE attrelid='public.vehicles'::regclass AND attnum>0 AND NOT attisdropped;
  EXECUTE format('REVOKE SELECT (%1$s), INSERT (%1$s), UPDATE (%1$s), REFERENCES (%1$s) ON TABLE public.vehicles FROM PUBLIC,anon,authenticated,service_role',v_columns);
END $column_acl$;
REVOKE DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN ON TABLE public.vehicles FROM service_role;
GRANT SELECT,INSERT,UPDATE ON TABLE public.vehicles TO service_role;
-- TRUNCATE bypasses row triggers/RLS and could erase the route holds.
REVOKE TRUNCATE ON TABLE public.pickup_routes FROM PUBLIC,anon,authenticated,service_role;
-- NGO clients are RPC-only. Trusted service writes retain all row guards/audit.
-- BYPASSRLS does not bypass constraints or ordinary enabled row triggers.

CREATE OR REPLACE FUNCTION fleet_private.require_ngo() RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $f$
DECLARE v_actor uuid := auth.uid();
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;
  PERFORM 1 FROM public.ngo_profiles n JOIN public.user_profiles u ON u.user_id=n.user_id AND u.role=n.role
    WHERE n.user_id=v_actor AND n.active_flag AND n.role='NGO' FOR SHARE OF n,u;
  IF NOT FOUND THEN RAISE EXCEPTION 'ACTIVE_NGO_PROFILE_REQUIRED'; END IF;
  RETURN v_actor;
END $f$;

CREATE OR REPLACE FUNCTION fleet_private.road_node_key(p_node text) RETURNS bigint
LANGUAGE plpgsql IMMUTABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $f$
BEGIN
  RETURN p_node::bigint;
EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN RETURN NULL;
END $f$;

CREATE OR REPLACE FUNCTION fleet_private.require_depot(p_actor uuid) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $f$
DECLARE v_node text;
BEGIN
  SELECT n.road_node_id INTO v_node FROM public.ngo_profiles n
  WHERE n.user_id=p_actor AND n.active_flag AND n.location_verified_at IS NOT NULL
    AND EXISTS(SELECT 1 FROM public.road_network_nodes r JOIN public.road_network_coverage c
      ON c.network_snapshot_id=r.network_snapshot_id WHERE r.osm_node_id=fleet_private.road_node_key(n.road_node_id)
      AND r.active_flag AND c.active_flag AND c.dataset_kind='OPERATIONAL' AND c.approved_at IS NOT NULL);
  IF v_node IS NULL THEN RAISE EXCEPTION 'VERIFIED_OPERATIONAL_DEPOT_REQUIRED'; END IF;
  RETURN v_node;
END $f$;

CREATE OR REPLACE FUNCTION fleet_private.check_values(p_label text,p_type text,p_capacity numeric,
  p_fixed numeric,p_distance numeric,p_duration numeric) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $f$
BEGIN
  IF p_label IS NULL OR length(btrim(p_label)) NOT BETWEEN 1 AND 120
    OR p_type IS NULL OR length(btrim(p_type)) NOT BETWEEN 1 AND 80
    OR p_capacity IS NULL OR NOT(p_capacity>0 AND p_capacity<1000000000 AND p_capacity=round(p_capacity,3))
    OR p_fixed IS NULL OR NOT(p_fixed>=0 AND p_fixed<'Infinity'::numeric AND scale(p_fixed)<=2)
    OR p_distance IS NULL OR NOT(p_distance>=0 AND p_distance<'Infinity'::numeric AND scale(p_distance)<=4)
    OR p_duration IS NULL OR NOT(p_duration>0 AND p_duration<'Infinity'::numeric AND scale(p_duration)<=3)
  THEN RAISE EXCEPTION 'INVALID_VEHICLE_FIELDS'; END IF;
END $f$;

CREATE OR REPLACE FUNCTION fleet_private.vehicle_has_hold(p_vehicle uuid) RETURNS boolean
LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $f$
  SELECT EXISTS(SELECT 1 FROM public.pickup_routes r WHERE r.vehicle_id=p_vehicle
    AND (r.route_status IN ('DRAFT','VALIDATED','AUTHORISED','IN_PROGRESS')
      OR EXISTS(SELECT 1 FROM public.active_task_route_assignments a WHERE a.route_id=r.route_id)
      OR EXISTS(SELECT 1 FROM public.pickup_route_stops s JOIN public.pickup_tasks t ON t.task_id=s.task_id
        WHERE s.route_id=r.route_id AND t.task_status IN ('PLANNED','DISPATCHED'))));
$f$;

CREATE OR REPLACE FUNCTION fleet_private.vehicle_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $f$
BEGIN
  IF current_setting('transaction_isolation')<>'read committed' THEN
    RAISE EXCEPTION 'FLEET_REQUIRES_READ_COMMITTED'; END IF;
  IF TG_OP='DELETE' THEN RAISE EXCEPTION 'DEACTIVATE_VEHICLE_INSTEAD'; END IF;
  IF TG_OP='UPDATE' THEN
    IF NEW.vehicle_id IS DISTINCT FROM OLD.vehicle_id OR NEW.ngo_user_id IS DISTINCT FROM OLD.ngo_user_id
      OR NEW.registration_request_id IS DISTINCT FROM OLD.registration_request_id
      OR NEW.registration_payload IS DISTINCT FROM OLD.registration_payload
    THEN RAISE EXCEPTION 'IMMUTABLE_VEHICLE_IDENTITY'; END IF;
    IF NEW.vehicle_version IS DISTINCT FROM OLD.vehicle_version OR NEW.updated_at IS DISTINCT FROM OLD.updated_at
    THEN RAISE EXCEPTION 'VEHICLE_METADATA_MANAGED'; END IF;
    IF NOT OLD.active_flag AND NEW.active_flag THEN RAISE EXCEPTION 'VEHICLE_DEACTIVATED'; END IF;
    -- Preserve idle-vehicle location revocation: a cleared trusted depot disables
    -- planning. A bound nonterminal route still rejects this entire change below.
    IF NEW.depot_road_node_id IS NULL AND OLD.depot_road_node_id IS NOT NULL THEN
      NEW.available_for_planning:=false;
    END IF;
    IF ROW(NEW.vehicle_label,NEW.vehicle_type,NEW.payload_capacity_kg,NEW.fixed_cost_rm,NEW.distance_cost_rm_per_km,
      NEW.max_route_duration_min,NEW.depot_road_node_id,NEW.active_flag,NEW.available_for_planning)
      IS DISTINCT FROM ROW(OLD.vehicle_label,OLD.vehicle_type,OLD.payload_capacity_kg,OLD.fixed_cost_rm,OLD.distance_cost_rm_per_km,
      OLD.max_route_duration_min,OLD.depot_road_node_id,OLD.active_flag,OLD.available_for_planning)
      AND fleet_private.vehicle_has_hold(OLD.vehicle_id)
    THEN RAISE EXCEPTION 'VEHICLE_HAS_ACTIVE_ROUTE'; END IF;
    IF NEW IS NOT DISTINCT FROM OLD THEN RETURN OLD; END IF;
    NEW.vehicle_version:=OLD.vehicle_version+1;
  ELSE
    NEW.vehicle_version:=1;
  END IF;
  -- Existing depot trigger runs first alphabetically; never trusts a client node.
  IF NEW.available_for_planning THEN
    IF NEW.depot_road_node_id IS DISTINCT FROM fleet_private.require_depot(NEW.ngo_user_id)
    THEN RAISE EXCEPTION 'VEHICLE_DEPOT_STALE'; END IF;
    PERFORM fleet_private.check_values(NEW.vehicle_label,NEW.vehicle_type,NEW.payload_capacity_kg,
      NEW.fixed_cost_rm,NEW.distance_cost_rm_per_km,NEW.max_route_duration_min);
  END IF;
  NEW.updated_at:=clock_timestamp();
  RETURN NEW;
END $f$;
DROP TRIGGER IF EXISTS zz_c1_vehicle_guard ON public.vehicles;
CREATE TRIGGER zz_c1_vehicle_guard BEFORE INSERT OR UPDATE OR DELETE ON public.vehicles
  FOR EACH ROW EXECUTE FUNCTION fleet_private.vehicle_guard();

-- Fleet-only race guard on the EXISTING route table. No reservation/dispatch implementation.
CREATE OR REPLACE FUNCTION fleet_private.route_vehicle_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $f$
DECLARE v public.vehicles%rowtype;
BEGIN
  IF current_setting('transaction_isolation')<>'read committed' THEN RAISE EXCEPTION 'FLEET_REQUIRES_READ_COMMITTED'; END IF;
  IF TG_OP='DELETE' THEN
    IF OLD.route_status IN ('DRAFT','VALIDATED','AUTHORISED','IN_PROGRESS')
      OR EXISTS(SELECT 1 FROM public.active_task_route_assignments a WHERE a.route_id=OLD.route_id)
      OR EXISTS(SELECT 1 FROM public.pickup_route_stops s JOIN public.pickup_tasks t ON t.task_id=s.task_id
        WHERE s.route_id=OLD.route_id AND t.task_status IN ('PLANNED','DISPATCHED'))
    THEN RAISE EXCEPTION 'ACTIVE_ROUTE_DELETE_FORBIDDEN'; END IF;
    RETURN OLD;
  END IF;
  -- Lock vehicle even when leaving a protected state; fleet edits see committed release.
  IF TG_OP='UPDATE' AND ROW(NEW.vehicle_id,NEW.ngo_user_id) IS DISTINCT FROM ROW(OLD.vehicle_id,OLD.ngo_user_id)
  THEN RAISE EXCEPTION 'ROUTE_VEHICLE_BINDING_IMMUTABLE'; END IF;
  SELECT * INTO v FROM public.vehicles WHERE vehicle_id=NEW.vehicle_id FOR UPDATE;
  IF TG_OP='UPDATE' AND OLD.route_status IN ('COMPLETED','CANCELLED','STALE')
    AND NEW.route_status IS DISTINCT FROM OLD.route_status
  THEN RAISE EXCEPTION 'ROUTE_TERMINAL_STATE_IMMUTABLE'; END IF;
  IF NEW.route_status IN ('COMPLETED','CANCELLED','STALE') AND
    (TG_OP='INSERT' OR NEW.route_status IS DISTINCT FROM OLD.route_status) THEN
    IF EXISTS(SELECT 1 FROM public.active_task_route_assignments a WHERE a.route_id=NEW.route_id)
      OR EXISTS(SELECT 1 FROM public.pickup_route_stops s JOIN public.pickup_tasks t ON t.task_id=s.task_id
        WHERE s.route_id=NEW.route_id AND (t.task_status IN ('PLANNED','DISPATCHED')
          OR (NEW.route_status='COMPLETED' AND t.task_status<>'COLLECTED')))
    THEN RAISE EXCEPTION 'ROUTE_HAS_UNRESOLVED_ACTIVITY'; END IF;
  END IF;
  IF NEW.route_status IN ('DRAFT','VALIDATED','AUTHORISED','IN_PROGRESS') THEN
    IF v.vehicle_id IS NULL OR v.ngo_user_id IS DISTINCT FROM NEW.ngo_user_id
      OR NOT v.active_flag OR NOT v.available_for_planning
    THEN RAISE EXCEPTION 'VEHICLE_NOT_AVAILABLE'; END IF;
    IF v.depot_road_node_id IS DISTINCT FROM fleet_private.require_depot(v.ngo_user_id)
    THEN RAISE EXCEPTION 'VEHICLE_DEPOT_STALE'; END IF;
  END IF;
  RETURN NEW;
END $f$;
DROP TRIGGER IF EXISTS c1_route_vehicle_guard ON public.pickup_routes;
CREATE TRIGGER c1_route_vehicle_guard BEFORE INSERT OR UPDATE OR DELETE ON public.pickup_routes
  FOR EACH ROW EXECUTE FUNCTION fleet_private.route_vehicle_guard();

CREATE OR REPLACE FUNCTION fleet_private.audit_vehicle() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $f$
BEGIN
  IF TG_OP='UPDATE' AND NEW IS NOT DISTINCT FROM OLD THEN RETURN NEW; END IF;
  INSERT INTO public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,outcome,details)
  VALUES(auth.uid(),CASE WHEN auth.uid() IS NULL THEN 'SYSTEM'
    ELSE coalesce((SELECT role FROM public.user_profiles WHERE user_id=auth.uid()),'SYSTEM') END,'VEHICLE',NEW.vehicle_id,
    'FLEET_'||TG_OP,'SUCCESS',jsonb_build_object('owner',NEW.ngo_user_id,'version',NEW.vehicle_version,
      'before',CASE WHEN TG_OP='UPDATE' THEN to_jsonb(OLD)-'registration_payload' ELSE NULL END,
      'after',to_jsonb(NEW)-'registration_payload'));
  RETURN NEW;
END $f$;
DROP TRIGGER IF EXISTS c1_vehicle_audit ON public.vehicles;
CREATE TRIGGER c1_vehicle_audit AFTER INSERT OR UPDATE ON public.vehicles
  FOR EACH ROW EXECUTE FUNCTION fleet_private.audit_vehicle();

CREATE OR REPLACE FUNCTION public.register_my_vehicle(p_request_id uuid,p_label text,p_vehicle_type text,
 p_capacity_kg numeric,p_fixed_cost_rm numeric,p_distance_cost_rm_per_km numeric,p_max_route_duration_min numeric,
 p_available boolean DEFAULT false) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $f$
DECLARE v_actor uuid:=fleet_private.require_ngo(); v public.vehicles%rowtype; v_payload jsonb; v_node text;
BEGIN
  IF p_request_id IS NULL OR p_available IS NULL THEN RAISE EXCEPTION 'REQUEST_AND_AVAILABILITY_REQUIRED'; END IF;
  PERFORM fleet_private.check_values(p_label,p_vehicle_type,p_capacity_kg,p_fixed_cost_rm,p_distance_cost_rm_per_km,p_max_route_duration_min);
  v_payload:=jsonb_build_array(btrim(p_label),btrim(p_vehicle_type),p_capacity_kg,p_fixed_cost_rm,p_distance_cost_rm_per_km,p_max_route_duration_min,p_available);
  -- Serializes retries for this owner/request, without trusting an owner parameter.
  PERFORM pg_advisory_xact_lock(hashtextextended(v_actor::text||':'||p_request_id::text,0));
  SELECT * INTO v FROM public.vehicles WHERE ngo_user_id=v_actor AND registration_request_id=p_request_id;
  IF FOUND THEN
    IF v.registration_payload IS DISTINCT FROM v_payload THEN RAISE EXCEPTION 'REGISTRATION_REQUEST_CONFLICT'; END IF;
    RETURN to_jsonb(v)-'registration_payload';
  END IF;
  v_node:=fleet_private.require_depot(v_actor);
  INSERT INTO public.vehicles(ngo_user_id,vehicle_label,vehicle_type,payload_capacity_kg,fixed_cost_rm,
    distance_cost_rm_per_km,max_route_duration_min,depot_road_node_id,available_for_planning,registration_request_id,registration_payload)
  VALUES(v_actor,btrim(p_label),btrim(p_vehicle_type),p_capacity_kg,p_fixed_cost_rm,p_distance_cost_rm_per_km,
    p_max_route_duration_min,v_node,p_available,p_request_id,v_payload) RETURNING * INTO v;
  RETURN to_jsonb(v)-'registration_payload';
END $f$;

CREATE OR REPLACE FUNCTION public.list_my_vehicles() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $f$
DECLARE v_actor uuid:=fleet_private.require_ngo(); v_rows jsonb;
BEGIN
  SELECT coalesce(jsonb_agg((to_jsonb(v)-'registration_payload')||jsonb_build_object('eligible_for_planning',
    coalesce(v.active_flag AND v.available_for_planning AND n.location_verified_at IS NOT NULL
    AND v.depot_road_node_id=n.road_node_id AND EXISTS(SELECT 1 FROM public.road_network_nodes rn
      JOIN public.road_network_coverage c ON c.network_snapshot_id=rn.network_snapshot_id
      WHERE rn.osm_node_id=fleet_private.road_node_key(v.depot_road_node_id) AND rn.active_flag AND c.active_flag
      AND c.dataset_kind='OPERATIONAL' AND c.approved_at IS NOT NULL)
    AND NOT fleet_private.vehicle_has_hold(v.vehicle_id),false)) ORDER BY v.vehicle_id),'[]'::jsonb)
    INTO v_rows FROM public.vehicles v JOIN public.ngo_profiles n ON n.user_id=v.ngo_user_id WHERE v.ngo_user_id=v_actor;
  RETURN jsonb_build_object('vehicles',v_rows,'fleet_outcome',CASE WHEN EXISTS(
    SELECT 1 FROM jsonb_array_elements(v_rows) e WHERE (e->>'eligible_for_planning')::boolean)
    THEN 'AVAILABLE_VEHICLES' ELSE 'NO_FEASIBLE_PLAN' END,
    'reason',CASE WHEN jsonb_array_length(v_rows)=0 THEN 'NO_REGISTERED_VEHICLES' ELSE 'SEE_VEHICLE_ELIGIBILITY' END);
END $f$;

CREATE OR REPLACE FUNCTION public.update_my_vehicle(p_vehicle_id uuid,p_expected_version bigint,
 p_label text,p_vehicle_type text,p_capacity_kg numeric,p_fixed_cost_rm numeric,
 p_distance_cost_rm_per_km numeric,p_max_route_duration_min numeric) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $f$
DECLARE v_actor uuid:=fleet_private.require_ngo(); v public.vehicles%rowtype;
BEGIN
  SELECT * INTO v FROM public.vehicles WHERE vehicle_id=p_vehicle_id AND ngo_user_id=v_actor FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'VEHICLE_NOT_FOUND'; END IF;
  IF NOT v.active_flag THEN RAISE EXCEPTION 'VEHICLE_DEACTIVATED'; END IF;
  IF p_expected_version IS NULL OR v.vehicle_version<>p_expected_version THEN RAISE EXCEPTION 'VEHICLE_VERSION_CONFLICT'; END IF;
  PERFORM fleet_private.check_values(p_label,p_vehicle_type,p_capacity_kg,p_fixed_cost_rm,p_distance_cost_rm_per_km,p_max_route_duration_min);
  UPDATE public.vehicles SET vehicle_label=btrim(p_label),vehicle_type=btrim(p_vehicle_type),payload_capacity_kg=p_capacity_kg,
    fixed_cost_rm=p_fixed_cost_rm,distance_cost_rm_per_km=p_distance_cost_rm_per_km,max_route_duration_min=p_max_route_duration_min
    WHERE vehicle_id=v.vehicle_id RETURNING * INTO v;
  RETURN to_jsonb(v)-'registration_payload';
END $f$;

CREATE OR REPLACE FUNCTION public.set_my_vehicle_availability(p_vehicle_id uuid,p_expected_version bigint,p_available boolean) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $f$
DECLARE v_actor uuid:=fleet_private.require_ngo(); v public.vehicles%rowtype;
BEGIN
  SELECT * INTO v FROM public.vehicles WHERE vehicle_id=p_vehicle_id AND ngo_user_id=v_actor FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'VEHICLE_NOT_FOUND'; END IF;
  IF NOT v.active_flag THEN RAISE EXCEPTION 'VEHICLE_DEACTIVATED'; END IF;
  IF p_expected_version IS NULL OR v.vehicle_version<>p_expected_version THEN RAISE EXCEPTION 'VEHICLE_VERSION_CONFLICT'; END IF;
  IF p_available IS NULL THEN RAISE EXCEPTION 'AVAILABILITY_REQUIRED'; END IF;
  IF p_available THEN PERFORM fleet_private.require_depot(v_actor); END IF;
  UPDATE public.vehicles SET available_for_planning=p_available WHERE vehicle_id=v.vehicle_id RETURNING * INTO v;
  RETURN to_jsonb(v)-'registration_payload';
END $f$;

CREATE OR REPLACE FUNCTION public.deactivate_my_vehicle(p_vehicle_id uuid,p_expected_version bigint) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $f$
DECLARE v_actor uuid:=fleet_private.require_ngo(); v public.vehicles%rowtype;
BEGIN
  SELECT * INTO v FROM public.vehicles WHERE vehicle_id=p_vehicle_id AND ngo_user_id=v_actor FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'VEHICLE_NOT_FOUND'; END IF;
  IF p_expected_version IS NULL OR v.vehicle_version<>p_expected_version THEN RAISE EXCEPTION 'VEHICLE_VERSION_CONFLICT'; END IF;
  UPDATE public.vehicles SET active_flag=false,available_for_planning=false WHERE vehicle_id=v.vehicle_id RETURNING * INTO v;
  RETURN to_jsonb(v)-'registration_payload';
END $f$;

CREATE OR REPLACE FUNCTION fleet_private.installation_fingerprint() RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $f$
 SELECT md5(jsonb_build_object(
  'tables',(SELECT jsonb_agg(jsonb_build_array(c.relname,c.relowner,c.relrowsecurity,c.relforcerowsecurity) ORDER BY c.relname)
    FROM pg_class c WHERE c.oid IN ('public.vehicles'::regclass,'public.pickup_routes'::regclass)),
  'columns',(SELECT jsonb_agg(jsonb_build_array(a.attname,format_type(a.atttypid,a.atttypmod),a.attnotnull,
      pg_get_expr(d.adbin,d.adrelid)) ORDER BY a.attnum) FROM pg_attribute a LEFT JOIN pg_attrdef d
    ON d.adrelid=a.attrelid AND d.adnum=a.attnum WHERE a.attrelid='public.vehicles'::regclass AND a.attnum>0 AND NOT a.attisdropped),
  'constraints',(SELECT jsonb_agg(jsonb_build_array(conrelid::regclass::text,conname,pg_get_constraintdef(oid),convalidated) ORDER BY conrelid,conname)
    FROM pg_constraint WHERE conrelid IN ('public.vehicles'::regclass,'public.pickup_routes'::regclass)),
  'indexes',(SELECT jsonb_agg(jsonb_build_array(indexrelid::regclass::text,pg_get_indexdef(indexrelid),indisvalid) ORDER BY indexrelid)
    FROM pg_index WHERE indrelid IN ('public.vehicles'::regclass,'public.pickup_routes'::regclass)),
  'functions',(SELECT jsonb_agg(jsonb_build_array(p.oid::regprocedure::text,p.proowner,pg_get_functiondef(p.oid)) ORDER BY p.oid)
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE p.prokind='f' AND (n.nspname='fleet_private'
      OR (n.nspname='public' AND p.proname IN ('register_my_vehicle','list_my_vehicles','update_my_vehicle',
        'set_my_vehicle_availability','deactivate_my_vehicle','geolock_assign_vehicle_depot')))),
  'triggers',(SELECT jsonb_agg(jsonb_build_array(tgrelid::regclass::text,tgname,pg_get_triggerdef(oid),tgenabled) ORDER BY tgrelid,tgname)
    FROM pg_trigger WHERE tgrelid IN ('public.vehicles'::regclass,'public.pickup_routes'::regclass) AND NOT tgisinternal)
 )::text);
$f$;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA fleet_private FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.register_my_vehicle(uuid,text,text,numeric,numeric,numeric,numeric,boolean),
 public.list_my_vehicles(),public.update_my_vehicle(uuid,bigint,text,text,numeric,numeric,numeric,numeric),
 public.set_my_vehicle_availability(uuid,bigint,boolean),public.deactivate_my_vehicle(uuid,bigint)
 FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.register_my_vehicle(uuid,text,text,numeric,numeric,numeric,numeric,boolean),
 public.list_my_vehicles(),public.update_my_vehicle(uuid,bigint,text,text,numeric,numeric,numeric,numeric),
 public.set_my_vehicle_availability(uuid,bigint,boolean),public.deactivate_my_vehicle(uuid,bigint) TO authenticated;
DO $seal_installation$
BEGIN
  EXECUTE format('COMMENT ON SCHEMA fleet_private IS %L','geolock-stage8-c1-v2:'||fleet_private.installation_fingerprint());
END $seal_installation$;
COMMIT;
