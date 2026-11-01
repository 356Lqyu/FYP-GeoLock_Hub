-- GeoLock Hub: drop-off day + category list for the hub sign-up form.
--
-- Run the whole file once in Supabase > SQL Editor. It is one transaction: if any
-- statement fails, nothing is changed.
--
-- 1. Drop-off day (replaces the 2-hour hold).
--    The donor picks the day they will bring the donation (today up to 6 days ahead).
--    A hub can be chosen when it accepts the items, has space, has a road route and is
--    open for at least 30 minutes that day (counted from now when the day is today).
--    The booking holds the space until the hub's last closing time that day; the donor
--    can come at any time the hub is open that day. No time slots.
-- 2. Categories stay a fixed list (edit them and their 4 needs in Table Editor).
-- 3. The hub sign-up form can list the categories (names and needs only).
-- 4. Removes functions that nothing uses any more (get_eligible_hubs).
--
-- Old app versions keep working: p_dropoff_date is optional and means "today".

begin;

-- 1. Drop-off day -------------------------------------------------------------------------

-- Remove the old versions first (their argument lists change).
drop function if exists public.get_eligible_hubs(uuid);              -- unused, replaced by get_hub_options
drop function if exists public.get_hub_options(uuid);
drop function if exists public.geolock_hub_candidates(uuid, timestamptz);
drop function if exists public.reserve_hub_capacity(uuid, uuid);

-- Last closing time of the hub on one day (Malaysia time); null when closed that day.
create or replace function public.geolock_hub_last_close(p_hours jsonb, p_day date)
returns timestamptz
language sql stable
set search_path to 'pg_catalog', 'public', 'pg_temp'
as $$
  select max(case when iv->>'close' = '24:00'
                  then (p_day + 1)::timestamp at time zone 'Asia/Kuala_Lumpur'
                  else (p_day + (iv->>'close')::time) at time zone 'Asia/Kuala_Lumpur' end)
  from jsonb_array_elements(
         case when public.geolock_valid_operating_hours(p_hours)
              then coalesce(p_hours -> to_char(p_day, 'dy'), '[]'::jsonb)
              else '[]'::jsonb end) iv
$$;

-- Every hub within 20 km of the donation, with the hard-rule checks for one drop-off day.
create or replace function public.geolock_hub_candidates(p_donation uuid, p_at timestamptz, p_day date)
returns table(hub_id uuid, hub_name text, address_text text, latitude double precision,
  longitude double precision, capacity_kg numeric, stored_kg numeric, reserved_kg numeric,
  available_capacity_kg numeric, road_km double precision, operating_hours jsonb,
  open_minutes_on_day numeric, closes_at timestamptz, utilisation_ratio numeric,
  capacity_pressure numeric, feasible boolean, reasons text[])
