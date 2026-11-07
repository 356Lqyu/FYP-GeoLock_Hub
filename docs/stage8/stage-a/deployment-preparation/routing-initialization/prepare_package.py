"""Local preparation/validation only. No database or network connection."""
import hashlib
import json
import math
import sys
from pathlib import Path
from uuid import uuid4

ROOT = Path(__file__).resolve().parents[5]
sys.path.insert(0, str(ROOT))
from backend.routing.contract import _solver
from backend.routing.phase_b.models import ExecutionConfig
import ortools

HERE = Path(__file__).resolve().parent
RESULTS = ROOT / 'results/routing-initialization-preparation'

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def save(name, value):
    (HERE / name).write_text(json.dumps(value, indent=2) + '\n', encoding='utf-8')

policy = json.loads((HERE / 'policy.proposed.json').read_text(encoding='utf-8'))
assert set(policy) == {'mandatory','horizon_minutes','dispatch_margin_minutes',
                       'direct_service_minutes','hub_service_minutes','solver','execution'}
assert type(policy['mandatory']) is bool
for key in ('horizon_minutes','dispatch_margin_minutes','direct_service_minutes','hub_service_minutes'):
    value = policy[key]
    assert type(value) in (int, float) and math.isfinite(value) and value >= 0, key
assert 0 < policy['horizon_minutes'] <= 1440
_solver(policy['solver'])
assert set(policy['execution']) == {'fixed_cost_weight','distance_cost_weight','deterministic_seconds_per_pass'}
ExecutionConfig(**policy['execution'])
assert policy['solver']['version'] == ortools.__version__

requests_path = HERE / 'requests.proposed.json'
if requests_path.exists():
    requests = json.loads(requests_path.read_text())
else:
    requests = {'status':'PROPOSED / NOT APPROVED / NOT EXECUTED',
                'project_ref':'rcgyuwiidqvrgbxswhqj',
                'policy_request_id':str(uuid4()),'graph_request_id':str(uuid4()),
                'network_snapshot_id':'OSM-OPS-20261018',
                'speed_profile':'OSM_MAXSPEED_OR_CLASS_DEFAULT_BUILD_188bde7568b4d9eb_DIST5DP_TIME4DP_NO_LIVE_TRAFFIC_PG_REAL_OUTPUT_0',
                'precision_policy':'EXACT_MAX_6_DECIMALS','float_output_profile':'PG_REAL_OUTPUT_0',
                'lock_timeout':'5s','policy_statement_timeout':'30s','graph_statement_timeout':'120s'}
    save('requests.proposed.json',requests)

expected = json.loads((HERE.parent / 'expected-functions.json').read_text())['baseline']
source = (ROOT/'docs/stage8/stage-a/forward-migrations/20261101_routing_authority.sql').read_text()
policy_body = source.split('CREATE FUNCTION public.install_routing_policy(',1)[1].split('AS $$',1)[1].split('$$;',1)[0]
assert hashlib.md5(policy_body.encode()).hexdigest() == expected['public.install_routing_policy(uuid,jsonb)']['md5']
sql_guard = policy_body.split(' IF p_request IS NULL',1)[1].split(" THEN RAISE EXCEPTION 'EXPLICIT_ROUTING_POLICY_REQUIRED';",1)[0]
sql_guard = 'p_request IS NULL' + sql_guard
sql_guard = sql_guard.replace('p_request', "'"+requests['policy_request_id']+"'::uuid").replace('p_body','body')
sql_check = ('-- Read-only evaluation of the verbatim installed-policy source guard, not an RPC call.\n'
             'BEGIN READ ONLY;\nSET LOCAL statement_timeout=\'5s\';\n'
             'WITH proposed(body) AS (VALUES ($policy$'+json.dumps(policy)+'$policy$::jsonb))\n'
             'SELECT NOT ('+sql_guard+') AS sql_policy_guard_pass FROM proposed;\nROLLBACK;\n')
(HERE/'policy-contract-check.readonly.sql').write_text(sql_check,encoding='utf-8')

def operation(name, signature, arguments, timeout):
    spec = expected[signature]
    guard = f"""-- PROPOSED ONLY. Execute only after explicit approval of this exact file/hash/request.
\\set ON_ERROR_STOP on
BEGIN;
SET LOCAL ROLE geolock_graph_worker;
SET LOCAL lock_timeout='{requests['lock_timeout']}';
SET LOCAL statement_timeout='{timeout}';
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
 IF NOT EXISTS(SELECT 1 FROM pg_proc WHERE oid='{signature}'::regprocedure
   AND md5(replace(prosrc,E'\\r\\n',E'\\n'))='{spec['md5']}' AND prosecdef AND provolatile='v'
   AND prorettype='uuid'::regtype AND pg_get_userbyid(proowner)='postgres'
   AND proconfig=ARRAY['search_path=pg_catalog, pg_temp','TimeZone=UTC','extra_float_digits=0']::text[])
 OR NOT has_function_privilege(current_user,'{signature}','EXECUTE')
 THEN RAISE EXCEPTION 'RPC_CONTRACT_DRIFT'; END IF;
END $guard$;
SELECT public.{name}({arguments}) AS {('policy_id' if name=='install_routing_policy' else 'graph_id')};
COMMIT;
"""
    (HERE/(name+'.proposed.sql')).write_text(guard,encoding='utf-8')

operation('install_routing_policy','public.install_routing_policy(uuid,jsonb)',
          "'"+requests['policy_request_id']+"'::uuid, $policy$"+json.dumps(policy,indent=2)+"$policy$::jsonb",requests['policy_statement_timeout'])
