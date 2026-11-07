-- SELECT ONLY. DEV rcgyuwiidqvrgbxswhqj only; no recovery/cron/fixture mutation.
SELECT jsonb_build_object(
 'observed_at',statement_timestamp(),'server_after_expiry',statement_timestamp()>'2026-10-23 02:33:13.441725+00'::timestamptz,
 'overdue_for',statement_timestamp()-'2026-10-23 02:33:13.441725+00'::timestamptz,
 'function',(SELECT jsonb_build_object('definition',pg_get_functiondef(p.oid),'body_md5',md5(replace(p.prosrc,E'\r\n',E'\n')),'arguments',pg_get_function_arguments(p.oid),'return_type',pg_get_function_result(p.oid),'owner',pg_get_userbyid(p.proowner),'security_definer',p.prosecdef,'config',p.proconfig,'acl',p.proacl::text,'anon_execute',has_function_privilege('anon',p.oid,'EXECUTE'),'authenticated_execute',has_function_privilege('authenticated',p.oid,'EXECUTE'),'service_execute',has_function_privilege('service_role',p.oid,'EXECUTE')) FROM pg_proc p WHERE p.oid='public.recover_expired_claims(integer)'::regprocedure),
 'eligibility_health',(SELECT jsonb_agg(to_jsonb(x)) FROM(SELECT jobid,status,count(*) AS runs,max(start_time) AS latest_start,max(end_time) AS latest_end FROM cron.job_run_details WHERE jobid IN(1,2) AND start_time>=statement_timestamp()-interval '1 hour' GROUP BY jobid,status ORDER BY jobid,status)x),
 'unfinished',(SELECT coalesce(jsonb_agg(to_jsonb(x)),'[]') FROM cron.job_run_details x WHERE jobid IN(1,2,3) AND end_time IS NULL),
 'job3_history',(SELECT jsonb_build_object('runs',count(*),'succeeded',count(*) FILTER(WHERE status='succeeded'),'failed',count(*) FILTER(WHERE status='failed'),'max_runid',max(runid),'runids',jsonb_agg(runid ORDER BY runid)) FROM cron.job_run_details WHERE jobid=3),
 'active_leases',(SELECT count(*) FROM public.claim_leases WHERE lease_status IN('ACTIVE','RECONCILIATION_REQUIRED')),
 'unresolved_cases',(SELECT count(*) FROM public.claim_reconciliation_cases WHERE case_status IN('OPEN','MANUAL_REVIEW')),
 'custody',(SELECT jsonb_build_object(
 'inventory',(SELECT coalesce(jsonb_agg(to_jsonb(x)),'[]') FROM public.hub_inventory x WHERE donation_id='3a012ba4-25cc-4054-897e-008e11da3e9e'),
 'memberships',(SELECT coalesce(jsonb_agg(to_jsonb(x)),'[]') FROM public.hub_batch_members x WHERE donation_id='3a012ba4-25cc-4054-897e-008e11da3e9e'))),
 'all_target_audit_types',(SELECT jsonb_agg(jsonb_build_object('event_type',event_type,'outcome',outcome,'occurred_at',occurred_at) ORDER BY occurred_at,event_id) FROM public.audit_events WHERE claim_id='8161392c-e1e1-4723-a954-c80b6b61a8c7' OR entity_id IN('3a012ba4-25cc-4054-897e-008e11da3e9e','95d6cd51-866b-4eec-8a36-36dc24296aec')),
 'items',(SELECT jsonb_agg(to_jsonb(i) ORDER BY i.created_at,i.item_id) FROM public.donation_items i WHERE donation_id='3a012ba4-25cc-4054-897e-008e11da3e9e'),
 'photos',(SELECT jsonb_agg(jsonb_build_object('image_id',i.image_id,'owner_user_id',i.owner_user_id,'is_primary',i.is_primary,'display_order',i.display_order,'content_type',i.content_type,'size_bytes',i.size_bytes,'created_at',i.created_at) ORDER BY i.display_order,i.image_id) FROM public.donation_images i WHERE donation_id='3a012ba4-25cc-4054-897e-008e11da3e9e'),
 'other_functions',(SELECT jsonb_build_object('count',count(*),'hash',md5(string_agg(n.nspname||'.'||p.proname||'('||pg_get_function_identity_arguments(p.oid)||')'||replace(pg_get_functiondef(p.oid),E'\r\n',E'\n')||pg_get_userbyid(p.proowner)||coalesce(p.proacl::text,'<NULL>'),E'\n' ORDER BY p.proname,pg_get_function_identity_arguments(p.oid)))) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.oid<>'public.recover_expired_claims(integer)'::regprocedure)
) AS evidence;

SELECT jsonb_build_object('observed_at',statement_timestamp(),
 'reservations',(SELECT coalesce(jsonb_agg(to_jsonb(x)),'[]') FROM public.hub_reservations x WHERE donation_id='3a012ba4-25cc-4054-897e-008e11da3e9e'),
 'receipts',(SELECT coalesce(jsonb_agg(to_jsonb(x)),'[]') FROM public.hub_receipts x WHERE donation_id='3a012ba4-25cc-4054-897e-008e11da3e9e'),
 'claim_request',(SELECT to_jsonb(x) FROM public.claim_requests x WHERE request_id='38aba660-edee-4cab-b1eb-ee75692607c4'),
 'job3',(SELECT jsonb_build_object('active',active,'command',command) FROM cron.job WHERE jobid=3),
 'job3_runs',(SELECT count(*) FROM cron.job_run_details WHERE jobid=3)) AS evidence;
