-- GeoLock Hub: READ-ONLY preflight for 20261020_operational_road_node_resolution.sql.
-- Run in the Supabase SQL Editor of the DEV project (rcgyuwiidqvrgbxswhqj).
-- It changes nothing. Every row should show ok = true before the migration is applied.
-- Function bodies are compared without \r (SQL pasted from Windows stores CRLF).

with fn(name, expected, patched) as (values
  ('claim_listing','d909b92ca69be452b0304a0d0f9ee06d','bacffdf27eb54ff7d6aa55b586864d2e'),
  ('discover_eligible_listings','fe05da99ac2ab6112830e8e364d41b83','dd1496b1f208a2bdceaf7848b4a8ffe4'),
  ('discover_eligible_listing_cards','46c74d78e25ee109b10dbff5f62addcb','33edca558aadd00a9b41202d00209d9f'),
  ('get_eligible_listing_constituents','7b61192411e956625cddd2a961b4e73f','9f9edea32a40479536052c37ab543455'),
  ('can_read_geolock_donation_image','1caa7c567220ab5505609873f034a31a','b86eb6c43f15d9d472127c00a0da69cb'),
  ('can_read_geolock_batch_image','ad4a7f01ec4a36112459712cff575276','9370a1d726340a5248ff0145c77efa38'),
  ('get_my_donation_detail','f93bf6c90747ebc0ff7e20e233d0cd9e','2ab3f6f7a72ae45d07bbd1e6eb067d71'),
  ('get_my_donations','7687b5d43e75aa449954b37b5cb76429','bd0724a840d848a700aeaaf85ac0dfd2'),
  ('get_eligible_hubs','f2987fb4e6cef90878073124a106e1e5','073ab402c8a196a36321e459f680c9cb'))
select 'function ' || f.name as check_name,
       coalesce(d.body_md5, 'MISSING') as found,
       coalesce(d.body_md5 in (f.expected, f.patched), false) as ok
  from fn f
  left join lateral (select md5(replace(p.prosrc, E'\r', '')) as body_md5
                       from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname = 'public' and p.proname = f.name limit 1) d on true
union all
select 'extension postgis', coalesce((select extversion from pg_extension where extname = 'postgis'), 'MISSING'),
       exists (select 1 from pg_extension where extname = 'postgis')
union all
select 'extension pgrouting available',
       coalesce((select coalesce(installed_version, 'not enabled, ' || default_version)
                   from pg_available_extensions where name = 'pgrouting'), 'NOT AVAILABLE'),
       exists (select 1 from pg_available_extensions where name = 'pgrouting')
union all
-- An older layout (road_node_id text, from 20261017_stage1_location_and_read_rpcs.sql)
-- makes the new migration stop with OLD_ROAD_NETWORK_TABLES_PRESENT.
-- The table is never referenced directly here: when it does not exist (the normal
-- case) a direct reference would make the whole query fail before it runs.
select 'road_network_nodes layout',
       case when to_regclass('public.road_network_nodes') is null then 'absent (fine)'
            when exists (select 1 from information_schema.columns
                          where table_schema = 'public' and table_name = 'road_network_nodes'
                            and column_name = 'osm_node_id') then 'new layout (fine)'
            else 'OLD layout (from 20261017_stage1_location_and_read_rpcs.sql)' end,
       to_regclass('public.road_network_nodes') is null
       or exists (select 1 from information_schema.columns
                   where table_schema = 'public' and table_name = 'road_network_nodes'
                     and column_name = 'osm_node_id')
union all
select 'old stage1 road triggers',
       coalesce(string_agg(tgname, ', '), 'none'),
       count(*) = 0
  from pg_trigger
 where not tgisinternal
   and tgname in ('trg_listing_validate_road_node', 'trg_nodes_invalidate_listings',
                  'trg_coverage_invalidate_listings')
union all
select 'required columns',
       coalesce(string_agg(t || '.' || c, ', ') filter (where not present), 'all present'),
       bool_and(present)
  from (select t, c, exists (select 1 from information_schema.columns
                              where table_schema = 'public' and table_name = t and column_name = c) as present
          from (values ('donations','pickup_road_node_id'), ('listings','pickup_road_node_id'),
                       ('community_hubs','road_node_id'),
                       ('ngo_profiles','road_node_id'), ('ngo_profiles','location_verified_at'),
                       ('vehicles','depot_road_node_id'),
                       ('coordination_config','geofence_radius_m')) v(t, c)) x
union all
select 'database size', pg_size_pretty(pg_database_size(current_database())),
       pg_database_size(current_database()) < 150 * 1024 * 1024;  -- leaves room for ~300 MB of road data
