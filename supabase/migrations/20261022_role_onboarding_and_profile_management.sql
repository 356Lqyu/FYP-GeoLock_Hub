-- GeoLock Hub role onboarding and protected profile updates.
-- Forward-only. Apply after V3 and the operational road-network migration.
-- This migration does not change donation, listing, lease, or hub capacity rules.

begin;

do $$
begin
  if to_regprocedure('public.register_role_profile(text,text,text,text,text,text,double precision,double precision,text)') is null
     or to_regprocedure('public.get_my_profile()') is null
     or to_regprocedure('public.register_community_hub(text,text,double precision,double precision,numeric,text)') is null
     or to_regprocedure('public.claim_listing(uuid,uuid)') is null
     or to_regprocedure('public.geolock_resolve_road_node(double precision,double precision)') is null
     or to_regprocedure('public.geolock_refresh_ngo_road_eligibility(uuid)') is null then
    raise exception 'ROLE_ONBOARDING_REQUIRED_RPC_MISSING';
  end if;

  if to_regclass('public.user_profiles') is null
     or to_regclass('public.donor_profiles') is null
     or to_regclass('public.ngo_profiles') is null
     or to_regclass('public.hub_admin_profiles') is null
     or to_regclass('public.community_hubs') is null
     or to_regclass('public.road_network_coverage') is null
     or to_regclass('public.ngo_listing_road_eligibility') is null
     or to_regclass('public.vehicles') is null
     or to_regclass('public.donation_claims') is null
     or to_regclass('public.claim_leases') is null
     or to_regclass('public.hub_inventory') is null
     or to_regclass('public.hub_reservations') is null
     or to_regclass('public.hub_batch_members') is null
     or to_regclass('public.hub_batches') is null
     or to_regclass('public.audit_events') is null
     or to_regclass('public.coordination_config') is null then
    raise exception 'ROLE_ONBOARDING_REQUIRED_TABLE_MISSING';
  end if;

  if (select count(*) from public.road_network_coverage
       where active_flag and dataset_kind='OPERATIONAL' and approved_at is not null
         and max_snap_distance_m=500) <> 1 then
    raise exception 'ONE_APPROVED_500M_OPERATIONAL_SNAPSHOT_REQUIRED';
  end if;
  if (select count(*) from public.coordination_config
       where singleton and donation_direct_min_kg=10
         and geofence_radius_m=20000 and claim_lease_minutes=360
         and hub_reservation_minutes=120) <> 1 then
    raise exception 'EXPECTED_LIFECYCLE_CONFIGURATION_MISSING';
  end if;
end;
$$;

-- NGO role profiles exist before an operating location is selected. Existing
-- address and coordinate checks accept NULL, so keep their constraints intact.
alter table public.ngo_profiles alter column operating_address drop not null;
alter table public.ngo_profiles alter column latitude drop not null;
alter table public.ngo_profiles alter column longitude drop not null;

-- Keep onboarding profile reads and ownership checks indexed by hub admin.
create index if not exists ix_community_hubs_admin_onboarding
  on public.community_hubs(admin_user_id,active_flag,created_at desc);

