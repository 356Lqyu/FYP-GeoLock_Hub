-- Synthetic DEV demonstration evidence only. No physical custody/return proof.
-- SELECT-only inspection inside an explicit READ ONLY transaction; no application RPCs.
\set ON_ERROR_STOP on
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout='15s';
SET LOCAL lock_timeout='2s';
SET LOCAL idle_in_transaction_session_timeout='60s';
SELECT jsonb_build_object('section','identity','observed_at',statement_timestamp(),
 'database',current_database(),'session_user',session_user,'current_user',current_user,
 'transaction_read_only',current_setting('transaction_read_only'),
 'ssl',(SELECT ssl FROM pg_catalog.pg_stat_ssl WHERE pid=pg_backend_pid()));
SELECT current_database()='postgres' AND session_user='postgres' AND current_user='postgres'
 AND current_setting('transaction_read_only')='on'
 AND coalesce((SELECT ssl FROM pg_catalog.pg_stat_ssl WHERE pid=pg_backend_pid()),false)
 AS approved_identity \gset
\if :approved_identity
\else
\echo IDENTITY_OR_READONLY_OR_TLS_GUARD_FAILED
ROLLBACK;
\quit 3
\endif

WITH observed AS (
 SELECT b.route_id,b.ngo_id,b.vehicle_id,b.candidate_id,b.started_at,b.closed_at,r.route_status
 FROM routing_private.bindings b JOIN public.pickup_routes r USING(route_id)
 WHERE b.route_id='7dd2d00a-ff03-4021-994f-155bbfc8e12c'
)
SELECT jsonb_build_object('section','closed_binding','status',CASE WHEN count(*)=1
 AND bool_and(closed_at IS NOT NULL AND route_status='COMPLETED'
 AND ngo_id='8e50bc66-7a8d-4791-bc6b-640682daa496'::uuid
 AND vehicle_id='604d6303-ff33-4cdb-a37a-4442f5005f8f'::uuid
 AND candidate_id='fba83a33-fd32-49fa-a123-a4f1d68908d4'::uuid)
 THEN 'VERIFIED' ELSE 'FAILURE' END,'rows',coalesce(jsonb_agg(to_jsonb(observed)),'[]'::jsonb))
FROM observed;

SELECT jsonb_build_object('section','active_assignments','status',
 CASE WHEN count(*)=0 THEN 'VERIFIED' ELSE 'FAILURE' END,
 'remaining_for_route_or_exact_tasks',count(*),
 'rows',coalesce(jsonb_agg(jsonb_build_object('route_id',a.route_id,'task_id',a.task_id)),'[]'::jsonb))
FROM public.active_task_route_assignments a
WHERE a.route_id='7dd2d00a-ff03-4021-994f-155bbfc8e12c'
 OR a.task_id IN ('74d8a748-7424-4c81-8c31-3aea7fc2b1d3','6581c6a1-4c94-4299-bb60-14ab04f732dc','403430ba-6a5a-4377-a0f7-0a0c5ed5de6a');

WITH observed AS (
 SELECT a.event_id,a.occurred_at,a.entity_type,a.entity_id,a.event_type,
 a.actor_user_id,a.actor_role,a.outcome,a.details->>'assignments_cleared' AS assignments_cleared,
 a.actor_user_id=b.ngo_id AS actor_matches_route_owner
 FROM public.audit_events a JOIN routing_private.bindings b ON b.route_id=a.entity_id
 WHERE a.entity_id='7dd2d00a-ff03-4021-994f-155bbfc8e12c'
 AND a.event_type='CLOSE_COLLECTED_ROUTE'
)
SELECT jsonb_build_object('section','closure_audit','status',CASE WHEN count(*)=1
 AND bool_and(entity_type='ROUTE' AND actor_role='NGO' AND outcome='SUCCESS'
 AND actor_user_id='8e50bc66-7a8d-4791-bc6b-640682daa496'::uuid
 AND actor_matches_route_owner AND assignments_cleared='true')
 THEN 'VERIFIED' ELSE 'FAILURE' END,'event_count',count(*),
 'events',coalesce(jsonb_agg(to_jsonb(observed)),'[]'::jsonb)) FROM observed;
ROLLBACK;
