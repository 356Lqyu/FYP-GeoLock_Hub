"""Per-environment configuration (DEV default, KLSEL new project). Offline only:
no database, network, worker startup or saved profiles are used."""
from copy import deepcopy
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest import mock
import json
import os
import unittest

from backend.routing import environment as environments
from backend.routing.contract import DEV_PROJECT, ContractError
from backend.routing.database import native_connection, supabase_rpc
from backend.routing.database.supabase_rpc import RoleRpc, SupabaseAuth
from backend.routing.diagnostics import connection_check
from backend.routing.road_network.graph_cache import GraphCache
from backend.routing.road_network.matrix import freeze_graph
from backend.routing.service import http_api
from backend.routing.service.errors import WorkerError
from backend.routing.snapshot import prepare_bundle
from backend.routing.tests.test_snapshot import synthetic_bundle

DEV = environments.ENVIRONMENTS['DEV']
KLSEL = environments.ENVIRONMENTS['KLSEL']
SELECT_KLSEL = {'GEOLOCK_ENVIRONMENT': 'KLSEL'}
POOLER = 'aws-0-ap-southeast-1.pooler.supabase.com'


def unset():
    return {k: v for k, v in os.environ.items() if k not in ('GEOLOCK_ENVIRONMENT', 'GEOLOCK_PG_SERVICE_FILE')}


def dsn(login, project, host=POOLER, ca='C:/Users/User/Downloads/prod-ca-2021.crt'):
    return f"host={host} port=5432 dbname=postgres user={login}.{project} sslmode=verify-full sslrootcert={ca}"


class RegistryTests(unittest.TestCase):
    def test_dev_is_the_default_and_keeps_the_original_identity(self):
        with mock.patch.dict(os.environ, unset(), clear=True):
            self.assertEqual(environments.active().name, 'DEV')
        self.assertEqual(DEV.project_ref, DEV_PROJECT)
        self.assertEqual(DEV.project_ref, supabase_rpc.DEV)
        self.assertEqual(DEV.supabase_url, supabase_rpc.BASE)
        self.assertEqual((DEV.graph_id, DEV.graph_digest), (connection_check.GRAPH, connection_check.DIGEST))
        self.assertEqual((DEV.tail_after_node, list(DEV.tail_node_ids), DEV.tail_after_edge, list(DEV.tail_edge_ids)),
                         (connection_check.AFTER_NODE, connection_check.NODE_IDS, connection_check.AFTER_EDGE, connection_check.EDGE_IDS))
        self.assertEqual(DEV.service_name, native_connection.SERVICE)

    def test_new_project_identity_is_the_frozen_klsel_graph(self):
        self.assertEqual(KLSEL.project_ref, 'ppwmdsyoesvhgmqiaoxa')
        self.assertEqual(KLSEL.graph_id, '19c44bd2-8871-4eca-bf6b-4262f1bf766d')
        self.assertEqual(KLSEL.graph_digest, '6b62b3654312587e00461a21d9aafe93272d301f39dd644f5011b1afae9edc32')
        self.assertEqual((KLSEL.coverage_snapshot, KLSEL.node_count, KLSEL.edge_count), ('OSM-OPS-20261018-KLSEL', 205524, 454178))
        self.assertNotEqual(KLSEL.graph_id, DEV.graph_id)
        self.assertNotEqual(KLSEL.graph_digest, DEV.graph_digest)
        self.assertNotEqual(KLSEL.local_directory, DEV.local_directory)
        self.assertEqual(KLSEL.speed_profile, DEV.speed_profile)  # identical builder edge costs

    def test_unknown_environment_fails_closed(self):
        with self.assertRaises(ValueError):
            environments.active({'GEOLOCK_ENVIRONMENT': 'PROD'})
        with self.assertRaises(WorkerError) as e:
            http_api.application_from_env('planner', {'GEOLOCK_ENVIRONMENT': 'dev'})
        self.assertEqual(e.exception.code, 'UNKNOWN_GEOLOCK_ENVIRONMENT')

    def test_registry_holds_no_secrets(self):
        text = Path(environments.__file__).read_text()
        for marker in ('sb_publishable_', 'sb_secret_', 'password=', 'service_role'):
            self.assertNotIn(marker, text)


