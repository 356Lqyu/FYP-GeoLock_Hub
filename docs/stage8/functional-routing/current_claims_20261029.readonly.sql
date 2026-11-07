-- DEV rcgyuwiidqvrgbxswhqj, approved owner-export service only. No application RPC.
\set ON_ERROR_STOP on
BEGIN READ ONLY;
SET LOCAL statement_timeout='15s';
SELECT statement_timestamp() AS observed_at,current_database(),session_user,
 current_setting('transaction_read_only') AS read_only,
 (SELECT ssl FROM pg_stat_ssl WHERE pid=pg_backend_pid()) AS ssl;
-- ALL current ACTIVE claims; admitted records still require the overview/planner.
SELECT d.title,c.claim_id,c.claim_status,le.lease_status,t.task_id,t.task_status,
 t.load_kg,l.listing_id,l.listing_status,d.donation_status,
 d.pickup_address,l.pickup_latitude,l.pickup_longitude,t.pickup_road_node_id,
 le.expires_at,round(extract(epoch FROM(le.expires_at-statement_timestamp()))/60,2) AS remaining_minutes,
 le.expires_at>statement_timestamp()+interval '255 minutes' AS covers_strict_255_minutes,
 l.listing_expires_at,
 EXISTS(SELECT 1 FROM public.active_task_route_assignments a WHERE a.task_id=t.task_id) AS assigned,
 rn.active_flag AS node_active,rn.network_snapshot_id,
 g.graph_id,g.content_digest,
 (SELECT count(*) FROM public.claim_reconciliation_cases rc WHERE (rc.claim_id=c.claim_id OR rc.listing_id=c.listing_id)
   AND rc.case_status IN('OPEN','MANUAL_REVIEW')) AS unresolved_cases
FROM public.donation_claims c JOIN public.claim_leases le USING(claim_id)
JOIN public.pickup_tasks t USING(claim_id) JOIN public.listings l ON l.listing_id=c.listing_id
LEFT JOIN public.donations d ON d.donation_id=l.donation_id
LEFT JOIN public.road_network_nodes rn ON rn.osm_node_id=t.pickup_road_node_id::bigint
LEFT JOIN routing_private.graphs g ON g.graph_id='eab1f7ee-a8e0-4bed-a0e1-2c4bff024936'
 AND rn.network_snapshot_id=g.coverage_snapshot
WHERE c.ngo_user_id='8e50bc66-7a8d-4791-bc6b-640682daa496' AND c.claim_status='ACTIVE'
ORDER BY c.claimed_at DESC,c.claim_id;
SELECT v.vehicle_id,v.vehicle_label,v.payload_capacity_kg,v.max_route_duration_min,
 v.active_flag,v.available_for_planning,v.depot_road_node_id,n.location_verified_at,
 n.road_node_id AS ngo_depot_node,rn.active_flag AS depot_node_active,rn.network_snapshot_id,
 EXISTS(SELECT 1 FROM public.pickup_routes r WHERE r.vehicle_id=v.vehicle_id
   AND r.route_status NOT IN('COMPLETED','CANCELLED','STALE')) AS has_nonterminal_route,
 EXISTS(SELECT 1 FROM routing_private.bindings b WHERE b.vehicle_id=v.vehicle_id AND b.closed_at IS NULL) AS has_open_binding
FROM public.vehicles v JOIN public.ngo_profiles n ON n.user_id=v.ngo_user_id
LEFT JOIN public.road_network_nodes rn ON rn.osm_node_id=v.depot_road_node_id::bigint
WHERE v.ngo_user_id='8e50bc66-7a8d-4791-bc6b-640682daa496' ORDER BY v.vehicle_label;
-- Historical expiry is not the current reclaimed claim: keep UUIDs distinct.
SELECT d.title,c.claim_id,c.claim_status,c.close_reason,le.lease_status,le.release_reason,
 le.expires_at,a.occurred_at,a.outcome,a.reason_code
FROM public.donation_claims c JOIN public.claim_leases le USING(claim_id)
JOIN public.listings l USING(listing_id) LEFT JOIN public.donations d USING(donation_id)
LEFT JOIN public.audit_events a ON a.claim_id=c.claim_id AND a.lease_id=le.lease_id AND a.event_type='LEASE_RECOVERY'
WHERE c.ngo_user_id='8e50bc66-7a8d-4791-bc6b-640682daa496'
 AND le.expires_at<=statement_timestamp() ORDER BY le.expires_at,c.claim_id;
SELECT policy_id,body->>'horizon_minutes' AS horizon_minutes,
 body->>'dispatch_margin_minutes' AS margin_minutes FROM routing_private.policies
WHERE policy_id='80db858b-93e8-4a0a-94e2-dbe14940f0a1';
SELECT graph_id,coverage_snapshot,content_digest FROM routing_private.graphs
WHERE graph_id='eab1f7ee-a8e0-4bed-a0e1-2c4bff024936';
SELECT snapshot_id,request_id,cutoff FROM routing_private.snapshots
WHERE request_id='20a8b059-63fc-40b6-bea9-0751ef1a199b';
SELECT count(*) AS owner_authorization_receipts FROM routing_private.requests
WHERE ngo_id='8e50bc66-7a8d-4791-bc6b-640682daa496';
SELECT route_id,route_status,vehicle_id FROM public.pickup_routes
WHERE ngo_user_id='8e50bc66-7a8d-4791-bc6b-640682daa496';
ROLLBACK;
