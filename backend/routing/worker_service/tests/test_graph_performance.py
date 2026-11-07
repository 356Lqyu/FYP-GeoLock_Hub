"""Synthetic graphs only: measured phases, full pages and deterministic search."""
from decimal import Decimal
import heapq
import random
from tempfile import TemporaryDirectory
import unittest

from backend.routing.phase_c2.matrices import freeze_graph,build_matrix
from backend.routing.worker_service.graph_cache import GraphCache
from backend.routing.worker_service.tests.test_graph_http import RoadRpc
from backend.routing.worker_service.tests.test_worker_flow import GID


def exhaustive_reference(edges,nodes,order):
    adjacency={n:[] for n in nodes}
    for e in edges:adjacency[e['source_node']].append(e)
    distances=[];minutes=[]
    for source in order:
        best={source:(Decimal(0),Decimal(0),())};queue=[(*best[source],source)];settled=set()
        while queue:
            d,t,path,node=heapq.heappop(queue)
            if node in settled or (d,t,path)!=best[node]:continue
            settled.add(node)
            for e in adjacency[node]:
                target=e['target_node']
                if target in settled:continue
                score=(d+Decimal(str(e['road_km'])),t+Decimal(str(e['travel_minutes'])),path+(e['edge_id'],))
                if target not in best or score<best[target]:
                    best[target]=score;heapq.heappush(queue,(*score,target))
        distances.append([float(best[n][0]) if n in best else None for n in order])
        minutes.append([float(best[n][1]) if n in best else None for n in order])
    return distances,minutes


def synthetic_graph(nodes,edges):
    return freeze_graph(nodes=nodes,edges=edges,snapshot_id='SYNTHETIC',kind='SYNTHETIC_BENCHMARK',
        complete=True,speed_profile='synthetic only')


class GraphPerformanceTests(unittest.TestCase):
    def test_target_settlement_matches_exhaustive_direction_cost_tie_and_unreachable_cases(self):
        for seed in range(20):
            rng=random.Random(seed);nodes=[str(i) for i in range(15)];edges=[]
            for i in range(13):
                for j in range(13):
                    if i!=j and rng.random()<.2:
                        edges.append(dict(edge_id=str(len(edges)+1),source_node=str(i),target_node=str(j),
                            road_km=rng.choice([0,1,1,2]),travel_minutes=rng.choice([0,1,2])))
            for order in [['0','1','2'],['0','14'],['2']]:
                expected=exhaustive_reference(edges,nodes,order)
                matrix=build_matrix(synthetic_graph(nodes,edges),order)
                self.assertEqual((matrix['distance_km'],matrix['travel_minutes']),expected)

    def test_large_irrelevant_tail_is_not_expanded_after_all_targets_settle(self):
        nodes=[str(i) for i in range(10000)]
        edges=[dict(edge_id=str(i+1),source_node='0',target_node=str(i),road_km=i,travel_minutes=i) for i in range(1,len(nodes))]
        profiles=[];matrix=build_matrix(synthetic_graph(nodes,edges),['0','1','2'],profile=profiles.append)
        self.assertEqual(matrix['distance_km'][0],[0,1,2])
        searches=profiles[-1]['searches']
        self.assertEqual(searches[0]['settled_nodes'],3)
        self.assertTrue(all(k in profiles[-1] for k in ['canonical_decode_seconds','contract_reconstruction_seconds','adjacency_construction_seconds','directed_search_seconds']))
        self.assertEqual(matrix,build_matrix(synthetic_graph(nodes,edges),['0','1','2']))

    def test_full_10000_row_keyset_pages_and_profile_do_not_change_graph(self):
        rpc=RoadRpc();count=10001
        rpc.nodes=[dict(osm_node_id=i,active_flag=True,network_snapshot_id=rpc.manifest['coverage_snapshot']) for i in range(1,count+1)]
        rpc.edges=[dict(edge_id=i,source_node=(i-1)%count+1,target_node=i%count+1,road_km=1,travel_minutes=2) for i in range(1,20002)]
        rpc.manifest.update(node_count=count,edge_count=len(rpc.edges))
        calls=[]
        def page(name,gid,after_node,after_edge):
            calls.append((after_node,after_edge))
            return dict(graph=dict(rpc.manifest),nodes=rpc.nodes[after_node or 0:(after_node or 0)+10000],edges=rpc.edges[after_edge or 0:(after_edge or 0)+10000])
        rpc.call=page
        with TemporaryDirectory() as folder:
            cache=GraphCache(rpc,GID,folder);manifest,nodes,edges=cache.load()
            self.assertEqual(nodes,rpc.nodes);self.assertEqual(edges,rpc.edges)
            self.assertEqual(calls,[(None,None),(10000,10000),(10001,20000)])
            self.assertEqual([p['kind'] for p in cache.profile['pages']],['nodes_and_edges','nodes_and_edges','edges_only'])
            self.assertTrue(all(p['rows_per_second']>0 for p in cache.profile['pages']))
            self.assertEqual(cache.profile['phase'],'complete')
            self.assertEqual(GraphCache(rpc,GID,folder).load(),(manifest,nodes,edges))

    def test_failed_page_retains_measured_phase_without_claiming_completion(self):
        rpc=RoadRpc();rpc.call=lambda *args:(_ for _ in ()).throw(ValueError('SYNTHETIC'))
        with TemporaryDirectory() as folder:
            cache=GraphCache(rpc,GID,folder)
            with self.assertRaises(ValueError):cache.load()
            self.assertEqual(cache.profile['phase'],'rpc_fetch');self.assertEqual(cache.profile['pages'],[])
            self.assertGreaterEqual(cache.profile['failed_rpc_seconds'],0)
