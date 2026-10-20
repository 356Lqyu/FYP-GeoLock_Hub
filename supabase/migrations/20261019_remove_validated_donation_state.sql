-- GeoLock Hub: remove VALIDATED as a persisted donation state.
-- Apply only after V3, the October 18 hub-reservation migration, Stage 1
-- recovery/reconciliation, and 20261019_retire_delivered_state.sql.
-- Prepared for review only. This file has NOT been executed.
--
-- SUBMITTED is both the transaction-local construction state and the committed
-- hub-collection state awaiting reservation. Donation items are frozen once
-- collection_path/total_weight_kg have been assigned. Direct donations move
-- SUBMITTED -> READY_FOR_PICKUP inside the same transaction that creates their
-- listing. No intermediate state is visible outside that transaction.

begin;

-- Serialize the preflight, legacy-row conversion, and constraint/function
-- replacement against all donation lifecycle writers.
lock table public.donations in access exclusive mode;

do $$
declare
  v_status_constraint text;
  v_threshold numeric;
begin
  if to_regprocedure('public.create_and_validate_donation(text,text,text,double precision,double precision,jsonb,text,timestamp with time zone,timestamp with time zone)') is null
     or to_regprocedure('public.get_eligible_hubs(uuid)') is null
     or to_regprocedure('public.reserve_hub_capacity(uuid,uuid)') is null
     or to_regprocedure('public.cancel_donation(uuid,uuid)') is null
     or to_regprocedure('public.enforce_donation_transition()') is null
     or to_regprocedure('public.guard_donation_items()') is null then
    raise exception 'REQUIRED_V3_DONATION_FUNCTION_MISSING';
  end if;

  select pg_get_constraintdef(c.oid) into v_status_constraint
  from pg_constraint c
  where c.conrelid='public.donations'::regclass
    and c.conname='donations_donation_status_check';
  if v_status_constraint is null
     or position('VALIDATED' in v_status_constraint)=0
     or position('DELIVERED' in v_status_constraint)>0 then
    raise exception 'UNEXPECTED_DONATION_STATUS_CONSTRAINT: %',v_status_constraint;
  end if;

  select donation_direct_min_kg into v_threshold
  from public.coordination_config where singleton;
  if not found or v_threshold is distinct from 10::numeric then
    raise exception 'UNEXPECTED_DIRECT_PICKUP_THRESHOLD: %',v_threshold;
  end if;
  if not exists(select 1 from public.coordination_config
    where singleton and config_version is not null) then
    raise exception 'COORDINATION_CONFIG_NOT_READY';
  end if;

  if exists(select 1 from public.donations where donation_status='DELIVERED') then
    raise exception 'DELIVERED_ROWS_EXIST';
  end if;

  -- A normally committed V3 VALIDATED donation is a small hub-collection
  -- donation awaiting hub choice. Refuse to reinterpret any inconsistent row
  -- or row already associated with listing, reservation, custody, or claims.
  if exists(
    select 1 from public.donations d
    where d.donation_status='VALIDATED'
      and (d.collection_path is distinct from 'HUB_COLLECTION'
        or d.total_weight_kg is null or d.total_weight_kg<=0
        or d.total_weight_kg >= (select c.donation_direct_min_kg
                                 from public.coordination_config c where c.singleton)
        or not exists(select 1 from public.donation_items i where i.donation_id=d.donation_id)
        or exists(select 1 from public.listings l where l.donation_id=d.donation_id)
        or exists(select 1 from public.hub_reservations r where r.donation_id=d.donation_id)
        or exists(select 1 from public.hub_receipts r where r.donation_id=d.donation_id)
        or exists(select 1 from public.hub_inventory i where i.donation_id=d.donation_id)
        or exists(select 1 from public.hub_batch_members m where m.donation_id=d.donation_id))
  ) then
    raise exception 'VALIDATED_DONATION_REQUIRES_MANUAL_REVIEW';
  end if;

  if not exists(select 1 from pg_trigger t
    where t.tgrelid='public.donations'::regclass
      and t.tgname='trg_donation_transition' and not t.tgisinternal) then
    raise exception 'DONATION_TRANSITION_TRIGGER_MISSING';
  end if;
  if not exists(select 1 from pg_trigger t
    where t.tgrelid='public.donation_items'::regclass
      and t.tgname='trg_items_guard' and not t.tgisinternal) then
    raise exception 'DONATION_ITEM_GUARD_TRIGGER_MISSING';
  end if;
