-- TEST-ONLY SUPPORT OBJECTS. Never apply to the shared project or production.
-- Run only after manually confirming the SQL Editor is connected to the
-- disposable DEV project rcgyuwiidqvrgbxswhqj. These triggers fail only when a
-- matching request UUID is explicitly inserted into the private test schema.
-- They do not replace or edit any production function, constraint, or policy.

BEGIN;

DO $$
BEGIN
  IF to_regnamespace('geolock_stage2_test') IS NOT NULL THEN
    RAISE EXCEPTION 'geolock_stage2_test already exists; inspect and run the separate cleanup script before installation';
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_catalog.pg_trigger AS t
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
  ) THEN
    RAISE EXCEPTION 'A test trigger name already exists; refusing to overwrite it';
  END IF;
END;
$$;

CREATE SCHEMA geolock_stage2_test;

CREATE TABLE IF NOT EXISTS geolock_stage2_test.claim_write_failpoints (
  request_id uuid PRIMARY KEY,
  fail_at text NOT NULL CHECK (fail_at IN (
    'claim_requests_insert',
    'donation_claims_insert',
    'claim_leases_insert',
    'listings_update',
    'pickup_tasks_insert',
    'claim_requests_update',
    'audit_events_insert'
  )),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE FUNCTION geolock_stage2_test.fail_claim_write()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, geolock_stage2_test, pg_temp
AS $$
DECLARE
  v_request_id uuid;
  v_fail_at text;
BEGIN
  v_fail_at := TG_TABLE_NAME || '_' || lower(TG_OP);

  CASE TG_TABLE_NAME
    WHEN 'claim_requests' THEN
      v_request_id := NEW.request_id;
    WHEN 'donation_claims' THEN
      v_request_id := NEW.request_id;
    WHEN 'claim_leases' THEN
      SELECT dc.request_id INTO v_request_id
      FROM public.donation_claims AS dc
      WHERE dc.claim_id = NEW.claim_id;
    WHEN 'listings' THEN
      SELECT dc.request_id INTO v_request_id
      FROM public.donation_claims AS dc
      WHERE dc.listing_id = NEW.listing_id
        AND dc.claim_status = 'ACTIVE'
      ORDER BY dc.claimed_at DESC
      LIMIT 1;
    WHEN 'pickup_tasks' THEN
      SELECT dc.request_id INTO v_request_id
      FROM public.donation_claims AS dc
      WHERE dc.claim_id = NEW.claim_id;
    WHEN 'audit_events' THEN
      v_request_id := NEW.request_id;
    ELSE
      RETURN NEW;
  END CASE;

  IF v_request_id IS NOT NULL AND EXISTS (
    SELECT 1
    FROM geolock_stage2_test.claim_write_failpoints AS f
    WHERE f.request_id = v_request_id
      AND f.fail_at = v_fail_at
  ) THEN
    RAISE EXCEPTION 'STAGE2_TEST_FAILPOINT:%', v_fail_at
      USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON SCHEMA geolock_stage2_test FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON TABLE geolock_stage2_test.claim_write_failpoints FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION geolock_stage2_test.fail_claim_write() FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER geolock_stage2_fail_claim_requests_insert
BEFORE INSERT ON public.claim_requests
FOR EACH ROW EXECUTE FUNCTION geolock_stage2_test.fail_claim_write();

CREATE TRIGGER geolock_stage2_fail_claim_requests_update
BEFORE UPDATE ON public.claim_requests
FOR EACH ROW EXECUTE FUNCTION geolock_stage2_test.fail_claim_write();

CREATE TRIGGER geolock_stage2_fail_donation_claims_insert
BEFORE INSERT ON public.donation_claims
FOR EACH ROW EXECUTE FUNCTION geolock_stage2_test.fail_claim_write();

CREATE TRIGGER geolock_stage2_fail_claim_leases_insert
BEFORE INSERT ON public.claim_leases
FOR EACH ROW EXECUTE FUNCTION geolock_stage2_test.fail_claim_write();

CREATE TRIGGER geolock_stage2_fail_listings_update
BEFORE UPDATE ON public.listings
FOR EACH ROW EXECUTE FUNCTION geolock_stage2_test.fail_claim_write();

CREATE TRIGGER geolock_stage2_fail_pickup_tasks_insert
BEFORE INSERT ON public.pickup_tasks
FOR EACH ROW EXECUTE FUNCTION geolock_stage2_test.fail_claim_write();

CREATE TRIGGER geolock_stage2_fail_audit_events_insert
BEFORE INSERT ON public.audit_events
FOR EACH ROW WHEN (NEW.event_type = 'CLAIM_ATTEMPT')
EXECUTE FUNCTION geolock_stage2_test.fail_claim_write();

COMMIT;

SELECT t.tgname AS installed_test_trigger, t.tgrelid::regclass AS target_table
FROM pg_catalog.pg_trigger AS t
WHERE NOT t.tgisinternal
  AND t.tgname LIKE 'geolock_stage2_fail_%'
ORDER BY t.tgname;
