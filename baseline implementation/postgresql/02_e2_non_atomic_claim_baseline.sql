-- STEP 2 — Non-Atomic Claim baseline objects. Run on an ISOLATED TEST database after
-- 01 (01_GeoLock_Hub_Supabase_Schema_V3_10kg_360min.sql). Never run on production.
--
-- What it implements: the unsafe "read-then-write" claim.
--   1. read the listing WITHOUT a row lock (no SELECT ... FOR UPDATE);
--   2. run the same eligibility checks as public.claim_listing();
--   3. wait p_race_window_ms (the gap between the app's read and its write, e.g. one
--      network round trip);
--   4. write the claim and mark the listing CLAIMED WITHOUT rechecking availability.
-- Claims go to e2_baseline.naive_claims, which has NO one-active-claim unique index.
-- (public.donation_claims has ux_active_claim; that index is part of the proposed
-- protection and would block the duplicate this baseline must be able to produce.)
--
-- Everything else is identical to the proposed method: same tables for NGOs, donations
-- and listings, same 20 km geofence, same 360-minute lease, same request identity.
--
-- The Protected-Claim-without-Lease-Recovery baseline needs no SQL: it calls the real
-- public.claim_listing() and never runs public.recover_expired_claims().
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
-- Deliberately NOT unique: several ACTIVE claims per listing are possible.
create index if not exists idx_naive_claims_listing on e2_baseline.naive_claims (listing_id);

create or replace function e2_baseline.non_atomic_claim_listing(
  p_listing uuid, p_request uuid, p_race_window_ms integer default 50)
returns jsonb
language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_actor  uuid := auth.uid();
  v_ngo    public.ngo_profiles%rowtype;
  v_l      public.listings%rowtype;
  v_cfg    public.coordination_config%rowtype;
  v_reason text;
  v_claim  uuid;
begin
  if v_actor is null then raise exception 'UNAUTHENTICATED'; end if;
  select * into v_ngo from public.ngo_profiles where user_id = v_actor and active_flag;
  if not found then raise exception 'ACTIVE_NGO_ONLY'; end if;
  if p_request is null or p_listing is null then raise exception 'REQUEST_AND_LISTING_REQUIRED'; end if;
  select * into v_cfg from public.coordination_config where singleton;

  -- (1) UNSAFE READ: no FOR UPDATE, so concurrent requests all read the same state.
  select * into v_l from public.listings where listing_id = p_listing;

  -- (2) Same checks, same order and same reason codes as public.claim_listing().
  if not found then v_reason := 'LISTING_NOT_FOUND';
  elsif v_l.listing_status <> 'AVAILABLE' then v_reason := 'CLAIM_CONFLICT';
  elsif v_l.listing_expires_at is not null and v_l.listing_expires_at <= clock_timestamp()
    then v_reason := 'LISTING_EXPIRED';
  elsif v_ngo.location_verified_at is null then v_reason := 'ELIGIBILITY_UNDETERMINED';
  elsif not ST_DWithin(
      ST_SetSRID(ST_MakePoint(v_ngo.longitude, v_ngo.latitude), 4326)::geography,
      ST_SetSRID(ST_MakePoint(v_l.pickup_longitude, v_l.pickup_latitude), 4326)::geography,
      v_cfg.geofence_radius_m) then v_reason := 'NGO_INELIGIBLE';
  elsif v_l.pickup_road_node_id is null then v_reason := 'ROUTING_NODE_MISSING';
  elsif v_l.source_type = 'DIRECT_DONATION' and not exists (
      select 1 from public.donations d where d.donation_id = v_l.donation_id
        and d.donation_status = 'READY_FOR_PICKUP'
        and (d.availability_start is null or d.availability_start <= clock_timestamp()))
    then v_reason := 'DONATION_NOT_READY';
  end if;
  if v_reason is not null then
    return jsonb_build_object('outcome', case when v_reason = 'NGO_INELIGIBLE' then 'INELIGIBLE' else 'CONFLICT' end,
                              'claim_id', null, 'reason_code', v_reason);
  end if;

  -- (3) Gap between the availability read and the ownership write.
  perform pg_sleep(greatest(coalesce(p_race_window_ms, 0), 0) / 1000.0);

  -- (4) UNSAFE WRITE: no recheck of the listing and no uniqueness guard.
  insert into e2_baseline.naive_claims (listing_id, ngo_user_id, request_id, expires_at)
  values (p_listing, v_actor, p_request, clock_timestamp() + make_interval(mins => v_cfg.claim_lease_minutes))
  returning claim_id into v_claim;
  update public.listings set listing_status = 'CLAIMED', listing_version = listing_version + 1
   where listing_id = p_listing;
  return jsonb_build_object('outcome', 'SUCCESS', 'claim_id', v_claim, 'reason_code', null);
end $$;

revoke all on function e2_baseline.non_atomic_claim_listing(uuid, uuid, integer) from public;
grant usage on schema e2_baseline to authenticated;
grant execute on function e2_baseline.non_atomic_claim_listing(uuid, uuid, integer) to authenticated;
