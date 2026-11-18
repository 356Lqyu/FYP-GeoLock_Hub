
-- REVIEW ONLY. Apply solely in a disposable fixture until separately approved.
-- The 1.02 bound is certified only for this immutable DEV graph. A read-only
-- edge scan must be repeated before any deployment. See the companion review.
BEGIN;

DO $check$
BEGIN
  IF EXISTS (
    SELECT 1 FROM (VALUES
      ('public.geolock_refresh_listing_road_eligibility(uuid,uuid)', '87630057b08e63ebae1308079be4e219'),
      ('public.geolock_refresh_ngo_road_eligibility(uuid)', '6542d9f3523a847628ea9967af6f5597'),
      ('public.geolock_road_eligible_km(uuid,uuid)', 'e8b0b68574b762ecc6eb4fc07974d735'),
      ('public.geolock_ngo_listing_road_check(uuid,uuid)', '93a7a7e6ae29713d182cee184fa52842'),
      ('public.geolock_road_costs(bigint[],bigint[],double precision,double precision,double precision)',
       '828217e0b8faeeb3d32fa726b3e06a2a')
    ) v(signature, expected_hash)
    LEFT JOIN pg_catalog.pg_proc p ON p.oid = pg_catalog.to_regprocedure(v.signature)
    WHERE md5(replace(p.prosrc, chr(13), '')) IS DISTINCT FROM v.expected_hash
  ) THEN
    RAISE EXCEPTION 'ELIGIBILITY_BASELINE_DRIFT';
  END IF;

  -- Legacy negative rows may be false negatives; do not put the new readers
  -- over them or delete them implicitly. The observed DEV cache has only positives.
  IF EXISTS (SELECT 1 FROM public.ngo_listing_road_eligibility WHERE outcome <> 'ELIGIBLE') THEN
    RAISE EXCEPTION 'LEGACY_NEGATIVE_ELIGIBILITY_REQUIRES_REVIEW';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.road_network_coverage c
    JOIN routing_private.graphs g ON g.coverage_snapshot = c.network_snapshot_id
    WHERE c.active_flag AND c.approved_at IS NOT NULL AND c.dataset_kind = 'OPERATIONAL'
      AND c.network_snapshot_id = 'OSM-OPS-20261018'
      AND g.graph_id = 'eab1f7ee-a8e0-4bed-a0e1-2c4bff024936'::uuid
      AND g.content_digest = '5e06dab0fb4d2b97ac53fd9a1178dc46aa6b98811aefbaef96528c604a04012a'
      AND (c.node_count,c.edge_count,g.node_count,g.edge_count) = (926414,2145828,926414,2145828)
  ) THEN
    RAISE EXCEPTION 'ELIGIBILITY_GRAPH_CERTIFICATE_MISMATCH';
  END IF;
END
$check$;

CREATE FUNCTION routing_private.claim_eligibility_search_radius(p_snapshot text, p_radius integer)
RETURNS double precision
LANGUAGE sql STABLE
SET search_path TO 'pg_catalog', 'pg_temp'
AS $function$
  SELECT p_radius::double precision * 1.02
  WHERE p_radius = 20000 AND p_snapshot = 'OSM-OPS-20261018'
    AND EXISTS (
      SELECT 1 FROM routing_private.graphs g
      WHERE g.coverage_snapshot = p_snapshot
        AND g.graph_id = 'eab1f7ee-a8e0-4bed-a0e1-2c4bff024936'::uuid
        AND g.content_digest = '5e06dab0fb4d2b97ac53fd9a1178dc46aa6b98811aefbaef96528c604a04012a'
        AND (g.node_count,g.edge_count) = (926414,2145828)
    )
$function$;

CREATE FUNCTION routing_private.claim_eligibility_costs(
  p_sources bigint[], p_targets bigint[], p_anchor bigint, p_snapshot text, p_radius integer)
