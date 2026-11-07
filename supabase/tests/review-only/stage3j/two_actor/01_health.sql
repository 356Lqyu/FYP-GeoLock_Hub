-- SELECT ONLY. DEV rcgyuwiidqvrgbxswhqj, executed with transaction READ ONLY.
SELECT jsonb_build_object(
 'checked_at',statement_timestamp(),
 'functions',(SELECT jsonb_agg(jsonb_build_object(
   'identity',p.proname||'('||replace(oidvectortypes(p.proargtypes),', ', ',')||')','owner',pg_get_userbyid(p.proowner),
   'security_definer',p.prosecdef,'config',p.proconfig,'acl',p.proacl::text,
   'body_md5',md5(replace(p.prosrc,E'\r\n',E'\n')),
   'arguments',pg_get_function_arguments(p.oid),'return',
     CASE WHEN p.proretset AND p.prorettype=to_regtype('public.audit_events')
       THEN 'SETOF public.audit_events' ELSE pg_get_function_result(p.oid) END)
   ORDER BY p.proname,pg_get_function_identity_arguments(p.oid)) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.proname IN('claim_listing','start_pickup',
    'complete_pickup','cancel_claim','get_my_claim_cards_v2','recover_expired_claims',
    'geolock_transition_listing_donations','submit_claim_reconciliation','get_authorized_audit_events')),
 'other_functions_md5',(SELECT md5(string_agg(n.nspname||'.'||p.proname||'('||
   pg_get_function_identity_arguments(p.oid)||')'||replace(pg_get_functiondef(p.oid),E'\r\n',E'\n')||
   pg_get_userbyid(p.proowner)||coalesce(p.proacl::text,'<NULL>'),E'\n'
   ORDER BY p.proname,pg_get_function_identity_arguments(p.oid)))
   FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.prokind IN ('f','p')
     AND p.proname NOT IN('claim_listing','start_pickup','complete_pickup','cancel_claim',
       'get_my_claim_cards_v2','recover_expired_claims','geolock_transition_listing_donations',
       'submit_claim_reconciliation','get_authorized_audit_events')),
 'failure_contract_ok',EXISTS(
   SELECT 1 FROM pg_class t JOIN pg_index i ON i.indrelid=t.oid
   WHERE t.oid=to_regclass('public.operation_failure_events') AND t.relkind='r'
     AND t.relowner='postgres'::regrole AND t.relrowsecurity
     AND NOT has_table_privilege('anon',t.oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
     AND NOT has_table_privilege('authenticated',t.oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
     AND i.indexrelid=to_regclass('public.operation_failure_claim_request_unique')
     AND i.indisunique AND i.indisvalid AND i.indisready AND i.indnkeyatts=5 AND i.indnatts=5
     AND (SELECT array_agg(a.attname::text ORDER BY k.n)
       FROM unnest(i.indkey) WITH ORDINALITY k(attnum,n)
       JOIN pg_attribute a ON a.attrelid=t.oid AND a.attnum=k.attnum)
       =ARRAY['actor_user_id','request_id','listing_id','operation_name','reason_code']
     AND lower(regexp_replace(pg_get_expr(i.indpred,i.indrelid),'[()[:space:]]','','g'))=
       'operation_name=''claim_listing''::textandactor_user_idisnotnullandrequest_idisnotnullandlisting_idisnotnull'
 ) AND EXISTS(
   SELECT 1 FROM pg_proc p
   WHERE p.oid=to_regprocedure('public.geolock_transition_listing_donations(uuid,text,text,uuid,uuid,text)')
     AND NOT p.prosecdef AND p.proowner='postgres'::regrole
     AND NOT EXISTS(SELECT 1 FROM pg_roles r
       WHERE r.rolname IN ('anon','authenticated','service_role','geolock_graph_worker','geolock_planner','geolock_validator')
         AND has_function_privilege(r.oid,p.oid,'EXECUTE'))
 ),
 'jobs',(SELECT jsonb_agg(jsonb_build_object('jobid',jobid,'active',active) ORDER BY jobid)
   FROM cron.job WHERE jobid IN(1,2,3)),
 'recovery_history',(SELECT jsonb_build_object('total',count(*),
   'failed',count(*) FILTER(WHERE status<>'succeeded'),
   'unfinished',count(*) FILTER(WHERE end_time IS NULL)) FROM cron.job_run_details WHERE jobid=3),
 'active_recovery_jobs',(SELECT count(*) FROM cron.job
   WHERE active AND command ~* '\mrecover_expired_claims\M'),
 'healthy_eligibility_jobs',(SELECT count(*) FROM cron.job j WHERE jobid IN(1,2)
   AND EXISTS(SELECT 1 FROM cron.job_run_details r WHERE r.jobid=j.jobid
     AND r.status='succeeded' AND r.end_time>statement_timestamp()-interval '3 minutes')
   AND NOT EXISTS(SELECT 1 FROM cron.job_run_details r WHERE r.jobid=j.jobid
     AND r.status='failed' AND r.start_time>statement_timestamp()-interval '15 minutes')),
 'lease_minutes',(SELECT claim_lease_minutes FROM public.coordination_config WHERE singleton),
 'unresolved_cases',(SELECT count(*) FROM public.claim_reconciliation_cases
   WHERE case_status IN('OPEN','MANUAL_REVIEW')),
 'overdue_active_pairs',(SELECT count(*) FROM public.donation_claims c
   JOIN public.claim_leases le USING(claim_id) WHERE c.claim_status='ACTIVE'
   AND le.lease_status='ACTIVE' AND le.expires_at<=statement_timestamp()));
