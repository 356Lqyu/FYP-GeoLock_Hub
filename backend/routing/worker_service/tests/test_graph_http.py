"""Only local disk/loopback HTTP and explicitly synthetic road data."""
from copy import deepcopy
from http.server import ThreadingHTTPServer
from tempfile import TemporaryDirectory
from threading import Thread
import json
import unittest
import urllib.error
import urllib.request

from backend.routing.worker_service.graph_cache import GraphCache
from backend.routing.worker_service.errors import WorkerError
from backend.routing.worker_service.server import Application,make_handler
from backend.routing.worker_service.tests.test_worker_flow import GID


class RoadRpc:
    def __init__(self):
        self.manifest=dict(graph_id=GID,node_count=2,edge_count=2,coverage_snapshot='OSM-OPS-SYNTHETIC-UNIT-ONLY',
            content_digest='d'*64,precision_policy='EXACT_MAX_6_DECIMALS',float_output_profile='PG_REAL_OUTPUT_0',speed_profile='SYNTHETIC paired edge costs')
        self.nodes=[dict(osm_node_id=i,network_snapshot_id=self.manifest['coverage_snapshot'],active_flag=True) for i in (101,102)]
        self.edges=[dict(edge_id=1,source_node=101,target_node=102,road_km=1,travel_minutes=4),
                    dict(edge_id=2,source_node=102,target_node=101,road_km=2,travel_minutes=5)]
        self.calls=0
    def call(self,name,graph,after_node,after_edge):
        assert name=='read_frozen_routing_graph' and graph==GID
        self.calls+=1
        return deepcopy(dict(graph=self.manifest,nodes=[n for n in self.nodes if after_node is None or n['osm_node_id']>after_node][:1],
                             edges=[e for e in self.edges if after_edge is None or e['edge_id']>after_edge][:1]))


class GraphTests(unittest.TestCase):
    def setUp(self):
        self.temp=TemporaryDirectory();self.addCleanup(self.temp.cleanup);self.rpc=RoadRpc()
        self.cache=GraphCache(self.rpc,GID,self.temp.name)

    def test_complete_paging_reuses_c2_directed_distances_and_times(self):
        matrix=self.cache.matrix(['101','102'])
        self.assertEqual(matrix['distance_km'],[[0,1],[2,0]])
        self.assertEqual(matrix['travel_minutes'],[[0,4],[5,0]])
        self.assertEqual(self.rpc.calls,2)

    def test_disk_cache_is_reusable_after_process_restart(self):
        first=self.cache.matrix(['101','102'])
        second=GraphCache(self.rpc,GID,self.temp.name).matrix(['101','102'])
        self.assertEqual(first,second);self.assertEqual(self.rpc.calls,3)

    def test_cache_tampering_fails_closed(self):
        self.cache.load()
        with (self.cache.directory/(GID+'.jsonl')).open('a') as f:f.write('\n')
        with self.assertRaises(WorkerError):GraphCache(self.rpc,GID,self.temp.name).load()

    def test_incomplete_export_is_not_declared_reachable(self):
        self.rpc.manifest['edge_count']=3
        with self.assertRaises(WorkerError) as caught:self.cache.load()
        self.assertEqual(caught.exception.code,'INCOMPLETE_GRAPH_EXPORT')

    def test_missing_reverse_arc_is_not_invented(self):
        self.rpc.edges.pop();self.rpc.manifest['edge_count']=1
        with self.assertRaises(WorkerError) as caught:self.cache.matrix(['101','102'])
        self.assertEqual(caught.exception.code,'ROUTE_UNAVAILABLE')


class HttpTests(unittest.TestCase):
    def setUp(self):
        self.server=ThreadingHTTPServer(('127.0.0.1',0),make_handler(Application(active=False)))
        self.thread=Thread(target=self.server.serve_forever,daemon=True);self.thread.start()
        self.base='http://127.0.0.1:'+str(self.server.server_port)
        self.addCleanup(self.stop)

    def stop(self):
        self.server.shutdown();self.server.server_close();self.thread.join(timeout=5)

    def test_disabled_health_is_not_a_live_success_claim(self):
        with urllib.request.urlopen(self.base+'/health') as response:
            self.assertEqual(json.load(response)['status'],'DISABLED')

    def test_disabled_http_request_cannot_trigger_worker_or_dev_writes(self):
        req=urllib.request.Request(self.base+'/v1/plan',data=b'{}',headers={'Content-Type':'application/json','Authorization':'Bearer SYNTHETIC'})
        with self.assertRaises(urllib.error.HTTPError) as caught:urllib.request.urlopen(req)
        self.assertEqual(caught.exception.code,503)
        result=json.load(caught.exception)
        self.assertEqual(result['error']['code'],'WORKER_NOT_ACTIVATED')
        self.assertFalse(result['dispatch_authority_issued'])


if __name__=='__main__':unittest.main()
