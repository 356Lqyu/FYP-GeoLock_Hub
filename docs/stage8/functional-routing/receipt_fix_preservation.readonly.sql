-- READ ONLY: capture immediately before/after the separately approved migration.
-- Compare unrelated-function aggregate, routing evidence, policy/graph and cron.
-- Concurrent application/cron writes can legitimately change row fingerprints;
-- inspect their audits rather than force them to match or pause jobs without approval.
BEGIN READ ONLY; SET LOCAL statement_timeout='10s';
SELECT jsonb_build_object('observed_at',statement_timestamp(),
'unchanged_functions',(SELECT jsonb_build_object('count',count(*),'digest',md5(string_agg(n.nspname||'.'||p.oid::regprocedure::text||pg_get_functiondef(p.oid)||pg_get_userbyid(proowner)||coalesce(proacl::text,'NULL'),E'\n' ORDER BY n.nspname,p.oid::regprocedure::text))) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname IN('public','fleet_private','routing_private') AND p.prokind='f' AND p.oid<>'public.get_my_routing_authorization_receipt(uuid)'::regprocedure),
'claim_leases',(SELECT jsonb_build_object('count',count(*),'digest',md5(string_agg(to_jsonb(l)::text,E'\n' ORDER BY lease_id))) FROM public.claim_leases l),
'recovery_job',(SELECT jsonb_build_object('id',jobid,'active',active,'schedule',schedule,'command',command) FROM cron.job WHERE jobid=3),
'policy',(SELECT jsonb_agg(jsonb_build_object('id',policy_id,'digest',digest)) FROM routing_private.policies),
'graph',(SELECT jsonb_agg(jsonb_build_object('id',graph_id,'digest',content_digest)) FROM routing_private.graphs),
'routing_counts',jsonb_build_object('snapshots',(SELECT count(*) FROM routing_private.snapshots),'candidates',(SELECT count(*) FROM routing_private.candidates),'validations',(SELECT count(*) FROM routing_private.validations),'routes',(SELECT count(*) FROM public.pickup_routes),'assignments',(SELECT count(*) FROM public.active_task_route_assignments))
) AS evidence; ROLLBACK;
