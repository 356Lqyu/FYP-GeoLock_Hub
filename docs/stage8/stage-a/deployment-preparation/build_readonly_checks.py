"""Offline authoring helper. No database clients, credentials, or connections."""
from pathlib import Path
import hashlib
import json
import re

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
STAGE = HERE.parent
FILES = sorted((STAGE / 'forward-migrations').glob('*.sql'))
PINS = [
    'fbe81acd7811e884536ed5bf125fb6b0b5eb71e6bd314872378e68b2da0ec94f',
    '96bc7763a30b7a641d6dc768dda4e255e12d4b9de2a5e52e8979cb0e26d1682f',
    '6541f0a002ea56ad77c023e33ad1500ab2273cc821f87fa43d38e633bd6724ea',
]
assert len(FILES) == 3
for path, pin in zip(FILES, PINS):
    assert hashlib.sha256(path.read_bytes()).hexdigest() == pin, path.name
sources = [p.read_text(encoding='utf-8') for p in FILES]

pattern = re.compile(
    r'CREATE (?:OR REPLACE )?FUNCTION\s+([\w.]+)\((.*?)\)\s*'
    r'RETURNS\s+(.*?)\s+LANGUAGE\s+(.*?)\bAS\s+(\$\w*\$)(.*?)\5\s*;',
    re.S | re.I,
)

def functions(sql):
    result = {}
    for m in pattern.finditer(sql):
        name, args, returns, header, delimiter, body = m.groups()
        types = [re.split(r'\s+', a.strip(), maxsplit=1)[1].split(' DEFAULT ')[0].strip()
                 for a in args.split(',') if a.strip()]
        signature = name + '(' + ','.join(types) + ')'
        configs = []
        for setting in re.finditer(r'\bSET\s+(\w+)\s*(?:=|\bTO\b)\s*(.*?)(?=\s+SET\b|$)', header, re.S | re.I):
            key, value = setting.groups()
            key = 'TimeZone' if key.lower() == 'timezone' else key.lower()
            value = ', '.join(part.strip().strip("'") for part in value.strip().split(','))
            configs.append(key + '=' + value)
        result[signature] = dict(
            signature=signature, md5=hashlib.md5(body.encode()).hexdigest(),
            result=' '.join(returns.split()), security_definer=bool(re.search(r'SECURITY\s+DEFINER', header, re.I)),
            volatility='i' if re.search(r'\bIMMUTABLE\b', header, re.I) else 's' if re.search(r'\bSTABLE\b', header, re.I) else 'v',
            config=configs,
        )
    assert len(result) == len(re.findall(r'CREATE (?:OR REPLACE )?FUNCTION\b', sql, re.I))
    return result

baseline = functions(sources[0]) | functions(sources[1])
post = functions(sources[2])
assert len(baseline) == 28 and len(post) == 17
assert post['routing_private.task_guard()']['md5'] == 'ab3101347fdbd148116c634e6c6132ad'
c3 = (ROOT / 'docs/stage8/stage-c3/RESULTS.md').read_text(encoding='utf-8')
reported = dict(re.findall(r'\| `([^`]+\([^`]*\))` \| `([0-9a-f]{32})`', c3))
assert len(reported) == 28
assert all(reported[sig] == item['md5'] for sig, item in baseline.items())

grants = {}
for sql in sources[:2]:
    for m in re.finditer(r'GRANT EXECUTE ON FUNCTION\s+(.*?)\s+TO\s+(\w+)\s*;', sql, re.S):
        signatures, role = m.groups()
        for sig in re.findall(r'[\w.]+\([^)]*\)', signatures):
            grants.setdefault(sig, set()).add(role)
for sig, item in baseline.items():
    item['grantees'] = sorted({'postgres'} | grants.get(sig, set()))
for sig, item in post.items():
    item['grantees'] = ['postgres'] if sig.startswith('routing_private.') else sorted(['postgres', 'authenticated'] + (['service_role'] if 'submit_claim_reconciliation' in sig else []))

def quote(s):
    return "'" + s.replace("'", "''") + "'"