class ProjectScopeTests(unittest.TestCase):
    def test_operational_snapshot_carries_the_active_project(self):
        with mock.patch.dict(os.environ, unset(), clear=True):
            dev = json.loads(prepare_bundle(synthetic_bundle()).snapshot.canonical_json)['input']['source']['project_ref']
        with mock.patch.dict(os.environ, SELECT_KLSEL):
            klsel = json.loads(prepare_bundle(synthetic_bundle()).snapshot.canonical_json)['input']['source']['project_ref']
        self.assertEqual((dev, klsel), (DEV.project_ref, KLSEL.project_ref))

    def test_graph_freeze_accepts_only_the_active_project(self):
        args = dict(nodes=['1', '2'], edges=[dict(edge_id='1', source_node='1', target_node='2', road_km=1, travel_minutes=1)],
                    snapshot_id='OSM-OPS-UNIT', kind='OPERATIONAL_ROAD_NETWORK', complete=True, speed_profile='unit')
        with mock.patch.dict(os.environ, unset(), clear=True):
            freeze_graph(project_ref=DEV.project_ref, **args)
            with self.assertRaises(ContractError):
                freeze_graph(project_ref=KLSEL.project_ref, **args)
        with mock.patch.dict(os.environ, SELECT_KLSEL):
            freeze_graph(project_ref=KLSEL.project_ref, **args)
            with self.assertRaises(ContractError):
                freeze_graph(project_ref=DEV.project_ref, **args)


class TransportTests(unittest.TestCase):
    def test_dsn_target_follows_the_environment(self):
        with mock.patch.dict(os.environ, unset(), clear=True):
            RoleRpc.validate_dsn(dsn('geolock_graph_login', DEV.project_ref))
            with self.assertRaises(WorkerError) as e:
                RoleRpc.validate_dsn(dsn('geolock_graph_login', KLSEL.project_ref))
            self.assertEqual(e.exception.code, 'DEV_DATABASE_TARGET_REQUIRED')
        with mock.patch.dict(os.environ, SELECT_KLSEL):
            RoleRpc.validate_dsn(dsn('geolock_graph_login', KLSEL.project_ref))
            RoleRpc.validate_dsn(f"host=db.{KLSEL.project_ref}.supabase.co user=geolock_graph_login sslmode=verify-full sslrootcert=x")
            for bad in (dsn('geolock_graph_login', DEV.project_ref),
                        f"host=db.{DEV.project_ref}.supabase.co user=geolock_graph_login sslmode=verify-full sslrootcert=x"):
                with self.subTest(bad=bad), self.assertRaises(WorkerError) as e:
                    RoleRpc.validate_dsn(bad)
                self.assertEqual(e.exception.code, 'ENVIRONMENT_DATABASE_TARGET_REQUIRED')

    def test_ngo_jwt_is_verified_against_the_active_project(self):
        class Http:
            def __init__(self): self.urls = []
            def request(self, url, **kwargs):
                self.urls.append(url)
                return {'id': '00000000-0000-4000-8000-000000000001'} if url.endswith('/auth/v1/user') else []
        for env, project in ((unset(), DEV.project_ref), ({**unset(), **SELECT_KLSEL}, KLSEL.project_ref)):
            with mock.patch.dict(os.environ, env, clear=True):
                http = Http()
                SupabaseAuth('sb_publishable_unit', http).verify('Bearer token')
                self.assertEqual(http.urls, ['https://' + project + '.supabase.co/auth/v1/user',
                                             'https://' + project + '.supabase.co/rest/v1/rpc/list_my_vehicles'])


