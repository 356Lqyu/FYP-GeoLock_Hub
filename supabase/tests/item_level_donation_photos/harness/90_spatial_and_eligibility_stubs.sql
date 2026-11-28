-- LOCAL TEST HARNESS ONLY.
-- PostGIS/pgRouting are not available locally, so exactly two deployed functions are
-- replaced here. Everything else in the database is the verbatim bootstrap + repo readers.
--  * geolock_resolve_road_node: deterministic snap (real one uses PostGIS nearest node).
--  * geolock_road_eligible_km: reads test_harness.road_eligibility instead of the
--    road-distance tables, so tests can make an NGO eligible / ineligible on purpose.
--    The new item readers call this SAME function as the existing readers, so the
--    authorisation comparison between old and new readers stays like-for-like.
CREATE SCHEMA test_harness;
CREATE TABLE test_harness.road_eligibility (ngo_user_id uuid, listing_id uuid, km double precision,
  PRIMARY KEY (ngo_user_id, listing_id));

ALTER TABLE public.road_network_coverage DISABLE TRIGGER USER;
INSERT INTO public.road_network_coverage (network_snapshot_id, coverage_area, max_snap_distance_m, provenance,
  dataset_kind, approved_at, active_flag)
VALUES ('OSM-OPS-TEST-SNAPSHOT', 'harness', 500, 'OPERATIONAL; local harness', 'OPERATIONAL', now(), true);
ALTER TABLE public.road_network_coverage ENABLE TRIGGER USER;

CREATE OR REPLACE FUNCTION public.geolock_resolve_road_node(p_latitude double precision, p_longitude double precision)
 RETURNS TABLE(node_id text, snap_distance_m double precision, snapshot_id text)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $$ SELECT 'TN-' || round(p_latitude::numeric, 5) || '-' || round(p_longitude::numeric, 5),
             1.0::double precision, 'OSM-OPS-TEST-SNAPSHOT'::text
      WHERE p_latitude IS NOT NULL AND p_longitude IS NOT NULL $$;

CREATE OR REPLACE FUNCTION public.geolock_road_eligible_km(p_ngo uuid, p_listing uuid)
 RETURNS double precision
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $$ SELECT e.km FROM test_harness.road_eligibility e
      JOIN public.ngo_profiles n ON n.user_id = e.ngo_user_id
     WHERE e.ngo_user_id = p_ngo AND e.listing_id = p_listing
       AND n.location_verified_at IS NOT NULL AND n.active_flag $$;
