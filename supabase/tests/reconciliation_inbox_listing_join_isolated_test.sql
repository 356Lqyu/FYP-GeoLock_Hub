-- Run only on a fresh disposable PostgreSQL instance with ON_ERROR_STOP enabled.
CREATE ROLE anon;
CREATE ROLE authenticated;
CREATE ROLE service_role;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;

CREATE TABLE public.user_profiles(user_id uuid PRIMARY KEY, role text NOT NULL);
CREATE TABLE public.donations(donation_id uuid PRIMARY KEY, donor_user_id uuid NOT NULL);
CREATE TABLE public.community_hubs(hub_id uuid PRIMARY KEY, admin_user_id uuid NOT NULL);
CREATE TABLE public.hub_batches(batch_id uuid PRIMARY KEY, hub_id uuid NOT NULL REFERENCES public.community_hubs);
CREATE TABLE public.listings(
  listing_id uuid PRIMARY KEY, source_type text NOT NULL,
  donation_id uuid REFERENCES public.donations, batch_id uuid REFERENCES public.hub_batches
);
CREATE TABLE public.donation_claims(
  claim_id uuid PRIMARY KEY, listing_id uuid NOT NULL REFERENCES public.listings, ngo_user_id uuid NOT NULL
);
CREATE TABLE public.claim_reconciliation_cases(
  case_id uuid PRIMARY KEY, claim_id uuid UNIQUE NOT NULL REFERENCES public.donation_claims,
  listing_id uuid NOT NULL REFERENCES public.listings, donation_id uuid,
  source_type text NOT NULL, case_status text NOT NULL, opened_at timestamptz NOT NULL
);

-- Exact reader body and ACL from the verified, pre-fix KLSEL catalog.
CREATE OR REPLACE FUNCTION public.get_my_reconciliation_cases()
 RETURNS TABLE(case_id uuid, claim_id uuid, listing_id uuid, donation_id uuid, source_type text, case_status text, opened_at timestamp with time zone)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
declare v_user uuid:=auth.uid(); v_role text;
begin
  if v_user is null then raise exception 'UNAUTHENTICATED'; end if;
  select p.role into v_role from public.user_profiles p where p.user_id=v_user;
  if v_role not in ('DONOR','NGO','HUB_ADMIN') then raise exception 'ROLE_REQUIRED'; end if;
  return query
  select rc.case_id,rc.claim_id,rc.listing_id,rc.donation_id,rc.source_type,rc.case_status,rc.opened_at
  from public.claim_reconciliation_cases rc
  join public.donation_claims c using(claim_id)
  join public.listings l using(listing_id)
  where rc.case_status in ('OPEN','MANUAL_REVIEW') and (
    (v_role='NGO' and c.ngo_user_id=v_user)
    or (v_role='DONOR' and l.source_type='DIRECT_DONATION' and exists(
      select 1 from public.donations d where d.donation_id=l.donation_id and d.donor_user_id=v_user))
    or (v_role='HUB_ADMIN' and l.source_type='HUB_BATCH' and exists(
      select 1 from public.hub_batches b join public.community_hubs h using(hub_id)
      where b.batch_id=l.batch_id and h.admin_user_id=v_user))
  ) order by rc.opened_at desc,rc.case_id;
end;
$function$;

REVOKE ALL ON FUNCTION public.get_my_reconciliation_cases() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_my_reconciliation_cases() TO authenticated, service_role;

CREATE FUNCTION public.fixture_id(n int) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
  SELECT lpad(n::text, 32, '0')::uuid
