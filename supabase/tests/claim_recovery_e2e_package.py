"""Generate/render Stage 3I review-only SQL; filesystem only, no DB connections.

--write-templates creates canonical files. --manifest/--output-dir renders copies
for a future human review, never executes them. Empty manifests fail activation.
"""
from pathlib import Path
import argparse
import hashlib
import json
import re

ROOT=Path(__file__).resolve().parent
DEST=ROOT/'review-only/stage3i'
MARKER="/* STAGE3I_MANIFEST */ '{}'::jsonb"
FINGERPRINT='5ff6d8719db9681aae6f444b89dfbaee'
COMMAND="set lock_timeout = '5s'; set statement_timeout = '50s'; select public.recover_expired_claims(1);"
RUNIDS=[3104,3107,3110,3113,3116,3119,3122,3125,3128,3131,3134,3137]

TABLES={
 'donations':'x.donation_id IS DISTINCT FROM e.did',
 'listings':'x.listing_id IS DISTINCT FROM e.lid',
 'donation_claims':'x.claim_id IS DISTINCT FROM e.cid',
 'claim_leases':'x.lease_id IS DISTINCT FROM e.leid',
 'pickup_tasks':'x.task_id IS DISTINCT FROM e.tid',
 'hub_batches':'true','hub_batch_members':'true','hub_inventory':'true',
 'active_task_route_assignments':'true','pickup_route_stops':'true',
 'claim_reconciliation_cases':'true',
 'audit_events':"x.claim_id IS DISTINCT FROM e.cid AND x.entity_id IS DISTINCT FROM e.cid AND x.entity_id IS DISTINCT FROM e.did AND x.entity_id IS DISTINCT FROM e.lid",
 'listing_eligibility_refresh_jobs':'x.listing_id IS DISTINCT FROM e.lid',
}
SNAPSHOT="jsonb_build_object("+','.join(
 f"'{table}',(SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb) FROM public.{table} x WHERE {where})"
 for table,where in TABLES.items())+")"
CONTEXT=f"""WITH p AS (SELECT {MARKER} AS j),
 e AS (SELECT j,(j->>'claim_id')::uuid AS cid,(j->>'lease_id')::uuid AS leid,
   (j->>'listing_id')::uuid AS lid,(j->>'donation_id')::uuid AS did,
   (j->>'task_id')::uuid AS tid FROM p),
 outside_snapshot AS (SELECT {SNAPSHOT} AS data FROM e),
 target AS (SELECT e.*,to_jsonb(c) AS claim,to_jsonb(le) AS lease,to_jsonb(t) AS task,
   to_jsonb(l) AS listing,to_jsonb(d) AS donation,
   c.claim_status,le.lease_status,le.issued_at,le.expires_at,t.task_status,
   l.listing_status,l.listing_version,l.eligibility_generation,l.listing_expires_at,
   d.donation_status,d.collection_path,d.title,c.ngo_user_id,d.donor_user_id,
   (c.claim_id=e.cid AND le.lease_id=e.leid AND t.task_id=e.tid
     AND c.listing_id=e.lid AND t.listing_id=e.lid
     AND l.donation_id=e.did AND l.source_type='DIRECT_DONATION'
     AND l.batch_id IS NULL) AS identities_match
 FROM e LEFT JOIN public.donation_claims c ON c.claim_id=e.cid
 LEFT JOIN public.claim_leases le ON le.claim_id=c.claim_id
 LEFT JOIN public.pickup_tasks t ON t.claim_id=c.claim_id
 LEFT JOIN public.listings l ON l.listing_id=c.listing_id
 LEFT JOIN public.donations d ON d.donation_id=l.donation_id),
 evidence AS (SELECT t.*,md5(s.data::text) AS other_business_md5,
   (SELECT jsonb_agg(to_jsonb(a) ORDER BY a.occurred_at,a.event_id)
     FROM public.audit_events a WHERE a.claim_id=t.cid OR a.entity_id IN(t.cid,t.lid,t.did)) AS audits,
   (SELECT jsonb_agg(to_jsonb(q) ORDER BY q.eligibility_generation)
     FROM public.listing_eligibility_refresh_jobs q WHERE q.listing_id=t.lid) AS refresh
 FROM target t CROSS JOIN outside_snapshot s)
"""