-- Preserve the deployed signature and account-role immutability. The accepted
-- legacy location arguments are intentionally ignored: only the authenticated
-- post-login location RPC may write trusted NGO coordinates or road_node_id.
create or replace function public.register_role_profile(
  p_full_name text,
  p_role text,
  p_phone text default null,
  p_ngo_name text default null,
  p_registration_number text default null,
  p_operating_address text default null,
  p_latitude double precision default null,
  p_longitude double precision default null,
  p_road_node_id text default null
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public, extensions, pg_temp
as $$
declare
  v_user uuid := auth.uid();
begin
  if v_user is null then raise exception 'UNAUTHENTICATED'; end if;
  if p_role is null or p_role not in ('DONOR','NGO','HUB_ADMIN') then
    raise exception 'ROLE_NOT_SELF_SERVICE';
  end if;
  if nullif(btrim(p_full_name),'') is null then raise exception 'FULL_NAME_REQUIRED'; end if;
  if p_role='NGO' and nullif(btrim(p_ngo_name),'') is null then
    raise exception 'NGO_NAME_REQUIRED';
  end if;
  if exists(select 1 from public.user_profiles u where u.user_id=v_user) then
    raise exception 'ROLE_ALREADY_REGISTERED';
  end if;

  insert into public.user_profiles(user_id,full_name,phone_number,role)
  values(v_user,btrim(p_full_name),nullif(btrim(p_phone),''),p_role);

  if p_role='DONOR' then
    insert into public.donor_profiles(user_id) values(v_user);
  elsif p_role='NGO' then
    insert into public.ngo_profiles(user_id,ngo_name,registration_number)
    values(v_user,btrim(p_ngo_name),nullif(btrim(p_registration_number),''));
  else
    insert into public.hub_admin_profiles(user_id) values(v_user);
  end if;

  insert into public.audit_events(
    actor_user_id,actor_role,entity_type,entity_id,event_type,
    requested_state,resulting_state,reason_code,outcome,details
  ) values(
    v_user,p_role,'USER',v_user,'REGISTER_ROLE',p_role,p_role,
    case p_role when 'NGO' then 'NGO_LOCATION_SETUP_REQUIRED'
                when 'HUB_ADMIN' then 'HUB_SETUP_REQUIRED' end,
    'SUCCESS',jsonb_build_object('location_supplied_during_signup',false)
  );
  return v_user;
end;
$$;

-- Profile reads remain indexed point lookups. This function does not run road
-- routing, distance calculations, or eligibility refreshes.
create or replace function public.get_my_profile()
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_profile jsonb;
begin
  if v_user is null then raise exception 'UNAUTHENTICATED'; end if;

  select jsonb_build_object(
    'user_id',u.user_id,
    'full_name',u.full_name,
    'phone_number',u.phone_number,
    'role',u.role,
    'created_at',u.created_at,
    'ngo_name',n.ngo_name,
    'registration_number',n.registration_number,
    'operating_address',n.operating_address,
    'latitude',n.latitude,
    'longitude',n.longitude,
    'road_node_id',n.road_node_id,
    'location_verified_at',n.location_verified_at,
    'location_status',case
      when u.role<>'NGO' then null
      when n.user_id is null or n.location_verified_at is null
        or n.road_node_id is null then 'SETUP_REQUIRED'
      else 'VERIFIED'
    end,
    'ngo_location_setup_required',u.role='NGO' and
      (n.user_id is null or n.location_verified_at is null or n.road_node_id is null),
    'hub_admin',hadmin.user_id is not null,
    'hub_id',hub.hub_id,
    'hub_name',hub.hub_name,
    'hub_address',hub.address_text,
    'hub_latitude',hub.latitude,
    'hub_longitude',hub.longitude,
    'hub_road_node_id',hub.road_node_id,
    'hub_capacity_kg',hub.capacity_kg,
    'hub_active',hub.active_flag,
    'hub_setup_required',u.role='HUB_ADMIN' and
      (hub.hub_id is null or not hub.active_flag or hub.road_node_id is null),
    'onboarding_status',case
      when u.role='DONOR' then 'COMPLETE'
      when u.role='NGO' and n.location_verified_at is not null and n.road_node_id is not null then 'COMPLETE'
      when u.role='NGO' then 'LOCATION_REQUIRED'
      when u.role='HUB_ADMIN' and hub.hub_id is not null
        and hub.active_flag and hub.road_node_id is not null then 'COMPLETE'
      else 'HUB_REQUIRED'
    end
  ) into v_profile
  from public.user_profiles u
  left join public.ngo_profiles n on n.user_id=u.user_id
  left join public.hub_admin_profiles hadmin on hadmin.user_id=u.user_id
  left join lateral (
    select h.hub_id,h.hub_name,h.address_text,h.latitude,h.longitude,
           h.road_node_id,h.capacity_kg,h.active_flag
      from public.community_hubs h
     where h.admin_user_id=u.user_id
     order by h.active_flag desc,h.created_at desc,h.hub_id
     limit 1
  ) hub on true
  where u.user_id=v_user;
  return v_profile;
end;
$$;

-- The same NGO profile row serializes this update with claim_listing(). A
-- claimant takes FOR SHARE before eligibility evaluation; location updates take
-- FOR UPDATE before checking claims, so exactly one side proceeds first.
create or replace function public.set_ngo_operating_location(
  p_operating_address text,
  p_latitude double precision,
  p_longitude double precision
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_ngo public.ngo_profiles%rowtype;
  v_snapshot text;
  v_node text;
  v_snap_distance double precision;
  v_resolved_snapshot text;
begin
  if v_user is null then raise exception 'UNAUTHENTICATED'; end if;
  if nullif(btrim(p_operating_address),'') is null
     or p_latitude is null or p_longitude is null
     or p_latitude not between -90 and 90
     or p_longitude not between -180 and 180 then
    raise exception 'INVALID_NGO_LOCATION';
  end if;

  -- Lock the active approved snapshot first. Snapshot activation updates this
  -- row and therefore cannot change the graph mid-validation/refresh.
  select c.network_snapshot_id into v_snapshot
    from public.road_network_coverage c
   where c.active_flag and c.dataset_kind='OPERATIONAL'
     and c.approved_at is not null and c.max_snap_distance_m=500
   for share;
  if v_snapshot is null then raise exception 'OPERATIONAL_ROAD_COVERAGE_UNAVAILABLE'; end if;

  select * into v_ngo from public.ngo_profiles n
   where n.user_id=v_user and n.active_flag for update;
  if not found then raise exception 'ACTIVE_NGO_PROFILE_REQUIRED'; end if;

  -- Missing leases and mismatched claim/lease terminal states fail closed.
  if exists(
    select 1 from public.donation_claims c
     where c.ngo_user_id=v_user and (
       c.claim_status in ('ACTIVE','RECONCILIATION_REQUIRED')
       or exists(select 1 from public.claim_leases le
                  where le.claim_id=c.claim_id
                    and le.lease_status in ('ACTIVE','RECONCILIATION_REQUIRED'))
       or not exists(select 1 from public.claim_leases le where le.claim_id=c.claim_id
          and ((c.claim_status='COMPLETED' and le.lease_status='COMPLETED')
            or (c.claim_status in ('RELEASED','EXPIRED','CANCELLED')
                and le.lease_status in ('RELEASED','EXPIRED'))))
     )
  ) then raise exception 'NGO_HAS_ACTIVE_OR_UNRESOLVED_CLAIMS'; end if;

  select r.node_id,r.snap_distance_m,r.snapshot_id
    into v_node,v_snap_distance,v_resolved_snapshot
    from public.geolock_resolve_road_node(p_latitude,p_longitude) r;
  if v_node is null or v_snap_distance is null or v_snap_distance<0
     or v_snap_distance>500 or v_resolved_snapshot is distinct from v_snapshot then
    raise exception 'NGO_LOCATION_NOT_ROUTABLE';
  end if;

  update public.ngo_profiles set operating_address=btrim(p_operating_address),
    latitude=p_latitude,longitude=p_longitude,road_node_id=v_node,
    location_verified_at=clock_timestamp()
   where user_id=v_user;
  -- Existing trigger derives vehicle depots from this trusted NGO node.
  update public.vehicles set depot_road_node_id=null where ngo_user_id=v_user;
  perform public.geolock_refresh_ngo_road_eligibility(v_user);

  insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,
    event_type,request_id,correlation_id,previous_state,requested_state,
    resulting_state,reason_code,outcome,details)
  values(v_user,'NGO','NGO',v_user,'SET_NGO_OPERATING_LOCATION',gen_random_uuid(),
    gen_random_uuid(),case when v_ngo.location_verified_at is null then 'INCOMPLETE' else 'VERIFIED' end,
    'VERIFIED','VERIFIED','SERVER_ROAD_NODE_VALIDATION','SUCCESS',
    jsonb_build_object('network_snapshot_id',v_snapshot,'road_node_id',v_node,
      'snap_distance_m',round(v_snap_distance::numeric,1)));

  return jsonb_build_object('location_status','VERIFIED','road_node_id',v_node,
    'snap_distance_m',round(v_snap_distance::numeric,1),'network_snapshot_id',v_snapshot);
end;
$$;

-- NGO discovery already returns no rows without a verified node. Add the same
-- profile-row lock before claim request/listing locks to serialize claim-time
-- eligibility with set_ngo_operating_location(). All other claim logic and
-- response fields are retained from the checked-in Stage 4 definition.
create or replace function public.claim_listing(p_listing uuid,p_request uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_actor uuid:=auth.uid(); v_ngo public.ngo_profiles%rowtype;
  v_req public.claim_requests%rowtype; v_l public.listings%rowtype;
  v_digest text; v_reason text; v_claim uuid; v_lease uuid; v_mins integer;
  v_success boolean:=false; v_outcome text;
begin
  if v_actor is null then raise exception 'UNAUTHENTICATED'; end if;
  select * into v_ngo from public.ngo_profiles
   where user_id=v_actor and active_flag for share;
  if not found then raise exception 'ACTIVE_NGO_ONLY'; end if;
  if p_request is null or p_listing is null then raise exception 'REQUEST_AND_LISTING_REQUIRED'; end if;

  v_digest:=md5(p_listing::text||':'||v_actor::text);
  insert into public.claim_requests(request_id,listing_id,ngo_user_id,request_digest)
  values(p_request,p_listing,v_actor,v_digest) on conflict(request_id) do nothing;
  select * into v_req from public.claim_requests where request_id=p_request for update;
  if v_req.request_digest<>v_digest or v_req.listing_id<>p_listing or v_req.ngo_user_id<>v_actor then
    raise exception 'IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD';
  end if;
  if v_req.outcome is not null then
    return jsonb_build_object('outcome',v_req.outcome,'claim_id',v_req.result_claim_id,
      'reason_code',v_req.reason_code,'replayed',true);
  end if;
  select * into v_l from public.listings where listing_id=p_listing for update;
  if not found then v_reason:='LISTING_NOT_FOUND';
  elsif v_l.listing_status<>'AVAILABLE' then v_reason:='CLAIM_CONFLICT';
  elsif v_l.listing_expires_at is not null and v_l.listing_expires_at<=clock_timestamp() then v_reason:='LISTING_EXPIRED';
  elsif v_ngo.location_verified_at is null or v_ngo.road_node_id is null then v_reason:='ELIGIBILITY_UNDETERMINED';
  elsif public.geolock_ngo_listing_road_check(v_actor,p_listing)->>'outcome'<>'ELIGIBLE'
    then v_reason:=public.geolock_ngo_listing_road_check(v_actor,p_listing)->>'outcome';
  elsif v_l.source_type='DIRECT_DONATION' and not exists(
    select 1 from public.donations d where d.donation_id=v_l.donation_id and d.donation_status='READY_FOR_PICKUP')
    then v_reason:='DONATION_NOT_READY';
  elsif v_l.source_type='HUB_BATCH' and not exists(
    select 1 from public.hub_batches b where b.batch_id=v_l.batch_id and b.batch_status='PUBLISHED')
    then v_reason:='BATCH_NOT_PUBLISHED';
  else
    select claim_lease_minutes into v_mins from public.coordination_config where singleton;
    if v_mins is null then raise exception 'CLAIM_LEASE_NOT_CONFIGURED'; end if;
    insert into public.donation_claims(listing_id,ngo_user_id,request_id)
      values(p_listing,v_actor,p_request) returning claim_id into v_claim;
    insert into public.claim_leases(claim_id,expires_at)
      values(v_claim,clock_timestamp()+make_interval(mins=>v_mins)) returning lease_id into v_lease;
    update public.listings set listing_status='CLAIMED',listing_version=listing_version+1
      where listing_id=p_listing;
    insert into public.pickup_tasks(claim_id,listing_id,ngo_user_id,pickup_road_node_id,load_kg)
      values(v_claim,p_listing,v_actor,v_l.pickup_road_node_id,v_l.listing_weight_kg);
    v_success:=true;
  end if;
  v_outcome:=case when v_success then 'SUCCESS'
    when v_reason in ('OUTSIDE_GEOFENCE','ROUTE_UNAVAILABLE') then 'INELIGIBLE' else 'CONFLICT' end;
  update public.claim_requests set outcome=v_outcome,result_claim_id=v_claim,
    reason_code=v_reason,completed_at=clock_timestamp() where request_id=p_request;
  insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,
    request_id,claim_id,lease_id,previous_state,requested_state,resulting_state,
    reason_code,outcome,details,configuration_version)
  select v_actor,'NGO','LISTING',p_listing,'CLAIM_ATTEMPT',p_request,v_claim,v_lease,
    v_l.listing_status,'CLAIMED',case when v_success then 'CLAIMED' else v_l.listing_status end,
    v_reason,case when v_success then 'SUCCESS' else 'REJECTED' end,
    jsonb_build_object('ngo_id',v_actor),cfg.config_version
    from public.coordination_config cfg where cfg.singleton;
  return jsonb_build_object('outcome',v_outcome,'claim_id',v_claim,
    'reason_code',v_reason,'replayed',false);
end;
$$;

-- A role can edit only its own allowed profile fields; role and email are not
-- accepted parameters and therefore cannot be changed by this RPC.
create or replace function public.update_my_profile(
  p_full_name text,p_phone text,p_ngo_name text default null,
  p_registration_number text default null
)
returns jsonb
language plpgsql security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare v_user uuid:=auth.uid(); v_role text;
begin
  if v_user is null then raise exception 'UNAUTHENTICATED'; end if;
  if nullif(btrim(p_full_name),'') is null then raise exception 'FULL_NAME_REQUIRED'; end if;
  select role into v_role from public.user_profiles where user_id=v_user for update;
  if not found then raise exception 'PROFILE_NOT_FOUND'; end if;
  update public.user_profiles set full_name=btrim(p_full_name),phone_number=nullif(btrim(p_phone),'')
    where user_id=v_user;
  if v_role='NGO' then
    if nullif(btrim(p_ngo_name),'') is null then raise exception 'NGO_NAME_REQUIRED'; end if;
    update public.ngo_profiles set ngo_name=btrim(p_ngo_name),
      registration_number=nullif(btrim(p_registration_number),'') where user_id=v_user;
  end if;
  insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,
    event_type,request_id,requested_state,resulting_state,outcome)
  values(v_user,v_role,'USER',v_user,'UPDATE_PROFILE',gen_random_uuid(),v_role,v_role,'SUCCESS');
  return jsonb_build_object('user_id',v_user,'role',v_role,'updated',true);
