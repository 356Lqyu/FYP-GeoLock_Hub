-- GeoLock Hub: location stage before claim and lease.
--
-- Implements the location rules of the uploaded report and authority contract
-- for the path "donation submitted -> listing AVAILABLE -> NGO claim":
--   * Section 3.3.5.1: donor, hub, NGO and depot locations map to the nearest
--     drivable OpenStreetMap node within 500 m; otherwise not routable.
--   * Algorithm 2 / Eq. 4.4: a hub is feasible only with a usable donor-to-hub route.
--   * Algorithm 6 lines 2-4 / Eq. 4.9: NGO eligibility is directed road-network
--     distance NGO -> listing <= 20 km; ROUTE_UNAVAILABLE or OUTSIDE_GEOFENCE otherwise.
--   * Contract INV-02 / section 5: the geofence decides eligibility only, never the
--     claim winner; missing coordinates give ELIGIBILITY_UNDETERMINED.
--
-- Data separation: nodes and edges come only from an OPERATIONAL snapshot
-- (OSM-OPS-<date>) built by supabase/road_network from a Geofabrik extract. The research
-- benchmark dataset, its matrix and node files are never loaded into this database.
--
-- Not changed: idempotent claim, one-active-claim rule, 360-minute lease, recovery,
-- reconciliation, hub capacity, batching. In claim_listing only the two location
-- branches are replaced; every other line is kept verbatim.
--
-- Target: deployed V3 + October 18/19 migrations (DEV rcgyuwiidqvrgbxswhqj).
-- Requires PostGIS and pgRouting in schema "extensions".
-- Prepared for review. NOT executed against Supabase.

begin;

create extension if not exists pgrouting with schema extensions;

-- 0. Preflight: refuse to replace functions that changed since this file was written
--    (compared without \r, so bodies pasted from Windows with CRLF still match)
--    (expected = deployed body; patched = body installed by this file, for re-runs).
do $$
declare r record;
begin
  for r in select * from (values
    ('claim_listing','d909b92ca69be452b0304a0d0f9ee06d','bacffdf27eb54ff7d6aa55b586864d2e'),
    ('discover_eligible_listings','fe05da99ac2ab6112830e8e364d41b83','dd1496b1f208a2bdceaf7848b4a8ffe4'),
    ('discover_eligible_listing_cards','46c74d78e25ee109b10dbff5f62addcb','33edca558aadd00a9b41202d00209d9f'),
    ('get_eligible_listing_constituents','7b61192411e956625cddd2a961b4e73f','9f9edea32a40479536052c37ab543455'),
    ('can_read_geolock_donation_image','1caa7c567220ab5505609873f034a31a','b86eb6c43f15d9d472127c00a0da69cb'),
    ('can_read_geolock_batch_image','ad4a7f01ec4a36112459712cff575276','9370a1d726340a5248ff0145c77efa38'),
    ('get_my_donation_detail','f93bf6c90747ebc0ff7e20e233d0cd9e','2ab3f6f7a72ae45d07bbd1e6eb067d71'),
    ('get_my_donations','7687b5d43e75aa449954b37b5cb76429','bd0724a840d848a700aeaaf85ac0dfd2'),
    ('get_eligible_hubs','f2987fb4e6cef90878073124a106e1e5','073ab402c8a196a36321e459f680c9cb')) v(fn, expected, patched)
  loop
    if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                   where n.nspname = 'public' and p.proname = r.fn
                     and md5(replace(p.prosrc, E'\r', '')) in (r.expected, r.patched)) then
      raise exception 'FUNCTION_CHANGED_SINCE_REVIEW: %', r.fn;
    end if;
  end loop;
  if to_regclass('public.road_network_nodes') is not null
     and not exists (select 1 from information_schema.columns
                     where table_schema = 'public' and table_name = 'road_network_nodes'
                       and column_name = 'osm_node_id') then
    raise exception 'OLD_ROAD_NETWORK_TABLES_PRESENT: review before applying';
  end if;
end $$;

-- 1. Operational snapshot registry.
create table if not exists public.road_network_coverage (
  network_snapshot_id text primary key,
  coverage_area extensions.geometry(MultiPolygon,4326) not null,
  max_snap_distance_m integer not null default 500
    check (max_snap_distance_m = 500),               -- report 3.3.5.1
  provenance text not null,
  dataset_kind text not null default 'OPERATIONAL'
    check (dataset_kind in ('OPERATIONAL','BENCHMARK')),
  node_count integer check (node_count is null or node_count > 0),
  edge_count integer check (edge_count is null or edge_count > 0),
  approved_at timestamptz,
  active_flag boolean not null default false,
  created_at timestamptz not null default clock_timestamp(),
  constraint road_network_active_requires_approval
    check (not active_flag or approved_at is not null),
  constraint road_network_operational_not_benchmark
    check (dataset_kind <> 'OPERATIONAL'
           or (network_snapshot_id like 'OSM-OPS-%' and provenance like 'OPERATIONAL;%'))
);
create unique index if not exists road_network_one_active_operational
  on public.road_network_coverage ((true))
  where active_flag and dataset_kind = 'OPERATIONAL';
create index if not exists idx_road_coverage_gist
  on public.road_network_coverage using gist (coverage_area);

-- 2. Drivable OSM nodes.
create table if not exists public.road_network_nodes (
  osm_node_id bigint primary key check (osm_node_id > 0),  -- OpenStreetMap node id;
                                                            -- app tables store it as text
  network_snapshot_id text not null
    references public.road_network_coverage(network_snapshot_id),
  latitude double precision not null check (latitude between -90 and 90),
  longitude double precision not null check (longitude between -180 and 180),
  geog extensions.geography(Point,4326) generated always as
    (extensions.ST_SetSRID(extensions.ST_MakePoint(longitude, latitude), 4326)::extensions.geography) stored,
  component_id integer not null,                     -- strongly connected network (builder keeps one)
  active_flag boolean not null default true
);
create index if not exists idx_road_nodes_geog on public.road_network_nodes using gist (geog);

-- 3. Directed drivable edges (road distance for the geofence and routes).
-- An edge belongs to the snapshot of its source node; deleting a snapshot's nodes
-- deletes its edges. Compact types keep the network within a small database.
create table if not exists public.road_network_edges (
  edge_id integer generated always as identity,      -- pgRouting edge id
  source_node bigint not null
    references public.road_network_nodes(osm_node_id) on delete cascade,
  target_node bigint not null,
  road_km real not null check (road_km > 0),
  travel_minutes real not null check (travel_minutes > 0),
  primary key (source_node, target_node)              -- also serves source lookups
);

