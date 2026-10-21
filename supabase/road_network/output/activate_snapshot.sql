-- Approve and activate the imported snapshot, then re-resolve open records.
-- Stops (and changes nothing) if the imported counts differ from manifest.json.
begin;
do $$
declare v_nodes bigint; v_edges bigint;
begin
  select count(*) into v_nodes from public.road_network_nodes where network_snapshot_id = 'OSM-OPS-20261018';
  select count(*) into v_edges from public.road_network_edges e
    join public.road_network_nodes n on n.osm_node_id = e.source_node
   where n.network_snapshot_id = 'OSM-OPS-20261018';
  if v_nodes <> 926414 or v_edges <> 2145828 then
    raise exception 'SNAPSHOT_COUNT_MISMATCH: nodes % of 926414, edges % of 2145828', v_nodes, v_edges;
  end if;
end $$;
update public.road_network_coverage set active_flag = false
 where active_flag and network_snapshot_id <> 'OSM-OPS-20261018';
update public.road_network_coverage
   set approved_at = coalesce(approved_at, clock_timestamp()), active_flag = true
 where network_snapshot_id = 'OSM-OPS-20261018';
commit;
select public.geolock_backfill_road_nodes();