operation('freeze_routing_graph','public.freeze_routing_graph(uuid,text,text,text)',
          ', '.join("'"+str(requests[k])+"'"+('::uuid' if k=='graph_request_id' else '::text') for k in
                    ('graph_request_id','network_snapshot_id','speed_profile','precision_policy')),requests['graph_statement_timeout'])

postflight = f"""-- Approved read-only inspector/export identity; NOT the limited graph login.
BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout='30s';
SET LOCAL extra_float_digits=0;
SELECT statement_timestamp(),current_user,current_setting('transaction_read_only');
SELECT policy_id,request_id,body,digest,created_at,
 request_id='{requests['policy_request_id']}'::uuid AS request_matches,
 body=$policy${json.dumps(policy)}$policy$::jsonb AS body_matches,
 digest=encode(sha256(convert_to(body::text,'UTF8')),'hex') AS digest_matches
FROM routing_private.policies ORDER BY created_at;
SELECT *, request_id='{requests['graph_request_id']}'::uuid AND coverage_snapshot='{requests['network_snapshot_id']}' AND
 speed_profile='{requests['speed_profile']}' AND precision_policy='EXACT_MAX_6_DECIMALS'
 AND float_output_profile='PG_REAL_OUTPUT_0' AND node_count=926414 AND edge_count=2145828 AS metadata_matches
FROM routing_private.graphs;
SELECT 'policies' AS relation,count(*) FROM routing_private.policies UNION ALL
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
 SELECT 'audit_events',count(*) FROM public.audit_events;
SELECT tgrelid::regclass AS relation,tgname,tgenabled,pg_get_triggerdef(oid,true)
FROM pg_trigger WHERE NOT tgisinternal AND tgname IN ('routing_graph_freeze','routing_graph_truncate');
SELECT p.oid::regprocedure AS signature,md5(replace(p.prosrc,E'\\r\\n',E'\\n')) AS normalized_md5,
 p.proargnames,p.prosecdef,p.proconfig,pg_get_userbyid(p.proowner) AS owner,
 r.rolname,has_function_privilege(r.oid,p.oid,'EXECUTE') AS can_execute
FROM pg_proc p CROSS JOIN pg_roles r
WHERE p.oid IN ('public.install_routing_policy(uuid,jsonb)'::regprocedure,
 'public.freeze_routing_graph(uuid,text,text,text)'::regprocedure)
AND r.rolname IN ('anon','authenticated','service_role','geolock_graph_worker','geolock_planner','geolock_validator');
SELECT jobname,active FROM cron.job WHERE jobname='geolock-expired-claim-recovery';
ROLLBACK;
"""
# One evidence result avoids MCP retaining only the last of several SELECTs.
queries=[part.strip() for part in postflight.split(';\n') if part.strip().startswith('SELECT ')]
labels=['identity','policies','graphs','counts','freeze_triggers','function_permissions','recovery_jobs']
assert len(queries)==len(labels)
header=postflight.split('SELECT statement_timestamp()',1)[0]
postflight=header+'SELECT jsonb_build_object(\n'+',\n'.join(
    "'"+label+"',(SELECT coalesce(jsonb_agg(to_jsonb(q)),'[]'::jsonb) FROM ("+query+") q)"
    for label,query in zip(labels,queries))+') AS evidence;\nROLLBACK;\n'
(HERE/'postflight.readonly.sql').write_text(postflight,encoding='utf-8')

manifest = json.loads((ROOT/'supabase/road_network/output/manifest.json').read_text())
output_checks = {f: {'sha256':sha(ROOT/'supabase/road_network/output'/f),'expected':h}
                 for f,h in manifest['files'].items()}
assert all(v['sha256']==v['expected'] for v in output_checks.values())
builder = ROOT/'supabase/road_network/build_operational_road_network.py'
validation = {'status':'OFFLINE POLICY CONTRACT PASS; GRAPH APPROVAL PENDING',
 'sql_guard':'Verbatim guard extracted into policy-contract-check.readonly.sql; evaluation recorded separately',
 'python_solver_contract':'PASS','execution_config_contract':'PASS',
 'installed_ortools_version':ortools.__version__, 'policy_file_sha256':sha(HERE/'policy.proposed.json'),
 'source_artifact_hashes':output_checks,'recorded_builder_sha256':manifest['builder']['sha256'],
 'current_builder_sha256':sha(builder),'builder_identity_match':sha(builder)==manifest['builder']['sha256'],
 'source_pbf_sha256':manifest['source']['sha256'],'source_pbf_hash_status':'RECORDED IN MANIFEST; NOT REHASHED',
 'current_dev_directed_reachability':'NOT VERIFIED; MCP HTTP 524; no repeated expensive query',
 'offline_csv_directed_reachability':json.loads((RESULTS/'offline-reachability.json').read_text()) if (RESULTS/'offline-reachability.json').exists() else 'NOT RUN',
 'sql_guard_evaluation':json.loads((RESULTS/'policy-sql-validation.json').read_text())['status'] if (RESULTS/'policy-sql-validation.json').exists() else 'NOT RUN',
 'database_writes_executed':False}
(RESULTS/'approval-validation.json').write_text(json.dumps(validation,indent=2)+'\n',encoding='utf-8')
save('approval-file-hashes.json',{p.name:sha(p) for p in sorted(HERE.iterdir())
                                if p.suffix in ('.json','.sql','.conf','.py','.md','.ps1') and p.name!='approval-file-hashes.json'})
print(json.dumps(validation,indent=2))
