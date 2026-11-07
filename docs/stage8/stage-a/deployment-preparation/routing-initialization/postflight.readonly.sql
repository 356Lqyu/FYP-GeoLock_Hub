-- Approved read-only inspector/export identity; NOT the limited graph login.
BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout='30s';
SET LOCAL extra_float_digits=0;
SELECT jsonb_build_object(
'identity',(SELECT coalesce(jsonb_agg(to_jsonb(q)),'[]'::jsonb) FROM (SELECT statement_timestamp(),current_user,current_setting('transaction_read_only')) q),
'policies',(SELECT coalesce(jsonb_agg(to_jsonb(q)),'[]'::jsonb) FROM (SELECT policy_id,request_id,body,digest,created_at,
 request_id='0b8db479-20c8-4595-9d41-d831650cba93'::uuid AS request_matches,
 body=$policy${"mandatory": false, "horizon_minutes": 240, "dispatch_margin_minutes": 15, "direct_service_minutes": 10, "hub_service_minutes": 15, "solver": {"engine": "OR_TOOLS", "version": "9.15.6755", "time_limit_seconds": 15, "workers": 1, "seed": 42, "first_solution": "PATH_CHEAPEST_ARC", "local_search": "GUIDED_LOCAL_SEARCH", "tie_break": "TASK_ID_THEN_VEHICLE_ID", "timeout_policy": "VALIDATED_INCUMBENT_ONLY"}, "execution": {"fixed_cost_weight": 1.0, "distance_cost_weight": 1.0, "deterministic_seconds_per_pass": 0.25}}$policy$::jsonb AS body_matches,
 digest=encode(sha256(convert_to(body::text,'UTF8')),'hex') AS digest_matches
FROM routing_private.policies ORDER BY created_at) q),
'graphs',(SELECT coalesce(jsonb_agg(to_jsonb(q)),'[]'::jsonb) FROM (SELECT *, request_id='eb29d74d-d556-4135-b200-a691902cfbba'::uuid AND coverage_snapshot='OSM-OPS-20261018' AND
 speed_profile='OSM_MAXSPEED_OR_CLASS_DEFAULT_BUILD_188bde7568b4d9eb_DIST5DP_TIME4DP_NO_LIVE_TRAFFIC_PG_REAL_OUTPUT_0' AND precision_policy='EXACT_MAX_6_DECIMALS'
 AND float_output_profile='PG_REAL_OUTPUT_0' AND node_count=926414 AND edge_count=2145828 AS metadata_matches
FROM routing_private.graphs) q),
'counts',(SELECT coalesce(jsonb_agg(to_jsonb(q)),'[]'::jsonb) FROM (SELECT 'policies' AS relation,count(*) FROM routing_private.policies UNION ALL
 SELECT 'graphs',count(*) FROM routing_private.graphs UNION ALL
 SELECT 'matrices',count(*) FROM routing_private.matrices UNION ALL
 SELECT 'snapshots',count(*) FROM routing_private.snapshots UNION ALL
 SELECT 'candidates',count(*) FROM routing_private.candidates UNION ALL
 SELECT 'bindings',count(*) FROM routing_private.bindings UNION ALL
 SELECT 'items',count(*) FROM routing_private.items UNION ALL
 SELECT 'validations',count(*) FROM routing_private.validations UNION ALL
 SELECT 'cancelled_stop_history',count(*) FROM routing_private.cancelled_stop_history UNION ALL
 SELECT 'requests',count(*) FROM routing_private.requests UNION ALL
 SELECT 'legacy_inflight',count(*) FROM routing_private.legacy_inflight UNION ALL
 SELECT 'pickup_routes',count(*) FROM public.pickup_routes UNION ALL
 SELECT 'pickup_route_stops',count(*) FROM public.pickup_route_stops UNION ALL
 SELECT 'active_task_route_assignments',count(*) FROM public.active_task_route_assignments UNION ALL
 SELECT 'pickup_tasks',count(*) FROM public.pickup_tasks UNION ALL
 SELECT 'donation_claims',count(*) FROM public.donation_claims UNION ALL
 SELECT 'claim_leases',count(*) FROM public.claim_leases UNION ALL
 SELECT 'donations',count(*) FROM public.donations UNION ALL
 SELECT 'listings',count(*) FROM public.listings UNION ALL
 SELECT 'audit_events',count(*) FROM public.audit_events) q),
'freeze_triggers',(SELECT coalesce(jsonb_agg(to_jsonb(q)),'[]'::jsonb) FROM (SELECT tgrelid::regclass AS relation,tgname,tgenabled,pg_get_triggerdef(oid,true)
FROM pg_trigger WHERE NOT tgisinternal AND tgname IN ('routing_graph_freeze','routing_graph_truncate')) q),
'function_permissions',(SELECT coalesce(jsonb_agg(to_jsonb(q)),'[]'::jsonb) FROM (SELECT p.oid::regprocedure AS signature,md5(replace(p.prosrc,E'\r\n',E'\n')) AS normalized_md5,
 p.proargnames,p.prosecdef,p.proconfig,pg_get_userbyid(p.proowner) AS owner,
 r.rolname,has_function_privilege(r.oid,p.oid,'EXECUTE') AS can_execute
FROM pg_proc p CROSS JOIN pg_roles r
WHERE p.oid IN ('public.install_routing_policy(uuid,jsonb)'::regprocedure,
 'public.freeze_routing_graph(uuid,text,text,text)'::regprocedure)
AND r.rolname IN ('anon','authenticated','service_role','geolock_graph_worker','geolock_planner','geolock_validator')) q),
'recovery_jobs',(SELECT coalesce(jsonb_agg(to_jsonb(q)),'[]'::jsonb) FROM (SELECT jobname,active FROM cron.job WHERE jobname='geolock-expired-claim-recovery') q)) AS evidence;
ROLLBACK;