def function_check(items, label):
    rows = []
    for sig, item in sorted(items.items()):
        configs = 'ARRAY[' + ','.join(map(quote, item['config'])) + ']::text[]'
        acl = 'ARRAY[' + ','.join(map(quote, item['grantees'])) + ']::text[]'
        rows.append(f"({quote(sig)},{quote(item['md5'])},{quote(item['result'])},{str(item['security_definer']).lower()},{quote(item['volatility'])},{configs},{acl})")
    return f"""-- {label}: exact source/metadata/direct EXECUTE ACL; membership checked separately.
WITH expected(signature,body_md5,result_type,definer,volatility,config,grantees) AS (VALUES
{',\n'.join(rows)}
), observed AS (
 SELECT e.*,p.oid,p.prosrc,p.proconfig,p.prosecdef,p.provolatile,
 pg_get_userbyid(p.proowner) AS owner,pg_get_function_result(p.oid) AS actual_result,
 ARRAY(SELECT CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee)::text END
 FROM aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
 WHERE a.privilege_type='EXECUTE' ORDER BY 1) AS actual_grantees,p.proacl::text AS acl
 FROM expected e LEFT JOIN pg_proc p ON p.oid=to_regprocedure(e.signature)
)
SELECT signature,CASE WHEN oid IS NOT NULL AND owner='postgres'
 AND md5(replace(prosrc,E'\\r\\n',E'\\n'))=body_md5 AND actual_result=result_type
 AND prosecdef=definer AND provolatile::text=volatility AND proconfig IS NOT DISTINCT FROM config
 AND actual_grantees=grantees THEN 'PASS' ELSE 'FAIL' END AS status,
 body_md5 AS expected_md5,md5(replace(prosrc,E'\\r\\n',E'\\n')) AS actual_md5,
 owner,actual_result,prosecdef,provolatile,proconfig,actual_grantees,acl
FROM observed ORDER BY signature;
"""

# Exact five-function guard tuples are taken unchanged from 003, not hand-transcribed.
guard_values = re.search(r'FROM \(VALUES\s*(.*?)\) e\(signature,body_md5,config,result_type\)', sources[2], re.S).group(1)
lifecycle = f"""-- P03: migration's five exact lifecycle inputs; the audit helper is separate.
WITH expected(signature,body_md5,config,result_type) AS (VALUES {guard_values})
SELECT e.signature,CASE WHEN p.oid IS NOT NULL AND pg_get_userbyid(p.proowner)='postgres'
 AND p.prosecdef AND p.provolatile='v' AND p.proconfig=ARRAY[e.config]
 AND pg_get_function_result(p.oid)=e.result_type
 AND md5(replace(p.prosrc,E'\\r\\n',E'\\n'))=e.body_md5 THEN 'PASS' ELSE 'FAIL' END AS status,
 e.body_md5 AS expected_md5,md5(replace(p.prosrc,E'\\r\\n',E'\\n')) AS actual_md5,
 p.proconfig,p.proacl::text AS acl
FROM expected e LEFT JOIN pg_proc p ON p.oid=to_regprocedure(e.signature);
SELECT 'six_argument_audit_helper' AS check_name,
 CASE WHEN pg_get_userbyid(p.proowner)='postgres' AND NOT p.prosecdef
 AND p.proconfig=ARRAY['search_path=pg_catalog, public, pg_temp']
 AND pg_get_function_result(p.oid)='void'
 AND md5(replace(p.prosrc,E'\\r\\n',E'\\n'))='67f27a85fb9129c9017bb0e9178f8ba1'
 THEN 'PASS' ELSE 'FAIL' END AS status,p.proacl::text AS acl
FROM (SELECT to_regprocedure('public.geolock_transition_listing_donations(uuid,text,text,uuid,uuid,text)') oid) t
LEFT JOIN pg_proc p USING(oid);
"""
c3sql = (ROOT / 'docs/stage8/stage-c3/READ_ONLY_QUERIES.sql').read_text(encoding='utf-8')
structure = c3sql.split('-- QUERY 2 ')[1].split('-- QUERY 3 ')[0]
structure = '-- P05: reused C.3 Query 2 — full definition comparison, not counts alone.\n-- QUERY 2 ' + structure
privileges = '-- P06: reused scoped effective privileges and membership evidence.\n-- QUERY 3 ' + c3sql.split('-- QUERY 3 ')[1].split('-- QUERY 5 ')[0]
cutover = '-- P07: reused ten aggregate cutover predicates.\n-- QUERY 5 ' + c3sql.split('-- QUERY 5 ')[1].split('-- QUERY 6 ')[0]
cutover += """
-- Active lifecycle summaries: review even when route/dispatch counts are zero.
SELECT task_status::text AS status,count(*) FROM public.pickup_tasks GROUP BY task_status ORDER BY 1;
SELECT claim_status::text AS status,count(*) FROM public.donation_claims GROUP BY claim_status ORDER BY 1;
SELECT lease_status::text AS status,count(*),count(*) FILTER (WHERE expires_at<=statement_timestamp()) AS expired
FROM public.claim_leases GROUP BY lease_status ORDER BY 1;
-- Global counts are comparable only during an agreed writer/deployment pause.
SELECT 'pickup_tasks' AS relation,count(*) FROM public.pickup_tasks
UNION ALL SELECT 'donation_claims',count(*) FROM public.donation_claims
UNION ALL SELECT 'claim_leases',count(*) FROM public.claim_leases
UNION ALL SELECT 'pickup_routes',count(*) FROM public.pickup_routes
UNION ALL SELECT 'pickup_route_stops',count(*) FROM public.pickup_route_stops
UNION ALL SELECT 'active_task_route_assignments',count(*) FROM public.active_task_route_assignments
UNION ALL SELECT 'claim_reconciliation_cases',count(*) FROM public.claim_reconciliation_cases
UNION ALL SELECT 'audit_events',count(*) FROM public.audit_events
UNION ALL SELECT 'donations',count(*) FROM public.donations
UNION ALL SELECT 'listings',count(*) FROM public.listings;
"""

