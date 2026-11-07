-- SELECT ONLY. Stage 3I closure; DEV rcgyuwiidqvrgbxswhqj only.
-- No recovery, validator, cron API, fixture write or lock-acquisition function.
SELECT statement_timestamp() AS audited_at, current_database(), current_user,
 current_setting('transaction_read_only') AS transaction_read_only,
 (SELECT jsonb_agg(to_jsonb(j) ORDER BY jobid) FROM cron.job j WHERE jobid IN(1,2,3)) AS jobs,
 (SELECT coalesce(jsonb_agg(to_jsonb(j) ORDER BY jobid),'[]'::jsonb) FROM cron.job j
   WHERE command ~* '\mrecover_expired_claims\M') AS recovery_schedules,
 (SELECT jsonb_build_object('total',count(*),'succeeded',count(*) FILTER(WHERE status='succeeded'),
   'failed',count(*) FILTER(WHERE status='failed'),'unfinished',count(*) FILTER(WHERE end_time IS NULL),
   'latest_end',max(end_time)) FROM cron.job_run_details WHERE jobid=3) AS history_summary,
 (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY runid),'[]'::jsonb)
   FROM cron.job_run_details r WHERE jobid=3 AND runid>3137) AS test_runs,
 (SELECT jsonb_agg(jsonb_build_object('runid',r.runid,'start_time',r.start_time,'end_time',r.end_time,
   'recovery_event_id',a.event_id,'recovery_occurred_at',a.occurred_at))
   FROM cron.job_run_details r JOIN public.audit_events a
     ON a.claim_id='8161392c-e1e1-4723-a954-c80b6b61a8c7' AND a.event_type='LEASE_RECOVERY'
    AND a.occurred_at BETWEEN r.start_time AND r.end_time
   WHERE r.jobid=3 AND r.runid>3137) AS scheduler_audit_correlation,
 (SELECT jsonb_agg(to_jsonb(x) ORDER BY jobid,status) FROM
   (SELECT jobid,status,count(*) AS runs,max(start_time) AS latest_start,max(end_time) AS latest_end
    FROM cron.job_run_details WHERE jobid IN(1,2)
      AND start_time>=statement_timestamp()-interval '1 hour' GROUP BY jobid,status)x) AS eligibility_health,
 (SELECT coalesce(jsonb_agg(to_jsonb(r)),'[]'::jsonb) FROM cron.job_run_details r
   WHERE jobid IN(1,2,3) AND end_time IS NULL) AS unfinished_runs,
 (SELECT coalesce(jsonb_agg(jsonb_build_object('pid',pid,'role',usename,
   'application_name',application_name,'state',state,'wait_event',wait_event)),'[]'::jsonb)
   FROM pg_stat_activity WHERE pid<>pg_backend_pid()
     AND backend_type='client backend' AND xact_start IS NOT NULL) AS active_transactions,
 (SELECT coalesce(jsonb_agg(jsonb_build_object('table',c.relname,'mode',l.mode,'granted',l.granted,
   'pid',l.pid)),'[]'::jsonb) FROM pg_locks l JOIN pg_class c ON c.oid=l.relation
   JOIN pg_namespace n ON n.oid=c.relnamespace WHERE l.pid<>pg_backend_pid()
     AND n.nspname='public' AND c.relname IN('donation_claims','claim_leases','pickup_tasks',
       'listings','donations','hub_batches','hub_batch_members','hub_inventory','claim_reconciliation_cases')
     AND l.mode<>'AccessShareLock') AS relevant_locks,
 (SELECT jsonb_build_object('body_md5',md5(replace(prosrc,E'\r\n',E'\n')),
   'owner',pg_get_userbyid(proowner),'security_definer',prosecdef,'config',proconfig,
   'acl',proacl::text,'arguments',pg_get_function_arguments(oid),'return',pg_get_function_result(oid))
   FROM pg_proc WHERE oid='public.recover_expired_claims(integer)'::regprocedure) AS recovery_function,
 (SELECT jsonb_build_object('count',count(*),'md5',md5(string_agg(n.nspname||'.'||p.proname||'('||
   pg_get_function_identity_arguments(p.oid)||')'||replace(pg_get_functiondef(p.oid),E'\r\n',E'\n')||
   pg_get_userbyid(p.proowner)||coalesce(p.proacl::text,'<NULL>'),E'\n'
   ORDER BY p.proname,pg_get_function_identity_arguments(p.oid))))
   FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.oid<>'public.recover_expired_claims(integer)'::regprocedure) AS other_functions,
 (SELECT count(*) FROM public.donation_claims c JOIN public.claim_leases le USING(claim_id)
   WHERE c.claim_status='ACTIVE' AND le.lease_status='ACTIVE'
     AND le.expires_at<=statement_timestamp()) AS overdue_active_pairs,
 (SELECT count(*) FROM public.donation_claims
   WHERE claim_status IN('ACTIVE','RECONCILIATION_REQUIRED')) AS nonterminal_claims,
 (SELECT count(*) FROM public.claim_reconciliation_cases
   WHERE case_status IN('OPEN','MANUAL_REVIEW')) AS unresolved_cases,
 (SELECT jsonb_agg(to_jsonb(i) ORDER BY i.item_id) FROM public.donation_items i
   WHERE donation_id='3a012ba4-25cc-4054-897e-008e11da3e9e') AS fixture_items,
 (SELECT jsonb_agg(jsonb_build_object('image_id',image_id,'created_at',created_at,
   'owner_user_id',owner_user_id,'is_primary',is_primary,'display_order',display_order,
   'content_type',content_type,'size_bytes',size_bytes) ORDER BY display_order,image_id)
   FROM public.donation_images WHERE donation_id='3a012ba4-25cc-4054-897e-008e11da3e9e') AS fixture_images;
