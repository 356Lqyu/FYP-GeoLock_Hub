-- Repeat-safe cleanup for only the Stage 2 test-owned failpoint objects.
-- Run only after confirming the SQL Editor is on disposable DEV
-- rcgyuwiidqvrgbxswhqj. This is not a production migration.

BEGIN;

DO $$
DECLARE
  v_helper oid := to_regprocedure('geolock_stage2_test.fail_claim_write()');
  v_expected_rel oid;
  r record;
BEGIN
  FOR r IN
    SELECT t.tgname, t.tgrelid, t.tgfoid
    FROM pg_catalog.pg_trigger AS t
    WHERE NOT t.tgisinternal
      AND t.tgname IN (
        'geolock_stage2_fail_claim_requests_insert',
        'geolock_stage2_fail_claim_requests_update',
        'geolock_stage2_fail_donation_claims_insert',
        'geolock_stage2_fail_claim_leases_insert',
        'geolock_stage2_fail_listings_update',
        'geolock_stage2_fail_pickup_tasks_insert',
        'geolock_stage2_fail_audit_events_insert'
      )
  LOOP
    v_expected_rel := CASE r.tgname
      WHEN 'geolock_stage2_fail_claim_requests_insert' THEN 'public.claim_requests'::regclass::oid
      WHEN 'geolock_stage2_fail_claim_requests_update' THEN 'public.claim_requests'::regclass::oid
      WHEN 'geolock_stage2_fail_donation_claims_insert' THEN 'public.donation_claims'::regclass::oid
      WHEN 'geolock_stage2_fail_claim_leases_insert' THEN 'public.claim_leases'::regclass::oid
      WHEN 'geolock_stage2_fail_listings_update' THEN 'public.listings'::regclass::oid
      WHEN 'geolock_stage2_fail_pickup_tasks_insert' THEN 'public.pickup_tasks'::regclass::oid
      WHEN 'geolock_stage2_fail_audit_events_insert' THEN 'public.audit_events'::regclass::oid
    END;
    IF v_helper IS NULL OR r.tgfoid <> v_helper OR r.tgrelid <> v_expected_rel THEN
      RAISE EXCEPTION 'Refusing to remove unexpected trigger % on relation %',
        r.tgname, r.tgrelid::regclass;
    END IF;
  END LOOP;
END;
$$;

DROP TRIGGER IF EXISTS geolock_stage2_fail_claim_requests_insert ON public.claim_requests;
DROP TRIGGER IF EXISTS geolock_stage2_fail_claim_requests_update ON public.claim_requests;
DROP TRIGGER IF EXISTS geolock_stage2_fail_donation_claims_insert ON public.donation_claims;
DROP TRIGGER IF EXISTS geolock_stage2_fail_claim_leases_insert ON public.claim_leases;
DROP TRIGGER IF EXISTS geolock_stage2_fail_listings_update ON public.listings;
DROP TRIGGER IF EXISTS geolock_stage2_fail_pickup_tasks_insert ON public.pickup_tasks;
DROP TRIGGER IF EXISTS geolock_stage2_fail_audit_events_insert ON public.audit_events;

DO $$
DECLARE
  v_remaining bigint;
BEGIN
  IF to_regclass('geolock_stage2_test.claim_write_failpoints') IS NOT NULL THEN
    DELETE FROM geolock_stage2_test.claim_write_failpoints;
    SELECT count(*) INTO v_remaining
    FROM geolock_stage2_test.claim_write_failpoints;
    IF v_remaining <> 0 THEN
      RAISE EXCEPTION 'Failpoint cleanup left % rows', v_remaining;
    END IF;
  END IF;
END;
$$;

DROP FUNCTION IF EXISTS geolock_stage2_test.fail_claim_write();
DROP TABLE IF EXISTS geolock_stage2_test.claim_write_failpoints;
DROP SCHEMA IF EXISTS geolock_stage2_test;

COMMIT;

-- Final verification: both values must be true / zero after cleanup.
SELECT
  to_regnamespace('geolock_stage2_test') IS NULL AS test_schema_removed,
  count(*) FILTER (WHERE t.tgname LIKE 'geolock_stage2_fail_%') AS remaining_test_triggers
FROM pg_catalog.pg_trigger AS t
WHERE NOT t.tgisinternal;
