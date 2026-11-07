-- SELECT ONLY. Run in DEV SQL Editor session used for the rejected 113154 file.
-- Shows each manifest predicate independently; does not activate, change session
-- settings, run recovery or modify data. A true rejecting_conditions flag fails.
-- Old package is now stale: compare failed-attempt time with old expiry separately.
WITH p AS(SELECT '{"phase":"STAGE3I_PHASE2_FINAL_PREPARATION_ONLY","approval_ref":"Final preparation approved; activation/recovery execution still requires separate explicit approval","operator":"DEV Test Operator (user)","maintenance_confirmed":true,"claim_id":"8161392c-e1e1-4723-a954-c80b6b61a8c7","lease_id":"11b7d48e-a459-4b47-b1db-b43f98d0d474","listing_id":"95d6cd51-866b-4eec-8a36-36dc24296aec","donation_id":"3a012ba4-25cc-4054-897e-008e11da3e9e","task_id":"270caa8b-5a6d-481c-b199-c9a47156dda2","donor_user_id":"21d373a7-6551-4469-81d1-280198d4317e","ngo_user_id":"743cf8c1-12db-4c7d-8768-e584bae29c0e","fixture_title":"STAGE3I-E2E-30bc928b-2843-4b9c-a5d4-298b76a8c514","expected_version":2,"expected_generation":1,"expires_at":"2026-10-23T02:33:13.441725+00:00","other_business_md5":"070bb28ff5737477d6d91ec9e36feb02","timezone":"UTC","baseline_at":"2026-10-23 11:31:54.423718+00","stop_at":null,"max_activation_seconds":300,"deadline_mode":"server_clock_immediately_before_activation"}'::jsonb AS j) SELECT statement_timestamp() AS observed_at,current_setting('TimeZone') AS inspected_session_timezone,
 (j->>'baseline_at')::timestamptz AS reviewed_at,(j->>'baseline_at')::timestamptz+interval '3 minutes' AS expires_at,
 jsonb_build_object(
 'approval_reference_empty',coalesce(j->>'approval_ref','')='',
 'operator_empty',coalesce(j->>'operator','')='',
 'maintenance_not_confirmed',(j->>'maintenance_confirmed')::boolean IS DISTINCT FROM true,
 'missing_required_keys',NOT(j ?& ARRAY['claim_id','lease_id','listing_id','donation_id','task_id','donor_user_id','ngo_user_id','fixture_title','expected_version','expected_generation','expires_at','other_business_md5','timezone','baseline_at','stop_at']),
 'bad_snapshot_hash',j->>'other_business_md5' IS NULL OR length(j->>'other_business_md5')<>32,
 'wrong_maximum_window',(j->>'max_activation_seconds')::integer IS DISTINCT FROM 300,
 'wrong_deadline_mode',j->>'deadline_mode' IS DISTINCT FROM 'server_clock_immediately_before_activation',
 'missing_baseline',(j->>'baseline_at')::timestamptz IS NULL,
 'stale_baseline',(j->>'baseline_at')::timestamptz<clock_timestamp()-interval '3 minutes',
 'future_baseline',(j->>'baseline_at')::timestamptz>clock_timestamp(),
 'session_timezone_string_mismatch',j->>'timezone' IS DISTINCT FROM current_setting('TimeZone')) AS rejecting_conditions,
 (SELECT to_jsonb(x) FROM cron.job x WHERE jobid=3) AS job3,
 (SELECT jsonb_build_object('total',count(*),'succeeded',count(*)FILTER(WHERE status='succeeded'),'failed',count(*)FILTER(WHERE status='failed'),'unfinished',count(*)FILTER(WHERE end_time IS NULL),'last_start',max(start_time)) FROM cron.job_run_details WHERE jobid=3) AS runs,
 (SELECT coalesce(jsonb_agg(jsonb_build_object('pid',pid,'application_name',application_name,'state',state,'xact_start',xact_start,'query_start',query_start,'query',query)),'[]') FROM pg_stat_activity WHERE pid<>pg_backend_pid() AND backend_type='client backend' AND xact_start IS NOT NULL) AS open_transactions
 FROM p;
