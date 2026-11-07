"""Offline/local-only regression. No DEV DSN, credentials, backup or restore.

Runs the pure PowerShell SQL builder in both shells and executes generated SELECTs
on a NEW disposable loopback PostgreSQL 17 cluster with tiny local policy fixtures.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent


def run(args, **kw):
    kw.setdefault('env', {k:v for k,v in os.environ.items() if not k.upper().startswith('PG')})
    result = subprocess.run([str(a) for a in args], capture_output=True, text=True, **kw)
    if result.returncode:
        raise RuntimeError(result.stdout+'\n'+result.stderr)
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime', type=Path, required=True)
    args = parser.parse_args()
    runtime = args.runtime.resolve()
    if not runtime.name.startswith('geolock-spatial-runtime-'):
        raise ValueError('Only existing private local runtime allowed')
    pg = runtime/'pgsql/bin'
    if not (pg/'initdb.exe').exists():
        pg = runtime/'bin'
    if '17.' not in run([pg/'postgres.exe','--version']):
        raise ValueError('PostgreSQL 17 required')
    target = Path(tempfile.mkdtemp(prefix='geolock-backup-quoting-'))
    outputs = []
    for i, shell in enumerate(('C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe', shutil.which('pwsh'))):
        directory = target/str(i); directory.mkdir()
        # Run reviewed test text as a command without changing execution policy.
        quote = lambda p: "'"+str(p).replace("'", "''")+"'"
        command = '& ([scriptblock]::Create([IO.File]::ReadAllText('+quote(HERE/'test_backup_inventory.ps1')+'))) -OutputDirectory '+quote(directory)+' -ScriptDirectory '+quote(HERE)
        env = os.environ.copy()
        if i == 0:
            env['PSModulePath'] = 'C:/Windows/System32/WindowsPowerShell/v1.0/Modules;C:/Program Files/WindowsPowerShell/Modules'
        outputs.append(json.loads(run([shell,'-NoProfile','-Command',command],env=env)))
    assert (target/'0/inventory with spaces.sql').read_bytes() == (target/'1/inventory with spaces.sql').read_bytes()
    with socket.socket() as s:
        s.bind(('127.0.0.1',0)); port = s.getsockname()[1]
    data = target/'cluster'
    run([pg/'initdb.exe','-D',data,'-U','postgres','-A','trust','--encoding=UTF8','--no-locale'])
    started = False
    try:
        # PostgreSQL descendants must not keep a captured stdout pipe open.
        with (target/'control.log').open('w') as control:
            subprocess.run([str(pg/'pg_ctl.exe'),'-D',str(data),'-l',str(target/'server.log'),'-o',f'-h 127.0.0.1 -p {port} -c shared_buffers=16MB','-w','start'],
                stdout=control,stderr=subprocess.STDOUT,check=True,timeout=60)
        started = True
        client = [pg/'psql.exe','-X','-w','-h','127.0.0.1','-p',str(port),'-U','postgres','-d','postgres','-qAt','-v','ON_ERROR_STOP=1']
        body = (HERE/'routing-initialization/policy.proposed.json').read_text()
        fixture = target/'fixture.sql'
        fixture.write_text("CREATE SCHEMA routing_private; CREATE TABLE routing_private.graphs(graph_id uuid); "
            "CREATE TABLE routing_private.policies(policy_id uuid,request_id uuid,body jsonb,digest text,created_at timestamptz DEFAULT now()); "
            "INSERT INTO routing_private.policies(policy_id,request_id,body,digest) SELECT "
            "'80db858b-93e8-4a0a-94e2-dbe14940f0a1','0b8db479-20c8-4595-9d41-d831650cba93',b,"
            "encode(sha256(convert_to(b::text,'UTF8')),'hex') FROM (SELECT $body$"+body+"$body$::jsonb b) q;",encoding='utf-8')
        run(client+['-f',fixture])
        for i in ('0','1'):
            evidence = json.loads(run(client+['-f',target/i/'inventory with spaces.sql']))
            assert evidence['read_only']=='on' and evidence['graph_count']==0
            policy = evidence['routing_policies'][0]
            assert policy['body']==json.loads(body) and policy['body_matches'] and policy['digest_matches']
            baseline = json.loads(run(client+['-f',target/i/'baseline.sql']))
            assert baseline['read_only']=='on' and 'routing_policies' not in baseline
        # Prove the actual comparison detects a differing policy, on LOCAL data only.
        negative = target/'negative.sql'
        negative.write_text("UPDATE routing_private.policies SET body=jsonb_set(body,'{mandatory}','true');",encoding='utf-8')
        run(client+['-f',negative])
        evidence = json.loads(run(client+['-f',target/'0/inventory with spaces.sql']))
        assert not evidence['routing_policies'][0]['body_matches']
        print(json.dumps({'status':'PASS','shell_checks':outputs,'postgresql17_generated_sql':'PASS in both modes/shells',
            'changed_policy_rejected':True,'dev_connections':0,'evidence':str(target)},indent=2))
    finally:
        if started:
            run([pg/'pg_ctl.exe','-D',data,'-m','fast','-w','stop'])
        # Preserve only this test-owned temporary evidence. No destructive cleanup.


if __name__ == '__main__':
    main()