PREFLIGHT=CONTEXT+"""SELECT statement_timestamp() AS observed_at,current_database(),current_user,
 current_setting('transaction_read_only') AS read_only,current_setting('TimeZone') AS timezone,
 claim,lease,task,listing,donation,audits,refresh,other_business_md5,
 coalesce(identities_match AND claim_status='ACTIVE' AND lease_status='ACTIVE'
   AND task_status='CONFIRMED' AND listing_status='CLAIMED' AND donation_status='CLAIMED'
   AND collection_path='DIRECT_PICKUP' AND listing_expires_at IS NULL
   AND expires_at<=statement_timestamp(),false) AS target_is_overdue,
 (SELECT claim_lease_minutes FROM public.coordination_config WHERE singleton) AS configured_lease_minutes,
 (SELECT count(*) FROM public.donation_claims WHERE claim_status IN('ACTIVE','RECONCILIATION_REQUIRED')) AS nonterminal_claims,
 (SELECT jsonb_agg(jsonb_build_object('claim',c.claim_id,'lease',le.lease_id,'expires_at',le.expires_at)
   ORDER BY le.expires_at,c.claim_id) FROM public.donation_claims c JOIN public.claim_leases le USING(claim_id)
   WHERE c.claim_status='ACTIVE' AND le.lease_status='ACTIVE' AND le.expires_at<=statement_timestamp()) AS all_overdue,
 (SELECT jsonb_agg(to_jsonb(rc)) FROM public.claim_reconciliation_cases rc
   WHERE rc.case_status IN('OPEN','MANUAL_REVIEW')) AS unresolved_cases,
 (SELECT jsonb_agg(to_jsonb(a)) FROM public.active_task_route_assignments a WHERE a.task_id=tid) AS assignments,
 (SELECT jsonb_agg(to_jsonb(s)) FROM public.pickup_route_stops s WHERE s.task_id=tid) AS stops,
 (SELECT jsonb_agg(to_jsonb(cj) ORDER BY jobid) FROM cron.job cj WHERE jobid IN(1,2,3)) AS cron,
 (SELECT jsonb_agg(to_jsonb(r) ORDER BY runid) FROM cron.job_run_details r WHERE jobid=3) AS job3_history,
 (SELECT jsonb_agg(to_jsonb(r)) FROM cron.job_run_details r WHERE jobid IN(1,2,3) AND end_time IS NULL) AS unfinished,
 (SELECT md5(replace(prosrc,E'\\r\\n',E'\\n')) FROM pg_proc
   WHERE oid='public.recover_expired_claims(integer)'::regprocedure) AS recovery_body_md5,
 j || jsonb_build_object('expected_version',listing_version,'expected_generation',eligibility_generation,
   'expires_at',expires_at,'other_business_md5',other_business_md5,
   'timezone',current_setting('TimeZone'),'baseline_at',statement_timestamp()) AS proposed_manifest
FROM evidence;
"""

