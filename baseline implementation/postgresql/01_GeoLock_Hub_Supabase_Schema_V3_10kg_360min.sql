-- GEOLOCK HUB V2 | Fresh-install PostgreSQL/Supabase schema and protected workflows
-- IMPORTANT: Execute on a NEW project after review. Not an in-place migration.
-- Design: 20 km straight-line geofence for discovery/claim; road network for routing.
-- Fixed classification: weight < 10 kg -> HUB_COLLECTION; weight >= 10 kg -> DIRECT_PICKUP.
-- Claim lease duration: 360 minutes (6 hours).
-- Route feasibility (road network, time windows) requires an external trusted validator.
-- No automatic lease renewal. Backend must invoke recovery periodically.
-- Security: no direct client table writes; RPCs validate auth.uid() and role.
-- WARNING: Auth bootstrap for HUB_ADMIN must be provisioned by trusted backend.
-- The script deliberately DOES NOT grant a public function to self-assign HUB_ADMIN.

create extension if not exists pgcrypto;
create schema if not exists extensions;
create extension if not exists postgis with schema extensions;

-- 1. Identity and configuration
create table public.user_profiles (
 user_id uuid primary key references auth.users(id) on delete cascade,
 full_name text not null,
 phone_number text,
 role text not null check(role in ('DONOR','NGO','HUB_ADMIN')),
 created_at timestamptz not null default now(),
 unique(user_id,role)
);
create table public.donor_profiles (
 user_id uuid primary key,
 role text not null default 'DONOR' check(role='DONOR'),
 foreign key(user_id,role) references public.user_profiles(user_id,role)
);
create table public.ngo_profiles (
 user_id uuid primary key,
 role text not null default 'NGO' check(role='NGO'),
 ngo_name text not null,
 registration_number text unique,
 operating_address text not null,
 latitude double precision not null check(latitude between -90 and 90),
 longitude double precision not null check(longitude between -180 and 180),
 road_node_id text,
 active_flag boolean not null default true,
 location_verified_at timestamptz,
 foreign key(user_id,role) references public.user_profiles(user_id,role),
 check(btrim(operating_address)<>'')
);
create table public.hub_admin_profiles (
 user_id uuid primary key,
 role text not null default 'HUB_ADMIN' check(role='HUB_ADMIN'),
 foreign key(user_id,role) references public.user_profiles(user_id,role)
);
create table public.coordination_config (
 singleton boolean primary key default true check(singleton),
 geofence_radius_m integer not null default 20000 check(geofence_radius_m=20000),
 donation_direct_min_kg numeric(12,3) not null default 10.000 check(donation_direct_min_kg=10.000),
 claim_lease_minutes integer not null default 360 check(claim_lease_minutes=360),
 hub_reservation_minutes integer not null default 120 check(hub_reservation_minutes between 1 and 10080),
 batch_min_donations integer not null default 3 check(batch_min_donations>0),
 batch_max_donations integer not null default 5 check(batch_max_donations>=3),
 batch_max_weight_kg numeric(12,3) not null default 30 check(batch_max_weight_kg>0),
 config_version text not null default 'v2.0',
 updated_at timestamptz not null default now(),
 check(batch_min_donations<=batch_max_donations)
);
insert into public.coordination_config(singleton) values(true);
-- The fixed 10 kg threshold and 360-minute lease are initialized above.
-- Examples: 9.999 kg -> HUB_COLLECTION; 10.000 kg -> DIRECT_PICKUP.

-- 2. Categories, hubs, donations
create table public.donation_categories (
 category_id uuid primary key default gen_random_uuid(),
 category_name text not null unique,
 active_flag boolean not null default true
);
create table public.community_hubs (
 hub_id uuid primary key default gen_random_uuid(),
 admin_user_id uuid not null references public.hub_admin_profiles(user_id),
 hub_name text not null,
 address_text text not null,
 latitude double precision not null check(latitude between -90 and 90),
 longitude double precision not null check(longitude between -180 and 180),
 road_node_id text,
 capacity_kg numeric(12,3) not null check(capacity_kg between 50 and 250),
 active_flag boolean not null default true,
 operating_hours jsonb not null default '{}'::jsonb,
 created_at timestamptz not null default now(),
 unique(hub_id,admin_user_id)
);
create table public.hub_accepted_categories (
 hub_id uuid not null references public.community_hubs(hub_id),
 category_id uuid not null references public.donation_categories(category_id),
 primary key(hub_id,category_id)
);
create table public.donations (
 donation_id uuid primary key default gen_random_uuid(),
 donor_user_id uuid not null references public.donor_profiles(user_id),
 title text not null,
 description text,
 collection_path text check(collection_path in ('DIRECT_PICKUP','HUB_COLLECTION')),
 donation_status text not null default 'SUBMITTED' check(donation_status in
 ('SUBMITTED','VALIDATED','READY_FOR_PICKUP','HUB_ASSIGNED','AT_HUB',
  'BATCHED','PICKUP_IN_PROGRESS','COLLECTED','DELIVERED','CANCELLED')),
 pickup_address text,
 latitude double precision check(latitude between -90 and 90),
 longitude double precision check(longitude between -180 and 180),
 pickup_road_node_id text,
 total_weight_kg numeric(12,3) check(total_weight_kg>0),
 availability_start timestamptz,
 availability_end timestamptz,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 check(availability_start is null or availability_end is null or availability_end>availability_start),
 check((latitude is null)=(longitude is null))
);
create table public.donation_items (
 item_id uuid primary key default gen_random_uuid(),
 donation_id uuid not null references public.donations(donation_id),
 category_id uuid not null references public.donation_categories(category_id),
 item_name text not null,
 description text,
 quantity integer not null check(quantity>0),
 unit_label text not null default 'piece',
 unit_weight_kg numeric(12,3) not null check(unit_weight_kg>0),
 item_condition text not null default 'GOOD' check(item_condition in ('NEW','GOOD','FAIR')),
 created_at timestamptz not null default now(),
 unique(item_id,donation_id)
);
create index idx_donations_donor on public.donations(donor_user_id);
create index idx_items_donation on public.donation_items(donation_id);

-- 3. Hub reservations, custody and batches
create table public.hub_reservations (
 reservation_id uuid primary key default gen_random_uuid(),
 donation_id uuid not null references public.donations(donation_id),
 hub_id uuid not null references public.community_hubs(hub_id),
 reserved_weight_kg numeric(12,3) not null check(reserved_weight_kg>0),
 reservation_status text not null default 'ACTIVE' check(reservation_status in
 ('ACTIVE','CONSUMED','RELEASED','EXPIRED')),
 reserved_at timestamptz not null default now(),
 expires_at timestamptz not null,
 check(expires_at>reserved_at),
 unique(reservation_id,donation_id,hub_id)
);
create unique index ux_active_reservation on public.hub_reservations(donation_id)
 where reservation_status='ACTIVE';
