"""Enrollment and safety checks for a disposable Supabase Session Pooler target."""
from dataclasses import dataclass
import json
import os
from pathlib import Path
import re
import uuid

import psycopg


BLOCKED_PROJECTS = {'rcgyuwiidqvrgbxswhqj', 'mffccmlimmbrgasgfnnq'}
POOLER_HOST = re.compile(r'aws-[0-9]+-[a-z0-9-]+\.pooler\.supabase\.com')
RUN_LOCK = (1195724620, 2)
AUTH_PROBE_ACTOR = '7a315913-d192-4e63-b591-77d24e19f287'


def approval_phrase(project):
    return f'APPROVE DESTRUCTIVE E2 REBUILDS FOR {project}'


@dataclass(frozen=True)
class HostedTarget:
    project: str
    host: str
    target_id: str
    ca: Path

    @classmethod
    def from_config(cls, config):
        if not isinstance(config, dict) or set(config) != {
            'version', 'project', 'host', 'target_id', 'ca', 'authorization',
        } or config['version'] != 1:
            raise SystemExit('Hosted E2 enrollment has an unsupported format.')
        project, host, marker, ca = (config[key] for key in ('project', 'host', 'target_id', 'ca'))
        if not all(isinstance(value, str) for value in (project, host, marker, ca)):
            raise SystemExit('Hosted E2 enrollment fields must be strings.')
        if not re.fullmatch(r'[a-z0-9]{20}', project) or project in BLOCKED_PROJECTS:
            raise SystemExit('Hosted E2 requires a dedicated project reference; known Flutter projects are refused.')
        if not POOLER_HOST.fullmatch(host):
            raise SystemExit('Use the Supabase Session Pooler hostname from the dashboard Connect dialog.')
        if not re.fullmatch(r'[0-9a-f]{32}', marker):
            raise SystemExit('Hosted E2 requires the registered UUID marker.')
        if config['authorization'] != approval_phrase(project):
            raise SystemExit('Hosted E2 requires explicit authorization for this project reference.')
        ca = Path(ca)
        if not ca.is_absolute() or not ca.is_file():
            raise SystemExit('Hosted E2 requires an absolute path to a trusted CA bundle.')
        return cls(project, host, marker, ca)

    @property
    def username(self):
        return f'postgres.{self.project}'

    def connect(self, *, connect_timeout, statement_timeout):
        if os.environ.get('PGPASSWORD'):
            raise SystemExit('Clear PGPASSWORD and use the per-user PostgreSQL password file.')
        appdata = os.environ.get('APPDATA')
        if not appdata:
            raise SystemExit('APPDATA is required to locate the Windows PostgreSQL password file.')
        try:
            conn = psycopg.connect(
                host=self.host, port=5432, dbname='postgres', user=self.username,
                hostaddr='', sslmode='verify-full', sslrootcert=str(self.ca), gssencmode='disable',
                passfile=str(Path(appdata) / 'postgresql/pgpass.conf'), options='',
                connect_timeout=connect_timeout, autocommit=True,
            )
        except psycopg.Error:
            raise SystemExit('Hosted E2 connection failed. Check the dashboard endpoint, CA, and password file.') from None
        try:
            if not conn.pgconn.ssl_in_use:
                raise SystemExit('Hosted E2 requires a verified TLS connection.')
            conn.execute('select set_config(%s, %s, false)', ('statement_timeout', f'{statement_timeout}s'))
            return conn
        except BaseException:
            conn.close()
            raise


def register(path, project, host, ca, *, input_fn=input):
    """Write local authorization and print marker SQL for the selected dashboard."""
    if path.exists():
        raise SystemExit(f'Hosted enrollment already exists: {path}')
    config = dict(version=1, project=project, host=host, target_id=uuid.uuid4().hex,
                  ca=str(Path(ca).resolve()), authorization=approval_phrase(project))
    target = HostedTarget.from_config(config)
    print('Authorize only a new E2-only project with no application data or integrations.')
    if input_fn(f'Type "{config["authorization"]}": ') != config['authorization']:
        raise SystemExit('Hosted E2 enrollment cancelled.')
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('x', encoding='utf-8') as file:
        json.dump(config, file, indent=2)
        file.write('\n')
    print(f'Wrote password-free enrollment to {path}. No connection was opened.')
    print(f'Provision this marker only in the SQL Editor for project {target.project}:')
    print(f"""begin;
create table public.e2_disposable_target (
  singleton boolean primary key check (singleton),
  target_id uuid not null,
  project_ref text not null
);
revoke all on public.e2_disposable_target from public, anon, authenticated, service_role;
insert into public.e2_disposable_target values (true, '{uuid.UUID(target.target_id)}', '{target.project}');
commit;""")


