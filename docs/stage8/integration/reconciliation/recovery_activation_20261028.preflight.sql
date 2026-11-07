-- READ ONLY. DEV rcgyuwiidqvrgbxswhqj; no application RPC invocation.
BEGIN READ ONLY;
SET LOCAL statement_timeout='10s';
SELECT current_database(),session_user,current_setting('transaction_read_only'),statement_timestamp();
SELECT p.oid::regprocedure,pg_get_userbyid(proowner) AS owner,prosecdef,proconfig,proacl,
 md5(replace(prosrc,E'\r\n',E'\n')) AS body_md5
FROM pg_proc p WHERE p.oid='public.recover_expired_claims(integer)'::regprocedure;
SELECT jobid,jobname,schedule,command,active,username,database FROM cron.job
WHERE jobname='geolock-expired-claim-recovery' OR command ILIKE '%recover_expired_claims%';
-- Snapshot references are historical observations, NOT reservations. Classify
-- unresolved client outcomes separately before approval; this query cannot see them.
WITH checks AS (
 SELECT c.claim_id,c.listing_id,le.lease_id,le.expires_at,t.task_id,t.task_status,
 l.source_type,l.listing_status,l.listing_expires_at,
 coalesce(t.ngo_user_id=c.ngo_user_id AND t.listing_id=c.listing_id
   AND t.task_status='CONFIRMED',false) AS task_ready,
 coalesce(l.listing_status='CLAIMED' AND (l.listing_expires_at IS NULL
   OR l.listing_expires_at>statement_timestamp()),false) AS listing_reopenable,
 NOT EXISTS(SELECT 1 FROM public.claim_reconciliation_cases rc
   WHERE (rc.claim_id=c.claim_id OR rc.listing_id=c.listing_id)
   AND rc.case_status IN('OPEN','MANUAL_REVIEW')) AS no_unresolved_case,
 NOT EXISTS(SELECT 1 FROM public.donation_claims other WHERE other.listing_id=c.listing_id
   AND other.claim_id<>c.claim_id AND other.claim_status IN('ACTIVE','RECONCILIATION_REQUIRED')) AS no_competing_owner,
 NOT EXISTS(SELECT 1 FROM public.active_task_route_assignments a WHERE a.task_id=t.task_id)
   AND NOT EXISTS(SELECT 1 FROM public.pickup_route_stops s WHERE s.task_id=t.task_id)
   AND NOT EXISTS(SELECT 1 FROM routing_private.items i WHERE i.task_id=t.task_id
     AND i.released_at IS NULL) AS no_route_reservation,
 CASE WHEN l.source_type='DIRECT_DONATION' THEN EXISTS(SELECT 1 FROM public.donations d
   WHERE d.donation_id=l.donation_id AND d.donation_status='CLAIMED'
     AND d.collection_path='DIRECT_PICKUP')
 WHEN l.source_type='HUB_BATCH' THEN EXISTS(SELECT 1 FROM public.hub_batches b
   WHERE b.batch_id=l.batch_id AND b.batch_status='PUBLISHED' AND b.batch_donation_count>0
   AND b.batch_donation_count=(SELECT count(*) FROM public.hub_batch_members m
     WHERE m.batch_id=b.batch_id AND m.membership_status='ACTIVE')
   AND NOT EXISTS(SELECT 1 FROM public.hub_batch_members m LEFT JOIN public.donations d USING(donation_id)
     WHERE m.batch_id=b.batch_id AND m.membership_status='ACTIVE'
     AND (d.donation_id IS NULL OR d.donation_status IS DISTINCT FROM 'CLAIMED'
       OR d.collection_path IS DISTINCT FROM 'HUB_COLLECTION'
       OR NOT EXISTS(SELECT 1 FROM public.hub_inventory hi WHERE hi.donation_id=m.donation_id
         AND hi.hub_id=b.hub_id AND hi.inventory_status='BATCHED')))) ELSE false END AS custody_ready,
 (SELECT coalesce(jsonb_agg(s.snapshot_id),'[]'::jsonb) FROM routing_private.snapshots s
   WHERE EXISTS(SELECT 1 FROM jsonb_array_elements(s.body->'observations') o
     WHERE o->'task'->>'task_id'=t.task_id::text)) AS historical_snapshots
 FROM public.donation_claims c JOIN public.claim_leases le USING(claim_id)
 LEFT JOIN public.pickup_tasks t USING(claim_id) LEFT JOIN public.listings l ON l.listing_id=c.listing_id
 WHERE c.claim_status='ACTIVE' AND le.lease_status='ACTIVE' AND le.expires_at<=statement_timestamp()
)
SELECT *,CASE WHEN task_ready AND listing_reopenable AND no_unresolved_case
 AND no_competing_owner AND no_route_reservation AND custody_ready
 THEN 'CONSERVATIVE_RELEASE_CANDIDATE_NOT_EXECUTION_GUARANTEE'
 ELSE 'RECONCILIATION_OR_OPERATOR_REVIEW_REQUIRED' END AS assessment
FROM checks ORDER BY expires_at,claim_id;
SELECT claim_id,case_status,opened_at FROM public.claim_reconciliation_cases
WHERE case_status IN('OPEN','MANUAL_REVIEW');
SELECT count(*) AS snapshots FROM routing_private.snapshots;
SELECT count(*) AS candidates FROM routing_private.candidates;
SELECT count(*) AS attestations FROM routing_private.validations;
SELECT count(*) AS routes FROM public.pickup_routes;
SELECT count(*) AS assignments FROM public.active_task_route_assignments;
SELECT event_id,occurred_at,claim_id,lease_id,resulting_state,reason_code,outcome
FROM public.audit_events WHERE event_type='LEASE_RECOVERY'
ORDER BY occurred_at DESC,event_id DESC LIMIT 20;
ROLLBACK;