create table public.hub_receipts (
 receipt_id uuid primary key default gen_random_uuid(),
 reservation_id uuid not null unique,
 donation_id uuid not null unique,
 hub_id uuid not null,
 received_by uuid not null references public.hub_admin_profiles(user_id),
 receipt_status text not null default 'CONFIRMED' check(receipt_status in
 ('CONFIRMED','RECONCILIATION_REQUIRED')),
 received_weight_kg numeric(12,3) not null check(received_weight_kg>0),
 received_at timestamptz not null default now(),
 foreign key(reservation_id,donation_id,hub_id)
 references public.hub_reservations(reservation_id,donation_id,hub_id),
 unique(donation_id,hub_id)
);
create table public.hub_inventory (
 donation_id uuid primary key,
 hub_id uuid not null,
 inventory_status text not null default 'STORED' check(inventory_status in
 ('STORED','BATCHED','COLLECTED','RECONCILIATION_REQUIRED')),
 recorded_at timestamptz not null default now(),
 foreign key(donation_id,hub_id) references public.hub_receipts(donation_id,hub_id),
 unique(donation_id,hub_id)
);
create table public.hub_batches (
 batch_id uuid primary key default gen_random_uuid(),
 hub_id uuid not null references public.community_hubs(hub_id),
 batch_category_id uuid references public.donation_categories(category_id),
 batch_status text not null default 'DRAFT' check(batch_status in
 ('DRAFT','PUBLISHED','CLAIMED','COLLECTED','CANCELLED')),
 batch_weight_kg numeric(12,3) not null default 0 check(batch_weight_kg>=0),
 batch_donation_count integer not null default 0 check(batch_donation_count>=0),
 batch_version bigint not null default 1 check(batch_version>0),
 created_by uuid not null references public.hub_admin_profiles(user_id),
 created_at timestamptz not null default now(),
 published_at timestamptz,
 unique(batch_id,hub_id)
);
-- Batch DRAFT is an assembly state, not donation DRAFT.
create table public.hub_batch_members (
 batch_id uuid not null,
 hub_id uuid not null,
 donation_id uuid not null,
 membership_status text not null default 'ACTIVE' check(membership_status in ('ACTIVE','RELEASED')),
 added_at timestamptz not null default now(),
 primary key(batch_id,donation_id),
 foreign key(batch_id,hub_id) references public.hub_batches(batch_id,hub_id),
 foreign key(donation_id,hub_id) references public.hub_inventory(donation_id,hub_id)
);
create unique index ux_active_batch_member on public.hub_batch_members(donation_id)
 where membership_status='ACTIVE';

-- 4. Listings, claim attempts, claims and leases
create table public.listings (
 listing_id uuid primary key default gen_random_uuid(),
 source_type text not null check(source_type in ('DIRECT_DONATION','HUB_BATCH')),
 donation_id uuid references public.donations(donation_id),
 batch_id uuid references public.hub_batches(batch_id),
 listing_status text not null default 'AVAILABLE' check(listing_status in
 ('AVAILABLE','CLAIMED','CLOSED','CANCELLED')),
 listing_weight_kg numeric(12,3) not null check(listing_weight_kg>0),
 pickup_latitude double precision not null check(pickup_latitude between -90 and 90),
 pickup_longitude double precision not null check(pickup_longitude between -180 and 180),
 pickup_road_node_id text,
 listing_version bigint not null default 1 check(listing_version>0),
 created_at timestamptz not null default now(),
 listing_expires_at timestamptz,
 check((source_type='DIRECT_DONATION' and donation_id is not null and batch_id is null)
    or (source_type='HUB_BATCH' and batch_id is not null and donation_id is null))
);
create unique index ux_direct_listing on public.listings(donation_id)
 where source_type='DIRECT_DONATION';
create unique index ux_batch_listing on public.listings(batch_id)
 where source_type='HUB_BATCH';
create table public.claim_requests (
 request_id uuid primary key,
 listing_id uuid not null references public.listings(listing_id),
 ngo_user_id uuid not null references public.ngo_profiles(user_id),
 request_digest text not null,
 outcome text check(outcome in ('SUCCESS','CONFLICT','INELIGIBLE','ERROR')),
 result_claim_id uuid,
 reason_code text,
 created_at timestamptz not null default now(),
 completed_at timestamptz
);
create table public.donation_claims (
 claim_id uuid primary key default gen_random_uuid(),
 listing_id uuid not null references public.listings(listing_id),
 ngo_user_id uuid not null references public.ngo_profiles(user_id),
 request_id uuid not null unique references public.claim_requests(request_id),
 claim_status text not null default 'ACTIVE' check(claim_status in
 ('ACTIVE','RELEASED','EXPIRED','COMPLETED','CANCELLED','RECONCILIATION_REQUIRED')),
 claimed_at timestamptz not null default now(),
 closed_at timestamptz,
 close_reason text,
 unique(claim_id,listing_id,ngo_user_id)
);
alter table public.claim_requests add constraint fk_request_result
 foreign key(result_claim_id) references public.donation_claims(claim_id);
create unique index ux_active_claim on public.donation_claims(listing_id)
 where claim_status in ('ACTIVE','RECONCILIATION_REQUIRED');
create table public.claim_leases (
 lease_id uuid primary key default gen_random_uuid(),
 claim_id uuid not null unique references public.donation_claims(claim_id),
 lease_status text not null default 'ACTIVE' check(lease_status in
 ('ACTIVE','EXPIRED','RELEASED','COMPLETED','RECONCILIATION_REQUIRED')),
 issued_at timestamptz not null default clock_timestamp(),
 expires_at timestamptz not null,
 closed_at timestamptz,
 release_reason text,
 check(expires_at>issued_at)
);
create index idx_active_lease_expiry on public.claim_leases(expires_at)
 where lease_status='ACTIVE';

-- 5. Tasks and routes
create table public.vehicles (
 vehicle_id uuid primary key default gen_random_uuid(),
 ngo_user_id uuid not null references public.ngo_profiles(user_id),
 vehicle_label text not null,
 payload_capacity_kg numeric(12,3) not null check(payload_capacity_kg>0),
 depot_road_node_id text,
 active_flag boolean not null default true,
 unique(vehicle_id,ngo_user_id)
);
create table public.pickup_tasks (
 task_id uuid primary key default gen_random_uuid(),
 claim_id uuid not null unique,
 listing_id uuid not null,
 ngo_user_id uuid not null,
 pickup_road_node_id text not null,
 load_kg numeric(12,3) not null check(load_kg>0),
 task_status text not null default 'CONFIRMED' check(task_status in
 ('CONFIRMED','PLANNED','DISPATCHED','COLLECTED','CANCELLED','STALE')),
 created_at timestamptz not null default now(),
 foreign key(claim_id,listing_id,ngo_user_id)
 references public.donation_claims(claim_id,listing_id,ngo_user_id)
);
create table public.pickup_routes (
 route_id uuid primary key default gen_random_uuid(),
 ngo_user_id uuid not null references public.ngo_profiles(user_id),
 vehicle_id uuid not null,
 route_status text not null default 'DRAFT' check(route_status in
 ('DRAFT','VALIDATED','AUTHORISED','IN_PROGRESS','COMPLETED','CANCELLED','STALE')),
 matrix_id text,
 total_distance_km numeric(14,3) check(total_distance_km>=0),
 total_duration_min numeric(14,3) check(total_duration_min>=0),
 planned_at timestamptz not null default now(),
 authorised_at timestamptz,
 validation_reference text,
 foreign key(vehicle_id,ngo_user_id) references public.vehicles(vehicle_id,ngo_user_id),
 unique(route_id,ngo_user_id)
);
create table public.pickup_route_stops (
 route_id uuid not null,
 ngo_user_id uuid not null,
 stop_order integer not null check(stop_order>0),
 task_id uuid not null references public.pickup_tasks(task_id),
 planned_arrival timestamptz,
 primary key(route_id,stop_order),
 unique(route_id,task_id),
 foreign key(route_id,ngo_user_id) references public.pickup_routes(route_id,ngo_user_id)
);
-- One active assignment per task, regardless of route. Release only after route cancellation.
create table public.active_task_route_assignments (
 task_id uuid primary key references public.pickup_tasks(task_id),
 route_id uuid not null references public.pickup_routes(route_id),
 assigned_at timestamptz not null default now(),
 unique(task_id,route_id)
);

