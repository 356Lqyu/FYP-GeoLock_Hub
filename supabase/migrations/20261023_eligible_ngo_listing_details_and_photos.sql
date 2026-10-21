-- Allow currently eligible NGOs to view the same listing photos that their
-- protected discovery result permits, while keeping private Storage access
-- bound to the live road-eligibility cache. Empty photo sets are valid.
begin;

do $$
begin
  if to_regprocedure('public.geolock_road_eligible_km(uuid,uuid)') is null
     or to_regprocedure('public.discover_eligible_listing_cards()') is null
     or to_regprocedure('public.get_eligible_listing_constituents(uuid)') is null
     or to_regprocedure('public.get_donation_images(uuid)') is null
     or to_regprocedure('public.get_batch_images(uuid)') is null
     or to_regprocedure('public.can_read_geolock_donation_image(text)') is null
     or to_regprocedure('public.can_read_geolock_batch_image(text)') is null then
    raise exception 'ELIGIBLE_LISTING_PHOTO_DEPENDENCY_MISSING';
  end if;
  if to_regclass('public.listings') is null
     or to_regclass('public.donations') is null
     or to_regclass('public.donation_images') is null
     or to_regclass('public.hub_batches') is null
     or to_regclass('public.hub_batch_images') is null
     or to_regclass('public.hub_batch_members') is null
     or to_regclass('public.ngo_profiles') is null then
    raise exception 'ELIGIBLE_LISTING_PHOTO_TABLE_MISSING';
  end if;
end;
$$;

-- Private donation image reads remain available to the donor, authorized hub
-- administrators, and NGOs with a valid claim. Also allow an NGO to view a
-- currently AVAILABLE listing only when the authoritative directed-road cache
-- says that NGO is eligible. No straight-line fallback is used here.
create or replace function public.can_read_geolock_donation_image(p_path text)
returns boolean language sql security definer
set search_path=pg_catalog,public,extensions,pg_temp
as $$
  select auth.uid() is not null and exists(
    select 1 from public.donation_images i
    join public.donations d using(donation_id)
    where i.storage_path=p_path and (
      d.donor_user_id=auth.uid()
      or exists(
        select 1 from public.ngo_profiles n
        join public.listings l on l.donation_id=d.donation_id
          and l.source_type='DIRECT_DONATION'
        where n.user_id=auth.uid() and n.active_flag
          and n.location_verified_at is not null
          and exists(select 1 from public.donation_claims c
            left join public.claim_leases le using(claim_id)
            where c.listing_id=l.listing_id and c.ngo_user_id=auth.uid()
              and (c.claim_status in ('COMPLETED','RECONCILIATION_REQUIRED')
                or (c.claim_status='ACTIVE' and le.lease_status='ACTIVE'
                    and le.expires_at>clock_timestamp())))
          and public.geolock_road_eligible_km(n.user_id,l.listing_id) is not null
      )
      or exists(
        select 1 from public.ngo_profiles n
        join public.listings l on l.donation_id=d.donation_id
          and l.source_type='DIRECT_DONATION'
        where n.user_id=auth.uid() and n.active_flag
          and n.location_verified_at is not null
          and l.listing_status='AVAILABLE'
          and (l.listing_expires_at is null or l.listing_expires_at>clock_timestamp())
          and d.donation_status='READY_FOR_PICKUP'
          and public.geolock_road_eligible_km(n.user_id,l.listing_id) is not null
      )
      or exists(
        select 1 from public.ngo_profiles n
        join public.hub_batch_members m on m.donation_id=d.donation_id
          and m.membership_status='ACTIVE'
        join public.listings l on l.batch_id=m.batch_id and l.source_type='HUB_BATCH'
        join public.hub_batches b on b.batch_id=m.batch_id and b.batch_status='PUBLISHED'
        where n.user_id=auth.uid() and n.active_flag
          and n.location_verified_at is not null
          and l.listing_status='AVAILABLE'
          and (l.listing_expires_at is null or l.listing_expires_at>clock_timestamp())
          and public.geolock_road_eligible_km(n.user_id,l.listing_id) is not null
      )
      -- Preserve claimant access after a batch listing leaves AVAILABLE.
      or exists(
        select 1 from public.ngo_profiles n
        join public.coordination_config cfg on cfg.singleton
        join public.hub_batch_members m on m.donation_id=d.donation_id
          and m.membership_status='ACTIVE'
        join public.listings l on l.batch_id=m.batch_id and l.source_type='HUB_BATCH'
        join public.hub_batches b on b.batch_id=m.batch_id and b.batch_status='PUBLISHED'
        where n.user_id=auth.uid() and n.active_flag
          and n.location_verified_at is not null
          and exists(select 1 from public.donation_claims c
            left join public.claim_leases le using(claim_id)
            where c.listing_id=l.listing_id and c.ngo_user_id=auth.uid()
              and (c.claim_status in ('COMPLETED','RECONCILIATION_REQUIRED')
                or (c.claim_status='ACTIVE' and le.lease_status='ACTIVE'
                    and le.expires_at>clock_timestamp())))
          and public.geolock_road_eligible_km(n.user_id,l.listing_id) is not null
      )
      or exists(select 1 from public.hub_reservations r
        join public.community_hubs h using(hub_id)
        where r.donation_id=d.donation_id and h.admin_user_id=auth.uid()
          and r.reservation_status='ACTIVE' and r.expires_at>clock_timestamp())
      or exists(select 1 from public.hub_inventory hi
        join public.community_hubs h using(hub_id)
        where hi.donation_id=d.donation_id and h.admin_user_id=auth.uid())
    )
  );
