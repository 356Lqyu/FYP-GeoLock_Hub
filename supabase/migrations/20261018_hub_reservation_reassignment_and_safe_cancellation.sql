-- GeoLock Hub: scoped hub reservation reassignment and safe donor cancellation.
-- Prepared against the deployed V3 inventory dated 2026-10-18. Review and
-- apply only to an isolated development project after running the read-only
-- preflight. This file has NOT been executed.
--
-- Preserves the deployed RPC identities and the 120-minute hub reservation
-- configuration. NGO claim/lease/recovery/reconciliation RPCs are untouched.

begin;

-- Donor-owned candidate lookup. An assigned donation is reassignable only if
-- it has no physical custody and no non-expired active reservation. Database
-- time, not a Flutter device clock, determines effective expiry.
create or replace function public.get_eligible_hubs(p_donation uuid)
returns table(
  hub_id uuid,
  hub_name text,
  address_text text,
  latitude double precision,
  longitude double precision,
  capacity_kg numeric,
  available_capacity_kg numeric
)
language plpgsql stable security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_donation public.donations%rowtype; v_latest public.hub_reservations%rowtype;
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  select d.* into v_donation
  from public.donations d
  where d.donation_id = p_donation and d.donor_user_id = auth.uid();
  if not found then raise exception 'DONATION_NOT_FOUND_OR_FORBIDDEN'; end if;

  if v_donation.collection_path <> 'HUB_COLLECTION'
     or v_donation.donation_status not in ('VALIDATED','HUB_ASSIGNED') then
    raise exception 'DONATION_NOT_HUB_ELIGIBLE';
  end if;
  if v_donation.donation_status='HUB_ASSIGNED' then
    select * into v_latest from public.hub_reservations r
    where r.donation_id=p_donation
    order by r.reserved_at desc,r.reservation_id desc limit 1;
    if v_latest.reservation_id is null or exists(select 1 from public.hub_reservations r
        where r.donation_id=p_donation and r.reservation_status in ('RELEASED','CONSUMED'))
      or exists(select 1 from public.hub_reservations r where r.donation_id=p_donation
          and r.reservation_status='EXPIRED' and r.expires_at>clock_timestamp())
      or (select count(*) from public.hub_reservations r
          where r.donation_id=p_donation and r.reservation_status='ACTIVE')>1
      or (v_latest.reservation_status='EXPIRED' and exists(
          select 1 from public.hub_reservations r where r.donation_id=p_donation
            and r.reservation_status='ACTIVE'))
      or not (
      v_latest.reservation_status='EXPIRED'
      or (v_latest.reservation_status='ACTIVE'
          and v_latest.expires_at<=statement_timestamp())
    ) then raise exception 'HUB_RESERVATION_NOT_EXPIRED'; end if;
  end if;
  if exists (select 1 from public.hub_receipts r where r.donation_id=p_donation)
     or exists (select 1 from public.hub_inventory i where i.donation_id=p_donation)
     or exists (select 1 from public.hub_batch_members m
                where m.donation_id=p_donation and m.membership_status='ACTIVE') then
    raise exception 'DONATION_HAS_PHYSICAL_CUSTODY';
  end if;
  if exists (select 1 from public.hub_reservations r
             where r.donation_id=p_donation
               and r.reservation_status='ACTIVE'
               and r.expires_at > statement_timestamp()) then
    raise exception 'HUB_RESERVATION_STILL_ACTIVE';
  end if;

  return query
  with hub_usage as (
    select h.hub_id,
      coalesce((select sum(hr.received_weight_kg)
        from public.hub_inventory hi join public.hub_receipts hr using(donation_id)
        where hi.hub_id=h.hub_id
          and hi.inventory_status in ('STORED','BATCHED','RECONCILIATION_REQUIRED')),0)
      + coalesce((select sum(r.reserved_weight_kg)
        from public.hub_reservations r
        where r.hub_id=h.hub_id and r.reservation_status='ACTIVE'
          and r.expires_at > statement_timestamp()
          and not exists(select 1 from public.hub_receipts hr
                         where hr.reservation_id=r.reservation_id)),0) as used_kg
    from public.community_hubs h
  )
  select h.hub_id,h.hub_name,h.address_text,h.latitude,h.longitude,
         h.capacity_kg,greatest(0,h.capacity_kg-u.used_kg)::numeric
  from public.community_hubs h join hub_usage u using(hub_id)
  where h.active_flag
    and u.used_kg+v_donation.total_weight_kg<=h.capacity_kg
    and not exists (
      select 1 from public.donation_items i
      where i.donation_id=p_donation
        and not exists(select 1 from public.hub_accepted_categories a
                       where a.hub_id=h.hub_id and a.category_id=i.category_id)
    )
  order by h.hub_name;
end;
$$;

