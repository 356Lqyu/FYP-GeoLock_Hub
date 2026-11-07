"""Local-only modeled capacity runs; no cloud/DB credentials or live journals."""
import json
import os
from pathlib import Path
import subprocess
import time
from uuid import uuid4

ROOT=Path(__file__).resolve().parents[3];SOURCE=Path(__file__).resolve().parent;OUT=SOURCE/'run2'
OLD=ROOT/'docs/investigations/routing-render-docker-validation'
DOCKER=Path(os.environ['LOCALAPPDATA'])/'Programs/DockerDesktop/resources/bin/docker.exe'
PREFIX=[str(DOCKER),'--context','desktop-linux'];ENV=dict(os.environ,PATH=str(DOCKER.parent)+os.pathsep+os.environ['PATH'])
PLANNER='geolock-planner:validation-fixed-20261107';VALIDATOR='geolock-validator:validation-fixed-20261107'
PROFILES=[('512mb-0.1cpu','512m','.1'),('2gb-1cpu','2g','1'),('4gb-2cpu','4g','2'),('8gb-2cpu','8g','2')]
VOLUME='geolock-workload-offline-'+uuid4().hex[:12];RECEIPTS=[]
GRAPH=ROOT/'results/worker-readiness/20261027T083653Z-5f56bb/graphs/eab1f7ee-a8e0-4bed-a0e1-2c4bff024936.jsonl'


def docker(args):return subprocess.run(PREFIX+args,env=ENV,capture_output=True,text=True,timeout=60,check=True)
def run(label,command,*,profile=PROFILES[-1],image=PLANNER,mounts=(),timeout=300):
    name='geolock-workload-'+uuid4().hex[:12];key,memory,cpu=profile
    args=['run','--pull','never','--name',name,'--network','none','--read-only','--memory',memory,
          '--memory-swap',memory,'--cpus',cpu,'--pids-limit','128','--cap-drop','ALL','--security-opt','no-new-privileges',
          '--tmpfs','/tmp:rw,nosuid,size=128m','--mount',f'type=bind,source={SOURCE / "workload_probe.py"},target=/workload.py,readonly']+list(mounts)+[image]+list(command)
    started=time.monotonic();timed=False
    with (OUT/(label+'.log')).open('x',encoding='utf-8') as log:
        process=subprocess.Popen(PREFIX+args,env=ENV,stdout=log,stderr=subprocess.STDOUT)
        try:code=process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed=True;docker(['kill',name]);code=process.wait(timeout=30)
    inspection=json.loads(docker(['inspect',name]).stdout)[0]
    result=dict(label=label,profile=key,image_id=inspection['Image'],exit_code=code,
                oom=inspection['State']['OOMKilled'],external_timeout=timed,wall_seconds=time.monotonic()-started,
                limits={k:inspection['HostConfig'][k] for k in ('Memory','MemorySwap','NanoCpus','NetworkMode','ReadonlyRootfs')})
    if code==0:
        for line in reversed((OUT/(label+'.log')).read_text().splitlines()):
            try:result['result']=json.loads(line);break
            except json.JSONDecodeError:pass
    RECEIPTS.append(result);(OUT/'receipts.json').write_text(json.dumps(RECEIPTS,indent=2)+'\n',encoding='utf-8')
    docker(['rm',name]);print(json.dumps(dict(label=label,exit_code=code,oom=result['oom'],timeout=timed)),flush=True)
    return result


def main():
    OUT.mkdir(exist_ok=False)
    version=json.loads(docker(['version','--format','{{json .}}']).stdout);assert version['Server']['Os']=='linux'
    for image in (PLANNER,VALIDATOR):
        config=json.loads(docker(['image','inspect',image]).stdout)[0];assert config['Config']['User']=='10001:10001'
    volume=['--mount',f'type=volume,source={VOLUME},target=/var/data']
    graph_mounts=['--mount',f'type=bind,source={GRAPH},target=/fixtures/graph.jsonl,readonly']
    try:
        compile_mounts=volume+graph_mounts+['--mount',f'type=bind,source={GRAPH.parent.parent / "matrix-1.json"},target=/fixtures/expected-matrix.json,readonly',
            '--mount',f'type=bind,source={OLD / "container_probe.py"},target=/compile.py,readonly']
        compiled=run('compile-sealed-full-graph',['python','-B','/compile.py','graph','--engine','compact'],mounts=compile_mounts)
        assert compiled['exit_code']==0 and compiled['result']['artifact_sha256']=='7958972d08ea412c7515a47521640588528daa206440a198db2ad47507b8bd01'
        preparation=volume+graph_mounts+['--mount',f'type=bind,source={OLD / "frozen-v33-sample.json"},target=/fixtures/frozen.json,readonly',
            '--mount',f'type=bind,source={ROOT / "experiments/repro_inputs/v33/road_nodes.csv"},target=/fixtures/road_nodes.csv,readonly',
            '--mount',f'type=bind,source={OUT},target=/out']
        prepared=run('prepare-and-parity-available-nodes',['python','-B','/workload.py','prepare'],mounts=preparation,timeout=600)
        assert prepared['exit_code']==0
        planner_mounts=volume+graph_mounts+['--mount',f'type=bind,source={OUT / "cases"},target=/fixtures/cases,readonly',
            '--mount',f'type=bind,source={OUT},target=/out']
        for case in ('small','typical-provisional','large-provisional','source-boundary-stress'):
            # Largest profile first, to preserve a reference plan for independent
            # validator measurements even if a smaller planner is OOM-killed.
            for profile in [PROFILES[-1]]+PROFILES[:-1]:
                label=case+'-'+profile[0]+'-planner'
                run(label,['python','-B','/workload.py','planner','--case',case,'--label',label],profile=profile,mounts=planner_mounts)
            reference=OUT/(case+'-'+PROFILES[-1][0]+'-planner-plans.json')
            for profile in PROFILES:
                candidate=OUT/(case+'-'+profile[0]+'-planner-plans.json')
                plans=candidate if candidate.exists() else reference
                if not plans.exists():continue
                result=run(case+'-'+profile[0]+'-validator',['python','-B','/workload.py','validator','--plans','/fixtures/plans.json'],
                    profile=profile,image=VALIDATOR,mounts=['--mount',f'type=bind,source={plans},target=/fixtures/plans.json,readonly'])
                result['plan_source_file']=plans.name
                (OUT/'receipts.json').write_text(json.dumps(RECEIPTS,indent=2)+'\n',encoding='utf-8')
    finally:docker(['volume','rm',VOLUME])
    print('ALL_OFFLINE_WORKLOAD_CASES_FINISHED',flush=True)


if __name__=='__main__':main()
