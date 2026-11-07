"""Offline archive-extract verification. No database driver or network access."""
import argparse
from datetime import datetime
from decimal import Decimal, InvalidOperation
import hashlib
import json
from pathlib import Path
import re

TABLES = ('policies', 'graphs', 'snapshots', 'matrices', 'candidates', 'validations')
KEYS = dict(zip(TABLES, ('policy_id','graph_id','snapshot_id','matrix_id','candidate_id','candidate_id')))
ROUTE_TABLES = TABLES + ('bindings', 'items', 'requests')
KEYS.update(bindings='route_id', items=('route_id', 'task_id'), requests=('ngo_id', 'request_id'))
PURPOSES = ('PRE_AUTOMATIC_DEPARTURE_CURRENT_DEV', 'PRE_ROUTE_RESOLUTION_CURRENT_DEV',
            'PRE_CLAIM_SCOPED_RECONCILIATION_CURRENT_DEV', 'PRE_SIMPLIFIED_RECONCILIATION_CURRENT_DEV')


def copy_value(value):
    if value == r'\N':
        return None
    escapes = {'b':'\b','f':'\f','n':'\n','r':'\r','t':'\t','v':'\v'}
    def replace(match):
        token = match[1]
        if re.fullmatch(r'[0-7]{1,3}', token):
            return chr(int(token, 8))
        if token.startswith('x') and len(token) > 1:
            return chr(int(token[1:], 16))
        return escapes.get(token, token)
    return re.sub(r'\\([0-7]{1,3}|x[0-9a-fA-F]{1,2}|.)', replace, value)


def copy_tables(text, tables=TABLES):
    result = {}
    table = None
    for line in text.splitlines():
        if table is None:
            match = re.fullmatch(r'COPY routing_private\."?(\w+)"? \((.+)\) FROM stdin;', line)
            if not match:
                continue
            table = match[1]
            if table not in tables or table in result:
                raise ValueError('Unexpected or duplicate routing COPY section')
            columns = [x.strip().strip('"') for x in match[2].split(',')]
            result[table] = []
        elif line == r'\.':
            table = None
        else:
            values = line.split('\t')
            if len(values) != len(columns):
                raise ValueError('COPY column count mismatch')
            result[table].append(dict(zip(columns, map(copy_value, values))))
    if table is not None or set(result) != set(tables):
        raise ValueError('Incomplete routing COPY data')
    return result


def equal_value(expected, actual):
    if expected is None:
        return actual is None
    if actual is None:
        return False
    if isinstance(expected, (dict, list)):
        return json.loads(actual) == expected
    if isinstance(expected, bool):
        return actual == ('t' if expected else 'f')
    if isinstance(expected, (int, float)):
        try:
            return Decimal(str(expected)) == Decimal(actual)
        except InvalidOperation:
            return False
    if re.match(r'^\d{4}-\d\d-\d\d[T ]', expected):
        try:
            return datetime.fromisoformat(expected) == datetime.fromisoformat(actual)
        except ValueError:
            return False
    return expected == actual


