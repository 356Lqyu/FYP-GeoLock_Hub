"""Windows runtime entrypoint: pinned native libpq; passwords stay native bytes.

--check-runtime-connection is independently READ ONLY and never starts a server.
Normal activation remains guarded by server.py. No secret-bearing DSNs required.
"""
import argparse
from datetime import datetime,timezone
import json
import os
from pathlib import Path
import sys
from uuid import uuid4


class NativeRpcFactory:
    def __init__(self,*,reader=None,connector=None,read_only=False):
        from .password_transport_check import read_native_console_password
        from .native_service_connection import connect_native
        self.reader=reader or read_native_console_password;self.connector=connector or connect_native
        self.read_only=read_only;self.passwords={};self.closed=False

    def __call__(self,dsn,role):
        from .transport import RoleRpc
        from .native_service_connection import approved_profile
        from psycopg.conninfo import conninfo_to_dict
        settings=approved_profile();values=conninfo_to_dict(dsn)
        logins={'geolock_graph_worker':'geolock_graph_login','geolock_planner':'geolock_planner_login','geolock_validator':'geolock_validator_login'}
        if role not in logins or self.closed:raise ValueError('NATIVE_RUNTIME_ROLE_REJECTED')
        expected={k:settings[k] for k in ('host','port','dbname','sslmode')}
        expected['user']=logins[role]+'.rcgyuwiidqvrgbxswhqj'
        if set(values)!=set(expected)|{'sslrootcert'} or any(values.get(k)!=v for k,v in expected.items()) or Path(values['sslrootcert']).resolve()!=Path(settings['sslrootcert']).resolve():
            raise ValueError('NATIVE_RUNTIME_CONFIG_MISMATCH')
        RoleRpc.validate_dsn(dsn)
        # Collect once BEFORE the HTTP server starts, never on an NGO request
        # thread. No database connection is made by constructing the factory.
        if role not in self.passwords:
            password=self.reader((logins[role]+' password (native console; hidden): ').encode('ascii'))
            if not isinstance(password,bytearray) or not password or b'\0' in password:
                if isinstance(password,bytearray):password[:]=b'\0'*len(password)
                raise ValueError('NATIVE_PASSWORD_BYTES_REQUIRED')
            self.passwords[role]=password
        def connect():
            if self.closed:raise RuntimeError('NATIVE_RUNTIME_CLOSED')
            # Normal RoleRpc owns each connection's commit/rollback/close. Never
            # reuse the diagnostic Borrowed wrapper (which always rolls back).
            return self.connector(bytearray(self.passwords[role]),role=role,read_only=self.read_only)
        return RoleRpc(dsn,role,connect=connect)

    def close(self):
        self.closed=True
        for password in self.passwords.values():password[:]=b'\0'*len(password)
        self.passwords.clear()


