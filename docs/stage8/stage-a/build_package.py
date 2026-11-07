"""Build review-only forward SQL from preserved routing proposals and 20261031.

Standard library only. No SQL executor, subprocess, network or credential loading.
Historical proposals, source migrations, live guards and evidence are read only.
"""
from pathlib import Path
import hashlib
import json
import re

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
OLD = ROOT / 'docs/stage8/integration'
CURRENT = ROOT / 'supabase/migrations/20261031_claim_audit_and_failure_capture.sql'
OUTPUTS = ('20261101_routing_authority.sql', '20261102_routing_publication.sql',
           '20261103_routing_pickup_and_reconciliation.sql')
PAT = re.compile(r'CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION\s+([\w.]+)\s*'
                 r'\((.*?)\)\s*(.*?)\bAS\s+(\$\w*\$)(.*?)\4\s*;', re.I | re.S)
# Reviewed local source expectations, NOT adopted DEV fingerprints.
PINS = {
    'start_pickup': 'e89b650c83713b04e8310f4c372f10f4',
    'complete_pickup': 'ae1b885377292281da17951cb18afd55',
    'submit_claim_reconciliation': '246a33d552da2ac4e229fa79c357d194',
    'recover_expired_claims': '89e01f42d5ec23bfcbcdc47c1f4fd4e5',
    'claim_listing': '2c1f60c876797c61b44b3cb43591bab8',
}
PROTECTED = [CURRENT, ROOT/'supabase/migrations/20261027_persisted_donation_lifecycle.sql',
    ROOT/'supabase/migrations/20261030_fix_claim_recovery_unresolved_reconciliation.sql',
    *(OLD/name for name in ('001_authority_proposal.sql','002_publication_proposal.sql',
      '003_pickup_enforcement_proposal.sql','build_legacy.py','package-manifest.json',
      'expected-lifecycle-source-hashes.json','dev-preparation-evidence.json')),
    *(OLD/'reconciliation'/name for name in ('build_proposal.py','compatibility_prefix.sql',
      '003_with_reconciliation_proposal.sql','003_reconciliation_compatibility_proposal.sql',
      'proposal-manifest.json')),
    ROOT/'supabase/tests/claim_e2e_contract.py',
    ROOT/'supabase/tests/review-only/stage3j/live_evidence.json',
    ROOT/'supabase/tests/review-only/stage3j/two_actor/approved_functions.json',
    ROOT/'frontend/geolock_hub_app/lib/donation_pages.dart']


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def md5(body):
    return hashlib.md5(body.replace('\r\n', '\n').encode()).hexdigest()


def function(sql, name):
    matches = [m for m in PAT.finditer(sql) if m[1].lower() == name.lower()]
    if len(matches) != 1:
        raise ValueError('EXACT_FUNCTION_REQUIRED: ' + name)
    return matches[0]


def quote(value):
    return "'" + value.replace("'", "''") + "'"


