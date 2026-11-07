-- PREPARED ONLY. One operator-approved read; no snapshot, matrix or business RPC.
\set ON_ERROR_STOP on
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout='15s';
SET LOCAL lock_timeout='2s';
SET LOCAL idle_in_transaction_session_timeout='60s';
SELECT jsonb_build_object('section','identity','observed_at',statement_timestamp(),
 'database',current_database(),'session_user',session_user,'current_user',current_user,
 'read_only',current_setting('transaction_read_only'),
 'ssl',(SELECT ssl FROM pg_stat_ssl WHERE pid=pg_backend_pid()),
 'tls',(SELECT version FROM pg_stat_ssl WHERE pid=pg_backend_pid()));
SELECT 1/CASE WHEN current_database()='postgres' AND session_user='postgres' AND current_user='postgres'
 AND current_setting('transaction_read_only')='on'
 AND coalesce((SELECT ssl FROM pg_stat_ssl WHERE pid=pg_backend_pid()),false) THEN 1 ELSE 0 END AS identity_guard;

SELECT jsonb_build_object('section','ngo_and_policy','ngo',
 (SELECT jsonb_build_object('user_id',n.user_id,'role',u.role,'profile_role',n.role,
 'active',n.active_flag,'depot_node',n.road_node_id,'location_verified_at',n.location_verified_at)
 FROM public.ngo_profiles n JOIN public.user_profiles u ON u.user_id=n.user_id
 WHERE n.user_id='8e50bc66-7a8d-4791-bc6b-640682daa496'),
 'policy',(SELECT jsonb_build_object('policy_id',p.policy_id,'digest',p.digest,
 'horizon_minutes',p.body->'horizon_minutes','dispatch_margin_minutes',p.body->'dispatch_margin_minutes',
 'mandatory',p.body->'mandatory') FROM routing_private.policies p ORDER BY p.created_at DESC,p.policy_id LIMIT 1));

WITH policy AS (SELECT * FROM routing_private.policies ORDER BY created_at DESC,policy_id LIMIT 1)
SELECT jsonb_build_object('section','v3','rows',coalesce(jsonb_agg(jsonb_build_object(
 'vehicle_id',v.vehicle_id,'ngo_id',v.ngo_user_id,'label',v.vehicle_label,
 'active',v.active_flag,'available_for_planning',v.available_for_planning,
 'capacity_kg',v.payload_capacity_kg,'max_duration_min',v.max_route_duration_min,
 'duration_is_240',v.max_route_duration_min=240,
 'duration_within_policy',v.max_route_duration_min<=(p.body->>'horizon_minutes')::numeric,
 'fixed_cost_rm',v.fixed_cost_rm,'distance_cost_rm_per_km',v.distance_cost_rm_per_km,
 'vehicle_type',v.vehicle_type,'vehicle_version',v.vehicle_version,
 'depot_node',v.depot_road_node_id,'ngo_depot_node',n.road_node_id,
 'depot_active',rn.active_flag,'depot_snapshot',rn.network_snapshot_id,
 'open_binding_count',(SELECT count(*) FROM routing_private.bindings b WHERE b.vehicle_id=v.vehicle_id AND b.closed_at IS NULL),
 'held_by_existing_route',fleet_private.vehicle_has_hold(v.vehicle_id))), '[]'))
FROM public.vehicles v JOIN public.ngo_profiles n ON n.user_id=v.ngo_user_id CROSS JOIN policy p
LEFT JOIN public.road_network_nodes rn ON rn.osm_node_id=v.depot_road_node_id::bigint
WHERE v.vehicle_id='604d6303-ff33-4cdb-a37a-4442f5005f8f'
 AND v.ngo_user_id='8e50bc66-7a8d-4791-bc6b-640682daa496';

WITH policy AS (SELECT * FROM routing_private.policies ORDER BY created_at DESC,policy_id LIMIT 1),
observations AS (SELECT t.task_id,routing_private.observe_task(t.task_id) AS o FROM public.pickup_tasks t
 JOIN public.donation_claims c ON c.claim_id=t.claim_id
 WHERE t.ngo_user_id='8e50bc66-7a8d-4791-bc6b-640682daa496' AND c.claim_status='ACTIVE'
 ORDER BY t.task_id LIMIT 101)
SELECT jsonb_build_object('section','active_claims','rows',coalesce(jsonb_agg(jsonb_build_object(
 'task_id',q.task_id,'claim_id',q.o->'claim'->'claim_id','claim_status',q.o->'claim'->'claim_status',
 'task_status',q.o->'task'->'task_status','load_kg',q.o->'task'->'load_kg',
 'lease_status',q.o->'lease'->'lease_status','lease_expires_at',q.o->'lease'->'expires_at',
 'remaining_minutes',round(extract(epoch FROM((q.o->'lease'->>'expires_at')::timestamptz-statement_timestamp()))/60,2),
 'listing_id',q.o->'listing'->'listing_id','listing_status',q.o->'listing'->'listing_status',
 'listing_expires_at',q.o->'listing'->'listing_expires_at','source_type',q.o->'listing'->'source_type',
 'title',(SELECT d.title FROM public.donations d WHERE d.donation_id=(q.o->'listing'->>'donation_id')::uuid),
 'pickup_node',q.o->'task'->'pickup_road_node_id','has_assignment',q.o->'has_route_assignment',
 'source_observations',q.o->'donations',
 'pickup_node_active',(SELECT r.active_flag FROM public.road_network_nodes r WHERE r.osm_node_id=(q.o->'task'->>'pickup_road_node_id')::bigint),
 'pickup_node_snapshot',(SELECT r.network_snapshot_id FROM public.road_network_nodes r WHERE r.osm_node_id=(q.o->'task'->>'pickup_road_node_id')::bigint),
 'window',routing_private.task_window(q.o,statement_timestamp(),p.body),
 'admitted_by_deployed_contract',routing_private.admissible(q.o,'8e50bc66-7a8d-4791-bc6b-640682daa496',statement_timestamp(),p.body),
 'open_cases',(SELECT count(*) FROM public.claim_reconciliation_cases rc WHERE
 (rc.claim_id=(q.o->'claim'->>'claim_id')::uuid OR rc.listing_id=(q.o->'listing'->>'listing_id')::uuid)
 AND rc.case_status IN('OPEN','MANUAL_REVIEW'))) ORDER BY q.task_id),'[]')) FROM observations q CROSS JOIN policy p;

SELECT jsonb_build_object('section','preserved_route_hold',
 'route_status',(SELECT route_status FROM public.pickup_routes WHERE route_id='db1b455e-92d0-4d58-9fa1-5de07d7ab0f9'),
 'v2_open_bindings',(SELECT count(*) FROM routing_private.bindings WHERE vehicle_id='c5c1836c-9d55-4004-8851-0f4ecf6d0f32' AND closed_at IS NULL),
 'assignment_count',(SELECT count(*) FROM public.active_task_route_assignments WHERE route_id='db1b455e-92d0-4d58-9fa1-5de07d7ab0f9'));
ROLLBACK;
