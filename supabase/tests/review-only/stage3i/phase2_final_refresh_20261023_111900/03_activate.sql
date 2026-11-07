-- Stage 3I REVIEW ONLY. DEV rcgyuwiidqvrgbxswhqj only. Not executed.
-- REVIEW ONLY: MUTATES JOB 3 IF EXECUTED AFTER SEPARATE APPROVAL.
-- DEV rcgyuwiidqvrgbxswhqj only. Not a migration. No fixture/recovery invocation.
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='10s';
SET LOCAL idle_in_transaction_session_timeout='10s';
SET LOCAL search_path=pg_catalog,public,pg_temp;
DO $stage3i$
DECLARE v_manifest jsonb := '{"approval_ref": "Final preparation approved; activation/recovery execution still requires separate explicit approval", "baseline_at": "2026-10-23 11:19:00.774683+00", "claim_id": "8161392c-e1e1-4723-a954-c80b6b61a8c7", "deadline_mode": "server_clock_immediately_before_activation", "donation_id": "3a012ba4-25cc-4054-897e-008e11da3e9e", "donor_user_id": "21d373a7-6551-4469-81d1-280198d4317e", "expected_generation": 1, "expected_version": 2, "expires_at": "2026-10-23T02:33:13.441725+00:00", "fixture_title": "STAGE3I-E2E-30bc928b-2843-4b9c-a5d4-298b76a8c514", "lease_id": "11b7d48e-a459-4b47-b1db-b43f98d0d474", "listing_id": "95d6cd51-866b-4eec-8a36-36dc24296aec", "maintenance_confirmed": true, "max_activation_seconds": 300, "ngo_user_id": "743cf8c1-12db-4c7d-8768-e584bae29c0e", "operator": "DEV Test Operator (user)", "other_business_md5": "070bb28ff5737477d6d91ec9e36feb02", "phase": "STAGE3I_PHASE2_FINAL_PREPARATION_ONLY", "stop_at": null, "task_id": "270caa8b-5a6d-481c-b199-c9a47156dda2", "timezone": "UTC"}'::jsonb;
 v record; v_jobs jsonb; v_activation_at timestamptz; v_pause_deadline timestamptz;
