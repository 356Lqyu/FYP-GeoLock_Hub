"""Whitelisted role RPCs + server-verified NGO JWTs. No direct table writes."""
import json
import urllib.error
import urllib.request
from uuid import UUID

from .errors import WorkerError, check

DEV = 'rcgyuwiidqvrgbxswhqj'
BASE = 'https://' + DEV + '.supabase.co'
RPCS = {
    'geolock_graph_worker': {
        'read_frozen_routing_graph': ('uuid', 'bigint', 'integer'),
        'store_routing_matrix': ('uuid', 'uuid', 'jsonb'),
    },
    'geolock_planner': {
        'read_pending_routing_snapshot': ('uuid',),
        'seal_routing_snapshot': ('uuid', 'uuid'),
        'read_routing_snapshot_bundle': ('uuid',),
        'submit_routing_candidate': ('uuid', 'uuid', 'jsonb'),
    },
    'geolock_validator': {
        'read_routing_work_item': ('uuid',),
        'attest_routing_candidate': ('uuid', 'text', 'jsonb'),
    },
}


def uuid(value):
    try:
        check(type(value) is str, 'INVALID_UUID', 400)
        return str(UUID(value))
    except (ValueError, TypeError, AttributeError):
        raise WorkerError('INVALID_UUID', 400) from None


def encode(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False)


def database_error(code, message):
    # Never return a DSN, raw SQL exception, JWT or caller-supplied database text.
    if code in ('40001', '40P01', '55P03', '57014'):
        return WorkerError('DATABASE_BUSY_RETRY', 503, True)
    if message in ('REQUEST_CONFLICT', 'VALIDATION_CONFLICT'):
        return WorkerError('IDEMPOTENCY_CONFLICT_REPLAN', 409)
    if code == '42501':
        return WorkerError('WORKER_DATABASE_PERMISSION_DENIED', 503)
    if any(s in message for s in ('STALE', 'LEASE_TOO_SHORT', 'INVALID_DEPARTURE', 'EXPIRED', 'ACTIVE_ROUTE', 'ALREADY_ASSIGNED')):
        return WorkerError('SNAPSHOT_STALE_OR_RESERVATION_CONFLICT', 409)
    return WorkerError('DATABASE_REJECTED_REQUEST', 409)


class RoleRpc:
    def __init__(self, dsn, role, *, connect=None):
        check(role in RPCS, 'INVALID_WORKER_ROLE', 503)
        self._dsn, self.role, self._connect = dsn, role, connect
        self._phase = 'idle'

    def _failure(self, error):
        # Probe subclasses may record allowlisted metadata before translation.
        # Normal worker responses retain their existing outcome-safety contract.
        observer=getattr(self,'failure_observer',None)
        if observer:
            try:observer(error,self._phase)
            except Exception:pass

    @staticmethod
    def validate_dsn(dsn):
        # Lazy dependency: offline unit tests/disabled startup need no driver.
        try:
            from psycopg.conninfo import conninfo_to_dict
            values = conninfo_to_dict(dsn)
        except Exception:
            raise WorkerError('INVALID_OR_MISSING_DATABASE_DRIVER_CONFIG', 503) from None
        host, user = values.get('host', ''), values.get('user', '')
        direct = host == 'db.' + DEV + '.supabase.co'
        pooled = host.endswith('.pooler.supabase.com') and user.endswith('.' + DEV)
        login = user.split('.')[0]
        check((direct or pooled) and ',' not in host and not values.get('hostaddr'), 'DEV_DATABASE_TARGET_REQUIRED', 503)
        check(login.startswith('geolock_') and login.endswith('_login'), 'DEDICATED_WORKER_LOGIN_REQUIRED', 503)
        check(values.get('sslmode') == 'verify-full' and bool(values.get('sslrootcert')), 'VERIFIED_DATABASE_TLS_REQUIRED', 503)
        check(values.get('dbname', 'postgres') == 'postgres' and values.get('port', '5432') in ('5432','6543'), 'INVALID_DATABASE_TARGET', 503)
        check(not any(k in values for k in ('options','service','passfile')), 'UNREVIEWED_DATABASE_OPTIONS', 503)

    def _connection(self):
        self._phase = 'connect'
        if self._connect is not None:
            return self._connect()
        self._phase = 'connection_configuration'
        self.validate_dsn(self._dsn)
        import psycopg
        from psycopg.conninfo import conninfo_to_dict
        values=conninfo_to_dict(self._dsn)
        # Explicit target fields override ambient PGHOSTADDR/PGPORT/PGOPTIONS.
        self._phase = 'connect'
        conn = psycopg.connect(self._dsn, connect_timeout=5, host=values['host'],hostaddr='',
            port=values.get('port','5432'),dbname='postgres',user=values['user'],options='')
        self._phase = 'connection_open'
        return conn

    def _run(self, name=None, args=()):
        if name is not None:
            check(name in RPCS[self.role] and len(args) == len(RPCS[self.role][name]), 'RPC_NOT_ALLOWED', 403)
        try:
            with self._connection() as conn:
                self._phase = 'open_cursor'
                with conn.cursor() as cur:
                    # The role is a constant whitelist value, never a request field.
                    self._phase = 'set_role'
                    cur.execute('SET LOCAL ROLE ' + self.role)
                    self._phase = 'set_statement_timeout'
                    cur.execute("SET LOCAL statement_timeout = '120s'")
                    self._phase = 'set_lock_timeout'
                    cur.execute("SET LOCAL lock_timeout = '5s'")
                    self._phase = 'verify_login'
                    cur.execute("SELECT pg_has_role(session_user,%s,'MEMBER') AND NOT r.rolsuper AND NOT r.rolbypassrls AND NOT r.rolcreaterole AND NOT r.rolcreatedb AND NOT EXISTS(SELECT 1 FROM pg_roles other WHERE other.rolname IN ('geolock_graph_worker','geolock_planner','geolock_validator') AND other.rolname<>%s AND pg_has_role(session_user,other.oid,'MEMBER')) FROM pg_roles r WHERE r.rolname=session_user", (self.role,self.role))
                    check(cur.fetchone() == (True,), 'UNSAFE_WORKER_LOGIN', 503)
                    if name is None:
                        self._phase = 'read_clock'
                        cur.execute('SELECT clock_timestamp()')
                    else:
                        self._phase = 'encode_rpc_parameters'
                        types = RPCS[self.role][name]
                        params = tuple(encode(v) if t == 'jsonb' else v for v,t in zip(args,types))
                        self._phase = 'execute_rpc'
                        cur.execute('SELECT public.'+name+'('+','.join('%s::'+t for t in types)+')', params)
                    self._phase = 'fetch_result'
                    value = cur.fetchone()[0]
                    self._phase = 'transaction_end'
                    return value
        except WorkerError as e:
            self._failure(e)
            raise
        except Exception as e:
            self._failure(e)
            code = getattr(e, 'sqlstate', None)
            if code is not None:
                message = getattr(getattr(e, 'diag', None), 'message_primary', '') or ''
                raise database_error(code, message) from None
            # Outcome may have committed. Exact request/payload MUST be retried.
            raise WorkerError('RPC_OUTCOME_UNKNOWN_RETRY_SAME_REQUEST', 503, True) from None

    def call(self, name, *args):
        return self._run(name, args)

    def now(self):
        return self._run()


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