end $$;

-- Reclassify only the known safe legacy case. The migration emits an explicit
-- append-only audit event for each converted row; no donation/item/history is
-- deleted. Trigger disabling is scoped to this one known state conversion and
-- is transactional. Any later failure rolls the entire migration back.
alter table public.donations disable trigger trg_donation_transition;
with migrated as (
  update public.donations d
  set donation_status='SUBMITTED',updated_at=clock_timestamp()
  where d.donation_status='VALIDATED'
  returning d.donation_id,d.donor_user_id,d.collection_path,d.total_weight_kg
)
insert into public.audit_events(
  actor_user_id,actor_role,entity_type,entity_id,event_type,
  previous_state,requested_state,resulting_state,reason_code,outcome,
  correlation_id,software_version,configuration_version,details
)
select null,'SYSTEM','DONATION',m.donation_id,'REMOVE_VALIDATED_DONATION_STATE',
  'VALIDATED','SUBMITTED','SUBMITTED','LEGACY_HUB_AWAITING_SELECTION',
  'SUCCESS',gen_random_uuid(),'geolock-state-simplification-2026-10-19',
  c.config_version,
  jsonb_build_object('collection_path',m.collection_path,
    'total_weight_kg',m.total_weight_kg,
    'transaction_id',pg_current_xact_id()::text,
    'migration','20261019_remove_validated_donation_state.sql')
from migrated m cross join public.coordination_config c where c.singleton;
alter table public.donations enable trigger trg_donation_transition;

alter table public.donations drop constraint donations_donation_status_check;
alter table public.donations add constraint donations_donation_status_check
  check (donation_status = any (array[
    'SUBMITTED'::text,'READY_FOR_PICKUP'::text,'HUB_ASSIGNED'::text,
    'AT_HUB'::text,'BATCHED'::text,'PICKUP_IN_PROGRESS'::text,
    'COLLECTED'::text,'CANCELLED'::text
  ]));

create or replace function public.enforce_donation_transition()
returns trigger language plpgsql
set search_path = public, pg_temp
as $$
declare v_direct_min numeric;
begin
  if tg_op='UPDATE' and new.donation_status is distinct from old.donation_status then
    if old.donation_status='SUBMITTED' and new.donation_status='READY_FOR_PICKUP' then
      select donation_direct_min_kg into v_direct_min
      from public.coordination_config where singleton;
      if v_direct_min is null
         or new.collection_path is distinct from 'DIRECT_PICKUP'
         or new.total_weight_kg is null or new.total_weight_kg<v_direct_min then
        raise exception 'INVALID_DONATION_TRANSITION: SUBMITTED -> READY_FOR_PICKUP';
      end if;
    elsif old.donation_status='SUBMITTED' and new.donation_status='HUB_ASSIGNED' then
      select donation_direct_min_kg into v_direct_min
      from public.coordination_config where singleton;
      if v_direct_min is null
         or new.collection_path is distinct from 'HUB_COLLECTION'
         or new.total_weight_kg is null or new.total_weight_kg<=0
         or new.total_weight_kg>=v_direct_min then
        raise exception 'INVALID_DONATION_TRANSITION: SUBMITTED -> HUB_ASSIGNED';
      end if;
    elsif not (
      (old.donation_status='SUBMITTED' and new.donation_status='CANCELLED')
      or (old.donation_status='READY_FOR_PICKUP' and new.donation_status in ('PICKUP_IN_PROGRESS','CANCELLED'))
      or (old.donation_status='HUB_ASSIGNED' and new.donation_status in ('AT_HUB','CANCELLED'))
      or (old.donation_status='AT_HUB' and new.donation_status='BATCHED')
      or (old.donation_status='BATCHED' and new.donation_status='PICKUP_IN_PROGRESS')
      or (old.donation_status='PICKUP_IN_PROGRESS' and new.donation_status='COLLECTED')
    ) then
      raise exception 'INVALID_DONATION_TRANSITION: % -> %',old.donation_status,new.donation_status;
    end if;
  end if;
  new.updated_at=clock_timestamp();
  return new;