language plpgsql stable security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare v_d public.donations%rowtype; v_radius integer; v_day_start timestamptz;
begin
  select * into v_d from public.donations where donation_id = p_donation;
  select geofence_radius_m into v_radius from public.coordination_config where singleton;
  if v_d.donation_id is null or v_d.latitude is null or v_d.total_weight_kg is null then return; end if;
  v_day_start := p_day::timestamp at time zone 'Asia/Kuala_Lumpur';
  return query
  with near as (
    select h.* from public.community_hubs h
    where extensions.ST_DWithin(
      extensions.ST_SetSRID(extensions.ST_MakePoint(h.longitude, h.latitude), 4326)::extensions.geography,
      extensions.ST_SetSRID(extensions.ST_MakePoint(v_d.longitude, v_d.latitude), 4326)::extensions.geography,
      v_radius)
  ), routes as (
    select * from public.geolock_donation_hub_routes(p_donation)
  ), usage as (
    select n.hub_id,
      coalesce((select sum(hr.received_weight_kg)
        from public.hub_inventory hi join public.hub_receipts hr using (donation_id)
        where hi.hub_id = n.hub_id
          and hi.inventory_status in ('STORED','BATCHED','RECONCILIATION_REQUIRED')), 0) as stored,
      -- Every booking that still holds space now counts, whatever day it is for.
      coalesce((select sum(r.reserved_weight_kg) from public.hub_reservations r
        where r.hub_id = n.hub_id and r.reservation_status = 'ACTIVE' and r.expires_at > p_at
          and r.donation_id <> p_donation
          and not exists (select 1 from public.hub_receipts hr where hr.reservation_id = r.reservation_id)), 0) as reserved
    from near n
  ), checks as (
    select n.*, u.stored, u.reserved, rt.road_km as km,
      public.geolock_hub_last_close(n.operating_hours, p_day) as close_at,
      public.geolock_hub_open_minutes(n.operating_hours, greatest(p_at, v_day_start),
        public.geolock_hub_last_close(n.operating_hours, p_day)) as open_min,
      n.capacity_kg - u.stored - u.reserved as remaining,
      not exists (select 1 from public.donation_items i
        where i.donation_id = p_donation
          and not exists (select 1 from public.hub_accepted_categories a
                          where a.hub_id = n.hub_id and a.category_id = i.category_id)) as category_ok
    from near n join usage u using (hub_id) left join routes rt using (hub_id)
  )
  select c.hub_id, c.hub_name, c.address_text, c.latitude, c.longitude, c.capacity_kg,
    c.stored, c.reserved, greatest(0, c.remaining)::numeric, c.km, c.operating_hours,
    coalesce(c.open_min, 0), c.close_at,
    case when c.capacity_kg > 0 then round(c.stored / c.capacity_kg, 4) end,
    case when c.remaining > 0 then round(v_d.total_weight_kg / c.remaining, 4) end,
    cardinality(r.reasons) = 0, r.reasons
  from checks c,
  lateral (select array_remove(array[
      case when not c.active_flag then 'HUB_INACTIVE' end,
      case when not public.geolock_hub_is_verified(c.hub_id) then 'HUB_NOT_VERIFIED' end,
      case when c.km is null then 'NO_ROAD_ROUTE' end,
      case when not c.category_ok then 'CATEGORY_NOT_ACCEPTED' end,
      case when c.capacity_kg <= 0 or c.stored < 0 or c.reserved < 0 or c.remaining < 0
           then 'CAPACITY_STATE_INVALID'
           when v_d.total_weight_kg > c.remaining then 'INSUFFICIENT_CAPACITY' end,
      case when not public.geolock_valid_operating_hours(c.operating_hours) then 'HOURS_NOT_SET'
           when coalesce(c.open_min, 0) < public.geolock_min_handover_minutes()
           then 'HUB_CLOSED_ON_DROPOFF_DAY' end
    ], null) as reasons) r;
end $function$;

-- Hubs the donor may choose for one drop-off day (default today), feasible first.
create or replace function public.get_hub_options(p_donation uuid, p_dropoff_date date default null)
returns table(hub_id uuid, hub_name text, address_text text, latitude double precision,
  longitude double precision, capacity_kg numeric, available_capacity_kg numeric,
  road_km double precision, operating_hours jsonb, dropoff_date date,
  open_minutes_on_day numeric, closes_at timestamptz, utilisation_ratio numeric,
  capacity_pressure numeric, feasible boolean, reasons text[])
language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'pg_temp'
as $function$
declare
  v_today date := (statement_timestamp() at time zone 'Asia/Kuala_Lumpur')::date;
  v_day date := coalesce(p_dropoff_date, (statement_timestamp() at time zone 'Asia/Kuala_Lumpur')::date);
begin
  perform public.geolock_assert_donor_hub_choice(p_donation);
  if v_day < v_today or v_day > v_today + 6 then raise exception 'DROPOFF_DATE_OUT_OF_RANGE'; end if;
  -- The AI hub-ranking API ranks only the rows with feasible = true.
  return query
  select c.hub_id, c.hub_name, c.address_text, c.latitude, c.longitude, c.capacity_kg,
    c.available_capacity_kg, c.road_km, c.operating_hours, v_day, c.open_minutes_on_day,
    c.closes_at, c.utilisation_ratio, c.capacity_pressure, c.feasible, c.reasons
  from public.geolock_hub_candidates(p_donation, statement_timestamp(), v_day) c
  order by c.feasible desc, c.road_km nulls last, c.hub_name;
end $function$;

