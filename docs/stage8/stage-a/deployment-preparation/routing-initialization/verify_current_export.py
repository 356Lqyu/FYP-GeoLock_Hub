"""Offline current-DEV export comparison; no database/network access.

Requires complete secure exporter receipt and hashes. Streaming sorted merge
compares all node/edge records, binary storage, coverage and directed costs.
Current edge IDs are generated, absent from import CSV: validate/pin separately.
"""
import argparse
from array import array
import csv
from datetime import datetime,timezone
from decimal import Decimal
import hashlib
import json
import math
from pathlib import Path
import struct
import sys
import time

from road_export_contract import (HERE,ROOT,REFERENCE,PROJECT,SNAPSHOT,NODES,EDGES,
    HASHES,sha,reference_check,approved_profile,real_bits,coverage_reference)
sys.path.insert(0,str(ROOT))
from backend.routing.phase_c2.matrices import numeric

POINTS=(1755847853,2308277456,5735535080)
EXPECTED_PROFILE={'host':'aws-0-ap-northeast-2.pooler.supabase.com','port':'5432','dbname':'postgres',
 'user':'postgres.'+PROJECT,'sslmode':'verify-full','sslrootcert':'C:/Users/User/Downloads/prod-ca-2021.crt',
 'options':'-c default_transaction_read_only=on','connect_timeout':'15'}

class Checks:
    def __init__(self):
        self.started=time.monotonic(); self.counts={}; self.examples=[]; self.progress={}
    def fail(self,kind,detail):
        self.counts[kind]=self.counts.get(kind,0)+1
        if len(self.examples)<30: self.examples.append({'kind':kind,'detail':detail})
    def budget(self):
        if time.monotonic()-self.started>180: raise TimeoutError('Offline 180-second budget exceeded; no PASS')

def rows(path,key,checks,expected_header):
    previous=None
    with path.open(newline='',encoding='utf-8-sig') as f:
        reader=csv.DictReader(f)
        if reader.fieldnames!=expected_header: raise ValueError('Unexpected CSV header: '+path.name)
        for i,row in enumerate(reader,1):
            k=key(row)
            if previous is not None and k<=previous:
                checks.fail('duplicate_or_unsorted_key',{'file':path.name,'key':k})
                raise ValueError('Duplicate/unsorted key: '+path.name)
            previous=k
            if i%65536==0: checks.budget()
            yield k,row

def merge(expected,actual,checks,label):
    left=next(expected,None); right=next(actual,None)
    while left is not None or right is not None:
        if right is None or (left is not None and left[0]<right[0]):
            checks.fail(label+'_missing',str(left[0])); left=next(expected,None)
        elif left is None or right[0]<left[0]:
            checks.fail(label+'_unexpected',str(right[0]));
            # Yield every actual record so ID/endpoint/coverage checks include extra rows.
            yield None,right[1]; right=next(actual,None)
        else:
            yield left[1],right[1]
            left=next(expected,None); right=next(actual,None)