end;
$$;

-- Keep the V3 immutable-item guard. Once classification data is populated,
-- even a committed SUBMITTED hub donation is frozen. Only the in-transaction
-- construction row (SUBMITTED with no path/weight yet) accepts item writes.
create or replace function public.guard_donation_items()
returns trigger language plpgsql
set search_path = public, pg_temp
as $$
declare v_donation uuid; v_status text; v_path text; v_weight numeric;
begin
  v_donation:=case when tg_op='DELETE' then old.donation_id else new.donation_id end;
  if tg_op='UPDATE' and new.donation_id<>old.donation_id then
    raise exception 'DONATION_ITEM_REPARENT_FORBIDDEN';
  end if;
  select donation_status,collection_path,total_weight_kg
    into v_status,v_path,v_weight
  from public.donations where donation_id=v_donation for update;
  if v_status is distinct from 'SUBMITTED'
     or v_path is not null or v_weight is not null then
    raise exception 'DONATION_ITEMS_FROZEN';
  end if;
  if tg_op='DELETE' then return old; end if;
  return new;
end;
$$;

-- Existing signature, return type, SECURITY DEFINER mode, search path and
-- grants are preserved. Legacy availability arguments remain accepted but
-- ignored, as in the installed October 18 implementation.
create or replace function public.create_and_validate_donation(
  p_title text,p_description text,p_pickup_address text,
  p_latitude double precision,p_longitude double precision,
  p_items jsonb,p_pickup_road_node_id text default null,
  p_availability_start timestamptz default null,p_availability_end timestamptz default null
) returns uuid language plpgsql security definer
set search_path=public,extensions,pg_temp
as $$
declare
  v_actor uuid:=auth.uid(); v_donation uuid; v_item jsonb;
  v_count integer:=0; v_weight numeric(12,3):=0; v_threshold numeric(12,3);
  v_path text; v_category uuid; v_qty integer; v_unit numeric(12,3);
  v_status text;