def check_connection(rpc):
    """Actual RoleRpc factory; bounded catalog SELECTs only; unconditional rollback."""
    from .connection_diagnostic import IDENTITY_SQL
    from .transport import RPCS
    conn=None;phase='connect';report={'role':rpc.role,'status':'FAIL','database_writes':False,'activation':False}
    try:
        conn=rpc._connection()
        conn.autocommit=True
        phase='begin_read_only'
        conn.execute('BEGIN READ ONLY')
        conn.execute("SET LOCAL statement_timeout='10s'")
        conn.execute("SET LOCAL lock_timeout='2s'")
        phase='identity_and_permissions'
        # pg_stat_ssl may redact fields after SET ROLE to a NOLOGIN worker role.
        # Observe TLS while still the authenticated login; do not grant stats
        # privileges or replace a redacted observation with a pinned assertion.
        login_identity=conn.execute(IDENTITY_SQL).fetchone()[0]
        report.update(login_identity=login_identity,tls_client_mode='verify-full')
        conn.execute('SET LOCAL ROLE '+rpc.role)
        identity=conn.execute(IDENTITY_SQL).fetchone()[0]
        report['identity']=identity
        expected={'geolock_graph_worker':'geolock_graph_login','geolock_planner':'geolock_planner_login','geolock_validator':'geolock_validator_login'}[rpc.role]
        if not(login_identity['session_user']==login_identity['current_user']==expected and login_identity['ssl'] is True
            and login_identity['read_only']=='on' and login_identity['database']=='postgres'
            and identity['session_user']==expected and identity['current_user']==rpc.role and identity['database']=='postgres' and identity['read_only']=='on'):
            raise ValueError('NATIVE_RUNTIME_IDENTITY_MISMATCH')
        safe=conn.execute("SELECT NOT r.rolsuper AND NOT r.rolbypassrls AND NOT r.rolcreatedb AND NOT r.rolcreaterole AND pg_has_role(session_user,%s,'MEMBER') AND NOT EXISTS(SELECT 1 FROM pg_roles other WHERE other.rolname IN ('geolock_graph_worker','geolock_planner','geolock_validator') AND other.rolname<>%s AND pg_has_role(session_user,other.oid,'MEMBER')) FROM pg_roles r WHERE r.rolname=session_user",(rpc.role,rpc.role)).fetchone()
        if safe!=(True,):raise ValueError('UNSAFE_RUNTIME_LOGIN')
        signatures={name:name+'('+','.join(types)+')' for functions in RPCS.values() for name,types in functions.items()}
        permissions={}
        for name,signature in signatures.items():
            actual=conn.execute("SELECT has_function_privilege(current_user,%s,'EXECUTE')",('public.'+signature,)).fetchone()[0]
            permissions[name]=actual
            if actual!=(name in RPCS[rpc.role]):raise ValueError('NATIVE_RUNTIME_PRIVILEGE_MISMATCH')
        report.update(identity=identity,permissions=permissions)
        phase='rollback';conn.rollback();report['rollback']=True
        report.update(status='PASS',phase='complete')
    except Exception as error:
        from .probe_diagnostics import safe_failure
        report.update(phase=phase,failure=safe_failure(error,phase))
    finally:
        if conn is not None:
            try:conn.rollback()
            except Exception:report.update(status='FAIL',phase='cleanup_rollback')
            try:conn.close();report['connection_closed']=True
            except Exception:report.update(status='FAIL',phase='cleanup_close',connection_closed=False)
    return report


def main():
    from .connection_diagnostic_native17 import configure_client
    handle=None;factory=None
    try:
        handle,client=configure_client() # MUST precede server/driver imports.
        parser=argparse.ArgumentParser(add_help=False)
        parser.add_argument('--mode',choices=('planner','validator'),default='planner')
        parser.add_argument('--check-runtime-connection',action='store_true')
        args,unknown=parser.parse_known_args()
        factory=NativeRpcFactory(read_only=args.check_runtime_connection)
        if args.check_runtime_connection:
            if unknown or os.environ.get('GEOLOCK_ROUTING_ALLOW_DEV_WRITES')=='APPROVED':raise ValueError('READ_ONLY_CHECK_REQUIRES_ACTIVATION_UNSET')
            from .transport import DEV
            if os.environ.get('GEOLOCK_PROJECT_REF')!=DEV:raise ValueError('DEV_PROJECT_REQUIRED')
            roles=['geolock_validator'] if args.mode=='validator' else ['geolock_planner','geolock_graph_worker']
            dsns={'geolock_planner':'GEOLOCK_PLANNER_DSN','geolock_graph_worker':'GEOLOCK_GRAPH_DSN','geolock_validator':'GEOLOCK_VALIDATOR_DSN'}
            reports=[]
            for role in roles:
                reports.append(check_connection(factory(os.environ[dsns[role]],role)))
                if reports[-1]['status']!='PASS':break # no authentication retry
            root=Path(__file__).resolve().parents[3]
            target=root/'results/worker-runtime-connections'/(datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')+'-'+uuid4().hex[:6])
            target.mkdir(parents=True,exist_ok=False)
            passed=len(reports)==len(roles) and all(r['status']=='PASS' for r in reports)
            report=dict(status='PASS' if passed else 'FAIL',client=client,mode=args.mode,checks=reports,database_writes=False,activation=False)
            (target/'result.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
            print('Read-only runtime evidence: '+str(target/'result.json'))
            return 0 if passed else 1
        from .server import main as serve
        serve(rpc_factory=factory)
        return 0
    except Exception as error:
        from .probe_diagnostics import safe_failure
        print(json.dumps({'status':'FAIL','failure':safe_failure(error,'native_worker_startup')}))
        return 2
    finally:
        if factory:factory.close()
        if handle:handle.close()


if __name__=='__main__':raise SystemExit(main())