def verify_identity(conn, target):
    if (conn.info.host, conn.info.port, conn.info.user, conn.info.dbname) != (
        target.host, 5432, target.username, 'postgres',
    ) or not conn.pgconn.ssl_in_use:
        raise SystemExit('Hosted E2 connection does not match its authorized TLS endpoint.')
    db, role, login, version = conn.execute(
        "select current_database(), current_user, session_user, current_setting('server_version')"
    ).fetchone()
    if (db, role, login) != ('postgres', 'postgres', 'postgres') or version.split('.')[0] != '17':
        raise SystemExit('Hosted E2 requires PostgreSQL 17 and the project postgres role.')
    if conn.execute("select to_regclass('public.e2_disposable_target')").fetchone()[0] is None:
        raise SystemExit('Hosted E2 marker missing. Check the enrolled project and dashboard marker.')
    rows = conn.execute(
        'select singleton, target_id::text, project_ref from public.e2_disposable_target'
    ).fetchall()
    if rows != [(True, str(uuid.UUID(target.target_id)), target.project)]:
        raise SystemExit('Hosted E2 marker does not match the authorized project and UUID.')
    return dict(mode='hosted', project_ref=target.project, connection_host=target.host,
                connection_user=target.username, database=db, server_version=version,
                target_id=target.target_id, marker_verified=True, tls='verify-full')


def check_compatibility(conn):
    """Inspect managed Auth and extensions and test the session role contract."""
    extensions = dict(conn.execute(
        "select extname, nspname from pg_extension join pg_namespace on pg_namespace.oid = extnamespace "
        "where extname in ('postgis', 'pgcrypto')"
    ).fetchall())
    if extensions.get('postgis') != 'extensions' or 'pgcrypto' not in extensions:
        raise SystemExit('Hosted E2 requires pgcrypto and PostGIS in the extensions schema.')
    # Other required columns would prevent the harness's id/email-only insert.
    auth_ready, privileges, fixture_columns, unexpected_columns, schema_privilege, fixture_key, rls = conn.execute("""
        select to_regclass('auth.users') is not null,
               (select bool_and(has_table_privilege(to_regclass('auth.users'), privilege))
                  from unnest(array['SELECT','INSERT','DELETE']) as p(privilege)),
               (select count(*) = 2 from information_schema.columns where table_schema='auth'
                 and table_name='users' and ((column_name='id' and udt_name='uuid')
                   or (column_name='email' and udt_name in ('text','varchar','citext')))),
               exists (select 1 from information_schema.columns where table_schema='auth'
                       and table_name='users' and is_nullable='NO' and column_default is null
                       and is_generated='NEVER' and is_identity='NO' and column_name not in ('id','email')),
               has_database_privilege(current_database(), 'CREATE') and has_schema_privilege('public','CREATE'),
               exists (select 1 from pg_index i join pg_attribute a on a.attrelid = i.indrelid
                         where i.indrelid = to_regclass('auth.users') and i.indisprimary and i.indisvalid
                           and a.attname = 'id' and i.indnkeyatts = 1 and i.indkey[0] = a.attnum),
               row_security_active(to_regclass('auth.users'))
    """).fetchone()
    if (not auth_ready or not privileges or not fixture_columns or unexpected_columns
            or not schema_privilege or not fixture_key or rls):
        raise SystemExit('Hosted E2 cannot verify managed Auth fixture access or schema creation privileges.')
    conn.execute("select set_config('request.jwt.claims', %s, true)",
                 (json.dumps({'sub': AUTH_PROBE_ACTOR, 'role': 'authenticated'}),))
    conn.execute('set local role authenticated')
    if conn.execute('select auth.uid()::text, auth.role()').fetchone() != (AUTH_PROBE_ACTOR, 'authenticated'):
        raise SystemExit('Hosted E2 Auth does not recognize the fixture claim context.')
    conn.execute('reset role')
    conn.execute("select set_config('request.jwt.claims', %s, true)", ('{"role":"service_role"}',))
    conn.execute('set local role service_role')
    if conn.execute('select auth.role()').fetchone()[0] != 'service_role':
        raise SystemExit('Hosted E2 Auth does not recognize the recovery role context.')
    conn.execute('reset role')


def check_session_contract(conn):
    """Verify the workload's session-scoped role and claims across read-only transactions."""
    for role, command, actor in (
        ('authenticated', 'set session role authenticated', AUTH_PROBE_ACTOR),
        ('service_role', 'set session role service_role', None),
    ):
        claims = {'role': role}
        if actor is not None:
            claims['sub'] = actor
        with conn.transaction():
            conn.execute('set transaction read only')
            backend = conn.execute('select pg_backend_pid()').fetchone()[0]
            conn.execute(command)
            conn.execute("select set_config('request.jwt.claims', %s, false)", (json.dumps(claims),))
        with conn.transaction():
            conn.execute('set transaction read only')
            actual = conn.execute(
                'select pg_backend_pid(), current_user, auth.uid()::text, auth.role()'
            ).fetchone()
            if actual != (backend, role, actor, role):
                raise SystemExit('Hosted E2 role or JWT claims did not persist across Session Pooler transactions.')
            conn.execute('reset role')
            conn.execute("select set_config('request.jwt.claims', '', false)")


def verify_run_lock(conn):
    held = conn.execute("""
        select exists (
            select 1 from pg_locks where locktype = 'advisory' and pid = pg_backend_pid()
              and database = (select oid from pg_database where datname = current_database())
              and classid = %s and objid = %s and objsubid = 2
              and mode = 'ExclusiveLock' and granted
        )
    """, RUN_LOCK).fetchone()[0]
    if not held:
        raise SystemExit('Hosted E2 lost the project run lock.')
