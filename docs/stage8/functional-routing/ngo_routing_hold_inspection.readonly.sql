-- One scoped DEV owner-export capture. No application RPCs or row locks.
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

SELECT jsonb_build_object('section','account_comparison','accounts',coalesce(jsonb_agg(jsonb_build_object(
 'user_id',u.id,'email',u.email,'role',p.role,'ngo_profile_present',n.user_id IS NOT NULL,
 'depot_node',n.road_node_id,'location_verified_at',n.location_verified_at,
 'preserved_route_owner',EXISTS(SELECT 1 FROM public.pickup_routes r
 WHERE r.route_id='db1b455e-92d0-4d58-9fa1-5de07d7ab0f9' AND r.ngo_user_id=u.id))), '[]'))
FROM auth.users u LEFT JOIN public.user_profiles p ON p.user_id=u.id
LEFT JOIN public.ngo_profiles n ON n.user_id=u.id
WHERE lower(u.email) IN('testerq@gmail.com','testerq356@gmail.com')
 OR u.id='8e50bc66-7a8d-4791-bc6b-640682daa496';

WITH owners AS (SELECT id FROM auth.users WHERE lower(email) IN('testerq@gmail.com','testerq356@gmail.com')
 UNION SELECT '8e50bc66-7a8d-4791-bc6b-640682daa496'::uuid)
SELECT jsonb_build_object('section','claims_and_tasks','rows',coalesce(jsonb_agg(jsonb_build_object(
 'ngo_id',c.ngo_user_id,'claim_id',c.claim_id,'claim_status',c.claim_status,
 'lease_id',le.lease_id,'lease_status',le.lease_status,'expires_at',le.expires_at,
 'remaining_minutes',round(extract(epoch FROM(le.expires_at-statement_timestamp()))/60,2),
 'covers_255_minutes',le.expires_at>statement_timestamp()+interval '255 minutes',
 'task_id',t.task_id,'task_status',t.task_status,'load_kg',t.load_kg,
 'pickup_node',t.pickup_road_node_id,'node_active',rn.active_flag,'node_snapshot',rn.network_snapshot_id,
 'listing_id',l.listing_id,'listing_status',l.listing_status,'listing_expires_at',l.listing_expires_at,
 'donation_id',d.donation_id,'title',d.title,'donation_status',d.donation_status,
 'assigned_routes',(SELECT coalesce(jsonb_agg(a.route_id),'[]') FROM public.active_task_route_assignments a WHERE a.task_id=t.task_id),
 'open_case_count',(SELECT count(*) FROM public.claim_reconciliation_cases rc
 WHERE (rc.claim_id=c.claim_id OR rc.listing_id=c.listing_id) AND rc.case_status IN('OPEN','MANUAL_REVIEW'))
 ) ORDER BY c.claimed_at DESC),'[]'))
FROM public.donation_claims c JOIN owners o ON o.id=c.ngo_user_id
LEFT JOIN public.claim_leases le ON le.claim_id=c.claim_id
LEFT JOIN public.pickup_tasks t ON t.claim_id=c.claim_id
JOIN public.listings l ON l.listing_id=c.listing_id
LEFT JOIN public.donations d ON d.donation_id=l.donation_id
LEFT JOIN public.road_network_nodes rn ON rn.osm_node_id=t.pickup_road_node_id::bigint;

WITH owners AS (SELECT id FROM auth.users WHERE lower(email) IN('testerq@gmail.com','testerq356@gmail.com')
 UNION SELECT '8e50bc66-7a8d-4791-bc6b-640682daa496'::uuid)
SELECT jsonb_build_object('section','vehicles','rows',coalesce(jsonb_agg(jsonb_build_object(
 'ngo_id',v.ngo_user_id,'vehicle_id',v.vehicle_id,'label',v.vehicle_label,
 'active',v.active_flag,'available_for_planning',v.available_for_planning,
 'capacity_kg',v.payload_capacity_kg,'max_duration_min',v.max_route_duration_min,
 'version',v.vehicle_version,'depot_node',v.depot_road_node_id,'ngo_depot_node',n.road_node_id,
 'location_verified_at',n.location_verified_at,'node_active',rn.active_flag,'node_snapshot',rn.network_snapshot_id,
 'open_bindings',(SELECT coalesce(jsonb_agg(jsonb_build_object('route_id',b.route_id,'version',b.vehicle_version,
 'started_at',b.started_at,'closed_at',b.closed_at)),'[]') FROM routing_private.bindings b WHERE b.vehicle_id=v.vehicle_id AND b.closed_at IS NULL),
 'nonterminal_routes',(SELECT coalesce(jsonb_agg(jsonb_build_object('route_id',r.route_id,'status',r.route_status)),'[]')
 FROM public.pickup_routes r WHERE r.vehicle_id=v.vehicle_id AND r.route_status::text NOT IN('COMPLETED','CANCELLED','STALE','ABANDONED'))
 ) ORDER BY v.vehicle_label),'[]'))
