"""Pinned Windows PostgreSQL policy and operator-local CA verification."""
import argparse
import configparser
import hashlib
import os
from pathlib import Path
import ssl

PROFILE_SHA = '01882460fe521e0ea1a50082a3d576c9b2a20208dd4d3ef943b0741cc5adb745'
# Set only after administrator verification and source review. No runtime override.
APPROVED_CA_SHA256 = '700723581420dd1ac98fd7e9ac529f0ef210eadcaf87fc868a3ad7d114c2f3b7'
SERVICE = 'geolock_dev_graph_initializer'
PROJECT = 'rcgyuwiidqvrgbxswhqj'
ROLE_LOGINS = {
    'geolock_graph_worker': 'geolock_graph_login',
    'geolock_planner': 'geolock_planner_login',
    'geolock_validator': 'geolock_validator_login',
}
PROFILE_FIELDS = {'host', 'port', 'dbname', 'user', 'sslmode', 'sslrootcert', 'options', 'connect_timeout'}


class PolicyError(RuntimeError):
    """Fixed message suitable for offline setup output."""


def profile_path():
    directory = os.environ.get('LOCALAPPDATA')
    if not directory or not Path(directory).is_absolute():
        raise PolicyError('OPERATOR_PROFILE_DIRECTORY_REQUIRED')
    return Path(directory) / 'GeoLockHubRoutingDev' / 'pg_service.proposed.conf'


def _approved_ca(ca_path):
    if not ca_path:
        raise PolicyError('LOCAL_CA_PATH_REQUIRED')
    path = Path(ca_path)
    if not path.is_absolute() or path.drive.startswith('\\\\'):
        raise PolicyError('ABSOLUTE_LOCAL_CA_PATH_REQUIRED')
    try:
        path = path.resolve(strict=True)
        if path.drive.startswith('\\\\') or not path.is_file():
            raise PolicyError('ABSOLUTE_LOCAL_CA_PATH_REQUIRED')
        raw = path.read_bytes()
    except (OSError, ValueError):
        raise PolicyError('APPROVED_CA_MISSING_OR_UNREADABLE') from None
    if hashlib.sha256(raw).hexdigest() != APPROVED_CA_SHA256:
        raise PolicyError('APPROVED_CA_CONTENT_MISMATCH')
    if b'PRIVATE KEY-----' in raw:
        raise PolicyError('CA_FILE_MUST_CONTAIN_PUBLIC_CERTIFICATES_ONLY')
    try:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.load_verify_locations(cadata=raw.decode('ascii'))
    except (ssl.SSLError, UnicodeError):
        raise PolicyError('APPROVED_CA_INVALID_PEM') from None
    return str(path)


def approved_profile(ca_path=None):
    if APPROVED_CA_SHA256 is None:
        raise PolicyError('ADMIN_APPROVED_CA_HASH_REQUIRED')
    try:
        raw = profile_path().read_bytes()
    except OSError:
        raise PolicyError('APPROVED_SERVICE_PROFILE_MISSING_OR_UNREADABLE') from None
    if hashlib.sha256(raw).hexdigest() != PROFILE_SHA:
        raise PolicyError('APPROVED_SERVICE_PROFILE_DRIFT')
    parser = configparser.ConfigParser(interpolation=None)
    try:
        parser.read_string(raw.decode('utf-8'))
    except (configparser.Error, UnicodeError):
        raise PolicyError('UNEXPECTED_SERVICE_SETTINGS') from None
    if parser.sections() != [SERVICE] or parser.defaults():
        raise PolicyError('UNEXPECTED_SERVICE_SETTINGS')
    settings = dict(parser[SERVICE])
    if (set(settings) != PROFILE_FIELDS or settings['sslmode'] != 'verify-full'
            or settings['dbname'] != 'postgres' or settings['port'] != '5432'
            or settings['user'] != ROLE_LOGINS['geolock_graph_worker'] + '.' + PROJECT):
        raise PolicyError('UNEXPECTED_SERVICE_SETTINGS')
    settings['sslrootcert'] = _approved_ca(ca_path)
    return settings


