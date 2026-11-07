"""Separate capped Linux runs of existing frozen synthetic benchmark inputs."""
import json
import subprocess
import time
from uuid import uuid4
import run_validation as v


def main():
    receipts=[]
    for profile,memory,cpu in v.PROFILES:
        name='geolock-frozen-offline-'+uuid4().hex[:12]
        args=['run','--pull','never','--name',name,'--network','none','--read-only','--memory',memory,
              '--memory-swap',memory,'--cpus',cpu,'--cap-drop','ALL','--security-opt','no-new-privileges',
              '--tmpfs','/tmp:rw,nosuid,size=64m','--mount',
              f'type=bind,source={v.OUT / "frozen_probe.py"},target=/frozen.py,readonly','--mount',
              f'type=bind,source={v.OUT / "frozen-v33-sample.json"},target=/fixtures/frozen.json,readonly',
              v.PLANNER,'python','-B','/frozen.py']
        started=time.monotonic()
        with (v.OUT/(profile+'-frozen-v33.log')).open('x',encoding='utf-8') as log:
            p=subprocess.Popen(v.PREFIX+args,env=v.ENV,stdout=log,stderr=subprocess.STDOUT)
            try:code=p.wait(timeout=240)
            except subprocess.TimeoutExpired:
                v.command(['kill',name]);code=p.wait(timeout=30)
        inspected=json.loads(v.command(['inspect',name]).stdout)[0]
        r=dict(profile=profile,exit_code=code,oom=inspected['State']['OOMKilled'],wall_seconds=time.monotonic()-started,
               image_id=inspected['Image'],limits={k:inspected['HostConfig'][k] for k in
               ('Memory','MemorySwap','NanoCpus','NetworkMode','ReadonlyRootfs')})
        if code==0:r['result']=json.loads((v.OUT/(profile+'-frozen-v33.log')).read_text())
        receipts.append(r);v.command(['rm',name])
        (v.OUT/'frozen-resource-receipts.json').write_text(json.dumps(receipts,indent=2)+'\n',encoding='utf-8')
        print(json.dumps(dict(profile=profile,exit_code=code,oom=r['oom'])),flush=True)


if __name__=='__main__':main()