-- 4. Stored NGO -> listing road eligibility (the live counterpart of a frozen matrix:
--    one deterministic record per pair, tied to the snapshot and both node IDs).
create table if not exists public.ngo_listing_road_eligibility (
  listing_id uuid not null references public.listings(listing_id),
  ngo_user_id uuid not null references public.ngo_profiles(user_id),
  network_snapshot_id text not null
    references public.road_network_coverage(network_snapshot_id),
  ngo_road_node_id text not null,
  listing_road_node_id text not null,
  road_distance_km double precision,                -- null: no path within the radius
  geofence_radius_m integer not null,
  outcome text not null check (outcome in ('ELIGIBLE','OUTSIDE_GEOFENCE','ROUTE_UNAVAILABLE')),
  computed_at timestamptz not null default clock_timestamp(),
  primary key (listing_id, ngo_user_id),
  constraint ngo_listing_road_eligibility_consistent check (
    (outcome = 'ELIGIBLE' and road_distance_km is not null
       and road_distance_km * 1000 <= geofence_radius_m)
    or (outcome = 'OUTSIDE_GEOFENCE'
       and (road_distance_km is null or road_distance_km * 1000 > geofence_radius_m))
    or (outcome = 'ROUTE_UNAVAILABLE' and road_distance_km is null))
);
create index if not exists idx_ngo_listing_road_ngo
  on public.ngo_listing_road_eligibility (ngo_user_id) where outcome = 'ELIGIBLE';

alter table public.road_network_coverage enable row level security;
alter table public.road_network_nodes enable row level security;
alter table public.road_network_edges enable row level security;
alter table public.ngo_listing_road_eligibility enable row level security;
revoke all on public.road_network_coverage from public, anon, authenticated;
revoke all on public.road_network_nodes from public, anon, authenticated;
revoke all on public.road_network_edges from public, anon, authenticated;
revoke all on public.ngo_listing_road_eligibility from public, anon, authenticated;

-- 5. Helpers ------------------------------------------------------------------

create or replace function public.geolock_active_road_snapshot()
returns text language sql stable security definer
set search_path = public, pg_temp as $$
  select network_snapshot_id from public.road_network_coverage
   where active_flag and dataset_kind = 'OPERATIONAL' and approved_at is not null
   limit 1
$$;

-- Connected road network of a node in the active snapshot (null if unknown).
create or replace function public.geolock_road_component(p_node text)
returns integer language sql stable security definer
set search_path = public, pg_temp as $$
  select n.component_id from public.road_network_nodes n
   where p_node ~ '^[0-9]{1,18}$' and n.osm_node_id = p_node::bigint and n.active_flag
     and n.network_snapshot_id = public.geolock_active_road_snapshot()
$$;

-- Nearest active node within 500 m inside the approved coverage (report 3.3.5.1).
create or replace function public.geolock_resolve_road_node(
  p_latitude double precision, p_longitude double precision)
returns table(node_id text, snap_distance_m double precision, snapshot_id text)
language sql stable security definer
set search_path = public, extensions, pg_temp
as $$
  with pt as (
    select extensions.ST_SetSRID(extensions.ST_MakePoint(p_longitude, p_latitude), 4326) as g
    where p_latitude between -90 and 90 and p_longitude between -180 and 180
  )
  select n.osm_node_id::text,
         extensions.ST_Distance(n.geog, pt.g::extensions.geography),
         n.network_snapshot_id
  from pt
  join public.road_network_coverage c
    on c.active_flag and c.dataset_kind = 'OPERATIONAL' and c.approved_at is not null
   and extensions.ST_Covers(c.coverage_area, pt.g)
  join public.road_network_nodes n
    on n.network_snapshot_id = c.network_snapshot_id and n.active_flag
   and extensions.ST_DWithin(n.geog, pt.g::extensions.geography, c.max_snap_distance_m)
  order by n.geog <-> pt.g::extensions.geography
  limit 1
$$;

-- Directed shortest road distance (km) between node sets on the active snapshot.
-- The search graph is limited to edges whose source lies within p_radius_m of the
-- centre. Every path of length <= p_radius_m that ends (or starts) at the centre
-- lies wholly inside that circle, so distances up to the radius are exact.
create or replace function public.geolock_road_costs(
  p_sources bigint[], p_targets bigint[],
  p_center_lat double precision, p_center_lon double precision, p_radius_m double precision)
returns table(source_node bigint, target_node bigint, road_km double precision)
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $$
declare v_snapshot text := public.geolock_active_road_snapshot(); v_sql text;
begin
  if v_snapshot is null or coalesce(cardinality(p_sources), 0) = 0
     or coalesce(cardinality(p_targets), 0) = 0 then
    return;
  end if;
  v_sql := format(
    'select e.edge_id as id, e.source_node as source, e.target_node as target,
            e.road_km::float8 as cost, -1::float8 as reverse_cost
       from public.road_network_nodes n
       join public.road_network_edges e on e.source_node = n.osm_node_id
      where n.network_snapshot_id = %L and n.active_flag
        and extensions.ST_DWithin(n.geog,
              extensions.ST_SetSRID(extensions.ST_MakePoint(%L::float8, %L::float8), 4326)::extensions.geography,
              %L::float8)',
    v_snapshot, p_center_lon, p_center_lat, p_radius_m);
  return query
    select s, s, 0::float8
      from unnest(p_sources) s where s = any(p_targets)
    union all
    select c.start_vid, c.end_vid, c.agg_cost
      from extensions.pgr_dijkstraCost(v_sql, p_sources, p_targets, true) c;
  -- road_km is stored as real (float4); sums are exact to well under 1 m.
end $$;

-- (Re)compute stored eligibility for one listing (all verified NGOs, or one NGO).
create or replace function public.geolock_refresh_listing_road_eligibility(
  p_listing uuid, p_ngo uuid default null)
returns void language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $$
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
       -- Road distance can never be shorter than the straight line.
       and extensions.ST_DWithin(
             extensions.ST_SetSRID(extensions.ST_MakePoint(n.longitude, n.latitude), 4326)::extensions.geography,
             extensions.ST_SetSRID(extensions.ST_MakePoint(v_l.pickup_longitude, v_l.pickup_latitude), 4326)::extensions.geography,
             v_radius)
  ), costs as materialized (
    select * from public.geolock_road_costs(
      array(select distinct c.road_node_id::bigint from candidates c),
      array[v_l.pickup_road_node_id::bigint],
      v_l.pickup_latitude, v_l.pickup_longitude, v_radius)
  )
  select p_listing, c.user_id, v_snapshot, c.road_node_id, v_l.pickup_road_node_id,
         case when k.road_km is not null then k.road_km end, v_radius,
         case when k.road_km is not null and k.road_km * 1000 <= v_radius then 'ELIGIBLE'
              when k.road_km is null and public.geolock_road_component(c.road_node_id)
                   is distinct from public.geolock_road_component(v_l.pickup_road_node_id)
              then 'ROUTE_UNAVAILABLE'
              else 'OUTSIDE_GEOFENCE' end
    from candidates c
    left join costs k on k.source_node = c.road_node_id::bigint;
end $$;