-- 6. Audits: append only, including rejected requests
create table public.audit_events (
 event_id uuid primary key default gen_random_uuid(),
 actor_user_id uuid references auth.users(id),
 actor_role text,
 entity_type text not null,
 entity_id uuid,
 event_type text not null,
 request_id uuid,
 claim_id uuid,
 lease_id uuid,
 correlation_id uuid,
 previous_state text,
 requested_state text,
 resulting_state text,
 reason_code text,
 outcome text not null check(outcome in ('SUCCESS','REJECTED','ERROR')),
 details jsonb not null default '{}'::jsonb,
 software_version text,
 configuration_version text,
 occurred_at timestamptz not null default clock_timestamp()
);
create index idx_audit_entity on public.audit_events(entity_type,entity_id,occurred_at);
create index idx_audit_request on public.audit_events(request_id);

-- 7. Guard functions (including defense against privileged accidental status skipping)
create function public.prevent_role_change() returns trigger
language plpgsql set search_path=public,pg_temp as $$
begin
 if new.user_id is distinct from old.user_id or new.role is distinct from old.role then
   raise exception 'IMMUTABLE_ROLE';
 end if;
 return new;
end $$;
create trigger trg_role_immutable before update on public.user_profiles
 for each row execute function public.prevent_role_change();

create function public.enforce_donation_transition() returns trigger
language plpgsql set search_path=public,pg_temp as $$
begin
 if tg_op='UPDATE' and new.donation_status is distinct from old.donation_status then
   if not (
     (old.donation_status='SUBMITTED' and new.donation_status in ('VALIDATED','CANCELLED'))
     or (old.donation_status='VALIDATED' and new.donation_status in ('READY_FOR_PICKUP','HUB_ASSIGNED','CANCELLED'))
     or (old.donation_status='READY_FOR_PICKUP' and new.donation_status in ('PICKUP_IN_PROGRESS','CANCELLED'))
     or (old.donation_status='HUB_ASSIGNED' and new.donation_status in ('AT_HUB','CANCELLED'))
     or (old.donation_status='AT_HUB' and new.donation_status='BATCHED')
     or (old.donation_status='BATCHED' and new.donation_status='PICKUP_IN_PROGRESS')
     or (old.donation_status='PICKUP_IN_PROGRESS' and new.donation_status='COLLECTED')
     or (old.donation_status='COLLECTED' and new.donation_status='DELIVERED')
   ) then raise exception 'INVALID_DONATION_TRANSITION: % -> %',old.donation_status,new.donation_status; end if;
 end if;
 new.updated_at=clock_timestamp();
 return new;
end $$;
create trigger trg_donation_transition before update on public.donations
 for each row execute function public.enforce_donation_transition();

create function public.enforce_listing_transition() returns trigger
language plpgsql set search_path=public,pg_temp as $$
begin
 if tg_op='UPDATE' and new.listing_status is distinct from old.listing_status then
   if not ((old.listing_status='AVAILABLE' and new.listing_status in ('CLAIMED','CANCELLED'))
       or (old.listing_status='CLAIMED' and new.listing_status in ('AVAILABLE','CLOSED')))
   then raise exception 'INVALID_LISTING_TRANSITION'; end if;
 end if;
 return new;
end $$;
create trigger trg_listing_transition before update on public.listings
 for each row execute function public.enforce_listing_transition();

create function public.guard_donation_items() returns trigger
language plpgsql set search_path=public,pg_temp as $$
declare v_donation uuid; v_status text;
begin
 v_donation=case when tg_op='DELETE' then old.donation_id else new.donation_id end;
 if tg_op='UPDATE' and new.donation_id<>old.donation_id then
  raise exception 'DONATION_ITEM_REPARENT_FORBIDDEN';
 end if;
 select donation_status into v_status from public.donations
 where donation_id=v_donation for update;
 if v_status is distinct from 'SUBMITTED' then
  raise exception 'DONATION_ITEMS_FROZEN';
 end if;
 return case when tg_op='DELETE' then old else new end;
end $$;
create trigger trg_items_guard before insert or update or delete on public.donation_items
 for each row execute function public.guard_donation_items();

create function public.guard_batch_immutability() returns trigger
language plpgsql set search_path=public,pg_temp as $$
declare v_status text;
begin
 if tg_table_name='hub_batch_members' then
   select batch_status into v_status from public.hub_batches
   where batch_id=coalesce(new.batch_id,old.batch_id) for update;
   if v_status<>'DRAFT' then raise exception 'PUBLISHED_BATCH_IMMUTABLE'; end if;
   return case when tg_op='DELETE' then old else new end;
 end if;
 if tg_op='DELETE' then
   if old.batch_status<>'DRAFT' then raise exception 'PUBLISHED_BATCH_IMMUTABLE'; end if;
   return old;
 end if;
 if old.batch_status<>'DRAFT' then
   -- Only operational status changes are permitted after publishing.
   if row(new.hub_id,new.batch_category_id,new.batch_weight_kg,new.batch_donation_count,
          new.batch_version,new.created_by,new.published_at)
      is distinct from
      row(old.hub_id,old.batch_category_id,old.batch_weight_kg,old.batch_donation_count,
          old.batch_version,old.created_by,old.published_at) then
      raise exception 'PUBLISHED_BATCH_IMMUTABLE';
   end if;
 end if;
 return new;
end $$;
create trigger trg_batch_guard before update or delete on public.hub_batches
 for each row execute function public.guard_batch_immutability();
create trigger trg_members_guard before insert or update or delete on public.hub_batch_members
 for each row execute function public.guard_batch_immutability();

create function public.prevent_audit_mutation() returns trigger
language plpgsql as $$
begin raise exception 'AUDIT_APPEND_ONLY'; end $$;
create trigger trg_audit_append_only before update or delete on public.audit_events
 for each row execute function public.prevent_audit_mutation();