def approved_dsn(dsn, role):
    from psycopg.conninfo import conninfo_to_dict
    from .transport import RoleRpc

    if role not in ROLE_LOGINS:
        raise PolicyError('UNAPPROVED_NATIVE_WORKER_ROLE')
    RoleRpc.validate_dsn(dsn)
    values = conninfo_to_dict(dsn)
    settings = approved_profile(values.get('sslrootcert'))
    expected = {key: settings[key] for key in ('host', 'port', 'dbname', 'sslmode')}
    expected['user'] = ROLE_LOGINS[role] + '.' + PROJECT
    if set(values) != set(expected) | {'sslrootcert'} or any(
            values.get(key) != value for key, value in expected.items()):
        raise PolicyError('NATIVE_RUNTIME_CONFIG_MISMATCH')
    return settings


def byte_conninfo(password, *, role=None, read_only=True, ca_path=None):
    if not isinstance(password, (bytes, bytearray)) or not password or b'\0' in password:
        raise ValueError('NATIVE_PASSWORD_BYTES_REQUIRED')
    if role is not None and role not in ROLE_LOGINS:
        raise PolicyError('UNAPPROVED_NATIVE_WORKER_ROLE')
    settings = approved_profile(ca_path)
    params = {key: settings[key] for key in ('host', 'port', 'dbname', 'sslmode', 'sslrootcert')}
    params.update(
        user=settings['user'] if role is None else ROLE_LOGINS[role] + '.' + PROJECT,
        hostaddr='', gssencmode='disable',
        options='-c default_transaction_read_only=on' if read_only or role is None else '',
        connect_timeout='5',
    )

    def quoted(value):
        return b"'" + value.replace(b'\\', b'\\\\').replace(b"'", b"\\'") + b"'"

    prefix = b' '.join(
        key.encode('ascii') + b'=' + quoted(value.encode('utf-8')) for key, value in params.items())
    return prefix + b' password=' + quoted(bytes(password))


def connect_native(password, *, connector=None, wrapper=None, role=None, read_only=True, ca_path=None):
    import psycopg
    from psycopg import pq

    pgconn = None
    conninfo = None
    try:
        # The pinned file is parsed by us, never re-opened by libpq. Reject a
        # default service that could inject settings not in the approved profile.
        if os.environ.get('PGSERVICE'):
            raise PolicyError('AMBIENT_POSTGRESQL_SERVICE_NOT_ALLOWED')
        # Revalidate the bytes on every connect, before passing a password to libpq.
        conninfo = byte_conninfo(password, role=role, read_only=read_only, ca_path=ca_path)
        pgconn = (connector or pq.PGconn.connect)(conninfo)
        if pgconn.status != pq.ConnStatus.OK:
            raise psycopg.OperationalError(pgconn.get_error_message())
        pgconn.nonblocking = 1
        connection = (wrapper or psycopg.Connection)(pgconn)
        pgconn = None
        return connection
    finally:
        if pgconn is not None:
            pgconn.finish()
        if isinstance(password, bytearray):
            password[:] = b'\0' * len(password)
        conninfo = None


def validation_dsn(ca_path=None):
    from psycopg.conninfo import make_conninfo

    settings = approved_profile(ca_path)
    return make_conninfo(**{key: settings[key] for key in ('host', 'port', 'dbname', 'user', 'sslmode', 'sslrootcert')})


def main():
    from .connection_diagnostic_native17 import configure_client

    parser = argparse.ArgumentParser(description='Validate approved settings offline')
    parser.add_argument('--ca-path')
    parser.add_argument('--db-host')
    args = parser.parse_args()
    handle = None
    try:
        handle, _ = configure_client()
        settings = approved_profile(args.ca_path)
        if args.db_host is not None and args.db_host != settings['host']:
            raise PolicyError('APPROVED_DATABASE_HOST_REQUIRED')
        print('PINNED_PROFILE_AND_CA_VALID / NO CONNECTION ATTEMPTED')
        return 0
    except PolicyError as error:
        print(str(error))
        return 1
    except Exception:
        print('OFFLINE_NATIVE_CLIENT_OR_PROFILE_CHECK_FAILED')
        return 1
    finally:
        if handle is not None:
            handle.close()


if __name__ == '__main__':
    raise SystemExit(main())