class JsonHttp:
    def request(self, url, *, token, key=None, body=None, timeout=15):
        headers = {'Authorization': 'Bearer ' + token, 'Accept':'application/json'}
        if key is not None:
            headers['apikey'] = key
        data = None if body is None else encode(body).encode()
        if data is not None:
            headers['Content-Type'] = 'application/json'
        req = urllib.request.Request(url, headers=headers, data=data)
        try:
            with urllib.request.build_opener(NoRedirect()).open(req, timeout=timeout) as response:
                raw = response.read(8_000_001)
                check(len(raw) <= 8_000_000, 'UPSTREAM_RESPONSE_TOO_LARGE', 502)
                return json.loads(raw)
        except urllib.error.HTTPError as e:
            if e.code in (401,403):
                raise WorkerError('AUTHENTICATION_OR_PERMISSION_DENIED', e.code) from None
            try:
                detail = json.loads(e.read(65536))
                if isinstance(detail.get('error'),dict):
                    # Propagate only fixed internal codes, never arbitrary text.
                    safe = {
                        'RPC_OUTCOME_UNKNOWN_RETRY_SAME_REQUEST':(503,True),
                        'DATABASE_BUSY_RETRY':(503,True),
                        'SNAPSHOT_STALE':(409,False),
                        'IDEMPOTENCY_CONFLICT_REPLAN':(409,False),
                        'ROUTING_INPUT_OR_OUTPUT_INVALID':(422,False),
                    }
                    code=detail['error'].get('code')
                    if code in safe:
                        status,retry=safe[code]
                        raise WorkerError(code,status,retry)
                    raise WorkerError('VALIDATOR_REJECTED_CANDIDATE', 422)
                raise database_error(str(detail.get('code','')), str(detail.get('message','')))
            except WorkerError:
                raise
            except Exception:
                raise WorkerError('UPSTREAM_REJECTED_REQUEST', 502) from None
        except WorkerError:
            raise
        except Exception:
            raise WorkerError('UPSTREAM_OUTCOME_UNKNOWN_RETRY', 503, True) from None


class NgoSession:
    ALLOWED = {'list_my_vehicles', 'get_my_claim_cards_v2', 'authorize_my_routing_candidate',
               'get_my_routing_authorization_receipt', 'get_my_routing_overview',
               'begin_my_routing_snapshot'}

    def __init__(self, user_id, token, key, http):
        self.user_id, self._token, self._key, self._http = user_id, token, key, http

    def rpc(self, name, params=None):
        check(name in self.ALLOWED, 'USER_RPC_NOT_ALLOWED', 403)
        return self._http.request(BASE+'/rest/v1/rpc/'+name, token=self._token, key=self._key, body=params or {})


class SupabaseAuth:
    def __init__(self, publishable_key, http=None):
        check(publishable_key.startswith('sb_publishable_'), 'PUBLISHABLE_KEY_REQUIRED', 503)
        self._key, self._http = publishable_key, http or JsonHttp()

    def verify(self, bearer):
        check(type(bearer) is str and bearer.startswith('Bearer ') and 1 <= len(bearer[7:]) <= 8192, 'AUTHENTICATION_REQUIRED', 401)
        token = bearer[7:]
        value = self._http.request(BASE+'/auth/v1/user', token=token, key=self._key)
        session = NgoSession(uuid(value.get('id')), token, self._key, self._http)
        # Executes the existing NGO-only RPC under the caller's real verified JWT.
        session.rpc('list_my_vehicles')
        return session
