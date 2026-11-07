"""Shared business code, separate Linux bootstrap and preflight readiness."""
from pathlib import Path
import os
import threading
from uuid import UUID, uuid5

from .compact_graph import CompactGraphCache
from ..worker_service.errors import WorkerError, check
from ..worker_service.graph_cache import GraphCache
from ..worker_service.journal import Journal
from ..worker_service.orchestrator import RoutingWorker
from ..worker_service.server import Application, request_event
from ..worker_service.transport import DEV, JsonHttp, RoleRpc, SupabaseAuth
from ..worker_service.validator import Validator, RemoteValidator


def scoped_rpc(settings, role):
    dsn, password = settings.credentials[role]
    from psycopg.conninfo import conninfo_to_dict
    values = conninfo_to_dict(dsn)
    def connect():
        import psycopg
        # Explicit fields neutralize ambient PGHOSTADDR/PGOPTIONS and keep the
        # password separate from argv/DSN. RoleRpc owns transactions and checks.
        return psycopg.connect(dsn, password=password, connect_timeout=5, host=values['host'],
                               hostaddr='', port=values.get('port', '5432'), dbname='postgres',
                               user=values['user'], options='')
    rpc = RoleRpc(dsn, role, connect=connect)
    rpc.failure_observer = lambda error, phase: request_event(dict(stage='rpc_failed', role=role,
        rpc_phase=phase, exception_type=type(error).__name__, sqlstate=getattr(error, 'sqlstate', None)))
    return rpc


class Runtime:
    def __init__(self, settings, *, rpc_factory=None, mount_check=os.path.ismount,
                 validator_health=None):
        self.settings = settings
        self.app = Application(active=False)
        self.ready = False
        self.closing = False
        self.reason = 'DISABLED'
        self.graph_ready = False
        self._instance_lock = None
        self._rpc_factory = rpc_factory or (lambda role: scoped_rpc(settings, role))
        self._mount_check = mount_check
        self._validator_health = validator_health or self._read_validator_health
        self._prepare_lock = threading.Lock()

    def _read_validator_health(self):
        return JsonHttp().request(self.settings.validator_url + '/health', token=self.settings.validator_token, timeout=5)

    def prepare(self):
        # Called once by a background startup thread, never by /health. No
        # retries, snapshot creation, graph freeze or business writes occur here.
        if not self.settings.active:
            return
        with self._prepare_lock:
            if self.closing or self.ready or self.reason not in ('DISABLED',):
                return
            self.reason = 'WARMING'
            try:
                s = self.settings
                if s.mode == 'validator':
                    rpc = self._rpc_factory('geolock_validator')
                    rpc.now()  # Scoped connection/login/TLS/clock checks, SELECT only.
                    self.app = Application(validator=Validator(rpc, max_age_seconds=s.max_age),
                                           validator_token=s.validator_token, active=True)
                else:
                    check(self._mount_check(s.mount), 'PERSISTENT_MOUNT_NOT_VERIFIED', 503)
                    s.state.mkdir(parents=True, exist_ok=True)
                    if os.name != 'nt':
                        s.state.chmod(0o700)
                    journal = Journal(s.state / 'journal')
                    self._instance_lock = journal.operation_lock(str(uuid5(UUID(DEV_UUID), 'hosted-planner-instance')))
                    self._instance_lock.__enter__()
                    graph_rpc = self._rpc_factory('geolock_graph_worker')
                    planner_rpc = self._rpc_factory('geolock_planner')
                    planner_rpc.now()
                    if s.graph_engine == 'compact':
                        graph = CompactGraphCache(graph_rpc, s.graph_id, s.state / 'graphs',
                                                  artifact=s.artifact, artifact_sha256=s.artifact_sha256)
                    else:
                        graph = GraphCache(graph_rpc, s.graph_id, s.state / 'graphs')
                    worker = RoutingWorker(planner_rpc, graph, RemoteValidator(s.validator_url, s.validator_token),
                                           journal, max_age_seconds=s.max_age, observe=request_event)
                    # Recovery reads stay available if graph prewarm fails later.
                    self.app = Application(auth=SupabaseAuth(s.publishable_key), worker=worker,
                                           active=True, combined_enabled=s.combined, exact_enabled=False)
                    graph.warm() if isinstance(graph, CompactGraphCache) else graph.load()
                    self.graph_ready = True
                    health = self._validator_health()
                    check(health.get('status') == 'ACTIVE' and health.get('project_ref') == DEV,
                          'VALIDATOR_NOT_READY', 503)
                if not self.closing:
                    self.ready = True
                    self.reason = 'READY'
            except WorkerError as error:
                self.reason = error.code
            except Exception:
                self.reason = 'HOSTED_STARTUP_FAILED'

    def health(self):
        return dict(status='ACTIVE' if self.ready and not self.closing else self.reason,
                    project_ref=DEV, mode=self.settings.mode, graph_ready=self.graph_ready)

    def close(self):
        self.closing = True
        self.ready = False
        self.reason = 'DRAINING'
        with self._prepare_lock:
            if self._instance_lock is not None:
                try:
                    self._instance_lock.__exit__(None, None, None)
                except (AttributeError, RuntimeError):
                    pass
                self._instance_lock = None


# Fixed local file-lock namespace, not a database identity or credential.
DEV_UUID = '9a4c9a52-df94-4d1a-9b83-5f7347d8ef77'
