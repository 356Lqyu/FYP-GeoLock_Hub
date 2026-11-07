"""Fail-closed, server-only Render configuration; no connection at import."""
from dataclasses import dataclass, field
import ipaddress
import os
from pathlib import Path
from urllib.parse import urlsplit

from ..worker_service.errors import WorkerError, check
from ..worker_service.transport import DEV, RoleRpc, uuid

LOGINS = {'geolock_graph_worker': 'geolock_graph_login',
          'geolock_planner': 'geolock_planner_login', 'geolock_validator': 'geolock_validator_login'}
PREFIXES = {'geolock_graph_worker': 'GEOLOCK_GRAPH', 'geolock_planner': 'GEOLOCK_PLANNER',
            'geolock_validator': 'GEOLOCK_VALIDATOR'}


def https_root(value):
    url = urlsplit(value)
    check(url.scheme == 'https' and bool(url.hostname) and not url.username and not url.password
          and not url.query and not url.fragment and url.path in ('', '/') and url.port in (None, 443),
          'HOSTED_HTTPS_ROOT_REQUIRED', 503)
    return value.rstrip('/')


@dataclass(frozen=True)
class Settings:
    mode: str
    active: bool
    port: int = 10000
    public_url: str = ''
    proxy_networks: tuple = ()
    origins: tuple = ()
    state: Path = Path('/var/data/routing')
    mount: Path = Path('/var/data')
    graph_id: str = ''
    graph_engine: str = 'legacy'
    artifact: str | None = None
    artifact_sha256: str | None = None
    validator_url: str = ''
    max_age: int = 300
    credentials: dict = field(default_factory=dict, repr=False)
    validator_token: str = field(default='', repr=False)
    publishable_key: str = field(default='', repr=False)
    combined: bool = False

    @classmethod
    def from_env(cls, mode, env=None):
        env = os.environ if env is None else env
        try:
            check(mode in ('planner', 'validator'), 'HOSTED_MODE_INVALID', 503)
            port = int(env.get('PORT', '10000'))
            check(1 <= port <= 65535, 'HOSTED_PORT_INVALID', 503)
            if env.get('GEOLOCK_ROUTING_ALLOW_DEV_WRITES') != 'APPROVED':
                return cls(mode=mode, active=False, port=port)
            check(env.get('GEOLOCK_PROJECT_REF') == DEV, 'DEV_PROJECT_REQUIRED', 503)
            check(bool(env.get('GEOLOCK_ROUTING_ACTIVATION_REF', '').strip()), 'ACTIVATION_RECEIPT_REQUIRED', 503)
            public = https_root(env['GEOLOCK_PUBLIC_URL'])
            # Never accept forwarding headers from every peer or infer a trusted
            # client from X-Forwarded-For. The operator must verify ingress CIDRs.
            nets = tuple(ipaddress.ip_network(n.strip()) for n in env.get('GEOLOCK_TRUSTED_PROXY_CIDRS', '').split(',') if n.strip())
            check(bool(nets) and all(n.prefixlen > 0 for n in nets), 'TRUSTED_PROXY_CIDRS_REQUIRED', 503)
            token = env['GEOLOCK_VALIDATOR_TOKEN']
            check(len(token) >= 32, 'VALIDATOR_SECRET_REQUIRED', 503)
            roles = ('geolock_graph_worker', 'geolock_planner') if mode == 'planner' else ('geolock_validator',)
            credentials = {}
            from psycopg.conninfo import conninfo_to_dict
            for role, prefix in PREFIXES.items():
                if role not in roles:
                    check(not any(env.get(prefix + suffix) for suffix in ('_DSN', '_PASSWORD', '_PASSWORD_FILE')),
                          'CROSS_SERVICE_CREDENTIALS_FORBIDDEN', 503)
                    continue
                dsn = env[prefix + '_DSN']
                RoleRpc.validate_dsn(dsn)
                values = conninfo_to_dict(dsn)
                expected = LOGINS[role] + ('.' + DEV if values['host'].endswith('.pooler.supabase.com') else '')
                check(values['user'] == expected and not values.get('password'), 'SCOPED_LOGIN_AND_SEPARATE_PASSWORD_REQUIRED', 503)
                check(Path(values['sslrootcert']).is_file(), 'DATABASE_CA_FILE_REQUIRED', 503)
                password, filename = env.get(prefix + '_PASSWORD'), env.get(prefix + '_PASSWORD_FILE')
                check(bool(password) != bool(filename), 'ONE_PASSWORD_SOURCE_REQUIRED', 503)
                if filename:
                    password = Path(filename).read_text(encoding='utf-8').rstrip('\r\n')
                check(bool(password) and '\0' not in password, 'DATABASE_PASSWORD_REQUIRED', 503)
                credentials[role] = (dsn, password)
            max_age = int(env.get('GEOLOCK_MAX_SNAPSHOT_AGE_SECONDS', '300'))
            check(1 <= max_age <= 1800, 'INVALID_FRESHNESS_LIMIT', 503)
            origins = tuple(https_root(o.strip()) for o in env.get('GEOLOCK_CORS_ORIGINS', '').split(',') if o.strip())
            extra = {}
            if mode == 'planner':
                check(Path(env['GEOLOCK_STATE_MOUNT']).is_absolute() and Path(env['GEOLOCK_WORKER_STATE']).is_absolute(),
                      'ABSOLUTE_STATE_PATH_REQUIRED', 503)
                mount = Path(env['GEOLOCK_STATE_MOUNT']).resolve()
                state = Path(env['GEOLOCK_WORKER_STATE']).resolve()
                check(mount.is_absolute() and state.is_relative_to(mount) and state != mount,
                      'PERSISTENT_STATE_PATH_REQUIRED', 503)
                check(env.get('GEOLOCK_PERSISTENCE_MODE') == 'mounted-disk', 'PERSISTENT_RECOVERY_REQUIRED', 503)
                graph_id = uuid(env['GEOLOCK_GRAPH_ID'])
                engine = env.get('GEOLOCK_GRAPH_ENGINE', 'legacy')
                check(engine in ('legacy', 'compact'), 'GRAPH_ENGINE_INVALID', 503)
                artifact, seal = env.get('GEOLOCK_COMPACT_ARTIFACT'), env.get('GEOLOCK_COMPACT_ARTIFACT_SHA256')
                check(bool(artifact) == bool(seal) and (not artifact or engine == 'compact'), 'COMPACT_ARTIFACT_CONFIG_INVALID', 503)
                key = env['GEOLOCK_SUPABASE_PUBLISHABLE_KEY']
                check(key.startswith('sb_publishable_'), 'PUBLISHABLE_KEY_REQUIRED', 503)
                extra = dict(state=state, mount=mount, graph_id=graph_id, graph_engine=engine,
                             artifact=artifact, artifact_sha256=seal,
                             validator_url=https_root(env['GEOLOCK_VALIDATOR_URL']), publishable_key=key,
                             combined=env.get('GEOLOCK_COMBINED_ROUTE_ENABLED') == 'APPROVED')
            return cls(mode=mode, active=True, port=port, public_url=public, proxy_networks=nets,
                       origins=origins, credentials=credentials, validator_token=token, max_age=max_age, **extra)
        except WorkerError:
            raise
        except Exception:
            # No underlying DSN, path contents or password is printed.
            raise WorkerError('HOSTED_CONFIGURATION_INVALID', 503) from None

    def trusted_https(self, peer, headers):
        try:
            address = ipaddress.ip_address(peer)
            return (any(address in network for network in self.proxy_networks)
                    and headers.get_all('X-Forwarded-Proto', []) == ['https']
                    and headers.get_all('Host', []) in ([urlsplit(self.public_url).netloc],
                                                       [urlsplit(self.public_url).hostname + ':443']))
        except (ValueError, TypeError):
            return False
