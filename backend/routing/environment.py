"""Per-environment routing identity. Importing performs no I/O.

DEV is the default whenever GEOLOCK_ENVIRONMENT is unset, so every existing DEV
launch keeps its exact behaviour. Another environment is used only when it is
selected explicitly. Values here are non-secret identifiers: no passwords,
publishable keys, tokens or DSNs.
"""
from dataclasses import dataclass
import os

ENVIRONMENT_VARIABLE = 'GEOLOCK_ENVIRONMENT'
SERVICE_FILE_VARIABLE = 'GEOLOCK_PG_SERVICE_FILE'


@dataclass(frozen=True)
class Environment:
    name: str
    project_ref: str
    graph_id: str
    graph_digest: str
    coverage_snapshot: str
    node_count: int
    edge_count: int
    speed_profile: str
    local_directory: str          # folder under %LOCALAPPDATA% for profiles, state and cache
    service_name: str             # libpq service section used by the native Windows runtime
    pinned_pooler_host: str = None  # DEV pins its host; other environments take it from their profile
    pinned_ca_path: str = None
    tail_after_node: int = None   # bounded read-only diagnostic sample (no full pages)
    tail_node_ids: tuple = ()
    tail_after_edge: int = None
    tail_edge_ids: tuple = ()

    @property
    def is_dev(self):
        return self.name == 'DEV'

    @property
    def supabase_url(self):
        return 'https://' + self.project_ref + '.supabase.co'

    def graph_manifest(self):
        """The frozen-graph fields a cache or diagnostic must observe."""
        return dict(graph_id=self.graph_id, content_digest=self.graph_digest,
                    coverage_snapshot=self.coverage_snapshot, node_count=self.node_count,
                    edge_count=self.edge_count, speed_profile=self.speed_profile)


SPEED_PROFILE = 'OSM_MAXSPEED_OR_CLASS_DEFAULT_BUILD_188bde7568b4d9eb_DIST5DP_TIME4DP_NO_LIVE_TRAFFIC_PG_REAL_OUTPUT_0'

ENVIRONMENTS = {
    'DEV': Environment(
        name='DEV', project_ref='rcgyuwiidqvrgbxswhqj',
        graph_id='eab1f7ee-a8e0-4bed-a0e1-2c4bff024936',
        graph_digest='5e06dab0fb4d2b97ac53fd9a1178dc46aa6b98811aefbaef96528c604a04012a',
        coverage_snapshot='OSM-OPS-20261018', node_count=926414, edge_count=2145828,
        speed_profile=SPEED_PROFILE, local_directory='GeoLockHubRoutingDev',
        service_name='geolock_dev_graph_initializer',
        pinned_pooler_host='aws-0-ap-northeast-2.pooler.supabase.com',
        pinned_ca_path='C:/Users/User/Downloads/prod-ca-2021.crt',
        tail_after_node=14297239927, tail_node_ids=(14297239930, 14297239933, 14297239934),
        tail_after_edge=2145825, tail_edge_ids=(2145826, 2145827, 2145828)),
    # NEW project: KL + Selangor + Putrajaya, frozen 21 Nov 2026 (graph freeze package, 03 verified).
    'KLSEL': Environment(
        name='KLSEL', project_ref='ppwmdsyoesvhgmqiaoxa',
        graph_id='19c44bd2-8871-4eca-bf6b-4262f1bf766d',
        graph_digest='6b62b3654312587e00461a21d9aafe93272d301f39dd644f5011b1afae9edc32',
        coverage_snapshot='OSM-OPS-20261018-KLSEL', node_count=205524, edge_count=454178,
        speed_profile=SPEED_PROFILE, local_directory='GeoLockHubRoutingKLSEL',
        service_name='geolock_klsel_worker',
        # Highest node IDs of the reviewed trimmer output; edge IDs depend on import
        # order, so the bounded sample reads no edges (cursor past the last edge).
        tail_after_node=14297239927, tail_node_ids=(14297239930, 14297239933, 14297239934),
        tail_after_edge=2147483647, tail_edge_ids=()),
}


def active(env=None):
    """The selected environment; DEV when nothing is selected. Unknown names fail closed."""
    name = (os.environ if env is None else env).get(ENVIRONMENT_VARIABLE) or 'DEV'
    if name not in ENVIRONMENTS:
        raise ValueError('UNKNOWN_GEOLOCK_ENVIRONMENT')
    return ENVIRONMENTS[name]


def active_project_ref(env=None):
    return active(env).project_ref


def by_project_ref(project_ref):
    for item in ENVIRONMENTS.values():
        if item.project_ref == project_ref:
            return item
    raise ValueError('UNKNOWN_PROJECT_REF')
