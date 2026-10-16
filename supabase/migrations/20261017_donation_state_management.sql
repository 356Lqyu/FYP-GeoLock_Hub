-- GeoLock Hub donation reads, eligible-hub lookup, and safe donor cancellation.
-- Target: an already-installed GeoLock Hub V3_10kg_360min schema.
-- Review and deploy manually. This migration does not execute or alter records.

begin;

-- Flutter expects an array of {category_id, category_name} objects from a
-- zero-argument PostgREST RPC. Require any registered role, not anonymous Auth.
create or replace function public.get_active_donation_categories()
returns table(category_id uuid, category_name text)
language plpgsql
stable
security definer
set search_path = pg_catalog, public, pg_temp
as $$
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED';
  end if;
  if not exists (
    select 1 from public.user_profiles p where p.user_id = auth.uid()
  ) then
    raise exception 'PROFILE_REQUIRED';
  end if;

  return query
  select c.category_id, c.category_name
  from public.donation_categories c
  where c.active_flag
  order by c.category_name;
end;
$$;

-- Donor-owned capacity and category lookup used by the existing hub
-- reservation UI. This is read-only; reserve_hub_capacity remains authoritative.
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
language plpgsql
stable
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_donation public.donations%rowtype;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED';
  end if;

  select d.* into v_donation
  from public.donations d
  where d.donation_id = p_donation
    and d.donor_user_id = auth.uid();
  if not found then
    raise exception 'DONATION_NOT_FOUND_OR_FORBIDDEN';
  end if;
  if v_donation.donation_status <> 'VALIDATED'
     or v_donation.collection_path <> 'HUB_COLLECTION' then
    raise exception 'DONATION_NOT_HUB_ELIGIBLE';
  end if;

  return query
  with hub_usage as (
    select h.hub_id,
      coalesce((
        select sum(hr.received_weight_kg)
        from public.hub_inventory hi
        join public.hub_receipts hr using (donation_id)
        where hi.hub_id = h.hub_id
          and hi.inventory_status in ('STORED', 'BATCHED', 'RECONCILIATION_REQUIRED')
      ), 0)
      + coalesce((
        select sum(r.reserved_weight_kg)
        from public.hub_reservations r
        where r.hub_id = h.hub_id
          and r.reservation_status = 'ACTIVE'
          and r.expires_at > statement_timestamp()
          and not exists (
            select 1 from public.hub_receipts hr
            where hr.reservation_id = r.reservation_id
          )
      ), 0) as used_kg
    from public.community_hubs h
  )
  select h.hub_id, h.hub_name, h.address_text, h.latitude, h.longitude,
    h.capacity_kg, greatest(0, h.capacity_kg - u.used_kg)::numeric
  from public.community_hubs h
  join hub_usage u on u.hub_id = h.hub_id
  where h.active_flag
    and u.used_kg + v_donation.total_weight_kg <= h.capacity_kg
    and not exists (
      select 1
      from public.donation_items i
      where i.donation_id = v_donation.donation_id
        and not exists (
          select 1 from public.hub_accepted_categories a
          where a.hub_id = h.hub_id and a.category_id = i.category_id
        )
    )
  order by h.hub_name;
end;
$$;

-- Listing and detail data is restricted to the authenticated donor. Routing
-- status is deliberately conservative because V3 has no trusted graph status
-- column: a stored node value is not represented as verified.
create or replace function public.get_my_donations()
returns table(
  donation_id uuid,
  title text,
  donation_status text,
  collection_path text,
  total_weight_kg numeric,
  created_at timestamptz,
  hub_name text,
  reservation_status text,
  listing_routing_status text
)
language plpgsql
stable
security definer
set search_path = pg_catalog, public, pg_temp
as $$
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED';
  end if;
  if not exists (
    select 1 from public.donor_profiles dp where dp.user_id = auth.uid()
  ) then
    raise exception 'DONOR_ONLY';
  end if;

  return query
  select d.donation_id, d.title, d.donation_status, d.collection_path,
    d.total_weight_kg, d.created_at,
    latest.hub_name, latest.reservation_status,
    case
      when l.listing_id is null then null::text
      when l.pickup_road_node_id is null then 'PENDING_NODE'::text
      else 'UNVERIFIED'::text
    end as listing_routing_status
  from public.donations d
  left join lateral (
    select h.hub_name, r.reservation_status
    from public.hub_reservations r
    join public.community_hubs h using (hub_id)
    where r.donation_id = d.donation_id
    order by r.reserved_at desc
    limit 1
  ) latest on true
  left join public.listings l
    on l.donation_id = d.donation_id
   and l.source_type = 'DIRECT_DONATION'
  where d.donor_user_id = auth.uid()
  order by d.created_at desc, d.donation_id;
