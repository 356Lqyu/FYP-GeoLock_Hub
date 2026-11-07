"""Offline C1 verification result comparison. Never connects to a database.

Results are evidence exports, not authenticated attestations. Correct project and
SQL provenance must be confirmed separately by the operator.
"""
import argparse
import hashlib
import json
from pathlib import Path

HERE=Path(__file__).resolve().parent
PROJECT='rcgyuwiidqvrgbxswhqj'
SHA='f50af9705de117bdd12581f2515605c8e5c548e0fee7ae01d7ea33ecfbb0cb05'
PUBLIC={'register_my_vehicle','list_my_vehicles','update_my_vehicle','set_my_vehicle_availability','deactivate_my_vehicle'}
PRIVATE={'require_ngo','road_node_key','require_depot','check_values','vehicle_has_hold','vehicle_guard',
         'route_vehicle_guard','audit_vehicle','installation_fingerprint'}


def check_package():
    manifest=json.loads((HERE/'package-manifest.json').read_text(encoding='utf-8'))
    if hashlib.sha256((HERE.parent/'proposed_migration_v2.sql').read_bytes()).hexdigest()!=SHA:
        raise ValueError('Migration digest differs from reviewed v2')
    for name,digest in manifest['files'].items():
        if hashlib.sha256((HERE/name).read_bytes()).hexdigest()!=digest:
            raise ValueError('Generated SQL changed: '+name)
    return manifest


def indexed(document,phase):
    if document.get('project_ref')!=PROJECT or document.get('migration_sha256')!=SHA or document.get('phase')!=phase:
        raise ValueError('Wrong project, migration digest or result phase')
    result={}
    for item in document['results']:
        if item['check_id'] in result: raise ValueError('Duplicate check ID')
        if not isinstance(item['rows'],list): raise ValueError('Rows must be an array')
        result[item['check_id']]=item['rows']
    return result


def read_text(path):
    raw=path.read_bytes()
    return raw.decode('utf-16') if raw.startswith((b'\xff\xfe',b'\xfe\xff')) else raw.decode('utf-8-sig')


def keyed(rows,fields):
    out={tuple(row[k] for k in fields):row for row in rows}
    if len(out)!=len(rows): raise ValueError('Duplicate row identity')
    return out


