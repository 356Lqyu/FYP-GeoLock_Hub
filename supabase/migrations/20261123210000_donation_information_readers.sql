-- Additive readers based on the verified NEW KLSEL catalog.
BEGIN;

CREATE FUNCTION public.discover_eligible_listing_cards_v2()
 RETURNS TABLE(listing_id uuid, source_type text, title text, listing_weight_kg numeric, listing_created_at timestamp with time zone, collection_path text, distance_m double precision, routing_status text, primary_image_path text, batch_id uuid, donation_id uuid, listing_total_item_quantity bigint)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'extensions', 'pg_temp'
AS $function$
declare v_ngo public.ngo_profiles%rowtype;
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  select * into v_ngo from public.ngo_profiles
   where user_id=auth.uid() and active_flag;
  if not found or v_ngo.location_verified_at is null then return; end if;
  return query
  select l.listing_id,l.source_type,
    case when l.source_type='DIRECT_DONATION' then d.title else 'Community Hub Batch' end,
    l.listing_weight_kg,l.created_at,
    case when l.source_type='DIRECT_DONATION' then d.collection_path else 'HUB_COLLECTION' end,
    public.geolock_road_eligible_km(v_ngo.user_id,l.listing_id)*1000,
    'READY'::text,
    case
      when l.source_type='DIRECT_DONATION'
        and public.can_read_geolock_donation_image(di.storage_path) then di.storage_path
      when l.source_type='HUB_BATCH'
        and public.can_read_geolock_batch_image(bi.storage_path) then bi.storage_path
      when l.source_type='HUB_BATCH'
        and public.can_read_geolock_donation_image(member_img.storage_path) then member_img.storage_path
      else null
    end,
    l.batch_id,l.donation_id,
    case l.source_type
      when 'DIRECT_DONATION' then (
        select sum(i.quantity) from public.donation_items i
        where i.donation_id = l.donation_id
      )
      when 'HUB_BATCH' then (
        select case when count(member.total_quantity) = count(*)
                    then sum(member.total_quantity)::bigint end
        from public.hub_batch_members m
        cross join lateral (
          select sum(i.quantity) as total_quantity
          from public.donation_items i where i.donation_id = m.donation_id
        ) member
        where m.batch_id = l.batch_id and m.membership_status = 'ACTIVE'
      )
    end
  from public.listings l
  join public.coordination_config cfg on cfg.singleton
  left join public.donations d on d.donation_id=l.donation_id
  left join public.hub_batches b on b.batch_id=l.batch_id
  left join lateral(select i.storage_path from public.donation_images i
    where i.donation_id=d.donation_id and i.display_order=1 limit 1) di on true
  left join lateral(select i.storage_path from public.hub_batch_images i
    where i.batch_id=b.batch_id and i.is_primary limit 1) bi on true
  left join lateral(select i.storage_path from public.hub_batch_members m
    join public.donation_images i on i.donation_id=m.donation_id and i.display_order=1
    join public.donations md on md.donation_id=m.donation_id
    where m.batch_id=b.batch_id and m.membership_status='ACTIVE'
    order by md.created_at,md.donation_id limit 1) member_img on true
  where l.listing_status='AVAILABLE'
    and (l.listing_expires_at is null or l.listing_expires_at>clock_timestamp())
    and public.geolock_road_eligible_km(v_ngo.user_id,l.listing_id) is not null
    and ((l.source_type='DIRECT_DONATION' and d.donation_status='AVAILABLE')
      or (l.source_type='HUB_BATCH' and b.batch_status='PUBLISHED'))
  order by l.created_at desc;
end;
$function$;