$$;
CREATE FUNCTION public.assert_inbox(expected int[], scenario text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  actual uuid[];
  expected_ids uuid[];
BEGIN
  SELECT coalesce(array_agg(r.case_id ORDER BY r.ordinality), '{}'::uuid[])
  INTO actual FROM public.get_my_reconciliation_cases() WITH ORDINALITY AS r;
  SELECT coalesce(array_agg(public.fixture_id(n) ORDER BY ordinality), '{}'::uuid[])
  INTO expected_ids FROM unnest(expected) WITH ORDINALITY AS e(n, ordinality);
  IF actual IS DISTINCT FROM expected_ids THEN
    RAISE EXCEPTION 'Inbox assertion failed (%)', scenario;
  END IF;
END;
$$;

CREATE TEMP TABLE inbox_baseline AS
SELECT oid, proowner, proacl, prosecdef, provolatile, proconfig, prosrc,
       pg_get_function_arguments(oid) AS arguments,
       pg_get_function_result(oid) AS return_type
FROM pg_proc WHERE oid = 'public.get_my_reconciliation_cases()'::regprocedure;

INSERT INTO public.user_profiles VALUES
  (fixture_id(1), 'DONOR'), (fixture_id(2), 'DONOR'), (fixture_id(3), 'DONOR'),
  (fixture_id(4), 'NGO'), (fixture_id(5), 'NGO'), (fixture_id(6), 'NGO'),
  (fixture_id(7), 'HUB_ADMIN'), (fixture_id(8), 'HUB_ADMIN'), (fixture_id(9), 'HUB_ADMIN');

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', fixture_id(1)::text, false);
DO $original$
BEGIN
  PERFORM * FROM public.get_my_reconciliation_cases();
  RAISE EXCEPTION 'Original definition did not fail';
EXCEPTION WHEN SQLSTATE '42702' THEN
  IF SQLERRM NOT LIKE 'common column name "listing_id" appears more than once%' THEN
    RAISE;
  END IF;
  RAISE NOTICE 'Verified original SQLSTATE 42702 even with zero cases';
END;
$original$;
RESET ROLE;

\ir ../migrations/20261123220000_fix_reconciliation_inbox_listing_join.sql

DO $contract$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN inbox_baseline b USING (oid)
    WHERE p.oid = 'public.get_my_reconciliation_cases()'::regprocedure
      AND ROW(p.proowner, p.proacl, p.prosecdef, p.provolatile, p.proconfig,
              pg_get_function_arguments(p.oid), pg_get_function_result(p.oid))
          IS NOT DISTINCT FROM
          ROW(b.proowner, b.proacl, b.prosecdef, b.provolatile, b.proconfig,
              b.arguments, b.return_type)
      AND replace(p.prosrc, chr(13), '') = replace(replace(b.prosrc, chr(13), ''),
        'join public.listings l using(listing_id)',
        'join public.listings l on l.listing_id = c.listing_id and l.listing_id = rc.listing_id')
  ) THEN RAISE EXCEPTION 'Function contract or unrelated body text changed'; END IF;
  IF NOT has_function_privilege('authenticated', 'public.get_my_reconciliation_cases()', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'public.get_my_reconciliation_cases()', 'EXECUTE')
     OR has_function_privilege('anon', 'public.get_my_reconciliation_cases()', 'EXECUTE')
  THEN RAISE EXCEPTION 'Effective reader grants changed'; END IF;
END;
$contract$;

SET ROLE authenticated;
SELECT assert_inbox(ARRAY[]::int[], 'empty database returns an empty result');
RESET ROLE;

INSERT INTO public.donations VALUES
  (fixture_id(11),fixture_id(1)), (fixture_id(12),fixture_id(2));
INSERT INTO public.community_hubs VALUES
  (fixture_id(13),fixture_id(7)), (fixture_id(14),fixture_id(8));
INSERT INTO public.hub_batches VALUES
  (fixture_id(15),fixture_id(13)), (fixture_id(16),fixture_id(14));
INSERT INTO public.listings VALUES
  (fixture_id(21),'DIRECT_DONATION',fixture_id(11),NULL),
  (fixture_id(22),'DIRECT_DONATION',fixture_id(12),NULL),
  (fixture_id(23),'HUB_BATCH',NULL,fixture_id(15)),
  (fixture_id(24),'HUB_BATCH',NULL,fixture_id(16));
