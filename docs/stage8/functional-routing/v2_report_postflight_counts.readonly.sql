-- Optional operator-run completion of private counts not exposed by NGO RPCs.
-- Supabase DEV rcgyuwiidqvrgbxswhqj, postgres role; SELECT-only, no evidence writes.
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout='15s';
SET LOCAL lock_timeout='2s';
SET LOCAL idle_in_transaction_session_timeout='60s';
SELECT current_database(),current_user,session_user,
 current_setting('transaction_read_only') AS read_only,statement_timestamp() AS observed_at;
SELECT count(*) AS v2_resolution_cases FROM resolution_private.cases
 WHERE route_id='db1b455e-92d0-4d58-9fa1-5de07d7ab0f9';
SELECT case_id,route_id,version,status FROM resolution_private.cases
 WHERE case_id='075e845c-9e00-4821-b36e-3f16d8c743ce';
SELECT
 (SELECT count(*) FROM resolution_private.items WHERE case_id='075e845c-9e00-4821-b36e-3f16d8c743ce') AS items,
 (SELECT count(*) FROM resolution_private.evidence WHERE case_id='075e845c-9e00-4821-b36e-3f16d8c743ce') AS statements,
 (SELECT count(*) FROM resolution_private.requests
  WHERE actor_key='user:8e50bc66-7a8d-4791-bc6b-640682daa496'
  AND request_id='02e2c3eb-c715-4a29-b822-03342784ae19' AND operation='REPORT'
  AND result->>'case_id'='075e845c-9e00-4821-b36e-3f16d8c743ce') AS matching_report_receipts;
SELECT r.route_id,r.route_status,b.closed_at,
 (SELECT count(*) FROM public.active_task_route_assignments a WHERE a.route_id=r.route_id) AS assignments,
 fleet_private.vehicle_has_hold(r.vehicle_id) AS vehicle_held
 FROM public.pickup_routes r JOIN routing_private.bindings b USING(route_id)
 WHERE r.route_id IN('db1b455e-92d0-4d58-9fa1-5de07d7ab0f9','7dd2d00a-ff03-4021-994f-155bbfc8e12c');
ROLLBACK;
