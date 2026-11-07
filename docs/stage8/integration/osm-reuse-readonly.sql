-- DEV rcgyuwiidqvrgbxswhqj ONLY. SELECT-only; no graph initialization.
-- Coverage and actual counts must agree.
SELECT network_snapshot_id, dataset_kind, active_flag, approved_at,
       max_snap_distance_m, node_count, edge_count, provenance
FROM public.road_network_coverage;

SELECT network_snapshot_id, count(*) AS nodes,
       count(*) FILTER (WHERE active_flag) AS active_nodes,
       count(DISTINCT component_id) AS stored_component_labels,
       min(latitude) AS min_lat, max(latitude) AS max_lat,
       min(longitude) AS min_lon, max(longitude) AS max_lon
FROM public.road_network_nodes GROUP BY network_snapshot_id;

SELECT count(*) AS edges, count(DISTINCT edge_id) AS unique_edge_ids,
       count(*) FILTER (WHERE road_km <= 0 OR travel_minutes <= 0
         OR road_km::text IN ('NaN','Infinity','-Infinity')
         OR travel_minutes::text IN ('NaN','Infinity','-Infinity')) AS invalid_costs
FROM public.road_network_edges;

SELECT count(*) FILTER (WHERE s.osm_node_id IS NULL) AS missing_sources,
       count(*) FILTER (WHERE t.osm_node_id IS NULL) AS missing_targets,
       count(*) FILTER (WHERE s.network_snapshot_id IS DISTINCT FROM t.network_snapshot_id)
         AS cross_snapshot_edges,
       count(*) FILTER (WHERE NOT s.active_flag OR NOT t.active_flag)
         AS inactive_endpoint_edges
FROM public.road_network_edges e
LEFT JOIN public.road_network_nodes s ON s.osm_node_id=e.source_node
LEFT JOIN public.road_network_nodes t ON t.osm_node_id=e.target_node;

SELECT geofence_radius_m FROM public.coordination_config WHERE singleton;

-- Empty before initialization. After an approved manual freeze, expect the
-- selected coverage, approved speed-profile label, matching counts and digest.
SELECT graph_id, coverage_snapshot, content_digest, speed_profile,
       node_count, edge_count, precision_policy, float_output_profile
FROM routing_private.graphs ORDER BY created_at;

SELECT t.tgrelid::regclass AS relation, t.tgname, t.tgenabled,
       pg_get_triggerdef(t.oid) AS definition
FROM pg_trigger t WHERE NOT t.tgisinternal
AND t.tgrelid IN ('public.road_network_nodes'::regclass,
                 'public.road_network_edges'::regclass,
                 'public.road_network_coverage'::regclass);

SELECT tablename,indexname,indexdef FROM pg_indexes
WHERE schemaname='public' AND tablename='road_network_edges';

-- Function definitions only: these SELECTs do not invoke eligibility refresh
-- or graph-freeze functions, which can write despite SELECT call syntax.
SELECT p.oid::regprocedure AS signature, pg_get_functiondef(p.oid) AS definition
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public' AND p.proname IN
 ('geolock_road_costs','geolock_road_eligible_km',
  'geolock_refresh_listing_road_eligibility','freeze_routing_graph',
  'read_frozen_routing_graph','store_routing_matrix');