-- Books the hub for the drop-off day. Same checks as before; the booking now lasts
-- until the hub's last closing time that day.
create or replace function public.reserve_hub_capacity(p_donation uuid, p_hub uuid, p_dropoff_date date default null)
returns uuid
language plpgsql security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_actor uuid:=auth.uid(); v_d public.donations%rowtype;
  v_h public.community_hubs%rowtype; v_old_hub uuid;
  v_latest public.hub_reservations%rowtype;
  v_used numeric; v_reserved numeric; v_res uuid; v_active_count integer;
  v_old public.hub_reservations%rowtype;
  v_today date := (clock_timestamp() at time zone 'Asia/Kuala_Lumpur')::date;
  v_day date; v_close timestamptz;
begin
  if v_actor is null then raise exception 'UNAUTHENTICATED'; end if;
  v_day := coalesce(p_dropoff_date, v_today);
  if v_day < v_today or v_day > v_today + 6 then raise exception 'DROPOFF_DATE_OUT_OF_RANGE'; end if;
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

  -- Opening hours on the drop-off day.
  if not public.geolock_valid_operating_hours(v_h.operating_hours) then
    raise exception 'HUB_HOURS_NOT_SET';
  end if;
  v_close := public.geolock_hub_last_close(v_h.operating_hours, v_day);
  if v_close is null or public.geolock_hub_open_minutes(v_h.operating_hours,
       greatest(clock_timestamp(), v_day::timestamp at time zone 'Asia/Kuala_Lumpur'), v_close)
     < public.geolock_min_handover_minutes() then
    raise exception 'HUB_CLOSED_ON_DROPOFF_DAY';
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
  insert into public.hub_reservations(donation_id,hub_id,reserved_weight_kg,expires_at)
  values(p_donation,p_hub,v_d.total_weight_kg,v_close) returning reservation_id into v_res;
  if v_d.donation_status='SUBMITTED' then
    update public.donations set donation_status='HUB_ASSIGNED'
    where donation_id=p_donation;
  end if;
  insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,
    event_type,previous_state,requested_state,resulting_state,outcome,details,
    correlation_id,configuration_version)
  select v_actor,'DONOR','DONATION',p_donation,'RESERVE_HUB',v_d.donation_status,
    'HUB_ASSIGNED','HUB_ASSIGNED','SUCCESS',
    jsonb_build_object('hub_id',p_hub,'reservation_id',v_res,'dropoff_date',v_day,
      'supersedes_reservation_id',v_old.reservation_id),v_res,c.config_version
  from public.coordination_config c where c.singleton;
  return v_res;
end;
$function$;

-- Safety net on every new booking (trigger trg_hub_reservation_opening_hours stays as it is):
-- the hub must be open for at least 30 minutes on the booked day.
create or replace function public.geolock_require_hub_open()
returns trigger
language plpgsql security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_hours jsonb; v_day date;
begin
  if new.reservation_status = 'ACTIVE' then
    if not public.geolock_hub_is_verified(new.hub_id) then
      raise exception 'HUB_NOT_VERIFIED';
    end if;
    select operating_hours into v_hours from public.community_hubs where hub_id = new.hub_id;
    if not public.geolock_valid_operating_hours(v_hours) then
      raise exception 'HUB_HOURS_NOT_SET';
    end if;
    -- The booked day is the day of the closing time (a 24:00 close ends just after it).
    v_day := ((new.expires_at - interval '1 second') at time zone 'Asia/Kuala_Lumpur')::date;
    if public.geolock_hub_open_minutes(v_hours,
         greatest(clock_timestamp(), v_day::timestamp at time zone 'Asia/Kuala_Lumpur'),
         new.expires_at) < public.geolock_min_handover_minutes() then
      raise exception 'HUB_CLOSED_ON_DROPOFF_DAY';
    end if;
  end if;
  return new;
end $function$;

