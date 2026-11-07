"""Separate trusted validator process. No solver execution or planner login."""
from datetime import timedelta
from pathlib import Path
import hashlib
from urllib.parse import urlparse

from ..validator import validate_work_item
from ..integration.worker import timestamp
from .errors import check
from .transport import JsonHttp, uuid


def validator_build():
    root=Path(__file__).resolve().parents[1]
    h=hashlib.sha256()
    for name in ('contract.py','phase_b/validation.py','integration/worker.py'):
        h.update((root/name).read_bytes())
    return 'geolock-independent-validator:'+h.hexdigest()


class Validator:
    def __init__(self, rpc, *, max_age_seconds=300):
        self.rpc, self.max_age = rpc, max_age_seconds

    def validate(self, candidate_id, snapshot_id, ngo_id):
        candidate_id,snapshot_id,ngo_id = uuid(candidate_id),uuid(snapshot_id),uuid(ngo_id)
        work=self.rpc.call('read_routing_work_item',candidate_id)
        check(work is not None and work['candidate']['candidate_id']==candidate_id
              and work['snapshot']['snapshot_id']==snapshot_id and work['snapshot']['ngo_id']==ngo_id,'CANDIDATE_BINDING_MISMATCH',403)
        age=self.rpc.now()-timestamp(work['snapshot']['cutoff'])
        check(timedelta(0)<=age<=timedelta(seconds=self.max_age),'SNAPSHOT_STALE',409)
        report=validate_work_item(work,validator_build=validator_build())
        self.rpc.call('attest_routing_candidate',candidate_id,work['candidate']['digest'],report)
        return {'candidate_id':candidate_id,'attested_digest':work['candidate']['digest'],'validator_build':report['validator_build']}


class RemoteValidator:
    def __init__(self, base, token, http=None):
        value=urlparse(base)
        check(bool(value.hostname) and (value.scheme=='https' or (value.scheme=='http' and value.hostname in ('127.0.0.1','localhost','::1'))),'VALIDATOR_TLS_OR_LOOPBACK_REQUIRED',503)
        check(not value.username and not value.password and not value.query and not value.fragment and value.path in ('','/'),'INVALID_VALIDATOR_URL',503)
        check(len(token)>=32,'VALIDATOR_SECRET_REQUIRED',503)
        self._base,self._token,self._http=base.rstrip('/'),token,http or JsonHttp()

    def validate(self,candidate_id,snapshot_id,ngo_id):
        return self._http.request(self._base+'/v1/validate',token=self._token,
             body=dict(candidate_id=candidate_id,snapshot_id=snapshot_id,ngo_id=ngo_id),timeout=120)
