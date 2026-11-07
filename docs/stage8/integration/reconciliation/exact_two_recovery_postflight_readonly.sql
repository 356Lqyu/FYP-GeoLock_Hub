-- SELECT ONLY. DEV rcgyuwiidqvrgbxswhqj; run after separately approved committed execution.
-- Exported preflight baselines remain necessary: these queries cannot reconstruct the past.
-- E01: Exact outcomes and direct custody. Require exactly two rows, all checks true.
WITH targets(claim_id,task_id) AS (VALUES
 ('b4bea793-9755-470a-95bb-6b02bc0c4443'::uuid,'521ad842-5d79-4157-97f9-9fb1c73ca632'::uuid),
 ('dd1be70f-0e42-4b75-9124-cac3702d76f6'::uuid,'bbbf6b10-cb79-42ed-82cc-8b2246bf8bcb'::uuid))
SELECT statement_timestamp() AS observed_at,x.*,c.listing_id,le.lease_id,
 c.claim_status,le.lease_status,t.task_status,l.listing_status,l.listing_version,d.donation_status,
 coalesce(c.claim_status='RELEASED' AND le.lease_status='RELEASED' AND t.task_id=x.task_id
  AND t.task_status='STALE' AND c.close_reason='EXPIRED_SAFE_RELEASE' AND le.release_reason='EXPIRED_SAFE_RELEASE'
  AND c.closed_at IS NOT NULL AND le.closed_at IS NOT NULL AND l.listing_status='AVAILABLE'
  AND (l.listing_expires_at IS NULL OR l.listing_expires_at>statement_timestamp())
  AND l.source_type='DIRECT_DONATION' AND d.donation_status='AVAILABLE' AND d.collection_path='DIRECT_PICKUP',false) AS expected_state,
 NOT EXISTS(SELECT 1 FROM public.claim_reconciliation_cases rc WHERE rc.claim_id=c.claim_id OR rc.listing_id=c.listing_id) AS no_cases,
 NOT EXISTS(SELECT 1 FROM public.pickup_tasks tt WHERE tt.listing_id=c.listing_id AND
  (EXISTS(SELECT 1 FROM routing_private.items i WHERE i.task_id=tt.task_id)
   OR EXISTS(SELECT 1 FROM public.active_task_route_assignments a WHERE a.task_id=tt.task_id)
   OR EXISTS(SELECT 1 FROM public.pickup_route_stops s WHERE s.task_id=tt.task_id))) AS no_routing_references
FROM targets x LEFT JOIN public.donation_claims c ON c.claim_id=x.claim_id
LEFT JOIN public.claim_leases le ON le.claim_id=c.claim_id LEFT JOIN public.pickup_tasks t ON t.claim_id=c.claim_id
LEFT JOIN public.listings l ON l.listing_id=c.listing_id LEFT JOIN public.donations d ON d.donation_id=l.donation_id
ORDER BY x.claim_id;
-- Compare listing IDs/donation IDs to preflight; listing_version must be preflight +1.

-- E02: Historical rows; compare row count/IDs/hash to saved preflight P04, not just status.
SELECT 'claim' AS object_type,c.claim_id::text AS id,md5(to_jsonb(c)::text) AS row_md5,to_jsonb(c) AS record
FROM public.donation_claims c WHERE c.claim_id='8161392c-e1e1-4723-a954-c80b6b61a8c7'
UNION ALL SELECT 'lease',le.lease_id::text,md5(to_jsonb(le)::text),to_jsonb(le)
FROM public.claim_leases le WHERE le.claim_id='8161392c-e1e1-4723-a954-c80b6b61a8c7'
UNION ALL SELECT 'task',t.task_id::text,md5(to_jsonb(t)::text),to_jsonb(t)
FROM public.pickup_tasks t WHERE t.claim_id='8161392c-e1e1-4723-a954-c80b6b61a8c7'
ORDER BY object_type,id;

-- E03: Compare event IDs with preflight D06; expect exactly one NEW safe-release event per target,
-- and no new historical event. Integer function return alone is not sufficient evidence.
SELECT a.* FROM public.audit_events a WHERE a.claim_id IN
 ('b4bea793-9755-470a-95bb-6b02bc0c4443','dd1be70f-0e42-4b75-9124-cac3702d76f6','8161392c-e1e1-4723-a954-c80b6b61a8c7')
ORDER BY coalesce(to_jsonb(a)->>'occurred_at',to_jsonb(a)->>'created_at'),a.event_id;

-- E04: Scheduler remains disabled; do not enable as part of this operation.
SELECT jobid,jobname,active FROM cron.job
WHERE jobname='geolock-expired-claim-recovery' OR command ~* '\mrecover_expired_claims\M';
