"""Offline dependencies + two isolated DISABLED HTTP startups, no saved secrets.

Production worker configuration and live ports/journals are never read or used.
"""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[4]


def main():
    # Child processes cannot inherit activation, credentials or libpq overrides.
    env = {k: v for k, v in os.environ.items()
           if not k.upper().startswith(('GEOLOCK_', 'PG', 'PSYCOPG_'))}
    env['PYTHONDONTWRITEBYTECODE'] = '1'
    results = []
    def child(label, args):
        process = subprocess.run([sys.executable, '-B', *args], cwd=ROOT, env=env,
                                 capture_output=True, text=True, timeout=30)
        # Only offline commands with fixed non-secret output are invoked.
        results.append(dict(check=label, exit_code=process.returncode,
                            output=process.stdout.strip(), error=process.stderr.strip()))
        return process.returncode == 0

    ok = child('dependency_versions', ['-c',
        "import json,sys,sqlite3,ortools,psycopg; "
        "print(json.dumps(dict(python=sys.version.split()[0],sqlite=sqlite3.sqlite_version,"
        "ortools=ortools.__version__,psycopg=psycopg.__version__))); "
        "assert sys.version_info[:2]==(3,12); assert ortools.__version__=='9.15.6755'; "
        "assert psycopg.__version__=='3.3.6'"])
    ok = child('native_libpq_no_connection', ['-m',
        'backend.routing.worker_service.connection_diagnostic_native17', '--check-local']) and ok
    ok = child('pinned_profile_and_ca_no_connection', ['-c',
        "from backend.routing.worker_service.native_service_connection import approved_profile; "
        "approved_profile(); print('PINNED_PROFILE_AND_CA_PRESENT / NOT CONNECTED')"]) and ok
    for mode in ('validator', 'planner'):
        ok = child(mode+'_native_disabled_configuration', ['-m',
            'backend.routing.worker_service.native_worker', '--mode', mode, '--check-config']) and ok
        with socket.socket() as reserve:
            reserve.bind(('127.0.0.1', 0))
            port = reserve.getsockname()[1]
        process = subprocess.Popen([sys.executable, '-B', '-m',
            'backend.routing.worker_service', '--mode', mode, '--host', '127.0.0.1',
            '--port', str(port)], cwd=ROOT, env=env,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        result = dict(check=mode+'_isolated_disabled_http', status='FAIL', loopback_port=port)
        try:
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
            deadline = time.monotonic()+15
            while process.poll() is None and time.monotonic() < deadline:
                try:
                    with opener.open(f'http://127.0.0.1:{port}/health', timeout=1) as response:
                        value = json.load(response)
                        assert response.status == 200 and value == {
                            'project_ref': 'rcgyuwiidqvrgbxswhqj', 'status': 'DISABLED'}
                    result.update(status='PASS', health=value)
                    break
                except (OSError, ValueError):
                    time.sleep(.1)
            ok = result['status'] == 'PASS' and ok
        finally:
            if process.poll() is None:
                process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
        result['child_stopped'] = process.poll() is not None
        results.append(result)
    print(json.dumps(dict(status='PASS' if ok else 'FAIL', checks=results,
        dev_access=False, activation=False, saved_profiles_read=False,
        live_ports_or_journals_used=False), indent=2))
    return 0 if ok else 1


if __name__ == '__main__':
    raise SystemExit(main())