-- Keep the deployed return shape. The status field is effective status, so an
-- expired ACTIVE row is never displayed as awaiting receipt. Persisted status
-- remains available in donor details/history for audit purposes.
create or replace function public.get_my_hub_reservations(p_hub uuid)
returns table(reservation_id uuid,donation_id uuid,title text,
  reserved_weight_kg numeric,status text,expires_at timestamptz)
language plpgsql stable security definer
set search_path = pg_catalog, public, pg_temp
as $$
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  if not exists(select 1 from public.community_hubs h
    where h.hub_id=p_hub and h.admin_user_id=auth.uid()) then
    raise exception 'HUB_NOT_FOUND_OR_FORBIDDEN';
  end if;
  return query select r.reservation_id,r.donation_id,d.title,r.reserved_weight_kg,
    case when r.reservation_status='ACTIVE'
      and r.expires_at<=statement_timestamp() then 'EXPIRED'
      else r.reservation_status end,r.expires_at
  from public.hub_reservations r join public.donations d using(donation_id)
  where r.hub_id=p_hub order by r.reserved_at desc,r.reservation_id desc;
end;
$$;

-- Detailed donor read adds an effective_status field per reservation while
-- preserving stored status/history. It is a computed view, not a row update.
create or replace function public.get_my_donation_detail(p_donation uuid)
returns jsonb language plpgsql stable security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare v_result jsonb;
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  if not exists(select 1 from public.donor_profiles dp where dp.user_id=auth.uid())
  then raise exception 'DONOR_ONLY'; end if;
  select jsonb_build_object(
    'donation_id',d.donation_id,'title',d.title,'description',d.description,
    'status',d.donation_status,'donation_status',d.donation_status,
    'collection_path',d.collection_path,'total_weight_kg',d.total_weight_kg,
    'pickup_address',d.pickup_address,'latitude',d.latitude,'longitude',d.longitude,
    'created_at',d.created_at,'updated_at',d.updated_at,
    'availability_start',d.availability_start,'availability_end',d.availability_end,
    'listing_status',l.listing_status,
    'road_node_status',case when l.listing_id is null then null
      when l.pickup_road_node_id is null then 'PENDING_NODE' else 'UNVERIFIED' end,
    'items',coalesce((select jsonb_agg(jsonb_build_object(
      'item_id',i.item_id,'category_id',i.category_id,'category',c.category_name,
      'item_name',i.item_name,'description',i.description,'quantity',i.quantity,
      'unit_label',i.unit_label,'unit_weight_kg',i.unit_weight_kg,
      'item_condition',i.item_condition) order by i.created_at,i.item_id)
      from public.donation_items i join public.donation_categories c using(category_id)
      where i.donation_id=d.donation_id),'[]'::jsonb),
    'hub_reservations',coalesce((select jsonb_agg(jsonb_build_object(
      'reservation_id',r.reservation_id,'hub_id',r.hub_id,'hub_name',h.hub_name,
      'status',r.reservation_status,
      'effective_status',case when r.reservation_status='ACTIVE'
        and r.expires_at<=statement_timestamp() then 'EXPIRED'
        else r.reservation_status end,
      'reserved_weight_kg',r.reserved_weight_kg,'reserved_at',r.reserved_at,
      'expires_at',r.expires_at,'receipt_status',hr.receipt_status,
      'received_weight_kg',hr.received_weight_kg,'received_at',hr.received_at)
      order by r.reserved_at desc,r.reservation_id desc)
      from public.hub_reservations r join public.community_hubs h using(hub_id)
      left join public.hub_receipts hr on hr.reservation_id=r.reservation_id
      where r.donation_id=d.donation_id),'[]'::jsonb)
  ) into v_result
  from public.donations d
  left join public.listings l on l.donation_id=d.donation_id
    and l.source_type='DIRECT_DONATION'
  where d.donation_id=p_donation and d.donor_user_id=auth.uid();
  return v_result;
end;
$$;

-- New list read for donor dashboard/history. The existing dashboard RPC has a
-- TABLE return type that cannot be extended with CREATE OR REPLACE; this
-- version adds reservation expiry fields without changing the old RPC.
create or replace function public.get_my_donation_dashboard_v2()
returns table(
  donation_id uuid,title text,donation_status text,collection_path text,
  total_weight_kg numeric,created_at timestamptz,hub_name text,
  reservation_status text,reservation_effective_status text,
  reservation_expires_at timestamptz,listing_status text,receipt_status text,
  inventory_status text,item_count bigint,primary_image_path text
)
language plpgsql stable security definer
set search_path = pg_catalog, public, pg_temp
as $$
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
    (select count(*) from public.donation_items di where di.donation_id=d.donation_id),
    img.storage_path
  from public.donations d
  left join public.listings l on l.donation_id=d.donation_id
    and l.source_type='DIRECT_DONATION'
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
$$;

