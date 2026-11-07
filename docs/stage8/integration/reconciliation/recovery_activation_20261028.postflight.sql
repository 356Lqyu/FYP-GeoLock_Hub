-- READ ONLY. Compare approved claim IDs and audit watermark to the saved preflight.
BEGIN READ ONLY;
SET LOCAL statement_timeout='10s';
SELECT c.claim_id,c.listing_id,c.claim_status,c.close_reason,
 le.lease_status,le.release_reason,t.task_status,l.listing_status,l.listing_version,
 d.donation_status,rc.case_status,rc.resolution_reason
FROM public.donation_claims c JOIN public.claim_leases le USING(claim_id)
LEFT JOIN public.pickup_tasks t USING(claim_id)
LEFT JOIN public.listings l ON l.listing_id=c.listing_id
LEFT JOIN public.donations d ON d.donation_id=l.donation_id
LEFT JOIN public.claim_reconciliation_cases rc ON rc.claim_id=c.claim_id
WHERE c.claim_id IN (
 'dd1be70f-0e42-4b75-9124-cac3702d76f6','b4bea793-9755-470a-95bb-6b02bc0c4443',
 'ca8eb131-6ca0-4256-9a8c-c8f781fcbf05','988b92f7-10d5-4471-ae72-cf1a37d53e0f',
 '26265510-e487-4587-9557-f1a8bee6cc19','84879ced-16b5-441e-9e3b-308283edf7be')
ORDER BY c.claim_id;
SELECT event_id,occurred_at,claim_id,lease_id,event_type,previous_state,resulting_state,reason_code,outcome
FROM public.audit_events WHERE event_type IN('LEASE_RECOVERY','DONATION_STATUS_CHANGED')
ORDER BY occurred_at DESC,event_id DESC LIMIT 100;
SELECT jobid,active,command,schedule FROM cron.job WHERE jobid=3;
SELECT runid,status,start_time,end_time,return_message FROM cron.job_run_details
WHERE jobid=3 ORDER BY runid DESC LIMIT 10;
SELECT c.claim_id FROM public.donation_claims c JOIN public.claim_leases le USING(claim_id)
WHERE c.claim_status='ACTIVE' AND le.lease_status='ACTIVE' AND le.expires_at<=statement_timestamp();
SELECT claim_id,case_status FROM public.claim_reconciliation_cases WHERE case_status IN('OPEN','MANUAL_REVIEW');
SELECT count(*) AS snapshots FROM routing_private.snapshots;
SELECT count(*) AS candidates FROM routing_private.candidates;
SELECT count(*) AS attestations FROM routing_private.validations;
SELECT count(*) AS routes FROM public.pickup_routes;
SELECT count(*) AS assignments FROM public.active_task_route_assignments;
ROLLBACK;