RETURNS TABLE (source_node bigint, target_node bigint, road_km double precision, outcome text)
LANGUAGE sql VOLATILE
SET search_path TO 'pg_catalog', 'extensions', 'pg_temp'
AS $function$
  WITH anchor AS MATERIALIZED (
    SELECT n.geog, n.latitude, n.longitude,
           routing_private.claim_eligibility_search_radius(p_snapshot, p_radius) AS search_m
    FROM public.road_network_nodes n
    WHERE n.osm_node_id = p_anchor AND n.active_flag AND n.network_snapshot_id = p_snapshot
      AND p_snapshot = public.geolock_active_road_snapshot()
      AND (p_sources = ARRAY[p_anchor] OR p_targets = ARRAY[p_anchor])
  ), sources AS MATERIALIZED (
    SELECT DISTINCT n.osm_node_id, n.component_id, extensions.ST_DWithin(n.geog, a.geog, a.search_m) AS nearby
    FROM unnest(p_sources) AS x(id)
    JOIN public.road_network_nodes n ON n.osm_node_id = x.id
    CROSS JOIN anchor a
    WHERE a.search_m IS NOT NULL AND n.active_flag AND n.network_snapshot_id = p_snapshot
  ), targets AS MATERIALIZED (
    SELECT DISTINCT n.osm_node_id, n.component_id, extensions.ST_DWithin(n.geog, a.geog, a.search_m) AS nearby
    FROM unnest(p_targets) AS x(id)
    JOIN public.road_network_nodes n ON n.osm_node_id = x.id
    CROSS JOIN anchor a
    WHERE a.search_m IS NOT NULL AND n.active_flag AND n.network_snapshot_id = p_snapshot
  ), costs AS MATERIALIZED (
    SELECT c.*
    FROM anchor a
    CROSS JOIN LATERAL public.geolock_road_costs(
      ARRAY(SELECT s.osm_node_id FROM sources s WHERE s.nearby),
      ARRAY(SELECT t.osm_node_id FROM targets t WHERE t.nearby),
      a.latitude, a.longitude, a.search_m
    ) c
    WHERE a.search_m IS NOT NULL
  )
  SELECT s.osm_node_id, t.osm_node_id, c.road_km,
         CASE WHEN c.road_km * 1000 <= p_radius THEN 'ELIGIBLE'
              WHEN c.road_km IS NOT NULL THEN 'OUTSIDE_GEOFENCE'
              WHEN s.component_id <> t.component_id THEN 'ROUTE_UNAVAILABLE'
              ELSE NULL END
  FROM sources s CROSS JOIN targets t
  LEFT JOIN costs c ON c.source_node = s.osm_node_id AND c.target_node = t.osm_node_id
$function$;

REVOKE ALL ON FUNCTION routing_private.claim_eligibility_search_radius(text,integer)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION routing_private.claim_eligibility_costs(bigint[],bigint[],bigint,text,integer)
  FROM PUBLIC, anon, authenticated, service_role;