def source_guard(source, *, first=False):
    rows = []
    for name in PINS:
        m = function(source, 'public.' + name)
        if md5(m[5]) != PINS[name]:
            raise ValueError('REVIEWED_20261031_SOURCE_DRIFT: ' + name)
        types = [arg.strip().split()[1] for arg in m[2].split(',')]
        signature = 'public.' + name + '(' + ','.join(types) + ')'
        path = re.search(r'SET search_path TO (.*)', m[3])[1].strip()
        path = 'search_path=' + ', '.join(v.strip().strip("'") for v in path.split(','))
        result = re.search(r'RETURNS\s+(\w+)', m[3], re.I)[1].lower()
        rows.append('  (' + ','.join(map(quote, (signature, PINS[name], path, result))) + ')')
    absent = " IF to_regnamespace('routing_private') IS NOT NULL THEN RAISE EXCEPTION 'ROUTING_INSTALL_EXISTS_REVIEW_VERSION_INSTEAD_OF_REPLAY'; END IF;\n" if first else ''
    # The unchanged legacy assignment entry point retains its original exact DDL pin.
    assignment_pin = json.loads((OLD/'expected-lifecycle-source-hashes.json').read_text())['assign_task_to_route']
    assignment_guard = ''' IF encode(sha256(convert_to(pg_get_functiondef('public.assign_task_to_route(uuid,uuid,integer)'::regprocedure),'UTF8')),'hex')
 IS DISTINCT FROM ''' + quote(assignment_pin) + ''' THEN RAISE EXCEPTION 'ASSIGNMENT_SOURCE_DRIFT'; END IF;
'''
    if not first:
        replaced=function((OLD/'002_publication_proposal.sql').read_text(),'public.assign_task_to_route')
        assignment_guard=''' IF NOT EXISTS(SELECT 1 FROM pg_proc p
 WHERE p.oid=to_regprocedure('public.assign_task_to_route(uuid,uuid,integer)')
 AND p.proowner='postgres'::regrole AND p.prosecdef
 AND p.proconfig=ARRAY['search_path=pg_catalog, pg_temp', 'TimeZone=UTC', 'extra_float_digits=0']
 AND md5(replace(p.prosrc,E'\\r\\n',E'\\n'))='''+quote(md5(replaced[5]))+''')
 THEN RAISE EXCEPTION 'POST_PUBLICATION_ASSIGNMENT_SOURCE_DRIFT'; END IF;
'''
    return '''DO $stage_a_source_guard$ BEGIN
 IF current_user<>'postgres' OR session_user<>'postgres' THEN RAISE EXCEPTION 'POSTGRES_SESSION_REQUIRED'; END IF;
''' + absent + ''' IF EXISTS(SELECT 1 FROM (VALUES
''' + ',\n'.join(rows) + ''') e(signature,body_md5,config,result_type)
 LEFT JOIN pg_proc p ON p.oid=to_regprocedure(e.signature)
 WHERE p.oid IS NULL OR p.proowner<>'postgres'::regrole OR NOT p.prosecdef
 OR p.provolatile<>'v' OR p.proconfig IS DISTINCT FROM ARRAY[e.config]
 OR pg_get_function_result(p.oid) IS DISTINCT FROM e.result_type
 OR md5(replace(p.prosrc,E'\\r\\n',E'\\n')) IS DISTINCT FROM e.body_md5)
 THEN RAISE EXCEPTION 'CURRENT_LIFECYCLE_SOURCE_OR_SECURITY_DRIFT'; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_proc p
 WHERE p.oid=to_regprocedure('public.geolock_transition_listing_donations(uuid,text,text,uuid,uuid,text)')
 AND p.proowner='postgres'::regrole AND NOT p.prosecdef
 AND p.proconfig=ARRAY['search_path=pg_catalog, public, pg_temp']
 AND md5(replace(p.prosrc,E'\\r\\n',E'\\n'))='67f27a85fb9129c9017bb0e9178f8ba1')
 THEN RAISE EXCEPTION 'CURRENT_SIX_ARGUMENT_AUDIT_HELPER_REQUIRED'; END IF;
 IF EXISTS(SELECT 1 FROM pg_roles r WHERE r.rolname IN
 ('anon','authenticated','service_role','geolock_graph_worker','geolock_planner','geolock_validator')
 AND has_function_privilege(r.oid,
 to_regprocedure('public.geolock_transition_listing_donations(uuid,text,text,uuid,uuid,text)'),'EXECUTE'))
 THEN RAISE EXCEPTION 'PRIVATE_AUDIT_HELPER_PRIVILEGE_DRIFT'; END IF;
''' + assignment_guard + '''
 IF NOT EXISTS(SELECT 1 FROM public.coordination_config WHERE singleton AND claim_lease_minutes=360
 AND donation_direct_min_kg=10 AND geofence_radius_m=20000) THEN RAISE EXCEPTION 'COORDINATION_POLICY_DRIFT'; END IF;
END $stage_a_source_guard$;
'''


def legacy_definition(source, name):
    m = function(source, 'public.' + name)
    definition = m[0].replace('FUNCTION public.' + name,
                              'FUNCTION routing_private.legacy_' + name, 1)
    # Only the name and execution settings change. The complete current body is exact.
    definition = definition.replace("SET search_path TO 'public', 'extensions', 'pg_temp'",
        "SET search_path TO 'pg_catalog', 'pg_temp'\n SET timezone TO 'UTC'\n SET extra_float_digits TO '0'", 1)
    if function(definition, 'routing_private.legacy_' + name)[5] != m[5]:
        raise ValueError('LIFECYCLE_BODY_CHANGED')
    return definition


