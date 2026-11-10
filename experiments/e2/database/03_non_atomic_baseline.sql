-- E2 baseline 1: Non-Atomic Claim, adapted from "baseline implementation/source code/non_atomic_claim_baseline.py".
-- A claim done in two separate steps, without GeoLock's protection:
--   step 1, non_atomic_check_listing(): read the listing without a lock and run the same checks as claim_listing()
--   step 2, non_atomic_write_claim(): save the claim and mark the listing CLAIMED, without checking again
-- The harness lets every NGO finish step 1 before any NGO starts step 2. Claims go into their own table,
-- which has no one active claim rule; public.donation_claims is never touched.
create schema if not exists e2_baseline;
create table if not exists e2_baseline.naive_claims (
  claim_id     uuid primary key default gen_random_uuid(),
  listing_id   uuid not null references public.listings(listing_id),
  ngo_user_id  uuid not null references public.ngo_profiles(user_id),
  request_id   uuid not null unique,
  claim_status text not null default 'ACTIVE' check (claim_status = 'ACTIVE'),
  claimed_at   timestamptz not null default clock_timestamp(),
  expires_at   timestamptz not null
);
create index if not exists idx_naive_claims_listing on e2_baseline.naive_claims (listing_id);

-- step 1: read and check (no lock)
create or replace function e2_baseline.non_atomic_check_listing(p_listing uuid)
returns jsonb language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_actor uuid := auth.uid(); v_ngo public.ngo_profiles%rowtype; v_l public.listings%rowtype;
  v_reason text; v_geo text;
begin
  if v_actor is null then raise exception 'UNAUTHENTICATED'; end if;
  select * into v_ngo from public.ngo_profiles where user_id = v_actor and active_flag;
  if not found then raise exception 'ACTIVE_NGO_ONLY'; end if;
  if p_listing is null then raise exception 'REQUEST_AND_LISTING_REQUIRED'; end if;
  select * into v_l from public.listings where listing_id = p_listing;
  if not found then v_reason := 'LISTING_NOT_FOUND';
  elsif v_l.listing_status <> 'AVAILABLE' then v_reason := 'CLAIM_CONFLICT';
  elsif v_l.listing_expires_at is not null and v_l.listing_expires_at <= clock_timestamp() then v_reason := 'LISTING_EXPIRED';
  elsif v_ngo.location_verified_at is null or v_ngo.road_node_id is null then v_reason := 'ELIGIBILITY_UNDETERMINED';
  else
    v_geo := public.geolock_ngo_listing_road_check(v_actor, p_listing)->>'outcome';
    if v_geo <> 'ELIGIBLE' then v_reason := v_geo;
    elsif v_l.source_type = 'DIRECT_DONATION' and not exists (
        select 1 from public.donations d where d.donation_id = v_l.donation_id and d.donation_status = 'AVAILABLE')
      then v_reason := 'DONATION_NOT_READY';
    end if;
  end if;
  if v_reason is not null then
    return jsonb_build_object('outcome', case when v_reason in ('OUTSIDE_GEOFENCE','ROUTE_UNAVAILABLE') then 'INELIGIBLE' else 'CONFLICT' end,
                              'claim_id', null, 'reason_code', v_reason);
  end if;
  return jsonb_build_object('outcome', 'AVAILABLE', 'claim_id', null, 'reason_code', null);
end $$;

-- step 2: write the claim without checking again
create or replace function e2_baseline.non_atomic_write_claim(p_listing uuid, p_request uuid)
returns jsonb language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
declare v_actor uuid := auth.uid(); v_cfg public.coordination_config%rowtype; v_claim uuid;
begin
  if v_actor is null then raise exception 'UNAUTHENTICATED'; end if;
  if p_request is null or p_listing is null then raise exception 'REQUEST_AND_LISTING_REQUIRED'; end if;
  select * into v_cfg from public.coordination_config where singleton;
  insert into e2_baseline.naive_claims (listing_id, ngo_user_id, request_id, expires_at)
  values (p_listing, v_actor, p_request, clock_timestamp() + make_interval(mins => v_cfg.claim_lease_minutes))
  returning claim_id into v_claim;
  update public.listings set listing_status = 'CLAIMED', listing_version = listing_version + 1 where listing_id = p_listing;
  return jsonb_build_object('outcome', 'SUCCESS', 'claim_id', v_claim, 'reason_code', null);
end $$;

revoke all on function e2_baseline.non_atomic_check_listing(uuid) from public;
revoke all on function e2_baseline.non_atomic_write_claim(uuid, uuid) from public;
grant usage on schema e2_baseline to authenticated;
grant execute on function e2_baseline.non_atomic_check_listing(uuid) to authenticated;
grant execute on function e2_baseline.non_atomic_write_claim(uuid, uuid) to authenticated;
grant usage on schema e2_bench to authenticated, service_role;
grant select on e2_bench.road_km to authenticated, service_role;