-- (Re)compute stored eligibility for one NGO against all open listings and the
-- listings it currently holds (ACTIVE / COMPLETED / RECONCILIATION_REQUIRED claim).
-- Rows of other closed listings are left untouched (history), so re-verifying an
-- NGO or activating a snapshot never removes a claimant's photo access.
create or replace function public.geolock_refresh_ngo_road_eligibility(p_ngo uuid)
returns void language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $$
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
       and extensions.ST_DWithin(
             extensions.ST_SetSRID(extensions.ST_MakePoint(v_n.longitude, v_n.latitude), 4326)::extensions.geography,
             extensions.ST_SetSRID(extensions.ST_MakePoint(l.pickup_longitude, l.pickup_latitude), 4326)::extensions.geography,
             v_radius)
  ), costs as materialized (
    select * from public.geolock_road_costs(
      array[v_n.road_node_id::bigint],
      array(select distinct t.pickup_road_node_id::bigint from targets t),
      v_n.latitude, v_n.longitude, v_radius)
  )
  select t.listing_id, p_ngo, v_snapshot, v_n.road_node_id, t.pickup_road_node_id,
         k.road_km, v_radius,
         case when k.road_km is not null and k.road_km * 1000 <= v_radius then 'ELIGIBLE'
              when k.road_km is null and public.geolock_road_component(v_n.road_node_id)
                   is distinct from public.geolock_road_component(t.pickup_road_node_id)
              then 'ROUTE_UNAVAILABLE'
              else 'OUTSIDE_GEOFENCE' end
    from targets t
    left join costs k on k.target_node = t.pickup_road_node_id::bigint
  on conflict (listing_id, ngo_user_id) do update
    set network_snapshot_id = excluded.network_snapshot_id,
        ngo_road_node_id = excluded.ngo_road_node_id,
        listing_road_node_id = excluded.listing_road_node_id,
        road_distance_km = excluded.road_distance_km,
        geofence_radius_m = excluded.geofence_radius_m,
        outcome = excluded.outcome,
        computed_at = clock_timestamp();
end $$;

-- Stored, still-valid ELIGIBLE road distance (km) for discovery; null otherwise.
create or replace function public.geolock_road_eligible_km(p_ngo uuid, p_listing uuid)
returns double precision language sql stable security definer
set search_path = public, pg_temp as $$
  select e.road_distance_km
    from public.ngo_listing_road_eligibility e
    join public.ngo_profiles n on n.user_id = e.ngo_user_id
    join public.listings l on l.listing_id = e.listing_id
   where e.ngo_user_id = p_ngo and e.listing_id = p_listing
     and e.outcome = 'ELIGIBLE'
     and e.network_snapshot_id = public.geolock_active_road_snapshot()
     and e.ngo_road_node_id = n.road_node_id
     and e.listing_road_node_id = l.pickup_road_node_id
     and n.location_verified_at is not null and n.active_flag
$$;

-- Authoritative location decision used by claim_listing (Algorithm 6 lines 2-4).
-- Returns ELIGIBLE, ELIGIBILITY_UNDETERMINED, ROUTE_UNAVAILABLE or OUTSIDE_GEOFENCE.
create or replace function public.geolock_ngo_listing_road_check(p_ngo uuid, p_listing uuid)
returns jsonb language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $$
declare v_n public.ngo_profiles%rowtype; v_l public.listings%rowtype;
  v_radius integer; v_km double precision; v_outcome text;
begin
  select * into v_n from public.ngo_profiles where user_id = p_ngo;
  select * into v_l from public.listings where listing_id = p_listing;
  select geofence_radius_m into v_radius from public.coordination_config where singleton;
  if v_n.user_id is null or v_n.location_verified_at is null
     or v_n.latitude is null or v_n.longitude is null then
    return jsonb_build_object('outcome', 'ELIGIBILITY_UNDETERMINED');
  end if;
  if public.geolock_active_road_snapshot() is null
     or v_n.road_node_id is null or v_l.pickup_road_node_id is null then
    return jsonb_build_object('outcome', 'ROUTE_UNAVAILABLE');
  end if;
  if not extensions.ST_DWithin(
       extensions.ST_SetSRID(extensions.ST_MakePoint(v_n.longitude, v_n.latitude), 4326)::extensions.geography,
       extensions.ST_SetSRID(extensions.ST_MakePoint(v_l.pickup_longitude, v_l.pickup_latitude), 4326)::extensions.geography,
       v_radius) then
    return jsonb_build_object('outcome', 'OUTSIDE_GEOFENCE');
  end if;

  select e.outcome, e.road_distance_km into v_outcome, v_km
    from public.ngo_listing_road_eligibility e
   where e.ngo_user_id = p_ngo and e.listing_id = p_listing
     and e.network_snapshot_id = public.geolock_active_road_snapshot()
     and e.ngo_road_node_id = v_n.road_node_id
     and e.listing_road_node_id = v_l.pickup_road_node_id
     and e.geofence_radius_m = v_radius;
  if not found then
    perform public.geolock_refresh_listing_road_eligibility(p_listing, p_ngo);
    select e.outcome, e.road_distance_km into v_outcome, v_km
      from public.ngo_listing_road_eligibility e
     where e.ngo_user_id = p_ngo and e.listing_id = p_listing;
  end if;
  return jsonb_build_object('outcome', coalesce(v_outcome, 'ROUTE_UNAVAILABLE'),
                            'road_distance_km', round(v_km::numeric, 3));
end $$;

-- Donor -> hub routes for one donation (Algorithm 2 line 8 / Eq. 4.4).
-- Hubs without a node or without a directed route are omitted. The search is
-- bounded by the configured service radius around the donor.
create or replace function public.geolock_donation_hub_routes(p_donation uuid)
returns table(hub_id uuid, road_km double precision)
language plpgsql stable security definer
set search_path = public, extensions, pg_temp
as $$
declare v_d public.donations%rowtype; v_radius integer;
begin
  select * into v_d from public.donations where donation_id = p_donation;
  select geofence_radius_m into v_radius from public.coordination_config where singleton;
  if v_d.donation_id is null or v_d.pickup_road_node_id is null or v_radius is null
     or public.geolock_active_road_snapshot() is null then
    return;
  end if;
  return query
  with hubs as (
    select h.hub_id, h.road_node_id
      from public.community_hubs h
     where h.active_flag and h.road_node_id is not null
       and extensions.ST_DWithin(
             extensions.ST_SetSRID(extensions.ST_MakePoint(h.longitude, h.latitude), 4326)::extensions.geography,
             extensions.ST_SetSRID(extensions.ST_MakePoint(v_d.longitude, v_d.latitude), 4326)::extensions.geography,
             v_radius)
  ), costs as materialized (
    select * from public.geolock_road_costs(
      array[v_d.pickup_road_node_id::bigint],
      array(select distinct x.road_node_id::bigint from hubs x),
      v_d.latitude, v_d.longitude, v_radius)
  )
  select x.hub_id, k.road_km
    from hubs x join costs k on k.target_node = x.road_node_id::bigint;
