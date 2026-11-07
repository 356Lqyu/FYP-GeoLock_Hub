"""Bounded local directed graph matrices. No cropped-search no-path assertions.

Graph completeness is a supplied declaration, not proof of database provenance.
Operational sealing/version identity remains a protected PostgreSQL responsibility.
"""
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation
import hashlib
import heapq
import json
import re
from time import perf_counter

from ..contracts import DEV_PROJECT, ContractError


def require(ok,code):
    if not ok:
        raise ContractError(code,'phase_c2',code)


def canonical(value):
    return json.dumps(value,sort_keys=True,separators=(',',':'),allow_nan=False)


def digest(value):
    return hashlib.sha256(canonical(value).encode()).hexdigest()


def numeric(value,positive=False):
    require(type(value) in (int,float,str),'INVALID_GRAPH_COST')
    try:
        number=Decimal(str(value))
        valid=number.is_finite() and (number>0 if positive else number>=0)
        require(valid,'INVALID_GRAPH_COST')
        require(number==number.quantize(Decimal('0.000001')),'UNSUPPORTED_GRAPH_PRECISION')
    except InvalidOperation:
        require(False,'INVALID_GRAPH_COST')
    return number


@dataclass(frozen=True)
class FrozenGraph:
    canonical_json: str
    sha256: str

    def to_dict(self):
        return json.loads(self.canonical_json)


def freeze_graph(*,nodes,edges,snapshot_id,kind,complete,project_ref=None,speed_profile):
    require(kind in {'SYNTHETIC_BENCHMARK','OPERATIONAL_ROAD_NETWORK'},'INVALID_GRAPH_PROVENANCE')
    require(project_ref==(DEV_PROJECT if kind=='OPERATIONAL_ROAD_NETWORK' else None),'INVALID_PROJECT_SCOPE')
    require(isinstance(snapshot_id,str) and bool(snapshot_id.strip()),'INVALID_GRAPH_SNAPSHOT')
    require(kind!='OPERATIONAL_ROAD_NETWORK' or snapshot_id.startswith('OSM-OPS-'),'INVALID_GRAPH_SNAPSHOT')
    require(type(complete) is bool,'INVALID_GRAPH_COMPLETENESS')
    require(isinstance(speed_profile,str) and bool(speed_profile.strip()),'MISSING_SPEED_PROFILE')
    require(type(nodes) is list and all(type(n) is str and n.strip() for n in nodes),'INVALID_GRAPH_NODE')
    node_set=set(nodes)
    require(len(nodes)==len(node_set),'DUPLICATE_GRAPH_NODE')
    require(kind!='OPERATIONAL_ROAD_NETWORK' or all(re.fullmatch('[1-9][0-9]*',n) for n in nodes),'INVALID_GRAPH_NODE')
    require(type(edges) is list,'INVALID_GRAPH_EDGES')
    items=[]; seen=set()
    for edge in edges:
        require(type(edge) is dict and set(edge)=={'edge_id','source_node','target_node','road_km','travel_minutes'},'INVALID_GRAPH_EDGE')
        require(type(edge['edge_id']) is str and bool(edge['edge_id']) and edge['edge_id'] not in seen,'DUPLICATE_GRAPH_EDGE')
        seen.add(edge['edge_id'])
        require(edge['source_node'] in node_set and edge['target_node'] in node_set,'UNKNOWN_GRAPH_NODE')
        # Explicitly reject precision unsupported by the existing execution model.
        # Never round live REAL edge costs silently or invent a speed assumption.
        item=dict(edge)
        for key in ('road_km','travel_minutes'):
            item[key]=str(numeric(edge[key]))
        items.append(item)
    payload=dict(version='geolock.local.graph.v1',nodes=sorted(nodes),edges=sorted(items,key=lambda e:e['edge_id']),
                 snapshot_id=snapshot_id,kind=kind,complete=complete,project_ref=project_ref,speed_profile=speed_profile,
                 authority='LOCAL_UNTRUSTED')
    # Preserve the exact canonical bytes/digest while avoiding a second complete
    # JSON serialization (and its overlapping full-size string allocation).
    encoded=canonical(payload)
    return FrozenGraph(encoded,hashlib.sha256(encoded.encode()).hexdigest())


