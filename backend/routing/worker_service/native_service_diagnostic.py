"""One native-style prompt, standard libpq service auth, bounded Python SQL checks."""
import json
import sys

from .connection_diagnostic_native17 import configure_client


def main():
    try:
        handle,client=configure_client()
    except Exception:
        print('NATIVE_SERVICE_CLIENT_SETUP_FAILED / NO CONNECTION ATTEMPTED')
        return 2
    try:
        from .native_service_connection import approved_profile, validation_dsn, connect_native, byte_conninfo
        approved_profile()
        if sys.argv[1:]==['--check-local']:
            from psycopg import pq
            synthetic=b"OFFLINE \x82\xe9\xc3 quote' slash\\"
            options={v.keyword:v.val for v in pq.Conninfo.parse(byte_conninfo(synthetic))}
            if options.get(b'password')!=synthetic: raise RuntimeError('NATIVE_BYTE_PARAMETER_SELF_TEST_FAILED')
            print(json.dumps(dict(status='NATIVE_SERVICE_READY / NOT CONNECTED',client=client,
                                  byte_parameter_self_test='PASS / SYNTHETIC ONLY')))
            return 0
        from .connection_diagnostic import main as diagnostic
        from .password_transport_check import read_native_console_password
        def connect():
            # Anonymous stdin pipe from the one prompt; never env/argv/files.
            password=bytearray(sys.stdin.buffer.read(65536))
            return connect_native(password)
        return diagnostic(child_module=__spec__.name,connection_factory=connect,
            dsn_override=validation_dsn(),
            password_reader=lambda:read_native_console_password(b'Graph login password (native console; hidden): '),
            transport_label='native17 libpq service / original password bytes / PQconnectdb')
    except Exception:
        print('NATIVE_SERVICE_DIAGNOSTIC_SETUP_FAILED / NO RETRY PERFORMED')
        return 2
    finally:
        handle.close()


if __name__=='__main__':
    raise SystemExit(main())
