-- Existing DEV route only. Run using the approved owner-export profile.
-- SELECTs/catalog reads only; no application write RPC, locks or recovery calls.
\set ON_ERROR_STOP on
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout='15s';
SELECT statement_timestamp() AS observed_at,current_database(),session_user,
 current_setting('transaction_read_only') AS read_only,
 (SELECT ssl FROM pg_stat_ssl WHERE pid=pg_backend_pid()) AS ssl;

SELECT r.route_id,r.route_status,r.vehicle_id,r.validation_reference,
 b.ngo_id,b.candidate_id,b.departure_at,b.started_at,b.closed_at,
 b.vehicle_version,v.vehicle_version AS current_vehicle_version,
 v.vehicle_label,v.active_flag,v.available_for_planning,
 s.snapshot_id,s.cutoff,s.body->'policy'->>'horizon_minutes' AS horizon_minutes,
 s.body->'policy'->>'dispatch_margin_minutes' AS dispatch_margin_minutes
FROM routing_private.bindings b JOIN public.pickup_routes r USING(route_id)
JOIN public.vehicles v ON v.vehicle_id=b.vehicle_id
JOIN routing_private.candidates c ON c.candidate_id=b.candidate_id
JOIN routing_private.snapshots s ON s.snapshot_id=c.snapshot_id
WHERE b.route_id='db1b455e-92d0-4d58-9fa1-5de07d7ab0f9';

SELECT i.ordinal,d.title,i.task_id,t.claim_id,t.task_status,c.claim_status,
 le.lease_status,le.expires_at,
 round(extract(epoch FROM(le.expires_at-statement_timestamp()))/60,2) AS remaining_minutes,
 l.listing_status,l.listing_expires_at,d.donation_status,
 i.consumed_at,i.collected_at,i.released_at,
 EXISTS(SELECT 1 FROM public.active_task_route_assignments a
   WHERE a.task_id=i.task_id AND a.route_id=i.route_id) AS assigned_to_this_route
FROM routing_private.items i JOIN public.pickup_tasks t USING(task_id)
JOIN public.donation_claims c USING(claim_id) JOIN public.claim_leases le USING(claim_id)
JOIN public.listings l ON l.listing_id=c.listing_id
LEFT JOIN public.donations d ON d.donation_id=l.donation_id
WHERE i.route_id='db1b455e-92d0-4d58-9fa1-5de07d7ab0f9' ORDER BY i.ordinal;

SELECT rc.case_id,rc.claim_id,rc.listing_id,rc.case_status
FROM public.claim_reconciliation_cases rc
WHERE rc.claim_id IN(SELECT t.claim_id FROM routing_private.items i
 JOIN public.pickup_tasks t USING(task_id)
 WHERE i.route_id='db1b455e-92d0-4d58-9fa1-5de07d7ab0f9')
 OR rc.listing_id IN(SELECT t.listing_id FROM routing_private.items i
 JOIN public.pickup_tasks t USING(task_id)
 WHERE i.route_id='db1b455e-92d0-4d58-9fa1-5de07d7ab0f9');

SELECT a.occurred_at,a.event_type,a.claim_id,a.lease_id,a.outcome,a.reason_code,
 a.requested_state,a.resulting_state
FROM public.audit_events a
WHERE a.entity_id='db1b455e-92d0-4d58-9fa1-5de07d7ab0f9'
 OR a.claim_id IN(SELECT t.claim_id FROM routing_private.items i
 JOIN public.pickup_tasks t USING(task_id)
 WHERE i.route_id='db1b455e-92d0-4d58-9fa1-5de07d7ab0f9')
ORDER BY a.occurred_at DESC LIMIT 50;

SELECT jobid,jobname,schedule,active FROM cron.job
WHERE jobname='geolock-expired-claim-recovery';
SELECT pg_get_functiondef('public.get_my_reconciliation_cases()'::regprocedure)
 AS reconciliation_reader_definition;
ROLLBACK;
