-- Target: isolated DEV project rcgyuwiidqvrgbxswhqj only.
-- Prepared for review; do not deploy until separately approved.
--
-- Read-only preflight (run against the verified DEV endpoint before applying):
-- SELECT p.oid::regprocedure AS signature,
--        pg_get_userbyid(p.proowner) AS function_owner,
--        p.prorettype::regtype AS return_type,
--        p.provolatile AS volatility,
--        p.prosecdef AS security_definer,
--        p.proconfig AS settings,
--        p.proacl AS grants,
--        pg_get_functiondef(p.oid) AS deployed_definition
-- FROM pg_proc p
-- WHERE p.oid = to_regprocedure('public.get_my_donation_coordination(uuid)');
--
-- The expected preflight has owner postgres, jsonb return, STABLE,
-- SECURITY DEFINER, search_path=pg_catalog, pg_temp, and execute grants for
-- authenticated only (besides the owner). The deployed body must contain the
-- donor ownership check and either the known old join or this migration's
-- corrected join. The migration guard below enforces those conditions.

BEGIN;

DO $migration_guard$
DECLARE
  v_definition text;
  v_owner text;
  v_acl text;
  v_security_definer boolean;
  v_return_type text;
  v_volatility "char";
  v_config text[];
BEGIN
  SELECT pg_get_functiondef(p.oid), pg_get_userbyid(p.proowner),
         p.proacl::text, p.prosecdef, p.prorettype::regtype::text,
         p.provolatile, p.proconfig
    INTO v_definition, v_owner, v_acl, v_security_definer, v_return_type,
         v_volatility, v_config
  FROM pg_proc p
  WHERE p.oid = to_regprocedure('public.get_my_donation_coordination(uuid)');

  IF NOT FOUND THEN
    RAISE EXCEPTION 'EXPECTED_DONATION_COORDINATION_RPC_MISSING';
  END IF;
  IF v_owner IS DISTINCT FROM 'postgres'
     OR v_return_type IS DISTINCT FROM 'jsonb'
     OR v_volatility IS DISTINCT FROM 's'
     OR v_security_definer IS DISTINCT FROM true
     OR v_config IS DISTINCT FROM ARRAY['search_path=pg_catalog, pg_temp']::text[]
     OR v_acl IS DISTINCT FROM '{postgres=X/postgres,authenticated=X/postgres}' THEN
    RAISE EXCEPTION 'DONATION_COORDINATION_RPC_SECURITY_OR_GRANTS_DRIFT';
  END IF;
  IF position('auth.uid() IS NULL' IN v_definition) = 0
     OR position('DONATION_OWNER_REQUIRED' IN v_definition) = 0
     OR position('public.get_my_claim_coordination(x.claim_id)' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'DONATION_COORDINATION_RPC_AUTH_OR_RESPONSE_DRIFT';
  END IF;
  IF position('JOIN public.listings l USING(listing_id)' IN v_definition) = 0
     AND position('JOIN public.listings l ON l.listing_id = c.listing_id' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'DONATION_COORDINATION_RPC_JOIN_DRIFT';
  END IF;
END
$migration_guard$;

CREATE OR REPLACE FUNCTION public.get_my_donation_coordination(p_donation uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'pg_temp'
AS $function$
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (
    SELECT 1
    FROM public.donations
    WHERE donation_id = p_donation
      AND donor_user_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'DONATION_OWNER_REQUIRED';
  END IF;

  RETURN jsonb_build_object(
    'donation_id', p_donation,
    'contexts', (
      SELECT coalesce(
        jsonb_agg(public.get_my_claim_coordination(x.claim_id)),
        '[]'::jsonb
      )
      FROM (
        SELECT rc.claim_id
        FROM public.claim_reconciliation_cases rc
        JOIN public.donation_claims c
          ON c.claim_id = rc.claim_id
         AND c.listing_id = rc.listing_id
        JOIN public.listings l
          ON l.listing_id = c.listing_id
         AND l.listing_id = rc.listing_id
         AND (
           rc.donation_id IS NULL
           OR l.donation_id = rc.donation_id
         )
         AND l.source_type = rc.source_type
        WHERE l.donation_id = p_donation
          AND l.source_type = 'DIRECT_DONATION'
        ORDER BY (rc.resolved_at IS NULL) DESC, rc.opened_at DESC
        LIMIT 10
      ) x
    )
  );
END
$function$;

COMMIT;

-- Read-only postflight (run after an approved deployment):
-- SELECT p.oid::regprocedure AS signature,
--        pg_get_userbyid(p.proowner) AS function_owner,
--        p.prorettype::regtype AS return_type,
--        p.provolatile = 's' AS is_stable,
--        p.prosecdef AS security_definer,
--        p.proconfig AS settings,
--        p.proacl AS grants,
--        has_function_privilege('authenticated', p.oid, 'EXECUTE') AS authenticated_can_execute,
--        has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_can_execute,
--        position('JOIN public.listings l ON l.listing_id = c.listing_id' IN
--                 pg_get_functiondef(p.oid)) > 0 AS explicit_listing_join_present,
--        position('c.claim_id = rc.claim_id' IN pg_get_functiondef(p.oid)) > 0 AS claim_binding_present,
--        position('c.listing_id = rc.listing_id' IN pg_get_functiondef(p.oid)) > 0 AS case_listing_binding_present,
--        position('rc.donation_id IS NULL' IN pg_get_functiondef(p.oid)) > 0 AS nullable_case_donation_supported,
--        position('l.donation_id = rc.donation_id' IN pg_get_functiondef(p.oid)) > 0 AS conflicting_case_donation_rejected,
--        position('l.source_type = rc.source_type' IN pg_get_functiondef(p.oid)) > 0 AS source_type_binding_present,
--        position('l.donation_id = p_donation' IN pg_get_functiondef(p.oid)) > 0 AS requested_donation_binding_present,
--        position('DONATION_OWNER_REQUIRED' IN pg_get_functiondef(p.oid)) > 0 AS owner_check_present
-- FROM pg_proc p
-- WHERE p.oid = to_regprocedure('public.get_my_donation_coordination(uuid)');
