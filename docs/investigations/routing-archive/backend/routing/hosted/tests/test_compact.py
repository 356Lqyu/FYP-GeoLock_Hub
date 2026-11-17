from copy import deepcopy
from dataclasses import FrozenInstanceError
from pathlib import Path
import random
from tempfile import TemporaryDirectory
import unittest

from ...contract import ContractError
from ...integration.graph_worker import matrix_from_export
from ...worker_service.errors import WorkerError
from ...worker_service.tests.test_graph_http import RoadRpc
from ...worker_service.tests.test_worker_flow import GID
from ..compact_graph import CompactGraph, CompactGraphCache


class CompactTests(unittest.TestCase):
    def test_inactive_nodes_and_incident_edges_match_original_filtering(self):
        rpc=RoadRpc()
        rpc.nodes.append(dict(osm_node_id=103,active_flag=False,network_snapshot_id=rpc.manifest['coverage_snapshot']))
        rpc.edges.append(dict(edge_id=3,source_node=101,target_node=103,road_km=1,travel_minutes=1))
        rpc.manifest.update(node_count=3,edge_count=3)
        graph=CompactGraph.from_export(rpc.manifest,rpc.nodes,rpc.edges)
        self.assertEqual(graph.matrix(['101','102']),matrix_from_export(rpc.manifest,rpc.nodes,rpc.edges,['101','102']))

    def test_random_directed_asymmetric_zero_tie_and_unreachable_parity(self):
        for seed in range(30):
            rng = random.Random(seed)
            rpc = RoadRpc()
            rpc.nodes = [dict(osm_node_id=i, active_flag=True,
                              network_snapshot_id=rpc.manifest['coverage_snapshot']) for i in range(1, 17)]
            rpc.edges = []
            for src in range(1, 14):
                for dst in range(1, 14):
                    if src != dst and rng.random() < .20:
                        rpc.edges.append(dict(edge_id=len(rpc.edges) + 1, source_node=src, target_node=dst,
                                              road_km=rng.choice([0, .000001, .1, 1]),
                                              travel_minutes=rng.choice([0, .000002, .2, 3])))
            rpc.manifest.update(node_count=len(rpc.nodes), edge_count=len(rpc.edges))
            compact = CompactGraph.from_export(rpc.manifest, rpc.nodes, rpc.edges)
            for order in [['1', '2', '3'], ['2', '15', '16'], ['11'], ['3', '12', '1']]:
                with self.subTest(seed=seed, order=order):
                    original = matrix_from_export(rpc.manifest, rpc.nodes, rpc.edges, order)
                    self.assertEqual(compact.matrix(order), original)

    def test_equal_distance_uses_time_and_lexical_edge_ids(self):
        rpc = RoadRpc()
        rpc.nodes += [dict(osm_node_id=103, active_flag=True, network_snapshot_id=rpc.manifest['coverage_snapshot'])]
        rpc.edges = [dict(edge_id=i, source_node=a, target_node=b, road_km=d, travel_minutes=t)
                     for i, a, b, d, t in [(10,101,103,1,3),(2,101,102,1,1),(30,102,103,0,2),(4,103,101,1,1)]]
        rpc.manifest.update(node_count=3, edge_count=4)
        graph = CompactGraph.from_export(rpc.manifest, rpc.nodes, rpc.edges)
        self.assertEqual(graph.matrix(['101','102','103']), matrix_from_export(rpc.manifest,rpc.nodes,rpc.edges,['101','102','103']))

    def test_artifact_roundtrip_tamper_and_manifest_binding(self):
        rpc = RoadRpc()
        graph = CompactGraph.from_export(rpc.manifest, rpc.nodes, rpc.edges)
        with TemporaryDirectory() as tmp:
            path = Path(tmp) / 'graph.csr'
            seal = graph.write_artifact(path)
            restored = CompactGraph.read_artifact(path, seal, rpc.manifest)
            self.assertEqual(restored.matrix(['101','102']), graph.matrix(['101','102']))
            with self.assertRaises(FrozenInstanceError):
                restored.node_count = 99
            with self.assertRaises(TypeError):
                restored._targets[0] = 1
            changed = dict(rpc.manifest, content_digest='e'*64)
            with self.assertRaises(ContractError):
                CompactGraph.read_artifact(path, seal, changed)
            path.write_bytes(path.read_bytes() + b'x')
            with self.assertRaises(ContractError):
                CompactGraph.read_artifact(path, seal, rpc.manifest)

    def test_repeated_cache_matrix_releases_export_and_never_reconverts(self):
        rpc = RoadRpc()
        with TemporaryDirectory() as tmp:
            cache = CompactGraphCache(rpc, GID, tmp)
            first = cache.matrix(['101','102'])
            calls = rpc.calls
            self.assertIsNone(cache._loaded)
            self.assertEqual(cache.matrix(['101','102']), first)
            self.assertEqual(rpc.calls, calls)
            rpc.edges[0]['road_km'] = 999  # caller mutation cannot affect compiled graph
            self.assertEqual(cache.matrix(['101','102']), first)

    def test_pinned_artifact_needs_manifest_page_not_full_export(self):
        rpc = RoadRpc()
        with TemporaryDirectory() as tmp:
            path = Path(tmp) / 'graph.csr'
            seal = CompactGraph.from_export(rpc.manifest,rpc.nodes,rpc.edges).write_artifact(path)
            cache = CompactGraphCache(rpc,GID,Path(tmp)/'cache',artifact=path,artifact_sha256=seal)
            cache.matrix(['101','102'])
            self.assertEqual(rpc.calls,1)
            self.assertIsNone(cache._loaded)

    def test_duplicate_invalid_precision_scope_and_missing_arcs_fail_closed(self):
        rpc = RoadRpc()
        for change in ['duplicate', 'precision', 'count']:
            m,n,e = deepcopy((rpc.manifest,rpc.nodes,rpc.edges))
            if change == 'duplicate': e[1]['edge_id'] = e[0]['edge_id']
            if change == 'precision': e[0]['road_km'] = .0000001
            if change == 'count': m['edge_count'] += 1
            with self.subTest(change=change), self.assertRaises(ContractError):
                CompactGraph.from_export(m,n,e)
        rpc.edges.pop()
        rpc.manifest['edge_count'] = 1
        with TemporaryDirectory() as tmp:
            with self.assertRaises(WorkerError) as error:
                CompactGraphCache(rpc,GID,tmp).matrix(['101','102'])
            self.assertEqual(error.exception.code,'ROUTE_UNAVAILABLE')
