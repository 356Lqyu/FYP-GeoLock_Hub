-- Reviewed Stage B.2 forward correction. Local verification only; NOT deployed.
-- Requires the original reviewed October 20 helpers and current road schema.
-- CREATE OR REPLACE retains function OIDs, ownership and existing ACLs.
BEGIN;

DO $spatial_guard$
BEGIN
  IF current_user <> 'postgres' OR session_user <> 'postgres' THEN
    RAISE EXCEPTION 'POSTGRES_SESSION_REQUIRED';
  END IF;
  IF EXISTS (
    SELECT 1 FROM (VALUES
      ('public.geolock_resolve_road_node(double precision,double precision)',
       '9701683fdcfeb2486c887860c6470262', 's',
       'TABLE(node_id text, snap_distance_m double precision, snapshot_id text)'),
      ('public.geolock_road_costs(bigint[],bigint[],double precision,double precision,double precision)',
       '828217e0b8faeeb3d32fa726b3e06a2a', 'v',
       'TABLE(source_node bigint, target_node bigint, road_km double precision)')
    ) e(signature, body_md5, volatility, result_type)
    LEFT JOIN pg_proc p ON p.oid=to_regprocedure(e.signature)
    WHERE p.oid IS NULL OR p.proowner <> 'postgres'::regrole OR NOT p.prosecdef
       OR p.provolatile::text <> e.volatility
       OR p.proconfig IS DISTINCT FROM ARRAY['search_path=public, extensions, pg_temp']
       OR pg_get_function_result(p.oid) IS DISTINCT FROM e.result_type
       OR md5(replace(p.prosrc,E'\r\n',E'\n')) IS DISTINCT FROM e.body_md5
  ) THEN
    RAISE EXCEPTION 'REVIEWED_SPATIAL_SOURCE_OR_SECURITY_DRIFT';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles r CROSS JOIN pg_proc p
      WHERE r.rolname IN ('anon','authenticated','service_role')
        AND p.oid IN (
          to_regprocedure('public.geolock_resolve_road_node(double precision,double precision)'),
          to_regprocedure('public.geolock_road_costs(bigint[],bigint[],double precision,double precision,double precision)'))
        AND has_function_privilege(r.oid,p.oid,'EXECUTE')) THEN
    RAISE EXCEPTION 'PRIVATE_SPATIAL_HELPER_PRIVILEGE_DRIFT';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname='postgis')
     OR NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname='pgrouting')
     OR coalesce(to_regprocedure('extensions.pgr_dijkstraCost(text,bigint[],bigint[],boolean)'),
                 to_regprocedure('extensions.pgr_dijkstraCost(text,anyarray,anyarray,boolean)')) IS NULL THEN
    RAISE EXCEPTION 'SPATIAL_EXTENSION_CONTRACT_REQUIRED';
  END IF;
  IF (SELECT count(*) FROM public.road_network_coverage
      WHERE active_flag AND dataset_kind='OPERATIONAL' AND approved_at IS NOT NULL
        AND max_snap_distance_m=500) <> 1 THEN
    RAISE EXCEPTION 'ONE_APPROVED_500M_ROAD_SNAPSHOT_REQUIRED';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.coordination_config WHERE singleton
      AND geofence_radius_m=20000 AND claim_lease_minutes=360
      AND donation_direct_min_kg=10) THEN
    RAISE EXCEPTION 'COORDINATION_POLICY_DRIFT';
  END IF;
END
$spatial_guard$;

CREATE OR REPLACE FUNCTION public.geolock_resolve_road_node(
  p_latitude double precision, p_longitude double precision)
RETURNS TABLE(node_id text, snap_distance_m double precision, snapshot_id text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
  WITH pt AS (
    SELECT extensions.ST_SetSRID(extensions.ST_MakePoint(p_longitude, p_latitude), 4326) AS g
    WHERE p_latitude BETWEEN -90 AND 90 AND p_longitude BETWEEN -180 AND 180
  )
  SELECT n.osm_node_id::text,
         extensions.ST_Distance(n.geog, pt.g::extensions.geography),
         n.network_snapshot_id
  FROM pt
  JOIN public.road_network_coverage c
    ON c.active_flag AND c.dataset_kind='OPERATIONAL' AND c.approved_at IS NOT NULL
   AND extensions.ST_Covers(c.coverage_area, pt.g)
  JOIN public.road_network_nodes n
    ON n.network_snapshot_id=c.network_snapshot_id AND n.active_flag
   AND extensions.ST_DWithin(n.geog, pt.g::extensions.geography, c.max_snap_distance_m)
  ORDER BY n.geog <-> pt.g::extensions.geography, n.osm_node_id
  LIMIT 1
$$;

CREATE OR REPLACE FUNCTION public.geolock_road_costs(
  p_sources bigint[], p_targets bigint[],
  p_center_lat double precision, p_center_lon double precision, p_radius_m double precision)
RETURNS TABLE(source_node bigint, target_node bigint, road_km double precision)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
  v_snapshot text := public.geolock_active_road_snapshot();
  v_sources bigint[]; v_targets bigint[]; v_sql text;
BEGIN
  IF v_snapshot IS NULL OR coalesce(cardinality(p_sources),0)=0
     OR coalesce(cardinality(p_targets),0)=0
     OR (p_center_lat BETWEEN -90 AND 90 AND p_center_lon BETWEEN -180 AND 180
         AND p_radius_m>=0 AND p_radius_m<'Infinity'::double precision) IS NOT TRUE THEN
    RETURN;
  END IF;

  -- Validate BOTH endpoint sets before self-distance or shortest-path evaluation.
  -- Invalid endpoints yield no rows; valid members of a mixed set remain usable.
  SELECT array_agg(n.osm_node_id ORDER BY n.osm_node_id) INTO v_sources
    FROM public.road_network_nodes n
   WHERE n.osm_node_id=ANY(p_sources) AND n.active_flag
     AND n.network_snapshot_id=v_snapshot;
  SELECT array_agg(n.osm_node_id ORDER BY n.osm_node_id) INTO v_targets
    FROM public.road_network_nodes n
   WHERE n.osm_node_id=ANY(p_targets) AND n.active_flag
     AND n.network_snapshot_id=v_snapshot;
  IF v_sources IS NULL OR v_targets IS NULL THEN RETURN; END IF;

  v_sql := format(
    'SELECT e.edge_id AS id, e.source_node AS source, e.target_node AS target,
            e.road_km::float8 AS cost, -1::float8 AS reverse_cost
       FROM public.road_network_nodes n
       JOIN public.road_network_edges e ON e.source_node=n.osm_node_id
       JOIN public.road_network_nodes t ON t.osm_node_id=e.target_node
        AND t.active_flag AND t.network_snapshot_id=n.network_snapshot_id
      WHERE n.network_snapshot_id=%L AND n.active_flag
        AND extensions.ST_DWithin(n.geog,
              extensions.ST_SetSRID(extensions.ST_MakePoint(%L::float8,%L::float8),4326)::extensions.geography,
              %L::float8)',
    v_snapshot,p_center_lon,p_center_lat,p_radius_m);
  RETURN QUERY
    SELECT s,s,0::float8 FROM unnest(v_sources) s WHERE s=ANY(v_targets)
    UNION ALL
    SELECT c.start_vid,c.end_vid,c.agg_cost
      FROM extensions.pgr_dijkstraCost(v_sql,v_sources,v_targets,true) c
     WHERE c.start_vid<>c.end_vid;
END
$$;

-- No grants, extension changes, configuration changes, or business-row writes.
COMMIT;
