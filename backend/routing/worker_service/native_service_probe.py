"""Separately invoked native-service full read-only graph probe. Never starts APIs."""
import json
from pathlib import Path
import shutil
import sys

from .connection_diagnostic_native17 import configure_client


def main():
    try:
        handle,client=configure_client()
    except Exception:
        print('NATIVE_SERVICE_PROBE_CLIENT_SETUP_FAILED / NOT CONNECTED');return 2
    try:
        from .native_service_connection import approved_profile,validation_dsn
        from .probe_resources import host_memory
        approved_profile();memory=host_memory()
        memory['available_disk_mb']=shutil.disk_usage(Path(__file__).resolve().parents[3]).free//(1024*1024)
        if sys.argv[1:]==['--check-local']:
            print(json.dumps(dict(status='NATIVE_FULL_PROBE_READY / NOT CONNECTED',client=client,host_memory=memory)))
            return 0
        if '--child' not in sys.argv and '--run' in sys.argv and memory['available_physical_mb']<6144:
            print('INSUFFICIENT_LOCAL_MEMORY_HEADROOM / NOT CONNECTED');return 2
        if '--child' not in sys.argv and '--run' in sys.argv and memory['available_disk_mb']<2048:
            print('INSUFFICIENT_LOCAL_DISK_HEADROOM / NOT CONNECTED');return 2
        from .native_readonly_session import NativeReadOnlySession
        from .password_transport_check import read_native_console_password
        from .readonly_pilot_probe import main as probe
        session=None
        if '--child' in sys.argv:
            session=NativeReadOnlySession(bytearray(sys.stdin.buffer.read(65536)))
        try:
            return probe(child_module=__spec__.name,connection_factory=session,dsn_override=validation_dsn(),
                password_reader=lambda:read_native_console_password(b'Graph login password (native console; hidden): '),
                default_timeout=600,default_memory=4096)
        finally:
            if session:session.close()
    except Exception:
        print('NATIVE_SERVICE_PROBE_FAILED / PRESERVE REPORT / NO RETRY');return 2
    finally:handle.close()


if __name__=='__main__':
    raise SystemExit(main())