-- Reserve/reassign. Lock order: donation, both involved hub rows in UUID order,
-- then this donation's reservation row(s). Never mass-update expired rows for
-- a hub: doing so could deadlock with cancellation of a different donation.
create or replace function public.reserve_hub_capacity(p_donation uuid,p_hub uuid)
returns uuid language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_actor uuid:=auth.uid(); v_d public.donations%rowtype;
  v_h public.community_hubs%rowtype; v_old_hub uuid;
  v_latest public.hub_reservations%rowtype;
  v_used numeric; v_reserved numeric; v_res uuid; v_minutes integer; v_active_count integer;
  v_old public.hub_reservations%rowtype;
begin
  if v_actor is null then raise exception 'UNAUTHENTICATED'; end if;
  select * into v_d from public.donations where donation_id=p_donation for update;
  if not found or v_d.donor_user_id is distinct from v_actor then
    raise exception 'NOT_DONOR_OWNER';
  end if;
  if v_d.collection_path<>'HUB_COLLECTION'
     or v_d.donation_status not in ('VALIDATED','HUB_ASSIGNED') then
    raise exception 'DONATION_NOT_HUB_ELIGIBLE';
  end if;

  if v_d.donation_status='HUB_ASSIGNED' then
    select * into v_latest from public.hub_reservations
    where donation_id=p_donation
    order by reserved_at desc,reservation_id desc limit 1;
    select count(*) into v_active_count from public.hub_reservations
    where donation_id=p_donation and reservation_status='ACTIVE';
    if v_latest.reservation_id is null or exists(select 1 from public.hub_reservations r
        where r.donation_id=p_donation and r.reservation_status in ('RELEASED','CONSUMED'))
      or exists(select 1 from public.hub_reservations r where r.donation_id=p_donation
          and r.reservation_status='EXPIRED' and r.expires_at>clock_timestamp())
      or (select count(*) from public.hub_reservations r
          where r.donation_id=p_donation and r.reservation_status='ACTIVE')>1
      or (v_latest.reservation_status='EXPIRED' and v_active_count<>0)
      or not (v_latest.reservation_status='EXPIRED'
      or (v_latest.reservation_status='ACTIVE'
        and v_latest.expires_at<=clock_timestamp())) then
      raise exception 'HUB_RESERVATION_NOT_EXPIRED';
    end if;
  end if;

  select * into v_old from public.hub_reservations
  where donation_id=p_donation and reservation_status='ACTIVE'
  order by reserved_at desc limit 1;
  if found then v_old_hub:=v_old.hub_id; end if;
  if v_d.donation_status='HUB_ASSIGNED' and v_old.reservation_id is not null
     and v_old.expires_at>clock_timestamp() then
    raise exception 'HUB_RESERVATION_STILL_ACTIVE';
  end if;
  if exists(select 1 from public.hub_receipts where donation_id=p_donation)
     or exists(select 1 from public.hub_inventory where donation_id=p_donation)
     or exists(select 1 from public.hub_batch_members
       where donation_id=p_donation and membership_status='ACTIVE') then
    raise exception 'DONATION_HAS_PHYSICAL_CUSTODY';
  end if;

  -- Deterministic hub lock order protects cross-hub reassignment.
  perform 1 from public.community_hubs h
  where h.hub_id=p_hub or h.hub_id=v_old_hub
  order by h.hub_id for update;
  if v_old_hub is not null and not exists(
      select 1 from public.community_hubs where hub_id=v_old_hub) then
    raise exception 'OLD_RESERVATION_HUB_MISSING';
  end if;
  select * into v_h from public.community_hubs where hub_id=p_hub;
  if not found or not v_h.active_flag then raise exception 'HUB_INACTIVE'; end if;

  if v_old.reservation_id is not null then
    select * into v_old from public.hub_reservations
    where reservation_id=v_old.reservation_id for update;
    if not found or v_old.donation_id is distinct from p_donation
        or v_old.hub_id is distinct from v_old_hub then
      raise exception 'OLD_RESERVATION_CHANGED';
    end if;
    if v_old.reservation_status='ACTIVE' then
      if v_old.expires_at>clock_timestamp() then
        raise exception 'HUB_RESERVATION_STILL_ACTIVE';
      end if;
      update public.hub_reservations set reservation_status='EXPIRED'
      where reservation_id=v_old.reservation_id and reservation_status='ACTIVE';
      insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,
        event_type,previous_state,requested_state,resulting_state,reason_code,
        outcome,correlation_id,details,configuration_version)
      select v_actor,'DONOR','HUB_RESERVATION',v_old.reservation_id,
        'EXPIRE_HUB_RESERVATION','ACTIVE','EXPIRED','EXPIRED','RESERVATION_TIMEOUT',
        'SUCCESS',v_old.reservation_id,
        jsonb_build_object('donation_id',p_donation,'hub_id',v_old.hub_id),c.config_version
      from public.coordination_config c where c.singleton;
    end if;
  end if;

  if not exists(select 1 from public.donation_items where donation_id=p_donation)
    then raise exception 'EMPTY_DONATION'; end if;
  if exists(select 1 from public.donation_items di where di.donation_id=p_donation
    and not exists(select 1 from public.hub_accepted_categories a
      where a.hub_id=p_hub and a.category_id=di.category_id)) then
    raise exception 'CATEGORY_NOT_ACCEPTED';
  end if;

  select coalesce(sum(hr.received_weight_kg),0) into v_used
  from public.hub_inventory hi join public.hub_receipts hr using(donation_id)
  where hi.hub_id=p_hub
    and hi.inventory_status in ('STORED','BATCHED','RECONCILIATION_REQUIRED');
  select coalesce(sum(r.reserved_weight_kg),0) into v_reserved
  from public.hub_reservations r
  where r.hub_id=p_hub and r.reservation_status='ACTIVE'
    and r.expires_at>clock_timestamp()
    and not exists(select 1 from public.hub_receipts hr
      where hr.reservation_id=r.reservation_id);
  if v_used+v_reserved+v_d.total_weight_kg>v_h.capacity_kg then
    raise exception 'HUB_CAPACITY_EXCEEDED';
  end if;
  select hub_reservation_minutes into v_minutes
  from public.coordination_config where singleton;
  insert into public.hub_reservations(donation_id,hub_id,reserved_weight_kg,expires_at)
  values(p_donation,p_hub,v_d.total_weight_kg,
    clock_timestamp()+make_interval(mins=>v_minutes)) returning reservation_id into v_res;
  if v_d.donation_status='VALIDATED' then
    update public.donations set donation_status='HUB_ASSIGNED'
    where donation_id=p_donation;
  end if;
  insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,
    event_type,previous_state,requested_state,resulting_state,outcome,details,
    correlation_id,configuration_version)
  select v_actor,'DONOR','DONATION',p_donation,'RESERVE_HUB',v_d.donation_status,
    'HUB_ASSIGNED','HUB_ASSIGNED','SUCCESS',
    jsonb_build_object('hub_id',p_hub,'reservation_id',v_res,
      'supersedes_reservation_id',v_old.reservation_id),v_res,c.config_version
  from public.coordination_config c where c.singleton;
  return v_res;