class GraphCacheTests(unittest.TestCase):
    def manifest(self):
        return dict(graph_id=KLSEL.graph_id, content_digest=KLSEL.graph_digest, coverage_snapshot=KLSEL.coverage_snapshot,
                    node_count=1, edge_count=0, precision_policy='EXACT_MAX_6_DECIMALS', float_output_profile='PG_REAL_OUTPUT_0',
                    speed_profile=KLSEL.speed_profile, request_id='x', created_at='x')

    def rpc(self, manifest):
        class Rpc:
            def call(self, name, graph, after_node, after_edge):
                assert name == 'read_frozen_routing_graph' and graph == KLSEL.graph_id
                return deepcopy(dict(graph=manifest, nodes=[] if after_node else
                                     [dict(osm_node_id=7, network_snapshot_id=manifest['coverage_snapshot'], active_flag=True)], edges=[]))
        return Rpc()

    def expected(self):
        return dict(KLSEL.graph_manifest(), node_count=1, edge_count=0)

    def test_new_graph_cache_is_keyed_and_checked_by_the_new_id_and_digest(self):
        with TemporaryDirectory() as d:
            cache = GraphCache(self.rpc(self.manifest()), KLSEL.graph_id, d, expected=self.expected())
            manifest, nodes, edges = cache.load()
            self.assertEqual(manifest['content_digest'], KLSEL.graph_digest)
            self.assertEqual(sorted(p.name for p in Path(d).iterdir()), [KLSEL.graph_id + '.jsonl', KLSEL.graph_id + '.sha256'])

    def test_wrong_digest_or_dev_graph_id_is_refused(self):
        with TemporaryDirectory() as d:
            with self.assertRaises(WorkerError) as e:
                GraphCache(self.rpc(dict(self.manifest(), content_digest=DEV.graph_digest)), KLSEL.graph_id, d, expected=self.expected()).load()
            self.assertEqual(e.exception.code, 'ENVIRONMENT_GRAPH_MANIFEST_MISMATCH')
            self.assertEqual(list(Path(d).iterdir()), [])
            with self.assertRaises(WorkerError) as e:
                GraphCache(self.rpc(self.manifest()), DEV.graph_id, d, expected=self.expected())
            self.assertEqual(e.exception.code, 'ENVIRONMENT_GRAPH_ID_MISMATCH')

    def test_a_copied_dev_cache_is_never_reused(self):
        with TemporaryDirectory() as d:
            for suffix in ('.jsonl', '.sha256'):
                (Path(d) / (DEV.graph_id + suffix)).write_text('dev cache\n')
            with self.assertRaises(WorkerError) as e:
                GraphCache(self.rpc(self.manifest()), KLSEL.graph_id, d, expected=self.expected())
            self.assertEqual(e.exception.code, 'FOREIGN_GRAPH_CACHE_PRESENT')

    def test_dev_cache_behaviour_is_unchanged_without_expectations(self):
        with TemporaryDirectory() as d:
            (Path(d) / (KLSEL.graph_id + '.jsonl')).write_text('other\n')
            GraphCache(self.rpc(self.manifest()), DEV.graph_id, d)  # original constructor: no new checks