-- 8. Role registration. HUB_ADMIN is trusted-backend provisioned, not self-service.
create function public.register_role_profile(
 p_full_name text, p_role text, p_phone text default null,
 p_ngo_name text default null, p_registration_number text default null,
 p_operating_address text default null, p_latitude double precision default null,
 p_longitude double precision default null, p_road_node_id text default null
) returns uuid language plpgsql security definer
set search_path=public,extensions,pg_temp as $$
declare v_user uuid:=auth.uid();
begin
 if v_user is null then raise exception 'UNAUTHENTICATED'; end if;
 if p_role not in ('DONOR','NGO') then raise exception 'ROLE_NOT_SELF_SERVICE'; end if;
 if nullif(btrim(p_full_name),'') is null then raise exception 'FULL_NAME_REQUIRED'; end if;
 if exists(select 1 from public.user_profiles where user_id=v_user) then
  raise exception 'ROLE_ALREADY_REGISTERED';
 end if;
 if p_role='NGO' then
  if nullif(btrim(p_ngo_name),'') is null or nullif(btrim(p_operating_address),'') is null
     or p_latitude is null or p_longitude is null
     or p_latitude not between -90 and 90 or p_longitude not between -180 and 180
  then raise exception 'NGO_LOCATION_REQUIRED'; end if;
 end if;
 insert into public.user_profiles(user_id,full_name,phone_number,role)
 values(v_user,p_full_name,p_phone,p_role);
 if p_role='DONOR' then
   insert into public.donor_profiles(user_id) values(v_user);
 else
   insert into public.ngo_profiles(user_id,ngo_name,registration_number,operating_address,
       latitude,longitude,road_node_id,location_verified_at)
   values(v_user,p_ngo_name,p_registration_number,p_operating_address,
       p_latitude,p_longitude,p_road_node_id,clock_timestamp());
 end if;
 insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,
   requested_state,resulting_state,outcome)
 values(v_user,p_role,'USER',v_user,'REGISTER_ROLE',p_role,p_role,'SUCCESS');
 return v_user;
end $$;

-- 9. Donation creation and validation: item array inserted in same transaction.
-- p_items JSON array objects: category_id, item_name, quantity, unit_weight_kg,
-- optional description, unit_label, item_condition.
create function public.create_and_validate_donation(
 p_title text,p_description text,p_pickup_address text,
 p_latitude double precision,p_longitude double precision,
 p_items jsonb,p_pickup_road_node_id text default null,
 p_availability_start timestamptz default null,p_availability_end timestamptz default null
) returns uuid language plpgsql security definer
set search_path=public,extensions,pg_temp as $$
declare v_actor uuid:=auth.uid(); v_donation uuid; v_item jsonb;
 v_count integer:=0; v_weight numeric(12,3):=0; v_threshold numeric(12,3);
 v_path text; v_category uuid; v_qty integer; v_unit numeric(12,3);
begin
 if not exists(select 1 from public.donor_profiles where user_id=v_actor)
 then raise exception 'DONOR_ONLY'; end if;
 if nullif(btrim(p_title),'') is null or nullif(btrim(p_pickup_address),'') is null
   or p_latitude is null or p_longitude is null
   or p_latitude not between -90 and 90 or p_longitude not between -180 and 180
 then raise exception 'INVALID_DONATION_LOCATION_OR_TITLE'; end if;
 if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items)=0
 then raise exception 'AT_LEAST_ONE_ITEM_REQUIRED'; end if;
 if p_availability_start is not null and p_availability_end is not null
    and p_availability_end<=p_availability_start then raise exception 'INVALID_AVAILABILITY'; end if;
 select donation_direct_min_kg into v_threshold from public.coordination_config where singleton;
 if v_threshold is null then raise exception 'DONATION_THRESHOLD_NOT_CONFIGURED'; end if;
 insert into public.donations(donor_user_id,title,description,pickup_address,latitude,longitude,
  pickup_road_node_id,availability_start,availability_end)
 values(v_actor,p_title,p_description,p_pickup_address,p_latitude,p_longitude,
  p_pickup_road_node_id,p_availability_start,p_availability_end)
 returning donation_id into v_donation;
 for v_item in select value from jsonb_array_elements(p_items) loop
   v_category=(v_item->>'category_id')::uuid;
   v_qty=(v_item->>'quantity')::integer;
   v_unit=(v_item->>'unit_weight_kg')::numeric;
   if v_qty is null or v_qty<=0 or v_unit is null or v_unit<=0
      or nullif(btrim(v_item->>'item_name'),'') is null
      or not exists(select 1 from public.donation_categories
                    where category_id=v_category and active_flag)
   then raise exception 'INVALID_DONATION_ITEM'; end if;
   insert into public.donation_items(donation_id,category_id,item_name,description,
      quantity,unit_label,unit_weight_kg,item_condition)
   values(v_donation,v_category,v_item->>'item_name',v_item->>'description',
      v_qty,coalesce(v_item->>'unit_label','piece'),v_unit,
      coalesce(v_item->>'item_condition','GOOD'));
   v_count=v_count+1;
   v_weight=v_weight+(v_qty*v_unit);
 end loop;
 if v_count=0 or v_weight<=0 then raise exception 'INVALID_TOTAL_WEIGHT'; end if;
 v_path=case when v_weight>=v_threshold then 'DIRECT_PICKUP' else 'HUB_COLLECTION' end;
 update public.donations set donation_status='VALIDATED',
  collection_path=v_path,total_weight_kg=v_weight where donation_id=v_donation;
 if v_path='DIRECT_PICKUP' then
   update public.donations set donation_status='READY_FOR_PICKUP' where donation_id=v_donation;
   insert into public.listings(source_type,donation_id,listing_weight_kg,
      pickup_latitude,pickup_longitude,pickup_road_node_id,listing_expires_at)
   values('DIRECT_DONATION',v_donation,v_weight,p_latitude,p_longitude,
      p_pickup_road_node_id,p_availability_end);
 end if;
 insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,
  previous_state,requested_state,resulting_state,outcome,details,configuration_version)
 select v_actor,'DONOR','DONATION',v_donation,'CREATE_VALIDATE',
   null,'VALIDATED',case when v_path='DIRECT_PICKUP' then 'READY_FOR_PICKUP' else 'VALIDATED' end,
   'SUCCESS',jsonb_build_object('weight_kg',v_weight,'collection_path',v_path),config_version
 from public.coordination_config where singleton;
 return v_donation;
end $$;

-- 10. Hub registration. Caller must already be a trusted-provisioned HUB_ADMIN.
create function public.register_community_hub(
 p_name text,p_address text,p_lat double precision,p_lon double precision,
 p_capacity_kg numeric,p_road_node text default null
) returns uuid language plpgsql security definer
set search_path=public,extensions,pg_temp as $$
declare v_actor uuid:=auth.uid();v_hub uuid;
begin
 if not exists(select 1 from public.hub_admin_profiles where user_id=v_actor)
 then raise exception 'HUB_ADMIN_ONLY'; end if;
 if p_capacity_kg not between 50 and 250 then raise exception 'CAPACITY_MUST_BE_50_TO_250_KG'; end if;
 insert into public.community_hubs(admin_user_id,hub_name,address_text,latitude,longitude,
 capacity_kg,road_node_id)
 values(v_actor,p_name,p_address,p_lat,p_lon,p_capacity_kg,p_road_node)
 returning hub_id into v_hub;
 insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,
 event_type,requested_state,resulting_state,outcome)
 values(v_actor,'HUB_ADMIN','HUB',v_hub,'REGISTER_HUB','ACTIVE','ACTIVE','SUCCESS');
 return v_hub;
end $$;

-- 11. Capacity reservation. Lock hub row to serialize concurrent reservations.
create function public.reserve_hub_capacity(p_donation uuid,p_hub uuid)
returns uuid language plpgsql security definer
set search_path=public,extensions,pg_temp as $$
declare v_actor uuid:=auth.uid();v_d public.donations%rowtype;
 v_h public.community_hubs%rowtype;v_used numeric;v_reserved numeric;
 v_res uuid;v_minutes integer;