end;
$$;

-- New hub details are checked by the trusted resolver before activation.
create or replace function public.register_community_hub(
  p_name text,p_address text,p_lat double precision,p_lon double precision,
  p_capacity_kg numeric,p_road_node text default null
)
returns uuid language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
declare v_actor uuid:=auth.uid(); v_snapshot text; v_node text;
  v_distance double precision; v_resolved_snapshot text; v_hub uuid;
begin
  if v_actor is null then raise exception 'UNAUTHENTICATED'; end if;
  if not exists(select 1 from public.hub_admin_profiles where user_id=v_actor) then
    raise exception 'HUB_ADMIN_ONLY';
  end if;
  if nullif(btrim(p_name),'') is null or nullif(btrim(p_address),'') is null then
    raise exception 'HUB_NAME_AND_ADDRESS_REQUIRED';
  end if;
  if p_capacity_kg not between 50 and 250 then raise exception 'CAPACITY_MUST_BE_50_TO_250_KG'; end if;
  if p_lat is null or p_lon is null or p_lat not between -90 and 90 or p_lon not between -180 and 180 then
    raise exception 'INVALID_HUB_COORDINATES';
  end if;
  select c.network_snapshot_id into v_snapshot from public.road_network_coverage c
   where c.active_flag and c.dataset_kind='OPERATIONAL' and c.approved_at is not null
     and c.max_snap_distance_m=500 for share;
  if v_snapshot is null then raise exception 'OPERATIONAL_ROAD_COVERAGE_UNAVAILABLE'; end if;
  select r.node_id,r.snap_distance_m,r.snapshot_id into v_node,v_distance,v_resolved_snapshot
    from public.geolock_resolve_road_node(p_lat,p_lon) r;
  if v_node is null or v_distance is null or v_distance<0 or v_distance>500
     or v_resolved_snapshot is distinct from v_snapshot then
    raise exception 'HUB_LOCATION_NOT_ROUTABLE';
  end if;
  insert into public.community_hubs(admin_user_id,hub_name,address_text,latitude,longitude,
    capacity_kg,road_node_id,active_flag)
  values(v_actor,btrim(p_name),btrim(p_address),p_lat,p_lon,p_capacity_kg,v_node,false)
  returning hub_id into v_hub;
  if not exists(select 1 from public.community_hubs h where h.hub_id=v_hub and h.road_node_id=v_node) then
    raise exception 'HUB_LOCATION_NODE_MISMATCH';
  end if;
  update public.community_hubs set active_flag=true where hub_id=v_hub and admin_user_id=v_actor;
  insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,
    event_type,request_id,requested_state,resulting_state,reason_code,outcome,details)
  values(v_actor,'HUB_ADMIN','HUB',v_hub,'REGISTER_HUB',gen_random_uuid(),'PENDING_VALIDATION',
    'ACTIVE','SERVER_ROAD_NODE_VALIDATION','SUCCESS',
    jsonb_build_object('network_snapshot_id',v_snapshot,'road_node_id',v_node,
      'snap_distance_m',round(v_distance::numeric,1),'capacity_kg',p_capacity_kg));
  return v_hub;