INSERT INTO public.donation_claims
SELECT fixture_id(claim), fixture_id(listing), fixture_id(ngo)
FROM (VALUES (31,21,4),(32,21,4),(33,21,4),(34,22,5),(35,23,4),
             (36,24,5),(37,21,4),(38,22,5),(39,23,4)) AS x(claim,listing,ngo);
INSERT INTO public.claim_reconciliation_cases
SELECT fixture_id(case_num), fixture_id(claim), fixture_id(listing), fixture_id(donation),
       source_type, case_status, opened_at::timestamptz
FROM (VALUES
  (41,31,21,11,'DIRECT_DONATION','OPEN','2026-11-22 11:00:00+00'),
  (42,32,21,11,'DIRECT_DONATION','MANUAL_REVIEW','2026-11-23 12:00:00+00'),
  (43,33,21,11,'DIRECT_DONATION','OPEN','2026-11-23 12:00:00+00'),
  (44,34,22,12,'DIRECT_DONATION','OPEN','2026-11-23 13:00:00+00'),
  (45,35,23,NULL,'HUB_BATCH','OPEN','2026-11-23 14:00:00+00'),
  (46,36,24,NULL,'HUB_BATCH','MANUAL_REVIEW','2026-11-23 15:00:00+00'),
  (47,37,21,11,'DIRECT_DONATION','RESOLVED_COLLECTED','2026-11-23 16:00:00+00'),
  (48,38,21,11,'DIRECT_DONATION','OPEN','2026-11-23 17:00:00+00'),
  (49,39,23,NULL,'HUB_BATCH','RESOLVED_RELEASED','2026-11-23 18:00:00+00')
) AS x(case_num,claim,listing,donation,source_type,case_status,opened_at);

SET ROLE authenticated;
SELECT assert_inbox(ARRAY[42,43,41], 'donor scope, both open states and ordering with a date tie');
SELECT set_config('request.jwt.claim.sub', fixture_id(2)::text, false);
SELECT assert_inbox(ARRAY[44], 'other donor cannot see first donor or mismatched case');
SELECT set_config('request.jwt.claim.sub', fixture_id(3)::text, false);
SELECT assert_inbox(ARRAY[]::int[], 'unrelated donor');
SELECT set_config('request.jwt.claim.sub', fixture_id(4)::text, false);
SELECT assert_inbox(ARRAY[45,42,43,41], 'NGO sees own direct and batch claims');
SELECT set_config('request.jwt.claim.sub', fixture_id(5)::text, false);
SELECT assert_inbox(ARRAY[46,44], 'other NGO excludes inconsistent case');
SELECT set_config('request.jwt.claim.sub', fixture_id(6)::text, false);
SELECT assert_inbox(ARRAY[]::int[], 'unrelated NGO');
SELECT set_config('request.jwt.claim.sub', fixture_id(7)::text, false);
SELECT assert_inbox(ARRAY[45], 'Hub admin sees own batch only');
SELECT set_config('request.jwt.claim.sub', fixture_id(8)::text, false);
SELECT assert_inbox(ARRAY[46], 'other Hub admin sees own manual review only');
SELECT set_config('request.jwt.claim.sub', fixture_id(9)::text, false);
SELECT assert_inbox(ARRAY[]::int[], 'unrelated Hub admin');
RESET ROLE;

SET ROLE anon;
DO $anonymous$
BEGIN
  PERFORM * FROM public.get_my_reconciliation_cases();
  RAISE EXCEPTION 'Anonymous execution was allowed';
EXCEPTION WHEN insufficient_privilege THEN NULL;
END;
$anonymous$;
RESET ROLE;

SELECT 'PASS: baseline failure, corrected scope, ordering, metadata and ACL' AS result;
