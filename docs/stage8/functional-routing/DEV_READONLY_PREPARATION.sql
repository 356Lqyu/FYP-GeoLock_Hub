-- Operator-run routing inputs inspection using the existing approved psql profile.
-- No authentication investigation, graph computation, full export or mutations.
\set ON_ERROR_STOP on
BEGIN READ ONLY;
SET LOCAL statement_timeout='10s';
SELECT jsonb_build_object('observed_at',statement_timestamp(),'read_only',current_setting('transaction_read_only'),
 'policies',(SELECT coalesce(jsonb_agg(jsonb_build_object('policy_id',policy_id,'request_id',request_id,'body',body,'digest',digest)),'[]') FROM routing_private.policies),
 'graphs',(SELECT coalesce(jsonb_agg(to_jsonb(g)),'[]') FROM routing_private.graphs g),
 'coverage',(SELECT coalesce(jsonb_agg(to_jsonb(c)-'coverage_area'),'[]') FROM public.road_network_coverage c),
 'worker_roles',(SELECT jsonb_agg(jsonb_build_object('role',rolname,'login',rolcanlogin,'superuser',rolsuper,'bypassrls',rolbypassrls))
   FROM pg_roles WHERE rolname IN ('geolock_graph_login','geolock_planner_login','geolock_validator_login')),
 'recovery',(SELECT jsonb_agg(jsonb_build_object('jobname',jobname,'active',active)) FROM cron.job WHERE jobname='geolock-expired-claim-recovery')) AS preparation;
-- Small key lookup only. These diagnostic nodes do not make expired claims eligible.
SELECT osm_node_id,network_snapshot_id,active_flag FROM public.road_network_nodes
WHERE osm_node_id IN (1755847853,2308277456,5735535080) ORDER BY osm_node_id;
ROLLBACK;
