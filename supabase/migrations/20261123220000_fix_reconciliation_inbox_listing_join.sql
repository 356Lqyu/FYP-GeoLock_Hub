BEGIN;

-- Apply only to the reviewed NEW KLSEL reader. CREATE OR REPLACE preserves
-- the existing function identity, owner and grants.
DO $baseline$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_proc p
    WHERE p.oid = pg_catalog.to_regprocedure('public.get_my_reconciliation_cases()')
      AND pg_catalog.md5(pg_catalog.btrim(pg_catalog.regexp_replace(
        p.prosrc, '[[:space:]]+', ' ', 'g'
      ))) = '605bf2be905a87fe9151ae37b4ccf6df'
      AND pg_catalog.pg_get_userbyid(p.proowner) = 'postgres'
      AND p.prosecdef AND p.provolatile = 's'
      AND p.proconfig = ARRAY['search_path=pg_catalog, public, pg_temp']
  ) THEN
    RAISE EXCEPTION 'Reconciliation inbox definition differs from the reviewed baseline';
  END IF;
END;
$baseline$;

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
  join public.listings l on l.listing_id = c.listing_id and l.listing_id = rc.listing_id
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

COMMIT;