end;
$$;

-- Receipt and cancellation now serialize on donation first. The initial lookup
-- only discovers immutable foreign keys; reservation fields are reread after
-- all locks. Expiry is evaluated with database clock_timestamp().
create or replace function public.confirm_hub_receipt(
  p_reservation uuid,p_received_weight numeric
) returns uuid language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
declare v_actor uuid:=auth.uid(); v_r public.hub_reservations%rowtype;
  v_d public.donations%rowtype; v_h public.community_hubs%rowtype; v_receipt uuid;
  v_donation_id uuid; v_hub_id uuid;
begin
  if v_actor is null then raise exception 'UNAUTHENTICATED'; end if;
  select donation_id,hub_id into v_donation_id,v_hub_id
  from public.hub_reservations where reservation_id=p_reservation;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  select * into v_d from public.donations where donation_id=v_donation_id for update;
  if not found then raise exception 'DONATION_NOT_FOUND'; end if;
  perform 1 from public.community_hubs where hub_id=v_hub_id for update;
  select * into v_h from public.community_hubs where hub_id=v_hub_id;
  if v_h.admin_user_id is distinct from v_actor then raise exception 'NOT_HUB_ADMIN'; end if;
  select * into v_r from public.hub_reservations
  where reservation_id=p_reservation for update;
  if v_r.donation_id is distinct from v_donation_id or v_r.hub_id is distinct from v_hub_id
     or v_r.reservation_status<>'ACTIVE' or v_r.expires_at<=clock_timestamp() then
    raise exception 'RESERVATION_NOT_ACTIVE';
  end if;
  if v_d.donation_status<>'HUB_ASSIGNED' then raise exception 'INVALID_DONATION_STATE'; end if;
  if p_received_weight<=0 or p_received_weight>v_r.reserved_weight_kg then
    raise exception 'RECEIVED_WEIGHT_EXCEEDS_RESERVATION';
  end if;
  insert into public.hub_receipts(reservation_id,donation_id,hub_id,received_by,received_weight_kg)
  values(v_r.reservation_id,v_r.donation_id,v_r.hub_id,v_actor,p_received_weight)
  returning receipt_id into v_receipt;
  insert into public.hub_inventory(donation_id,hub_id)
  values(v_r.donation_id,v_r.hub_id);
  update public.hub_reservations set reservation_status='CONSUMED'
  where reservation_id=p_reservation and reservation_status='ACTIVE';
  update public.donations set donation_status='AT_HUB'
  where donation_id=v_donation_id;
  insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,
    event_type,previous_state,requested_state,resulting_state,outcome,details,
    correlation_id,configuration_version)
  select v_actor,'HUB_ADMIN','DONATION',v_donation_id,'CONFIRM_HUB_RECEIPT',
    'HUB_ASSIGNED','AT_HUB','AT_HUB','SUCCESS',
    jsonb_build_object('receipt_id',v_receipt,'reservation_id',p_reservation,
      'hub_id',v_hub_id),v_receipt,c.config_version
  from public.coordination_config c where c.singleton;
  return v_receipt;