FROM public.vehicles v JOIN owners o ON o.id=v.ngo_user_id
JOIN public.ngo_profiles n ON n.user_id=v.ngo_user_id
LEFT JOIN public.road_network_nodes rn ON rn.osm_node_id=v.depot_road_node_id::bigint;

SELECT jsonb_build_object('section','preserved_route','route',
 (SELECT to_jsonb(r) FROM public.pickup_routes r WHERE r.route_id='db1b455e-92d0-4d58-9fa1-5de07d7ab0f9'),
 'binding',(SELECT jsonb_build_object('ngo_id',b.ngo_id,'candidate_id',b.candidate_id,
 'vehicle_id',b.vehicle_id,'vehicle_version',b.vehicle_version,'departure_at',b.departure_at,
 'started_at',b.started_at,'closed_at',b.closed_at) FROM routing_private.bindings b
 WHERE b.route_id='db1b455e-92d0-4d58-9fa1-5de07d7ab0f9'),
 'items',(SELECT coalesce(jsonb_agg(jsonb_build_object('ordinal',i.ordinal,'task_id',i.task_id,
 'consumed_at',i.consumed_at,'collected_at',i.collected_at,'released_at',i.released_at) ORDER BY i.ordinal),'[]')
 FROM routing_private.items i WHERE i.route_id='db1b455e-92d0-4d58-9fa1-5de07d7ab0f9'));

WITH targets AS (SELECT t.claim_id FROM routing_private.items i JOIN public.pickup_tasks t ON t.task_id=i.task_id
 WHERE i.route_id='db1b455e-92d0-4d58-9fa1-5de07d7ab0f9')
SELECT jsonb_build_object('section','preserved_cases','rows',coalesce(jsonb_agg(jsonb_build_object(
 'case_id',rc.case_id,'claim_id',rc.claim_id,'listing_id',rc.listing_id,'status',rc.case_status)), '[]'))
FROM public.claim_reconciliation_cases rc WHERE rc.claim_id IN(SELECT claim_id FROM targets);

SELECT jsonb_build_object('section','preserved_audit','rows',coalesce(jsonb_agg(to_jsonb(x)),'[]')) FROM (
 SELECT a.occurred_at,a.event_type,a.claim_id,a.lease_id,a.outcome,a.reason_code
 FROM public.audit_events a WHERE a.entity_id='db1b455e-92d0-4d58-9fa1-5de07d7ab0f9'
 OR a.claim_id IN(SELECT t.claim_id FROM routing_private.items i JOIN public.pickup_tasks t ON t.task_id=i.task_id
 WHERE i.route_id='db1b455e-92d0-4d58-9fa1-5de07d7ab0f9')
 ORDER BY a.occurred_at DESC LIMIT 50) x;

WITH owners AS (SELECT id FROM auth.users WHERE lower(email) IN('testerq@gmail.com','testerq356@gmail.com')
 UNION SELECT '8e50bc66-7a8d-4791-bc6b-640682daa496'::uuid)
SELECT jsonb_build_object('section','operation_metadata',
 'snapshots',(SELECT coalesce(jsonb_agg(jsonb_build_object('ngo_id',s.ngo_id,'request_id',s.request_id,
 'snapshot_id',s.snapshot_id,'cutoff',s.cutoff,'sealed',s.sealed_at IS NOT NULL)),'[]') FROM routing_private.snapshots s WHERE s.ngo_id IN(SELECT id FROM owners)),
 'candidates',(SELECT coalesce(jsonb_agg(jsonb_build_object('candidate_id',c.candidate_id,'request_id',c.request_id,
 'snapshot_id',c.snapshot_id,'validation_present',EXISTS(SELECT 1 FROM routing_private.validations v WHERE v.candidate_id=c.candidate_id))),'[]')
 FROM routing_private.candidates c JOIN routing_private.snapshots s ON s.snapshot_id=c.snapshot_id WHERE s.ngo_id IN(SELECT id FROM owners)),
 'receipts',(SELECT coalesce(jsonb_agg(jsonb_build_object('ngo_id',r.ngo_id,'request_id',r.request_id,
 'operation',r.operation,'candidate_id',r.result->'candidate_id','snapshot_id',r.result->'snapshot_id',
 'route_ids',r.result->'route_ids','departure_mode',r.result->'departure_mode')),'[]') FROM routing_private.requests r WHERE r.ngo_id IN(SELECT id FROM owners)));

SELECT jsonb_build_object('section','deployed_functions','rows',jsonb_agg(jsonb_build_object(
 'signature',p.oid::regprocedure::text,'owner',p.proowner::regrole::text,'definer',p.prosecdef,
 'volatility',p.provolatile,'acl',p.proacl::text,'md5',md5(replace(p.prosrc,E'\r\n',E'\n')),
 'definition',pg_get_functiondef(p.oid)))) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public' AND p.proname IN('recover_expired_claims','submit_claim_reconciliation',
 'get_my_reconciliation_cases','get_my_routing_overview','get_my_routing_authorization_receipt','get_my_authorized_route');
ROLLBACK;
