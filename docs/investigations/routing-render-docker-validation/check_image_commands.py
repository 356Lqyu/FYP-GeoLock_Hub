"""Test actual image CMD/PORT/SIGTERM with activation absent, network disabled."""
import json
from uuid import uuid4
import run_validation as v


def main():
    receipts=[]
    for role,image,port in [('planner',v.PLANNER,18083),('validator',v.VALIDATOR,18084)]:
        name='geolock-disabled-cmd-'+uuid4().hex[:12]
        v.command(['run','-d','--pull','never','--name',name,'--network','none','--read-only',
                   '--memory','512m','--cpus','1','--cap-drop','ALL','--security-opt','no-new-privileges',
                   '-e','PORT='+str(port),image])
        try:
            code='''
from http.client import HTTPConnection
import json,os,time,sys
port=int(sys.argv[1]);deadline=time.monotonic()+5
while True:
 try:
  c=HTTPConnection('127.0.0.1',port,timeout=1);c.request('GET','/live');r=c.getresponse();assert r.status==200;r.read();break
 except (ConnectionError,OSError):
  if time.monotonic()>deadline:raise
  time.sleep(.05)
c.request('GET','/health');r=c.getresponse();assert r.status==503
body=json.loads(r.read());assert body['status']=='DISABLED';assert os.getuid()==10001
assert any(row.split()[1]=='00000000:'+format(port,'04X') for row in open('/proc/net/tcp').readlines()[1:])
print(json.dumps(dict(uid=os.getuid(),port=port,bound_all_interfaces=True,live=200,health=r.status,status=body['status'])))
'''
            checked=json.loads(v.command(['exec',name,'python','-B','-c',code,str(port)]).stdout)
            v.command(['stop','--time','10',name])
            inspected=json.loads(v.command(['inspect',name]).stdout)[0]
            assert inspected['State']['ExitCode']==0
            assert not inspected['State']['OOMKilled']
            receipts.append(dict(role=role,image_id=inspected['Image'],cmd=inspected['Config']['Cmd'],
                                 configuration=checked,sigterm_exit_code=0,network=inspected['HostConfig']['NetworkMode']))
        finally:v.command(['rm','-f',name])
    with (v.OUT/'actual-cmd-port-sigterm.json').open('x',encoding='utf-8') as f:json.dump(receipts,f,indent=2)
    print(json.dumps(receipts))


if __name__=='__main__':main()