end;
$$;

-- Preserve batch rules and signature while aligning locks with receipt,
-- reservation, and cancellation writers: member donations (sorted) -> hub ->
-- member inventory (sorted) -> batch members. The current deployed function
-- takes the hub lock before donation locks, which can deadlock against a
-- receipt transaction that has locked a donation and is waiting for that hub.
create or replace function public.publish_whole_donation_batch(
  p_hub uuid,p_donation_ids uuid[]
) returns uuid language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_actor uuid:=auth.uid(); v_batch uuid; v_count integer; v_weight numeric;
  v_min integer; v_max integer; v_limit numeric; v_cat uuid; v_cat_count integer;
  v_h public.community_hubs%rowtype; v_d uuid;
begin
  if v_actor is null then raise exception 'UNAUTHENTICATED'; end if;
  select * into v_h from public.community_hubs where hub_id=p_hub;
  if not found or v_h.admin_user_id is distinct from v_actor then
    raise exception 'NOT_HUB_ADMIN';
  end if;
  if not v_h.active_flag then raise exception 'HUB_INACTIVE'; end if;

  select batch_min_donations,batch_max_donations,batch_max_weight_kg
  into v_min,v_max,v_limit from public.coordination_config where singleton;
  select count(distinct x) into v_count from unnest(p_donation_ids) x;
  if v_count<>coalesce(array_length(p_donation_ids,1),0)
     or v_count<v_min or v_count>v_max then raise exception 'INVALID_BATCH_COUNT'; end if;

  -- All writers that can conflict on these donations acquire donation rows
  -- before hub rows. Stable UUID order prevents batch-vs-batch lock inversion.
  for v_d in select distinct unnest(p_donation_ids) order by 1 loop
    perform 1 from public.donations d
    where d.donation_id=v_d and d.donation_status='AT_HUB' for update;
    if not found then raise exception 'DONATION_NOT_STORED_AT_HUB'; end if;
  end loop;
  select * into v_h from public.community_hubs where hub_id=p_hub for update;
  if not found or v_h.admin_user_id is distinct from v_actor then
    raise exception 'NOT_HUB_ADMIN';
  end if;
  if not v_h.active_flag then raise exception 'HUB_INACTIVE'; end if;

  for v_d in select distinct unnest(p_donation_ids) order by 1 loop
    perform 1 from public.hub_inventory hi
    where hi.donation_id=v_d and hi.hub_id=p_hub
      and hi.inventory_status='STORED' for update;
    if not found then raise exception 'DONATION_NOT_STORED_AT_HUB'; end if;
    if exists(select 1 from public.hub_batch_members
      where donation_id=v_d and membership_status='ACTIVE') then
      raise exception 'DONATION_ALREADY_BATCHED';
    end if;
  end loop;

  select coalesce(sum(hr.received_weight_kg),0) into v_weight
  from public.hub_receipts hr where hr.donation_id=any(p_donation_ids);
  if v_weight>v_limit then raise exception 'BATCH_WEIGHT_EXCEEDED'; end if;
  select count(distinct di.category_id) into v_cat_count
  from public.donation_items di where di.donation_id=any(p_donation_ids);
  select di.category_id into v_cat from public.donation_items di
  where di.donation_id=any(p_donation_ids) limit 1;
  if v_cat_count<>1 then raise exception 'BATCH_CATEGORY_INCOMPATIBLE'; end if;

  insert into public.hub_batches(hub_id,batch_category_id,batch_weight_kg,
    batch_donation_count,created_by)
  values(p_hub,v_cat,v_weight,v_count,v_actor) returning batch_id into v_batch;
  insert into public.hub_batch_members(batch_id,hub_id,donation_id)
  select v_batch,p_hub,unnest(p_donation_ids);
  update public.hub_inventory set inventory_status='BATCHED'
  where donation_id=any(p_donation_ids);
  update public.donations set donation_status='BATCHED'
  where donation_id=any(p_donation_ids);
  update public.hub_batches set batch_status='PUBLISHED',published_at=clock_timestamp()
  where batch_id=v_batch;
  insert into public.listings(source_type,batch_id,listing_weight_kg,
    pickup_latitude,pickup_longitude,pickup_road_node_id)
  values('HUB_BATCH',v_batch,v_weight,v_h.latitude,v_h.longitude,v_h.road_node_id);
  insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,
    event_type,requested_state,resulting_state,outcome,details)
  values(v_actor,'HUB_ADMIN','BATCH',v_batch,'PUBLISH_BATCH','PUBLISHED',
    'PUBLISHED','SUCCESS',jsonb_build_object('count',v_count,'weight_kg',v_weight));
  return v_batch;