end $$;

-- App-facing preview for the location picker: "is this point routable?"
create or replace function public.preview_location_routing(
  p_latitude double precision, p_longitude double precision)
returns jsonb
language plpgsql stable security definer
set search_path = public, extensions, pg_temp
as $$
declare r record;
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  if p_latitude is null or p_longitude is null
     or p_latitude not between -90 and 90 or p_longitude not between -180 and 180 then
    raise exception 'INVALID_COORDINATES';
  end if;
  select * into r from public.geolock_resolve_road_node(p_latitude, p_longitude);
  return jsonb_build_object(
    'routable', r.node_id is not null,
    'snap_distance_m', round(r.snap_distance_m::numeric, 1),
    'max_snap_distance_m', 500,
    'reason_code', case when r.node_id is null then 'NO_DRIVABLE_NODE_WITHIN_500M' end);
end $$;

revoke all on function public.geolock_active_road_snapshot() from public, anon, authenticated;
revoke all on function public.geolock_road_component(text) from public, anon, authenticated;
revoke all on function public.geolock_resolve_road_node(double precision, double precision) from public, anon, authenticated;
revoke all on function public.geolock_road_costs(bigint[], bigint[], double precision, double precision, double precision) from public, anon, authenticated;
revoke all on function public.geolock_refresh_listing_road_eligibility(uuid, uuid) from public, anon, authenticated;
revoke all on function public.geolock_refresh_ngo_road_eligibility(uuid) from public, anon, authenticated;
revoke all on function public.geolock_road_eligible_km(uuid, uuid) from public, anon, authenticated;
revoke all on function public.geolock_ngo_listing_road_check(uuid, uuid) from public, anon, authenticated;
revoke all on function public.geolock_donation_hub_routes(uuid) from public, anon, authenticated;
revoke all on function public.preview_location_routing(double precision, double precision) from public, anon;
grant execute on function public.preview_location_routing(double precision, double precision) to authenticated;

-- 6. Explicit replacements of deployed functions. Only the location predicates
--    differ from the deployed bodies (straight-line ST_DWithin / node placeholders
--    -> stored road-network eligibility). Signatures, security, grants unchanged.

-- claim_listing
CREATE OR REPLACE FUNCTION public.claim_listing(p_listing uuid, p_request uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare v_actor uuid:=auth.uid();v_ngo public.ngo_profiles%rowtype;
 v_req public.claim_requests%rowtype;v_l public.listings%rowtype;
 v_digest text;v_reason text;v_claim uuid;v_lease uuid;v_mins integer;
 v_node text;v_success boolean:=false;v_outcome text;
begin
 if v_actor is null then raise exception 'UNAUTHENTICATED'; end if;
 select * into v_ngo from public.ngo_profiles where user_id=v_actor and active_flag;
 if not found then raise exception 'ACTIVE_NGO_ONLY'; end if;
 if p_request is null or p_listing is null then raise exception 'REQUEST_AND_LISTING_REQUIRED'; end if;
 v_digest=md5(p_listing::text||':'||v_actor::text);
 insert into public.claim_requests(request_id,listing_id,ngo_user_id,request_digest)
 values(p_request,p_listing,v_actor,v_digest) on conflict(request_id) do nothing;
 select * into v_req from public.claim_requests where request_id=p_request for update;
 if v_req.request_digest<>v_digest or v_req.listing_id<>p_listing or v_req.ngo_user_id<>v_actor
 then raise exception 'IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD'; end if;
 if v_req.outcome is not null then
  return jsonb_build_object('outcome',v_req.outcome,'claim_id',v_req.result_claim_id,
    'reason_code',v_req.reason_code,'replayed',true);
 end if;
 select * into v_l from public.listings where listing_id=p_listing for update;
 if not found then v_reason='LISTING_NOT_FOUND';
 elsif v_l.listing_status<>'AVAILABLE' then v_reason='CLAIM_CONFLICT';
 elsif v_l.listing_expires_at is not null and v_l.listing_expires_at<=clock_timestamp()
 then v_reason='LISTING_EXPIRED';
 elsif v_ngo.location_verified_at is null then v_reason='ELIGIBILITY_UNDETERMINED';
 elsif public.geolock_ngo_listing_road_check(v_actor,p_listing)->>'outcome'<>'ELIGIBLE'
 then v_reason=public.geolock_ngo_listing_road_check(v_actor,p_listing)->>'outcome';
 elsif v_l.source_type='DIRECT_DONATION' and not exists(
  select 1 from public.donations d where d.donation_id=v_l.donation_id
  and d.donation_status='READY_FOR_PICKUP')
 then v_reason='DONATION_NOT_READY';
 elsif v_l.source_type='HUB_BATCH' and not exists(
  select 1 from public.hub_batches b where b.batch_id=v_l.batch_id and b.batch_status='PUBLISHED')
 then v_reason='BATCH_NOT_PUBLISHED';
 else
  select claim_lease_minutes into v_mins from public.coordination_config where singleton;
  if v_mins is null then raise exception 'CLAIM_LEASE_NOT_CONFIGURED'; end if;
  insert into public.donation_claims(listing_id,ngo_user_id,request_id)
  values(p_listing,v_actor,p_request) returning claim_id into v_claim;
  insert into public.claim_leases(claim_id,expires_at)
  values(v_claim,clock_timestamp()+make_interval(mins=>v_mins))
  returning lease_id into v_lease;
  update public.listings set listing_status='CLAIMED',listing_version=listing_version+1
   where listing_id=p_listing;
  insert into public.pickup_tasks(claim_id,listing_id,ngo_user_id,pickup_road_node_id,load_kg)
  values(v_claim,p_listing,v_actor,v_l.pickup_road_node_id,v_l.listing_weight_kg);
  v_success=true;
 end if;
 v_outcome=case when v_success then 'SUCCESS'
  when v_reason in ('OUTSIDE_GEOFENCE','ROUTE_UNAVAILABLE') then 'INELIGIBLE' else 'CONFLICT' end;
 update public.claim_requests set outcome=v_outcome,result_claim_id=v_claim,
  reason_code=v_reason,completed_at=clock_timestamp() where request_id=p_request;
 insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,
 request_id,claim_id,lease_id,previous_state,requested_state,resulting_state,
 reason_code,outcome,details,configuration_version)
 select v_actor,'NGO','LISTING',p_listing,'CLAIM_ATTEMPT',p_request,v_claim,v_lease,
 v_l.listing_status,'CLAIMED',
 case when v_success then 'CLAIMED' else v_l.listing_status end,v_reason,
 case when v_success then 'SUCCESS' else 'REJECTED' end,
 jsonb_build_object('ngo_id',v_actor),cfg.config_version
 from public.coordination_config cfg where cfg.singleton;
 return jsonb_build_object('outcome',v_outcome,'claim_id',v_claim,
   'reason_code',v_reason,'replayed',false);
