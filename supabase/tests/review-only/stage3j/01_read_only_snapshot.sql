-- DEV rcgyuwiidqvrgbxswhqj ONLY. SELECT-only acceptance review.
-- Do not call claim, recovery, routing-refresh, validator or cron API functions.
SELECT statement_timestamp() AS checked_at, current_user,
  current_setting('transaction_read_only') AS transaction_read_only,
  (SELECT jsonb_agg(to_jsonb(j) ORDER BY jobid) FROM cron.job j
    WHERE jobid IN (1,2,3)) AS jobs,
  (SELECT jsonb_agg(to_jsonb(x)) FROM (
    SELECT jobid,status,count(*) AS runs,max(end_time) AS latest_end
    FROM cron.job_run_details WHERE jobid=3 OR
      (jobid IN (1,2) AND start_time>=statement_timestamp()-interval '1 hour')
    GROUP BY jobid,status ORDER BY jobid,status) x) AS scheduler,
  (SELECT count(*) FROM cron.job_run_details
    WHERE jobid IN (1,2,3) AND end_time IS NULL) AS unfinished_runs,
  (SELECT count(*) FROM public.donation_claims c JOIN public.claim_leases le USING(claim_id)
    WHERE c.claim_status='ACTIVE' AND le.lease_status='ACTIVE'
      AND le.expires_at<=statement_timestamp()) AS overdue_active_pairs,
  (SELECT count(*) FROM public.claim_reconciliation_cases
    WHERE case_status IN ('OPEN','MANUAL_REVIEW')) AS unresolved_cases,
  (SELECT count(*) FROM public.ngo_profiles WHERE active_flag) AS active_ngos,
  (SELECT count(*) FROM public.ngo_profiles WHERE active_flag
    AND location_verified_at IS NOT NULL AND road_node_id IS NOT NULL) AS technically_routable_ngos,
  (SELECT count(*) FROM public.claim_requests WHERE outcome IS NULL) AS unfinished_requests,
  (SELECT jsonb_agg(jsonb_build_object('identity',p.oid::regprocedure::text,
    'owner',pg_get_userbyid(p.proowner),'security_definer',p.prosecdef,
    'config',p.proconfig,'acl',p.proacl::text,
    'body_md5',md5(replace(p.prosrc,E'\r\n',E'\n')),
    'arguments',pg_get_function_arguments(p.oid),'return',pg_get_function_result(p.oid))
    ORDER BY p.proname)
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname IN
      ('claim_listing','start_pickup','complete_pickup','cancel_claim',
       'recover_expired_claims','get_my_claim_cards_v2')) AS functions;

-- Existing precise retained-fixture verifier remains:
-- ../stage3i/closure/02_verify.sql (SELECT only; do not alter its baseline).