ACTIVATE="""-- REVIEW ONLY: MUTATES JOB 3 IF EXECUTED AFTER SEPARATE APPROVAL.
-- DEV rcgyuwiidqvrgbxswhqj only. Not a migration. No fixture/recovery invocation.
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='10s';
SET LOCAL search_path=pg_catalog,public,pg_temp;
DO $stage3i$
DECLARE j jsonb := /* STAGE3I_MANIFEST */ '{}'::jsonb;
 v record; v_jobs jsonb;
BEGIN
 IF current_database()<>'postgres' OR current_user<>'postgres' OR session_user<>'postgres'
   OR auth.uid() IS NOT NULL THEN RAISE EXCEPTION 'CLEAN_POSTGRES_SESSION_REQUIRED'; END IF;
 IF coalesce(j->>'approval_ref','')='' OR coalesce(j->>'operator','')=''
   OR (j->>'maintenance_confirmed')::boolean IS DISTINCT FROM true
   OR NOT (j ?& ARRAY['claim_id','lease_id','listing_id','donation_id','task_id',
     'donor_user_id','ngo_user_id','fixture_title','expected_version','expected_generation',
     'expires_at','other_business_md5','timezone','baseline_at','stop_at'])
   OR j->>'other_business_md5' IS NULL OR length(j->>'other_business_md5')<>32
   OR (j->>'stop_at')::timestamptz IS NULL
   OR (j->>'stop_at')::timestamptz<=clock_timestamp()
   OR (j->>'stop_at')::timestamptz>clock_timestamp()+interval '5 minutes'
   OR (j->>'baseline_at')::timestamptz IS NULL
   OR (j->>'baseline_at')::timestamptz<clock_timestamp()-interval '3 minutes'
   OR (j->>'baseline_at')::timestamptz>clock_timestamp()
   OR j->>'timezone' IS DISTINCT FROM current_setting('TimeZone') THEN
   RAISE EXCEPTION 'REVIEWED_FRESH_MANIFEST_AND_PRESENT_OPERATOR_REQUIRED'; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_proc p
   WHERE p.oid='public.recover_expired_claims(integer)'::regprocedure
     AND md5(replace(p.prosrc,E'\\r\\n',E'\\n'))='5ff6d8719db9681aae6f444b89dfbaee'
     AND p.proowner='postgres'::regrole AND p.prosecdef
     AND p.proconfig=ARRAY['search_path=pg_catalog, public, extensions, pg_temp']
     AND p.proacl='{postgres=X/postgres,service_role=X/postgres}'::aclitem[]
     AND pg_get_function_arguments(p.oid)='p_limit integer DEFAULT 100'
     AND pg_get_function_result(p.oid)='integer') THEN
   RAISE EXCEPTION 'SOURCE_OR_SECURITY_DRIFT'; END IF;
 IF NOT EXISTS(SELECT 1 FROM cron.job WHERE jobid=3 AND NOT active
     AND jobname='geolock-expired-claim-recovery' AND username='postgres'
     AND database=current_database() AND schedule='* * * * *'
     AND command='set lock_timeout = ''5s''; set statement_timeout = ''50s''; select public.recover_expired_claims(1);')
   OR (SELECT count(*) FROM cron.job WHERE command ~* '\\mrecover_expired_claims\\M')<>1
   OR (SELECT array_agg(runid ORDER BY runid) FROM cron.job_run_details WHERE jobid=3)
     IS DISTINCT FROM ARRAY[3104,3107,3110,3113,3116,3119,3122,3125,3128,3131,3134,3137]::bigint[]
   OR EXISTS(SELECT 1 FROM cron.job_run_details WHERE jobid=3 AND (status<>'succeeded' OR end_time IS NULL))
   OR (SELECT count(*) FROM cron.job WHERE jobid IN(1,2) AND active)<>2 THEN
   RAISE EXCEPTION 'POST_CANARY_CRON_BASELINE_DRIFT'; END IF;
 IF EXISTS(SELECT 1 FROM cron.job_run_details WHERE jobid IN(1,2,3) AND end_time IS NULL)
   OR EXISTS(SELECT 1 FROM cron.job_run_details WHERE jobid IN(1,2)
     AND start_time>=statement_timestamp()-interval '10 minutes' AND status<>'succeeded')
   OR (SELECT count(DISTINCT jobid) FROM cron.job_run_details WHERE jobid IN(1,2)
     AND status='succeeded' AND end_time>=statement_timestamp()-interval '3 minutes')<>2
   OR EXISTS(SELECT 1 FROM pg_stat_activity WHERE pid<>pg_backend_pid()
     AND backend_type='client backend' AND xact_start IS NOT NULL) THEN
   RAISE EXCEPTION 'WORKER_OR_CONCURRENCY_REVIEW_REQUIRED'; END IF;
 __CONTEXT__ SELECT * INTO v FROM evidence;
 IF NOT coalesce(v.identities_match AND v.claim_status='ACTIVE' AND v.lease_status='ACTIVE'
   AND v.task_status='CONFIRMED' AND v.listing_status='CLAIMED' AND v.donation_status='CLAIMED'
   AND v.collection_path='DIRECT_PICKUP' AND v.listing_expires_at IS NULL
   AND v.expires_at<=clock_timestamp()
   AND v.expires_at=(j->>'expires_at')::timestamptz
   AND abs(extract(epoch FROM(v.expires_at-v.issued_at))-21600)<1
   AND v.listing_version=(j->>'expected_version')::bigint
   AND v.eligibility_generation=(j->>'expected_generation')::bigint
   AND v.donor_user_id=(j->>'donor_user_id')::uuid AND v.ngo_user_id=(j->>'ngo_user_id')::uuid
   AND v.title=j->>'fixture_title' AND v.title LIKE 'STAGE3I-E2E-%'
   AND v.other_business_md5=j->>'other_business_md5',false) THEN
   RAISE EXCEPTION 'TARGET_OR_SNAPSHOT_CHANGED'; END IF;
 IF (SELECT claim_lease_minutes FROM public.coordination_config WHERE singleton) IS DISTINCT FROM 360
   OR (SELECT count(*) FROM public.donation_claims WHERE claim_status IN('ACTIVE','RECONCILIATION_REQUIRED'))<>1
   OR (SELECT count(*) FROM public.claim_leases WHERE lease_status IN('ACTIVE','RECONCILIATION_REQUIRED'))<>1
   OR EXISTS(SELECT 1 FROM public.claim_reconciliation_cases WHERE case_status IN('OPEN','MANUAL_REVIEW'))
   OR EXISTS(SELECT 1 FROM public.active_task_route_assignments WHERE task_id=v.tid)
   OR EXISTS(SELECT 1 FROM public.pickup_route_stops WHERE task_id=v.tid)
   OR EXISTS(SELECT 1 FROM public.hub_inventory WHERE donation_id=v.did)
   OR EXISTS(SELECT 1 FROM public.hub_batch_members WHERE donation_id=v.did)
   OR EXISTS(SELECT 1 FROM public.audit_events WHERE claim_id=v.cid AND event_type='LEASE_RECOVERY') THEN
   RAISE EXCEPTION 'SOLE_SAFE_CANDIDATE_REQUIRED'; END IF;
 SELECT jsonb_agg(to_jsonb(x) ORDER BY jobid) INTO v_jobs FROM cron.job x WHERE jobid IN(1,2);
 PERFORM cron.alter_job(3,active := true);
 IF NOT EXISTS(SELECT 1 FROM cron.job WHERE jobid=3 AND active
     AND command='set lock_timeout = ''5s''; set statement_timeout = ''50s''; select public.recover_expired_claims(1);')
   OR v_jobs IS DISTINCT FROM (SELECT jsonb_agg(to_jsonb(x) ORDER BY jobid) FROM cron.job x WHERE jobid IN(1,2)) THEN
   RAISE EXCEPTION 'ACTIVATION_POSTCONDITION_FAILED'; END IF;
END;
$stage3i$;
COMMIT;
-- stop_at is a human deadline, NOT automatic cron deactivation. Watch continuously.
-- Capture actual COMMIT time. Pause immediately after result or by stop_at.
"""
ACTIVATE=re.sub(r'\bj\b','v_manifest',ACTIVATE).replace('__CONTEXT__',CONTEXT.replace(MARKER,'v_manifest'))

