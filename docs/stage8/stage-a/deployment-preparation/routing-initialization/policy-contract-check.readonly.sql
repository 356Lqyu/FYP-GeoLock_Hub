-- Read-only evaluation of the verbatim installed-policy source guard, not an RPC call.
BEGIN READ ONLY;
SET LOCAL statement_timeout='5s';
WITH proposed(body) AS (VALUES ($policy${"mandatory": false, "horizon_minutes": 240, "dispatch_margin_minutes": 15, "direct_service_minutes": 10, "hub_service_minutes": 15, "solver": {"engine": "OR_TOOLS", "version": "9.15.6755", "time_limit_seconds": 15, "workers": 1, "seed": 42, "first_solution": "PATH_CHEAPEST_ARC", "local_search": "GUIDED_LOCAL_SEARCH", "tie_break": "TASK_ID_THEN_VEHICLE_ID", "timeout_policy": "VALIDATED_INCUMBENT_ONLY"}, "execution": {"fixed_cost_weight": 1.0, "distance_cost_weight": 1.0, "deterministic_seconds_per_pass": 0.25}}$policy$::jsonb))
SELECT NOT ('0b8db479-20c8-4595-9d41-d831650cba93'::uuid IS NULL OR body IS NULL OR jsonb_typeof(body->'mandatory') IS DISTINCT FROM 'boolean'
 OR NOT(body?'horizon_minutes' AND body?'dispatch_margin_minutes' AND body?'direct_service_minutes' AND body?'hub_service_minutes')
 OR NOT coalesce(((body->>'horizon_minutes')::numeric>0 AND (body->>'horizon_minutes')::numeric<=1440
 AND (body->>'dispatch_margin_minutes')::numeric>=0 AND (body->>'direct_service_minutes')::numeric>=0
 AND (body->>'hub_service_minutes')::numeric>=0 AND (body->>'horizon_minutes')::numeric<'Infinity'::numeric
 AND (body->>'dispatch_margin_minutes')::numeric<'Infinity'::numeric AND (body->>'direct_service_minutes')::numeric<'Infinity'::numeric
 AND (body->>'hub_service_minutes')::numeric<'Infinity'::numeric),false)
 OR jsonb_typeof(body->'solver') IS DISTINCT FROM 'object'
 OR jsonb_typeof(body->'execution') IS DISTINCT FROM 'object'
) AS sql_policy_guard_pass FROM proposed;
ROLLBACK;