end;
$$;

-- Cancellation is based on the deployed implementation and preserves its
-- request-table fingerprint/replay behavior, including SUCCESS/ALREADY_CANCELLED.
-- Hub path locks: donation -> hub -> reservation. Direct path locks listing ->
-- donation, matching the deployed NGO claim/pickup lock order.
create or replace function public.cancel_donation(p_donation uuid,p_request uuid)
returns jsonb language plpgsql security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_actor uuid:=auth.uid(); v_actor_role text; v_owner uuid; v_path text;
  v_previous text; v_listing uuid; v_listing_status text; v_fingerprint text;
  v_request public.donation_cancellation_requests%rowtype; v_response jsonb;
  v_outcome text; v_reason text; v_result_state text;
  v_res public.hub_reservations%rowtype; v_hub public.community_hubs%rowtype;
  v_res_old_status text; v_res_new_status text;
  v_active_count integer; v_latest_res public.hub_reservations%rowtype;
begin
  if v_actor is null then raise exception 'UNAUTHENTICATED'; end if;
  if p_request is null then raise exception 'REQUEST_ID_REQUIRED'; end if;
  if p_donation is null then raise exception 'DONATION_ID_REQUIRED'; end if;
  select p.role into v_actor_role from public.user_profiles p where p.user_id=v_actor;
  select d.donor_user_id into v_owner from public.donations d where d.donation_id=p_donation;
  if not found or v_owner is distinct from v_actor
     or not exists(select 1 from public.donor_profiles dp where dp.user_id=v_actor) then
    insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,
      request_id,correlation_id,requested_state,resulting_state,reason_code,outcome,details,
      configuration_version)
    select v_actor,v_actor_role,'DONATION',p_donation,'CANCEL_DONATION',p_request,p_request,
      'CANCELLED',null,'DONATION_NOT_FOUND_OR_FORBIDDEN','REJECTED',
      jsonb_build_object('request_id',p_request),c.config_version
    from public.coordination_config c where c.singleton;
    return jsonb_build_object('outcome','REJECTED','donation_id',p_donation,
      'reason_code','DONATION_NOT_FOUND_OR_FORBIDDEN');
  end if;

  v_fingerprint:=v_actor::text||':'||p_donation::text;
  insert into public.donation_cancellation_requests(
    request_id,donor_user_id,donation_id,request_fingerprint)
  values(p_request,v_actor,p_donation,v_fingerprint)
  on conflict(request_id) do nothing;
  select * into v_request from public.donation_cancellation_requests
  where request_id=p_request for update;
  if v_request.request_fingerprint<>v_fingerprint then
    v_response:=jsonb_build_object('outcome','REJECTED','donation_id',p_donation,
      'reason_code','IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD');
    insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,
      request_id,correlation_id,requested_state,resulting_state,reason_code,outcome,details,
      configuration_version)
    select v_actor,v_actor_role,'DONATION',p_donation,'CANCEL_DONATION',p_request,p_request,
      'CANCELLED',null,'IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD','REJECTED',
      jsonb_build_object('request_id',p_request),c.config_version
    from public.coordination_config c where c.singleton;
    return v_response;
  end if;
  if v_request.response is not null then return v_request.response; end if;

  -- Match direct claim lock order; HUB_COLLECTION has no direct listing row.
  select l.listing_id,l.listing_status into v_listing,v_listing_status
  from public.listings l where l.donation_id=p_donation
    and l.source_type='DIRECT_DONATION' for update;
  select d.donor_user_id,d.collection_path,d.donation_status
  into v_owner,v_path,v_previous from public.donations d
  where d.donation_id=p_donation for update;

  if not found then v_reason:='DONATION_NOT_FOUND_OR_FORBIDDEN';
  elsif v_owner is distinct from v_actor
     or not exists(select 1 from public.donor_profiles dp where dp.user_id=v_actor) then
    v_reason:='DONATION_NOT_FOUND_OR_FORBIDDEN';
  elsif v_previous='CANCELLED' then
    -- Preserve deployed semantics: successful idempotent completion.
    v_outcome:='SUCCESS'; v_reason:='ALREADY_CANCELLED';
  elsif v_previous not in ('SUBMITTED','VALIDATED','READY_FOR_PICKUP','HUB_ASSIGNED') then
    v_reason:='CANCELLATION_NOT_PERMITTED';
  elsif v_previous='READY_FOR_PICKUP' and v_path is distinct from 'DIRECT_PICKUP' then
    v_reason:='DONATION_COLLECTION_PATH_INCONSISTENT';
  elsif v_previous='READY_FOR_PICKUP' and v_listing is null then
    v_reason:='DIRECT_LISTING_MISSING';
  elsif v_path='HUB_COLLECTION' and v_listing is not null then
    v_reason:='DONATION_LISTING_PATH_INCONSISTENT';
  elsif exists(select 1 from public.hub_receipts where donation_id=p_donation)
     or exists(select 1 from public.hub_inventory where donation_id=p_donation)
     or exists(select 1 from public.hub_batch_members where donation_id=p_donation
               and membership_status='ACTIVE') then
    v_reason:='DONATION_HAS_PHYSICAL_CUSTODY';
  elsif exists(select 1 from public.pickup_tasks pt
    join public.donation_claims c using(claim_id)
    join public.listings l using(listing_id)
    where l.source_type='DIRECT_DONATION' and l.donation_id=p_donation
      and pt.task_status in ('DISPATCHED','COLLECTED')) then
    v_reason:='PICKUP_HANDOVER_MAY_HAVE_OCCURRED';
  elsif exists(select 1 from public.donation_claims c
    join public.listings l using(listing_id)
    left join public.claim_leases le using(claim_id)
    where l.source_type='DIRECT_DONATION' and l.donation_id=p_donation
      and (c.claim_status in ('ACTIVE','RECONCILIATION_REQUIRED')
        or le.lease_status in ('ACTIVE','RECONCILIATION_REQUIRED')))
    or v_listing_status='CLAIMED' then
    v_reason:='DONATION_HAS_ACTIVE_CLAIM';
  elsif v_listing_status in ('CLOSED','CANCELLED') then
    v_reason:='LISTING_NOT_CANCELLABLE';
  elsif v_previous='HUB_ASSIGNED' and v_path is distinct from 'HUB_COLLECTION' then
    v_reason:='DONATION_COLLECTION_PATH_INCONSISTENT';
  elsif v_path is distinct from 'HUB_COLLECTION' and exists(
    select 1 from public.hub_reservations r where r.donation_id=p_donation) then
    v_reason:='DONATION_RESERVATION_PATH_INCONSISTENT';
  elsif v_previous in ('SUBMITTED','VALIDATED') and v_path='HUB_COLLECTION'
      and exists(select 1 from public.hub_reservations r where r.donation_id=p_donation) then
    v_reason:='HUB_RESERVATION_STATE_INCONSISTENT';
  elsif v_previous='HUB_ASSIGNED' and not exists(
    select 1 from public.hub_reservations r where r.donation_id=p_donation) then
    v_reason:='HUB_RESERVATION_HISTORY_MISSING';
  elsif v_previous='HUB_ASSIGNED' and exists(
    select 1 from public.hub_reservations r where r.donation_id=p_donation
      and r.reservation_status in ('RELEASED','CONSUMED')) then
    v_reason:='HUB_RESERVATION_HISTORY_INCONSISTENT';
  elsif v_previous='HUB_ASSIGNED' and exists(
    select 1 from public.hub_reservations r where r.donation_id=p_donation
      and r.reservation_status='EXPIRED' and r.expires_at>clock_timestamp()) then
    v_reason:='HUB_RESERVATION_HISTORY_INCONSISTENT';
  elsif v_previous='HUB_ASSIGNED' and (select count(*) from public.hub_reservations r
      where r.donation_id=p_donation and r.reservation_status='ACTIVE')>1 then
    v_reason:='MULTIPLE_ACTIVE_HUB_RESERVATIONS';
  else
    if v_path='HUB_COLLECTION' then
      select count(*) into v_active_count from public.hub_reservations
      where donation_id=p_donation and reservation_status='ACTIVE';
      select * into v_latest_res from public.hub_reservations
      where donation_id=p_donation
      order by reserved_at desc,reservation_id desc limit 1;
      if v_previous='HUB_ASSIGNED' and v_latest_res.reservation_id is null then
        v_reason:='HUB_RESERVATION_HISTORY_MISSING';
      elsif v_previous='HUB_ASSIGNED' and v_latest_res.reservation_status not in ('ACTIVE','EXPIRED') then
        v_reason:='HUB_RESERVATION_HISTORY_INCONSISTENT';
      elsif v_previous='HUB_ASSIGNED' and v_active_count=1
          and v_latest_res.reservation_status<>'ACTIVE' then
        v_reason:='HUB_RESERVATION_HISTORY_INCONSISTENT';
      elsif v_previous='HUB_ASSIGNED' and v_active_count=0
          and (v_latest_res.reservation_status<>'EXPIRED'
            or v_latest_res.expires_at>clock_timestamp()) then
        v_reason:='HUB_RESERVATION_HISTORY_INCONSISTENT';
      elsif v_latest_res.reservation_status='ACTIVE' then
        -- The donation lock serializes receipt, reassignment and cancellation.
        -- Lock the hub before the reservation, then revalidate every field.
        v_res:=v_latest_res;
        perform 1 from public.community_hubs where hub_id=v_res.hub_id for update;
        select * into v_hub from public.community_hubs where hub_id=v_res.hub_id;
        if not found then
          v_reason:='HUB_RESERVATION_HUB_MISSING';
        else
        select * into v_res from public.hub_reservations
        where reservation_id=v_res.reservation_id for update;
        if not found or v_res.donation_id<>p_donation or v_res.hub_id is distinct from v_latest_res.hub_id
            or v_res.reservation_status<>'ACTIVE' then
          v_reason:='HUB_RESERVATION_CHANGED';
        elsif v_res.expires_at<=clock_timestamp() then
          update public.hub_reservations set reservation_status='EXPIRED'
          where reservation_id=v_res.reservation_id and reservation_status='ACTIVE';
          v_res_old_status:='ACTIVE'; v_res_new_status:='EXPIRED';
        else
            update public.hub_reservations set reservation_status='RELEASED'
            where reservation_id=v_res.reservation_id and reservation_status='ACTIVE';
            v_res_old_status:='ACTIVE'; v_res_new_status:='RELEASED';
        end if;
        end if;
      end if;
    end if;
    if v_reason is not null and v_reason<>'DONOR_REQUEST' then
      v_outcome:='REJECTED';
    else
    -- A current reservation is RELEASED atomically; an expired reservation
    -- is marked EXPIRED and retained. Both are compatible with cancellation.
    v_reason:='DONOR_REQUEST';
    update public.donations set donation_status='CANCELLED'
    where donation_id=p_donation;
    if v_listing is not null and v_listing_status='AVAILABLE' then
      update public.listings set listing_status='CANCELLED',
        listing_version=listing_version+1
      where listing_id=v_listing and listing_status='AVAILABLE';
    end if;
    v_outcome:='SUCCESS';
    if v_res_old_status is not null then
      insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,
        event_type,previous_state,requested_state,resulting_state,reason_code,
        outcome,request_id,correlation_id,details,configuration_version)
      select v_actor,v_actor_role,'HUB_RESERVATION',v_res.reservation_id,
        case when v_res_new_status='EXPIRED' then 'EXPIRE_HUB_RESERVATION'
             else 'RELEASE_HUB_RESERVATION' end,
        v_res_old_status,v_res_new_status,v_res_new_status,
        case when v_res_new_status='EXPIRED' then 'RESERVATION_TIMEOUT'
             else 'DONOR_CANCELLATION' end,
        'SUCCESS',p_request,p_request,
        jsonb_build_object('donation_id',p_donation,'hub_id',v_res.hub_id),
        c.config_version
      from public.coordination_config c where c.singleton;
    end if;
    end if;
  end if;

  if v_outcome is distinct from 'SUCCESS' then v_outcome:='REJECTED'; end if;
  v_result_state:=case when v_outcome='SUCCESS' then 'CANCELLED' else v_previous end;
  v_response:=jsonb_build_object('outcome',v_outcome,'donation_id',p_donation,
    'reason_code',v_reason,'resulting_state',v_result_state);
  update public.donation_cancellation_requests set response=v_response,
    completed_at=clock_timestamp() where request_id=p_request;
  insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,
    request_id,correlation_id,previous_state,requested_state,resulting_state,
    reason_code,outcome,details,configuration_version)
  select v_actor,v_actor_role,'DONATION',p_donation,'CANCEL_DONATION',p_request,p_request,
    v_previous,'CANCELLED',v_result_state,v_reason,v_outcome,
    jsonb_build_object('request_id',p_request,
      'reservation_id',case when v_res.reservation_id is null then null
        else v_res.reservation_id end,
      'reservation_result',v_res_new_status),c.config_version
  from public.coordination_config c where c.singleton;
  return v_response;
