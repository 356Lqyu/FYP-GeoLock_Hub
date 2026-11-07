"""Approved C.5 NON-PARITY local testing. No URL/DSN or existing server accepted.

Fail-stop runner: first unexpected error ends the lane, preserving every input,
SQL submission, diagnostic and unrun scenario. Never repairs reviewed sources.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
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
sys.path.insert(0, str(ROOT))
import stage8_spatial_isolated_test as spatial
from isolated_psql_sqlfile import single_transaction

AUTHORITY = 'docs/stage8/stage-a/forward-migrations/'
A_FILES = ['20261101_routing_authority.sql', '20261102_routing_publication.sql',
           '20261103_routing_pickup_and_reconciliation.sql']
B2 = 'docs/stage8/stage-b2/forward-migrations/20261104_spatial_endpoint_validation.sql'
B43 = 'docs/stage8/stage-b4-3/migrations/20261105_b43_claim_and_donation_lock_no_key_update.sql'
HISTORICAL = [
 '20261019_stage1_claim_recovery_and_reconciliation.sql',
 '20261019_retire_delivered_state.sql', '20261019_remove_validated_donation_state.sql',
 '20261020_operational_road_node_resolution.sql',
 '20261021_auto_validate_ngo_registration_location.sql',
 '20261022_role_onboarding_and_profile_management.sql',
 '20261023_async_ngo_eligibility_refresh.sql',
 '20261023_eligible_ngo_listing_details_and_photos.sql',
 '20261024_async_listing_eligibility_refresh.sql',
 '20261025_fix_cancel_claim_audit_columns.sql',
 '20261026_fix_claim_recovery_reconciliation_audit_columns.sql',
 '20261027_persisted_donation_lifecycle.sql',
 '20261029_fix_claim_recovery_listing_expiration_race.sql',
 '20261030_fix_claim_recovery_unresolved_reconciliation.sql',
 '20261031_claim_audit_and_failure_capture.sql',
]
PAT = re.compile(r'CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION\s+([\w.]+)\s*'
                 r'\((.*?)\)\s*(.*?)\bAS\s+(\$\w*\$)(.*?)\4\s*;', re.I | re.S)
ROLES = ['anon', 'authenticated', 'service_role', 'geolock_graph_worker',
         'geolock_planner', 'geolock_validator']
NEGATIVES = [
 ('lifecycle-body', "COMMENT ON SCHEMA public IS 'synthetic body-drift case'; DO $$ BEGIN EXECUTE replace(pg_get_functiondef('public.start_pickup(uuid)'::regprocedure),'BEGIN',E'BEGIN\\n-- synthetic drift'); END $$;", 'CURRENT_LIFECYCLE_SOURCE_OR_SECURITY_DRIFT'),
 ('search-path', 'ALTER FUNCTION public.start_pickup(uuid) SET search_path=public;', 'CURRENT_LIFECYCLE_SOURCE_OR_SECURITY_DRIFT'),
 ('security-mode', 'ALTER FUNCTION public.start_pickup(uuid) SECURITY INVOKER;', 'CURRENT_LIFECYCLE_SOURCE_OR_SECURITY_DRIFT'),
 ('coordination', 'UPDATE public.coordination_config SET geofence_radius_m=19999;', 'COORDINATION_POLICY_DRIFT'),
 ('private-table-grant', 'GRANT INSERT ON routing_private.items TO authenticated;', 'PRIVATE_PERMIT_TABLE_PRIVILEGES_REQUIRE_REVIEW'),
 ('helper-execute', 'GRANT EXECUTE ON FUNCTION public.geolock_transition_listing_donations(uuid,text,text,uuid,uuid,text) TO authenticated;', 'PRIVATE_AUDIT_HELPER_PRIVILEGE_DRIFT'),
 ('partial-003', 'CREATE FUNCTION routing_private.lock_route(uuid,boolean DEFAULT true) RETURNS routing_private.bindings LANGUAGE sql AS $$ SELECT NULL::routing_private.bindings $$;', 'already exists'),
 ('wrong-installer', 'CREATE ROLE c5_installer LOGIN SUPERUSER;', 'POSTGRES_SESSION_REQUIRED'),
 ('repeatable-read', '', 'READ_COMMITTED_REQUIRED'),
]
SCENARIOS = ['runtime-identity', 'historical-assembly', 'baseline-contract', 'unchanged-003-empty']
SCENARIOS += ['negative-' + n[0] for n in NEGATIVES]
SCENARIOS += ['003-replay', 'security-postflight', 'existing-record-preservation',
 'legacy-capture-1', 'legacy-capture-10', 'legacy-capture-100', 'legacy-collision']
SCENARIOS += [f'{name}-{i}' for name in ('writer-first', 'migration-first', 'lock-timeout') for i in range(1, 4)]
SCENARIOS += ['managed-direct', 'managed-reconciliation', 'audit-failure-rollback',
 'legacy-completion', 'whole-batch-pickup', 'whole-batch-reconciliation',
 'whole-batch-inconsistent', 'correction-order', 'reverse-order-rejected']


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def literal(value):
    return "'" + str(value).replace("'", "''") + "'"


class Lane:
    def __init__(self, runtime, out):
        self.runtime, self.out = runtime, out
        self.pg = runtime / 'pgsql'
        self.data = out / 'cluster-data'
        self.marker = 'geolock-c5-' + uuid.uuid4().hex
        self.env = {k: v for k, v in os.environ.items()
                    if not k.upper().startswith(('PG', 'GEOLOCK', 'SUPABASE'))
                    and k.upper() not in ('DATABASE_URL', 'DB_URL')}
        self.env.update(PGCONNECT_TIMEOUT='3', PGPASSFILE=str(out / 'absent-password-file'),
                        PGCLIENTENCODING='UTF8',
                        PGOPTIONS=f'-c search_path=pg_catalog,public,extensions -c application_name={self.marker}')
        self.env['PATH'] = str(self.pg / 'bin') + os.pathsep + self.env.get('PATH', '')
        self.started = False
        self.seq = 0
        self.db = 'postgres'
        self.begin = time.monotonic()
        self.applied = []
        self.status = {name: dict(status='NOT RUN', lane='NON-PARITY') for name in SCENARIOS}
        self.hashes = {}
        self.active = None

    def save(self, name, obj):
        (self.out / name).write_text(json.dumps(obj, indent=2, default=str) + '\n', encoding='utf-8')

    def freeze(self):
        """Freeze before startup. Include all historical files, even exclusions."""
        files = [ROOT / 'geolock-v3-public-schema.sql', Path(__file__),
                 ROOT / 'supabase/tests/stage8_spatial_isolated_test.py',
                 ROOT / 'supabase/tests/isolated_psql_sqlfile.py',
                 ROOT / 'docs/stage8/phase-c1/dev-evidence.json',
                 ROOT / 'docs/stage8/phase-c1/proposed_migration_v2.sql',
                 ROOT / 'docs/stage8/integration/dev-preparation-evidence.json',
                 ROOT / 'docs/stage8/stage-a/package-manifest.json',
                 ROOT / 'docs/stage8/stage-c3/READ_ONLY_QUERIES.sql',
                 ROOT / B2, ROOT / B43]
        files += list((ROOT / 'supabase/migrations').glob('*.sql'))
        files += [ROOT / AUTHORITY / n for n in A_FILES]
        files += list((ROOT / 'backend/routing').rglob('*.py'))
        files += list((ROOT / 'results/stage-b3').rglob('*'))
        self.hashes = {str(p.relative_to(ROOT)).replace('\\', '/'): digest(p)
                       for p in files if p.is_file()}
        pinned = json.loads((ROOT / 'docs/stage8/stage-a/package-manifest.json').read_text())
        for name in A_FILES:
            assert self.hashes[AUTHORITY + name] == pinned['files'][name], 'STAGE_A_ARTIFACT_DRIFT'
        assert digest(ROOT / 'backend/routing/phase_b/benchmark.py') == digest(
            ROOT / 'results/stage-b3/pre-correction/benchmark.py'), 'REPRODUCIBILITY_GUARD_DRIFT'
        coverage = []
        for p in sorted((ROOT / 'supabase/migrations').glob('*.sql')):
            if p.name in HISTORICAL:
                disposition, reason = 'APPLY', 'Exact historical source; explicit dependency order in assembly-order.json.'
            elif p.name.startswith('20261028'):
                disposition, reason = 'NOT_REQUIRED_FOR_STAGE_A_BASELINE', (
                    'Adds claim-card v2 reader and paused scheduler; requires real pg_cron. '
                    'Not required by 001/002/003. Scheduler and reader-v2 parity excluded; '
                    'no fabricated pg_extension entry. Recovery bodies are installed from 20261031.')
            else:
                disposition, reason = 'SNAPSHOT_BASE_OR_SUPERSEDED', (
                    'Snapshot supplies pre-20261019 public schema/function foundation; '
                    'post-snapshot lifecycle replacements listed explicitly. Do not replay older schema DDL.')
            coverage.append(dict(file=str(p.relative_to(ROOT)).replace('\\', '/'),
                                 sha256=digest(p), disposition=disposition, reason=reason))
        self.save('assembly-map.json', dict(lane='NON-PARITY', files=coverage,
            adapters=['synthetic auth JWT GUC', 'storage metadata only', 'inert cron catalog'],
            exclusions=['real pg_cron', 'claim-card v2', 'real Supabase services']))
        self.save('assembly-order.json', ['synthetic auth/storage/extensions', 'geolock-v3-public-schema.sql',
            HISTORICAL[:4], 'synthetic road coverage and inert cron', HISTORICAL[4:],
            'captured depot and original assignment definitions',
            'docs/stage8/phase-c1/proposed_migration_v2.sql', *[AUTHORITY + n for n in A_FILES[:2]],
            'baseline assertions', AUTHORITY + A_FILES[2]])
        self.save('input-manifest.json', dict(lane='NON-PARITY', sha256=self.hashes))
        self.save('scenario-manifest.json', dict(lane='NON-PARITY', maximum_scenarios=60,
            maximum_tasks=100, maximum_vehicles=2, maximum_connections=10,
            maximum_lane_seconds=3600, scenarios=SCENARIOS))
        self.save('repository.json', dict(lane='NON-PARITY', head=self.process_git(['rev-parse', 'HEAD']),
            status=self.process_git(['status', '--short'])))

    def process_git(self, args):
        return subprocess.run(['git', *args], cwd=ROOT, capture_output=True, text=True,
                              timeout=20, creationflags=subprocess.CREATE_NO_WINDOW).stdout

    def verify_frozen(self):
        result = {name: digest(ROOT / name) == value for name, value in self.hashes.items()}
        self.save('input-integrity-final.json', dict(lane='NON-PARITY', matches=result))
        assert all(result.values()), 'FROZEN_INPUT_DRIFT'

    def process(self, name, args, timeout=180):
        exe = (self.pg / 'bin' / (name + '.exe')).resolve()
        assert name in ('initdb', 'pg_ctl', 'psql', 'postgres') and exe.is_relative_to(self.pg.resolve())
        started = time.monotonic()
        # A real file prevents inherited Windows pipe handles keeping pg_ctl alive.
        with (self.out / f'process-{uuid.uuid4().hex}.log').open('w+', encoding='utf-8') as stream:
            p = subprocess.run([str(exe), *args], env=self.env, stdout=stream,
                               stderr=subprocess.STDOUT, timeout=timeout,
                               creationflags=subprocess.CREATE_NO_WINDOW)
            stream.seek(0)
            output = stream.read()
        with (self.out / 'processes.jsonl').open('a', encoding='utf-8') as stream:
            stream.write(json.dumps(dict(lane='NON-PARITY', executable=str(exe), arguments=args,
                returncode=p.returncode, elapsed=time.monotonic() - started, output=output)) + '\n')
        return p.returncode, output.strip()

    def sql(self, sql, expected=None, db=None, user='postgres', exact_bytes=None):
        self.seq += 1
        path = self.out / 'sql' / f'{self.seq:04}.sql'
        path.write_bytes(exact_bytes if exact_bytes is not None else sql.encode('utf-8'))
        args = ['-X', '--no-password', '-qAt', '-v', 'ON_ERROR_STOP=1', '-v', 'VERBOSITY=verbose',
                '-h', '127.0.0.1', '-p', str(self.port), '-U', user, '-d', db or self.db]
        if exact_bytes is None and single_transaction(sql):
            args.append('--single-transaction')
        code, result = self.process('psql', args + ['-f', str(path)])
        with (self.out / 'operations.jsonl').open('a', encoding='utf-8') as stream:
            stream.write(json.dumps(dict(lane='NON-PARITY', scenario=self.active, sql=str(path.name),
                sha256=digest(path), database=db or self.db, user=user, returncode=code,
                expected_error=expected, output=result)) + '\n')
        if expected:
            assert code and expected in result, f'EXPECTED_REJECTION_MISSING: {expected}\n{result}'
        else:
            assert code == 0, result
        return result

    def js(self, sql):
        return json.loads(self.sql(sql))

    def apply(self, relative):
        p = ROOT / relative
        assert digest(p) == self.hashes[relative], 'INPUT_DRIFT_BEFORE_APPLY'
        self.sql('', exact_bytes=p.read_bytes())
        self.applied.append(dict(file=relative, sha256=digest(p), lane='NON-PARITY'))
        self.save('applied.json', self.applied)

    def case(self, name, fn):
        assert time.monotonic() - self.begin < 3600, 'LANE_TIME_LIMIT'
        self.active = name
        self.status[name]['status'] = 'RUNNING'
        self.save('scenarios.json', self.status)
        started = time.monotonic()
        print('NON-PARITY START', name, flush=True)
        try:
            fn()
            assert time.monotonic() - started <= 180, 'SCENARIO_TIME_LIMIT'
        except BaseException as error:
            self.status[name].update(status='FAIL', error=str(error), traceback=traceback.format_exc())
            raise
        else:
            self.status[name]['status'] = 'PASS'
            print('NON-PARITY PASS', name, flush=True)
        finally:
            self.status[name]['elapsed_seconds'] = time.monotonic() - started
            self.save('scenarios.json', self.status)

    def start(self):
        code, version = self.process('postgres', ['--version'])
        assert code == 0 and '17.11' in version, 'POSTGRES_BINARY_VERSION'
        assert not self.data.exists(), 'FRESH_DATA_DIRECTORY_REQUIRED'
        code, output = self.process('initdb', ['-D', str(self.data), '-U', 'postgres',
                        '--auth-local=trust', '--auth-host=trust', '--no-locale', '--encoding=UTF8'])
        assert code == 0, output
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            self.port = sock.getsockname()[1]
        with (self.data / 'postgresql.conf').open('a', encoding='utf-8') as f:
            f.write(f"\ncluster_name = '{self.marker}'\nlisten_addresses = '127.0.0.1'\n"
                    "max_connections = 10\nlog_min_error_statement = error\nlog_lock_waits = on\n"
                    "deadlock_timeout = '100ms'\nlog_line_prefix = '%m [%p] %a %u %d '\n")
        code, output = self.process('pg_ctl', ['-D', str(self.data), '-l', str(self.out / 'server.log'),
                                    '-w', '-t', '25', '-o', f'-p {self.port}', 'start'])
        self.started = (self.data / 'postmaster.pid').exists()
        assert code == 0 and self.started, output
        identity = self.js("SELECT jsonb_build_object('host',inet_server_addr(),'port',inet_server_port(),"
            "'data_directory',current_setting('data_directory'),'cluster_name',current_setting('cluster_name'),"
            "'current_user',current_user,'session_user',session_user,'isolation',current_setting('transaction_isolation'),"
            "'server_version',current_setting('server_version'),'server_version_num',current_setting('server_version_num'),"
            "'listen_addresses',current_setting('listen_addresses'),'max_connections',current_setting('max_connections')); ")
        self.save('identity.json', dict(lane='NON-PARITY', **identity))
        assert identity['host'] == '127.0.0.1' and identity['port'] == self.port
        assert Path(identity['data_directory']).resolve() == self.data.resolve()
        assert identity['cluster_name'] == self.marker and identity['server_version_num'] == '170011'
        assert identity['current_user'] == identity['session_user'] == 'postgres'
        assert identity['isolation'] == 'read committed' and identity['max_connections'] == '10'
        self.sql(spatial.BOOT)
        environment = self.js("SELECT jsonb_build_object('postgis',extensions.postgis_full_version(),"
            "'pgrouting',extensions.pgr_full_version(),'extensions',(SELECT jsonb_agg(jsonb_build_object("
            "'name',extname,'version',extversion,'schema',extnamespace::regnamespace::text) ORDER BY extname) FROM pg_extension),"
            "'many_to_many_overload',coalesce(to_regprocedure('extensions.pgr_dijkstraCost(text,bigint[],bigint[],boolean)'),"
            "to_regprocedure('extensions.pgr_dijkstraCost(text,anyarray,anyarray,boolean)'))::text);")
        self.save('environment.json', dict(lane='NON-PARITY', python=sys.version, **environment))
        versions = {v['name']: v['version'] for v in environment['extensions']}
        assert versions['postgis'] == '3.6.2' and versions['pgrouting'] == '4.0.1', 'EXTENSION_VERSION_UNCERTAINTY'
        assert environment['many_to_many_overload'], 'PGR_OVERLOAD_MISSING'

    def assemble(self):
        # psql restrict directives are dump transport controls, not business SQL.
        snapshot = (ROOT / 'geolock-v3-public-schema.sql').read_text(encoding='utf-8')
        self.sql(re.sub(r'^\\(?:un)?restrict[^\n]*', '', snapshot, flags=re.M))
        self.applied.append(dict(file='geolock-v3-public-schema.sql',
            sha256=self.hashes['geolock-v3-public-schema.sql'], transport='restrict directives removed', lane='NON-PARITY'))
        self.sql('INSERT INTO public.coordination_config(singleton) VALUES(true);')
        for name in HISTORICAL[:4]:
            self.apply('supabase/migrations/' + name)
        self.sql(spatial.COVERAGE + spatial.CRON)
        for name in HISTORICAL[4:]:
            self.apply('supabase/migrations/' + name)
        fleet_evidence = json.loads((ROOT / 'docs/stage8/phase-c1/dev-evidence.json').read_text())
        depot = next(r['definition'] for q in fleet_evidence['queries'] if q['name'] == 'functions'
                     for r in q['rows'] if r['signature'] == 'geolock_assign_vehicle_depot()')
        self.sql(depot + ';')
        # The captured public snapshot may already carry this trigger. Preserve
        # and verify it instead of failing assembly with duplicate_object.
        present = self.sql("SELECT count(*) FROM pg_trigger WHERE tgrelid='public.vehicles'::regclass AND tgname='trg_vehicle_depot_node';")
        if present == '0':
            self.sql('CREATE TRIGGER trg_vehicle_depot_node BEFORE INSERT OR UPDATE OF depot_road_node_id,ngo_user_id '
                     'ON public.vehicles FOR EACH ROW EXECUTE FUNCTION public.geolock_assign_vehicle_depot();')
        else:
            assert present == '1' and self.sql("SELECT tgenabled='O' AND tgtype=23 AND tgfoid='public.geolock_assign_vehicle_depot()'::regprocedure "
                "AND pg_get_triggerdef(oid) LIKE '%UPDATE OF depot_road_node_id, ngo_user_id%' FROM pg_trigger "
                "WHERE tgrelid='public.vehicles'::regclass AND tgname='trg_vehicle_depot_node';") == 't', 'EXISTING_DEPOT_TRIGGER_DRIFT'
        assignment = next(f['definition'] for f in json.loads((ROOT / 'docs/stage8/integration/dev-preparation-evidence.json').read_text())['functions']
                          if f['name'] == 'assign_task_to_route')
        self.sql(assignment)
        self.apply('docs/stage8/phase-c1/proposed_migration_v2.sql')
        for name in A_FILES[:2]:
            self.apply(AUTHORITY + name)

    def catalog(self):
        return self.js("""SELECT jsonb_build_object(
          'functions',(SELECT jsonb_agg(jsonb_build_object('signature',p.oid::regprocedure::text,
            'definition',pg_get_functiondef(p.oid),'owner',p.proowner::regrole::text,'config',p.proconfig,
            'acl',p.proacl::text,'security_definer',p.prosecdef,'volatility',p.provolatile,
            'result',pg_get_function_result(p.oid),'md5',md5(replace(p.prosrc,E'\\r\\n',E'\\n')))
            ORDER BY p.oid::regprocedure::text) FROM pg_proc p WHERE p.pronamespace IN
            ('public'::regnamespace,'fleet_private'::regnamespace,'routing_private'::regnamespace)),
          'tables',(SELECT jsonb_agg(to_jsonb(c) ORDER BY c.relname) FROM
            (SELECT relname,relowner::regrole::text owner,relkind,relpersistence,relrowsecurity,relforcerowsecurity,relacl::text
             FROM pg_class WHERE relnamespace='routing_private'::regnamespace AND relkind='r') c),
          'columns',(SELECT jsonb_agg(jsonb_build_object('table',a.attrelid::regclass::text,'name',a.attname,
            'type',format_type(a.atttypid,a.atttypmod),'notnull',a.attnotnull,'acl',a.attacl::text,
            'default',pg_get_expr(d.adbin,d.adrelid)) ORDER BY a.attrelid::regclass::text,a.attnum)
            FROM pg_attribute a LEFT JOIN pg_attrdef d ON d.adrelid=a.attrelid AND d.adnum=a.attnum
            WHERE a.attnum>0 AND NOT a.attisdropped AND a.attrelid IN
            (SELECT oid FROM pg_class WHERE relnamespace='routing_private'::regnamespace AND relkind='r')),
          'indexes',(SELECT jsonb_agg(jsonb_build_object('name',c.relname,'definition',pg_get_indexdef(i.indexrelid),
            'valid',i.indisvalid,'live',i.indislive) ORDER BY c.relname)
            FROM pg_index i JOIN pg_class c ON c.oid=i.indexrelid WHERE c.relnamespace='routing_private'::regnamespace),
          'constraints',(SELECT jsonb_agg(jsonb_build_object('table',conrelid::regclass::text,'name',conname,
            'type',contype,'definition',pg_get_constraintdef(oid,true),'validated',convalidated) ORDER BY conname)
            FROM pg_constraint WHERE connamespace='routing_private'::regnamespace),
          'triggers',(SELECT jsonb_agg(jsonb_build_object('table',tgrelid::regclass::text,'name',tgname,
            'enabled',tgenabled,'definition',pg_get_triggerdef(oid,true)) ORDER BY tgrelid::regclass::text,tgname)
            FROM pg_trigger WHERE NOT tgisinternal AND tgrelid IN
            (SELECT oid FROM pg_class WHERE relnamespace IN ('public'::regnamespace,'routing_private'::regnamespace))),
          'roles',(SELECT jsonb_agg(jsonb_build_object('name',rolname,'login',rolcanlogin,'super',rolsuper,
            'bypassrls',rolbypassrls) ORDER BY rolname) FROM pg_roles WHERE rolname NOT LIKE 'pg_%'),
          'memberships',(SELECT coalesce(jsonb_agg(jsonb_build_object('role',roleid::regrole::text,
            'member',member::regrole::text,'inherit',inherit_option,'set',set_option)), '[]') FROM pg_auth_members));""")

    def rows(self):
        tables = self.js("SELECT jsonb_agg(format('%I.%I',schemaname,tablename) ORDER BY schemaname,tablename) "
                         "FROM pg_tables WHERE schemaname IN ('public','fleet_private','routing_private');")
        return {table: self.js(f"SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text),'[]') FROM {table} t;")
                for table in tables}

    def baseline(self):
        cat = self.catalog()
        self.save('baseline-catalog.json', dict(lane='NON-PARITY', catalog=cat))
        assert len(cat['tables']) == 11 and len(cat['columns']) == 75
        assert len(cat['indexes']) == 21 and len(cat['constraints']) == 35
        assert all(i['valid'] and i['live'] for i in cat['indexes'])
        assert all(c['validated'] for c in cat['constraints'])
        assert all(t['owner'] == 'postgres' and t['relrowsecurity'] and not t['relforcerowsecurity'] for t in cat['tables'])
        private_triggers = [t for t in cat['triggers'] if t['table'].startswith('routing_private.')]
        assert len(private_triggers) == 8 and all(t['enabled'] == 'O' for t in private_triggers)
        expected = {}
        for name in A_FILES[:2]:
            for m in PAT.finditer((ROOT / AUTHORITY / name).read_text()):
                types = ','.join(a.strip().split()[1] for a in m[2].split(',') if a.strip())
                signature = m[1] + '(' + types + ')'
                expected[signature] = dict(md5=hashlib.md5(m[5].replace('\r\n', '\n').encode()).hexdigest(),
                    secdef=bool(re.search(r'SECURITY\s+DEFINER', m[3], re.I)),
                    volatility='i' if re.search(r'\bIMMUTABLE\b', m[3], re.I) else 's' if re.search(r'\bSTABLE\b', m[3], re.I) else 'v')
        assert len(expected) == 28, 'EXPECTED_FUNCTION_PARSER_COUNT'
        # Resolve aliases with regprocedure rather than string-normalizing signatures.
        verified = []
        for signature, wanted in expected.items():
            actual = self.js("SELECT jsonb_build_object('md5',md5(replace(prosrc,E'\\r\\n',E'\\n')),'owner',proowner::regrole::text,"
                "'secdef',prosecdef,'volatility',provolatile,'config',proconfig,'result',pg_get_function_result(oid),'acl',proacl::text) "
                f"FROM pg_proc WHERE oid=to_regprocedure({literal(signature)});")
            assert all(actual[k] == v for k, v in wanted.items()), f'FUNCTION_BASELINE_DRIFT {signature}'
            assert actual['owner'] == 'postgres' and actual['config'] == [
                'search_path=pg_catalog, pg_temp', 'TimeZone=UTC', 'extra_float_digits=0'], signature
            verified.append(dict(signature=signature, expected=wanted, actual=actual))
        self.save('baseline-functions.json', dict(lane='NON-PARITY', functions=verified))
        self.security(before=True)
        assert self.sql("SELECT to_regprocedure('routing_private.task_guard()') IS NULL AND NOT EXISTS(SELECT 1 FROM pg_trigger WHERE tgname='routing_task_authority');") == 't'
        self.save('baseline-rows.json', dict(lane='NON-PARITY', rows=self.rows()))
        # Clone databases inherit schema/data but not cluster roles; roles already exist once.
        self.sql('CREATE DATABASE c5_base TEMPLATE postgres;', db='template1')

    def security(self, before=False):
        values = ','.join('(' + literal(r) + ')' for r in ROLES)
        matrix = self.js(f"""WITH roles(name) AS (VALUES {values})
          SELECT jsonb_agg(jsonb_build_object('role',r.name,'table',t::text,
            'dml',has_table_privilege(r.name,t,'INSERT,UPDATE,DELETE,TRUNCATE'),
            'column_write',has_any_column_privilege(r.name,t,'INSERT,UPDATE')) ORDER BY r.name,t::text)
          FROM roles r CROSS JOIN unnest(ARRAY['routing_private.items'::regclass,'routing_private.legacy_inflight'::regclass]) t;""")
        self.save(('baseline' if before else 'postflight') + '-security.json', dict(lane='NON-PARITY', matrix=matrix))
        assert all(not row['dml'] and not row['column_write'] for row in matrix), 'PRIVATE_DML_BOUNDARY'
        worker_grants = {
            'geolock_graph_worker': ['public.install_routing_policy(uuid,jsonb)', 'public.freeze_routing_graph(uuid,text,text,text)',
                'public.store_routing_matrix(uuid,uuid,jsonb)', 'public.read_frozen_routing_graph(uuid,bigint,integer)'],
            'geolock_planner': ['public.seal_routing_snapshot(uuid,uuid)', 'public.submit_routing_candidate(uuid,uuid,jsonb)',
                'public.read_routing_snapshot_bundle(uuid)', 'public.read_pending_routing_snapshot(uuid)'],
            'geolock_validator': ['public.read_routing_work_item(uuid)', 'public.attest_routing_candidate(uuid,text,jsonb)']}
        grants = []
        for allowed, signatures in worker_grants.items():
            for signature in signatures:
                for role in ROLES:
                    access = self.sql(f"SELECT has_function_privilege({literal(role)},{literal(signature)},'EXECUTE');") == 't'
                    grants.append(dict(role=role, signature=signature, execute=access))
                    assert access == (role == allowed), 'WORKER_EXECUTE_BOUNDARY'
        self.save(('baseline' if before else 'postflight') + '-worker-grants.json', dict(lane='NON-PARITY', matrix=grants))
        if not before:
            for signature in ['public.start_pickup(uuid)', 'public.complete_pickup(uuid,boolean)']:
                for role in ROLES:
                    assert (self.sql(f"SELECT has_function_privilege({literal(role)},{literal(signature)},'EXECUTE');") == 't') == (role == 'authenticated')

    def clone(self, name):
        assert re.fullmatch(r'c5_[a-z0-9_]+', name)
        self.sql(f'CREATE DATABASE {name} TEMPLATE c5_base;', db='template1')
        self.db = name

    def negative(self, name, mutation, message):
        self.clone('c5_neg_' + name.replace('-', '_'))
        if mutation:
            self.sql(mutation)
        before = dict(catalog=self.catalog(), rows=self.rows())
        self.save(name + '-before.json', dict(lane='NON-PARITY', **before))
        old_options = self.env['PGOPTIONS']
        if name == 'repeatable-read':
            self.env['PGOPTIONS'] += ' -c default_transaction_isolation=repeatable\\ read'
        try:
            self.sql('', expected=message, user='c5_installer' if name == 'wrong-installer' else 'postgres',
                     exact_bytes=(ROOT / AUTHORITY / A_FILES[2]).read_bytes())
        finally:
            self.env['PGOPTIONS'] = old_options
        after = dict(catalog=self.catalog(), rows=self.rows())
        self.save(name + '-after.json', dict(lane='NON-PARITY', **after))
        assert before == after, 'REJECTED_MIGRATION_NOT_ATOMIC'

    def run(self):
        self.case('runtime-identity', self.start)
        self.case('historical-assembly', self.assemble)
        self.case('baseline-contract', self.baseline)
        self.case('unchanged-003-empty', lambda: self.apply(AUTHORITY + A_FILES[2]))
        for name, mutation, message in NEGATIVES:
            self.case('negative-' + name, lambda n=name, m=mutation, e=message: self.negative(n, m, e))
        self.db = 'postgres'
        self.case('003-replay', lambda: self.sql('', expected='already exists', exact_bytes=(ROOT / AUTHORITY / A_FILES[2]).read_bytes()))
        self.case('security-postflight', self.security)
        # Later fixture families are deliberately gated, never marked PASS by absence.
        # A missing implementation is a coverage blocker, not a SQL compatibility verdict.
        self.status['existing-record-preservation'].update(status='BLOCKED',
            error='Remaining synthetic workflow/race fixtures require implementation before their execution; no substitution with historical results.')

    def finish(self, error):
        stopped = not self.started
        if self.started:
            code, output = self.process('pg_ctl', ['-D', str(self.data), '-m', 'fast', '-w', '-t', '25', 'stop'])
            stopped = code == 0 and not (self.data / 'postmaster.pid').exists()
            self.save('cleanup.json', dict(lane='NON-PARITY', cluster_stopped=stopped,
                postmaster_pid_absent=not (self.data / 'postmaster.pid').exists(), output=output,
                data_directory=str(self.data), marker=self.marker))
        self.verify_frozen()
        counts = {state: sum(row['status'] == state for row in self.status.values())
                  for state in ('PASS', 'FAIL', 'BLOCKED', 'NOT RUN')}
        self.save('scenarios.json', self.status)
        self.save('results.json', dict(lane='NON-PARITY', status='STOPPED' if error or counts['BLOCKED'] else 'PASS',
            counts=counts, error=error, cluster_stopped=stopped,
            unchanged_003_success=self.status['unchanged-003-empty']['status'] == 'PASS',
            remote_database_connections=0, parity_lane='BLOCKED_NOT_APPROVED',
            elapsed_seconds=time.monotonic() - self.begin))
        assert stopped, 'OWNED_CLUSTER_CLEANUP_FAILED'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run-isolated', action='store_true', required=True)
    parser.add_argument('--runtime', type=Path, required=True)
    parser.add_argument('--lane', choices=['nonparity'], required=True)
    parser.add_argument('--output-dir', type=Path, required=True)
    args = parser.parse_args()
    runtime, out = args.runtime.resolve(), args.output_dir.resolve()
    if not runtime.name.startswith('geolock-spatial-runtime-') or not (runtime / 'pgsql/bin/postgres.exe').is_file():
        parser.error('Existing private binary runtime required; never a system-service data directory')
    if not out.is_relative_to(ROOT / 'results/stage-c5') or out.exists():
        parser.error('New owned results/stage-c5 attempt directory required')
    assert len(SCENARIOS) <= 60
    out.mkdir(parents=True)
    (out / 'sql').mkdir()
    lane = Lane(runtime, out)
    error = None
    try:
        lane.freeze()
        lane.run()
    except BaseException:
        error = traceback.format_exc()
        print(error, file=sys.stderr)
        lane.save('failure.json', dict(lane='NON-PARITY', error=error, active=lane.active))
    finally:
        lane.finish(error)
    return int(bool(error or any(r['status'] == 'BLOCKED' for r in lane.status.values())))


if __name__ == '__main__':
    raise SystemExit(main())