class ApplicationTests(unittest.TestCase):
    def base_env(self, state, **overrides):
        env = dict(GEOLOCK_ENVIRONMENT='KLSEL', GEOLOCK_ROUTING_ALLOW_DEV_WRITES='APPROVED', GEOLOCK_ROUTING_ACTIVATION_REF='CHG-UNIT',
                   GEOLOCK_PROJECT_REF=KLSEL.project_ref, GEOLOCK_VALIDATOR_TOKEN='t' * 40,
                   GEOLOCK_GRAPH_DSN=dsn('geolock_graph_login', KLSEL.project_ref),
                   GEOLOCK_PLANNER_DSN=dsn('geolock_planner_login', KLSEL.project_ref),
                   GEOLOCK_VALIDATOR_DSN=dsn('geolock_validator_login', KLSEL.project_ref),
                   GEOLOCK_VALIDATOR_URL='http://127.0.0.1:8788', GEOLOCK_SUPABASE_PUBLISHABLE_KEY='sb_publishable_unit',
                   GEOLOCK_GRAPH_ID=KLSEL.graph_id, GEOLOCK_WORKER_STATE=str(state))
        env.update(overrides)
        return {k: v for k, v in env.items() if v is not None}

    def build(self, env, mode='planner'):
        with mock.patch.dict(os.environ, {**unset(), **{k: v for k, v in env.items() if k == 'GEOLOCK_ENVIRONMENT'}}, clear=True):
            return http_api.application_from_env(mode, env, rpc_factory=lambda d, role: type('Rpc', (), {'role': role})())

    def code(self, env, mode='planner'):
        with self.assertRaises(WorkerError) as e:
            self.build(env, mode)
        return e.exception.code

    def test_planner_uses_new_project_graph_and_isolated_state(self):
        with TemporaryDirectory() as d:
            state = Path(d) / 'GeoLockHubRoutingKLSEL' / 'state'
            app = self.build(self.base_env(state))
            self.assertTrue(app.active)
            self.assertEqual(app.project_ref, KLSEL.project_ref)
            self.assertEqual(app.auth._base, KLSEL.supabase_url)
            self.assertEqual(app.worker.graph.graph_id, KLSEL.graph_id)
            self.assertEqual(app.worker.graph.expected['content_digest'], KLSEL.graph_digest)
            self.assertEqual(json.loads((state / 'environment.json').read_text()),
                             {'environment': 'KLSEL', 'project_ref': KLSEL.project_ref, 'graph_id': KLSEL.graph_id})
            self.assertTrue(self.build(self.base_env(state)).active)  # same environment may reopen its state

    def test_validator_uses_new_project(self):
        with TemporaryDirectory() as d:
            app = self.build(self.base_env(Path(d)), mode='validator')
            self.assertEqual(app.project_ref, KLSEL.project_ref)

    def test_dev_identity_or_shared_state_is_refused(self):
        with TemporaryDirectory() as d:
            state = Path(d) / 'state'
            self.assertEqual(self.code(self.base_env(state, GEOLOCK_PROJECT_REF=DEV.project_ref)), 'ENVIRONMENT_PROJECT_REQUIRED')
            self.assertEqual(self.code(self.base_env(state, GEOLOCK_GRAPH_ID=DEV.graph_id)), 'ENVIRONMENT_GRAPH_ID_MISMATCH')
            self.assertEqual(self.code(self.base_env(state, GEOLOCK_GRAPH_DSN=dsn('geolock_graph_login', DEV.project_ref))),
                             'ENVIRONMENT_DATABASE_TARGET_REQUIRED')
            self.assertEqual(self.code(self.base_env(None, GEOLOCK_WORKER_STATE=None)), 'ENVIRONMENT_STATE_DIRECTORY_REQUIRED')
            self.assertEqual(self.code(self.base_env('relative/state')), 'ENVIRONMENT_STATE_DIRECTORY_REQUIRED')
            dev_state = Path(d) / 'GeoLockHubRoutingDev' / 'state'
            (dev_state / 'journal').mkdir(parents=True)
            self.assertEqual(self.code(self.base_env(dev_state)), 'STATE_DIRECTORY_BELONGS_TO_ANOTHER_ENVIRONMENT')
            other = Path(d) / 'other'
            other.mkdir()
            (other / 'environment.json').write_text(json.dumps({'environment': 'DEV', 'project_ref': DEV.project_ref, 'graph_id': DEV.graph_id}))
            self.assertEqual(self.code(self.base_env(other)), 'STATE_DIRECTORY_BELONGS_TO_ANOTHER_ENVIRONMENT')

    def test_disabled_startup_reports_the_selected_project_and_dev_is_unchanged(self):
        self.assertEqual(http_api.application_from_env('planner', {}).project_ref, DEV.project_ref)
        self.assertEqual(http_api.application_from_env('planner', SELECT_KLSEL).project_ref, KLSEL.project_ref)
        self.assertFalse(http_api.application_from_env('planner', SELECT_KLSEL).active)


