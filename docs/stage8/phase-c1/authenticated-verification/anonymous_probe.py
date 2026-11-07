"""Batch A: only anonymous read-only list RPC, never acquire user sessions."""
import json
import os
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, build_opener

from rpc_harness import BASE, NoRedirect, PROJECT, demand


def main():
    key=os.environ['C1_PUBLIC_KEY']
    results=[]
    for mode in ('anonymous','invalid_bearer'):
        headers={'apikey':key,'Content-Type':'application/json'}
        if mode=='invalid_bearer': headers['Authorization']='Bearer invalid.c1.test'
        request=Request(BASE+'/rest/v1/rpc/list_my_vehicles',data=b'{}',headers=headers,method='POST')
        try:
            with build_opener(NoRedirect()).open(request,timeout=30) as response:
                response.read()
                raise AssertionError('Anonymous list unexpectedly succeeded')
        except HTTPError as error:
            body=json.loads(error.read())
            demand(error.code in (401,403),'Unexpected transport result; cannot prove denial')
            code=body.get('code')
            if mode=='anonymous':
                demand(code=='42501','Anonymous denial did not reach PostgreSQL permission check')
            results.append(dict(mode=mode,status=error.code,error_code=code,result='PASS'))
    output=dict(project_ref=PROJECT,evidence_kind='LIVE_ANONYMOUS_READ_ONLY',
                group='F16',coverage='PARTIAL: list RPC only; no expired token or mutation RPC attempted',results=results)
    Path(__file__).with_name('batch-a-anonymous-results.json').write_text(json.dumps(output,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(output,indent=2))


if __name__=='__main__': main()