$$;

create or replace function public.can_read_geolock_batch_image(p_path text)
returns boolean language sql security definer
set search_path=pg_catalog,public,extensions,pg_temp
as $$
  select auth.uid() is not null and exists(
    select 1 from public.hub_batch_images i
    join public.hub_batches b using(batch_id)
    where i.storage_path=p_path and (
      exists(select 1 from public.community_hubs h
        where h.hub_id=b.hub_id and h.admin_user_id=auth.uid())
      or exists(
        select 1 from public.ngo_profiles n
        join public.listings l on l.batch_id=b.batch_id and l.source_type='HUB_BATCH'
        where n.user_id=auth.uid() and n.active_flag
          and n.location_verified_at is not null
          and exists(select 1 from public.donation_claims c
            left join public.claim_leases le using(claim_id)
            where c.listing_id=l.listing_id and c.ngo_user_id=auth.uid()
              and (c.claim_status in ('COMPLETED','RECONCILIATION_REQUIRED')
                or (c.claim_status='ACTIVE' and le.lease_status='ACTIVE'
                    and le.expires_at>clock_timestamp())))
          and public.geolock_road_eligible_km(n.user_id,l.listing_id) is not null
      )
      or exists(
        select 1 from public.ngo_profiles n
        join public.listings l on l.batch_id=b.batch_id and l.source_type='HUB_BATCH'
        where n.user_id=auth.uid() and n.active_flag
          and n.location_verified_at is not null
          and l.listing_status='AVAILABLE'
          and (l.listing_expires_at is null or l.listing_expires_at>clock_timestamp())
          and b.batch_status='PUBLISHED'
          and public.geolock_road_eligible_km(n.user_id,l.listing_id) is not null
      )
    )
  );
$$;

-- Preserve the existing RPC signatures and grants. Return an empty set when a
-- caller has no readable photos; never make photo presence a prerequisite for
-- opening otherwise-authorized listing details.
create or replace function public.get_donation_images(p_donation uuid)
returns table(image_id uuid,storage_path text,display_order smallint,is_cover boolean,content_type text)
language plpgsql volatile security definer
set search_path=pg_catalog,public,pg_temp
as $$
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  return query select i.image_id,i.storage_path,i.display_order,i.display_order=1,i.content_type
    from public.donation_images i
   where i.donation_id=p_donation
     and public.can_read_geolock_donation_image(i.storage_path)
   order by i.display_order;
end;
$$;

create or replace function public.get_batch_images(p_batch uuid)
returns table(image_id uuid,storage_path text,is_cover boolean,content_type text)
language plpgsql volatile security definer
set search_path=pg_catalog,public,pg_temp
as $$
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  return query select i.image_id,i.storage_path,i.is_primary,i.content_type
    from public.hub_batch_images i
   where i.batch_id=p_batch
     and public.can_read_geolock_batch_image(i.storage_path)
   order by i.created_at,i.image_id;
end;
$$;

-- Keep the deployed card contract and all eligibility filters. Only expose an
-- image path after the same directed-road eligibility check used for discovery.
create or replace function public.discover_eligible_listing_cards()
returns table(listing_id uuid,source_type text,title text,listing_weight_kg numeric,
  listing_created_at timestamptz,collection_path text,distance_m double precision,
  routing_status text,primary_image_path text,batch_id uuid,donation_id uuid)
language plpgsql volatile security definer
set search_path=pg_catalog,public,extensions,pg_temp
as $$
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
    l.batch_id,l.donation_id
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
    and ((l.source_type='DIRECT_DONATION' and d.donation_status='READY_FOR_PICKUP')
      or (l.source_type='HUB_BATCH' and b.batch_status='PUBLISHED'))
  order by l.created_at desc;
end;
$$;

-- This protected detail RPC already rechecks the listing's exact cached road
-- eligibility. Return only image paths authorized by the same read helper.
create or replace function public.get_eligible_listing_constituents(p_listing uuid)
returns table(donation_id uuid,title text,total_weight_kg numeric,donation_status text,
  primary_image_path text)
language plpgsql volatile security definer
set search_path=pg_catalog,public,extensions,pg_temp
as $$
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
       where d.donation_id=l.donation_id and d.donation_status='READY_FOR_PICKUP'))
       or (l.source_type='HUB_BATCH' and exists(select 1 from public.hub_batches b
         where b.batch_id=l.batch_id and b.batch_status='PUBLISHED')));
  if not found then raise exception 'LISTING_NOT_ELIGIBLE'; end if;
  return query
  select d.donation_id,d.title,d.total_weight_kg,d.donation_status,
    case when public.can_read_geolock_donation_image(i.storage_path) then i.storage_path end
  from public.donations d
  left join lateral(select x.storage_path from public.donation_images x
    where x.donation_id=d.donation_id and x.display_order=1 limit 1) i on true
  where (v_listing.source_type='DIRECT_DONATION' and d.donation_id=v_listing.donation_id)
     or (v_listing.source_type='HUB_BATCH' and exists(select 1 from public.hub_batch_members m
       where m.batch_id=v_listing.batch_id and m.donation_id=d.donation_id
         and m.membership_status='ACTIVE'))
  order by d.created_at,d.donation_id;
end;
$$;

commit;