CREATE OR REPLACE FUNCTION public.geolock_refresh_listing_road_eligibility(p_listing uuid, p_ngo uuid DEFAULT NULL::uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare v_l public.listings%rowtype; v_snapshot text; v_radius integer;
begin
  delete from public.ngo_listing_road_eligibility
   where listing_id = p_listing and (p_ngo is null or ngo_user_id = p_ngo);
  select * into v_l from public.listings where listing_id = p_listing;
  v_snapshot := public.geolock_active_road_snapshot();
  select geofence_radius_m into v_radius from public.coordination_config where singleton;
  if not found or v_snapshot is null or v_l.pickup_road_node_id is null or v_radius is null then
    return;
  end if;

  insert into public.ngo_listing_road_eligibility(listing_id, ngo_user_id,
    network_snapshot_id, ngo_road_node_id, listing_road_node_id, road_distance_km,
    geofence_radius_m, outcome)
  with candidates as (
    select n.user_id, n.road_node_id
      from public.ngo_profiles n
     where n.active_flag and n.location_verified_at is not null
       and n.road_node_id is not null
       and (p_ngo is null or n.user_id = p_ngo)

  ), costs as materialized (
    select * from routing_private.claim_eligibility_costs(
      array(select distinct c.road_node_id::bigint from candidates c),
      array[v_l.pickup_road_node_id::bigint],
      v_l.pickup_road_node_id::bigint, v_snapshot, v_radius)
  )
  select p_listing, c.user_id, v_snapshot, c.road_node_id, v_l.pickup_road_node_id,
         k.road_km, v_radius, k.outcome
    from candidates c
    join costs k on k.source_node = c.road_node_id::bigint
   where k.outcome is not null
   order by c.user_id
  on conflict (listing_id, ngo_user_id) do update
    set network_snapshot_id = excluded.network_snapshot_id,
        ngo_road_node_id = excluded.ngo_road_node_id,
        listing_road_node_id = excluded.listing_road_node_id,
        road_distance_km = excluded.road_distance_km,
        geofence_radius_m = excluded.geofence_radius_m,
        outcome = excluded.outcome,
        computed_at = clock_timestamp();
end $function$;

CREATE OR REPLACE FUNCTION public.geolock_refresh_ngo_road_eligibility(p_ngo uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare v_n public.ngo_profiles%rowtype; v_snapshot text; v_radius integer;
begin
  delete from public.ngo_listing_road_eligibility e
   where e.ngo_user_id = p_ngo
     and exists (select 1 from public.listings l
                  where l.listing_id = e.listing_id
                    and (l.listing_status = 'AVAILABLE'
                         or exists (select 1 from public.donation_claims c
                                     where c.listing_id = l.listing_id and c.ngo_user_id = p_ngo
                                       and c.claim_status in ('ACTIVE','COMPLETED','RECONCILIATION_REQUIRED'))));
  select * into v_n from public.ngo_profiles where user_id = p_ngo;
  v_snapshot := public.geolock_active_road_snapshot();
  select geofence_radius_m into v_radius from public.coordination_config where singleton;
  if not found or v_snapshot is null or v_n.road_node_id is null
     or v_n.location_verified_at is null or not v_n.active_flag or v_radius is null then
    return;
  end if;

  insert into public.ngo_listing_road_eligibility(listing_id, ngo_user_id,
    network_snapshot_id, ngo_road_node_id, listing_road_node_id, road_distance_km,
    geofence_radius_m, outcome)
  with targets as (
    select l.listing_id, l.pickup_road_node_id
      from public.listings l
     where l.pickup_road_node_id is not null
       and (l.listing_status = 'AVAILABLE'
            or exists (select 1 from public.donation_claims c
                        where c.listing_id = l.listing_id and c.ngo_user_id = p_ngo
                          and c.claim_status in ('ACTIVE','COMPLETED','RECONCILIATION_REQUIRED')))

  ), costs as materialized (
    select * from routing_private.claim_eligibility_costs(
      array[v_n.road_node_id::bigint],
      array(select distinct t.pickup_road_node_id::bigint from targets t),
      v_n.road_node_id::bigint, v_snapshot, v_radius)
  )
  select t.listing_id, p_ngo, v_snapshot, v_n.road_node_id, t.pickup_road_node_id,
         k.road_km, v_radius, k.outcome
    from targets t
    join costs k on k.target_node = t.pickup_road_node_id::bigint
   where k.outcome is not null
   order by t.listing_id
  on conflict (listing_id, ngo_user_id) do update
    set network_snapshot_id = excluded.network_snapshot_id,
        ngo_road_node_id = excluded.ngo_road_node_id,
        listing_road_node_id = excluded.listing_road_node_id,
        road_distance_km = excluded.road_distance_km,
        geofence_radius_m = excluded.geofence_radius_m,
        outcome = excluded.outcome,
        computed_at = clock_timestamp();
end $function$;

CREATE OR REPLACE FUNCTION public.geolock_road_eligible_km(p_ngo uuid, p_listing uuid)
 RETURNS double precision
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
  select e.road_distance_km from public.ngo_listing_road_eligibility e
    join public.ngo_profiles n on n.user_id=e.ngo_user_id
    join public.listings l on l.listing_id=e.listing_id
    join public.coordination_config cfg on cfg.singleton
   where e.ngo_user_id=p_ngo and e.listing_id=p_listing and e.outcome='ELIGIBLE'
     and e.network_snapshot_id=public.geolock_active_road_snapshot()
     and routing_private.claim_eligibility_search_radius(e.network_snapshot_id,cfg.geofence_radius_m) is not null
     and e.ngo_road_node_id=n.road_node_id and e.listing_road_node_id=l.pickup_road_node_id
     and e.geofence_radius_m=cfg.geofence_radius_m
     and e.road_distance_km*1000<=cfg.geofence_radius_m
     and n.location_verified_at is not null and n.active_flag
     and public.geolock_ngo_eligibility_ready(p_ngo)
     and public.geolock_listing_eligibility_ready(p_listing)
$function$;

CREATE OR REPLACE FUNCTION public.geolock_ngo_listing_road_check(p_ngo uuid, p_listing uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare v_n public.ngo_profiles%rowtype; v_l public.listings%rowtype;
  v_radius integer; v_km double precision; v_outcome text; v_snapshot text;
begin
  -- claim_listing already holds NGO FOR SHARE, then listing FOR NO KEY UPDATE.
  -- Do not let on-demand routing bypass pending/failed/stale queue generations.
  if not public.geolock_ngo_eligibility_ready(p_ngo)
     or not public.geolock_listing_eligibility_ready(p_listing) then
    return jsonb_build_object('outcome','ELIGIBILITY_UNDETERMINED');
  end if;
  select * into v_n from public.ngo_profiles where user_id = p_ngo;
  select * into v_l from public.listings where listing_id = p_listing;
  select geofence_radius_m into v_radius from public.coordination_config where singleton;
  if v_n.user_id is null or v_n.location_verified_at is null
     or v_n.latitude is null or v_n.longitude is null then
    return jsonb_build_object('outcome', 'ELIGIBILITY_UNDETERMINED');
  end if;
  v_snapshot := public.geolock_active_road_snapshot();
  if routing_private.claim_eligibility_search_radius(v_snapshot, v_radius) is null
     or v_n.road_node_id is null or v_l.pickup_road_node_id is null then
    return jsonb_build_object('outcome', 'ELIGIBILITY_UNDETERMINED');
  end if;

  select e.outcome, e.road_distance_km into v_outcome, v_km
    from public.ngo_listing_road_eligibility e
   where e.ngo_user_id = p_ngo and e.listing_id = p_listing
     and e.network_snapshot_id = v_snapshot
     and e.ngo_road_node_id = v_n.road_node_id
     and e.listing_road_node_id = v_l.pickup_road_node_id
     and e.geofence_radius_m = v_radius;
  if not found then
    perform public.geolock_refresh_listing_road_eligibility(p_listing, p_ngo);
    select e.outcome, e.road_distance_km into v_outcome, v_km
      from public.ngo_listing_road_eligibility e
     where e.ngo_user_id = p_ngo and e.listing_id = p_listing
       and e.network_snapshot_id = v_snapshot
       and e.ngo_road_node_id = v_n.road_node_id
       and e.listing_road_node_id = v_l.pickup_road_node_id
       and e.geofence_radius_m = v_radius;
  end if;
  if public.geolock_active_road_snapshot() is distinct from v_snapshot then
    return jsonb_build_object('outcome', 'ELIGIBILITY_UNDETERMINED');
  end if;
  return jsonb_build_object('outcome', coalesce(v_outcome, 'ELIGIBILITY_UNDETERMINED'),
                            'road_distance_km', round(v_km::numeric, 3));
end $function$;

COMMIT;