begin
 select * into v_d from public.donations where donation_id=p_donation for update;
 if not found or v_d.donor_user_id is distinct from v_actor then raise exception 'NOT_DONOR_OWNER'; end if;
 if v_d.donation_status<>'VALIDATED' or v_d.collection_path<>'HUB_COLLECTION'
 then raise exception 'DONATION_NOT_HUB_ELIGIBLE'; end if;
 select * into v_h from public.community_hubs where hub_id=p_hub for update;
 if not found or not v_h.active_flag then raise exception 'HUB_INACTIVE'; end if;
 if not exists(select 1 from public.donation_items di
   where di.donation_id=p_donation)
 then raise exception 'EMPTY_DONATION'; end if;
 if exists(select 1 from public.donation_items di where di.donation_id=p_donation
  and not exists(select 1 from public.hub_accepted_categories hac
  where hac.hub_id=p_hub and hac.category_id=di.category_id))
 then raise exception 'CATEGORY_NOT_ACCEPTED'; end if;
 -- Clean expired reservations for this hub ONLY when no physical receipt exists.
 update public.hub_reservations r set reservation_status='EXPIRED'
 where r.hub_id=p_hub and r.reservation_status='ACTIVE'
   and r.expires_at<=clock_timestamp()
   and not exists(select 1 from public.hub_receipts hr where hr.reservation_id=r.reservation_id);
 select coalesce(sum(hr.received_weight_kg),0) into v_used
 from public.hub_inventory hi join public.hub_receipts hr using(donation_id)
 where hi.hub_id=p_hub and hi.inventory_status in
 ('STORED','BATCHED','RECONCILIATION_REQUIRED');
 select coalesce(sum(r.reserved_weight_kg),0) into v_reserved
 from public.hub_reservations r
 where r.hub_id=p_hub and r.reservation_status='ACTIVE'
 and r.expires_at>clock_timestamp()
 and not exists(select 1 from public.hub_receipts hr where hr.reservation_id=r.reservation_id);
 if v_used+v_reserved+v_d.total_weight_kg>v_h.capacity_kg then
  raise exception 'HUB_CAPACITY_EXCEEDED';
 end if;
 select hub_reservation_minutes into v_minutes from public.coordination_config where singleton;
 insert into public.hub_reservations(donation_id,hub_id,reserved_weight_kg,expires_at)
 values(p_donation,p_hub,v_d.total_weight_kg,clock_timestamp()+make_interval(mins=>v_minutes))
 returning reservation_id into v_res;
 update public.donations set donation_status='HUB_ASSIGNED' where donation_id=p_donation;
 insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,
 previous_state,requested_state,resulting_state,outcome,details)
 values(v_actor,'DONOR','DONATION',p_donation,'RESERVE_HUB',
 'VALIDATED','HUB_ASSIGNED','HUB_ASSIGNED','SUCCESS',jsonb_build_object('hub_id',p_hub,'reservation_id',v_res));
 return v_res;
end $$;

-- 12. Hub receipt: custody transfer and reservation consumption, under hub lock.
create function public.confirm_hub_receipt(p_reservation uuid,p_received_weight numeric)
returns uuid language plpgsql security definer
set search_path=public,extensions,pg_temp as $$
declare v_actor uuid:=auth.uid();v_r public.hub_reservations%rowtype;
 v_receipt uuid;v_hub public.community_hubs%rowtype;
begin
 select * into v_r from public.hub_reservations where reservation_id=p_reservation;
 if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
 select * into v_hub from public.community_hubs where hub_id=v_r.hub_id for update;
 if v_hub.admin_user_id is distinct from v_actor then raise exception 'NOT_HUB_ADMIN'; end if;
 select * into v_r from public.hub_reservations where reservation_id=p_reservation for update;
 if v_r.reservation_status<>'ACTIVE' or v_r.expires_at<=clock_timestamp()
 then raise exception 'RESERVATION_NOT_ACTIVE'; end if;
 if p_received_weight<=0 or p_received_weight>v_r.reserved_weight_kg
 then raise exception 'RECEIVED_WEIGHT_EXCEEDS_RESERVATION'; end if;
 if not exists(select 1 from public.donations where donation_id=v_r.donation_id
  and donation_status='HUB_ASSIGNED') then raise exception 'INVALID_DONATION_STATE'; end if;
 insert into public.hub_receipts(reservation_id,donation_id,hub_id,received_by,received_weight_kg)
 values(v_r.reservation_id,v_r.donation_id,v_r.hub_id,v_actor,p_received_weight)
 returning receipt_id into v_receipt;
 insert into public.hub_inventory(donation_id,hub_id)
 values(v_r.donation_id,v_r.hub_id);
 update public.hub_reservations set reservation_status='CONSUMED'
 where reservation_id=p_reservation;
 update public.donations set donation_status='AT_HUB' where donation_id=v_r.donation_id;
 insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,
 previous_state,requested_state,resulting_state,outcome,details)
 values(v_actor,'HUB_ADMIN','DONATION',v_r.donation_id,'CONFIRM_HUB_RECEIPT',
 'HUB_ASSIGNED','AT_HUB','AT_HUB','SUCCESS',jsonb_build_object('receipt_id',v_receipt));
 return v_receipt;
end $$;

-- 13. Batch publication: whole-donation aggregation, no edits after publish.
-- p_donation_ids must be distinct, 3-5 items (configurable) and <=30 kg.
create function public.publish_whole_donation_batch(p_hub uuid,p_donation_ids uuid[])
returns uuid language plpgsql security definer
set search_path=public,extensions,pg_temp as $$
declare v_actor uuid:=auth.uid();v_batch uuid;v_count integer;v_weight numeric;
 v_min integer;v_max integer;v_limit numeric;v_cat uuid;v_cat_count integer;
 v_h public.community_hubs%rowtype;v_d uuid;
begin
 select * into v_h from public.community_hubs where hub_id=p_hub for update;
 if not found or v_h.admin_user_id is distinct from v_actor then raise exception 'NOT_HUB_ADMIN'; end if;
 if not v_h.active_flag then raise exception 'HUB_INACTIVE'; end if;
 select batch_min_donations,batch_max_donations,batch_max_weight_kg
 into v_min,v_max,v_limit from public.coordination_config where singleton;
 select count(distinct x) into v_count from unnest(p_donation_ids) x;
 if v_count<>coalesce(array_length(p_donation_ids,1),0)
 or v_count<v_min or v_count>v_max then raise exception 'INVALID_BATCH_COUNT'; end if;
 -- Lock member donations in stable order; hub row already serializes batch operations.
 for v_d in select unnest(p_donation_ids) order by 1 loop
  perform 1 from public.hub_inventory hi join public.donations d using(donation_id)
  where hi.donation_id=v_d and hi.hub_id=p_hub and hi.inventory_status='STORED'
  and d.donation_status='AT_HUB' for update of hi,d;
  if not found then raise exception 'DONATION_NOT_STORED_AT_HUB'; end if;
  if exists(select 1 from public.hub_batch_members
    where donation_id=v_d and membership_status='ACTIVE')
  then raise exception 'DONATION_ALREADY_BATCHED'; end if;
 end loop;
 select coalesce(sum(hr.received_weight_kg),0) into v_weight
 from public.hub_receipts hr where hr.donation_id=any(p_donation_ids);
 if v_weight>v_limit then raise exception 'BATCH_WEIGHT_EXCEEDED'; end if;
 -- Single-category compatibility for whole donations; mixed-category donations
 -- cannot join a single-category batch without an approved alternative rule.
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
 insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,
 requested_state,resulting_state,outcome,details)
 values(v_actor,'HUB_ADMIN','BATCH',v_batch,'PUBLISH_BATCH','PUBLISHED','PUBLISHED',
 'SUCCESS',jsonb_build_object('count',v_count,'weight_kg',v_weight));
 return v_batch;