def reconciliation(source):
    original = function(source, 'public.submit_claim_reconciliation')[0]
    replay = '''  -- STAGE_A_AUTHORIZED_REPLAY_BEGIN
  perform routing_private.lock_reconciliation_scope(p_claim);
  select e.response into v_result from public.claim_reconciliation_evidence e
  join public.claim_reconciliation_cases rc using(case_id)
  where e.request_id=p_request and e.actor_user_id=v_actor
    and e.handover_confirmed is not distinct from p_handover_confirmed
    and rc.claim_id=p_claim;
  if v_result is not null then return v_result; end if;
  -- STAGE_A_AUTHORIZED_REPLAY_END
'''
    body = original
    changes = [
      ('  -- Same lock prefix as start/complete/recovery.\n', replay + '  -- Same lock prefix as start/complete/recovery.\n'),
      ("      update public.pickup_tasks set task_status='COLLECTED' where task_id=v_t.task_id;",
       "      perform routing_private.permit_reconciled_collection(p_claim);\n      update public.pickup_tasks set task_status='COLLECTED' where task_id=v_t.task_id;"),
      ("      v_result:=jsonb_build_object('outcome','SUCCESS','case_id',v_case.case_id,\n        'claim_status','COMPLETED','donation_status','COLLECTED','reason_code','HANDOVER_CONFIRMED');",
       "      perform routing_private.finish_reconciled_collection(p_claim);\n      v_result:=jsonb_build_object('outcome','SUCCESS','case_id',v_case.case_id,\n        'claim_status','COMPLETED','donation_status','COLLECTED','reason_code','HANDOVER_CONFIRMED');")]
    for before, after in changes:
        if body.count(before) != 1:
            raise ValueError('RECONCILIATION_ANCHOR_DRIFT')
        body = body.replace(before, after)
    prefix = (OLD/'reconciliation/compatibility_prefix.sql').read_text()
    # Already inside the single installation transaction. Preserve every compatibility guard.
    prefix = prefix.split('BEGIN;', 1)[1]
    for token, value in [('RECON', PINS['submit_claim_reconciliation']),
                         ('RECOVERY', PINS['recover_expired_claims']),
                         ('GUARD', md5(function((OLD/'003_pickup_enforcement_proposal.sql').read_text(), 'routing_private.task_guard')[5]))]:
        prefix = prefix.replace('__' + token + '_MD5__', value)
    return prefix + '\n' + body + '\n', replay


def render():
    source = CURRENT.read_text()
    sql1 = (OLD/'001_authority_proposal.sql').read_text()
    sql1, count = re.subn(r'DO \$pin\$ BEGIN.*?END \$pin\$;\n?',
        lambda _: source_guard(source, first=True), sql1, count=1, flags=re.S)
    if count != 1:
        raise ValueError('AUTHORITY_GUARD_ANCHOR_DRIFT')
    sql2 = (OLD/'002_publication_proposal.sql').read_text()
    sql3 = (OLD/'003_pickup_enforcement_proposal.sql').read_text()
    prefix = sql3.split('-- LEGACY_BODIES_AND_COMMIT')[0]
    prefix, count = re.subn(r'DO \$pin\$ BEGIN.*?END \$pin\$;\n?',
        lambda _: source_guard(source), prefix, count=1, flags=re.S)
    if count != 1:
        raise ValueError('PICKUP_GUARD_ANCHOR_DRIFT')
    bridge, _ = reconciliation(source)
    sql3 = prefix + '-- CURRENT_20261031_BODIES\n' + '\n'.join(
        legacy_definition(source, name) for name in ('start_pickup','complete_pickup'))
    sql3 += '\nREVOKE ALL ON ALL FUNCTIONS IN SCHEMA routing_private FROM PUBLIC,anon,authenticated,service_role;\n'
    sql3 += bridge + '\nCOMMIT;\n'
    banner = '-- STAGE A FORWARD REVIEW ARTIFACT. NOT DEPLOYED. DEV rcgyuwiidqvrgbxswhqj ONLY.\n'
    return dict(zip(OUTPUTS, (banner+sql1, banner+sql2, banner+sql3)))