opening = """-- PREPARATION ONLY. DEV rcgyuwiidqvrgbxswhqj. No database execution performed.
-- Confirm Dashboard project ref / credential endpoint OUT OF BAND before connecting.
-- No SQL database name or user-supplied label authenticates a Supabase project.
BEGIN ISOLATION LEVEL READ COMMITTED READ ONLY;
SET LOCAL lock_timeout='2s';
SET LOCAL statement_timeout='30s';
-- P01: identity evidence; execution session must later be postgres/postgres.
SELECT clock_timestamp() AS observed_at,current_database(),current_user,session_user,
 current_setting('transaction_read_only') AS read_only,
 current_setting('transaction_isolation') AS isolation,
 current_setting('server_version') AS server_version,
 current_setting('extra_float_digits') AS extra_float_digits,
 current_setting('TimeZone') AS timezone;
"""
partial = '-- P04: all 14 added signatures must be absent before first 003 installation.\nWITH expected(signature) AS (VALUES\n' + ',\n'.join('(' + quote(sig) + ')' for sig in sorted(post) if sig not in ['public.start_pickup(uuid)', 'public.complete_pickup(uuid,boolean)', 'public.submit_claim_reconciliation(uuid,boolean,uuid)']) + """
)
SELECT signature,to_regprocedure(signature) IS NULL AS must_be_absent FROM expected;
-- Name inventory also detects unexpected overloads/partial helpers; compare baseline names.
SELECT n.nspname,p.proname,p.oid::regprocedure::text AS signature
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='routing_private' OR (n.nspname='public' AND p.proname IN
 ('close_my_collected_route','cancel_my_unstarted_route','get_my_routing_overview','get_my_authorized_route'))
ORDER BY 1,2,3;
"""
common = """-- P08: full application trigger definitions; compare C.1/C.3 evidence.
SELECT n.nspname,c.relname,t.tgname,t.tgenabled,t.tgfoid::regprocedure::text AS function,
 pg_get_triggerdef(t.oid,true) AS definition
FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE NOT t.tgisinternal AND (n.nspname='routing_private' OR (n.nspname='public' AND c.relname IN
 ('pickup_tasks','pickup_routes','pickup_route_stops','active_task_route_assignments',
 'donation_claims','claim_leases','listings','donations','claim_reconciliation_cases')))
ORDER BY 1,2,3;
SELECT nspname,pg_get_userbyid(nspowner) AS owner,nspacl::text,
 obj_description(oid,'pg_namespace') AS comment
FROM pg_namespace WHERE nspname IN ('routing_private','fleet_private');
-- Explicit false required preflight; true required postflight.
SELECT EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid=to_regclass('public.pickup_tasks')
 AND tgname='routing_task_authority') AS authority_trigger_present;
-- Worker presence/attributes; no automatic repair on missing/unexpected roles.
WITH expected(name) AS (VALUES ('geolock_graph_worker'),('geolock_planner'),('geolock_validator'))
SELECT e.name,r.oid IS NOT NULL AS present,r.rolcanlogin,r.rolsuper,r.rolcreatedb,
 r.rolcreaterole,r.rolreplication,r.rolbypassrls
FROM expected e LEFT JOIN pg_roles r ON r.rolname=e.name;
-- Global direct membership edges expose paths beyond the earlier six-role scope.
SELECT pg_get_userbyid(member) AS member,pg_get_userbyid(roleid) AS granted_role,
 inherit_option,set_option,admin_option FROM pg_auth_members ORDER BY 1,2;
-- Audit helper must be inaccessible to all six roles.
WITH expected(name) AS (VALUES ('anon'),('authenticated'),('service_role'),
 ('geolock_graph_worker'),('geolock_planner'),('geolock_validator'))
SELECT e.name,r.oid IS NOT NULL AS present,
 CASE WHEN r.oid IS NULL OR f.oid IS NULL THEN NULL ELSE has_function_privilege(r.oid,f.oid,'EXECUTE') END AS forbidden_execute
FROM expected e LEFT JOIN pg_roles r ON r.rolname=e.name
CROSS JOIN (SELECT to_regprocedure('public.geolock_transition_listing_donations(uuid,text,text,uuid,uuid,text)') oid) f;
-- P09: inherited table/column writes; every returned forbidden_write must be false.
SELECT r.rolname,c.oid::regclass::text AS relation,
 (has_table_privilege(r.oid,c.oid,'INSERT,UPDATE,DELETE,TRUNCATE')
 OR has_any_column_privilege(r.oid,c.oid,'INSERT,UPDATE')) AS forbidden_write
FROM pg_roles r CROSS JOIN pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE (r.rolname IN ('anon','authenticated') AND n.nspname='public'
 AND c.relname IN ('pickup_tasks','pickup_routes','pickup_route_stops','active_task_route_assignments'))
OR (r.rolname IN ('anon','authenticated','service_role','geolock_graph_worker','geolock_planner','geolock_validator')
 AND n.nspname='routing_private' AND c.relkind='r') ORDER BY 1,2;
-- P10: policy and spatial inventory. 003 has no direct spatial-version guard.
SELECT count(*) AS singleton_rows,bool_and(claim_lease_minutes=360 AND donation_direct_min_kg=10
 AND geofence_radius_m=20000) AS policy_matches FROM public.coordination_config WHERE singleton;
SELECT e.extname,e.extversion,n.nspname AS schema FROM pg_extension e
JOIN pg_namespace n ON n.oid=e.extnamespace WHERE e.extname IN ('postgis','pgrouting');
SELECT p.oid::regprocedure::text AS signature,pg_get_function_result(p.oid) AS result,
 p.provolatile FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='extensions' AND p.proname='pgr_dijkstracost' ORDER BY 1;
-- Catalog seal observation only: no SECURITY DEFINER application function invoked.
SELECT pg_get_userbyid(p.proowner) AS owner,p.prosecdef,p.provolatile,p.proconfig,p.proacl::text,
 md5(replace(p.prosrc,E'\\r\\n',E'\\n')) AS body_md5
FROM pg_proc p WHERE p.oid=to_regprocedure('fleet_private.installation_fingerprint()');
-- P11: history discovery only. Missing ledger is UNKNOWN, not "never applied".
SELECT to_regclass('supabase_migrations.schema_migrations') AS application_ledger,
 EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='supabase_migrations'
 AND table_name='schema_migrations' AND column_name='version') AS has_version,
 EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='supabase_migrations'
 AND table_name='schema_migrations' AND column_name='name') AS has_name;
"""
effective = """-- Effective function EXECUTE matrix; compare allowed roles in expected-functions.json.
WITH functions AS (SELECT p.oid,n.nspname,p.proname FROM pg_proc p
 JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='routing_private'
 OR (n.nspname='public' AND p.proname IN
 ('start_pickup','complete_pickup','submit_claim_reconciliation','close_my_collected_route',
 'cancel_my_unstarted_route','get_my_routing_overview','get_my_authorized_route')))
SELECT f.oid::regprocedure::text AS signature,r.rolname,has_function_privilege(r.oid,f.oid,'EXECUTE') AS can_execute
FROM functions f CROSS JOIN pg_roles r WHERE r.rolname IN ('anon','authenticated','service_role',
 'geolock_graph_worker','geolock_planner','geolock_validator') ORDER BY 1,2;
"""
(HERE / 'preflight.sql').write_text(opening + function_check(baseline,'P02: 28 reviewed 001/002 functions') + lifecycle + partial + structure + privileges + cutover + common + effective + '\nROLLBACK;\n', encoding='utf-8')
(HERE / 'postflight.sql').write_text(opening + function_check(post,'POST01: all 17 exact 003 function bodies and metadata') + function_check(baseline,'POST02: 28 preserved 001/002 functions') + structure + privileges + cutover + common + effective + """
-- POST03: preserved source functions (must match preflight).
SELECT p.oid::regprocedure::text AS signature,md5(replace(p.prosrc,E'\\r\\n',E'\\n')) AS body_md5,
 p.proconfig,p.proacl::text FROM pg_proc p WHERE p.oid IN
 (to_regprocedure('public.claim_listing(uuid,uuid)'),to_regprocedure('public.recover_expired_claims(integer)'),
 to_regprocedure('public.geolock_transition_listing_donations(uuid,text,text,uuid,uuid,text)'));
-- POST04: exact authority trigger identity, event and enabled mode.
SELECT t.tgenabled,t.tgtype,t.tgfoid::regprocedure::text AS function,pg_get_triggerdef(t.oid,true) AS definition
FROM pg_trigger t WHERE t.tgrelid=to_regclass('public.pickup_tasks') AND t.tgname='routing_task_authority';
ROLLBACK;
""", encoding='utf-8')
(HERE / 'expected-functions.json').write_text(json.dumps(dict(baseline=baseline,post003=post),indent=2)+'\n',encoding='utf-8')
manifest = {'target_project':'rcgyuwiidqvrgbxswhqj','status':'PREPARATION_ONLY_NOT_EXECUTED',
 'migration':str(FILES[2].relative_to(ROOT)), 'migration_sha256':PINS[2],
 'generated':{name:hashlib.sha256((HERE/name).read_bytes()).hexdigest() for name in ['preflight.sql','postflight.sql','expected-functions.json','RUNBOOK.md','DIRECT_DEV_DECISION.md','BACKUP_AND_RECOVERY.md','POST_DEPLOYMENT_TESTS.md','POSTDEPLOYMENT_ASSESSMENT.md','ROUTING_INITIALIZATION_PROCEDURE.md','ACTION_SEQUENCE.md','BACKUP_OPERATOR_STEPS.md','FINAL_DEPLOYMENT_CHECKPOINT.md','EXECUTION_APPROVAL.md','backup_pre003.ps1','backup_native_arguments.ps1','validate_backup_arguments.ps1','backup_argv_probe.py','offline_service_validation.conf','build_readonly_checks.py']}}
(HERE/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n',encoding='utf-8')
print('Offline generation PASS: 28 baseline hashes agree with C.3; 17 post-003 functions parsed; 3 source SHA-256 pins unchanged. No SQL executed.')