-- Donor's drop-off pass: hold_minutes is gone; the booking shows its drop-off day.
create or replace function public.get_my_hub_dropoff(p_donation uuid)
returns jsonb
language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'pg_temp'
as $function$
declare v_d public.donations%rowtype; v_res public.hub_reservations%rowtype;
  v_h public.community_hubs%rowtype; v_receipt public.hub_receipts%rowtype;
  v_can boolean := false; v_block text; v_status text; v_step text;
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  select * into v_d from public.donations d
  where d.donation_id = p_donation and d.donor_user_id = auth.uid();
  if not found then raise exception 'DONATION_NOT_FOUND_OR_FORBIDDEN'; end if;
  begin
    perform public.geolock_assert_donor_hub_choice(p_donation);
    v_can := true;
  exception when others then
    v_can := false; v_block := sqlerrm;
  end;
  select * into v_res from public.hub_reservations r where r.donation_id = p_donation
  order by r.reserved_at desc, r.reservation_id desc limit 1;
  if v_res.reservation_id is not null then
    select * into v_h from public.community_hubs h where h.hub_id = v_res.hub_id;
    select * into v_receipt from public.hub_receipts hr where hr.reservation_id = v_res.reservation_id;
    v_status := public.geolock_hub_dropoff_status(v_res.reservation_status, v_res.expires_at,
      v_receipt.receipt_id is not null);
  end if;
  v_step := case
    when v_d.collection_path is distinct from 'HUB_COLLECTION' then 'NOT_HUB'
    when v_d.donation_status = 'CANCELLED' then 'CANCELLED'
    when v_d.donation_status in ('COLLECTED') then 'DONE'
    when v_d.donation_status in ('BATCHED','CLAIMED','PICKUP_IN_PROGRESS') then 'IN_BATCH'
    when v_d.donation_status = 'AT_HUB' then 'AT_HUB'
    when v_status = 'AWAITING' then 'DROP_OFF'
    when v_can and v_res.reservation_id is not null then 'CHOOSE_AGAIN'
    when v_can then 'CHOOSE_HUB'
    else 'NOT_HUB' end;
  return jsonb_build_object(
    'donation_id', v_d.donation_id, 'title', v_d.title, 'donation_status', v_d.donation_status,
    'collection_path', v_d.collection_path, 'total_weight_kg', v_d.total_weight_kg,
    'can_choose_hub', v_can, 'choose_block_reason', v_block,
    'next_step', v_step,
    'reservation', case when v_res.reservation_id is null then null else jsonb_build_object(
      'reservation_id', v_res.reservation_id,
      'reference_code', public.geolock_hub_reference(v_res.reservation_id),
      'status', v_status, 'reserved_weight_kg', v_res.reserved_weight_kg,
      'reserved_at', v_res.reserved_at, 'expires_at', v_res.expires_at,
      'dropoff_date', ((v_res.expires_at - interval '1 second') at time zone 'Asia/Kuala_Lumpur')::date,
      'minutes_left', case when v_status = 'AWAITING' then
        ceil(extract(epoch from (v_res.expires_at - statement_timestamp())) / 60)::integer end,
      'received_at', v_receipt.received_at, 'received_weight_kg', v_receipt.received_weight_kg,
      'hub', jsonb_build_object('hub_id', v_h.hub_id, 'hub_name', v_h.hub_name,
        'address_text', v_h.address_text, 'latitude', v_h.latitude, 'longitude', v_h.longitude,
        'operating_hours', v_h.operating_hours)) end);
end $function$;

-- Who may call what.
revoke all on function public.geolock_hub_last_close(jsonb, date) from public, anon, authenticated;
revoke all on function public.geolock_hub_candidates(uuid, timestamptz, date) from public, anon, authenticated;
revoke all on function public.get_hub_options(uuid, date) from public, anon;
revoke all on function public.reserve_hub_capacity(uuid, uuid, date) from public, anon;
grant execute on function public.get_hub_options(uuid, date) to authenticated;
grant execute on function public.reserve_hub_capacity(uuid, uuid, date) to authenticated;

-- 2. Categories are a fixed list ----------------------------------------------------------
-- Categories and their 4 storage needs are kept in Table Editor (donation_categories).
-- Nobody adds categories from the app, so remove the function if an earlier draft added it.
drop function if exists public.create_donation_category(text, boolean, boolean, boolean, boolean);

-- 3. Hub sign-up form lists the categories ----------------------------------------------------
-- The person signing up is not logged in yet, so allow reading active category names and
-- needs (nothing else) without an account.
grant select (category_id, category_name, active_flag, needs_food_safe_storage,
              needs_fragile_shelving, needs_lockable_storeroom, needs_vehicle_access)
  on public.donation_categories to anon;
drop policy if exists category_list_public on public.donation_categories;
create policy category_list_public on public.donation_categories
  for select to anon using (active_flag);

commit;

-- Check (optional): should list today's options without an error for one of your donations.
-- select hub_name, dropoff_date, feasible, reasons, closes_at
-- from public.get_hub_options('<donation uuid>', current_date + 1);
