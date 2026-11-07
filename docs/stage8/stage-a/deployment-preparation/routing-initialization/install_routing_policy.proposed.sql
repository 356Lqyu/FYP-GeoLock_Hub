-- PROPOSED ONLY. Execute only after explicit approval of this exact file/hash/request.
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL ROLE geolock_graph_worker;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='30s';
DO $guard$
BEGIN
 IF session_user <> 'geolock_graph_login' OR current_user <> 'geolock_graph_worker'
 OR current_setting('transaction_read_only') <> 'off'
 OR NOT pg_has_role(session_user,'geolock_graph_worker','MEMBER')
 OR pg_has_role(session_user,'geolock_planner','MEMBER')
 OR pg_has_role(session_user,'geolock_validator','MEMBER')
 OR EXISTS(SELECT 1 FROM pg_roles WHERE rolname=session_user AND
    (rolsuper OR rolbypassrls OR rolcreaterole OR rolcreatedb))
 THEN RAISE EXCEPTION 'APPROVED_GRAPH_IDENTITY_REQUIRED'; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_proc WHERE oid='public.install_routing_policy(uuid,jsonb)'::regprocedure
   AND md5(replace(prosrc,E'\r\n',E'\n'))='7b3549f82b239d6c6abbd4a5fee58b4e' AND prosecdef AND provolatile='v'
   AND prorettype='uuid'::regtype AND pg_get_userbyid(proowner)='postgres'
   AND proconfig=ARRAY['search_path=pg_catalog, pg_temp','TimeZone=UTC','extra_float_digits=0']::text[])
 OR NOT has_function_privilege(current_user,'public.install_routing_policy(uuid,jsonb)','EXECUTE')
 THEN RAISE EXCEPTION 'RPC_CONTRACT_DRIFT'; END IF;
END $guard$;
SELECT public.install_routing_policy('0b8db479-20c8-4595-9d41-d831650cba93'::uuid, $policy${
  "mandatory": false,
  "horizon_minutes": 240,
  "dispatch_margin_minutes": 15,
  "direct_service_minutes": 10,
  "hub_service_minutes": 15,
  "solver": {
    "engine": "OR_TOOLS",
    "version": "9.15.6755",
    "time_limit_seconds": 15,
    "workers": 1,
    "seed": 42,
    "first_solution": "PATH_CHEAPEST_ARC",
    "local_search": "GUIDED_LOCAL_SEARCH",
    "tie_break": "TASK_ID_THEN_VEHICLE_ID",
    "timeout_policy": "VALIDATED_INCUMBENT_ONLY"
  },
  "execution": {
    "fixed_cost_weight": 1.0,
    "distance_cost_weight": 1.0,
    "deterministic_seconds_per_pass": 0.25
  }
}$policy$::jsonb) AS policy_id;
COMMIT;