class NativeProfileTests(unittest.TestCase):
    def write_profile(self, folder, **overrides):
        ca = Path(folder) / 'prod-ca-2021.crt'
        ca.write_text('unit CA\n')
        values = dict(host=POOLER, port='5432', dbname='postgres', user='geolock_graph_login.' + KLSEL.project_ref,
                      sslmode='verify-full', sslrootcert=str(ca), options='-c default_transaction_read_only=off', connect_timeout='15')
        values.update(overrides)
        path = Path(folder) / 'pg_service.conf'
        path.write_text('[' + values.pop('section', KLSEL.service_name) + ']\n' + ''.join(f'{k}={v}\n' for k, v in values.items()))
        return path

    def env(self, path):
        return {**unset(), 'GEOLOCK_ENVIRONMENT': 'KLSEL', 'GEOLOCK_PG_SERVICE_FILE': str(path)}

    def test_profile_is_required_outside_git_and_checked_against_the_registry(self):
        with mock.patch.dict(os.environ, {**unset(), **SELECT_KLSEL}, clear=True):
            with self.assertRaisesRegex(RuntimeError, 'ENVIRONMENT_SERVICE_PROFILE_REQUIRED'):
                native_connection.approved_profile()
        with mock.patch.dict(os.environ, self.env(native_connection.PROFILE), clear=True):
            with self.assertRaisesRegex(RuntimeError, 'SERVICE_PROFILE_MUST_BE_OUTSIDE_REPOSITORY'):
                native_connection.approved_profile()
        with TemporaryDirectory() as d:
            for bad in (dict(user='geolock_graph_login.' + DEV.project_ref), dict(sslmode='require'), dict(port='6543'),
                        dict(host='db.ppwmdsyoesvhgmqiaoxa.supabase.co'), dict(options='-c default_transaction_read_only=on')):
                with self.subTest(bad=bad), mock.patch.dict(os.environ, self.env(self.write_profile(d, **bad)), clear=True):
                    with self.assertRaisesRegex(RuntimeError, 'ENVIRONMENT_SERVICE_PROFILE_REJECTED'):
                        native_connection.approved_profile()
            with mock.patch.dict(os.environ, self.env(self.write_profile(d, section='geolock_dev_graph_initializer')), clear=True):
                with self.assertRaisesRegex(RuntimeError, 'UNEXPECTED_SERVICE_SECTION'):
                    native_connection.approved_profile()

    def test_valid_profile_drives_conninfo_and_diagnostic_target(self):
        with TemporaryDirectory() as d:
            path = self.write_profile(d)
            with mock.patch.dict(os.environ, self.env(path), clear=True):
                settings = native_connection.approved_profile()
                self.assertEqual(settings['host'], POOLER)
                conninfo = native_connection.byte_conninfo(b'secret', role='geolock_planner')
                self.assertTrue(conninfo.startswith(b'service=geolock_klsel_worker '))
                self.assertIn(b"user='geolock_planner_login.ppwmdsyoesvhgmqiaoxa'", conninfo)
                self.assertNotIn(DEV.project_ref.encode(), conninfo)
                self.assertEqual(connection_check.expected_target(KLSEL), (POOLER, settings['sslrootcert']))

    def test_dev_conninfo_bytes_are_unchanged(self):
        with mock.patch.dict(os.environ, unset(), clear=True):
            self.assertEqual(native_connection.byte_conninfo(b"pa'ss"),
                             b"service=geolock_dev_graph_initializer connect_timeout=5 options='-c default_transaction_read_only=on' password='pa\\'ss'")
            self.assertEqual(connection_check.expected_target(DEV),
                             ('aws-0-ap-northeast-2.pooler.supabase.com', 'C:/Users/User/Downloads/prod-ca-2021.crt'))


class WarmGraphTests(unittest.TestCase):
    def factory_read_only(self, argv):
        import sys
        from backend.routing.service import start_worker
        seen = {}
        class Factory:
            def __init__(self, read_only=False): seen['read_only'] = read_only
            def close(self): pass
        class Handle:
            def close(self): pass
        with mock.patch.object(sys, 'argv', ['start_worker'] + argv), \
             mock.patch('backend.routing.database.libpq_client.configure_client', return_value=(Handle(), {})), \
             mock.patch.object(start_worker, 'NativeRpcFactory', Factory), \
             mock.patch('backend.routing.service.http_api.main', lambda **kw: None):
            self.assertEqual(start_worker.main(), 0)
        return seen['read_only']

    def test_warm_graph_sessions_are_read_only(self):
        self.assertTrue(self.factory_read_only(['--mode', 'planner', '--warm-graph']))

    def test_normal_planner_start_is_unchanged(self):
        self.assertFalse(self.factory_read_only(['--mode', 'planner']))


class DevOnlyToolTests(unittest.TestCase):
    def test_pilot_benchmark_probe_refuses_the_new_project(self):
        from backend.routing.diagnostics import pilot_benchmark_probe
        with mock.patch.dict(os.environ, SELECT_KLSEL), self.assertRaises(WorkerError) as e:
            pilot_benchmark_probe.main()
        self.assertEqual(e.exception.code, 'DEV_ONLY_DIAGNOSTIC')


if __name__ == '__main__':
    unittest.main()
