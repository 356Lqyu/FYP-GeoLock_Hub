"""Compute existing jsonb hash expression in a NEW disposable cluster only."""
import argparse
import json
from pathlib import Path
import sys
import tempfile
ROOT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT/'supabase/tests'))
from stage8_spatial_isolated_test import Harness

def main():
    p=argparse.ArgumentParser();p.add_argument('--runtime',required=True,type=Path);p.add_argument('--records',required=True,type=Path);p.add_argument('--output',required=True,type=Path);a=p.parse_args()
    runtime=a.runtime.resolve();out=a.output.resolve();records=a.records.resolve()
    if runtime.parent!=Path(tempfile.gettempdir()).resolve() or not runtime.name.startswith('geolock-spatial-runtime-'):p.error('Private owned runtime required')
    if out.exists() or not out.is_relative_to(ROOT) or not records.is_relative_to(ROOT):p.error('New workspace evidence directory required')
    out.mkdir(parents=True);(out/'sql').mkdir();h=Harness(runtime,out);error=None;stopped=False
    try:
        h.start();values=[]
        for path in sorted(records.glob('*.[0-9][0-9].json')):
            r=json.loads(path.read_text());body=json.dumps(r['candidate'],separators=(',',':'),allow_nan=False).replace("'","''")
            values.append("('"+path.name+"','"+body+"'::jsonb)")
        if len(values)!=24:raise RuntimeError('Expected 24 diagnostic candidates')
        # Exact hash expression from routing_private.hash(jsonb); no installation,
        # application RPC or authority operation is performed.
        sql="SET timezone='UTC'; SET extra_float_digits=0; SELECT jsonb_agg(jsonb_build_object('record',id,'candidate_digest',encode(sha256(convert_to(body::text,'UTF8')),'hex'),'jsonb_text',body::text) ORDER BY id) FROM (VALUES "+','.join(values)+") v(id,body);"
        hashes=json.loads(h.sql(sql));h.save('candidate-digests.json',hashes)
        h.save('environment.json',dict(postgresql=h.sql('SELECT version();'),scope='EXACT_LOCAL_POSTGRESQL_JSONB_HASH_EXPRESSION_ONLY',candidates=len(hashes)))
    except Exception as e:error=str(e);raise
    finally:
        if h.started:h.process('pg_ctl',['-D',str(h.data),'-m','fast','-w','stop']);stopped=True
        h.save('results.json',dict(error=error,cluster_stopped=stopped,supabase_connections=0))

if __name__=='__main__':main()
