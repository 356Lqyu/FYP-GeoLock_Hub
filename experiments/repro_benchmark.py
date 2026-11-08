"""Local experiment utilities. Never imports/runs a baseline CLI or remote DSN."""
from pathlib import Path
import csv, hashlib, importlib.util, json, os, platform, subprocess, sys
ROOT=Path(__file__).resolve().parents[1]
TEAM=ROOT
SOURCE_DATA=ROOT/'benchmark dataset/dataset'
DATA=ROOT/'experiments/repro_inputs/v33'

def sha(p): return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def write(p,obj): Path(p).write_text(json.dumps(obj,indent=2,default=str,allow_nan=False)+'\n',encoding='utf-8')
def rows(p):
    with Path(p).open(encoding='utf-8-sig',newline='') as f:return list(csv.DictReader(f))
def csv_write(p,records):
    if not records:return
    keys=list(dict.fromkeys(k for r in records for k in r))
    with Path(p).open('w',encoding='utf-8-sig',newline='') as f:
        w=csv.DictWriter(f,fieldnames=keys);w.writeheader();w.writerows(records)
def module(name):
    p=ROOT/'baseline implementation/source code'/f'{name}_baseline.py'
    m=importlib.util.module_from_spec(importlib.util.spec_from_file_location('original_'+name,p))
    # No pycache writes and no __main__: hardcoded remote defaults never execute.
    exec(compile(p.read_bytes(),str(p),'exec'),m.__dict__)
    return m
def clear_remote_env():
    for k in list(os.environ):
        if k.upper().startswith(('PG','SUPABASE','GEOLOCK')) or k.upper() in ('DATABASE_URL','DB_URL'):os.environ.pop(k,None)
def integrity(teammate_root=None):
    manifest=json.loads((SOURCE_DATA/'generation_manifest.json').read_text(encoding='utf-8'))
    assert manifest['benchmark_version']=='GEOLOCK-BM-v3.3'
    evidence={};transport=[]
    DATA.mkdir(parents=True,exist_ok=True)
    manifest_copy=DATA/'generation_manifest.json'
    if not manifest_copy.exists():manifest_copy.write_bytes((SOURCE_DATA/'generation_manifest.json').read_bytes())
    assert sha(manifest_copy)==sha(SOURCE_DATA/'generation_manifest.json')
    for name,digest in manifest['generated_csv_sha256'].items():
        original=SOURCE_DATA/(name+'.csv');supplied=original.read_bytes()
        canonical=supplied if sha(original)==digest else supplied.replace(b'\r\n',b'\n').replace(b'\n',b'\r\n')
        assert hashlib.sha256(canonical).hexdigest()==digest,('FROZEN_DATA_CHANGED',name)
        p=DATA/original.name
        if not p.exists():p.write_bytes(canonical)
        assert sha(p)==digest and len(rows(p))==manifest['row_counts'][name]
        if teammate_root is not None:
            t=Path(teammate_root)/'benchmark dataset/dataset'/p.name
            assert t.is_file() and sha(t)==sha(original),('TEAM_DATA_DIFFERS',name)
        evidence[str(p.relative_to(ROOT))]=digest
        transport.append(dict(file=name,source_sha256=sha(original),manifest_sha256=digest,repair='CRLF bytes in separate copy only' if supplied!=canonical else 'none'))
    for name in ('fcfs','nearest_next','non_atomic_claim','protected_claim_without_lease_recovery'):
        p=ROOT/'baseline implementation/source code'/f'{name}_baseline.py'
        if teammate_root is not None:
            assert sha(p)==sha(Path(teammate_root)/p.relative_to(ROOT)),('TEAM_BASELINE_DIFFERS',name)
        evidence[str(p.relative_to(ROOT))]=sha(p)
    evidence['benchmark dataset/dataset/generation_manifest.json']=sha(SOURCE_DATA/'generation_manifest.json')
    scenario_counts={}
    for r in rows(DATA/'scenarios.csv'):scenario_counts[r['scenario_type']]=scenario_counts.get(r['scenario_type'],0)+1
    for kind,n in [('CLAIM_COORDINATION',150),('LEASE_RECOVERY',100),('LEASE_ACTIVE_VERIFICATION',25),('ROUTE_PLANNING',100)]:assert scenario_counts[kind]==n
    return dict(version=manifest['benchmark_version'],matrix_id=manifest['matrix_id'],dataset_seed=manifest['seed'],scenario_counts=scenario_counts,verified_sha256=evidence,baseline_reference='checked-in untouched teammate baseline copies',external_teammate_root_verified=teammate_root is not None,transport_repairs=transport)
def environment():
    import ortools,psycopg
    g=subprocess.run(['git','rev-parse','HEAD'],cwd=ROOT,capture_output=True,text=True)
    status=subprocess.run(['git','status','--porcelain'],cwd=ROOT,capture_output=True,text=True)
    return dict(python=sys.version,executable=sys.executable,platform=platform.platform(),ortools=ortools.__version__,psycopg=psycopg.__version__,git_commit=g.stdout.strip(),working_tree_dirty=bool(status.stdout.strip()),remote_access=False)