CREATE FUNCTION public.get_eligible_listing_constituents_v2(p_listing uuid)
 RETURNS TABLE(donation_id uuid, title text, total_weight_kg numeric, donation_status text, primary_image_path text, donation_description text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'extensions', 'pg_temp'
AS $function$
declare v_ngo public.ngo_profiles%rowtype; v_listing public.listings%rowtype;
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  select * into v_ngo from public.ngo_profiles where user_id=auth.uid() and active_flag;
  if not found or v_ngo.location_verified_at is null then raise exception 'VERIFIED_NGO_ONLY'; end if;
  select l.* into v_listing from public.listings l
   where l.listing_id=p_listing and l.listing_status='AVAILABLE'
     and (l.listing_expires_at is null or l.listing_expires_at>clock_timestamp())
     and public.geolock_road_eligible_km(v_ngo.user_id,l.listing_id) is not null
     and ((l.source_type='DIRECT_DONATION' and exists(select 1 from public.donations d
       where d.donation_id=l.donation_id and d.donation_status='AVAILABLE'))
       or (l.source_type='HUB_BATCH' and exists(select 1 from public.hub_batches b
         where b.batch_id=l.batch_id and b.batch_status='PUBLISHED')));
  if not found then raise exception 'LISTING_NOT_ELIGIBLE'; end if;
  return query
  select d.donation_id,d.title,d.total_weight_kg,d.donation_status,
    case when public.can_read_geolock_donation_image(i.storage_path) then i.storage_path end,
    case when d.description ~ '[^[:space:]]' then d.description end
  from public.donations d
  left join lateral(select x.storage_path from public.donation_images x
    where x.donation_id=d.donation_id and x.display_order=1 limit 1) i on true
  join public.listings l on l.listing_id = p_listing
  join public.ngo_profiles n on n.user_id = auth.uid()
  where n.active_flag and n.location_verified_at is not null
    and l.listing_status = 'AVAILABLE'
    and (l.listing_expires_at is null or l.listing_expires_at > clock_timestamp())
    and public.geolock_road_eligible_km(n.user_id, l.listing_id) is not null
    and (
      (l.source_type = 'DIRECT_DONATION' and d.donation_id = l.donation_id
        and d.donation_status = 'AVAILABLE')
      or (l.source_type = 'HUB_BATCH' and exists (
        select 1 from public.hub_batches b
        join public.hub_batch_members m on m.batch_id = b.batch_id
        where b.batch_id = l.batch_id and b.batch_status = 'PUBLISHED'
          and m.donation_id = d.donation_id and m.membership_status = 'ACTIVE'
      ))
    )
  order by d.created_at,d.donation_id;
end;
$function$;

CREATE FUNCTION public.get_claimed_listing_constituents_v2(p_claim uuid)
 RETURNS TABLE(donation_id uuid, title text, total_weight_kg numeric, donation_status text, primary_image_path text, batch_cover_path text, donation_description text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
declare v_listing public.listings%rowtype;
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  select l.* into v_listing from public.donation_claims c
  join public.listings l using(listing_id)
  where c.claim_id=p_claim and c.ngo_user_id=auth.uid()
    and (c.claim_status in ('COMPLETED','RECONCILIATION_REQUIRED')
      or (c.claim_status='ACTIVE' and exists(select 1 from public.claim_leases le
          where le.claim_id=c.claim_id and le.lease_status='ACTIVE'
            and le.expires_at>clock_timestamp())));
  if not found then raise exception 'CLAIM_NOT_FOUND_OR_FORBIDDEN'; end if;
  return query
  -- Keep the legacy constituent scope. Description has its own active-claim gate.
  with description_access as materialized (
    select exists (
      select 1 from public.donation_claims c
      join public.claim_leases le using (claim_id)
      join public.listings l using (listing_id)
      join public.ngo_profiles n on n.user_id = c.ngo_user_id
      where c.claim_id = p_claim and c.ngo_user_id = auth.uid() and n.active_flag
        and c.claim_status = 'ACTIVE' and le.lease_status = 'ACTIVE'
        and le.expires_at > clock_timestamp()
        and l.listing_id = v_listing.listing_id and l.listing_status = 'CLAIMED'
        and (l.listing_expires_at is null or l.listing_expires_at > clock_timestamp())
    ) as allowed
  )
  select d.donation_id,d.title,d.total_weight_kg,d.donation_status,di.storage_path,bi.storage_path,
    case when description_access.allowed and d.description ~ '[^[:space:]]' then d.description end
  from public.donations d
  cross join description_access
  left join lateral(select i.storage_path from public.donation_images i
    where i.donation_id=d.donation_id and i.display_order=1 limit 1) di on true
  left join lateral(select i.storage_path from public.hub_batch_images i
    where i.batch_id=v_listing.batch_id and i.is_primary limit 1) bi on true
  where (v_listing.source_type='DIRECT_DONATION' and d.donation_id=v_listing.donation_id)
     or (v_listing.source_type='HUB_BATCH' and exists(
       select 1 from public.hub_batch_members m where m.batch_id=v_listing.batch_id
         and m.donation_id=d.donation_id and m.membership_status='ACTIVE'))
  order by d.created_at,d.donation_id;
end;
$function$;

CREATE FUNCTION public.get_my_donation_dashboard_v3()
 RETURNS TABLE(donation_id uuid, title text, donation_status text, collection_path text, total_weight_kg numeric, created_at timestamp with time zone, hub_name text, reservation_status text, reservation_effective_status text, reservation_expires_at timestamp with time zone, listing_status text, receipt_status text, inventory_status text, item_count bigint, primary_image_path text, total_item_quantity bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  if not exists(select 1 from public.donor_profiles dp where dp.user_id=auth.uid())
  then raise exception 'DONOR_ONLY'; end if;
  return query
  select d.donation_id,d.title,d.donation_status,d.collection_path,
    d.total_weight_kg,d.created_at,latest.hub_name,latest.reservation_status,
    case when latest.reservation_status='ACTIVE'
      and latest.reservation_expires_at<=statement_timestamp() then 'EXPIRED'
      else latest.reservation_status end,
    latest.reservation_expires_at,l.listing_status,latest.receipt_status,
    hi.inventory_status,
    items.item_count,
    img.storage_path,
    items.total_quantity
  from public.donations d
  cross join lateral (
    select count(*) as item_count, sum(di.quantity) as total_quantity
    from public.donation_items di where di.donation_id = d.donation_id
  ) items
  left join lateral (
    select dl.* from public.listings dl
    where (dl.source_type='DIRECT_DONATION' and dl.donation_id=d.donation_id)
      or (dl.source_type='HUB_BATCH' and exists(select 1 from public.hub_batch_members m
        where m.batch_id=dl.batch_id and m.donation_id=d.donation_id and m.membership_status='ACTIVE'))
    limit 1
  ) l on true
  left join public.hub_inventory hi on hi.donation_id=d.donation_id
  left join lateral (
    select h.hub_name,r.reservation_status,r.expires_at as reservation_expires_at,
      hr.receipt_status
    from public.hub_reservations r join public.community_hubs h using(hub_id)
    left join public.hub_receipts hr on hr.reservation_id=r.reservation_id
    where r.donation_id=d.donation_id
    order by r.reserved_at desc,r.reservation_id desc limit 1
  ) latest on true
  left join lateral (
    select i.storage_path from public.donation_images i
    where i.donation_id=d.donation_id and i.owner_user_id=auth.uid() and i.is_primary
    limit 1
  ) img on true
  where d.donor_user_id=auth.uid()
  order by d.created_at desc,d.donation_id;
end;
$function$;

ALTER FUNCTION public.discover_eligible_listing_cards_v2() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.discover_eligible_listing_cards_v2() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.discover_eligible_listing_cards_v2() TO authenticated;

ALTER FUNCTION public.get_eligible_listing_constituents_v2(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.get_eligible_listing_constituents_v2(uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_eligible_listing_constituents_v2(uuid) TO authenticated;

ALTER FUNCTION public.get_claimed_listing_constituents_v2(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.get_claimed_listing_constituents_v2(uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_claimed_listing_constituents_v2(uuid) TO authenticated;

ALTER FUNCTION public.get_my_donation_dashboard_v3() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.get_my_donation_dashboard_v3() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_my_donation_dashboard_v3() TO authenticated;

-- Fail atomically if inherited privileges defeat the explicit grants.
DO $permissions$
DECLARE
  reader regprocedure;
BEGIN
  FOREACH reader IN ARRAY ARRAY[
    'public.discover_eligible_listing_cards_v2()'::regprocedure,
    'public.get_eligible_listing_constituents_v2(uuid)'::regprocedure,
    'public.get_claimed_listing_constituents_v2(uuid)'::regprocedure,
    'public.get_my_donation_dashboard_v3()'::regprocedure
  ] LOOP
    IF pg_catalog.has_function_privilege('anon', reader::oid, 'EXECUTE')
      OR pg_catalog.has_function_privilege('service_role', reader::oid, 'EXECUTE')
      OR NOT pg_catalog.has_function_privilege('authenticated', reader::oid, 'EXECUTE')
      OR NOT pg_catalog.has_schema_privilege('authenticated', 'public', 'USAGE') THEN
      RAISE EXCEPTION 'Unexpected API permissions on %', reader;
    END IF;
  END LOOP;
END;
$permissions$;

NOTIFY pgrst, 'reload schema';
COMMIT;
