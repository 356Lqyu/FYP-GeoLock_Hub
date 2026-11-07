"""Assemble complete frozen RPC pages, then reuse C2's directed path builder."""
from ..contract import DEV_PROJECT
from ..planner.matrices import freeze_graph, build_matrix, require
from .worker import token
from time import perf_counter


def matrix_from_export(manifest, nodes, edges, required_nodes, *, profile=None):
    """No paging/network code here. Caller must supply the complete frozen export.

    Counts and ID uniqueness prove completeness relative to a trusted manifest;
    they do not authenticate a caller-created export. Worker credentials and RPC
    provenance remain deployment requirements. Synthetic tests are not road data.
    """
    started=perf_counter();stats={'phase':'export_validation'}
    def mark(phase):
        nonlocal started
        now=perf_counter();stats[stats['phase']+'_seconds']=now-started
        stats['phase']=phase;started=now
        if profile:profile(dict(stats))
    if profile:profile(dict(stats))
    token(manifest['content_digest'])
    require(manifest['precision_policy']=='EXACT_MAX_6_DECIMALS','UNREVIEWED_PRECISION_POLICY')
    require(manifest['float_output_profile']=='PG_REAL_OUTPUT_0','UNREVIEWED_FLOAT_PROJECTION')
    require(len(nodes)==manifest['node_count'] and len(edges)==manifest['edge_count'],'INCOMPLETE_GRAPH_EXPORT')
    require(len({n['osm_node_id'] for n in nodes})==len(nodes) and len({e['edge_id'] for e in edges})==len(edges),'DUPLICATE_GRAPH_ROWS')
    selected={str(n['osm_node_id']) for n in nodes if n['active_flag'] and n['network_snapshot_id']==manifest['coverage_snapshot']}
    require(bool(selected),'EMPTY_APPROVED_GRAPH')
    mark('graph_conversion_and_freeze')
    graph=freeze_graph(nodes=sorted(selected),edges=[dict(edge_id=str(e['edge_id']),source_node=str(e['source_node']),target_node=str(e['target_node']),
             road_km=e['road_km'],travel_minutes=e['travel_minutes']) for e in edges if str(e['source_node']) in selected and str(e['target_node']) in selected],
             snapshot_id=manifest['coverage_snapshot'],kind='OPERATIONAL_ROAD_NETWORK',complete=True,project_ref=DEV_PROJECT,
             speed_profile=manifest['speed_profile'])
    del selected
    mark('matrix_build')
    def matrix_profile(value):
        stats['matrix']=value
        if profile:profile(dict(stats))
    matrix=build_matrix(graph,required_nodes,profile=matrix_profile if profile else None)
    matrix['provenance']='Frozen graph '+manifest['graph_id']+' / DB digest '+manifest['content_digest']+'; '+manifest['float_output_profile']+'; C2 path digest '+graph.sha256
    mark('complete')
    return matrix