end $$;

-- 14. Eligibility-filtered discovery (20 km geographic distance).
-- SECURITY DEFINER prevents clients from querying private donor tables directly.
-- The result deliberately excludes donor address and precise coordinates.
create function public.discover_eligible_listings()
returns table(listing_id uuid,source_type text,listing_weight_kg numeric,
 listing_created_at timestamptz)
language plpgsql security definer
set search_path=public,extensions,pg_temp as $$
declare v_actor uuid:=auth.uid();v_ngo public.ngo_profiles%rowtype;
begin
 select * into v_ngo from public.ngo_profiles where user_id=v_actor and active_flag;
 if not found or v_ngo.location_verified_at is null then return; end if;
 return query
 select l.listing_id,l.source_type,l.listing_weight_kg,l.created_at
 from public.listings l join public.coordination_config cfg on cfg.singleton
 where l.listing_status='AVAILABLE'
 and (l.listing_expires_at is null or l.listing_expires_at>clock_timestamp())
 and ST_DWithin(
  ST_SetSRID(ST_MakePoint(v_ngo.longitude,v_ngo.latitude),4326)::geography,
  ST_SetSRID(ST_MakePoint(l.pickup_longitude,l.pickup_latitude),4326)::geography,
  cfg.geofence_radius_m)
 and ((l.source_type='DIRECT_DONATION' and exists(
   select 1 from public.donations d where d.donation_id=l.donation_id
   and d.donation_status='READY_FOR_PICKUP'
   and (d.availability_start is null or d.availability_start<=clock_timestamp())))
 or (l.source_type='HUB_BATCH' and exists(
   select 1 from public.hub_batches b where b.batch_id=l.batch_id
   and b.batch_status='PUBLISHED')))
 order by l.created_at desc;
end $$;

-- 15. Atomic claim, idempotent by request_id, one commit.
-- Request ID replay returns original outcome; a different payload is rejected.
-- Rejected attempts are logged in the same committed RPC transaction.
create function public.claim_listing(p_listing uuid,p_request uuid)
returns jsonb language plpgsql security definer
set search_path=public,extensions,pg_temp as $$
declare v_actor uuid:=auth.uid();v_ngo public.ngo_profiles%rowtype;
 v_req public.claim_requests%rowtype;v_l public.listings%rowtype;
 v_digest text;v_reason text;v_claim uuid;v_lease uuid;v_mins integer;
 v_node text;v_success boolean:=false;v_outcome text;
begin
 if v_actor is null then raise exception 'UNAUTHENTICATED'; end if;
 select * into v_ngo from public.ngo_profiles where user_id=v_actor and active_flag;
 if not found then raise exception 'ACTIVE_NGO_ONLY'; end if;
 if p_request is null or p_listing is null then raise exception 'REQUEST_AND_LISTING_REQUIRED'; end if;
 v_digest=md5(p_listing::text||':'||v_actor::text);
 insert into public.claim_requests(request_id,listing_id,ngo_user_id,request_digest)
 values(p_request,p_listing,v_actor,v_digest) on conflict(request_id) do nothing;
 select * into v_req from public.claim_requests where request_id=p_request for update;
 if v_req.request_digest<>v_digest or v_req.listing_id<>p_listing or v_req.ngo_user_id<>v_actor
 then raise exception 'IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD'; end if;
 if v_req.outcome is not null then
  return jsonb_build_object('outcome',v_req.outcome,'claim_id',v_req.result_claim_id,
    'reason_code',v_req.reason_code,'replayed',true);
 end if;
 select * into v_l from public.listings where listing_id=p_listing for update;
 if not found then v_reason='LISTING_NOT_FOUND';
 elsif v_l.listing_status<>'AVAILABLE' then v_reason='CLAIM_CONFLICT';
 elsif v_l.listing_expires_at is not null and v_l.listing_expires_at<=clock_timestamp()
 then v_reason='LISTING_EXPIRED';
 elsif v_ngo.location_verified_at is null then v_reason='ELIGIBILITY_UNDETERMINED';
 elsif not ST_DWithin(
  ST_SetSRID(ST_MakePoint(v_ngo.longitude,v_ngo.latitude),4326)::geography,
  ST_SetSRID(ST_MakePoint(v_l.pickup_longitude,v_l.pickup_latitude),4326)::geography,
  20000) then v_reason='NGO_INELIGIBLE';
 elsif v_l.pickup_road_node_id is null then v_reason='ROUTING_NODE_MISSING';
 elsif v_l.source_type='DIRECT_DONATION' and not exists(
  select 1 from public.donations d where d.donation_id=v_l.donation_id
  and d.donation_status='READY_FOR_PICKUP'
  and (d.availability_start is null or d.availability_start<=clock_timestamp()))
 then v_reason='DONATION_NOT_READY';
 elsif v_l.source_type='HUB_BATCH' and not exists(
  select 1 from public.hub_batches b where b.batch_id=v_l.batch_id and b.batch_status='PUBLISHED')
 then v_reason='BATCH_NOT_PUBLISHED';
 else
  select claim_lease_minutes into v_mins from public.coordination_config where singleton;
  if v_mins is null then raise exception 'CLAIM_LEASE_NOT_CONFIGURED'; end if;
  insert into public.donation_claims(listing_id,ngo_user_id,request_id)
  values(p_listing,v_actor,p_request) returning claim_id into v_claim;
  insert into public.claim_leases(claim_id,expires_at)
  values(v_claim,clock_timestamp()+make_interval(mins=>v_mins))
  returning lease_id into v_lease;
  update public.listings set listing_status='CLAIMED',listing_version=listing_version+1
   where listing_id=p_listing;
  insert into public.pickup_tasks(claim_id,listing_id,ngo_user_id,pickup_road_node_id,load_kg)
  values(v_claim,p_listing,v_actor,v_l.pickup_road_node_id,v_l.listing_weight_kg);
  v_success=true;
 end if;
 v_outcome=case when v_success then 'SUCCESS'
  when v_reason='NGO_INELIGIBLE' then 'INELIGIBLE' else 'CONFLICT' end;
 update public.claim_requests set outcome=v_outcome,result_claim_id=v_claim,
  reason_code=v_reason,completed_at=clock_timestamp() where request_id=p_request;
 insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,
 request_id,claim_id,lease_id,previous_state,requested_state,resulting_state,
 reason_code,outcome,details,configuration_version)
 select v_actor,'NGO','LISTING',p_listing,'CLAIM_ATTEMPT',p_request,v_claim,v_lease,
 v_l.listing_status,'CLAIMED',
 case when v_success then 'CLAIMED' else v_l.listing_status end,v_reason,
 case when v_success then 'SUCCESS' else 'REJECTED' end,
 jsonb_build_object('ngo_id',v_actor),cfg.config_version
 from public.coordination_config cfg where cfg.singleton;
 return jsonb_build_object('outcome',v_outcome,'claim_id',v_claim,
   'reason_code',v_reason,'replayed',false);