def compare(before,after,manifest):
    b=indexed(before,'preflight'); a=indexed(after,'postflight'); failures=[]
    if set(b)!=set(manifest['preflight_checks']): failures.append('Preflight check set is incomplete/unexpected')
    if set(a)!=set(manifest['postflight_checks']): failures.append('Postflight check set is incomplete/unexpected')
    if failures: return failures
    if b['C11_fleet_objects'] or b['C20_private_schema']:
        failures.append('This comparator requires a fresh pre-C1 baseline, not an installed/repeat baseline')
    if b['C19_invalid_legacy_capacity'] or a['C19_invalid_legacy_capacity']:
        failures.append('Invalid legacy capacity')
    for field in ['database_name','execution_role','server_version','search_path','isolation']:
        if b['C01_context'][0][field]!=a['C01_context'][0][field]: failures.append('Execution context changed: '+field)
    for name in ['C06_counts','C10_legacy_vehicle_rows','C17_route_row_hashes','C18_assignment_hashes',
                 'C13_role_capabilities','C14_vehicle_relations','C15_depot_identity','C16_route_jobs',
                 'L01_protected_object_fingerprints']:
        if b[name]!=a[name]: failures.append('Preservation mismatch: '+name)
    oldcols=keyed(b['C02_columns'],['attname']); newcols=keyed(a['C02_columns'],['attname'])
    for key,row in oldcols.items():
        if key not in newcols or any(row[k]!=newcols[key][k] for k in ['data_type','attnotnull','default_expression']):
            failures.append('Legacy column changed: '+str(key))
    if len(newcols)!=len(oldcols)+9: failures.append('Unexpected column count')
    oldcons=keyed(b['C03_constraints'],['table_name','conname']); newcons=keyed(a['C03_constraints'],['table_name','conname'])
    for key,row in oldcons.items():
        if newcons.get(key)!=row: failures.append('Existing constraint changed: '+str(key))
    extra=[v for k,v in newcons.items() if k not in oldcons]
    if {x['conname'] for x in extra}!={'vehicles_c1_fields','vehicles_c1_available_complete'} or len(extra)!=2:
        failures.append('Unexpected added constraints')
    oldobjects=keyed(b['C12_triggers_indexes'],['kind','table_name','name']); newobjects=keyed(a['C12_triggers_indexes'],['kind','table_name','name'])
    for key,row in oldobjects.items():
        if newobjects.get(key)!=row: failures.append('Existing trigger/index changed: '+str(key))
    extraobjects=[v for k,v in newobjects.items() if k not in oldobjects]
    expected={'vehicles_c1_registration_request','vehicles_c1_owner_active','pickup_routes_c1_vehicle_busy',
              'zz_c1_vehicle_guard','c1_vehicle_audit','c1_route_vehicle_guard'}
    if {x['name'].split('.')[-1] for x in extraobjects}!=expected or len(extraobjects)!=6:
        failures.append('Unexpected trigger/index additions')
    if any(x['kind']=='index' and x['enabled']!='true' for x in extraobjects):
        failures.append('New index is invalid')
    expected_rows={'V01_expected_columns':9,'V02_table_permission_assertions':24,
      'V03_column_permission_assertions':len(newcols)*8,'V04_rpc_assertions':15,'V05_private_permissions':27,
      'V06_route_truncate':3,'V08_snapshot_seal':1,'V09_trigger_assertions':4,
      'V10_constraint_assertions':2,'V11_private_function_assertions':9}
    for name,count in expected_rows.items():
        if len(a[name])!=count or any(row.get('pass') is not True for row in a[name]):
            failures.append('Assertion failed/rows missing: '+name)
    if a['V07_integrity_rows']: failures.append('Invalid vehicle rows reported')
    if any(row['grant_option'] for row in a['C05_effective_privileges']): failures.append('Unexpected vehicle grant option')
    tables=keyed(a['C04_acl_rls'],['relname']); oldtables=keyed(b['C04_acl_rls'],['relname'])
    for key,row in tables.items():
        old=oldtables.get(key,{})
        if any(row[k]!=old.get(k) for k in ['schema_name','owner','relrowsecurity','relforcerowsecurity','policies']):
            failures.append('Table owner/RLS/policy changed: '+str(key))
        if row['relname']=='vehicles':
            owner_acl=[x for x in old['acl'] if x['grantee']=='postgres']
            expected_acl=owner_acl+[{'grantee':'service_role','privilege':p,'grant_option':False} for p in ['SELECT','INSERT','UPDATE']]
        else:
            expected_acl=[x for x in old['acl'] if not(x['grantee'] in {'PUBLIC','anon','authenticated','service_role'} and x['privilege']=='TRUNCATE')]
        sort=lambda rows: sorted(rows,key=lambda x:(x['grantee'],x['privilege']))
        if sort(row['acl'])!=sort(expected_acl): failures.append('Unexpected ACL: '+row['relname'])
    objects=a['C11_fleet_objects']
    if {(x['nspname'],x['proname']) for x in objects}!={('public',n) for n in PUBLIC}|{('fleet_private',n) for n in PRIVATE} or len(objects)!=14:
        failures.append('Unexpected managed function set')
    for row in objects:
        grants=row.get('proacl') or []
        allowed={'postgres','authenticated'} if row['nspname']=='public' else {'postgres'}
        if not grants or {g.split('=')[0] for g in grants}!=allowed or any('*' in g for g in grants):
            failures.append('Unexpected function ACL: '+row['proname'])
    return failures


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    sub=parser.add_subparsers(dest='mode',required=True)
    sub.add_parser('check-package')
    wrap=sub.add_parser('wrap-jsonl'); wrap.add_argument('--input',type=Path,required=True)
    wrap.add_argument('--output',type=Path,required=True); wrap.add_argument('--phase',choices=['preflight','postflight'],required=True)
    cmp=sub.add_parser('compare'); cmp.add_argument('--before',type=Path,required=True); cmp.add_argument('--after',type=Path,required=True)
    args=parser.parse_args(); manifest=check_package()
    if args.mode=='check-package': print('PASS: reviewed migration and SELECT-check file hashes match'); return
    if args.mode=='wrap-jsonl':
        results=[json.loads(line) for line in read_text(args.input).splitlines() if line.strip()]
        doc={'project_ref':PROJECT,'phase':args.phase,'migration_sha256':SHA,'results':results}
        data=indexed(doc,args.phase)
        required=manifest['preflight_checks'] if args.phase=='preflight' else manifest['postflight_checks']
        if set(data)!=set(required): raise SystemExit('STOP: missing/unexpected check results')
        args.output.write_text(json.dumps(doc,indent=2)+'\n',encoding='utf-8'); print('Wrapped exports; project identity must be independently verified.'); return
    failures=compare(json.loads(read_text(args.before)),json.loads(read_text(args.after)),manifest)
    print(json.dumps({'catalog_comparison':'FAIL' if failures else 'PASS','failures':failures,
      'runtime_authorization_tests':'NOT_PROVEN_BY_CATALOGS'},indent=2))
    if failures: raise SystemExit(1)


if __name__=='__main__': main()
