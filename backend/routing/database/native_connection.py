"""Standard libpq service + original native password bytes. No Unicode recoding.

Probe and Windows runtime adapter using public pq.PGconn.connect (PQconnectdb),
then a psycopg Connection wrapper. Does not take over an existing psql session.
"""
import configparser
import hashlib
import os
from pathlib import Path

PROFILE_SHA='01882460fe521e0ea1a50082a3d576c9b2a20208dd4d3ef943b0741cc5adb745'
SERVICE='geolock_dev_graph_initializer'
ROOT=Path(__file__).resolve().parents[3]
PROFILE=ROOT/'docs/stage8/stage-a/deployment-preparation/routing-initialization/pg_service.proposed.conf'


SETTINGS={'host','port','dbname','user','sslmode','sslrootcert','options','connect_timeout'}


def _environment():
    from ..environment import active
    return active()


def profile_path(environment=None):
    """DEV: the tracked, hash-pinned profile. Other environments: an operator file OUTSIDE Git."""
    environment=environment or _environment()
    if environment.is_dev: return PROFILE
    from ..environment import SERVICE_FILE_VARIABLE
    value=os.environ.get(SERVICE_FILE_VARIABLE,'')
    if not value: raise RuntimeError('ENVIRONMENT_SERVICE_PROFILE_REQUIRED')
    path=Path(value).resolve()
    if path==ROOT.resolve() or ROOT.resolve() in path.parents: raise RuntimeError('SERVICE_PROFILE_MUST_BE_OUTSIDE_REPOSITORY')
    return path


def approved_profile():
    environment=_environment()
    if not environment.is_dev: return _environment_profile(environment)
    if hashlib.sha256(PROFILE.read_bytes()).hexdigest()!=PROFILE_SHA:
        raise RuntimeError('APPROVED_SERVICE_PROFILE_DRIFT')
    parser=configparser.ConfigParser(interpolation=None)
    parser.read(PROFILE)
    settings=dict(parser[SERVICE])
    if set(settings)!=SETTINGS:
        raise RuntimeError('UNEXPECTED_SERVICE_SETTINGS')
    if not Path(settings['sslrootcert']).is_file(): raise RuntimeError('APPROVED_CA_MISSING')
    return settings


def _environment_profile(environment):
    # Not hash-pinned (the operator writes the pooler host), so every value is checked
    # against the environment registry instead. The file never contains a password.
    path=profile_path(environment)
    if not path.is_file(): raise RuntimeError('ENVIRONMENT_SERVICE_PROFILE_MISSING')
    parser=configparser.ConfigParser(interpolation=None)
    parser.read(path,encoding='utf-8')
    if parser.sections()!=[environment.service_name]: raise RuntimeError('UNEXPECTED_SERVICE_SECTION')
    settings=dict(parser[environment.service_name])
    if set(settings)!=SETTINGS: raise RuntimeError('UNEXPECTED_SERVICE_SETTINGS')
    host=settings['host']
    if not (host.endswith('.pooler.supabase.com') and host.replace('-','').replace('.','').isalnum() and ',' not in host
            and settings['port']=='5432' and settings['dbname']=='postgres'
            and settings['user']=='geolock_graph_login.'+environment.project_ref
            and settings['sslmode']=='verify-full'
            and settings['options']=='-c default_transaction_read_only=off'
            and settings['connect_timeout'].isdigit()):
        raise RuntimeError('ENVIRONMENT_SERVICE_PROFILE_REJECTED')
    if not Path(settings['sslrootcert']).is_file(): raise RuntimeError('APPROVED_CA_MISSING')
    return settings


def byte_conninfo(password, *, role=None, read_only=True):
    if not isinstance(password,(bytes,bytearray)) or not password or b'\0' in password:
        raise ValueError('NATIVE_PASSWORD_BYTES_REQUIRED')
    # Escape libpq syntax bytes ONLY. No decode/encode/normalization/URI conversion.
    escaped=bytes(password).replace(b'\\',b'\\\\').replace(b"'",b"\\'")
    environment=_environment()
    service=environment.service_name.encode('ascii')
    if role is None:
        return (b'service='+service+b' connect_timeout=5 '
                b"options='-c default_transaction_read_only=on' password='"+escaped+b"'")
    logins={'geolock_graph_worker':'geolock_graph_login','geolock_planner':'geolock_planner_login',
            'geolock_validator':'geolock_validator_login'}
    if role not in logins:raise ValueError('UNAPPROVED_NATIVE_WORKER_ROLE')
    settings=approved_profile()
    # Same hash-pinned service/TLS settings, with an explicit dedicated login.
    # Explicit target/hostaddr/options prevent ambient libpq overrides. Only
    # non-secret configuration is encoded; password bytes never are.
    settings={k:settings[k] for k in ('host','port','dbname','sslmode','sslrootcert')}
    settings.update(user=logins[role]+'.'+environment.project_ref,hostaddr='',
        options='-c default_transaction_read_only=on' if read_only else '',connect_timeout='5')
    def quoted(value):return b"'"+value.encode('utf-8').replace(b'\\',b'\\\\').replace(b"'",b"\\'")+b"'"
    prefix=b'service='+service+b' '+b' '.join(k.encode('ascii')+b'='+quoted(v) for k,v in settings.items())
    return prefix+b" password='"+escaped+b"'"


def connect_native(password, *, connector=None, wrapper=None, role=None, read_only=True):
    import psycopg
    from psycopg import pq
    approved_profile()
    # Explicit approved file; nonempty explicit password avoids passfile fallback.
    os.environ['PGSERVICEFILE']=str(profile_path())
    conninfo=None; pgconn=None
    try:
        conninfo=byte_conninfo(password,role=role,read_only=read_only)
        pgconn=(connector or pq.PGconn.connect)(conninfo)
        if pgconn.status!=pq.ConnStatus.OK:
            # Raw detail exists only in memory; outer diagnostic records fixed markers.
            raise psycopg.OperationalError(pgconn.get_error_message())
        pgconn.nonblocking=1
        connection=(wrapper or psycopg.Connection)(pgconn)
        pgconn=None # ownership transferred; Connection.close() releases libpq memory
        return connection
    finally:
        if pgconn is not None: pgconn.finish()
        if isinstance(password,bytearray): password[:]=b'\0'*len(password)
        conninfo=None


def validation_dsn():
    from psycopg.conninfo import make_conninfo
    settings=approved_profile()
    # Nonsecret expected settings only; actual connection resolves the service above.
    return make_conninfo(**{k:settings[k] for k in ('host','port','dbname','user','sslmode','sslrootcert')})