def build():
    lock = HERE/'preserved-inputs.json'
    current_inputs = {str(p.relative_to(ROOT)).replace('\\','/'): sha(p) for p in PROTECTED}
    if lock.exists() and json.loads(lock.read_text()) != current_inputs:
        raise ValueError('PRESERVED_INPUT_DRIFT_REVIEW_REQUIRED')
    sql = render()
    target = HERE/'forward-migrations'
    target.mkdir(parents=True, exist_ok=True)
    for name, content in sql.items():
        (target/name).write_text(content, encoding='utf-8', newline='\n')
    if not lock.exists():
        lock.write_text(json.dumps(current_inputs,indent=2)+'\n',encoding='utf-8')
    manifest = dict(status='STAGE_A_REVIEW_ONLY_NOT_DEPLOYED',project_ref='rcgyuwiidqvrgbxswhqj',
        authoritative_source=str(CURRENT.relative_to(ROOT)).replace('\\','/'),
        authoritative_sha256=sha(CURRENT),source_pins=PINS,
        source_pin_scope='Reviewed local source only; fresh DEV source/ACL verification required',
        files={name:sha(target/name) for name in OUTPUTS},
        permitted_public_replacements=['assign_task_to_route','start_pickup','complete_pickup','submit_claim_reconciliation'],
        preserved_public_functions=['claim_listing','recover_expired_claims','cancel_claim',
          'get_authorized_audit_events','geolock_transition_listing_donations'],
        runtime_sql_validation='NOT_EXECUTED_STAGE_B_APPROVAL_REQUIRED')
    (HERE/'package-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n',encoding='utf-8')
    # Catalog-only verification prepared for a later approved checkpoint.
    expected = [('public.claim_listing(uuid,uuid)',PINS['claim_listing']),
                ('public.recover_expired_claims(integer)',PINS['recover_expired_claims'])]
    final = sql[OUTPUTS[2]]
    for name in ('public.start_pickup','public.complete_pickup','public.submit_claim_reconciliation',
                 'routing_private.legacy_start_pickup','routing_private.legacy_complete_pickup'):
        m = function(final,name)
        expected.append((name+'('+','.join(a.strip().split()[1] for a in m[2].split(','))+')',md5(m[5])))
    values = ',\n'.join('('+quote(sig)+','+quote(digest)+')' for sig,digest in expected)
    post = '''-- PREPARED SELECT ONLY; not executed. Verify DEV endpoint out of band first.
-- This is source evidence, not full permission, fixture or runtime acceptance.
SELECT e.signature,CASE WHEN p.oid IS NULL THEN 'FAIL'
 WHEN md5(replace(p.prosrc,E'\\r\\n',E'\\n'))=e.body_md5 AND p.proowner='postgres'::regrole
 AND p.prosecdef THEN 'PASS' ELSE 'FAIL' END AS status,
 md5(replace(p.prosrc,E'\\r\\n',E'\\n')) AS actual_body_md5,p.proconfig,p.proacl
FROM (VALUES
''' + values + ''') e(signature,body_md5)
LEFT JOIN pg_proc p ON p.oid=to_regprocedure(e.signature) ORDER BY e.signature;
SELECT 'routing_task_authority' AS check_name,CASE WHEN EXISTS(
 SELECT 1 FROM pg_trigger WHERE tgrelid=to_regclass('public.pickup_tasks')
 AND tgname='routing_task_authority' AND tgenabled='O'
 AND tgfoid=to_regprocedure('routing_private.task_guard()')) THEN 'PASS' ELSE 'FAIL' END AS status;
SELECT 'public_direct_writes' AS check_name,r.rolname,t.oid::regclass AS relation,
 CASE WHEN has_table_privilege(r.oid,t.oid,'INSERT,UPDATE,DELETE,TRUNCATE')
 OR has_any_column_privilege(r.oid,t.oid,'INSERT,UPDATE') THEN 'FAIL' ELSE 'PASS' END AS status
FROM pg_roles r CROSS JOIN pg_class t JOIN pg_namespace n ON n.oid=t.relnamespace
WHERE r.rolname IN ('anon','authenticated') AND n.nspname='public'
AND t.relname IN ('pickup_tasks','pickup_routes','pickup_route_stops','active_task_route_assignments');
-- Missing/extra relations, all function ACLs, role memberships, C1 seal,
-- protected-object delta and historical snapshots require the full reviewed pre/post comparison.
'''
    (HERE/'postdeployment_catalog.sql').write_text(post,encoding='utf-8',newline='\n')
    print('Prepared three review-only forward migrations. No database or network access.')


if __name__ == '__main__':
    build()