end;
$$;

-- Return SQL NULL when the donation is absent or belongs to another donor.
-- All pickup address/coordinate data is returned only after the ownership filter.
create or replace function public.get_my_donation_detail(p_donation uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_result jsonb;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED';
  end if;
  if not exists (
    select 1 from public.donor_profiles dp where dp.user_id = auth.uid()
  ) then
    raise exception 'DONOR_ONLY';
  end if;

  select jsonb_build_object(
    'donation_id', d.donation_id,
    'title', d.title,
    'description', d.description,
    'status', d.donation_status,
    'donation_status', d.donation_status,
    'collection_path', d.collection_path,
    'total_weight_kg', d.total_weight_kg,
    'pickup_address', d.pickup_address,
    'latitude', d.latitude,
    'longitude', d.longitude,
    'created_at', d.created_at,
    'updated_at', d.updated_at,
    'availability_start', d.availability_start,
    'availability_end', d.availability_end,
    'listing_status', l.listing_status,
    'road_node_status', case
      when l.listing_id is null then null
      when l.pickup_road_node_id is null then 'PENDING_NODE'
      else 'UNVERIFIED'
    end,
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'item_id', i.item_id,
        'category_id', i.category_id,
        'category', c.category_name,
        'item_name', i.item_name,
        'description', i.description,
        'quantity', i.quantity,
        'unit_label', i.unit_label,
        'unit_weight_kg', i.unit_weight_kg,
        'item_condition', i.item_condition
      ) order by i.created_at, i.item_id)
      from public.donation_items i
      join public.donation_categories c using (category_id)
      where i.donation_id = d.donation_id
    ), '[]'::jsonb),
    'hub_reservations', coalesce((
      select jsonb_agg(jsonb_build_object(
        'reservation_id', r.reservation_id,
        'hub_id', r.hub_id,
        'hub_name', h.hub_name,
        'status', r.reservation_status,
        'reserved_weight_kg', r.reserved_weight_kg,
        'reserved_at', r.reserved_at,
        'expires_at', r.expires_at,
        'receipt_status', hr.receipt_status,
        'received_weight_kg', hr.received_weight_kg,
        'received_at', hr.received_at
      ) order by r.reserved_at desc)
      from public.hub_reservations r
      join public.community_hubs h using (hub_id)
      left join public.hub_receipts hr
        on hr.reservation_id = r.reservation_id
      where r.donation_id = d.donation_id
    ), '[]'::jsonb)
  ) into v_result
  from public.donations d
  left join public.listings l
    on l.donation_id = d.donation_id
   and l.source_type = 'DIRECT_DONATION'
  where d.donation_id = p_donation
    and d.donor_user_id = auth.uid();

  return v_result;
end;
$$;

-- Keep idempotency records separate from claim_requests, whose key and foreign
-- keys have claim-specific meaning. App users cannot read or write this table.
create table if not exists public.donation_cancellation_requests (
  request_id uuid primary key,
  donor_user_id uuid not null,
  donation_id uuid not null,
  request_fingerprint text not null,
  response jsonb,
  created_at timestamptz not null default clock_timestamp(),
  completed_at timestamptz,
  check (response is null or jsonb_typeof(response) = 'object')
);
alter table public.donation_cancellation_requests enable row level security;
revoke all on public.donation_cancellation_requests from public, anon, authenticated;

-- Cancellation lock order is designed around V3:
-- * direct pickup locks listing, then donation, matching start_pickup's order;
-- * hub collection locks donation only, matching reserve_hub_capacity;
-- * this function never locks or changes hub reservation/receipt rows.
-- HUB_ASSIGNED and all later states are conservatively non-cancellable. This
-- avoids racing confirm_hub_receipt (hub -> reservation -> donation) and never
-- releases reserved capacity after a hub handover may be in progress.
create or replace function public.cancel_donation(p_donation uuid, p_request uuid)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_actor_role text;
  v_owner uuid;
  v_path text;
  v_previous text;
  v_listing uuid;
  v_listing_status text;
  v_fingerprint text;
  v_request public.donation_cancellation_requests%rowtype;
  v_response jsonb;
  v_outcome text;
  v_reason text;
  v_result_state text;
