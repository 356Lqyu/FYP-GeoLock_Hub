"""Generate review-only v2 and exact diff; never connects to any database."""
from pathlib import Path
import difflib

HERE=Path(__file__).resolve().parent
original=(HERE/'proposed_migration.sql').read_text(encoding='utf-8')
sql=original.replace('-- REVIEW ONLY.', '-- V2 FINAL REVIEW ONLY.',1)

def change(old,new):
    global sql
    assert sql.count(old)==1,old
    sql=sql.replace(old,new,1)

change("  IF current_user <> 'postgres' THEN RAISE EXCEPTION 'POSTGRES_OWNER_REQUIRED'; END IF;", """  IF current_user <> 'postgres' THEN RAISE EXCEPTION 'POSTGRES_OWNER_REQUIRED'; END IF;
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
  THEN RAISE EXCEPTION 'PUBLIC_FLEET_RPC_NAME_COLLISION'; END IF;""")
change("  IF EXISTS (SELECT 1 FROM pg_catalog.pg_policies", """  IF NOT EXISTS(SELECT 1 FROM pg_catalog.pg_namespace WHERE nspname='fleet_private') AND (
    EXISTS(SELECT 1 FROM pg_catalog.pg_attribute WHERE attrelid='public.vehicles'::regclass AND NOT attisdropped
      AND attname IN ('vehicle_type','fixed_cost_rm','distance_cost_rm_per_km','max_route_duration_min',
        'available_for_planning','vehicle_version','updated_at','registration_request_id','registration_payload'))
    OR EXISTS(SELECT 1 FROM pg_catalog.pg_constraint WHERE conrelid='public.vehicles'::regclass
      AND conname IN ('vehicles_c1_fields','vehicles_c1_available_complete'))
    OR EXISTS(SELECT 1 FROM pg_catalog.pg_class WHERE relnamespace='public'::regnamespace
      AND relname IN ('vehicles_c1_registration_request','vehicles_c1_owner_active','pickup_routes_c1_vehicle_busy')))
  THEN RAISE EXCEPTION 'UNREVIEWED_PARTIAL_FLEET_INSTALL'; END IF;
  IF EXISTS (SELECT 1 FROM pg_catalog.pg_policies""")
change("WHERE tgrelid='public.vehicles'::regclass AND tgname='trg_vehicle_depot_node' AND NOT tgisinternal)",
       "WHERE tgrelid='public.vehicles'::regclass AND tgname='trg_vehicle_depot_node' AND NOT tgisinternal\n      AND tgfoid='public.geolock_assign_vehicle_depot()'::regprocedure AND tgenabled='O')")
change('CREATE SCHEMA IF NOT EXISTS fleet_private AUTHORIZATION postgres;',
       "CREATE SCHEMA IF NOT EXISTS fleet_private AUTHORIZATION postgres;\nCOMMENT ON SCHEMA fleet_private IS 'geolock-stage8-c1-v2';")
change('REVOKE ALL ON TABLE public.vehicles FROM PUBLIC,anon,authenticated,service_role;\n-- Intentionally no client table policies or SELECT grants: all access through RPCs.',
       """REVOKE ALL ON TABLE public.vehicles FROM PUBLIC,anon,authenticated;
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
-- BYPASSRLS does not bypass constraints or ordinary enabled row triggers.""")
change('CREATE OR REPLACE FUNCTION fleet_private.vehicle_guard() RETURNS trigger',"""CREATE OR REPLACE FUNCTION fleet_private.vehicle_has_hold(p_vehicle uuid) RETURNS boolean
LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $f$
  SELECT EXISTS(SELECT 1 FROM public.pickup_routes r WHERE r.vehicle_id=p_vehicle
    AND (r.route_status IN ('DRAFT','VALIDATED','AUTHORISED','IN_PROGRESS')
      OR EXISTS(SELECT 1 FROM public.active_task_route_assignments a WHERE a.route_id=r.route_id)
      OR EXISTS(SELECT 1 FROM public.pickup_route_stops s JOIN public.pickup_tasks t ON t.task_id=s.task_id
        WHERE s.route_id=r.route_id AND t.task_status IN ('PLANNED','DISPATCHED'))));
$f$;

CREATE OR REPLACE FUNCTION fleet_private.vehicle_guard() RETURNS trigger""")
change("AND EXISTS(SELECT 1 FROM public.pickup_routes r WHERE r.vehicle_id=OLD.vehicle_id\n        AND r.route_status IN ('DRAFT','VALIDATED','AUTHORISED','IN_PROGRESS'))",
       'AND fleet_private.vehicle_has_hold(OLD.vehicle_id)')