def compare(directory,checks):
    hashes=reference_check()
    receipt=json.loads((directory/'receipt.json').read_text())
    if receipt.get('status')!='COMPLETE' or receipt.get('rollback_completed') is not True:
        raise ValueError('Complete export/ROLLBACK receipt required')
    if receipt.get('project_ref')!=PROJECT or receipt.get('connection')!=EXPECTED_PROFILE:
        raise ValueError('Export target/profile mismatch')
    exporter = receipt.get('exporter_file', 'export_current_dev.py')
    if exporter not in ('export_current_dev.py', 'export_current_dev_native.py'):
        raise ValueError('Unapproved exporter implementation')
    if receipt.get('exporter_sha256')!=sha(HERE/exporter) or receipt.get('query_contract_sha256')!=sha(HERE/'road_export_contract.py'):
        raise ValueError('Exporter source drift; review original capture before adapting verifier')
    identity=receipt['identity']
    if not(identity['database']=='postgres' and identity['current_user']==identity['session_user']=='postgres'
       and identity['read_only']=='on' and identity['ssl'] is True and identity['float_output']=='0'
       and 170000<=identity['server_version_num']<180000): raise ValueError('Identity/TLS/read-only receipt mismatch')
    for name in ('nodes.csv','edges.csv'):
        path=directory/name
        if path.stat().st_size>1_000_000_000: raise ValueError('Export exceeds local safety size bound')
        if sha(path)!=receipt['files'][name]['sha256'] or path.stat().st_size!=receipt['files'][name]['bytes']:
            raise ValueError('Export file checksum/size mismatch: '+name)
    coverage=receipt['coverage']; expected_coverage=coverage_reference()
    if len(coverage)!=1: checks.fail('coverage_inventory',len(coverage))
    matching=[c for c in coverage if c['network_snapshot_id']==SNAPSHOT]
    if len(matching)!=1: raise ValueError('Exactly one intended coverage row required')
    cov=matching[0]
    criteria={'dataset_kind':'OPERATIONAL','active_flag':True,'node_count':NODES,'edge_count':EDGES,
        'max_snap_distance_m':500,'srid':4326,'dimensions':2,'geometry_type':'MULTIPOLYGON',
        'valid_geometry':True,**expected_coverage}
    for key,value in criteria.items():
        if cov.get(key)!=value: checks.fail('coverage_'+key,{'expected':value,'actual':cov.get(key)})
    if not cov.get('approved_at'): checks.fail('coverage_approval','missing')

    node_index={}; count_nodes=0
    nh=['osm_node_id','network_snapshot_id','latitude','longitude','component_id','active_flag']
    ah=['osm_node_id','network_snapshot_id','latitude','latitude_hex','longitude','longitude_hex','component_id','active_flag']
    expected=rows(REFERENCE/'road_network_nodes.csv',lambda r:int(r['osm_node_id']),checks,nh)
    actual=rows(directory/'nodes.csv',lambda r:int(r['osm_node_id']),checks,ah)
    for old,new in merge(expected,actual,checks,'node'):
        count_nodes+=1; node=int(new['osm_node_id'])
        if count_nodes>1_500_000: raise ValueError('Node safety bound exceeded')
        node_index[node]=len(node_index)
        if node<=0: checks.fail('invalid_node_id',node)
        if new['network_snapshot_id']!=SNAPSHOT or new['active_flag']!='t': checks.fail('node_snapshot_or_active',node)
        for key,lo,hi in (('latitude',-90,90),('longitude',-180,180)):
            value=struct.unpack('!d',bytes.fromhex(new[key+'_hex']))[0]
            if not math.isfinite(value) or not lo<=value<=hi: checks.fail('node_coordinate_range',node)
            if old and struct.pack('!d',float(old[key])).hex()!=new[key+'_hex']:
                checks.fail('node_'+key+'_binary64',node)
        if old and (old['network_snapshot_id']!=new['network_snapshot_id'] or old['component_id']!=new['component_id']
           or (old['active_flag']=='true')!=(new['active_flag']=='t')): checks.fail('node_metadata',node)
    if count_nodes!=NODES: checks.fail('node_count',{'expected':NODES,'actual':count_nodes})
    checks.progress['nodes_compared']=count_nodes

    count_edges=0; seen_ids=set(); mapping_hash=hashlib.sha256()
    sources,targets=array('I'),array('I'); degree=array('I',[0])*len(node_index)
    converted_count={'road_km':0,'travel_minutes':0}; max_error={'road_km':Decimal(0),'travel_minutes':Decimal(0)}
    error_cache={}
    eh=['source_node','target_node','road_km','travel_minutes']
    ah=['edge_id','source_node','target_node','road_km','road_km_hex','travel_minutes','travel_minutes_hex']
    key=lambda r:(int(r['source_node']),int(r['target_node']))
    expected=rows(REFERENCE/'road_network_edges.csv',key,checks,eh)
    actual=rows(directory/'edges.csv',key,checks,ah)
    for old,new in merge(expected,actual,checks,'directed_edge'):
        count_edges+=1
        if count_edges>3_000_000: raise ValueError('Edge safety bound exceeded')
        edge,u,v=int(new['edge_id']),int(new['source_node']),int(new['target_node'])
        if not 0<edge<=2147483647 or edge in seen_ids: checks.fail('invalid_or_duplicate_edge_id',edge)
        seen_ids.add(edge); mapping_hash.update(f'{edge},{u},{v}\n'.encode())
        if u not in node_index or v not in node_index: checks.fail('missing_endpoint',[edge,u,v])
        else:
            a,b=node_index[u],node_index[v]; sources.append(a); targets.append(b); degree[a]+=1
        for field in ('road_km','travel_minutes'):
            hx=new[field+'_hex']
            value=struct.unpack('!f',bytes.fromhex(hx))[0]
            if not math.isfinite(value) or value<=0: checks.fail('invalid_'+field,edge)
            try: numeric(new[field],positive=True)
            except Exception: checks.fail('unsupported_projected_precision_'+field,{'edge_id':edge,'value':new[field]})
            if math.isfinite(value) and Decimal(new[field])!=Decimal(format(value,'.6g')):
                checks.fail('serialized_real_projection_'+field,{'edge_id':edge,'value':new[field]})
            if old:
                expected_bits=real_bits(old[field])
                if hx!=expected_bits: checks.fail(field+'_storage_bits',{'edge_id':edge,'expected':expected_bits,'actual':hx})
                text=old[field]
                if text not in error_cache:
                    converted=struct.unpack('!f',bytes.fromhex(expected_bits))[0]
                    error_cache[text]=abs(Decimal.from_float(converted)-Decimal(text))
                delta=error_cache[text]
                converted_count[field]+=int(delta!=0); max_error[field]=max(max_error[field],delta)
        if count_edges%65536==0: checks.budget(); checks.progress['edges_compared']=count_edges
    checks.progress['edges_compared']=count_edges
    if count_edges!=EDGES: checks.fail('edge_count',{'expected':EDGES,'actual':count_edges})

    # Actual exported graph only. Direction preserved; no cropped-search no-path claim.
    pairs=[]
    if all(p in node_index for p in POINTS):
        offsets=array('I',[0])
        for d in degree: offsets.append(offsets[-1]+d)
        cursor=array('I',offsets[:-1]); adjacency=array('I',[0])*len(sources)
        for i,(a,b) in enumerate(zip(sources,targets)):
            adjacency[cursor[a]]=b; cursor[a]+=1
            if i%65536==0: checks.budget()
        for point in POINTS:
            source=node_index[point]; visited=bytearray(len(node_index)); visited[source]=1
            queue=array('I',[source]); head=0; remaining={node_index[p] for p in POINTS if p!=point}
            while head<len(queue) and remaining:
                u=queue[head]; head+=1
                for i in range(offsets[u],offsets[u+1]):
                    v=adjacency[i]
                    if not visited[v]: visited[v]=1; queue.append(v); remaining.discard(v)
                if head%65536==0: checks.budget()
            for target in POINTS:
                reachable=bool(visited[node_index[target]])
                pairs.append({'source_node':point,'target_node':target,'directed_reachable':reachable})
                if not reachable: checks.fail('unreachable_pair',[point,target])
    else: checks.fail('diagnostic_node_missing',[p for p in POINTS if p not in node_index])
    checks.budget()
    return {'comparison_completed':True,'scope':'All imported node fields and directed natural-key edges at PostgreSQL storage precision; current export capture only',
      'node_count':count_nodes,'edge_count':count_edges,'unique_actual_edge_ids':len(seen_ids),
      'actual_edge_id_mapping_sha256':mapping_hash.hexdigest(),'reference_hashes':hashes,
      'coverage_checks':criteria,'coverage_observed_approved_at':cov.get('approved_at'),
      'real_conversion_nonzero_decimal_errors':converted_count,
      'maximum_expected_decimal_to_real_absolute_error':{k:str(v) for k,v in max_error.items()},
      'directed_reachability':pairs,'source_export_observed_at':identity['observed_at'],
      'limitations':['Import CSV does not contain generated edge_id; historical edge-ID equivalence cannot be established',
        'Exact import-time builder and original PBF not reconstructed/rehashed',
        'No whole-network SCC, shortest paired-cost matrix, performance, policy installation, freeze or runtime acceptance tested',
        'Approved coverage geometry/metadata equivalence, not a new point-in-polygon census or geographic service guarantee',
        'Receipt is operator evidence, not independent cryptographic attestation of the remote server']}

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--export-dir',type=Path,required=True)
    args=parser.parse_args(); directory=args.export_dir.resolve()
    # Never overwrite a prior verification outcome; retain failed/partial evidence.
    result_path=directory/('equivalence-'+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')+'.json')
    checks=Checks()
    try:
        result=compare(directory,checks)
        result['verdict']='PASS / SCOPED STORAGE EQUIVALENCE' if not checks.counts else 'FAIL'
    except Exception as error:
        result={'verdict':'NOT VERIFIED / COMPARISON INCOMPLETE','comparison_completed':False,
          'error_type':type(error).__name__,'error':str(error)}
    result.update(mismatches=checks.counts,mismatch_examples=checks.examples,progress=checks.progress,
       elapsed_seconds=round(time.monotonic()-checks.started,3),database_access=False)
    with result_path.open('x',encoding='utf-8') as f: json.dump(result,f,indent=2); f.write('\n')
    print('Verification report: '+str(result_path))
    print('Verdict: '+result['verdict'])
    return 0 if result['verdict'].startswith('PASS') else 1

if __name__=='__main__': raise SystemExit(main())