begin
  if v_actor is null or not exists(
    select 1 from public.donor_profiles where user_id=v_actor
  ) then raise exception 'DONOR_ONLY'; end if;
  if nullif(btrim(p_title),'') is null or nullif(btrim(p_pickup_address),'') is null
     or p_latitude is null or p_longitude is null
     or p_latitude not between -90 and 90 or p_longitude not between -180 and 180 then
    raise exception 'INVALID_DONATION_LOCATION_OR_TITLE';
  end if;
  if nullif(btrim(coalesce(p_description,'')),'') is null then
    raise exception 'DONATION_DESCRIPTION_REQUIRED';
  end if;
  if char_length(p_description)>1000 then
    raise exception 'DONATION_DESCRIPTION_TOO_LONG';
  end if;
  if jsonb_typeof(p_items) is distinct from 'array' then
    raise exception 'AT_LEAST_ONE_ITEM_REQUIRED';
  end if;
  if jsonb_array_length(p_items)=0 then raise exception 'AT_LEAST_ONE_ITEM_REQUIRED'; end if;
  select donation_direct_min_kg into v_threshold
  from public.coordination_config where singleton;
  if v_threshold is null then raise exception 'DONATION_THRESHOLD_NOT_CONFIGURED'; end if;

  -- The parent must temporarily be SUBMITTED so V3's item guard permits these
  -- inserts. This row is not externally visible until the whole RPC commits.
  insert into public.donations(
    donor_user_id,title,description,pickup_address,latitude,longitude,
    pickup_road_node_id,availability_start,availability_end,donation_status
  ) values(
    v_actor,p_title,p_description,p_pickup_address,p_latitude,p_longitude,
    p_pickup_road_node_id,null,null,'SUBMITTED'
  ) returning donation_id into v_donation;

  for v_item in select value from jsonb_array_elements(p_items) loop
    v_category:=(v_item->>'category_id')::uuid;
    v_qty:=(v_item->>'quantity')::integer;
    v_unit:=(v_item->>'unit_weight_kg')::numeric;
    if v_qty is null or v_qty<=0 or v_unit is null or v_unit<=0
       or nullif(btrim(v_item->>'item_name'),'') is null
       or not exists(select 1 from public.donation_categories
         where category_id=v_category and active_flag) then
      raise exception 'INVALID_DONATION_ITEM';
    end if;
    insert into public.donation_items(
      donation_id,category_id,item_name,description,quantity,unit_label,
      unit_weight_kg,item_condition
    ) values(
      v_donation,v_category,v_item->>'item_name',v_item->>'description',
      v_qty,coalesce(v_item->>'unit_label','piece'),v_unit,
      coalesce(v_item->>'item_condition','GOOD')
    );
    v_count:=v_count+1;
    v_weight:=v_weight+(v_qty*v_unit);
  end loop;
  if v_count=0 or v_weight<=0 then raise exception 'INVALID_TOTAL_WEIGHT'; end if;

  v_path:=case when v_weight>=v_threshold then 'DIRECT_PICKUP' else 'HUB_COLLECTION' end;
  v_status:=case when v_path='DIRECT_PICKUP' then 'READY_FOR_PICKUP' else 'SUBMITTED' end;
  update public.donations set donation_status=v_status,
    collection_path=v_path,total_weight_kg=v_weight
  where donation_id=v_donation;

  if v_path='DIRECT_PICKUP' then
    insert into public.listings(
      source_type,donation_id,listing_weight_kg,pickup_latitude,
      pickup_longitude,pickup_road_node_id,listing_expires_at
    ) values(
      'DIRECT_DONATION',v_donation,v_weight,p_latitude,p_longitude,
      p_pickup_road_node_id,null
    );
  end if;

  insert into public.audit_events(
    actor_user_id,actor_role,entity_type,entity_id,event_type,
    previous_state,requested_state,resulting_state,outcome,details,configuration_version
  )
  select v_actor,'DONOR','DONATION',v_donation,'CREATE_DONATION',
    null,v_status,v_status,'SUCCESS',
    jsonb_build_object('validation_passed',true,'weight_kg',v_weight,
      'collection_path',v_path,'threshold_kg',v_threshold),c.config_version
  from public.coordination_config c where c.singleton;
  return v_donation;
end;
$$;


-- Reuse the reviewed October 18 implementations, changing only their
-- accepted pre-reservation state from VALIDATED to SUBMITTED.

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
     or v_donation.donation_status not in ('SUBMITTED','HUB_ASSIGNED') then
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
     or v_d.donation_status not in ('SUBMITTED','HUB_ASSIGNED') then
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
  if v_d.donation_status='SUBMITTED' then
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
  elsif v_previous not in ('SUBMITTED','READY_FOR_PICKUP','HUB_ASSIGNED') then
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
  elsif v_previous='SUBMITTED' and v_path='HUB_COLLECTION'
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

-- CREATE OR REPLACE preserves installed owners, SECURITY DEFINER flags,
-- search paths, return contracts and grants for these exact signatures.
notify pgrst, 'reload schema';

commit;