VERIFY=CONTEXT+""", checks AS (SELECT e.*,
 coalesce(identities_match AND claim_status='RELEASED' AND lease_status='RELEASED'
   AND task_status='STALE' AND listing_status='AVAILABLE' AND donation_status='AVAILABLE'
   AND collection_path='DIRECT_PICKUP' AND listing_expires_at IS NULL
   AND claim->>'close_reason'='EXPIRED_SAFE_RELEASE' AND claim->>'closed_at' IS NOT NULL
   AND lease->>'release_reason'='EXPIRED_SAFE_RELEASE' AND lease->>'closed_at' IS NOT NULL
   AND expires_at=(j->>'expires_at')::timestamptz
   AND listing_version=(j->>'expected_version')::bigint+1
   AND eligibility_generation=(j->>'expected_generation')::bigint+1,false) AS lifecycle_ok,
 (SELECT count(*)=1 AND bool_and(a.actor_role='SYSTEM' AND a.actor_user_id IS NULL
     AND a.entity_id=cid AND a.lease_id=leid AND a.previous_state='ACTIVE'
     AND a.resulting_state='RELEASED' AND a.requested_state='RELEASED'
     AND a.reason_code='EXPIRED_SAFE_RELEASE' AND a.outcome='SUCCESS'
     AND a.details->>'listing_id'=lid::text AND a.details->>'donation_id'=did::text
     AND a.details->>'task_id'=tid::text)
   FROM public.audit_events a WHERE a.claim_id=cid AND a.event_type='LEASE_RECOVERY') AS recovery_audit_ok,
 (SELECT count(*)=1 AND bool_and(a.entity_id=did AND a.lease_id=leid AND a.actor_role='SYSTEM'
     AND a.actor_user_id IS NULL AND a.previous_state='CLAIMED' AND a.resulting_state='AVAILABLE'
     AND a.requested_state='AVAILABLE' AND a.outcome='SUCCESS' AND a.details->>'listing_id'=lid::text)
   FROM public.audit_events a WHERE a.claim_id=cid AND a.event_type='DONATION_STATUS_CHANGED'
     AND a.resulting_state='AVAILABLE') AS donation_audit_ok,
 EXISTS(SELECT 1 FROM public.listing_eligibility_refresh_jobs q WHERE q.listing_id=lid
   AND q.eligibility_generation=(j->>'expected_generation')::bigint+1
   AND q.expected_road_node_id=listing->>'pickup_road_node_id'
   AND q.job_status='COMPLETED' AND q.last_error_code IS NULL) AS refresh_completed,
 NOT EXISTS(SELECT 1 FROM public.claim_reconciliation_cases r WHERE r.claim_id=cid OR r.listing_id=lid)
   AND NOT EXISTS(SELECT 1 FROM public.active_task_route_assignments a WHERE a.task_id=tid)
   AND NOT EXISTS(SELECT 1 FROM public.pickup_route_stops s WHERE s.task_id=tid) AS custody_clear,
 coalesce(other_business_md5=j->>'other_business_md5' AND j->>'timezone'=current_setting('TimeZone'),false) AS unrelated_unchanged,
 EXISTS(SELECT 1 FROM cron.job WHERE jobid=3 AND NOT active) AS recovery_paused,
 EXISTS(SELECT 1 FROM cron.job_run_details r WHERE jobid=3 AND runid>3137 AND status='succeeded'
   AND end_time IS NOT NULL AND start_time>=(j->>'baseline_at')::timestamptz) AS scheduler_success,
 NOT EXISTS(SELECT 1 FROM cron.job_run_details WHERE jobid=3 AND runid>3137
   AND (status<>'succeeded' OR end_time IS NULL)) AS scheduler_no_errors
 FROM evidence e)
SELECT *,coalesce(lifecycle_ok AND recovery_audit_ok AND donation_audit_ok AND refresh_completed
 AND custody_clear AND unrelated_unchanged AND recovery_paused AND scheduler_success AND scheduler_no_errors,false)
 AS all_checks_pass FROM checks;
"""

