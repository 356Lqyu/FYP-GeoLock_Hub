-- SELECT ONLY; DEV rcgyuwiidqvrgbxswhqj; no recovery call. Export results.
-- R01: Final target state and custody. Missing rows/NULLs are not successes.
WITH targets(claim_id,expected_task_id) AS (VALUES
 ('b4bea793-9755-470a-95bb-6b02bc0c4443'::uuid,'521ad842-5d79-4157-97f9-9fb1c73ca632'::uuid),
 ('dd1be70f-0e42-4b75-9124-cac3702d76f6'::uuid,'bbbf6b10-cb79-42ed-82cc-8b2246bf8bcb'::uuid))
SELECT statement_timestamp() AS observed_at,x.*,c.claim_status,c.closed_at,c.close_reason,
 le.lease_status,le.closed_at AS lease_closed_at,le.release_reason,t.task_id,t.task_status,
 l.listing_id,l.listing_status,l.listing_version,l.source_type,l.donation_id,l.batch_id,
 coalesce(c.claim_status='RELEASED' AND le.lease_status='RELEASED' AND t.task_id=x.expected_task_id
  AND t.task_status='STALE' AND c.close_reason='EXPIRED_SAFE_RELEASE' AND le.release_reason='EXPIRED_SAFE_RELEASE'
  AND c.closed_at IS NOT NULL AND le.closed_at IS NOT NULL AND l.listing_status='AVAILABLE',false) AS safe_release_state
FROM targets x LEFT JOIN public.donation_claims c ON c.claim_id=x.claim_id
LEFT JOIN public.claim_leases le ON le.claim_id=c.claim_id LEFT JOIN public.pickup_tasks t ON t.claim_id=c.claim_id
LEFT JOIN public.listings l ON l.listing_id=c.listing_id ORDER BY x.claim_id;
-- Both true for approved safe release. Compare listing_version with preflight: exactly +1.
-- Under the maintenance window no reclaims should intervene. A later reclaim needs separate audit review.

-- R02: Export newly observed recovery events; compare event IDs with preflight D06.
SELECT a.* FROM public.audit_events a WHERE a.claim_id IN
 ('b4bea793-9755-470a-95bb-6b02bc0c4443','dd1be70f-0e42-4b75-9124-cac3702d76f6','8161392c-e1e1-4723-a954-c80b6b61a8c7')
AND a.event_type='LEASE_RECOVERY' ORDER BY to_jsonb(a)->>'created_at',to_jsonb(a)->>'event_id';
-- Expect one NEW SUCCESS/RELEASED/EXPIRED_SAFE_RELEASE event for each target, none for historical claim.
-- A SUCCESS event with RECONCILIATION_REQUIRED is NOT safe-release success.

-- R03: All unresolved cases for either listing, including any unexpected partial state.
SELECT rc.* FROM public.claim_reconciliation_cases rc WHERE rc.listing_id IN
 (SELECT c.listing_id FROM public.donation_claims c WHERE c.claim_id IN
 ('b4bea793-9755-470a-95bb-6b02bc0c4443','dd1be70f-0e42-4b75-9124-cac3702d76f6'))
AND rc.case_status IN ('OPEN','MANUAL_REVIEW');
-- Expect zero for safe-release run. Do not force closed if rows appear.
-- REQUIRED additional SELECT-only postflight:
-- 1. Re-run three_claims_diagnostic_readonly.sql D01-D06: direct donations AVAILABLE;
--    hub donations BATCHED, batch remains PUBLISHED, inventory remains BATCHED;
--    all target routing references remain absent; no unauthorized custody transition.
-- 2. Re-run preflight P04: historical claim/lease/task hashes and row counts identical.
-- 3. Re-run preflight P02/P06: intended targets absent from ACTIVE/ACTIVE queue; scheduler still disabled.
--    Unrelated changes or remaining ACTIVE/RECONCILIATION_REQUIRED targets => STOP and investigate.