end;
$$;

-- Location and capacity edits serialize with reservation/receipt/batch writers
-- on the hub row. They are rejected while custody or commitments are present.
create or replace function public.update_my_hub(
  p_hub uuid,p_name text,p_address text,p_lat double precision,p_lon double precision,
  p_capacity_kg numeric
)
returns jsonb language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
declare v_actor uuid:=auth.uid(); v_h public.community_hubs%rowtype;
  v_snapshot text; v_node text; v_distance double precision; v_resolved_snapshot text;
  v_commitment_change boolean;
  v_road_location_change boolean;
begin
  if v_actor is null then raise exception 'UNAUTHENTICATED'; end if;
  if nullif(btrim(p_name),'') is null or nullif(btrim(p_address),'') is null then
    raise exception 'HUB_NAME_AND_ADDRESS_REQUIRED';
  end if;
  if p_capacity_kg not between 50 and 250 then raise exception 'CAPACITY_MUST_BE_50_TO_250_KG'; end if;
  if p_lat is null or p_lon is null or p_lat not between -90 and 90 or p_lon not between -180 and 180 then
    raise exception 'INVALID_HUB_COORDINATES';
  end if;

  -- Lock coverage before the hub row to align with snapshot activation and
  -- registration. This does not lock or serialize registrations with each other.
  select c.network_snapshot_id into v_snapshot from public.road_network_coverage c
   where c.active_flag and c.dataset_kind='OPERATIONAL' and c.approved_at is not null
     and c.max_snap_distance_m=500 for share;
  select * into v_h from public.community_hubs h
   where h.hub_id=p_hub and h.admin_user_id=v_actor for update;
  if not found then raise exception 'HUB_NOT_FOUND_OR_FORBIDDEN'; end if;
  v_road_location_change := not v_h.active_flag or v_h.road_node_id is null
    or v_h.address_text is distinct from btrim(p_address)
    or v_h.latitude is distinct from p_lat or v_h.longitude is distinct from p_lon;
  v_commitment_change := v_road_location_change
    or v_h.capacity_kg is distinct from p_capacity_kg;

  if v_commitment_change and (
    exists(select 1 from public.hub_inventory i where i.hub_id=p_hub
      and i.inventory_status in ('STORED','BATCHED','RECONCILIATION_REQUIRED'))
    or exists(select 1 from public.hub_reservations r where r.hub_id=p_hub
      and r.reservation_status='ACTIVE')
    or exists(select 1 from public.hub_batch_members m where m.hub_id=p_hub
      and m.membership_status='ACTIVE')
    or exists(select 1 from public.hub_batches b where b.hub_id=p_hub
      and b.batch_status in ('DRAFT','PUBLISHED','CLAIMED'))
  ) then raise exception 'HUB_HAS_ACTIVE_INVENTORY_OR_COMMITMENTS'; end if;

  if v_road_location_change then
    if v_snapshot is null then raise exception 'OPERATIONAL_ROAD_COVERAGE_UNAVAILABLE'; end if;
    select r.node_id,r.snap_distance_m,r.snapshot_id into v_node,v_distance,v_resolved_snapshot
      from public.geolock_resolve_road_node(p_lat,p_lon) r;
    if v_node is null or v_distance is null or v_distance<0 or v_distance>500
       or v_resolved_snapshot is distinct from v_snapshot then
      raise exception 'HUB_LOCATION_NOT_ROUTABLE';
    end if;
    update public.community_hubs set hub_name=btrim(p_name),address_text=btrim(p_address),
      latitude=p_lat,longitude=p_lon,capacity_kg=p_capacity_kg,road_node_id=v_node,
      active_flag=true where hub_id=p_hub and admin_user_id=v_actor;
  elsif v_h.capacity_kg is distinct from p_capacity_kg then
    v_node:=v_h.road_node_id;
    update public.community_hubs set hub_name=btrim(p_name),capacity_kg=p_capacity_kg
      where hub_id=p_hub and admin_user_id=v_actor;
  else
    v_node:=v_h.road_node_id;
    update public.community_hubs set hub_name=btrim(p_name)
      where hub_id=p_hub and admin_user_id=v_actor;
  end if;
  if v_road_location_change and not exists(select 1 from public.community_hubs h
      where h.hub_id=p_hub and h.road_node_id=v_node and h.active_flag) then
    raise exception 'HUB_LOCATION_NODE_MISMATCH';
  end if;
  insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,
    event_type,request_id,requested_state,resulting_state,reason_code,outcome)
  values(v_actor,'HUB_ADMIN','HUB',p_hub,'UPDATE_HUB_PROFILE',gen_random_uuid(),
    'UPDATED','UPDATED',case when v_commitment_change then 'LOCATION_AND_CAPACITY_VALIDATED' else 'PROFILE_FIELDS_UPDATED' end,
    'SUCCESS');
  return jsonb_build_object('hub_id',p_hub,'updated',true,'road_node_id',v_node);
end;
$$;

-- Protected client entry points. Keep the existing claim_listing ACL unchanged.
revoke all on function public.register_role_profile(text,text,text,text,text,text,double precision,double precision,text) from public,anon;
grant execute on function public.register_role_profile(text,text,text,text,text,text,double precision,double precision,text) to authenticated;
revoke all on function public.set_ngo_operating_location(text,double precision,double precision) from public,anon;
grant execute on function public.set_ngo_operating_location(text,double precision,double precision) to authenticated;
revoke all on function public.update_my_profile(text,text,text,text) from public,anon;
grant execute on function public.update_my_profile(text,text,text,text) to authenticated;
revoke all on function public.register_community_hub(text,text,double precision,double precision,numeric,text) from public,anon;
grant execute on function public.register_community_hub(text,text,double precision,double precision,numeric,text) to authenticated;
revoke all on function public.update_my_hub(uuid,text,text,double precision,double precision,numeric) from public,anon;
grant execute on function public.update_my_hub(uuid,text,text,double precision,double precision,numeric) to authenticated;

commit;
