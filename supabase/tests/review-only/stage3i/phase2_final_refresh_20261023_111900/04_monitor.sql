-- Stage 3I REVIEW ONLY. DEV rcgyuwiidqvrgbxswhqj only. Not executed.
-- SELECT ONLY.
WITH p AS (SELECT '{"approval_ref": "Final preparation approved; activation/recovery execution still requires separate explicit approval", "baseline_at": "2026-10-23 11:19:00.774683+00", "claim_id": "8161392c-e1e1-4723-a954-c80b6b61a8c7", "deadline_mode": "server_clock_immediately_before_activation", "donation_id": "3a012ba4-25cc-4054-897e-008e11da3e9e", "donor_user_id": "21d373a7-6551-4469-81d1-280198d4317e", "expected_generation": 1, "expected_version": 2, "expires_at": "2026-10-23T02:33:13.441725+00:00", "fixture_title": "STAGE3I-E2E-30bc928b-2843-4b9c-a5d4-298b76a8c514", "lease_id": "11b7d48e-a459-4b47-b1db-b43f98d0d474", "listing_id": "95d6cd51-866b-4eec-8a36-36dc24296aec", "maintenance_confirmed": true, "max_activation_seconds": 300, "ngo_user_id": "743cf8c1-12db-4c7d-8768-e584bae29c0e", "operator": "DEV Test Operator (user)", "other_business_md5": "070bb28ff5737477d6d91ec9e36feb02", "phase": "STAGE3I_PHASE2_FINAL_PREPARATION_ONLY", "stop_at": null, "task_id": "270caa8b-5a6d-481c-b199-c9a47156dda2", "timezone": "UTC"}'::jsonb AS j),
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
SELECT statement_timestamp() AS observed_at,(j->>'stop_at')::timestamptz AS receipt_deadline_if_copied,
 'Use saved activation_receipt absolute deadline; NULL here is not permission to extend the window'::text AS deadline_instruction,
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