def verify(inventory, schema, data, purpose='PRE_AUTOMATIC_DEPARTURE_CURRENT_DEV'):
    if purpose not in PURPOSES or inventory.get('capture_purpose') != purpose:
        raise ValueError('Incorrect capture purpose')
    tables = ROUTE_TABLES if purpose in ('PRE_ROUTE_RESOLUTION_CURRENT_DEV', 'PRE_CLAIM_SCOPED_RECONCILIATION_CURRENT_DEV', 'PRE_SIMPLIFIED_RECONCILIATION_CURRENT_DEV') else TABLES
    archived = copy_tables(data, tables)
    counts = {}
    for table in tables:
        expected = inventory['recovery_records'][table]
        rows = archived[table]
        keys = KEYS[table] if isinstance(KEYS[table], tuple) else (KEYS[table],)
        by_key = {tuple(r[k] for k in keys): r for r in rows}
        if len(by_key) != len(rows) or len(rows) != len(expected):
            raise ValueError('Routing record count or key mismatch: ' + table)
        for item in expected:
            row = by_key.get(tuple(item[k] for k in keys))
            if row is None or any(k not in row or not equal_value(v, row[k]) for k,v in item.items()):
                raise ValueError('Routing record metadata/body mismatch: ' + table)
        counts[table] = len(rows)
    pattern = re.compile(r'CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION\s+([\w.]+)\s*\(.*?\)\s*RETURNS\b.*?\bAS\s+(\$\w*\$)(.*?)\2', re.S|re.I)
    bodies = {}
    for match in pattern.finditer(schema):
        digest = hashlib.md5(match[3].replace('\r\n','\n').encode('utf-8')).hexdigest()
        bodies.setdefault(match[1], set()).add(digest)
    for fn in inventory['functions']:
        if fn['body_md5'] not in bodies.get(fn['name'], set()):
            raise ValueError('Archived function body mismatch: ' + fn['signature'])
    return {'status':'PASS / SCOPED CURRENT-STATE ARCHIVE CHECKS',
            'routing_record_counts':counts,'function_body_matches':len(inventory['functions']),
            'policy_body_and_routing_metadata':'MATCH captured inventory',
            'all_table_row_equivalence':'NOT VERIFIED',
            'archive_digest_columns':'Compared to catalog records; not recomputed from full road or application data',
            'exact_overload_acl_trigger_equivalence':'NOT VERIFIED; full schema extraction retained',
            'restore_validation':'NOT VERIFIED',
            'snapshot_note':'Database dump is one snapshot; catalog and roles are separate snapshots. No writers were paused.'}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--directory', required=True, type=Path)
    parser.add_argument('--purpose', choices=PURPOSES, default=PURPOSES[0])
    args = parser.parse_args()
    directory = args.directory
    try:
        inventory = json.loads((directory/'source-inventory.json').read_text(encoding='utf-8-sig'))
        receipt = json.loads((directory/'capture-record.json').read_text(encoding='utf-8-sig'))
        if receipt.get('purpose') != args.purpose or receipt.get('database_export_exit_code') != 0 or receipt.get('roles_export_exit_code') != 0:
            raise ValueError('Successful current capture receipt required')
        result = verify(inventory, (directory/'schema.sql').read_text(encoding='utf-8-sig'),
                        (directory/'routing-recovery-data.sql').read_text(encoding='utf-8-sig'), purpose=args.purpose)
        manifest = {'purpose':inventory['capture_purpose'],'project_ref':'rcgyuwiidqvrgbxswhqj',
                    'export_completed_at_utc':receipt['completed_at_utc'],
                    'source_observed_at':inventory['observed_at'], 'export':receipt,
                    'scope':'Unfiltered custom-format database archive plus roles/memberships without passwords',
                    'graph_manifests':inventory['recovery_records']['graphs'],
                    'policy_ids':[x['policy_id'] for x in inventory['recovery_records']['policies']],
                    'routing_record_counts':result['routing_record_counts'],
                    'security':'Operator/SYSTEM/Administrators-only directory ACL; Git ignored. Backup is not encrypted by this runner.',
                    'restore_validation':'NOT VERIFIED',
                    'external_exclusions':['Storage object bytes','Auth signing/service configuration secrets','worker credentials/journals','provider infrastructure','extension binaries','role passwords']}
        for name, body in [('current-state-verification.json',result),('capture-manifest.json',manifest)]:
            (directory/name).write_text(json.dumps(body, indent=2)+'\n', encoding='utf-8')
        print('Current-state archive comparison PASS (scoped); restore NOT VERIFIED.')
        return 0
    except Exception:
        # Never echo exception text, row data or paths read from an archive.
        print('Current-state archive comparison FAILED; evidence retained. No recovery PASS.')
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