begin
  if v_actor is null then
    raise exception 'UNAUTHENTICATED';
  end if;
  if p_request is null then
    raise exception 'REQUEST_ID_REQUIRED';
  end if;
  if p_donation is null then
    raise exception 'DONATION_ID_REQUIRED';
  end if;

  select p.role into v_actor_role
  from public.user_profiles p where p.user_id = v_actor;

  -- Do not reserve a caller-chosen request UUID for a donation the caller
  -- does not own. Otherwise an unauthorized caller who guesses/reuses a UUID
  -- could poison the owner's future idempotency key. Record the rejected
  -- attempt in the append-only audit table and return without touching the
  -- idempotency table. A normal return commits this rejection audit.
  select d.donor_user_id into v_owner
  from public.donations d
  where d.donation_id = p_donation;
  if not found or v_owner is distinct from v_actor
     or not exists (
       select 1 from public.donor_profiles dp where dp.user_id = v_actor
     ) then
    insert into public.audit_events(
      actor_user_id, actor_role, entity_type, entity_id, event_type,
      request_id, correlation_id, requested_state, resulting_state,
      reason_code, outcome, details, configuration_version
    ) values (
      v_actor, v_actor_role, 'DONATION', p_donation, 'CANCEL_DONATION',
      p_request, p_request, 'CANCELLED', null,
      'DONATION_NOT_FOUND_OR_FORBIDDEN', 'REJECTED',
      jsonb_build_object('request_id', p_request),
      (select c.config_version from public.coordination_config c where c.singleton)
    );
    return jsonb_build_object(
      'outcome', 'REJECTED',
      'donation_id', p_donation,
      'reason_code', 'DONATION_NOT_FOUND_OR_FORBIDDEN'
    );
  end if;

  v_fingerprint := v_actor::text || ':' || coalesce(p_donation::text, 'NULL');

  insert into public.donation_cancellation_requests(
    request_id, donor_user_id, donation_id, request_fingerprint
  ) values (p_request, v_actor, p_donation, v_fingerprint)
  on conflict (request_id) do nothing;

  select r.* into v_request
  from public.donation_cancellation_requests r
  where r.request_id = p_request
  for update;

  if v_request.request_fingerprint <> v_fingerprint then
    v_response := jsonb_build_object(
      'outcome', 'REJECTED',
      'donation_id', p_donation,
      'reason_code', 'IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD'
    );
    insert into public.audit_events(
      actor_user_id, actor_role, entity_type, entity_id, event_type,
      request_id, correlation_id, requested_state, resulting_state,
      reason_code, outcome, details, configuration_version
    ) values (
      v_actor, v_actor_role, 'DONATION', p_donation, 'CANCEL_DONATION',
      p_request, p_request, 'CANCELLED', null,
      'IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD', 'REJECTED',
      jsonb_build_object('request_id', p_request),
      (select c.config_version from public.coordination_config c where c.singleton)
    );
    return v_response;
  end if;

  if v_request.response is not null then
    return v_request.response;
  end if;

  -- Do not use an unlocked collection_path read to decide which lock to take.
  -- NGO claim/pickup functions lock listing before donation, so lock any direct
  -- donation listing by its stable relation first, then read the authoritative
  -- path and state from the donation row while holding that row lock. If the
  -- path is HUB_COLLECTION, an unexpected direct listing is rejected below.
  select l.listing_id, l.listing_status
  into v_listing, v_listing_status
  from public.listings l
  where l.donation_id = p_donation
    and l.source_type = 'DIRECT_DONATION'
  for update;

  select d.donor_user_id, d.collection_path, d.donation_status
  into v_owner, v_path, v_previous
  from public.donations d
  where d.donation_id = p_donation
  for update;

  if not found then
    v_reason := 'DONATION_NOT_FOUND_OR_FORBIDDEN';
  elsif v_owner is distinct from v_actor
     or not exists (select 1 from public.donor_profiles dp where dp.user_id = v_actor) then
    v_reason := 'DONATION_NOT_FOUND_OR_FORBIDDEN';
  elsif v_previous = 'CANCELLED' then
      v_outcome := 'SUCCESS';
      v_reason := 'ALREADY_CANCELLED';
  elsif v_previous not in ('SUBMITTED', 'VALIDATED', 'READY_FOR_PICKUP') then
    v_reason := 'CANCELLATION_NOT_PERMITTED';
  elsif v_previous = 'READY_FOR_PICKUP'
     and v_path is distinct from 'DIRECT_PICKUP' then
    v_reason := 'DONATION_COLLECTION_PATH_INCONSISTENT';
  elsif v_previous = 'READY_FOR_PICKUP' and v_listing is null then
    v_reason := 'DIRECT_LISTING_MISSING';
  elsif v_path = 'HUB_COLLECTION' and v_listing is not null then
    v_reason := 'DONATION_LISTING_PATH_INCONSISTENT';
  elsif exists (
      select 1
      from public.hub_receipts hr
      where hr.donation_id = p_donation
    ) or exists (
      select 1
      from public.hub_inventory hi
      where hi.donation_id = p_donation
    ) or exists (
      select 1
      from public.hub_batch_members bm
      where bm.donation_id = p_donation
        and bm.membership_status = 'ACTIVE'
    ) then
    v_reason := 'DONATION_HAS_PHYSICAL_CUSTODY';
  elsif exists (
      select 1
      from public.pickup_tasks pt
      join public.donation_claims c using (claim_id)
      join public.listings l using (listing_id)
      where l.source_type = 'DIRECT_DONATION'
        and l.donation_id = p_donation
        and pt.task_status in ('DISPATCHED', 'COLLECTED')
    ) then
    v_reason := 'PICKUP_HANDOVER_MAY_HAVE_OCCURRED';
  elsif exists (
      select 1
      from public.hub_reservations r
      where r.donation_id = p_donation
        and r.reservation_status = 'ACTIVE'
    ) then
    v_reason := 'DONATION_HAS_ACTIVE_HUB_RESERVATION';
  elsif exists (
      select 1
      from public.donation_claims c
      join public.listings l using (listing_id)
      left join public.claim_leases le using (claim_id)
      where l.source_type = 'DIRECT_DONATION'
        and l.donation_id = p_donation
        and (
          c.claim_status in ('ACTIVE', 'RECONCILIATION_REQUIRED')
          or le.lease_status in ('ACTIVE', 'RECONCILIATION_REQUIRED')
        )
    ) or v_listing_status = 'CLAIMED' then
    v_reason := 'DONATION_HAS_ACTIVE_CLAIM';
  elsif v_listing_status in ('CLOSED', 'CANCELLED') then
    v_reason := 'LISTING_NOT_CANCELLABLE';
  else
    -- A safe released/expired claim has no active lease and may be cancelled.
    -- All state changes are guarded again by V3 transition triggers.
    update public.donations
    set donation_status = 'CANCELLED'
    where donation_id = p_donation;

    if v_listing is not null and v_listing_status = 'AVAILABLE' then
      update public.listings
      set listing_status = 'CANCELLED', listing_version = listing_version + 1
      where listing_id = v_listing and listing_status = 'AVAILABLE';
    end if;

    v_outcome := 'SUCCESS';
    v_reason := 'DONOR_REQUEST';
  end if;

  if v_outcome is distinct from 'SUCCESS' then
    v_outcome := 'REJECTED';
  end if;
  v_result_state := case when v_outcome = 'SUCCESS' then 'CANCELLED' else v_previous end;
  v_response := jsonb_build_object(
    'outcome', v_outcome,
    'donation_id', p_donation,
    'reason_code', v_reason,
    'resulting_state', v_result_state
  );

  update public.donation_cancellation_requests
  set response = v_response, completed_at = clock_timestamp()
  where request_id = p_request;

  insert into public.audit_events(
    actor_user_id, actor_role, entity_type, entity_id, event_type,
    request_id, correlation_id,
    previous_state, requested_state, resulting_state,
    reason_code, outcome, details, configuration_version
  ) values (
    v_actor, v_actor_role, 'DONATION', p_donation, 'CANCEL_DONATION',
    p_request, p_request,
    v_previous, 'CANCELLED', v_result_state,
    v_reason, v_outcome,
    jsonb_build_object('request_id', p_request),
    (select c.config_version from public.coordination_config c where c.singleton)
  );

  return v_response;
end;
$$;

revoke all on function public.get_active_donation_categories() from public, anon;
revoke all on function public.get_eligible_hubs(uuid) from public, anon;
revoke all on function public.get_my_donations() from public, anon;
revoke all on function public.get_my_donation_detail(uuid) from public, anon;
revoke all on function public.cancel_donation(uuid, uuid) from public, anon;

grant execute on function public.get_active_donation_categories() to authenticated;
grant execute on function public.get_eligible_hubs(uuid) to authenticated;
grant execute on function public.get_my_donations() to authenticated;
grant execute on function public.get_my_donation_detail(uuid) to authenticated;
grant execute on function public.cancel_donation(uuid, uuid) to authenticated;

notify pgrst, 'reload schema';
commit;