end;
$$;

revoke all on function public.get_eligible_hubs(uuid) from public,anon;
revoke all on function public.get_my_donation_detail(uuid) from public,anon;
revoke all on function public.get_my_donation_dashboard_v2() from public,anon;
revoke all on function public.get_my_hub_reservations(uuid) from public,anon;
revoke all on function public.reserve_hub_capacity(uuid,uuid) from public,anon;
revoke all on function public.confirm_hub_receipt(uuid,numeric) from public,anon;
revoke all on function public.publish_whole_donation_batch(uuid,uuid[]) from public,anon;
revoke all on function public.cancel_donation(uuid,uuid) from public,anon;
grant execute on function public.get_eligible_hubs(uuid) to authenticated;
grant execute on function public.get_my_donation_detail(uuid) to authenticated;
grant execute on function public.get_my_donation_dashboard_v2() to authenticated;
grant execute on function public.get_my_hub_reservations(uuid) to authenticated;
grant execute on function public.reserve_hub_capacity(uuid,uuid) to authenticated;
grant execute on function public.confirm_hub_receipt(uuid,numeric) to authenticated;
grant execute on function public.publish_whole_donation_batch(uuid,uuid[]) to authenticated;
grant execute on function public.cancel_donation(uuid,uuid) to authenticated;

commit;
