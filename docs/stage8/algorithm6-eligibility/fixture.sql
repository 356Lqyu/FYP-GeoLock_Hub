-- Synthetic tables for the road eligibility draft. Use a disposable database.
CREATE SCHEMA extensions;
CREATE EXTENSION postgis WITH SCHEMA extensions;
CREATE EXTENSION pgrouting WITH SCHEMA extensions;
CREATE SCHEMA routing_private;
CREATE ROLE anon;
CREATE ROLE authenticated;
CREATE ROLE service_role;
CREATE TABLE public.road_network_coverage (
  network_snapshot_id text PRIMARY KEY, active_flag boolean, approved_at timestamptz,
  dataset_kind text, node_count integer, edge_count integer
);
CREATE TABLE routing_private.graphs (
  coverage_snapshot text, graph_id uuid, content_digest text, node_count integer, edge_count integer
);
INSERT INTO public.road_network_coverage VALUES
  ('OSM-OPS-20261018',true,now(),'OPERATIONAL',926414,2145828);
INSERT INTO routing_private.graphs VALUES
  ('OSM-OPS-20261018','eab1f7ee-a8e0-4bed-a0e1-2c4bff024936',
   '5e06dab0fb4d2b97ac53fd9a1178dc46aa6b98811aefbaef96528c604a04012a',926414,2145828);
CREATE TABLE public.road_network_nodes (
  osm_node_id bigint PRIMARY KEY, longitude float8, latitude float8, component_id integer,
  active_flag boolean DEFAULT true, network_snapshot_id text DEFAULT 'OSM-OPS-20261018',
  geog extensions.geography GENERATED ALWAYS AS
    (extensions.ST_SetSRID(extensions.ST_MakePoint(longitude,latitude),4326)::extensions.geography) STORED
);
INSERT INTO public.road_network_nodes (osm_node_id,longitude,latitude,component_id) VALUES
  (1,-0.002,0,1),(2,0.006,0,1),(3,0.167,0,1),(4,0.175,0,1),
  (5,0.05,0,1),(6,0.06,0,1),(7,0.07,0,2);
CREATE TABLE public.road_network_edges (edge_id bigint, source_node bigint, target_node bigint, road_km real);
INSERT INTO public.road_network_edges VALUES (1,1,2,1),(2,2,3,18),(3,3,4,1),(4,1,5,19),(5,1,6,21);
CREATE TABLE public.ngo_profiles (
  user_id uuid PRIMARY KEY, road_node_id text, longitude float8, latitude float8,
  active_flag boolean, location_verified_at timestamptz
);
CREATE TABLE public.listings (
  listing_id uuid PRIMARY KEY, pickup_road_node_id text, pickup_longitude float8,
  pickup_latitude float8, listing_status text DEFAULT 'AVAILABLE'
);
CREATE TABLE public.donation_claims (listing_id uuid, ngo_user_id uuid, claim_status text);
CREATE TABLE public.coordination_config (singleton boolean, geofence_radius_m integer);
INSERT INTO public.coordination_config VALUES (true,20000);
CREATE TABLE public.ngo_listing_road_eligibility (
  listing_id uuid, ngo_user_id uuid, network_snapshot_id text, ngo_road_node_id text,
  listing_road_node_id text, road_distance_km float8, geofence_radius_m integer,
  outcome text, computed_at timestamptz DEFAULT clock_timestamp(),
  PRIMARY KEY (listing_id,ngo_user_id)
);
INSERT INTO public.ngo_profiles VALUES
  ('00000000-0000-0000-0000-000000000001','1',-0.0063,0,true,now()),
  ('00000000-0000-0000-0000-000000000004','4',0.175,0,true,now());
INSERT INTO public.listings (listing_id,pickup_road_node_id,pickup_longitude,pickup_latitude) VALUES
  ('00000000-0000-0000-0001-000000000001','1',-0.002,0),
  ('00000000-0000-0000-0001-000000000004','4',0.1793,0),
  ('00000000-0000-0000-0001-000000000005','5',0.05,0),
  ('00000000-0000-0000-0001-000000000006','6',0.06,0),
  ('00000000-0000-0000-0001-000000000007','7',0.07,0);

CREATE FUNCTION public.geolock_active_road_snapshot() RETURNS text LANGUAGE sql STABLE AS $$
  SELECT network_snapshot_id FROM public.road_network_coverage WHERE active_flag;
$$;
CREATE FUNCTION public.geolock_road_component(p_node text) RETURNS integer LANGUAGE sql STABLE AS $$
  SELECT component_id FROM public.road_network_nodes WHERE osm_node_id=p_node::bigint;
$$;
CREATE FUNCTION public.geolock_ngo_eligibility_ready(p_ngo uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT EXISTS(SELECT FROM public.ngo_profiles WHERE user_id=p_ngo AND active_flag);
$$;
CREATE FUNCTION public.geolock_listing_eligibility_ready(p_listing uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT EXISTS(SELECT FROM public.listings WHERE listing_id=p_listing);
$$;
