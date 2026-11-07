-- Read-only DEV capture: exact deployed listing trigger functions.
-- ISOLATED FIXTURE ONLY. Their road-node resolver is explicitly stubbed in tests.
CREATE OR REPLACE FUNCTION public.geolock_listing_eligibility_trigger()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
declare v_snapshot text;
begin
  if tg_op='UPDATE' then
    if new.eligibility_generation=old.eligibility_generation then return null; end if;
  end if;
  delete from public.ngo_listing_road_eligibility where listing_id=new.listing_id;
  -- Do not lock old queue rows here: workers lock queue before listing, while
  -- this trigger already holds listing. Workers supersede old generations.
  if new.listing_status='AVAILABLE' then
    select c.network_snapshot_id into v_snapshot from public.road_network_coverage c
     where c.active_flag and c.dataset_kind='OPERATIONAL' and c.approved_at is not null
       and c.max_snap_distance_m=500 for share;
    if v_snapshot is null then raise exception 'OPERATIONAL_ROAD_COVERAGE_UNAVAILABLE'; end if;
    insert into public.listing_eligibility_refresh_jobs(
      listing_id,eligibility_generation,expected_road_node_id,expected_snapshot_id)
    values(new.listing_id,new.eligibility_generation,new.pickup_road_node_id,v_snapshot);
  end if;
  return null;
end;
$function$;

CREATE OR REPLACE FUNCTION public.geolock_prepare_listing_eligibility()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'extensions', 'pg_temp'
AS $function$
declare v_snapshot text; v_node text; v_distance double precision; v_resolved text;
  v_refresh boolean;
begin
  if tg_op='INSERT' then
    new.eligibility_generation:=1;
    v_refresh:=true;
  else
    v_refresh:=new.pickup_latitude is distinct from old.pickup_latitude
      or new.pickup_longitude is distinct from old.pickup_longitude
      or new.pickup_road_node_id is distinct from old.pickup_road_node_id
      or (new.listing_status='AVAILABLE' and old.listing_status<>'AVAILABLE');
    new.eligibility_generation:=old.eligibility_generation;
    if v_refresh then new.eligibility_generation:=old.eligibility_generation+1; end if;
  end if;
  if v_refresh then
    select c.network_snapshot_id into v_snapshot from public.road_network_coverage c
     where c.active_flag and c.dataset_kind='OPERATIONAL' and c.approved_at is not null
       and c.max_snap_distance_m=500 for share;
    select r.node_id,r.snap_distance_m,r.snapshot_id into v_node,v_distance,v_resolved
      from public.geolock_resolve_road_node(new.pickup_latitude,new.pickup_longitude) r;
    if v_snapshot is null or v_node is null or v_distance is null or v_distance<0
       or v_distance>500 or v_resolved is distinct from v_snapshot then
      raise exception 'LISTING_LOCATION_NOT_ROUTABLE';
    end if;
    -- Always replace client-supplied road nodes, including UPDATE/republication.
    new.pickup_road_node_id:=v_node;
  end if;
  return new;
end;
$function$;
