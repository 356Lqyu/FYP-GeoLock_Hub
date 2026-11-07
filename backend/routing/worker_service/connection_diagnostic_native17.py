"""Bounded diagnostic using the same installed libpq17.11 as native psql.

Only this process/diagnostic child is configured; no package upgrade or live-worker
configuration change. --check-local imports/checks the client without connecting.
"""
import json
import os
from pathlib import Path
import sys


def configure_client():
    folder=Path('C:/Program Files/PostgreSQL/17/bin')
    if sys.platform!='win32' or not (folder/'libpq.dll').is_file():
        raise RuntimeError('NATIVE_POSTGRESQL17_LIBRARY_REQUIRED')
    if 'psycopg' in sys.modules:
        raise RuntimeError('CLIENT_ALREADY_IMPORTED')
    os.environ['PSYCOPG_IMPL']='python'
    os.environ['PATH']=str(folder)+os.pathsep+os.environ.get('PATH','')
    handle=os.add_dll_directory(str(folder))
    try:
        import psycopg
        from psycopg import pq
        from psycopg.pq.misc import find_libpq_full_path
        if pq.__impl__!='python' or pq.version()!=170011 or Path(find_libpq_full_path()).resolve()!=(folder/'libpq.dll').resolve():
            raise RuntimeError('NATIVE_LIBPQ_VERSION_OR_PATH_MISMATCH')
        return handle,dict(psycopg=psycopg.__version__,implementation=pq.__impl__,libpq_version=pq.version())
    except BaseException:
        handle.close()
        raise


def main():
    try:
        handle,client=configure_client()
    except Exception:
        print('NATIVE17_DIAGNOSTIC_CLIENT_SETUP_FAILED / NO CONNECTION ATTEMPTED')
        return 2
    try:
        if sys.argv[1:]==['--check-local']:
            print(json.dumps(dict(status='NATIVE17_CLIENT_READY / NOT CONNECTED',client=client)))
            return 0
        if sys.argv[1:]==['--password-transport-check']:
            from .password_transport_check import main as compare_password
            return compare_password()
        from .connection_diagnostic import main as diagnostic
        return diagnostic(child_module=__spec__.name)
    finally:
        handle.close()


if __name__=='__main__':
    raise SystemExit(main())