def build_matrix(graph,node_order,*,unavailable_policy='FAIL_SCENARIO',profile=None):
    started=perf_counter();stats={'phase':'canonical_decode','searches':[]}
    def mark(phase):
        nonlocal started
        now=perf_counter();stats[stats['phase']+'_seconds']=now-started
        stats['phase']=phase;started=now
        if profile:profile(dict(stats))
    if profile:profile(dict(stats))
    data=graph.to_dict()
    mark('digest_verification')
    require(digest(data)==graph.sha256,'GRAPH_DIGEST_MISMATCH')
    require(type(data) is dict and set(data)=={'version','nodes','edges','snapshot_id','kind','complete','project_ref','speed_profile','authority'},'INVALID_GRAPH_CONTRACT')
    mark('contract_reconstruction')
    rebuilt=freeze_graph(nodes=data['nodes'],edges=data['edges'],snapshot_id=data['snapshot_id'],kind=data['kind'],complete=data['complete'],project_ref=data['project_ref'],speed_profile=data['speed_profile'])
    require(rebuilt==graph,'INVALID_GRAPH_CONTRACT')
    del rebuilt
    require(type(node_order) is list and all(type(n) is str for n in node_order) and len(node_order)==len(set(node_order)),'INVALID_MATRIX_NODE_ORDER')
    require(set(node_order)<=set(data['nodes']),'UNKNOWN_GRAPH_NODE')
    require(unavailable_policy in {'FAIL_SCENARIO','FORBID_ARC'},'INVALID_UNAVAILABLE_POLICY')
    mark('adjacency_construction')
    adjacency={n:[] for n in data['nodes']}
    for edge in data['edges']:
        adjacency[edge['source_node']].append(edge)
    mark('directed_search')
    distances=[]; durations=[]; statuses=[]
    for source in node_order:
        search_started=perf_counter();remaining=set(node_order)
        # Distance first; time and stable edge-ID path break exact distance ties.
        # Travel time is accumulated on precisely the selected distance path.
        best={source:(Decimal(0),Decimal(0),())}
        queue=[(*best[source],source)]; settled=set()
        while queue:
            distance,minutes,path,node=heapq.heappop(queue)
            if node in settled or (distance,minutes,path)!=best[node]:
                continue
            settled.add(node)
            # Every requested destination must be SETTLED, not merely discovered.
            # Subsequent expansion cannot alter those values in the existing
            # distance/time/edge-ID settlement algorithm. Unreachable targets
            # still exhaust the reachable graph; no cropped no-path assertion.
            remaining.discard(node)
            if not remaining:break
            for edge in adjacency[node]:
                target=edge['target_node']
                if target in settled:
                    continue
                score=(distance+Decimal(edge['road_km']),minutes+Decimal(edge['travel_minutes']),path+(edge['edge_id'],))
                if target not in best or score<best[target]:
                    best[target]=score; heapq.heappush(queue,(*score,target))
        # A path in a cropped graph does not certify the full graph's shortest
        # path. Never present even a found cropped path as an accepted matrix arc.
        usable=lambda n:n in best and (data['complete'] or n==source)
        distances.append([float(best[n][0]) if usable(n) else None for n in node_order])
        durations.append([float(best[n][1]) if usable(n) else None for n in node_order])
        statuses.append(['AVAILABLE' if usable(n) else 'UNREACHABLE' if data['complete'] else 'MISSING' for n in node_order])
        stats['searches'].append(dict(settled_nodes=len(settled),discovered_nodes=len(best),
            unsettled_targets=len(remaining),seconds=perf_counter()-search_started))
        if profile:profile(dict(stats))
    matrix=dict(matrix_id='LOCAL-'+graph.sha256,version=graph.sha256,network_snapshot_id=data['snapshot_id'],
                source_kind=data['kind'],provenance='Local graph digest '+graph.sha256+'; completeness is declared, not DB-attested',
                method='DIRECTED_DIJKSTRA_DISTANCE_THEN_TIME_THEN_EDGE_ID',edge_speed_profile=data['speed_profile'],
                path_policy='DIRECTED_SHORTEST_DISTANCE_WITH_TIME_ON_SAME_PATH',unavailable_policy=unavailable_policy,
                node_order=list(node_order),distance_km=distances,travel_minutes=durations,arc_status=statuses)
    mark('complete')
    return matrix
