"""Local desktop-linux only; offline containers, explicit readonly fixture mounts.

Never mounts live state or credentials. Removes only uniquely named containers
and the disposable volume created by this run, after recording their receipts.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
from uuid import uuid4

ROOT=Path(__file__).resolve().parents[3]
OUT=Path(__file__).resolve().parent
DOCKER=Path(os.environ['LOCALAPPDATA'])/'Programs/DockerDesktop/resources/bin/docker.exe'
ENV=dict(os.environ,PATH=str(DOCKER.parent)+os.pathsep+os.environ['PATH'])
PREFIX=[str(DOCKER),'--context','desktop-linux']
PLANNER='geolock-planner:validation-fixed-20261107'
VALIDATOR='geolock-validator:validation-fixed-20261107'
PROFILES=[('512mb-0.1cpu','512m','.1'),('2gb-1cpu','2g','1'),('4gb-2cpu','4g','2'),('8gb-2cpu','8g','2')]
VOLUME='geolock-offline-validation-'+uuid4().hex[:12]
RECEIPTS=[]


def command(args,**kwargs):
    return subprocess.run(PREFIX+args,env=ENV,capture_output=True,text=True,check=True,timeout=60,**kwargs)


def mounts():
    values=['--mount',f'type=bind,source={OUT / "container_probe.py"},target=/probe.py,readonly']
    for folder in ('worker_service/tests','integration/tests','hosted/tests','phase_c2/tests'):
        values+=['--mount',f'type=bind,source={ROOT / "backend/routing" / folder},target=/app/backend/routing/{folder},readonly']
    return values


def run_case(label,args,*,image=PLANNER,profile=('8gb-2cpu','8g','2'),extra=(),timeout=240):
    name='geolock-offline-'+uuid4().hex[:12]
    identifier,memory,cpu=profile
    options=['run','--pull','never','--name',name,'--network','none','--read-only',
             '--memory',memory,'--memory-swap',memory,'--cpus',cpu,'--pids-limit','128',
             '--cap-drop','ALL','--security-opt','no-new-privileges',
             '--tmpfs','/tmp:rw,nosuid,size=256m']+mounts()+list(extra)
    started=time.monotonic();timed_out=False
    with (OUT/(label+'.log')).open('x',encoding='utf-8') as log:
        proc=subprocess.Popen(PREFIX+options+[image]+list(args),env=ENV,stdout=log,stderr=subprocess.STDOUT,text=True)
        try:code=proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out=True;command(['kill',name]);code=proc.wait(timeout=30)
    inspection=json.loads(command(['inspect',name]).stdout)[0]
    state=inspection['State'];host=inspection['HostConfig']
    receipt=dict(label=label,profile=identifier,image_id=inspection['Image'],exit_code=code,
                 timed_out=timed_out,wall_seconds=time.monotonic()-started,
                 state={k:state.get(k) for k in ('ExitCode','OOMKilled','Error')},
                 limits={k:host.get(k) for k in ('Memory','MemorySwap','NanoCpus','NetworkMode','ReadonlyRootfs')})
    text=(OUT/(label+'.log')).read_text(encoding='utf-8')
    if code==0:
        for line in reversed(text.splitlines()):
            try:
                value=json.loads(line)
                if isinstance(value,dict):receipt['result']=value;break
            except json.JSONDecodeError:pass
    RECEIPTS.append(receipt)
    (OUT/'resource-receipts.json').write_text(json.dumps(RECEIPTS,indent=2)+'\n',encoding='utf-8')
    command(['rm',name])
    print(json.dumps(dict(label=label,exit_code=code,oom=state['OOMKilled'],timed_out=timed_out)),flush=True)
    return receipt


def main():
    info=json.loads(command(['version','--format','{{json .}}']).stdout)
    assert info['Server']['Os']=='linux' and info['Server']['Arch']=='amd64'
    with (OUT/'docker-version.json').open('x',encoding='utf-8') as f:json.dump(info,f,indent=2)
    images={}
    for role,image in [('planner',PLANNER),('validator',VALIDATOR)]:
        v=json.loads(command(['image','inspect',image]).stdout)[0]
        assert v['Config']['User']=='10001:10001'
        images[role]={k:v[k] for k in ('Id','RepoTags','Created','Architecture','Os','Size')}
        images[role]['user']=v['Config']['User'];images[role]['env_names']=[x.split('=',1)[0] for x in v['Config']['Env']]
        r=run_case(role+'-inventory',['python','-B','/probe.py','inventory'],image=image)
        assert r['exit_code']==0
    with (OUT/'image-receipts.json').open('x',encoding='utf-8') as f:json.dump(images,f,indent=2)
    # Runtime tests operate in a nonroot container with synthetic test directories.
    r=run_case('linux-hosted-after',['python','-B','-m','unittest','discover','-s','backend/routing/hosted/tests','-t','.','-v'])
    assert r['exit_code']==0
    r=run_case('linux-core-regression',['python','-B','-m','unittest',
        'backend.routing.phase_c2.tests.test_local','backend.routing.integration.tests.test_worker',
        'backend.routing.worker_service.tests.test_worker_flow','backend.routing.worker_service.tests.test_combined_workflow',
        'backend.routing.worker_service.tests.test_graph_http','-v'])
    assert r['exit_code']==0
    unit_out=['--mount',f'type=bind,source={OUT},target=/out']
    assert run_case('prepare-synthetic-validator',['python','-B','/probe.py','prepare-validator'],extra=unit_out)['exit_code']==0
    unit_in=['--mount',f'type=bind,source={OUT / "synthetic-validator-work.json"},target=/fixtures/synthetic-validator-work.json,readonly']
    for profile in PROFILES:
        for role,image in [('planner',PLANNER),('validator',VALIDATOR)]:
            run_case(profile[0]+'-'+role+'-startup',['python','-B','/probe.py','startup','--role',role],image=image,profile=profile)
        for engine in ('legacy','compact'):
            run_case(profile[0]+'-synthetic-planner-'+engine,['python','-B','/probe.py','planner','--engine',engine],profile=profile)
        run_case(profile[0]+'-synthetic-validator',['python','-B','/probe.py','validator'],image=VALIDATOR,profile=profile,extra=unit_in)
    graph=ROOT/'results/worker-readiness/20261027T083653Z-5f56bb/graphs/eab1f7ee-a8e0-4bed-a0e1-2c4bff024936.jsonl'
    reference=graph.parent.parent/'matrix-1.json'
    graph_mounts=['--mount',f'type=bind,source={graph},target=/fixtures/graph.jsonl,readonly',
                  '--mount',f'type=bind,source={reference},target=/fixtures/expected-matrix.json,readonly',
                  '--mount',f'type=volume,source={VOLUME},target=/var/data']
    try:
        # Compile once on the largest profile; its artifact seal is then pinned
        # in controller receipts before export-free fresh-process reload tests.
        compiled=run_case('full-graph-8gb-compact-bootstrap',['python','-B','/probe.py','graph','--engine','compact'],extra=graph_mounts)
        seal=compiled.get('result',{}).get('artifact_sha256')
        for profile in PROFILES:
            for engine in ('legacy','compact'):
                if profile[0]=='8gb-2cpu' and engine=='compact':continue
                run_case(profile[0]+'-full-graph-'+engine,['python','-B','/probe.py','graph','--engine',engine],profile=profile,extra=graph_mounts)
            if seal:
                run_case(profile[0]+'-full-graph-artifact-restart',
                    ['python','-B','/probe.py','graph','--engine','artifact','--artifact-sha256',seal],profile=profile,extra=graph_mounts)
        # Exact-container SIGKILL with a synthetic-only persistent Linux volume.
        name='geolock-offline-crash-'+uuid4().hex[:12]
        args=['run','-d','--pull','never','--name',name,'--network','none','--read-only','--memory','2g','--cpus','1',
              '--cap-drop','ALL','--security-opt','no-new-privileges','--tmpfs','/tmp:rw,size=64m']+mounts()+[
              '--mount',f'type=volume,source={VOLUME},target=/var/data',PLANNER,'python','-B','/probe.py','hold']
        command(args)
        try:
            deadline=time.monotonic()+30
            while 'READY_TO_KILL' not in command(['logs',name]).stdout:
                if time.monotonic()>deadline:raise RuntimeError('synthetic crash checkpoint timeout')
                time.sleep(.1)
            command(['kill','--signal','KILL',name])
            with (OUT/'container-crash-state.json').open('x',encoding='utf-8') as f:
                data=json.loads(command(['inspect',name]).stdout)[0]
                json.dump(dict(state=data['State'],mounts=[dict(type=m['Type'],destination=m['Destination']) for m in data['Mounts']]),f,indent=2)
        finally:command(['rm','-f',name])
        run_case('linux-volume-crash-reopen',['python','-B','/probe.py','restore'],profile=PROFILES[1],
                 extra=['--mount',f'type=volume,source={VOLUME},target=/var/data'])
    finally:
        # Exact unique disposable volume, not user state; no live journal mount.
        command(['volume','rm',VOLUME])
    print('OFFLINE_VALIDATION_FINISHED',flush=True)


if __name__=='__main__':main()
