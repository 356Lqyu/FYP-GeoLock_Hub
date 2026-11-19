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


def approved_profile():
    if hashlib.sha256(PROFILE.read_bytes()).hexdigest()!=PROFILE_SHA:
        raise RuntimeError('APPROVED_SERVICE_PROFILE_DRIFT')
    parser=configparser.ConfigParser(interpolation=None)
    parser.read(PROFILE)
    settings=dict(parser[SERVICE])
    if set(settings)!={'host','port','dbname','user','sslmode','sslrootcert','options','connect_timeout'}:
        raise RuntimeError('UNEXPECTED_SERVICE_SETTINGS')
    if not Path(settings['sslrootcert']).is_file(): raise RuntimeError('APPROVED_CA_MISSING')
    return settings


def byte_conninfo(password, *, role=None, read_only=True):
    if not isinstance(password,(bytes,bytearray)) or not password or b'\0' in password:
        raise ValueError('NATIVE_PASSWORD_BYTES_REQUIRED')
    # Escape libpq syntax bytes ONLY. No decode/encode/normalization/URI conversion.
    escaped=bytes(password).replace(b'\\',b'\\\\').replace(b"'",b"\\'")
    if role is None:
        return (b'service=geolock_dev_graph_initializer connect_timeout=5 '
                b"options='-c default_transaction_read_only=on' password='"+escaped+b"'")
    logins={'geolock_graph_worker':'geolock_graph_login','geolock_planner':'geolock_planner_login',
            'geolock_validator':'geolock_validator_login'}
    if role not in logins:raise ValueError('UNAPPROVED_NATIVE_WORKER_ROLE')
    settings=approved_profile()
    # Same hash-pinned service/TLS settings, with an explicit dedicated login.
    # Explicit target/hostaddr/options prevent ambient libpq overrides. Only
    # non-secret configuration is encoded; password bytes never are.
    settings={k:settings[k] for k in ('host','port','dbname','sslmode','sslrootcert')}
    settings.update(user=logins[role]+'.rcgyuwiidqvrgbxswhqj',hostaddr='',
        options='-c default_transaction_read_only=on' if read_only else '',connect_timeout='5')
    def quoted(value):return b"'"+value.encode('utf-8').replace(b'\\',b'\\\\').replace(b"'",b"\\'")+b"'"
    prefix=b'service=geolock_dev_graph_initializer '+b' '.join(k.encode('ascii')+b'='+quoted(v) for k,v in settings.items())
    return prefix+b" password='"+escaped+b"'"


def connect_native(password, *, connector=None, wrapper=None, role=None, read_only=True):
    import psycopg
    from psycopg import pq
    approved_profile()
    # Explicit approved file; nonempty explicit password avoids passfile fallback.
    os.environ['PGSERVICEFILE']=str(PROFILE)
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
