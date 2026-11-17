"""Offline single-process measurements; invoke in separate processes per engine.

No network, database, credentials, workers or hosted services. Synthetic mode is
unit-scale evidence only. Full-network evidence requires an approved sealed export
AND matching DB-shaped offline bundle, with explicit scope label.
"""
from time import perf_counter
START = perf_counter()
import argparse
from dataclasses import asdict
import hashlib
import json
import os
from pathlib import Path
import platform
from tempfile import TemporaryDirectory


def peak_memory():
    if os.name == 'nt':
        import ctypes
        from ctypes import wintypes
        class Counters(ctypes.Structure):
            _fields_ = [('cb',wintypes.DWORD),('PageFaultCount',wintypes.DWORD)] + [
                (name,ctypes.c_size_t) for name in ('PeakWorkingSetSize','WorkingSetSize',
                'QuotaPeakPagedPoolUsage','QuotaPagedPoolUsage','QuotaPeakNonPagedPoolUsage',
                'QuotaNonPagedPoolUsage','PagefileUsage','PeakPagefileUsage','PrivateUsage')]
        counters=Counters(); counters.cb=ctypes.sizeof(counters)
        kernel=ctypes.WinDLL('kernel32'); kernel.GetCurrentProcess.restype=wintypes.HANDLE
        get=ctypes.WinDLL('psapi').GetProcessMemoryInfo
        get.argtypes=(wintypes.HANDLE,ctypes.POINTER(Counters),wintypes.DWORD)
        get.restype=wintypes.BOOL
        ok=get(kernel.GetCurrentProcess(),ctypes.byref(counters),counters.cb)
        if not ok: raise OSError('GetProcessMemoryInfo failed')
        return dict(peak_rss_bytes=counters.PeakWorkingSetSize,peak_commit_bytes=counters.PeakPagefileUsage)
    import resource
    return dict(peak_rss_bytes=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss*1024)


