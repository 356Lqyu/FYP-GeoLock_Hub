"""Probe-only single native connection; borrowed page contexts always ROLLBACK."""
from .connection_diagnostic import IDENTITY_SQL
from .errors import check
from .native_service_connection import connect_native
from psycopg.pq import TransactionStatus
from time import perf_counter


class NativeReadOnlySession:
    def __init__(self,password,*,connector=connect_native):
        self._password=password;self._connector=connector;self._conn=None
        self._attempted=False;self._closed=False
        self.connections_opened=0;self.page_rollbacks=0;self.cleanup_failed=False
        self.observed_identity=None
        self.initialization_phase='not_started';self.failure_phase=None
        self.sql_seconds={};self.sql_calls={};self.active_sql_phase=None;self.on_profile=None

    def measure(self,phase,operation):
        start=perf_counter();self.active_sql_phase=phase
        if self.on_profile and phase=='rpc_execute':self.on_profile()
        try:return operation()
        finally:
            self.sql_seconds[phase]=self.sql_seconds.get(phase,0)+perf_counter()-start
            self.sql_calls[phase]=self.sql_calls.get(phase,0)+1
            self.active_sql_phase=None
            if self.on_profile and phase=='rpc_fetch_decode':self.on_profile()

    def __call__(self):
        check(not self._closed,'NATIVE_PROBE_SESSION_CLOSED',503)
        if self._conn is None:
            check(not self._attempted,'NATIVE_PROBE_RECONNECT_FORBIDDEN',503)
            self._attempted=True
            try:
                self.initialization_phase='native_connect'
                self._conn=self.measure('native_connect',lambda:self._connector(self._password))
                self.connections_opened+=1
                self.initialization_phase='configure_explicit_read_only_begin'
                check(self._conn.info.transaction_status==TransactionStatus.IDLE,
                      'NATIVE_PROBE_EXPECTED_IDLE_CONNECTION',503)
                # Do not trust service/pooler startup defaults. Psycopg must emit
                # BEGIN READ ONLY before the FIRST identity SELECT and each later
                # page transaction, including after a rollback/backend reassignment.
                self._conn.autocommit=False
                self._conn.read_only=True
                self.initialization_phase='verify_initial_read_only_identity'
                self.observed_identity=self._conn.execute(IDENTITY_SQL).fetchone()[0]
                value=self.observed_identity
                check(value['session_user']==value['current_user']=='geolock_graph_login'
                      and value['database']=='postgres' and value['read_only']=='on' and value['ssl'] is True,
                      'NATIVE_PROBE_IDENTITY_TLS_MISMATCH',503)
                self.initialization_phase='initial_rollback'
                self._conn.rollback()
                check(self._conn.info.transaction_status==TransactionStatus.IDLE,
                      'NATIVE_PROBE_ROLLBACK_NOT_IDLE',503)
                self.initialization_phase='ready'
            except BaseException:
                self.failure_phase=self.initialization_phase
                try:self.close()
                except Exception:self.cleanup_failed=True
                raise
            finally:
                self._password[:]=b'\0'*len(self._password)
        try:
            check(self._conn.info.transaction_status==TransactionStatus.IDLE
                  and self._conn.read_only is True and self._conn.autocommit is False,
                  'NATIVE_PROBE_TRANSACTION_POLICY_DRIFT',503)
        except BaseException:
            self.failure_phase='verify_borrow_policy'
            try:self.close()
            except Exception:self.cleanup_failed=True
            raise
        return Borrowed(self)

    def metrics(self):
        return dict(connection_transport='native17 service / one persistent read-only session',
                    connections_opened=self.connections_opened,page_rollbacks=self.page_rollbacks,
                    connection_closed=self._closed,cleanup_failed=self.cleanup_failed,
                    initialization_phase=self.initialization_phase,failure_phase=self.failure_phase,
                    transaction_policy='explicit psycopg BEGIN READ ONLY; verify each page',
                    sql_seconds={k:round(v,6) for k,v in self.sql_seconds.items()},
                    sql_calls=dict(self.sql_calls),active_sql_phase=self.active_sql_phase,
                    observed_identity=self.observed_identity)

    def close(self):
        self._closed=True
        self._password[:]=b'\0'*len(self._password)
        if self._conn is not None:
            conn=self._conn;self._conn=None
            try:conn.close()
            except Exception:
                self.cleanup_failed=True;raise


class Borrowed:
    def __init__(self,owner):self.owner=owner
    def execute(self,*args,**kwargs):
        return self.owner.measure('read_only_setup',lambda:self.owner._conn.execute(*args,**kwargs))
    def cursor(self,*args,**kwargs):return TimedCursor(self.owner,self.owner._conn.cursor(*args,**kwargs))
    def __getattr__(self,name):return getattr(self.owner._conn,name)
    def __enter__(self):return self
    def __exit__(self,kind,error,tb):
        try:
            self.owner.measure('page_rollback',self.owner._conn.rollback)
            check(self.owner._conn.info.transaction_status==TransactionStatus.IDLE,
                  'NATIVE_PROBE_PAGE_ROLLBACK_NOT_IDLE',503)
            self.owner.page_rollbacks+=1
        except Exception:
            self.owner.cleanup_failed=True
            try:self.owner.close()
            except Exception:pass
            if kind is None:raise
        if kind is not None:
            try:self.owner.close()
            except Exception:self.owner.cleanup_failed=True
        return False
    def close(self):self.owner.close()


class TimedCursor:
    def __init__(self,owner,cursor):self.owner=owner;self.context=cursor;self.current=None;self.phase='setup_execute'
    def __enter__(self):self.current=self.context.__enter__();return self
    def __exit__(self,*args):return self.context.__exit__(*args)
    def execute(self,sql,params=None):
        self.phase='rpc_execute' if sql.startswith('SELECT public.read_frozen_routing_graph(') else 'setup_execute'
        def operation():
            if params is None:return self.current.execute(sql)
            return self.current.execute(sql,params)
        self.owner.measure(self.phase,operation);return self
    def fetchone(self):
        return self.owner.measure('rpc_fetch_decode' if self.phase=='rpc_execute' else 'metadata_fetch',self.current.fetchone)
