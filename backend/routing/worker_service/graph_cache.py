"""Complete keyset export via protected RPC; immutable local disk cache."""
from pathlib import Path
import hashlib
import json
import os
import threading
from time import perf_counter

from ..integration.graph_worker import matrix_from_export
from .errors import check
from .transport import encode, uuid


class GraphCache:
    def __init__(self, rpc, graph_id, directory, *, max_edges=3_000_000, progress=None):
        self.rpc, self.graph_id = rpc, uuid(graph_id)
        self.directory = Path(directory)
        self.directory.mkdir(parents=True,exist_ok=True)
        self.max_edges = max_edges
        self._lock = threading.Lock()
        self._loaded = None
        self._progress = progress
        self.profile=dict(phase='not_started',rpc_seconds=0.0,json_encode_seconds=0.0,validation_seconds=0.0,
                          disk_write_seconds=0.0,fsync_seconds=0.0,cache_read_seconds=0.0,pages=[])
        self._counts=(0,0)

    def _notify(self):
        if self._progress:self._progress(*self._counts)

    def _page(self,after_node,after_edge):
        self.profile.update(phase='rpc_fetch',next_page=len(self.profile['pages'])+1)
        self._notify();start=perf_counter()
        try:page=self.rpc.call('read_frozen_routing_graph',self.graph_id,after_node,after_edge)
        except Exception:
            self.profile['failed_rpc_seconds']=perf_counter()-start
            self._notify()
            raise
        elapsed=perf_counter()-start;self.profile['rpc_seconds']+=elapsed
        self.profile['pages'].append(dict(nodes=len(page['nodes']),edges=len(page['edges']),rpc_seconds=round(elapsed,6),
            rows_per_second=round((len(page['nodes'])+len(page['edges']))/max(elapsed,1e-9),3),
            kind='nodes_and_edges' if page['nodes'] else 'edges_only' if page['edges'] else 'empty'))
        return page

    def _check_manifest(self,g):
        check(g['graph_id']==self.graph_id and 0<=g['edge_count']<=self.max_edges and 0<g['node_count']<=3_000_000,'GRAPH_SCOPE_REJECTED',422)
        check(g['coverage_snapshot'].startswith('OSM-OPS-') and g['float_output_profile']=='PG_REAL_OUTPUT_0','UNAPPROVED_GRAPH_PROFILE',422)

    def load(self):
        with self._lock:
            if self._loaded is not None: return self._loaded
            path = self.directory/(self.graph_id+'.jsonl')
            seal = self.directory/(self.graph_id+'.sha256')
            first = self._page(None,None)
            manifest = first['graph']; self._check_manifest(manifest)
            nodes,edges = [],[]
            if path.exists() and seal.exists():
                start=perf_counter();self.profile['phase']='disk_cache_read'
                h=hashlib.sha256()
                with path.open('rb') as f:
                    for line in f: h.update(line)
                check(h.hexdigest()==seal.read_text().strip(),'GRAPH_CACHE_INTEGRITY_FAILED',503)
                with path.open(encoding='utf-8') as f:
                    for line in f:
                        page=json.loads(line)
                        check(page['graph']==manifest,'GRAPH_MANIFEST_CHANGED',409)
                        nodes.extend(page['nodes']);edges.extend(page['edges'])
                self.profile['cache_read_seconds']+=perf_counter()-start
            else:
                # Partial files are never treated as complete graph coverage.
                temp=path.with_suffix('.partial')
                h=hashlib.sha256(); page=first; after_node=after_edge=None
                with temp.open('wb') as f:
                    while True:
                        start=perf_counter();self.profile['phase']='page_validation'
                        check(page['graph']==manifest,'GRAPH_MANIFEST_CHANGED',409)
                        ns,es=page['nodes'],page['edges']
                        check(len(ns)<=10000 and len(es)<=10000,'GRAPH_PAGE_INVALID',422)
                        if ns:
                            ids=[n['osm_node_id'] for n in ns]
                            check(ids==sorted(set(ids)) and (after_node is None or ids[0]>after_node),'GRAPH_CURSOR_INVALID',422)
                            after_node=ids[-1]
                        if es:
                            ids=[e['edge_id'] for e in es]
                            check(ids==sorted(set(ids)) and (after_edge is None or ids[0]>after_edge),'GRAPH_CURSOR_INVALID',422)
                            after_edge=ids[-1]
                        nodes.extend(ns);edges.extend(es)
                        self._counts=(len(nodes),len(edges))
                        check(len(nodes)<=manifest['node_count'] and len(edges)<=manifest['edge_count'],'GRAPH_EXPORT_OVERFLOW',422)
                        self.profile['validation_seconds']+=perf_counter()-start
                        start=perf_counter();self.profile['phase']='json_encode'
                        raw=(encode(page)+'\n').encode()
                        self.profile['json_encode_seconds']+=perf_counter()-start
                        start=perf_counter();self.profile['phase']='disk_write'
                        f.write(raw);h.update(raw)
                        self.profile['disk_write_seconds']+=perf_counter()-start
                        self._notify()
                        if len(nodes)==manifest['node_count'] and len(edges)==manifest['edge_count']: break
                        check(bool(ns or es),'INCOMPLETE_GRAPH_EXPORT',422)
                        page=self._page(after_node,after_edge)
                    start=perf_counter();f.flush();os.fsync(f.fileno())
                    self.profile['fsync_seconds']+=perf_counter()-start
                os.replace(temp,path)
                seal.write_text(h.hexdigest()+'\n')
            check(len(nodes)==manifest['node_count'] and len(edges)==manifest['edge_count'],'INCOMPLETE_GRAPH_EXPORT',422)
            self._loaded=(manifest,nodes,edges)
            self.profile['phase']='complete';self._counts=(len(nodes),len(edges));self._notify()
            return self._loaded

    def matrix(self, required_nodes, *, profile=None):
        check(1<=len(required_nodes)<=100,'MATRIX_SCOPE_REJECTED',422)
        manifest,nodes,edges=self.load()
        matrix=matrix_from_export(manifest,nodes,edges,required_nodes,profile=profile)
        check(all(s=='AVAILABLE' for row in matrix['arc_status'] for s in row),'ROUTE_UNAVAILABLE',422)
        return matrix