def cgroup():
    root=Path('/sys/fs/cgroup')
    return {name:(root/name).read_text().strip() if (root/name).is_file() else None
            for name in ('memory.max','cpu.max','memory.peak','memory.events')}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--engine',choices=('legacy','compact','artifact'),required=True)
    parser.add_argument('--synthetic',action='store_true')
    parser.add_argument('--export'); parser.add_argument('--export-sha256')
    parser.add_argument('--bundle'); parser.add_argument('--bundle-sha256')
    parser.add_argument('--scope',default='UNCLASSIFIED')
    parser.add_argument('--artifact'); parser.add_argument('--artifact-sha256')
    parser.add_argument('--output',required=True)
    parser.add_argument('--expected-memory-bytes',type=int)
    parser.add_argument('--expected-cpu',type=float)
    args=parser.parse_args()
    if (args.expected_memory_bytes is None)!=(args.expected_cpu is None):
        parser.error('memory and CPU expectations must be supplied together')
    if args.expected_memory_bytes is not None or args.expected_cpu is not None:
        limits=cgroup()
        if platform.system()!='Linux' or limits['memory.max']!=str(args.expected_memory_bytes):
            parser.error('requested Linux memory cgroup not verified')
        quota,period=limits['cpu.max'].split()
        if quota=='max' or abs(int(quota)/int(period)-args.expected_cpu)>0.000001:
            parser.error('requested Linux CPU quota not verified')
    from .compact_graph import CompactGraph
    from .artifact import load_export
    from ..integration.graph_worker import matrix_from_export
    from ..integration import solve_bundle, validate_work_item
    if args.synthetic:
        from ..worker_service.tests.test_graph_http import RoadRpc
        from ..integration.tests.test_worker import synthetic_bundle
        source=RoadRpc(); manifest=source.manifest
        nodes=[dict(osm_node_id=i,active_flag=True,network_snapshot_id=manifest['coverage_snapshot']) for i in range(101,1101)]
        edges=[]
        for i in range(101,1101):
            for offset in (1,7,29):
                edges.append(dict(edge_id=len(edges)+1,source_node=i,target_node=101+(i-101+offset)%1000,
                                  road_km=offset/100,travel_minutes=offset/10))
        manifest.update(node_count=len(nodes),edge_count=len(edges))
        bundle=synthetic_bundle(); scope='SYNTHETIC-1000-NODES-3000-EDGES-NOT-FULL-NETWORK'
        fixture_sha=hashlib.sha256(json.dumps([manifest,nodes,edges],sort_keys=True).encode()).hexdigest()
    else:
        if not all((args.export,args.export_sha256,args.bundle,args.bundle_sha256,args.scope!='UNCLASSIFIED')):
            parser.error('approved export/bundle paths, SHA256s and scope required')
        manifest,nodes,edges=load_export(args.export,args.export_sha256)
        raw=Path(args.bundle).read_bytes()
        if hashlib.sha256(raw).hexdigest()!=args.bundle_sha256: parser.error('bundle SHA256 mismatch')
        bundle=json.loads(raw);scope=args.scope;fixture_sha=args.export_sha256
    order=bundle['matrix']['body']['node_order']
    result=dict(engine=args.engine,scope=scope,fixture_sha256=fixture_sha,
                platform=platform.platform(),python=platform.python_version(),
                node_count=len(nodes),edge_count=len(edges),required_nodes=len(order),cgroup_before=cgroup(),
                startup_and_fixture_seconds=perf_counter()-START)
    result['after_fixture']=peak_memory()
    started=perf_counter()
    if args.engine=='compact':
        graph=CompactGraph.from_export(manifest,nodes,edges)
        matrix=lambda:graph.matrix(order)
        result['compact_payload_bytes']=len(graph._payload)
    elif args.engine=='artifact':
        if not args.artifact or not args.artifact_sha256: parser.error('artifact and independently pinned SHA required')
        # For apples-to-apples parity tests the export was loaded above. This
        # benchmark does NOT claim export-free artifact startup memory.
        graph=CompactGraph.read_artifact(args.artifact,args.artifact_sha256,manifest)
        matrix=lambda:graph.matrix(order)
        result['compact_payload_bytes']=len(graph._payload)
    else:
        matrix=lambda:matrix_from_export(manifest,nodes,edges,order)
    result['warm_seconds']=perf_counter()-started
    if args.engine=='compact':
        with TemporaryDirectory() as tmp:
            path=Path(tmp)/'offline.csr'
            started=perf_counter();seal=graph.write_artifact(path)
            result['artifact_write_and_seal_seconds']=perf_counter()-started
            started=perf_counter();restored=CompactGraph.read_artifact(path,seal,manifest)
            result['artifact_restore_seconds']=perf_counter()-started
            if restored.matrix(order)!=graph.matrix(order):raise AssertionError('artifact parity')
            del restored
    durations=[];output=None
    for _ in range(3):
        started=perf_counter();current=matrix();durations.append(perf_counter()-started)
        if output is not None and current!=output: raise AssertionError('non-deterministic matrix')
        output=current
    result['matrix_seconds']=durations
    result['matrix_sha256']=hashlib.sha256(json.dumps(output,sort_keys=True,separators=(',',':')).encode()).hexdigest()
    result['after_matrix']=peak_memory()
    bundle['matrix']['body']=output
    started=perf_counter();comparison=solve_bundle(bundle)
    result['four_methods_solver_seconds']=perf_counter()-started
    result['methods']=[name for name,_,_ in comparison.results]
    result['all_four_plans_valid']=all(check.valid for _,_,check in comparison.results)
    work=dict(**bundle,candidate=dict(snapshot_id=bundle['snapshot']['snapshot_id'],digest='c'*64,
                                      body=dict(plan=asdict(comparison.proposed_candidate))))
    started=perf_counter();report=validate_work_item(work,validator_build='OFFLINE-RENDER-BENCHMARK')
    result['independent_validation_seconds']=perf_counter()-started
    result['validation_status']=report['status'] if 'status' in report else report
    result['final_memory']=peak_memory();result['cgroup_after']=cgroup()
    result['total_seconds']=perf_counter()-START
    with Path(args.output).open('x',encoding='utf-8') as stream:
        json.dump(result,stream,indent=2);stream.write('\n')


if __name__=='__main__': main()
