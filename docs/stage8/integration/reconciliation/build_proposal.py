"""Generate NEW review artifacts only. Never imports a database client."""
from pathlib import Path
import hashlib
import json
import re

ROOT = Path(__file__).resolve().parents[4]
HERE = Path(__file__).resolve().parent
PAT = re.compile(r'CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION\s+([\w.]+)\s*\(.*?\bAS\s+(\$[\w]*\$)(.*?)\2\s*;', re.I|re.S)


def function(path, name):
    return next(m for m in PAT.finditer(path.read_text()) if m.group(1).lower()==name)


def md5(text):
    return hashlib.md5(text.replace('\r\n','\n').encode()).hexdigest()


def render():
    migration = ROOT/'supabase/migrations/20261027_persisted_donation_lifecycle.sql'
    recovery = ROOT/'supabase/migrations/20261030_fix_claim_recovery_unresolved_reconciliation.sql'
    original003 = ROOT/'docs/stage8/integration/003_pickup_enforcement_proposal.sql'
    original = function(migration,'public.submit_claim_reconciliation')
    body = original.group(0)
    # Three explicit hooks; every original evidence/audit/manual-review branch
    # remains verbatim. Retry replay additionally works after case resolution.
    insertion = '''  -- STAGE8_RECONCILIATION_LOCK_AND_REPLAY_BEGIN
  perform routing_private.lock_reconciliation_scope(p_claim);
  select e.response into v_result from public.claim_reconciliation_evidence e
  join public.claim_reconciliation_cases rc using(case_id)
  where e.request_id=p_request and e.actor_user_id=v_actor
    and e.handover_confirmed is not distinct from p_handover_confirmed
    and rc.claim_id=p_claim;
  if v_result is not null then return v_result; end if;
  -- STAGE8_RECONCILIATION_LOCK_AND_REPLAY_END
'''
    anchor = '  -- Same lock prefix as start/complete/recovery.\n'
    assert body.count(anchor)==1
    body = body.replace(anchor,insertion+anchor)
    anchor2 = "      update public.pickup_tasks set task_status='COLLECTED' where task_id=v_t.task_id;"
    assert body.count(anchor2)==1
    body = body.replace(anchor2,'      perform routing_private.permit_reconciled_collection(p_claim);\n'+anchor2)
    anchor3 = "      v_result:=jsonb_build_object('outcome','SUCCESS','case_id',v_case.case_id,\n        'claim_status','COMPLETED','donation_status','COLLECTED','reason_code','HANDOVER_CONFIRMED');"
    assert body.count(anchor3)==1
    body = body.replace(anchor3,'      perform routing_private.finish_reconciled_collection(p_claim);\n'+anchor3)
    prefix = (HERE/'compatibility_prefix.sql').read_text()
    pins = dict(reconciliation_md5=md5(original.group(3)),
                revised_reconciliation_md5=md5(next(PAT.finditer(body)).group(3)),
                recovery_md5=md5(function(recovery,'public.recover_expired_claims').group(3)),
                guard_md5=md5(function(original003,'routing_private.task_guard').group(3)))
    for name,key in [('RECON','reconciliation_md5'),('RECOVERY','recovery_md5'),('GUARD','guard_md5')]:
        prefix = prefix.replace('__'+name+'_MD5__',pins[key])
    standalone = prefix+'\n-- Rebased original RPC, with only the documented hooks.\n'+body+'\nCOMMIT;\n'
    # One transaction for first installation: no interval with a global guard
    # installed but the legitimate reconciliation path still incompatible.
    existing = original003.read_text()
    assert existing.count('\nBEGIN;')==1 and existing.rstrip().endswith('COMMIT;')
    combined = existing.rsplit('COMMIT;',1)[0]+'\n-- Atomic reconciliation compatibility extension.\n'+standalone.split('BEGIN;',1)[1]
    return standalone,combined,pins,insertion,original.group(0),body


def build():
    standalone,combined,pins,*_ = render()
    outputs = {'003_reconciliation_compatibility_proposal.sql':standalone,
               '003_with_reconciliation_proposal.sql':combined}
    for name,text in outputs.items():
        (HERE/name).write_text(text,encoding='utf-8',newline='\n')
    pins.update(status='REVIEW_ONLY_NOT_AUTHORIZED',project_ref='rcgyuwiidqvrgbxswhqj',
        source_pins_are='Repository baselines; require actual DEV comparison before approval',
        files={name:hashlib.sha256((HERE/name).read_bytes()).hexdigest() for name in outputs})
    (HERE/'proposal-manifest.json').write_text(json.dumps(pins,indent=2)+'\n')


if __name__=='__main__':
    build()