end $function$;

-- discover_eligible_listings
CREATE OR REPLACE FUNCTION public.discover_eligible_listings()
 RETURNS TABLE(listing_id uuid, source_type text, listing_weight_kg numeric, listing_created_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare v_actor uuid:=auth.uid();v_ngo public.ngo_profiles%rowtype;
begin
 select * into v_ngo from public.ngo_profiles where user_id=v_actor and active_flag;
 if not found or v_ngo.location_verified_at is null then return; end if;
 return query
 select l.listing_id,l.source_type,l.listing_weight_kg,l.created_at
 from public.listings l join public.coordination_config cfg on cfg.singleton
 where l.listing_status='AVAILABLE'
 and (l.listing_expires_at is null or l.listing_expires_at>clock_timestamp())
 and public.geolock_road_eligible_km(v_ngo.user_id,l.listing_id) is not null
 and ((l.source_type='DIRECT_DONATION' and exists(
   select 1 from public.donations d where d.donation_id=l.donation_id
   and d.donation_status='READY_FOR_PICKUP'))
 or (l.source_type='HUB_BATCH' and exists(
   select 1 from public.hub_batches b where b.batch_id=l.batch_id
   and b.batch_status='PUBLISHED')))
 order by l.created_at desc;
end $function$;

-- discover_eligible_listing_cards
CREATE OR REPLACE FUNCTION public.discover_eligible_listing_cards()
 RETURNS TABLE(listing_id uuid, source_type text, title text, listing_weight_kg numeric, listing_created_at timestamp with time zone, collection_path text, distance_m double precision, routing_status text, primary_image_path text, batch_id uuid, donation_id uuid)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'extensions', 'pg_temp'
AS $function$
declare v_ngo public.ngo_profiles%rowtype;
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  select * into v_ngo from public.ngo_profiles where user_id=auth.uid() and active_flag;
  if not found or v_ngo.location_verified_at is null then return; end if;
  return query
  select l.listing_id,l.source_type,
    case when l.source_type='DIRECT_DONATION' then d.title else 'Community Hub Batch' end,
    l.listing_weight_kg,l.created_at,
    case when l.source_type='DIRECT_DONATION' then d.collection_path else 'HUB_COLLECTION' end,
    public.geolock_road_eligible_km(v_ngo.user_id,l.listing_id)*1000,
    'READY'::text,
    null::text,l.batch_id,l.donation_id
  from public.listings l
  join public.coordination_config cfg on cfg.singleton
  left join public.donations d on d.donation_id=l.donation_id
  left join public.hub_batches b on b.batch_id=l.batch_id
  left join lateral(select i.storage_path from public.donation_images i
    where i.donation_id=d.donation_id and i.display_order=1 limit 1) di on true
  left join lateral(select i.storage_path from public.hub_batch_images i
    where i.batch_id=b.batch_id and i.is_primary limit 1) bi on true
  left join lateral(select i.storage_path from public.hub_batch_members m
    join public.donation_images i on i.donation_id=m.donation_id and i.display_order=1
    join public.donations md on md.donation_id=m.donation_id
    where m.batch_id=b.batch_id and m.membership_status='ACTIVE'
    order by md.created_at,md.donation_id limit 1) member_img on true
  where l.listing_status='AVAILABLE'
    and (l.listing_expires_at is null or l.listing_expires_at>clock_timestamp())
    and public.geolock_road_eligible_km(v_ngo.user_id,l.listing_id) is not null
    and ((l.source_type='DIRECT_DONATION' and d.donation_status='READY_FOR_PICKUP')
      or (l.source_type='HUB_BATCH' and b.batch_status='PUBLISHED'))
  order by l.created_at desc;
end;
$function$;

-- get_eligible_listing_constituents
CREATE OR REPLACE FUNCTION public.get_eligible_listing_constituents(p_listing uuid)
 RETURNS TABLE(donation_id uuid, title text, total_weight_kg numeric, donation_status text, primary_image_path text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'extensions', 'pg_temp'
AS $function$
declare v_ngo public.ngo_profiles%rowtype; v_listing public.listings%rowtype;
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  select * into v_ngo from public.ngo_profiles where user_id=auth.uid() and active_flag;
  if not found or v_ngo.location_verified_at is null then raise exception 'VERIFIED_NGO_ONLY'; end if;
  select l.* into v_listing from public.listings l
  join public.coordination_config cfg on cfg.singleton
  where l.listing_id=p_listing and l.listing_status='AVAILABLE'
    and (l.listing_expires_at is null or l.listing_expires_at>clock_timestamp())
    and public.geolock_road_eligible_km(v_ngo.user_id,l.listing_id) is not null
    and ((l.source_type='DIRECT_DONATION' and exists(select 1 from public.donations d
      where d.donation_id=l.donation_id and d.donation_status='READY_FOR_PICKUP'))
      or (l.source_type='HUB_BATCH' and exists(select 1 from public.hub_batches b
        where b.batch_id=l.batch_id and b.batch_status='PUBLISHED')));
  if not found then raise exception 'LISTING_NOT_ELIGIBLE'; end if;
  return query
  -- Listing photos remain withheld until an approved graph can establish that
  -- discovery eligibility includes trusted road-node validation.
  select d.donation_id,d.title,d.total_weight_kg,d.donation_status,null::text
  from public.donations d
  left join lateral(select x.storage_path from public.donation_images x
    where x.donation_id=d.donation_id and x.display_order=1 limit 1) i on true
  where (v_listing.source_type='DIRECT_DONATION' and d.donation_id=v_listing.donation_id)
     or (v_listing.source_type='HUB_BATCH' and exists(select 1 from public.hub_batch_members m
       where m.batch_id=v_listing.batch_id and m.donation_id=d.donation_id and m.membership_status='ACTIVE'))
  order by d.created_at,d.donation_id;
end;
$function$;

-- can_read_geolock_donation_image
CREATE OR REPLACE FUNCTION public.can_read_geolock_donation_image(p_path text)
 RETURNS boolean
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'extensions', 'pg_temp'
AS $function$
  select auth.uid() is not null and exists(
    select 1 from public.donation_images i
    join public.donations d using(donation_id)
    where i.storage_path=p_path and (
      d.donor_user_id=auth.uid()
      or exists(
        select 1 from public.ngo_profiles n
        join public.coordination_config cfg on cfg.singleton
        join public.listings l on l.donation_id=d.donation_id and l.source_type='DIRECT_DONATION'
        where n.user_id=auth.uid() and n.active_flag and n.location_verified_at is not null
          and exists(select 1 from public.donation_claims c
                left join public.claim_leases le using(claim_id)
                where c.listing_id=l.listing_id and c.ngo_user_id=auth.uid()
                  and (c.claim_status in ('COMPLETED','RECONCILIATION_REQUIRED')
                       or (c.claim_status='ACTIVE' and le.lease_status='ACTIVE' and le.expires_at>clock_timestamp())))
          and public.geolock_road_eligible_km(n.user_id,l.listing_id) is not null
      )
      or exists(
        select 1 from public.ngo_profiles n
        join public.coordination_config cfg on cfg.singleton
        join public.hub_batch_members m on m.donation_id=d.donation_id and m.membership_status='ACTIVE'
        join public.listings l on l.batch_id=m.batch_id and l.source_type='HUB_BATCH'
        join public.hub_batches b on b.batch_id=m.batch_id and b.batch_status='PUBLISHED'
        where n.user_id=auth.uid() and n.active_flag and n.location_verified_at is not null
          and exists(select 1 from public.donation_claims c
                left join public.claim_leases le using(claim_id)
                where c.listing_id=l.listing_id and c.ngo_user_id=auth.uid()
                  and (c.claim_status in ('COMPLETED','RECONCILIATION_REQUIRED')
                       or (c.claim_status='ACTIVE' and le.lease_status='ACTIVE' and le.expires_at>clock_timestamp())))
          and public.geolock_road_eligible_km(n.user_id,l.listing_id) is not null
      )
      or exists(select 1 from public.hub_reservations r
        join public.community_hubs h using(hub_id)
        where r.donation_id=d.donation_id and h.admin_user_id=auth.uid()
          and r.reservation_status='ACTIVE' and r.expires_at>clock_timestamp())
      or exists(select 1 from public.hub_inventory hi
        join public.community_hubs h using(hub_id)
        where hi.donation_id=d.donation_id and h.admin_user_id=auth.uid())
    )
  );
$function$;

-- can_read_geolock_batch_image
CREATE OR REPLACE FUNCTION public.can_read_geolock_batch_image(p_path text)
 RETURNS boolean
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'extensions', 'pg_temp'
AS $function$
  select auth.uid() is not null and exists(
    select 1 from public.hub_batch_images i
    join public.hub_batches b using(batch_id)
    where i.storage_path=p_path and (
      exists(select 1 from public.community_hubs h where h.hub_id=b.hub_id and h.admin_user_id=auth.uid())
      or exists(
        select 1 from public.ngo_profiles n
        join public.coordination_config cfg on cfg.singleton
        join public.listings l on l.batch_id=b.batch_id and l.source_type='HUB_BATCH'
        where n.user_id=auth.uid() and n.active_flag and n.location_verified_at is not null
          and exists(select 1 from public.donation_claims c left join public.claim_leases le using(claim_id)
                where c.listing_id=l.listing_id and c.ngo_user_id=auth.uid()
                  and (c.claim_status in ('COMPLETED','RECONCILIATION_REQUIRED')
                       or (c.claim_status='ACTIVE' and le.lease_status='ACTIVE' and le.expires_at>clock_timestamp())))
          and public.geolock_road_eligible_km(n.user_id,l.listing_id) is not null
      )
    )
  );
$function$;

-- get_my_donation_detail
CREATE OR REPLACE FUNCTION public.get_my_donation_detail(p_donation uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
declare v_result jsonb;
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  if not exists(select 1 from public.donor_profiles dp where dp.user_id=auth.uid())
  then raise exception 'DONOR_ONLY'; end if;
  select jsonb_build_object(
    'donation_id',d.donation_id,'title',d.title,'description',d.description,
    'status',d.donation_status,'donation_status',d.donation_status,
    'collection_path',d.collection_path,'total_weight_kg',d.total_weight_kg,
    'pickup_address',d.pickup_address,'latitude',d.latitude,'longitude',d.longitude,
    'created_at',d.created_at,'updated_at',d.updated_at,
    'availability_start',d.availability_start,'availability_end',d.availability_end,
    'listing_status',l.listing_status,
    'road_node_status',case when l.listing_id is null then null
      when l.pickup_road_node_id is null then case when public.geolock_active_road_snapshot() is null then 'PENDING_NODE' else 'NOT_ROUTABLE' end else 'READY' end,
    'items',coalesce((select jsonb_agg(jsonb_build_object(
      'item_id',i.item_id,'category_id',i.category_id,'category',c.category_name,
      'item_name',i.item_name,'description',i.description,'quantity',i.quantity,
      'unit_label',i.unit_label,'unit_weight_kg',i.unit_weight_kg,
      'item_condition',i.item_condition) order by i.created_at,i.item_id)
      from public.donation_items i join public.donation_categories c using(category_id)
      where i.donation_id=d.donation_id),'[]'::jsonb),
    'hub_reservations',coalesce((select jsonb_agg(jsonb_build_object(
      'reservation_id',r.reservation_id,'hub_id',r.hub_id,'hub_name',h.hub_name,
      'status',r.reservation_status,
      'effective_status',case when r.reservation_status='ACTIVE'
        and r.expires_at<=statement_timestamp() then 'EXPIRED'
        else r.reservation_status end,
      'reserved_weight_kg',r.reserved_weight_kg,'reserved_at',r.reserved_at,
      'expires_at',r.expires_at,'receipt_status',hr.receipt_status,
      'received_weight_kg',hr.received_weight_kg,'received_at',hr.received_at)
      order by r.reserved_at desc,r.reservation_id desc)
      from public.hub_reservations r join public.community_hubs h using(hub_id)
      left join public.hub_receipts hr on hr.reservation_id=r.reservation_id
      where r.donation_id=d.donation_id),'[]'::jsonb)
  ) into v_result
  from public.donations d
  left join public.listings l on l.donation_id=d.donation_id
    and l.source_type='DIRECT_DONATION'
  where d.donation_id=p_donation and d.donor_user_id=auth.uid();
  return v_result;
end;
$function$;

-- get_my_donations
CREATE OR REPLACE FUNCTION public.get_my_donations()
 RETURNS TABLE(donation_id uuid, title text, donation_status text, collection_path text, total_weight_kg numeric, created_at timestamp with time zone, hub_name text, reservation_status text, listing_routing_status text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED';
  end if;
  if not exists (
    select 1 from public.donor_profiles dp where dp.user_id = auth.uid()
  ) then
    raise exception 'DONOR_ONLY';
  end if;

  return query
  select d.donation_id, d.title, d.donation_status, d.collection_path,
    d.total_weight_kg, d.created_at,
    latest.hub_name, latest.reservation_status,
    case
      when l.listing_id is null then null::text
      when l.pickup_road_node_id is null then
        case when public.geolock_active_road_snapshot() is null then 'PENDING_NODE'::text else 'NOT_ROUTABLE'::text end
      else 'READY'::text
    end as listing_routing_status
  from public.donations d
  left join lateral (
    select h.hub_name, r.reservation_status
    from public.hub_reservations r
    join public.community_hubs h using (hub_id)
    where r.donation_id = d.donation_id
    order by r.reserved_at desc
    limit 1
  ) latest on true
  left join public.listings l
    on l.donation_id = d.donation_id
   and l.source_type = 'DIRECT_DONATION'
  where d.donor_user_id = auth.uid()
  order by d.created_at desc, d.donation_id;
end;
$function$;

-- get_eligible_hubs
CREATE OR REPLACE FUNCTION public.get_eligible_hubs(p_donation uuid)
 RETURNS TABLE(hub_id uuid, hub_name text, address_text text, latitude double precision, longitude double precision, capacity_kg numeric, available_capacity_kg numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
declare
  v_donation public.donations%rowtype; v_latest public.hub_reservations%rowtype;
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  select d.* into v_donation
  from public.donations d
  where d.donation_id = p_donation and d.donor_user_id = auth.uid();
  if not found then raise exception 'DONATION_NOT_FOUND_OR_FORBIDDEN'; end if;

  if v_donation.collection_path <> 'HUB_COLLECTION'
     or v_donation.donation_status not in ('SUBMITTED','HUB_ASSIGNED') then
    raise exception 'DONATION_NOT_HUB_ELIGIBLE';
  end if;
  if v_donation.donation_status='HUB_ASSIGNED' then
    select * into v_latest from public.hub_reservations r
    where r.donation_id=p_donation
    order by r.reserved_at desc,r.reservation_id desc limit 1;
    if v_latest.reservation_id is null or exists(select 1 from public.hub_reservations r
        where r.donation_id=p_donation and r.reservation_status in ('RELEASED','CONSUMED'))
      or exists(select 1 from public.hub_reservations r where r.donation_id=p_donation
          and r.reservation_status='EXPIRED' and r.expires_at>clock_timestamp())
      or (select count(*) from public.hub_reservations r
          where r.donation_id=p_donation and r.reservation_status='ACTIVE')>1
      or (v_latest.reservation_status='EXPIRED' and exists(
          select 1 from public.hub_reservations r where r.donation_id=p_donation
            and r.reservation_status='ACTIVE'))
      or not (
      v_latest.reservation_status='EXPIRED'
      or (v_latest.reservation_status='ACTIVE'
          and v_latest.expires_at<=statement_timestamp())
    ) then raise exception 'HUB_RESERVATION_NOT_EXPIRED'; end if;
  end if;
  if exists (select 1 from public.hub_receipts r where r.donation_id=p_donation)
     or exists (select 1 from public.hub_inventory i where i.donation_id=p_donation)
     or exists (select 1 from public.hub_batch_members m
                where m.donation_id=p_donation and m.membership_status='ACTIVE') then
    raise exception 'DONATION_HAS_PHYSICAL_CUSTODY';
  end if;
  if exists (select 1 from public.hub_reservations r
             where r.donation_id=p_donation
               and r.reservation_status='ACTIVE'
               and r.expires_at > statement_timestamp()) then
    raise exception 'HUB_RESERVATION_STILL_ACTIVE';
  end if;

  return query
  with hub_usage as (
    select h.hub_id,
      coalesce((select sum(hr.received_weight_kg)
        from public.hub_inventory hi join public.hub_receipts hr using(donation_id)
        where hi.hub_id=h.hub_id
          and hi.inventory_status in ('STORED','BATCHED','RECONCILIATION_REQUIRED')),0)
      + coalesce((select sum(r.reserved_weight_kg)
        from public.hub_reservations r
        where r.hub_id=h.hub_id and r.reservation_status='ACTIVE'
          and r.expires_at > statement_timestamp()
          and not exists(select 1 from public.hub_receipts hr
                         where hr.reservation_id=r.reservation_id)),0) as used_kg
    from public.community_hubs h
  )
  select h.hub_id,h.hub_name,h.address_text,h.latitude,h.longitude,
         h.capacity_kg,greatest(0,h.capacity_kg-u.used_kg)::numeric
  from public.community_hubs h join hub_usage u using(hub_id)
  join public.geolock_donation_hub_routes(p_donation) rt using(hub_id)
  where h.active_flag
    and u.used_kg+v_donation.total_weight_kg<=h.capacity_kg
    and not exists (
      select 1 from public.donation_items i
      where i.donation_id=p_donation
        and not exists(select 1 from public.hub_accepted_categories a
                       where a.hub_id=h.hub_id and a.category_id=i.category_id)
    )
  order by rt.road_km,h.hub_name;
end;
$function$;


-- 7. Server-side node assignment. Client-supplied node values are overwritten.
create or replace function public.geolock_assign_road_node()
returns trigger
language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
declare v_node text;
begin
  if tg_table_name = 'donations' then
    select node_id into v_node from public.geolock_resolve_road_node(new.latitude, new.longitude);
    new.pickup_road_node_id := v_node;
  elsif tg_table_name = 'listings' then
    select node_id into v_node
      from public.geolock_resolve_road_node(new.pickup_latitude, new.pickup_longitude);
    new.pickup_road_node_id := v_node;
  elsif tg_table_name = 'community_hubs' then
    select node_id into v_node from public.geolock_resolve_road_node(new.latitude, new.longitude);
    new.road_node_id := v_node;
  end if;
  return new;
end $$;

drop trigger if exists trg_donation_road_node on public.donations;
create trigger trg_donation_road_node
  before insert on public.donations
  for each row execute function public.geolock_assign_road_node();

drop trigger if exists trg_listing_road_node on public.listings;
create trigger trg_listing_road_node
  before insert on public.listings
  for each row execute function public.geolock_assign_road_node();

drop trigger if exists trg_hub_road_node on public.community_hubs;
create trigger trg_hub_road_node
  before insert or update of latitude, longitude, road_node_id on public.community_hubs
  for each row execute function public.geolock_assign_road_node();

-- Vehicle depot = owning NGO's verified node (route start/end).
create or replace function public.geolock_assign_vehicle_depot()
returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  select n.road_node_id into new.depot_road_node_id
    from public.ngo_profiles n
   where n.user_id = new.ngo_user_id and n.location_verified_at is not null;
  return new;
end $$;

drop trigger if exists trg_vehicle_depot_node on public.vehicles;
create trigger trg_vehicle_depot_node
  before insert or update of depot_road_node_id, ngo_user_id on public.vehicles
  for each row execute function public.geolock_assign_vehicle_depot();

-- 8. A new or re-noded AVAILABLE listing gets its NGO road eligibility computed.
--    A routing failure never blocks donation creation or batch publication:
--    claim_listing recomputes on demand (geolock_ngo_listing_road_check).
create or replace function public.geolock_listing_eligibility_trigger()
returns trigger
language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
begin
  if new.listing_status = 'AVAILABLE' and (tg_op = 'INSERT'
     or new.pickup_road_node_id is distinct from old.pickup_road_node_id) then
    begin
      perform public.geolock_refresh_listing_road_eligibility(new.listing_id);
    exception when others then
      raise warning 'ROAD_ELIGIBILITY_DEFERRED listing=% sqlstate=%', new.listing_id, sqlstate;
    end;
  end if;
  return null;
end $$;

drop trigger if exists trg_listing_road_eligibility on public.listings;
create trigger trg_listing_road_eligibility
  after insert or update of pickup_road_node_id on public.listings
  for each row execute function public.geolock_listing_eligibility_trigger();

-- 9. Hub reservation requires a usable donor-to-hub route (Algorithm 2 line 8).
create or replace function public.geolock_require_hub_route()
returns trigger
language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
begin
  if new.reservation_status = 'ACTIVE' and not exists (
       select 1 from public.geolock_donation_hub_routes(new.donation_id) r
        where r.hub_id = new.hub_id) then
    raise exception 'ROUTE_UNAVAILABLE';
  end if;
  return new;
end $$;

drop trigger if exists trg_hub_reservation_route on public.hub_reservations;
create trigger trg_hub_reservation_route
  before insert on public.hub_reservations
  for each row execute function public.geolock_require_hub_route();

-- 10. Trusted NGO location verification (service_role / database owner only).
create or replace function public.verify_ngo_location(
  p_ngo uuid, p_verified boolean, p_reason text)
returns jsonb
language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_ngo public.ngo_profiles%rowtype;
  v_node text;
  v_dist double precision;
  v_prev text;
  v_new text;
  v_eligible integer;
begin
  if coalesce(auth.role(), '') <> 'service_role'
     and session_user not in ('postgres', 'supabase_admin') then
    raise exception 'TRUSTED_VERIFIER_ONLY';
  end if;
  if p_ngo is null or p_verified is null then raise exception 'NGO_AND_DECISION_REQUIRED'; end if;
  if nullif(btrim(p_reason), '') is null then raise exception 'VERIFICATION_REASON_REQUIRED'; end if;

  select * into v_ngo from public.ngo_profiles where user_id = p_ngo for update;
  if not found then raise exception 'NGO_NOT_FOUND'; end if;
  v_prev := case when v_ngo.location_verified_at is null then 'UNVERIFIED' else 'VERIFIED' end;

  if p_verified then
    select node_id, snap_distance_m into v_node, v_dist
      from public.geolock_resolve_road_node(v_ngo.latitude, v_ngo.longitude);
    if v_node is null then raise exception 'NGO_LOCATION_NOT_ROUTABLE'; end if;
  end if;
  v_new := case when p_verified then 'VERIFIED' else 'UNVERIFIED' end;

  update public.ngo_profiles
     set location_verified_at = case when p_verified then clock_timestamp() end,
         road_node_id = v_node
   where user_id = p_ngo;
  update public.vehicles set depot_road_node_id = null where ngo_user_id = p_ngo;

  perform public.geolock_refresh_ngo_road_eligibility(p_ngo);
  select count(*) into v_eligible from public.ngo_listing_road_eligibility
   where ngo_user_id = p_ngo and outcome = 'ELIGIBLE';

  insert into public.audit_events(actor_user_id, actor_role, entity_type, entity_id,
    event_type, request_id, previous_state, requested_state, resulting_state,
    reason_code, outcome, details)
  values (null, 'SYSTEM', 'NGO', p_ngo, 'VERIFY_NGO_LOCATION', gen_random_uuid(),
    v_prev, v_new, v_new, p_reason, 'SUCCESS',
    jsonb_build_object('road_node_id', v_node,
                       'snap_distance_m', round(v_dist::numeric, 1),
                       'eligible_open_listings', v_eligible));

  return jsonb_build_object('ngo_user_id', p_ngo, 'location_status', v_new,
    'road_node_id', v_node, 'snap_distance_m', round(v_dist::numeric, 1),
    'eligible_open_listings', v_eligible);
end $$;

-- 11. After approving or replacing a snapshot: re-resolve open records and
--     recompute every stored eligibility row (service_role / owner only).
create or replace function public.geolock_backfill_road_nodes()
returns jsonb
language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
declare v_hubs integer; v_listings integer; v_donations integer; v_ngos integer := 0;
  v_rows integer; r record;
begin
  if coalesce(auth.role(), '') <> 'service_role'
     and session_user not in ('postgres', 'supabase_admin') then
    raise exception 'TRUSTED_OPERATOR_ONLY';
  end if;

  update public.community_hubs set road_node_id = null;   -- trigger re-resolves
  get diagnostics v_hubs = row_count;

  update public.donations d
     set pickup_road_node_id = r2.node_id
    from public.donations d2
    left join lateral public.geolock_resolve_road_node(d2.latitude, d2.longitude) r2 on true
   where d.donation_id = d2.donation_id
     and d.donation_status in ('SUBMITTED','READY_FOR_PICKUP','HUB_ASSIGNED')
     and d.pickup_road_node_id is distinct from r2.node_id;
  get diagnostics v_donations = row_count;

  update public.listings l
     set pickup_road_node_id = r2.node_id
    from public.listings l2
    left join lateral public.geolock_resolve_road_node(l2.pickup_latitude, l2.pickup_longitude) r2 on true
   where l.listing_id = l2.listing_id
     and l.listing_status = 'AVAILABLE'
     and l.pickup_road_node_id is distinct from r2.node_id;
  get diagnostics v_listings = row_count;

  -- Re-check verified NGOs against the new snapshot (verification is kept only
  -- if the stored location still snaps within 500 m).
  for r in select n.user_id, n.latitude, n.longitude from public.ngo_profiles n
            where n.location_verified_at is not null loop
    update public.ngo_profiles
       set road_node_id = (select x.node_id from public.geolock_resolve_road_node(r.latitude, r.longitude) x)
     where user_id = r.user_id;
    update public.vehicles set depot_road_node_id = null where ngo_user_id = r.user_id;
    perform public.geolock_refresh_ngo_road_eligibility(r.user_id);
    v_ngos := v_ngos + 1;
  end loop;
  select count(*) into v_rows from public.ngo_listing_road_eligibility;

  return jsonb_build_object('hubs_rechecked', v_hubs, 'donations_changed', v_donations,
    'listings_changed', v_listings, 'ngos_rechecked', v_ngos, 'eligibility_rows', v_rows);
end $$;

revoke all on function public.geolock_assign_road_node() from public, anon, authenticated;
revoke all on function public.geolock_assign_vehicle_depot() from public, anon, authenticated;
revoke all on function public.geolock_listing_eligibility_trigger() from public, anon, authenticated;
revoke all on function public.geolock_require_hub_route() from public, anon, authenticated;
revoke all on function public.verify_ngo_location(uuid, boolean, text) from public, anon, authenticated;
revoke all on function public.geolock_backfill_road_nodes() from public, anon, authenticated;
grant execute on function public.verify_ngo_location(uuid, boolean, text) to service_role;
grant execute on function public.geolock_backfill_road_nodes() to service_role;

commit;