BEGIN
 IF current_database()<>'postgres' OR current_user<>'postgres' OR session_user<>'postgres'
   OR auth.uid() IS NOT NULL THEN RAISE EXCEPTION 'CLEAN_POSTGRES_SESSION_REQUIRED'; END IF;
 IF coalesce(v_manifest->>'approval_ref','')='' OR coalesce(v_manifest->>'operator','')=''
   OR (v_manifest->>'maintenance_confirmed')::boolean IS DISTINCT FROM true
   OR NOT (v_manifest ?& ARRAY['claim_id','lease_id','listing_id','donation_id','task_id',
     'donor_user_id','ngo_user_id','fixture_title','expected_version','expected_generation',
     'expires_at','other_business_md5','timezone','baseline_at','stop_at'])
   OR v_manifest->>'other_business_md5' IS NULL OR length(v_manifest->>'other_business_md5')<>32
   OR (v_manifest->>'max_activation_seconds')::integer IS DISTINCT FROM 300
   OR v_manifest->>'deadline_mode' IS DISTINCT FROM 'server_clock_immediately_before_activation'
   OR (v_manifest->>'baseline_at')::timestamptz IS NULL
   OR (v_manifest->>'baseline_at')::timestamptz<clock_timestamp()-interval '3 minutes'
   OR (v_manifest->>'baseline_at')::timestamptz>clock_timestamp()
   OR v_manifest->>'timezone' IS DISTINCT FROM current_setting('TimeZone') THEN
   RAISE EXCEPTION 'REVIEWED_FRESH_MANIFEST_AND_PRESENT_OPERATOR_REQUIRED'; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_proc p
   WHERE p.oid='public.recover_expired_claims(integer)'::regprocedure
     AND md5(replace(p.prosrc,E'\r\n',E'\n'))='5ff6d8719db9681aae6f444b89dfbaee'
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
   OR (SELECT count(*) FROM cron.job WHERE command ~* '\mrecover_expired_claims\M')<>1
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
 WITH p AS (SELECT v_manifest AS j),
 e AS (SELECT j,(j->>'claim_id')::uuid AS cid,(j->>'lease_id')::uuid AS leid,
   (j->>'listing_id')::uuid AS lid,(j->>'donation_id')::uuid AS did,
   (j->>'task_id')::uuid AS tid FROM p),
 outside_snapshot AS (SELECT jsonb_build_object('donations',(SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb) FROM public.donations x WHERE x.donation_id IS DISTINCT FROM e.did),'listings',(SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb) FROM public.listings x WHERE x.listing_id IS DISTINCT FROM e.lid),'donation_claims',(SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb) FROM public.donation_claims x WHERE x.claim_id IS DISTINCT FROM e.cid),'claim_leases',(SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb) FROM public.claim_leases x WHERE x.lease_id IS DISTINCT FROM e.leid),'pickup_tasks',(SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb) FROM public.pickup_tasks x WHERE x.task_id IS DISTINCT FROM e.tid),'hub_batches',(SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb) FROM public.hub_batches x WHERE true),'hub_batch_members',(SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb) FROM public.hub_batch_members x WHERE true),'hub_inventory',(SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb) FROM public.hub_inventory x WHERE true),'active_task_route_assignments',(SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb) FROM public.active_task_route_assignments x WHERE true),'pickup_route_stops',(SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb) FROM public.pickup_route_stops x WHERE true),'claim_reconciliation_cases',(SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb) FROM public.claim_reconciliation_cases x WHERE true),'audit_events',(SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb) FROM public.audit_events x WHERE x.claim_id IS DISTINCT FROM e.cid AND x.entity_id IS DISTINCT FROM e.cid AND x.entity_id IS DISTINCT FROM e.did AND x.entity_id IS DISTINCT FROM e.lid),'listing_eligibility_refresh_jobs',(SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb) FROM public.listing_eligibility_refresh_jobs x WHERE x.listing_id IS DISTINCT FROM e.lid)) AS data FROM e),
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
 SELECT * INTO v FROM evidence;
 IF NOT coalesce(v.identities_match AND v.claim_status='ACTIVE' AND v.lease_status='ACTIVE'
   AND v.task_status='CONFIRMED' AND v.listing_status='CLAIMED' AND v.donation_status='CLAIMED'
   AND v.collection_path='DIRECT_PICKUP' AND v.listing_expires_at IS NULL
   AND v.expires_at<=clock_timestamp()
   AND v.expires_at=(v_manifest->>'expires_at')::timestamptz
   AND abs(extract(epoch FROM(v.expires_at-v.issued_at))-21600)<1
   AND v.listing_version=(v_manifest->>'expected_version')::bigint
   AND v.eligibility_generation=(v_manifest->>'expected_generation')::bigint
   AND v.donor_user_id=(v_manifest->>'donor_user_id')::uuid AND v.ngo_user_id=(v_manifest->>'ngo_user_id')::uuid
   AND v.title=v_manifest->>'fixture_title' AND v.title LIKE 'STAGE3I-E2E-%'
   AND v.other_business_md5=v_manifest->>'other_business_md5',false) THEN
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
 -- Capture a conservative real activation-statement anchor, before COMMIT.
 v_activation_at:=clock_timestamp();
 v_pause_deadline:=v_activation_at+make_interval(secs=>(v_manifest->>'max_activation_seconds')::integer);
 v_manifest:=v_manifest||jsonb_build_object('activation_statement_at',v_activation_at,'stop_at',v_pause_deadline);
 PERFORM set_config('geolock.stage3i_receipt',jsonb_build_object(
   'operator',v_manifest->>'operator','claim_id',v_manifest->>'claim_id',
   'activation_statement_utc',to_char(v_activation_at AT TIME ZONE 'UTC','YYYY-MM-DD HH24:MI:SS.US'),
   'pause_deadline_utc',to_char(v_pause_deadline AT TIME ZONE 'UTC','YYYY-MM-DD HH24:MI:SS.US'),
   'pause_deadline_myt',to_char(v_pause_deadline AT TIME ZONE 'Asia/Kuala_Lumpur','YYYY-MM-DD HH24:MI:SS.US'),
   'pause_deadline',v_pause_deadline,'window_seconds',300,
   'committed',false,'note','Receipt generated before COMMIT; confirm COMMIT and cron state separately')::text,true);
 PERFORM cron.alter_job(3,active := true);
 IF NOT EXISTS(SELECT 1 FROM cron.job WHERE jobid=3 AND active
     AND command='set lock_timeout = ''5s''; set statement_timeout = ''50s''; select public.recover_expired_claims(1);')
   OR v_jobs IS DISTINCT FROM (SELECT jsonb_agg(to_jsonb(x) ORDER BY jobid) FROM cron.job x WHERE jobid IN(1,2)) THEN
   RAISE EXCEPTION 'ACTIVATION_POSTCONDITION_FAILED'; END IF;
 IF clock_timestamp()>=v_pause_deadline THEN RAISE EXCEPTION 'ACTIVATION_WINDOW_ALREADY_ELAPSED'; END IF;
END;
$stage3i$;
SELECT current_setting('geolock.stage3i_receipt')::jsonb AS activation_receipt;
COMMIT;
-- Receipt anchor is immediately BEFORE ALTER, hence deadline is no later than COMMIT +5m.
-- The actual COMMIT timestamp cannot be predicted in a preparation-only package.
-- Start a five-minute timer BEFORE Run; pause on first outcome or receipt deadline, sooner wins.
-- Receipt is NOT commit proof and is not persisted. Save output; verify COMMIT/cron separately.
-- If no receipt is visible, pause immediately. No automatic stop job is installed.
