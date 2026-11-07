-- SELECT ONLY. DEV rcgyuwiidqvrgbxswhqj.
SELECT jsonb_build_object('observed_at',statement_timestamp(),'reservations',(SELECT coalesce(jsonb_agg(to_jsonb(x)),'[]') FROM public.hub_reservations x WHERE donation_id='3a012ba4-25cc-4054-897e-008e11da3e9e'),
 'receipts',(SELECT coalesce(jsonb_agg(to_jsonb(x)),'[]') FROM public.hub_receipts x WHERE donation_id='3a012ba4-25cc-4054-897e-008e11da3e9e'),
 'claim_request',(SELECT to_jsonb(x) FROM public.claim_requests x WHERE request_id='38aba660-edee-4cab-b1eb-ee75692607c4'),
 'job3',(SELECT jsonb_build_object('active',active,'command',command) FROM cron.job WHERE jobid=3),
 'job3_runs',(SELECT count(*) FROM cron.job_run_details WHERE jobid=3)) AS evidence;
