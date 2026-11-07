"""Manual normal-user Windows environment smoke only. NON-PARITY.

No imports from GeoLock, migrations, compatibility harnesses or database drivers.
No external DSN, arbitrary SQL, existing cluster or service arguments accepted.
Do not launch from Codex. See docs/stage8/stage-c5/ENVIRONMENT_SMOKE.md.
"""
import argparse
import ctypes
from ctypes import wintypes
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import time
import traceback
import uuid

ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / 'docs/stage8/stage-c5/environment-smoke-runtime-manifest.json'
LANE = 'NON-PARITY'
ERROR_OUTPUT = re.compile(
    r'could not (?:create|re-execute with|open) restricted token|'
    r'could not re-execute with restricted token|could not open process token|'
    r'could not start (?:server|process)|'
    r'\b(?:initdb|pg_ctl|postgres|psql)(?:\.exe)?:\s*(?:error|fatal|panic)\b|'
    r'\b(?:FATAL|PANIC)\s*:|\bERROR\s*:', re.I)


class Blocked(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise Blocked(message)


def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def reject_diagnostics(code, stdout, stderr):
    """Success text/exit zero never overrides a restriction or error diagnostic."""
    require(code == 0, f'PROCESS_EXIT_{code}')
    require(not ERROR_OUTPUT.search(stdout + '\n' + stderr),
            'ERROR_DIAGNOSTIC_EVEN_IF_EXIT_ZERO')


def no_links(path):
    for part in (path, *path.parents):
        if part.exists():
            require(not part.is_symlink() and not part.is_junction(), f'LINK_OR_JUNCTION: {part}')
            require(not (part.stat().st_file_attributes & 0x400), f'REPARSE_POINT: {part}')


class Windows:
    """Read-only token, owner and known-process inspection; no privilege changes."""
    def __init__(self):
        require(os.name == 'nt', 'WINDOWS_ONLY')
        self.k = ctypes.WinDLL('kernel32', use_last_error=True)
        self.a = ctypes.WinDLL('advapi32', use_last_error=True)
        self.k.GetCurrentProcess.restype = wintypes.HANDLE
        self.k.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        self.k.OpenProcess.restype = wintypes.HANDLE
        self.k.CloseHandle.argtypes = [wintypes.HANDLE]
        self.k.LocalFree.argtypes = [wintypes.HLOCAL]
        self.k.LocalFree.restype = wintypes.HLOCAL
        self.k.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
        self.k.WaitForSingleObject.restype = wintypes.DWORD
        self.k.QueryFullProcessImageNameW.argtypes = [wintypes.HANDLE, wintypes.DWORD,
                                                    wintypes.LPWSTR, ctypes.POINTER(wintypes.DWORD)]
        self.k.GetProcessTimes.argtypes = [wintypes.HANDLE, *([ctypes.POINTER(wintypes.FILETIME)] * 4)]
        self.a.OpenProcessToken.argtypes = [wintypes.HANDLE, wintypes.DWORD,
                                            ctypes.POINTER(wintypes.HANDLE)]
        self.a.GetTokenInformation.argtypes = [wintypes.HANDLE, ctypes.c_int, wintypes.LPVOID,
                                               wintypes.DWORD, ctypes.POINTER(wintypes.DWORD)]
        self.a.ConvertSidToStringSidW.argtypes = [wintypes.LPVOID, ctypes.POINTER(wintypes.LPWSTR)]
        self.a.LookupAccountSidW.argtypes = [wintypes.LPCWSTR, wintypes.LPVOID, wintypes.LPWSTR,
            ctypes.POINTER(wintypes.DWORD), wintypes.LPWSTR, ctypes.POINTER(wintypes.DWORD),
            ctypes.POINTER(wintypes.DWORD)]
        self.a.IsTokenRestricted.argtypes = [wintypes.HANDLE]
        self.a.IsTokenRestricted.restype = wintypes.BOOL
        self.a.GetNamedSecurityInfoW.argtypes = [wintypes.LPWSTR, ctypes.c_int, wintypes.DWORD,
            ctypes.POINTER(wintypes.LPVOID), wintypes.LPVOID, wintypes.LPVOID, wintypes.LPVOID,
            ctypes.POINTER(wintypes.LPVOID)]
        self.a.GetNamedSecurityInfoW.restype = wintypes.DWORD

    def check(self, value, operation):
        if not value:
            raise Blocked(f'{operation}: Windows error {ctypes.get_last_error()}')

    def sid_text(self, sid):
        text = wintypes.LPWSTR()
        self.check(self.a.ConvertSidToStringSidW(sid, ctypes.byref(text)), 'SID_TO_STRING')
        try:
            return text.value
        finally:
            self.k.LocalFree(ctypes.cast(text, wintypes.HLOCAL))

    def token_info(self, token, kind):
        length = wintypes.DWORD()
        ctypes.set_last_error(0)
        ok = self.a.GetTokenInformation(token, kind, None, 0, ctypes.byref(length))
        require(not ok and ctypes.get_last_error() == 122 and length.value > 0,
                'TOKEN_INFO_SIZE_UNAVAILABLE')
        buffer = ctypes.create_string_buffer(length.value)
        self.check(self.a.GetTokenInformation(token, kind, buffer, length, ctypes.byref(length)), 'TOKEN_INFO')
        return buffer

    def identity(self):
        token = wintypes.HANDLE()
        self.check(self.a.OpenProcessToken(self.k.GetCurrentProcess(), 0x8, ctypes.byref(token)), 'OPEN_OWN_TOKEN')
        try:
            user = self.token_info(token, 1)  # TOKEN_USER starts with SID pointer
            sid = ctypes.cast(user, ctypes.POINTER(wintypes.LPVOID))[0]
            name, domain = ctypes.create_unicode_buffer(512), ctypes.create_unicode_buffer(512)
            nl, dl, use = wintypes.DWORD(512), wintypes.DWORD(512), wintypes.DWORD()
            self.check(self.a.LookupAccountSidW(None, sid, name, ctypes.byref(nl), domain,
                        ctypes.byref(dl), ctypes.byref(use)), 'LOOKUP_OWN_SID')
            elevated = ctypes.cast(self.token_info(token, 20), ctypes.POINTER(wintypes.DWORD))[0]
            integrity = self.token_info(token, 25)
            integrity_sid = ctypes.cast(integrity, ctypes.POINTER(wintypes.LPVOID))[0]
            integrity_text = self.sid_text(integrity_sid)
            restricted_groups = self.token_info(token, 11)
            restricted_count = ctypes.cast(restricted_groups, ctypes.POINTER(wintypes.DWORD))[0]
            restricted = bool(self.a.IsTokenRestricted(token))
            return dict(account=domain.value + '\\' + name.value, sid=self.sid_text(sid),
                elevated=bool(elevated), integrity_sid=integrity_text,
                restricted=restricted, restricted_sid_count=int(restricted_count),
                env_username=os.environ.get('USERNAME'), env_userprofile=os.environ.get('USERPROFILE'))
        finally:
            self.k.CloseHandle(token)

    def owner(self, path):
        owner, descriptor = wintypes.LPVOID(), wintypes.LPVOID()
        code = self.a.GetNamedSecurityInfoW(str(path), 1, 1, ctypes.byref(owner), None, None, None,
                                            ctypes.byref(descriptor))
        require(code == 0, f'OWNER_QUERY_ERROR_{code}: {path}')
        try:
            return self.sid_text(owner)
        finally:
            self.k.LocalFree(descriptor)

    def open_owned_process(self, pid, exe, since):
        handle = self.k.OpenProcess(0x1000 | 0x100000, False, pid)  # query limited + synchronize
        self.check(handle, 'OPEN_KNOWN_POSTMASTER')
        try:
            image = ctypes.create_unicode_buffer(32768)
            length = wintypes.DWORD(len(image))
            self.check(self.k.QueryFullProcessImageNameW(handle, 0, image, ctypes.byref(length)), 'PROCESS_IMAGE')
            require(Path(image.value).resolve() == exe.resolve(), 'POSTMASTER_BINARY_IDENTITY_MISMATCH')
            created, exited, kernel, user = (wintypes.FILETIME() for _ in range(4))
            self.check(self.k.GetProcessTimes(handle, ctypes.byref(created), ctypes.byref(exited),
                       ctypes.byref(kernel), ctypes.byref(user)), 'PROCESS_CREATION_TIME')
            seconds = (((created.dwHighDateTime << 32) | created.dwLowDateTime) / 10000000) - 11644473600
            require(since - 2 <= seconds <= time.time() + 2, 'POSTMASTER_PROCESS_PREDATES_ATTEMPT')
            require(self.k.WaitForSingleObject(handle, 0) == 258, 'POSTMASTER_ALREADY_EXITED')
            return handle
        except BaseException:
            self.k.CloseHandle(handle)
            raise


class Smoke:
    def __init__(self, args):
        self.args = args
        self.win = Windows()
        self.started_at = time.monotonic()
        self.out = None
        self.marker = 'geolock-env-smoke-' + uuid.uuid4().hex
        self.phase = 'preflight'
        self.start_attempted = False
        self.start_verified = False
        self.handle = None
        self.pid = None
        self.seq = 0
        self.processes = []
        self.cleanup = dict(state='NOT_STARTED', shutdown_confirmed=False)
        self.error = None
        self.identity_result = None
        self.versions = None

    def save(self, name, data):
        if self.out:
            (self.out / name).write_text(json.dumps(dict(lane=LANE, **data), indent=2) + '\n', encoding='utf-8')

    def preflight(self):
        require(sys.version_info >= (3, 12), 'PYTHON_3_12_OR_LATER_REQUIRED')
        actual = self.win.identity()
        require(actual['account'].casefold() == self.args.expected_user.casefold(), 'ACTUAL_USER_MISMATCH')
        require('codexsandbox' not in actual['account'].casefold(), 'SANDBOX_ACCOUNT_REJECTED')
        require(not actual['elevated'], 'ELEVATED_TERMINAL_REJECTED')
        require(not actual['restricted'] and actual['restricted_sid_count'] == 0, 'RESTRICTED_TOKEN_REJECTED')
        require(actual['integrity_sid'] == 'S-1-16-8192', 'NORMAL_MEDIUM_INTEGRITY_TERMINAL_REQUIRED')
        require(not any(k.upper() == 'PG_RESTRICT_EXEC' for k in os.environ), 'PG_RESTRICT_EXEC_OVERRIDE_REJECTED')
        no_links(ROOT)
        no_links(MANIFEST)
        manifest = json.loads(MANIFEST.read_text(encoding='utf-8-sig'))
        require(manifest['lane'] == LANE and manifest['purpose'] == 'ENVIRONMENT_ONLY', 'MANIFEST_SCOPE')
        require(sha(Path(__file__).resolve()) == manifest['runner_sha256'], 'RUNNER_HASH_MISMATCH')
        self.pg = Path(manifest['runtime_root']).resolve()
        no_links(self.pg)
        require(self.pg.name == 'pgsql' and self.pg.parent.name.startswith('geolock-spatial-runtime-'),
                'PRIVATE_RUNTIME_REQUIRED')
        # Verify the entire retained distribution, including libraries and extension SQL.
        found = {}
        for p in self.pg.rglob('*'):
            no_links(p)
            if p.is_file():
                found[p.relative_to(self.pg).as_posix()] = sha(p)
        require(found == manifest['files'], 'RUNTIME_CONTENT_OR_FILE_SET_MISMATCH')
        for name in ('postgres.exe', 'initdb.exe', 'pg_ctl.exe', 'psql.exe'):
            require('bin/' + name in found, 'PINNED_EXECUTABLE_MISSING')
        evidence_parent = ROOT / 'results/stage-c5'
        no_links(evidence_parent)
        require(evidence_parent.is_dir(), 'EXISTING_EVIDENCE_PARENT_REQUIRED')
        self.out = evidence_parent / ('environment-smoke-' + dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ-') + uuid.uuid4().hex[:12])
        self.out.mkdir(exist_ok=False)
        no_links(self.out)
        require(self.win.owner(self.out) == actual['sid'], 'NEW_EVIDENCE_DIRECTORY_NOT_OWNED_BY_USER')
        self.data = self.out / 'data'
        require(not self.data.exists(), 'FRESH_DATA_DIRECTORY_REQUIRED')
        self.env = {k: v for k, v in os.environ.items()
                    if not k.upper().startswith(('PG', 'PSQL', 'SUPABASE', 'GEOLOCK'))
                    and k.upper() not in ('DATABASE_URL', 'DB_URL')}
        system_root = Path(os.environ.get('SystemRoot', ''))
        comspec = Path(os.environ.get('COMSPEC', ''))
        require(comspec.is_absolute() and comspec.is_file() and
                comspec.resolve() == (system_root / 'System32/cmd.exe').resolve(), 'COMSPEC_IDENTITY_UNCERTAIN')
        self.env.update(PATH=str(self.pg / 'bin') + os.pathsep + self.env.get('PATH', ''),
            PGPASSFILE=str(self.out / 'nonexistent-password-file'), PGCONNECT_TIMEOUT='3',
            PGCLIENTENCODING='UTF8', PGSSLMODE='disable', PGHOSTADDR='127.0.0.1',
            PGAPPNAME=self.marker, PGOPTIONS='-c TimeZone=UTC -c search_path=pg_catalog')
        self.save('preflight.json', dict(actual_windows_identity=actual, runtime_root=str(self.pg),
            runtime_files_verified=len(found), runtime_manifest_sha256=sha(MANIFEST),
            runner_sha256=sha(Path(__file__)), python=sys.version, os_version=sys.getwindowsversion()[:5],
            comspec=str(comspec), working_directory=str(ROOT), marker=self.marker,
            output_owner_sid=self.win.owner(self.out), extension_probe_explicit=self.args.probe_extensions,
            scope='ENVIRONMENT_ONLY_NO_BUSINESS_SCHEMA_NO_MIGRATIONS'))
        (self.out / 'runtime-manifest.json').write_bytes(MANIFEST.read_bytes())
        print('NON-PARITY evidence:', self.out, flush=True)

    def invoke(self, name, args, timeout=30, cleanup=False):
        require(self.out is not None, 'PREFLIGHT_REQUIRED')
        require(name in ('postgres', 'initdb', 'pg_ctl', 'psql'), 'UNAPPROVED_EXECUTABLE')
        if not cleanup:
            require(time.monotonic() - self.started_at < 300, 'SMOKE_FIVE_MINUTE_LIMIT')
            timeout = min(timeout, max(1, 300 - (time.monotonic() - self.started_at)))
        exe = self.pg / 'bin' / (name + '.exe')
        manifest = json.loads((self.out / 'runtime-manifest.json').read_text(encoding='utf-8-sig'))
        require(sha(exe) == manifest['files']['bin/' + name + '.exe'], 'EXECUTABLE_DRIFT')
        self.seq += 1
        prefix = f'{self.seq:02d}-{name}'
        out_path, err_path = self.out / (prefix + '.stdout.log'), self.out / (prefix + '.stderr.log')
        record = dict(lane=LANE, phase=self.phase, executable=str(exe), arguments=args,
                      stdout=out_path.name, stderr=err_path.name, timeout_seconds=timeout)
        start = time.monotonic()
        try:
            # Disk files avoid Windows inherited-pipe hangs when pg_ctl starts a server.
            with out_path.open('wb') as out, err_path.open('wb') as err:
                proc = subprocess.run([str(exe), *args], cwd=ROOT, env=self.env, stdout=out,
                    stderr=err, timeout=timeout, shell=False, creationflags=subprocess.CREATE_NO_WINDOW)
            record['exit_code'] = proc.returncode
            stdout = out_path.read_text(encoding='utf-8', errors='replace')
            stderr = err_path.read_text(encoding='utf-8', errors='replace')
            reject_diagnostics(proc.returncode, stdout, stderr)
            return stdout.strip()
        except BaseException as error:
            record['exception'] = str(error)
            raise
        finally:
            record['elapsed_seconds'] = time.monotonic() - start
            self.processes.append(record)
            self.save('processes.json', dict(processes=self.processes))

    def bind_pid(self):
        require(self.start_attempted, 'NO_OWNED_START_ATTEMPT')
        no_links(self.data)
        pid_path = self.data / 'postmaster.pid'
        require(pid_path.is_file(), 'NO_PID_FILE_STARTUP_OR_CLEANUP_UNCERTAIN')
        no_links(pid_path)
        lines = pid_path.read_text(encoding='utf-8').splitlines()
        require(len(lines) >= 6, 'INCOMPLETE_PID_FILE')
        pid = int(lines[0])
        require(pid > 0 and Path(lines[1]).resolve() == self.data.resolve(), 'PID_DATA_DIRECTORY_MISMATCH')
        require(int(lines[3]) == self.port and lines[5] == '127.0.0.1', 'PID_ENDPOINT_MISMATCH')
        require(int(lines[2]) >= int(self.launch_wall) - 2, 'STALE_PID_FILE')
        require(self.win.owner(self.data) == self.windows_sid, 'DATA_DIRECTORY_OWNER_CHANGED')
        if self.handle is None:
            self.handle = self.win.open_owned_process(pid, self.pg / 'bin/postgres.exe', self.launch_wall)
            self.pid = pid
        require(self.pid == pid and self.win.k.WaitForSingleObject(self.handle, 0) == 258,
                'OWNED_PROCESS_EXITED_OR_PID_CHANGED')

    def query(self, name):
        """Only three fixed inputs; no SQL/DSN supplied by the caller or command line."""
        self.bind_pid()
        quoted_marker = "'" + self.marker + "'"
        data_sql = "'" + str(self.data.resolve()).replace('\\', '/').replace("'", "''") + "'"
        gate = f"""DO $ownership$ BEGIN
          IF inet_server_addr()::text <> '127.0.0.1' OR inet_server_port() <> {self.port}
             OR current_setting('cluster_name') <> {quoted_marker}
             OR replace(current_setting('data_directory'),chr(92),'/') <> {data_sql}
             OR current_user <> 'postgres' OR session_user <> 'postgres'
          THEN RAISE EXCEPTION 'OWNED_SMOKE_INSTANCE_REQUIRED'; END IF;
        END $ownership$;
        """
        identity = """SELECT json_build_object('server_version',current_setting('server_version'),
          'server_version_num',current_setting('server_version_num'),'host',inet_server_addr(),
          'port',inet_server_port(),'data_directory',current_setting('data_directory'),
          'cluster_name',current_setting('cluster_name'),'current_user',current_user,'session_user',session_user,
          'isolation',current_setting('transaction_isolation'),'listen_addresses',current_setting('listen_addresses'),
          'max_connections',current_setting('max_connections'),'timezone',current_setting('TimeZone'));
        """
        extensions = """SELECT json_build_object('postgis',extensions.postgis_full_version(),
          'pgrouting',extensions.pgr_full_version(),'extensions',
          (SELECT json_agg(json_build_object('name',e.extname,'version',e.extversion,
           'schema',n.nspname) ORDER BY e.extname) FROM pg_extension e JOIN pg_namespace n ON n.oid=e.extnamespace));
        """
        if name == 'identity':
            sql = gate + identity
        elif name == 'extension-load':
            require(self.args.probe_extensions and self.start_verified, 'EXPLICIT_EXTENSION_PROBE_REQUIRED')
            sql = 'BEGIN;\n' + gate + "CREATE SCHEMA extensions AUTHORIZATION postgres;\n" + \
                  "CREATE EXTENSION postgis WITH SCHEMA extensions;\n" + \
                  "CREATE EXTENSION pgrouting WITH SCHEMA extensions;\nCOMMIT;\n"
        elif name == 'extension-versions':
            require(self.args.probe_extensions and self.start_verified, 'EXPLICIT_EXTENSION_PROBE_REQUIRED')
            sql = gate + extensions
        else:
            raise Blocked('UNAPPROVED_SQL_OPERATION')
        path = self.out / (name + '.sql')
        require(not path.exists(), 'SQL_EVIDENCE_REUSE')
        path.write_text(sql, encoding='utf-8', newline='\n')
        return self.invoke('psql', ['-X', '--no-password', '-qAt', '-P', 'pager=off',
            '-v', 'ON_ERROR_STOP=1', '-v', 'VERBOSITY=verbose', '-h', '127.0.0.1',
            '-p', str(self.port), '-U', 'postgres', '-d', 'postgres', '-f', str(path)], timeout=60)

    def run(self):
        self.preflight()
        self.windows_sid = self.win.identity()['sid']
        self.phase = 'binary-version'
        require(self.invoke('postgres', ['--version']).strip() == 'postgres (PostgreSQL) 17.11',
                'POSTGRES_BINARY_VERSION_MISMATCH')
        self.phase = 'initdb'
        # classify output before ANY config write or pg_ctl invocation
        self.invoke('initdb', ['-D', str(self.data), '-U', 'postgres', '--auth-local=trust',
            '--auth-host=trust', '--no-locale', '--encoding=UTF8'], timeout=90)
        no_links(self.data)
        require(self.win.owner(self.data) == self.windows_sid, 'NEW_CLUSTER_NOT_OWNED_BY_ACTUAL_USER')
        require((self.data / 'PG_VERSION').read_text().strip() == '17', 'PG_VERSION_MISMATCH')
        require(not (self.data / 'postmaster.pid').exists(), 'UNEXPECTED_PRESTART_PID_FILE')
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
            sock.bind(('127.0.0.1', 0))
            self.port = sock.getsockname()[1]
        config = f"\ncluster_name = '{self.marker}'\nlisten_addresses = '127.0.0.1'\nport = {self.port}\n" + \
            "max_connections = 10\ntimezone = 'UTC'\ndefault_transaction_isolation = 'read committed'\n" + \
            "log_min_error_statement = error\n"
        with (self.data / 'postgresql.conf').open('a', encoding='utf-8', newline='\n') as stream:
            stream.write(config)
        self.phase = 'startup'
        self.launch_wall = time.time()
        self.start_attempted = True
        self.invoke('pg_ctl', ['-D', str(self.data), '-l', str(self.out / 'server.log'),
            '-w', '-t', '25', 'start'], timeout=35)
        self.bind_pid()
        self.phase = 'identity'
        identity = json.loads(self.query('identity'))
        self.save('identity.json', dict(identity=identity, pid=self.pid, marker=self.marker))
        require(identity['server_version_num'] == '170011', 'ACTUAL_SERVER_VERSION_MISMATCH')
        require(identity['host'] == '127.0.0.1' and identity['port'] == self.port, 'ACTUAL_ENDPOINT_MISMATCH')
        require(Path(identity['data_directory']).resolve() == self.data.resolve() and
                identity['cluster_name'] == self.marker, 'ACTUAL_INSTANCE_MISMATCH')
        require(identity['current_user'] == identity['session_user'] == 'postgres', 'DB_USER_MISMATCH')
        require(identity['isolation'] == 'read committed' and identity['listen_addresses'] == '127.0.0.1'
                and identity['max_connections'] == '10', 'ACTUAL_CONFIGURATION_MISMATCH')
        self.identity_result = identity
        self.start_verified = True
        self.phase = 'extensions'
        if self.args.probe_extensions:
            self.query('extension-load')
            versions = json.loads(self.query('extension-versions'))
            self.save('extensions.json', dict(versions=versions))
            observed = {e['name']: (e['version'], e['schema']) for e in versions['extensions']}
            require(observed.get('postgis') == ('3.6.2', 'extensions') and
                    observed.get('pgrouting') == ('4.0.1', 'extensions'), 'ACTUAL_EXTENSION_VERSION_MISMATCH')
            self.versions = versions
        self.phase = 'environment-only-complete'
        # Deliberate terminal return: no compatibility/import/assembly branch exists.

    def shutdown(self):
        if not self.start_attempted:
            self.cleanup = dict(state='NOT_STARTED', shutdown_confirmed=False,
                                note='No pg_ctl start attempted; no database server launched by this runner.')
            return
        self.phase = 'shutdown'
        try:
            self.bind_pid()
            self.invoke('pg_ctl', ['-D', str(self.data), '-m', 'fast', '-w', '-t', '25', 'stop'],
                        timeout=35, cleanup=True)
            require(self.win.k.WaitForSingleObject(self.handle, 5000) == 0, 'KNOWN_POSTMASTER_NOT_EXITED')
            require(not (self.data / 'postmaster.pid').exists(), 'POSTMASTER_PID_REMAINS')
            self.cleanup = dict(state='STOPPED_CONFIRMED', shutdown_confirmed=True, pid=self.pid,
                                postmaster_pid_absent=True, data_directory=str(self.data))
        except BaseException as error:
            self.cleanup = dict(state='UNCERTAIN', shutdown_confirmed=False, error=str(error),
                note='No broad process kill, service action or retry was performed. Review evidence before further action.')
            if self.error is None:
                self.error = 'CLEANUP_UNCERTAIN: ' + str(error)
        finally:
            if self.handle:
                self.win.k.CloseHandle(self.handle)
                self.handle = None

    def finish(self):
        if self.out:
            self.save('cleanup.json', self.cleanup)
            self.save('results.json', dict(status='ENVIRONMENT_BLOCKED' if self.error else 'ENVIRONMENT_SMOKE_PASS',
                error=self.error, startup_attempted=self.start_attempted, identity_verified=self.start_verified,
                extension_probe='VERIFIED' if self.versions else 'NOT_VERIFIED' if self.args.probe_extensions else 'NOT_REQUESTED',
                shutdown=self.cleanup, migrations_executed=0, compatibility_scenarios_executed=0,
                remote_database_connections=0, parity_lane='BLOCKED',
                elapsed_seconds=time.monotonic() - self.started_at))
            files = {p.name: sha(p) for p in self.out.iterdir() if p.is_file() and p.name != 'evidence-index.json'}
            self.save('evidence-index.json', dict(sha256=files,
                data_directory_note='Retained for diagnosis; never reuse for another attempt.'))
        print('NON-PARITY', 'ENVIRONMENT_BLOCKED' if self.error else 'ENVIRONMENT_SMOKE_PASS', flush=True)
        if self.error:
            print(self.error, file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--normal-user-terminal', action='store_true', required=True)
    parser.add_argument('--confirm-environment-only', action='store_true', required=True)
    parser.add_argument('--expected-user', required=True)
    parser.add_argument('--probe-extensions', action='store_true', help='Create ONLY PostGIS/pgRouting in the owned disposable database')
    args = parser.parse_args()
    smoke = None
    try:
        smoke = Smoke(args)
        smoke.run()
    except BaseException:
        error = traceback.format_exc()
        if smoke:
            smoke.error = error
            smoke.save('failure.json', dict(error=error, phase=smoke.phase))
        else:
            print(error, file=sys.stderr)
        if smoke and smoke.out is None:
            print(error, file=sys.stderr)
    finally:
        if smoke:
            smoke.shutdown()
            smoke.finish()
    return 1 if smoke is None or smoke.error else 0


if __name__ == '__main__':
    raise SystemExit(main())