end $$;

-- 16. Pickup start and handover: require live lease and same NGO.
-- A collected donation is physically transferred, even if later lease expires.
create function public.start_pickup(p_claim uuid)
returns void language plpgsql security definer
set search_path=public,extensions,pg_temp as $$
declare v_actor uuid:=auth.uid();v_c public.donation_claims%rowtype;
 v_l public.listings%rowtype;v_lease public.claim_leases%rowtype;
begin
 select * into v_c from public.donation_claims where claim_id=p_claim for update;
 if not found or v_c.ngo_user_id is distinct from v_actor or v_c.claim_status<>'ACTIVE'
 then raise exception 'NOT_ACTIVE_CLAIM_HOLDER'; end if;
 select * into v_lease from public.claim_leases where claim_id=p_claim for update;
 if v_lease.lease_status<>'ACTIVE' or v_lease.expires_at<=clock_timestamp()
 then raise exception 'STALE_OR_EXPIRED_LEASE'; end if;
 select * into v_l from public.listings where listing_id=v_c.listing_id for update;
 if v_l.listing_status<>'CLAIMED' then raise exception 'LISTING_NOT_CLAIMED'; end if;
 update public.pickup_tasks set task_status='DISPATCHED'
 where claim_id=p_claim and task_status in ('CONFIRMED','PLANNED');
 if not found then raise exception 'PICKUP_TASK_NOT_DISPATCHABLE'; end if;
 if v_l.source_type='DIRECT_DONATION' then
  update public.donations set donation_status='PICKUP_IN_PROGRESS'
  where donation_id=v_l.donation_id and donation_status='READY_FOR_PICKUP';
 else
  update public.donations set donation_status='PICKUP_IN_PROGRESS'
  where donation_id in(select donation_id from public.hub_batch_members
    where batch_id=v_l.batch_id and membership_status='ACTIVE')
    and donation_status='BATCHED';
 end if;
 insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,
 claim_id,lease_id,requested_state,resulting_state,outcome)
 values(v_actor,'NGO','CLAIM',p_claim,'START_PICKUP',p_claim,v_lease.lease_id,
 'PICKUP_IN_PROGRESS','PICKUP_IN_PROGRESS','SUCCESS');
end $$;

create function public.complete_pickup(p_claim uuid,p_handover_confirmed boolean)
returns void language plpgsql security definer
set search_path=public,extensions,pg_temp as $$
declare v_actor uuid:=auth.uid();v_c public.donation_claims%rowtype;
 v_l public.listings%rowtype;v_lease public.claim_leases%rowtype;
begin
 select * into v_c from public.donation_claims where claim_id=p_claim for update;
 if not found or v_c.ngo_user_id is distinct from v_actor or v_c.claim_status<>'ACTIVE'
 then raise exception 'NOT_ACTIVE_CLAIM_HOLDER'; end if;
 select * into v_lease from public.claim_leases where claim_id=p_claim for update;
 if v_lease.lease_status<>'ACTIVE' or v_lease.expires_at<=clock_timestamp()
 then raise exception 'STALE_OR_EXPIRED_LEASE'; end if;
 if p_handover_confirmed is distinct from true then raise exception 'HANDOVER_NOT_CONFIRMED'; end if;
 select * into v_l from public.listings where listing_id=v_c.listing_id for update;
 if v_l.listing_status<>'CLAIMED' then raise exception 'LISTING_NOT_CLAIMED'; end if;
 update public.pickup_tasks set task_status='COLLECTED'
 where claim_id=p_claim and task_status='DISPATCHED';
 if not found then raise exception 'PICKUP_NOT_STARTED'; end if;
 if v_l.source_type='DIRECT_DONATION' then
  update public.donations set donation_status='COLLECTED'
  where donation_id=v_l.donation_id and donation_status='PICKUP_IN_PROGRESS';
  if not found then raise exception 'INVALID_DONATION_STATE'; end if;
 else
  update public.donations set donation_status='COLLECTED'
  where donation_id in(select donation_id from public.hub_batch_members
    where batch_id=v_l.batch_id and membership_status='ACTIVE')
    and donation_status='PICKUP_IN_PROGRESS';
  update public.hub_inventory set inventory_status='COLLECTED'
  where donation_id in(select donation_id from public.hub_batch_members
    where batch_id=v_l.batch_id and membership_status='ACTIVE');
  update public.hub_batches set batch_status='COLLECTED' where batch_id=v_l.batch_id;
 end if;
 update public.listings set listing_status='CLOSED',listing_version=listing_version+1
 where listing_id=v_l.listing_id;
 update public.donation_claims set claim_status='COMPLETED',closed_at=clock_timestamp()
 where claim_id=p_claim;
 update public.claim_leases set lease_status='COMPLETED',closed_at=clock_timestamp()
 where claim_id=p_claim;
 insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,
 claim_id,lease_id,requested_state,resulting_state,outcome)
 values(v_actor,'NGO','CLAIM',p_claim,'COMPLETE_PICKUP',p_claim,v_lease.lease_id,
 'COLLECTED','COLLECTED','SUCCESS');
end $$;

-- 17. Recovery: backend worker only. NEVER give this RPC to authenticated clients.
-- Distinguish expiry from safe release; dispatched/physical uncertainty requires reconciliation.
create function public.recover_expired_claims(p_limit integer default 100)
returns integer language plpgsql security definer
set search_path=public,extensions,pg_temp as $$
declare v_rec record;v_task_status text;v_l public.listings%rowtype;
 v_processed integer:=0;v_uncertain boolean;
begin
 if auth.role() is distinct from 'service_role' then raise exception 'SERVICE_ROLE_ONLY'; end if;
 for v_rec in
  select c.claim_id,c.listing_id,cl.lease_id from public.claim_leases cl
  join public.donation_claims c on c.claim_id=cl.claim_id
  where cl.lease_status='ACTIVE' and cl.expires_at<=clock_timestamp()
  order by cl.expires_at
  for update of cl skip locked limit greatest(1,least(p_limit,1000))
 loop
  select * into v_l from public.listings where listing_id=v_rec.listing_id for update;
  select task_status into v_task_status from public.pickup_tasks where claim_id=v_rec.claim_id for update;
  v_uncertain=v_task_status in ('DISPATCHED','COLLECTED')
   or v_l.listing_status='CLOSED'
   or (v_l.source_type='DIRECT_DONATION' and exists(
    select 1 from public.donations where donation_id=v_l.donation_id
    and donation_status in ('PICKUP_IN_PROGRESS','COLLECTED','DELIVERED')))
   or (v_l.source_type='HUB_BATCH' and exists(
    select 1 from public.donations where donation_id in
     (select donation_id from public.hub_batch_members where batch_id=v_l.batch_id)
    and donation_status in ('PICKUP_IN_PROGRESS','COLLECTED','DELIVERED')));
  if v_uncertain then
   update public.claim_leases set lease_status='RECONCILIATION_REQUIRED'
    where lease_id=v_rec.lease_id;
   update public.donation_claims set claim_status='RECONCILIATION_REQUIRED'
    where claim_id=v_rec.claim_id;
  else
   update public.claim_leases set lease_status='RELEASED',closed_at=clock_timestamp(),
    release_reason='EXPIRED_SAFE_RELEASE' where lease_id=v_rec.lease_id;
   update public.donation_claims set claim_status='RELEASED',closed_at=clock_timestamp(),
    close_reason='EXPIRED_SAFE_RELEASE' where claim_id=v_rec.claim_id;
   update public.pickup_tasks set task_status='STALE' where claim_id=v_rec.claim_id;
   if v_l.listing_status='CLAIMED'
      and (v_l.listing_expires_at is null or v_l.listing_expires_at>clock_timestamp()) then
     update public.listings set listing_status='AVAILABLE',listing_version=listing_version+1
      where listing_id=v_l.listing_id;
   end if;
  end if;
  insert into public.audit_events(actor_role,entity_type,entity_id,event_type,claim_id,
   lease_id,previous_state,requested_state,resulting_state,outcome,reason_code)
  values('SYSTEM','CLAIM',v_rec.claim_id,'LEASE_RECOVERY',v_rec.claim_id,v_rec.lease_id,
   'ACTIVE',case when v_uncertain then 'RECONCILIATION_REQUIRED' else 'RELEASED' end,
   case when v_uncertain then 'RECONCILIATION_REQUIRED' else 'RELEASED' end,'SUCCESS',
   case when v_uncertain then 'HANDOVER_UNCERTAIN' else 'EXPIRED_SAFE_RELEASE' end);
  v_processed=v_processed+1;
 end loop;
 return v_processed;
