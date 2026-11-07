"""Native psql transport; Python only prepares files and runs offline comparison.

Default is offline preparation. --export invokes psql once with its native hidden
password prompt. No password is accepted by this program or stored in evidence.
"""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import subprocess
import sys
from uuid import uuid4

from road_export_contract import (HERE, ROOT, PROJECT, sha, reference_check,
    approved_profile, IDENTITY_SQL, ACCESS_SQL, TYPES_SQL, COVERAGE_SQL, NODE_SQL, EDGE_SQL)


def write(path, value):
    path.write_text(json.dumps(value, indent=2)+'\n', encoding='utf-8')


def sql_for(target):
    def output(name):
        path = (target/name).as_posix()
        if "'" in path or '\n' in path: raise ValueError('Unsupported output path')
        return "'"+path+"'"
    lines = [r'\set ON_ERROR_STOP on',
        'BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;',
        "SET LOCAL statement_timeout='60s';", "SET LOCAL lock_timeout='5s';",
        'SET LOCAL extra_float_digits=0;', "SET LOCAL timezone='UTC';",
        "SELECT current_database()='postgres' AND current_user='postgres' AND session_user='postgres' "
        "AND current_setting('transaction_read_only')='on' "
        "AND current_setting('server_version_num')::int BETWEEN 170000 AND 179999 "
        "AND coalesce((SELECT ssl FROM pg_stat_ssl WHERE pid=pg_backend_pid()),false) "
        "AND (SELECT rolbypassrls FROM pg_roles WHERE rolname=current_user) AS identity_ok",
        r'\gset', r'\if :identity_ok', r'\else', r'\quit 3', r'\endif']
    for filename, query in [('identity.json', IDENTITY_SQL),
        ('access.json', 'SELECT jsonb_agg(to_jsonb(q)) FROM ('+ACCESS_SQL+') q'),
        ('types.json', 'SELECT jsonb_agg(to_jsonb(q)) FROM ('+TYPES_SQL+') q'),
        ('coverage.json', COVERAGE_SQL)]:
        lines += [r'\o '+output(filename), query+';', r'\o']
    for filename, query in [('nodes.csv', NODE_SQL), ('edges.csv', EDGE_SQL)]:
        lines += [r'\copy ('+' '.join(query.split())+') TO '+output(filename)+' WITH (FORMAT CSV, HEADER TRUE)']
    lines += ['ROLLBACK;', r'\o '+output('rollback.json'), "SELECT 'true';", r'\o']
    return '\n'.join(lines)+'\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--export', action='store_true')
    parser.add_argument('--psql', type=Path, default=Path('C:/Program Files/PostgreSQL/17/bin/psql.exe'))
    args = parser.parse_args()
    reference_check()
    profile, params = approved_profile()
    version = subprocess.run([str(args.psql), '--version'], capture_output=True, text=True, check=True).stdout.strip()
    if not version.startswith('psql (PostgreSQL) 17.'): raise ValueError('Native PostgreSQL 17 required')
    if not args.export:
        # Exercise SQL construction without connecting or creating an export receipt.
        sql_for(ROOT/'results/routing-current-export/native-offline-validation')
        print('Native export preparation PASS; pinned files/profile checked; '+version+'. No connection attempted.')
        return 0
    if not sys.stdin.isatty(): raise ValueError('Run from an interactive local console')
    target = ROOT/'results/routing-current-export'/(datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')+'-native-'+uuid4().hex[:6])
    target.mkdir(parents=True, exist_ok=False)
    query_file = target/'queries.sql'
    query_file.write_text(sql_for(target), encoding='utf-8')
    receipt = dict(status='INCOMPLETE', project_ref=PROJECT, connection=params,
        profile_sha256=sha(profile), exporter_file=Path(__file__).name,
        exporter_sha256=sha(Path(__file__)), query_contract_sha256=sha(HERE/'road_export_contract.py'),
        client=version, database_writes=False, files={})
    write(target/'receipt.json', receipt)
    env = {k:v for k,v in os.environ.items() if not k.upper().startswith('PG')}
    env['PGSERVICEFILE'] = str(profile)
    # No captured stdin, credential environment, retry loop or password-bearing arguments.
    result = subprocess.run([str(args.psql), '-X', '-q', '-A', '-t', '-W',
        '--dbname', 'service=geolock_dev_owner_export', '--file', str(query_file)], env=env)
    receipt['psql_exit_code'] = result.returncode
    try:
        if result.returncode: raise ValueError('Native export failed; preserve partial evidence')
        for name in ('identity','access','types','coverage'):
            receipt[name] = json.loads((target/(name+'.json')).read_text(encoding='utf-8-sig'))
        if json.loads((target/'rollback.json').read_text(encoding='utf-8-sig')) is not True:
            raise ValueError('ROLLBACK completion marker missing')
        if len(receipt['access']) != 3 or not all(r['can_select'] for r in receipt['access']):
            raise ValueError('SELECT coverage gap')
        for name in ('nodes.csv','edges.csv'):
            path = target/name
            receipt['files'][name] = dict(sha256=sha(path), bytes=path.stat().st_size)
        receipt.update(status='COMPLETE', rollback_completed=True)
    finally:
        write(target/'receipt.json', receipt)
        print('Evidence: '+str(target))
    return subprocess.run([sys.executable, '-B', str(HERE/'verify_current_export.py'), '--export-dir', str(target)]).returncode


if __name__ == '__main__':
    raise SystemExit(main())