MONITOR=CONTEXT+"""SELECT statement_timestamp() AS observed_at,(j->>'stop_at')::timestamptz AS operator_stop_at,
 claim,lease,task,listing,donation,audits,refresh,
 other_business_md5=j->>'other_business_md5' AS unrelated_unchanged,
 (SELECT jsonb_agg(to_jsonb(r) ORDER BY runid) FROM cron.job_run_details r WHERE jobid=3 AND runid>3137) AS new_runs,
 (SELECT jsonb_agg(to_jsonb(x) ORDER BY jobid) FROM cron.job x WHERE jobid IN(1,2,3)) AS cron,
 (SELECT jsonb_agg(to_jsonb(rc)) FROM public.claim_reconciliation_cases rc
   WHERE rc.case_status IN('OPEN','MANUAL_REVIEW')) AS unresolved_cases
FROM evidence;
SELECT pid,usename,application_name,state,xact_start,wait_event_type,wait_event,
 pg_blocking_pids(pid) AS blockers,query FROM pg_stat_activity
WHERE pid<>pg_backend_pid() AND xact_start IS NOT NULL AND backend_type='client backend';
SELECT DISTINCT ON(jobid) jobid,status,start_time,end_time,return_message
FROM cron.job_run_details WHERE jobid IN(1,2) ORDER BY jobid,runid DESC;
"""


def artifacts():
    header='-- Stage 3I REVIEW ONLY. DEV rcgyuwiidqvrgbxswhqj only. Not executed.\n'
    pause=(ROOT/'review-only/claim_recovery_pause.sql').read_text(encoding='utf-8')
    return {'01_preflight.sql':header+'-- SELECT ONLY; fill manifest IDs for target evidence.\n'+PREFLIGHT,
      '03_activate.sql':header+ACTIVATE,'04_monitor.sql':header+'-- SELECT ONLY.\n'+MONITOR,
      '05_verify.sql':header+'-- SELECT ONLY. Run after pause and refresh completion.\n'+VERIFY,
      '06_pause.sql':header+pause}


def render(sql,manifest):
    return sql.replace(MARKER,"'"+json.dumps(manifest,sort_keys=True).replace("'","''")+"'::jsonb")


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--write-templates',action='store_true')
    parser.add_argument('--manifest',type=Path)
    parser.add_argument('--output-dir',type=Path)
    args=parser.parse_args()
    if args.write_templates:
        DEST.mkdir(parents=True,exist_ok=True)
        for name,sql in artifacts().items():
            (DEST/name).write_text(sql,encoding='utf-8',newline='\n')
    elif args.manifest and args.output_dir:
        manifest=json.loads(args.manifest.read_text(encoding='utf-8'))
        if not isinstance(manifest,dict):
            parser.error('manifest must be a JSON object')
        args.output_dir.mkdir(parents=True,exist_ok=False)
        hashes=[]
        for name,sql in artifacts().items():
            data=render(sql,manifest).encode()
            (args.output_dir/name).write_bytes(data)
            hashes.append(hashlib.sha256(data).hexdigest().upper()+'  '+name)
        (args.output_dir/'SHA256SUMS.txt').write_text('\n'.join(hashes)+'\n',encoding='utf-8')
    else:
        parser.error('choose --write-templates or --manifest and a new --output-dir')
