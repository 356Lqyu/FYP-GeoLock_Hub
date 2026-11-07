"""Stage 3I live-state activation proposal. Filesystem only; never executes SQL.

Retains approved recovery function unchanged. Creates a review-only approval-gated
package using runtime locked snapshots, not an externally expiring readiness file.
"""
import argparse
import hashlib
import json
from pathlib import Path
import claim_recovery_final_activation_package as final

BASE=final.base
TOKEN='ca779d47-24ca-48a5-ae85-f005b598de3a'
MARKED_COMMAND=BASE.COMMAND+' -- STAGE3I_ONE_USE_'+TOKEN
CONFIRMATION='SUPERVISE_AND_PAUSE_WITHIN_300_SECONDS'
TABLES=('donation_claims','claim_leases','listings','pickup_tasks','donations',
 'hub_batches','hub_batch_members','hub_inventory','active_task_route_assignments',
 'pickup_route_stops','claim_reconciliation_cases','hub_reservations','hub_receipts',
 'coordination_config','audit_events','listing_eligibility_refresh_jobs')


def activation_template():
    sql=final.activation_template()
    sql=sql.replace('\nBEGIN;','\nBEGIN ISOLATION LEVEL READ COMMITTED;',1)
    sql=sql.replace("SET LOCAL search_path=pg_catalog,public,pg_temp;",
      "SET LOCAL search_path=pg_catalog,public,pg_temp;\nSET LOCAL TimeZone='UTC';")
    anchor="   OR auth.uid() IS NOT NULL THEN RAISE EXCEPTION 'CLEAN_POSTGRES_SESSION_REQUIRED'; END IF;"
    if sql.count(anchor)!=1:
        raise ValueError('Session guard drift')
    live="""
 -- Human approval is separate from preparation. Review-only default is FALSE.
 IF (v_manifest->>'execution_approved')::boolean IS DISTINCT FROM true
   OR v_manifest->>'operator_confirmation' IS DISTINCT FROM 'SUPERVISE_AND_PAUSE_WITHIN_300_SECONDS'
   OR v_manifest->>'activation_token' IS DISTINCT FROM 'ca779d47-24ca-48a5-ae85-f005b598de3a'
   OR current_setting('transaction_isolation')<>'read committed' THEN
   RAISE EXCEPTION 'EXPLICIT_EXECUTION_APPROVAL_AND_SUPERVISION_REQUIRED'; END IF;
 -- NOWAIT prevents waiting behind existing writers/recovery selectors. Locks are
 -- held through COMMIT; this is a short DEV maintenance transaction, not a worker.
 LOCK TABLE __TABLES__ IN EXCLUSIVE MODE NOWAIT;
 -- Freeze cron configuration too: no competing activation or extra schedule.
 LOCK TABLE cron.job IN SHARE ROW EXCLUSIVE MODE NOWAIT;
 -- This is a REAL fresh database read under locks, not a timestamp-only refresh.
 __CONTEXT__ SELECT * INTO v FROM evidence;
 -- Preserve the reviewed target's audit history as well as the outside snapshot.
 IF length(coalesce(v_manifest->>'target_audit_md5',''))<>32
   OR md5(coalesce(v.audits,'[]'::jsonb)::text) IS DISTINCT FROM v_manifest->>'target_audit_md5' THEN
   RAISE EXCEPTION 'TARGET_AUDIT_HISTORY_CHANGED'; END IF;
 v_manifest:=v_manifest||jsonb_build_object('baseline_at',clock_timestamp());
 -- Original freshness/operator/source/candidate/snapshot guards follow unchanged.
""".replace('__TABLES__',','.join('public.'+x for x in TABLES)).replace(
 '__CONTEXT__',BASE.CONTEXT.replace(BASE.MARKER,'v_manifest'))
    sql=sql.replace(anchor,anchor+live,1)
    sql=sql.replace('v_pause_deadline timestamptz;',
      "v_pause_deadline timestamptz; v_worker_command constant text := '"+MARKED_COMMAND.replace("'","''")+"';")
    sql=sql.replace("OR EXISTS(SELECT 1 FROM public.hub_inventory WHERE donation_id=v.did)",
      "OR EXISTS(SELECT 1 FROM public.hub_inventory WHERE donation_id=v.did)\n"
      "   OR EXISTS(SELECT 1 FROM public.hub_reservations WHERE donation_id=v.did)\n"
      "   OR EXISTS(SELECT 1 FROM public.hub_receipts WHERE donation_id=v.did)")
    sql=sql.replace(' PERFORM cron.alter_job(3,active := true);',
      ' PERFORM cron.alter_job(3,command := v_worker_command,active := true);',1)
    original="AND command='"+BASE.COMMAND.replace("'","''")+"'"
    if sql.count(original)!=2:
        raise ValueError('Cron pre/post command guard drift')
    at=sql.rfind(original)
    sql=sql[:at]+sql[at:].replace(original,'AND command=v_worker_command',1)
    # The original command remains a strict PREcondition. The marker is retained
    # after pause, so replay rejects even if activation was paused before a tick.
    check="""
 IF NOT EXISTS(SELECT 1 FROM pg_proc p
   WHERE p.oid='public.recover_expired_claims(integer)'::regprocedure
     AND md5(replace(p.prosrc,E'\\r\\n',E'\\n'))='5ff6d8719db9681aae6f444b89dfbaee'
     AND p.proowner='postgres'::regrole AND p.prosecdef
     AND p.proconfig=ARRAY['search_path=pg_catalog, public, extensions, pg_temp']
     AND p.proacl='{postgres=X/postgres,service_role=X/postgres}'::aclitem[]
     AND pg_get_function_arguments(p.oid)='p_limit integer DEFAULT 100'
     AND pg_get_function_result(p.oid)='integer') THEN
   RAISE EXCEPTION 'SOURCE_OR_SECURITY_CHANGED_DURING_ACTIVATION'; END IF;
"""
    sql=sql.replace(" IF clock_timestamp()>=v_pause_deadline",check+" IF clock_timestamp()>=v_pause_deadline",1)
    return ('-- PROPOSAL ONLY. Separate explicit execution approval required.\n'
      '-- All live checks run inside the transaction. No external three-minute deadline.\n'+sql)


def artifacts(manifest):
    result=final.artifacts(manifest)
    result['03_activate.sql']=BASE.render(activation_template(),manifest)
    return result


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--manifest',type=Path,required=True)
    p.add_argument('--output-dir',type=Path,required=True)
    a=p.parse_args()
    m=json.loads(a.manifest.read_text(encoding='utf-8'))
    a.output_dir.mkdir(parents=True,exist_ok=False)
    sums=[]
    for name,sql in artifacts(m).items():
        data=sql.encode()
        (a.output_dir/name).write_bytes(data)
        sums.append(hashlib.sha256(data).hexdigest().upper()+'  '+name)
    (a.output_dir/'SHA256SUMS.txt').write_text('\n'.join(sums)+'\n',encoding='utf-8',newline='\n')