end $$;

-- 18. Route task assignment: atomic uniqueness, owner check.
-- This does not replace the independent external route feasibility validator.
create function public.assign_task_to_route(p_route uuid,p_task uuid,p_stop_order integer)
returns void language plpgsql security definer
set search_path=public,extensions,pg_temp as $$
declare v_actor uuid:=auth.uid();v_r public.pickup_routes%rowtype;
 v_t public.pickup_tasks%rowtype;
begin
 select * into v_r from public.pickup_routes where route_id=p_route for update;
 if not found or v_r.ngo_user_id is distinct from v_actor or v_r.route_status<>'DRAFT'
 then raise exception 'ROUTE_NOT_EDITABLE_BY_NGO'; end if;
 select * into v_t from public.pickup_tasks where task_id=p_task for update;
 if not found or v_t.ngo_user_id<>v_actor or v_t.task_status not in ('CONFIRMED','PLANNED')
 then raise exception 'TASK_NOT_ASSIGNABLE'; end if;
 if not exists(select 1 from public.donation_claims c
 join public.claim_leases l on l.claim_id=c.claim_id
 where c.claim_id=v_t.claim_id and c.claim_status='ACTIVE'
 and l.lease_status='ACTIVE' and l.expires_at>clock_timestamp())
 then raise exception 'STALE_CLAIM'; end if;
 insert into public.active_task_route_assignments(task_id,route_id)
 values(p_task,p_route);
 insert into public.pickup_route_stops(route_id,ngo_user_id,stop_order,task_id)
 values(p_route,v_actor,p_stop_order,p_task);
 update public.pickup_tasks set task_status='PLANNED' where task_id=p_task;
 insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,
 requested_state,resulting_state,outcome,details)
 values(v_actor,'NGO','TASK',p_task,'ASSIGN_ROUTE','PLANNED','PLANNED','SUCCESS',
 jsonb_build_object('route_id',p_route));
end $$;

-- 19. RLS. Default deny for all tables; discovery and writes via protected RPCs.
do $$
declare t text;
begin
 foreach t in array array[
  'user_profiles','donor_profiles','ngo_profiles','hub_admin_profiles',
  'coordination_config','donation_categories','community_hubs','hub_accepted_categories',
  'donations','donation_items','hub_reservations','hub_receipts','hub_inventory',
  'hub_batches','hub_batch_members','listings','claim_requests','donation_claims',
  'claim_leases','vehicles','pickup_tasks','pickup_routes','pickup_route_stops',
  'active_task_route_assignments','audit_events'
 ] loop execute format('alter table public.%I enable row level security',t); end loop;
end $$;

-- No direct client writes. These revokes assume default grants may be broad.
revoke all on all tables in schema public from anon,authenticated;
revoke all on all sequences in schema public from anon,authenticated;
-- Explicitly control RPC access. Functions are PUBLIC-executable by default in PostgreSQL.
revoke all on function public.register_role_profile(text,text,text,text,text,text,double precision,double precision,text) from public;
revoke all on function public.create_and_validate_donation(text,text,text,double precision,double precision,jsonb,text,timestamptz,timestamptz) from public;
revoke all on function public.register_community_hub(text,text,double precision,double precision,numeric,text) from public;
revoke all on function public.reserve_hub_capacity(uuid,uuid) from public;
revoke all on function public.confirm_hub_receipt(uuid,numeric) from public;
revoke all on function public.publish_whole_donation_batch(uuid,uuid[]) from public;
revoke all on function public.discover_eligible_listings() from public;
revoke all on function public.claim_listing(uuid,uuid) from public;
revoke all on function public.start_pickup(uuid) from public;
revoke all on function public.complete_pickup(uuid,boolean) from public;
revoke all on function public.recover_expired_claims(integer) from public;
revoke all on function public.assign_task_to_route(uuid,uuid,integer) from public;
revoke all on function public.prevent_role_change() from public;
revoke all on function public.enforce_donation_transition() from public;
revoke all on function public.enforce_listing_transition() from public;
revoke all on function public.guard_donation_items() from public;
revoke all on function public.guard_batch_immutability() from public;
revoke all on function public.prevent_audit_mutation() from public;
grant execute on function public.register_role_profile(text,text,text,text,text,text,double precision,double precision,text) to authenticated;
grant execute on function public.create_and_validate_donation(text,text,text,double precision,double precision,jsonb,text,timestamptz,timestamptz) to authenticated;
grant execute on function public.register_community_hub(text,text,double precision,double precision,numeric,text) to authenticated;
grant execute on function public.reserve_hub_capacity(uuid,uuid) to authenticated;
grant execute on function public.confirm_hub_receipt(uuid,numeric) to authenticated;
grant execute on function public.publish_whole_donation_batch(uuid,uuid[]) to authenticated;
grant execute on function public.discover_eligible_listings() to authenticated;
grant execute on function public.claim_listing(uuid,uuid) to authenticated;
grant execute on function public.start_pickup(uuid) to authenticated;
grant execute on function public.complete_pickup(uuid,boolean) to authenticated;
grant execute on function public.assign_task_to_route(uuid,uuid,integer) to authenticated;
grant execute on function public.recover_expired_claims(integer) to service_role;

-- 20. Required trusted backend work before deployment:
-- A. Provision HUB_ADMIN via trusted service role (no self-registration endpoint).
-- B. Geocode and verify NGO address/pin; never blindly trust user-supplied coordinates.
-- C. Provision hub accepted categories via controlled admin workflow.
-- D. Implement read RPCs for owner data, listing detail, task and route detail.
-- E. Implement protected vehicle/route creation, route cancellation and route validation.
-- F. Implement route authorization with trusted road-network/time-window proof and revalidation.
-- G. Implement donor cancellation, delivery confirmation, and reconciliation resolution.
-- H. Schedule recover_expired_claims from trusted backend; verify auth.role() behavior.
-- I. Add tests for races, stale holders, transaction rollback, rejected attempts, hub capacity.
-- J. Review function-owner privileges, schema exposure, default privileges and RLS.