change("    IF NOT OLD.active_flag AND NEW.active_flag THEN RAISE EXCEPTION 'VEHICLE_DEACTIVATED'; END IF;", """    IF NEW.vehicle_version IS DISTINCT FROM OLD.vehicle_version OR NEW.updated_at IS DISTINCT FROM OLD.updated_at
    THEN RAISE EXCEPTION 'VEHICLE_METADATA_MANAGED'; END IF;
    IF NOT OLD.active_flag AND NEW.active_flag THEN RAISE EXCEPTION 'VEHICLE_DEACTIVATED'; END IF;""")
change("    IF OLD.route_status IN ('DRAFT','VALIDATED','AUTHORISED','IN_PROGRESS') THEN RAISE EXCEPTION 'ACTIVE_ROUTE_DELETE_FORBIDDEN'; END IF;",
       """    IF OLD.route_status IN ('DRAFT','VALIDATED','AUTHORISED','IN_PROGRESS')
      OR EXISTS(SELECT 1 FROM public.active_task_route_assignments a WHERE a.route_id=OLD.route_id)
      OR EXISTS(SELECT 1 FROM public.pickup_route_stops s JOIN public.pickup_tasks t ON t.task_id=s.task_id
        WHERE s.route_id=OLD.route_id AND t.task_status IN ('PLANNED','DISPATCHED'))
    THEN RAISE EXCEPTION 'ACTIVE_ROUTE_DELETE_FORBIDDEN'; END IF;""")
change("  SELECT * INTO v FROM public.vehicles WHERE vehicle_id=NEW.vehicle_id FOR UPDATE;\n  IF NEW.route_status", """  SELECT * INTO v FROM public.vehicles WHERE vehicle_id=NEW.vehicle_id FOR UPDATE;
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
  IF NEW.route_status""")
change("    AND NOT EXISTS(SELECT 1 FROM public.pickup_routes r WHERE r.vehicle_id=v.vehicle_id\n      AND r.route_status IN ('DRAFT','VALIDATED','AUTHORISED','IN_PROGRESS')),false))",
       '    AND NOT fleet_private.vehicle_has_hold(v.vehicle_id),false))')
change("  VALUES(auth.uid(),CASE WHEN auth.uid() IS NULL THEN 'SYSTEM' ELSE 'NGO' END,'VEHICLE',NEW.vehicle_id,",
       """  VALUES(auth.uid(),CASE WHEN auth.uid() IS NULL THEN 'SYSTEM'
    ELSE coalesce((SELECT role FROM public.user_profiles WHERE user_id=auth.uid()),'SYSTEM') END,'VEHICLE',NEW.vehicle_id,""")
# Strictly verify types/nullability/defaults on repeat execution, rather than
# allowing ADD COLUMN IF NOT EXISTS to hide partial/wrong prior installations.
change('-- New operational fields are nullable for legacy rows. No guessed cost/type/duration.', """DO $column_shapes$
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
-- New operational fields are nullable for legacy rows. No guessed cost/type/duration.""")
change('REVOKE ALL ON ALL FUNCTIONS IN SCHEMA fleet_private FROM PUBLIC,anon,authenticated,service_role;',"""CREATE OR REPLACE FUNCTION fleet_private.installation_fingerprint() RETURNS text
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
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA fleet_private FROM PUBLIC,anon,authenticated,service_role;""")
change('COMMIT;',"""DO $seal_installation$
BEGIN
  EXECUTE format('COMMENT ON SCHEMA fleet_private IS %L','geolock-stage8-c1-v2:'||fleet_private.installation_fingerprint());
END $seal_installation$;
COMMIT;""")
(HERE/'proposed_migration_v2.sql').write_text(sql,encoding='utf-8')
(HERE/'original-to-v2.diff').write_text(''.join(difflib.unified_diff(original.splitlines(True),sql.splitlines(True),
  fromfile='proposed_migration.sql (original, retained)',tofile='proposed_migration_v2.sql (review candidate)')),encoding='utf-8')
print('Generated review-only v2 SQL and exact diff; no database connection.')
