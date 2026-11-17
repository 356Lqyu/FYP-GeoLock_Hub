"""Future offline Docker benchmarks; never builds/pulls or connects to a service.

Requires a prebuilt local planner image, sealed local fixtures and explicit CLI
paths. Writes a fresh run directory, never historical benchmark evidence.
"""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import shutil
import subprocess
from uuid import uuid4

PROFILES=(('512mb-0.1cpu','512m','.1'),('2gb-1cpu','2g','1'),
          ('4gb-2cpu','4g','2'),('8gb-2cpu','8g','2'))


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--image',required=True);p.add_argument('--fixtures',required=True)
    p.add_argument('--export-sha256',required=True);p.add_argument('--bundle-sha256',required=True)
    p.add_argument('--scope',required=True);p.add_argument('--output-root',required=True)
    a=p.parse_args()
    if not shutil.which('docker'):p.error('Docker unavailable; no resource-profile PASS can be claimed')
    if os.name=='posix' and os.getuid()==0:
        p.error('run as a nonroot operator so bind-mounted benchmark results keep operator ownership')
    root=Path(a.output_root).resolve()/('render-'+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')+'-'+uuid4().hex[:8])
    root.mkdir(parents=True,exist_ok=False)
    fixtures=Path(a.fixtures).resolve()
    if not all((fixtures/name).is_file() for name in ('graph.jsonl','bundle.json')):p.error('missing approved fixtures')
    receipts=[]
    for name,memory,cpu in PROFILES:
        for engine in ('legacy','compact'):
            label=name+'-'+engine
            container='geolock-offline-'+uuid4().hex[:12]
            cmd=['docker','run','--pull=never','--name',container,'--network','none',
                 '--memory',memory,'--memory-swap',memory,'--cpus',cpu,'--pids-limit','128',
                 '--cap-drop','ALL','--security-opt','no-new-privileges','--read-only',
                 '--tmpfs','/tmp:rw,noexec,nosuid,size=64m',
                 '--mount',f'type=bind,source={fixtures},target=/fixtures,readonly',
                 '--mount',f'type=bind,source={root},target=/out',a.image,
                 'python','-m','backend.routing.hosted.benchmark','--engine',engine,
                 '--export','/fixtures/graph.jsonl','--export-sha256',a.export_sha256,
                 '--bundle','/fixtures/bundle.json','--bundle-sha256',a.bundle_sha256,
                 '--scope',a.scope,'--output','/out/'+label+'.json',
                 '--expected-memory-bytes',str(int(memory[:-1])*(1024**2 if memory[-1]=='m' else 1024**3)),
                 '--expected-cpu',cpu]
            if os.name=='posix':
                cmd[2:2]=['--user',str(os.getuid())+':'+str(os.getgid())]
            try:
                completed=subprocess.run(cmd,capture_output=True,text=True,timeout=3600)
                with (root/(label+'.log')).open('x',encoding='utf-8') as log:
                    log.write(completed.stdout+completed.stderr)
                receipt=dict(profile=name,engine=engine,exit_code=completed.returncode)
            except subprocess.TimeoutExpired:
                subprocess.run(['docker','stop','--time','10',container],capture_output=True,timeout=30)
                receipt=dict(profile=name,engine=engine,status='TIMEOUT')
            inspected=subprocess.run(['docker','inspect',container],capture_output=True,text=True,timeout=30)
            if inspected.returncode==0:
                instance=json.loads(inspected.stdout)[0];state=instance['State']
                receipt['container_state']={k:state.get(k) for k in ('ExitCode','OOMKilled','Error','FinishedAt')}
                receipt['host_config']={k:instance['HostConfig'].get(k) for k in
                                        ('Memory','MemorySwap','NanoCpus','NetworkMode','ReadonlyRootfs')}
            subprocess.run(['docker','rm',container],capture_output=True,timeout=30)
            receipts.append(receipt)
            (root/'receipts.json').write_text(json.dumps(receipts,indent=2)+'\n',encoding='utf-8')
    print(root)


if __name__=='__main__':main()
