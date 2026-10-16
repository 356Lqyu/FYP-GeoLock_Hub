-- GeoLock Hub additive Stage 1 migration proposal.
-- REVIEW ONLY: do not run on the shared project until the owner approves it.
-- Apply only after the matching V3_10kg_360min fresh-install schema.
-- No benchmark fixtures are imported by this migration.

begin;

-- Keep location evidence from NGO self-registration unverified. This preserves
-- the exact existing signature and role checks, while ignoring client supplied
-- road node IDs. Trusted verification is a separate operation below.
create or replace function public.register_role_profile(
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
 if p_role='NGO' and (
   nullif(btrim(p_ngo_name),'') is null or nullif(btrim(p_operating_address),'') is null
   or p_latitude is null or p_longitude is null
   or p_latitude not between -90 and 90 or p_longitude not between -180 and 180
 ) then raise exception 'NGO_LOCATION_REQUIRED'; end if;

 insert into public.user_profiles(user_id,full_name,phone_number,role)
 values(v_user,p_full_name,p_phone,p_role);
 if p_role='DONOR' then
  insert into public.donor_profiles(user_id) values(v_user);
 else
  insert into public.ngo_profiles(
   user_id,ngo_name,registration_number,operating_address,latitude,longitude,
   road_node_id,location_verified_at
  ) values(
   v_user,p_ngo_name,p_registration_number,p_operating_address,p_latitude,p_longitude,
   null,null
  );
 end if;
 insert into public.audit_events(
  actor_user_id,actor_role,entity_type,entity_id,event_type,requested_state,
  resulting_state,outcome,reason_code,transaction_id,configuration_version
 ) select v_user,p_role,'USER',v_user,'REGISTER_ROLE',p_role,p_role,'SUCCESS',
  case when p_role='NGO' then 'LOCATION_PENDING_TRUSTED_VERIFICATION' end,
  pg_current_xact_id()::text,config_version
 from public.coordination_config where singleton;
 return v_user;
end $$;

-- Preserve individual IDs and transaction correlation on audit records.
alter table public.audit_events add column if not exists donation_id uuid;
alter table public.audit_events add column if not exists listing_id uuid;
alter table public.audit_events add column if not exists transaction_id text;
create index if not exists idx_audit_donation on public.audit_events(donation_id,occurred_at);
create index if not exists idx_audit_listing on public.audit_events(listing_id,occurred_at);

-- Nodes are trusted road-network data, not values supplied by an app user.
-- A network import process must add independently validated production nodes.
create table if not exists public.road_network_nodes (
 road_node_id text primary key,
 latitude double precision not null check(latitude between -90 and 90),
 longitude double precision not null check(longitude between -180 and 180),
 network_snapshot_id text not null,
 active_flag boolean not null default true,
 imported_at timestamptz not null default clock_timestamp()
);
create table if not exists public.road_network_coverage (
 network_snapshot_id text primary key,
 coverage_area extensions.geometry(MultiPolygon,4326) not null,
 max_snap_distance_m integer not null check(max_snap_distance_m between 1 and 1000),
 provenance text not null,
 dataset_kind text not null default 'OPERATIONAL'
  check(dataset_kind in ('OPERATIONAL','BENCHMARK')),
 approved_at timestamptz,
 active_flag boolean not null default false
);
create index if not exists idx_road_coverage_gist
 on public.road_network_coverage using gist(coverage_area);
alter table public.road_network_nodes enable row level security;
alter table public.road_network_coverage enable row level security;
revoke all on public.road_network_nodes from public,anon,authenticated;
revoke all on public.road_network_coverage from public,anon,authenticated;

create or replace function public.geolock_app_capabilities()
returns jsonb language plpgsql stable security definer
set search_path=public,pg_temp as $$
begin
 if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
 return jsonb_build_object(
  'ngo_location_registration','UNVERIFIED',
  'road_node_resolution',true,
  'location_picker','GOOGLE_MAPS',
  'configuration_version',(select config_version from public.coordination_config where singleton)
 );
end $$;

create or replace function public.get_my_profile()
returns jsonb language plpgsql stable security definer
set search_path=public,pg_temp as $$
declare v_user uuid:=auth.uid(); v_result jsonb;
begin
 if v_user is null then raise exception 'UNAUTHENTICATED'; end if;
 select jsonb_build_object('user_id',u.user_id,'full_name',u.full_name,
  'phone_number',u.phone_number,'role',u.role,'created_at',u.created_at,
  'ngo_name',n.ngo_name,'operating_address',n.operating_address,
  'latitude',n.latitude,'longitude',n.longitude,
  'location_verified_at',n.location_verified_at,
  'location_status',case when n.user_id is null then null
    when n.location_verified_at is null then 'PENDING_VERIFICATION' else 'VERIFIED' end,
  'hub_admin',h.user_id is not null)
 into v_result from public.user_profiles u
 left join public.ngo_profiles n on n.user_id=u.user_id
 left join public.hub_admin_profiles h on h.user_id=u.user_id
 where u.user_id=v_user;
 return v_result;
end $$;

create or replace function public.get_active_donation_categories()
returns table(category_id uuid,category_name text)
language plpgsql stable security definer
set search_path=public,pg_temp as $$
begin
 if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
 if not exists(select 1 from public.user_profiles where user_id=auth.uid())
 then raise exception 'PROFILE_REQUIRED'; end if;
 return query select c.category_id,c.category_name from public.donation_categories c
 where c.active_flag order by c.category_name;
end $$;

create or replace function public.resolve_pickup_road_node(
 p_latitude double precision,p_longitude double precision
) returns text language plpgsql stable security definer
set search_path=public,extensions,pg_temp as $$
declare v_node text;
begin
 if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
 if not exists(select 1 from public.user_profiles where user_id=auth.uid())
 then raise exception 'PROFILE_REQUIRED'; end if;
 if p_latitude is null or p_longitude is null
   or p_latitude not between -90 and 90 or p_longitude not between -180 and 180
 then raise exception 'INVALID_COORDINATES'; end if;
 select n.road_node_id into v_node from public.road_network_nodes n
 join public.road_network_coverage c using(network_snapshot_id)
 where n.active_flag and c.active_flag and c.dataset_kind='OPERATIONAL'
 and c.approved_at is not null
 and extensions.ST_Covers(c.coverage_area,
   extensions.ST_SetSRID(extensions.ST_MakePoint(p_longitude,p_latitude),4326))
 and extensions.ST_DWithin(
  extensions.ST_SetSRID(extensions.ST_MakePoint(n.longitude,n.latitude),4326)::extensions.geography,
  extensions.ST_SetSRID(extensions.ST_MakePoint(p_longitude,p_latitude),4326)::extensions.geography,
  c.max_snap_distance_m
 )
 order by extensions.ST_Distance(
  extensions.ST_SetSRID(extensions.ST_MakePoint(n.longitude,n.latitude),4326)::extensions.geography,
  extensions.ST_SetSRID(extensions.ST_MakePoint(p_longitude,p_latitude),4326)::extensions.geography
 ) limit 1;
 return v_node;
end $$;

create or replace function public.validate_listing_road_node()
returns trigger language plpgsql security definer
set search_path=public,extensions,pg_temp as $$
begin
 if new.pickup_road_node_id is not null and not exists(
  select 1 from public.road_network_nodes n join public.road_network_coverage c
   using(network_snapshot_id)
  where n.road_node_id=new.pickup_road_node_id and n.active_flag
   and c.active_flag and c.dataset_kind='OPERATIONAL' and c.approved_at is not null
   and extensions.ST_Covers(c.coverage_area,
    extensions.ST_SetSRID(extensions.ST_MakePoint(new.pickup_longitude,new.pickup_latitude),4326))
   and extensions.ST_DWithin(
    extensions.ST_SetSRID(extensions.ST_MakePoint(n.longitude,n.latitude),4326)::extensions.geography,
    extensions.ST_SetSRID(extensions.ST_MakePoint(new.pickup_longitude,new.pickup_latitude),4326)::extensions.geography,
    c.max_snap_distance_m
   )
 ) then
  new.pickup_road_node_id:=null;
  new.routing_status:='PENDING_NODE';
 else
  new.routing_status:='READY';
 end if;
 return new;
end $$;

alter table public.listings add column if not exists routing_status text not null
 default 'PENDING_NODE' check(routing_status in ('PENDING_NODE','READY'));

drop function if exists public.get_my_donations();
create function public.get_my_donations()
returns table(donation_id uuid,title text,donation_status text,collection_path text,
 total_weight_kg numeric,created_at timestamptz,hub_name text,reservation_status text,
 listing_routing_status text)
language plpgsql stable security definer
set search_path=public,pg_temp as $$
begin
 if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
 if not exists(select 1 from public.donor_profiles where user_id=auth.uid())
 then raise exception 'DONOR_ONLY'; end if;
 return query select d.donation_id,d.title,d.donation_status,d.collection_path,
  d.total_weight_kg,d.created_at,h.hub_name,r.reservation_status,
  (select l.routing_status from public.listings l where l.donation_id=d.donation_id
   and l.source_type='DIRECT_DONATION')
 from public.donations d
 left join public.hub_reservations r on r.donation_id=d.donation_id
 left join public.community_hubs h on h.hub_id=r.hub_id
 where d.donor_user_id=auth.uid() order by d.created_at desc;
end $$;

create or replace function public.get_my_donation_detail(p_donation uuid)
returns jsonb language plpgsql stable security definer
set search_path=public,pg_temp as $$
declare v jsonb;
begin
 if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
 select jsonb_build_object(
  'donation_id',d.donation_id,'title',d.title,'description',d.description,
  'status',d.donation_status,'collection_path',d.collection_path,
  'total_weight_kg',d.total_weight_kg,'pickup_address',d.pickup_address,
  'latitude',d.latitude,'longitude',d.longitude,'created_at',d.created_at,
  'availability_start',d.availability_start,'availability_end',d.availability_end,
  'listing_status',(select l.listing_status from public.listings l
    where l.donation_id=d.donation_id and l.source_type='DIRECT_DONATION'),
  'road_node_status',(select l.routing_status from public.listings l
    where l.donation_id=d.donation_id and l.source_type='DIRECT_DONATION'),
  'items',coalesce((select jsonb_agg(jsonb_build_object(
   'item_id',i.item_id,'category_id',i.category_id,'category',c.category_name,
   'item_name',i.item_name,'quantity',i.quantity,'unit_weight_kg',i.unit_weight_kg,
   'item_condition',i.item_condition) order by i.created_at)
   from public.donation_items i join public.donation_categories c using(category_id)
   where i.donation_id=d.donation_id),'[]'::jsonb),
  'hub_reservations',coalesce((select jsonb_agg(jsonb_build_object(
   'reservation_id',r.reservation_id,'hub_id',r.hub_id,'hub_name',h.hub_name,
   'status',r.reservation_status,'expires_at',r.expires_at)
   order by r.reserved_at desc) from public.hub_reservations r
   join public.community_hubs h using(hub_id) where r.donation_id=d.donation_id),'[]'::jsonb)
 ) into v from public.donations d where d.donation_id=p_donation
 and d.donor_user_id=auth.uid();
 if v is null then raise exception 'DONATION_NOT_FOUND_OR_FORBIDDEN'; end if;
 return v;
end $$;

create or replace function public.validate_my_donation_road_node(p_donation uuid)
returns jsonb language plpgsql security definer
set search_path=public,extensions,pg_temp as $$
declare v_d public.donations%rowtype; v_node text; v_listing uuid;
 v_updated integer;
begin
 if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
 select * into v_d from public.donations where donation_id=p_donation
  and donor_user_id=auth.uid() for update;
 if not found then raise exception 'DONATION_NOT_FOUND_OR_FORBIDDEN'; end if;
 if v_d.collection_path<>'DIRECT_PICKUP' or v_d.donation_status<>'READY_FOR_PICKUP'
 then return jsonb_build_object('status','NOT_APPLICABLE','claimable',false); end if;
 v_node:=public.resolve_pickup_road_node(v_d.latitude,v_d.longitude);
 select listing_id into v_listing from public.listings
  where donation_id=p_donation and source_type='DIRECT_DONATION' for update;
 if not found then raise exception 'DIRECT_LISTING_NOT_FOUND'; end if;
 update public.listings set pickup_road_node_id=v_node where listing_id=v_listing
  and listing_status='AVAILABLE';
 get diagnostics v_updated=row_count;
 if v_updated=0 then
  return jsonb_build_object('status','NOT_AVAILABLE','claimable',false);
 end if;
 if v_node is null then
  return jsonb_build_object('status','PENDING_NODE','claimable',false);
 end if;
 update public.donations set pickup_road_node_id=v_node where donation_id=p_donation;
 return jsonb_build_object('status','READY','claimable',true,'road_node_id',v_node);
end $$;

create or replace function public.get_my_claims()
returns table(claim_id uuid,listing_id uuid,claim_status text,claimed_at timestamptz,
 lease_id uuid,lease_status text,lease_expires_at timestamptz,
 task_status text,source_type text,listing_weight_kg numeric)
language plpgsql stable security definer
set search_path=public,pg_temp as $$
begin
 if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
 if not exists(select 1 from public.ngo_profiles where user_id=auth.uid())
 then raise exception 'ACTIVE_NGO_ONLY'; end if;
 return query select c.claim_id,c.listing_id,c.claim_status,c.claimed_at,
  lse.lease_id,lse.lease_status,lse.expires_at,t.task_status,l.source_type,l.listing_weight_kg
 from public.donation_claims c
 join public.listings l using(listing_id)
 left join public.claim_leases lse using(claim_id)
 left join public.pickup_tasks t using(claim_id)
 where c.ngo_user_id=auth.uid() order by c.claimed_at desc;
end $$;

create or replace function public.get_claimed_listing_detail(p_claim uuid)
returns jsonb language plpgsql stable security definer
set search_path=public,pg_temp as $$
declare v jsonb;
begin
 if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
 select jsonb_build_object('claim_id',c.claim_id,'claim_status',c.claim_status,
  'listing_id',l.listing_id,'listing_status',l.listing_status,'source_type',l.source_type,
  'pickup_address',case when l.source_type='DIRECT_DONATION' then d.pickup_address else h.address_text end,
  'latitude',l.pickup_latitude,'longitude',l.pickup_longitude,
  'listing_weight_kg',l.listing_weight_kg,'lease_status',le.lease_status,
  'lease_expires_at',le.expires_at,'donation_ids',coalesce((select jsonb_agg(m.donation_id)
    from public.hub_batch_members m where m.batch_id=l.batch_id and m.membership_status='ACTIVE'),
    case when d.donation_id is null then '[]'::jsonb else jsonb_build_array(d.donation_id) end))
 into v from public.donation_claims c join public.listings l using(listing_id)
 left join public.donations d on d.donation_id=l.donation_id
 left join public.hub_batches b on b.batch_id=l.batch_id
 left join public.community_hubs h on h.hub_id=b.hub_id
 left join public.claim_leases le using(claim_id)
 where c.claim_id=p_claim and c.ngo_user_id=auth.uid();
 if v is null then raise exception 'CLAIM_NOT_FOUND_OR_FORBIDDEN'; end if;
 return v;
end $$;

create or replace function public.get_my_hubs()
returns table(hub_id uuid,hub_name text,address_text text,latitude double precision,
 longitude double precision,capacity_kg numeric,active_flag boolean)
language plpgsql stable security definer
set search_path=public,pg_temp as $$
begin
 if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
 if not exists(select 1 from public.hub_admin_profiles where user_id=auth.uid())
 then raise exception 'HUB_ADMIN_ONLY'; end if;
 return query select h.hub_id,h.hub_name,h.address_text,h.latitude,h.longitude,
  h.capacity_kg,h.active_flag from public.community_hubs h
 where h.admin_user_id=auth.uid() order by h.created_at desc;
end $$;

create or replace function public.get_my_hub_reservations(p_hub uuid)
returns table(reservation_id uuid,donation_id uuid,title text,reserved_weight_kg numeric,
 status text,expires_at timestamptz)
language plpgsql stable security definer
set search_path=public,pg_temp as $$
begin
 if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
 if not exists(select 1 from public.community_hubs where hub_id=p_hub
   and admin_user_id=auth.uid()) then raise exception 'NOT_HUB_ADMIN'; end if;
 return query select r.reservation_id,r.donation_id,d.title,r.reserved_weight_kg,
  r.reservation_status,r.expires_at from public.hub_reservations r
 join public.donations d using(donation_id) where r.hub_id=p_hub
 order by r.reserved_at desc;
end $$;

create or replace function public.get_my_hub_inventory(p_hub uuid)
returns table(donation_id uuid,title text,donation_status text,received_weight_kg numeric,
 inventory_status text,category_ids uuid[],category_name text)
language plpgsql stable security definer
set search_path=public,pg_temp as $$
begin
 if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
 if not exists(select 1 from public.community_hubs where hub_id=p_hub
   and admin_user_id=auth.uid()) then raise exception 'NOT_HUB_ADMIN'; end if;
 return query select d.donation_id,d.title,d.donation_status,hr.received_weight_kg,
  hi.inventory_status,array_agg(distinct di.category_id),
  case when count(distinct di.category_id)=1 then min(cat.category_name) else 'Mixed categories' end
 from public.hub_inventory hi join public.donations d using(donation_id)
 join public.hub_receipts hr using(donation_id)
 left join public.donation_items di using(donation_id)
 left join public.donation_categories cat using(category_id)
 where hi.hub_id=p_hub group by d.donation_id,hr.received_weight_kg,hi.inventory_status
 order by min(hr.received_at) desc;
end $$;

create or replace function public.get_my_hub_batches(p_hub uuid)
returns table(batch_id uuid,batch_status text,batch_weight_kg numeric,
 batch_donation_count integer,category_name text,published_at timestamptz)
language plpgsql stable security definer
set search_path=public,pg_temp as $$
begin
 if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
 if not exists(select 1 from public.community_hubs where hub_id=p_hub
   and admin_user_id=auth.uid()) then raise exception 'NOT_HUB_ADMIN'; end if;
 return query select b.batch_id,b.batch_status,b.batch_weight_kg,b.batch_donation_count,
  c.category_name,b.published_at from public.hub_batches b
 left join public.donation_categories c on c.category_id=b.batch_category_id
 where b.hub_id=p_hub and b.batch_status<>'DRAFT' order by b.created_at desc;
end $$;

-- Sanitize both new and existing listing road nodes against the approved graph.
drop trigger if exists trg_listing_validate_road_node on public.listings;
create trigger trg_listing_validate_road_node before insert or update of pickup_road_node_id
on public.listings for each row execute function public.validate_listing_road_node();
update public.listings l set pickup_road_node_id=null
where l.pickup_road_node_id is not null and not exists(
 select 1 from public.road_network_nodes n join public.road_network_coverage c
 using(network_snapshot_id) where n.road_node_id=l.pickup_road_node_id
 and n.active_flag and c.active_flag and c.dataset_kind='OPERATIONAL'
 and c.approved_at is not null
 and extensions.ST_Covers(c.coverage_area,
  extensions.ST_SetSRID(extensions.ST_MakePoint(l.pickup_longitude,l.pickup_latitude),4326))
 and extensions.ST_DWithin(
  extensions.ST_SetSRID(extensions.ST_MakePoint(n.longitude,n.latitude),4326)::extensions.geography,
  extensions.ST_SetSRID(extensions.ST_MakePoint(l.pickup_longitude,l.pickup_latitude),4326)::extensions.geography,
  c.max_snap_distance_m)
);
update public.listings set pickup_road_node_id=pickup_road_node_id
where pickup_road_node_id is not null;

create or replace function public.invalidate_listing_nodes_for_coverage_change()
returns trigger language plpgsql security definer
set search_path=public,pg_temp as $$
declare v_snapshot text; v_node text; v_invalidate boolean:=false;
begin
 if tg_table_name='road_network_nodes' then
  v_snapshot:=old.network_snapshot_id;
  v_node:=old.road_node_id;
  v_invalidate:=tg_op='DELETE' or (tg_op='UPDATE' and
   (not new.active_flag or new.network_snapshot_id is distinct from old.network_snapshot_id
    or new.latitude is distinct from old.latitude or new.longitude is distinct from old.longitude));
  if v_invalidate then
   update public.listings set pickup_road_node_id=null
   where pickup_road_node_id=v_node;
  end if;
 else
  v_snapshot:=old.network_snapshot_id;
  v_invalidate:=tg_op='DELETE' or (tg_op='UPDATE' and
   (not new.active_flag or new.dataset_kind<>'OPERATIONAL' or new.approved_at is null
    or new.coverage_area is distinct from old.coverage_area
    or new.max_snap_distance_m is distinct from old.max_snap_distance_m));
  if v_invalidate then
   update public.listings l set pickup_road_node_id=null
   where l.pickup_road_node_id in (select n.road_node_id from public.road_network_nodes n
    where n.network_snapshot_id=v_snapshot);
  end if;
 end if;
 return null;
end $$;
drop trigger if exists trg_nodes_invalidate_listings on public.road_network_nodes;
create trigger trg_nodes_invalidate_listings after update or delete
on public.road_network_nodes for each row execute function public.invalidate_listing_nodes_for_coverage_change();
drop trigger if exists trg_coverage_invalidate_listings on public.road_network_coverage;
create trigger trg_coverage_invalidate_listings after update or delete
on public.road_network_coverage for each row execute function public.invalidate_listing_nodes_for_coverage_change();

-- Existing discovery is replaced with the same 20 km rule and public-safe
-- columns, plus a required active road-node match. It never returns donor pins.
create or replace function public.discover_eligible_listings()
returns table(listing_id uuid,source_type text,listing_weight_kg numeric,
 listing_created_at timestamptz)
language plpgsql security definer
set search_path=public,extensions,pg_temp as $$
declare v_actor uuid:=auth.uid();v_ngo public.ngo_profiles%rowtype;
begin
 select * into v_ngo from public.ngo_profiles where user_id=v_actor and active_flag;
 if not found or v_ngo.location_verified_at is null then return; end if;
 return query select l.listing_id,l.source_type,l.listing_weight_kg,l.created_at
 from public.listings l join public.coordination_config cfg on cfg.singleton
 where l.listing_status='AVAILABLE'
 and exists(select 1 from public.road_network_nodes n
  join public.road_network_coverage c using(network_snapshot_id)
   where n.road_node_id=l.pickup_road_node_id and n.active_flag
    and c.active_flag and c.dataset_kind='OPERATIONAL' and c.approved_at is not null
    and extensions.ST_Covers(c.coverage_area,
     extensions.ST_SetSRID(extensions.ST_MakePoint(l.pickup_longitude,l.pickup_latitude),4326)))
 and (l.listing_expires_at is null or l.listing_expires_at>clock_timestamp())
 and extensions.ST_DWithin(
  extensions.ST_SetSRID(extensions.ST_MakePoint(v_ngo.longitude,v_ngo.latitude),4326)::extensions.geography,
  extensions.ST_SetSRID(extensions.ST_MakePoint(l.pickup_longitude,l.pickup_latitude),4326)::extensions.geography,
  cfg.geofence_radius_m)
 and ((l.source_type='DIRECT_DONATION' and exists(select 1 from public.donations d
  where d.donation_id=l.donation_id and d.donation_status='READY_FOR_PICKUP'
   and (d.availability_start is null or d.availability_start<=clock_timestamp())))
  or (l.source_type='HUB_BATCH' and exists(select 1 from public.hub_batches b
   where b.batch_id=l.batch_id and b.batch_status='PUBLISHED')))
 order by l.created_at desc;
end $$;

-- Fill audit correlation and ownership columns for existing lifecycle RPCs that
-- already write an event. Software version remains explicitly unknown when a
-- legacy call path does not provide it.
create or replace function public.enrich_audit_event()
returns trigger language plpgsql security definer
set search_path=public,pg_temp as $$
begin
 new.transaction_id:=coalesce(new.transaction_id,pg_current_xact_id()::text);
 new.software_version:=coalesce(new.software_version,'backend-version-unspecified');
 new.configuration_version:=coalesce(new.configuration_version,
  (select config_version from public.coordination_config where singleton));
 if new.actor_user_id is not null and new.actor_role is null then
  select role into new.actor_role from public.user_profiles where user_id=new.actor_user_id;
 end if;
 if new.entity_type='DONATION' then new.donation_id:=coalesce(new.donation_id,new.entity_id); end if;
 if new.entity_type='LISTING' then new.listing_id:=coalesce(new.listing_id,new.entity_id); end if;
 if new.entity_type='CLAIM' and new.claim_id is null then new.claim_id:=new.entity_id; end if;
 if new.claim_id is not null then
  select coalesce(new.listing_id,l.listing_id),coalesce(new.donation_id,l.donation_id),
   coalesce(new.lease_id,le.lease_id)
  into new.listing_id,new.donation_id,new.lease_id
  from public.donation_claims c join public.listings l using(listing_id)
  left join public.claim_leases le using(claim_id)
  where c.claim_id=new.claim_id;
 end if;
 return new;
end $$;
drop trigger if exists trg_audit_enrich on public.audit_events;
create trigger trg_audit_enrich before insert on public.audit_events
for each row execute function public.enrich_audit_event();

-- Safe, explicit reconciliation resolution; it can only reopen a listing after
-- a trusted reviewer records that no physical handover occurred. If pickup was
-- dispatched, the donation state cannot be rolled backwards; it stays blocked.
create or replace function public.resolve_claim_reconciliation(
 p_claim uuid,p_no_handover_confirmed boolean,p_reason text
) returns jsonb language plpgsql security definer
set search_path=public,pg_temp as $$
declare v_c public.donation_claims%rowtype;v_l public.listings%rowtype;
 v_lease public.claim_leases%rowtype;v_task text;v_can_release boolean:=false;
begin
 if auth.role() is distinct from 'service_role' then raise exception 'TRUSTED_RECONCILIATION_ONLY'; end if;
 if nullif(btrim(p_reason),'') is null then raise exception 'RECONCILIATION_REASON_REQUIRED'; end if;
 select * into v_c from public.donation_claims where claim_id=p_claim for update;
 if not found or v_c.claim_status<>'RECONCILIATION_REQUIRED' then raise exception 'RECONCILIATION_NOT_OPEN'; end if;
 select * into v_l from public.listings where listing_id=v_c.listing_id for update;
 select * into v_lease from public.claim_leases where claim_id=p_claim for update;
 select task_status into v_task from public.pickup_tasks where claim_id=p_claim for update;
 v_can_release:=p_no_handover_confirmed is true and v_task in ('CONFIRMED','PLANNED')
  and ((v_l.source_type='DIRECT_DONATION' and exists(select 1 from public.donations
   where donation_id=v_l.donation_id and donation_status='READY_FOR_PICKUP'))
   or (v_l.source_type='HUB_BATCH' and not exists(select 1 from public.donations d
    join public.hub_batch_members m using(donation_id)
    where m.batch_id=v_l.batch_id and d.donation_status<>'BATCHED')));
 if not v_can_release then
  insert into public.audit_events(actor_role,entity_type,entity_id,event_type,donation_id,
   listing_id,claim_id,lease_id,transaction_id,previous_state,requested_state,
   resulting_state,reason_code,outcome)
  values('SYSTEM','CLAIM',p_claim,'RECONCILIATION_REMAINS_BLOCKED',v_l.donation_id,
   v_l.listing_id,p_claim,v_lease.lease_id,pg_current_xact_id()::text,
   'RECONCILIATION_REQUIRED','RELEASED','RECONCILIATION_REQUIRED',p_reason,'REJECTED');
  return jsonb_build_object('outcome','RECONCILIATION_REQUIRED','reason_code','SAFE_RELEASE_NOT_PROVEN');
 end if;
 update public.claim_leases set lease_status='RELEASED',closed_at=clock_timestamp(),
  release_reason='TRUSTED_SAFE_RELEASE' where lease_id=v_lease.lease_id;
 update public.donation_claims set claim_status='RELEASED',closed_at=clock_timestamp(),
  close_reason='TRUSTED_SAFE_RELEASE' where claim_id=p_claim;
 update public.pickup_tasks set task_status='STALE' where claim_id=p_claim;
 if v_l.listing_status='CLAIMED' and (v_l.listing_expires_at is null
  or v_l.listing_expires_at>clock_timestamp()) then
  update public.listings set listing_status='AVAILABLE',listing_version=listing_version+1
   where listing_id=v_l.listing_id;
 end if;
 insert into public.audit_events(actor_role,entity_type,entity_id,event_type,donation_id,
  listing_id,claim_id,lease_id,transaction_id,previous_state,requested_state,
  resulting_state,reason_code,outcome)
 values('SYSTEM','CLAIM',p_claim,'TRUSTED_RECONCILIATION_RELEASE',v_l.donation_id,
  v_l.listing_id,p_claim,v_lease.lease_id,pg_current_xact_id()::text,
  'RECONCILIATION_REQUIRED','RELEASED','RELEASED',p_reason,'SUCCESS');
 return jsonb_build_object('outcome','SUCCESS','reason_code','TRUSTED_SAFE_RELEASE');
end $$;

create or replace function public.get_eligible_hubs(p_donation uuid)
returns table(hub_id uuid,hub_name text,address_text text,latitude double precision,
 longitude double precision,capacity_kg numeric,available_capacity_kg numeric)
language plpgsql stable security definer
set search_path=public,pg_temp as $$
declare v_d public.donations%rowtype;
begin
 if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
 select * into v_d from public.donations where donation_id=p_donation
 and donor_user_id=auth.uid();
 if not found then raise exception 'DONATION_NOT_FOUND_OR_FORBIDDEN'; end if;
 if v_d.donation_status<>'VALIDATED' or v_d.collection_path<>'HUB_COLLECTION'
 then raise exception 'DONATION_NOT_HUB_ELIGIBLE'; end if;
 return query
 with usage as (
  select h.hub_id,
   coalesce((select sum(hr.received_weight_kg) from public.hub_inventory hi
    join public.hub_receipts hr using(donation_id)
    where hi.hub_id=h.hub_id and hi.inventory_status in ('STORED','BATCHED','RECONCILIATION_REQUIRED')),0)
   +coalesce((select sum(r.reserved_weight_kg) from public.hub_reservations r
    where r.hub_id=h.hub_id and r.reservation_status='ACTIVE'
    and r.expires_at>clock_timestamp()
    and not exists(select 1 from public.hub_receipts hr where hr.reservation_id=r.reservation_id)),0) as used
  from public.community_hubs h
 )
 select h.hub_id,h.hub_name,h.address_text,h.latitude,h.longitude,h.capacity_kg,
  greatest(0,h.capacity_kg-u.used)::numeric
 from public.community_hubs h join usage u using(hub_id)
 where h.active_flag and u.used+v_d.total_weight_kg<=h.capacity_kg
 and not exists(select 1 from public.donation_items i where i.donation_id=v_d.donation_id
   and not exists(select 1 from public.hub_accepted_categories a
     where a.hub_id=h.hub_id and a.category_id=i.category_id))
 order by h.hub_name;
end $$;

-- Releasing a claim is allowed only before any pickup dispatch. If the task has
-- been dispatched or the donation state is uncertain, ownership is held in
-- reconciliation and the listing stays closed to reassignment.
create or replace function public.release_claim(p_claim uuid,p_reason text default 'NGO_RELEASE')
returns jsonb language plpgsql security definer
set search_path=public,pg_temp as $$
declare v_actor uuid:=auth.uid(); v_c public.donation_claims%rowtype;
 v_l public.listings%rowtype; v_le public.claim_leases%rowtype; v_task text;
 v_safe boolean:=false; v_req uuid:=gen_random_uuid();
begin
 if v_actor is null then raise exception 'UNAUTHENTICATED'; end if;
 select * into v_c from public.donation_claims where claim_id=p_claim for update;
 if not found or v_c.ngo_user_id<>v_actor then raise exception 'NOT_CLAIM_OWNER'; end if;
 select * into v_l from public.listings where listing_id=v_c.listing_id for update;
 select * into v_le from public.claim_leases where claim_id=p_claim for update;
 select task_status into v_task from public.pickup_tasks where claim_id=p_claim for update;
 v_safe:=v_task in ('CONFIRMED','PLANNED')
  and ((v_l.source_type='DIRECT_DONATION' and exists(select 1 from public.donations
    where donation_id=v_l.donation_id and donation_status='READY_FOR_PICKUP'))
   or (v_l.source_type='HUB_BATCH' and not exists(select 1 from public.donations d
    join public.hub_batch_members m using(donation_id)
    where m.batch_id=v_l.batch_id and d.donation_status<>'BATCHED')));
 if not v_safe then
  update public.claim_leases set lease_status='RECONCILIATION_REQUIRED',
   release_reason='HANDOVER_UNCERTAIN',closed_at=clock_timestamp() where lease_id=v_le.lease_id
   and lease_status in ('ACTIVE','EXPIRED');
  update public.donation_claims set claim_status='RECONCILIATION_REQUIRED',
   close_reason='HANDOVER_UNCERTAIN',closed_at=clock_timestamp() where claim_id=p_claim
   and claim_status in ('ACTIVE','EXPIRED');
  insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,
   donation_id,listing_id,claim_id,lease_id,request_id,transaction_id,previous_state,
   requested_state,resulting_state,reason_code,outcome)
  values(v_actor,'NGO','CLAIM',p_claim,'CLAIM_RELEASE_REQUIRES_RECONCILIATION',
   v_l.donation_id,v_l.listing_id,p_claim,v_le.lease_id,v_req,pg_current_xact_id()::text,
   v_c.claim_status,'RELEASED','RECONCILIATION_REQUIRED','HANDOVER_UNCERTAIN','REJECTED');
  return jsonb_build_object('outcome','RECONCILIATION_REQUIRED','reason_code','HANDOVER_UNCERTAIN');
 end if;
 update public.claim_leases set lease_status='RELEASED',closed_at=clock_timestamp(),
  release_reason=p_reason where lease_id=v_le.lease_id and lease_status in ('ACTIVE','EXPIRED');
 update public.donation_claims set claim_status='RELEASED',closed_at=clock_timestamp(),
  close_reason=p_reason where claim_id=p_claim and claim_status in ('ACTIVE','EXPIRED');
 update public.pickup_tasks set task_status='STALE' where claim_id=p_claim;
 if v_l.listing_status='CLAIMED' and (v_l.listing_expires_at is null
    or v_l.listing_expires_at>clock_timestamp()) then
  update public.listings set listing_status='AVAILABLE',listing_version=listing_version+1
   where listing_id=v_l.listing_id;
 else
  update public.listings set listing_status='CLOSED' where listing_id=v_l.listing_id
   and listing_status='CLAIMED';
 end if;
 insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,
  donation_id,listing_id,claim_id,lease_id,request_id,transaction_id,previous_state,
  requested_state,resulting_state,reason_code,outcome)
 values(v_actor,'NGO','CLAIM',p_claim,'SAFE_CLAIM_RELEASE',v_l.donation_id,
  v_l.listing_id,p_claim,v_le.lease_id,v_req,pg_current_xact_id()::text,
  v_c.claim_status,'RELEASED','RELEASED',p_reason,'SUCCESS');
 return jsonb_build_object('outcome','SUCCESS','reason_code',p_reason);
end $$;

create or replace function public.cancel_donation(p_donation uuid,p_request uuid)
returns jsonb language plpgsql security definer
set search_path=public,pg_temp as $$
declare v_actor uuid:=auth.uid(); v_d public.donations%rowtype;
 v_listing uuid; v_previous text; v_res uuid;
begin
 if v_actor is null then raise exception 'UNAUTHENTICATED'; end if;
 select * into v_d from public.donations where donation_id=p_donation for update;
 if not found or v_d.donor_user_id<>v_actor then raise exception 'NOT_DONOR_OWNER'; end if;
 v_previous:=v_d.donation_status;
 if v_previous not in ('SUBMITTED','VALIDATED','READY_FOR_PICKUP','HUB_ASSIGNED')
 then raise exception 'CANCELLATION_NOT_PERMITTED'; end if;
 if exists(select 1 from public.hub_receipts where donation_id=p_donation)
  or exists(select 1 from public.hub_batch_members where donation_id=p_donation and membership_status='ACTIVE')
  or exists(select 1 from public.donation_claims c join public.listings l using(listing_id)
    where l.donation_id=p_donation and c.claim_status in ('ACTIVE','RECONCILIATION_REQUIRED'))
 then raise exception 'DONATION_HAS_CUSTODY_OR_ACTIVE_CLAIM'; end if;
 select listing_id into v_listing from public.listings where donation_id=p_donation
 and source_type='DIRECT_DONATION' for update;
 if v_listing is not null and exists(select 1 from public.listings
   where listing_id=v_listing and listing_status='CLAIMED')
 then raise exception 'DONATION_HAS_ACTIVE_CLAIM'; end if;
 update public.donations set donation_status='CANCELLED' where donation_id=p_donation;
 if v_listing is not null then update public.listings set listing_status='CANCELLED',
  listing_version=listing_version+1 where listing_id=v_listing and listing_status='AVAILABLE'; end if;
 update public.hub_reservations set reservation_status='RELEASED'
 where donation_id=p_donation and reservation_status='ACTIVE';
 insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,
  donation_id,listing_id,request_id,transaction_id,previous_state,requested_state,
  resulting_state,reason_code,outcome,configuration_version)
 select v_actor,'DONOR','DONATION',p_donation,'CANCEL_DONATION',p_donation,v_listing,
  p_request,pg_current_xact_id()::text,v_previous,'CANCELLED','CANCELLED','DONOR_REQUEST','SUCCESS',config_version
 from public.coordination_config where singleton;
 return jsonb_build_object('outcome','SUCCESS','donation_id',p_donation);
end $$;

create table if not exists public.delivery_confirmations (
 claim_id uuid primary key references public.donation_claims(claim_id),
 confirmed_by uuid not null references public.ngo_profiles(user_id),
 confirmed_at timestamptz not null default clock_timestamp(),
 confirmation_note text
);
alter table public.delivery_confirmations enable row level security;
revoke all on public.delivery_confirmations from public,anon,authenticated;

create or replace function public.confirm_delivery(p_claim uuid,p_delivery_confirmed boolean)
returns jsonb language plpgsql security definer
set search_path=public,pg_temp as $$
declare v_actor uuid:=auth.uid(); v_c public.donation_claims%rowtype;
 v_l public.listings%rowtype; v_did uuid;
begin
 if v_actor is null then raise exception 'UNAUTHENTICATED'; end if;
 if p_delivery_confirmed is distinct from true then raise exception 'DELIVERY_NOT_CONFIRMED'; end if;
 select * into v_c from public.donation_claims where claim_id=p_claim for update;
 if not found or v_c.ngo_user_id<>v_actor then raise exception 'NOT_CLAIM_OWNER'; end if;
 select * into v_l from public.listings where listing_id=v_c.listing_id for update;
 if v_c.claim_status<>'COMPLETED' then raise exception 'PICKUP_NOT_COMPLETED'; end if;
 if exists(select 1 from public.delivery_confirmations where claim_id=p_claim) then
  return jsonb_build_object('outcome','SUCCESS','replayed',true);
 end if;
 if v_l.source_type='DIRECT_DONATION' then
  update public.donations set donation_status='DELIVERED'
   where donation_id=v_l.donation_id and donation_status='COLLECTED';
  if not found then raise exception 'DONATION_NOT_COLLECTED'; end if;
 else
  for v_did in select donation_id from public.hub_batch_members
    where batch_id=v_l.batch_id and membership_status='ACTIVE' order by donation_id for update
  loop
   update public.donations set donation_status='DELIVERED'
    where donation_id=v_did and donation_status='COLLECTED';
   if not found then raise exception 'BATCH_DONATION_NOT_COLLECTED'; end if;
  end loop;
 end if;
 insert into public.delivery_confirmations(claim_id,confirmed_by)
 values(p_claim,v_actor);
 insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,
  donation_id,listing_id,claim_id,request_id,transaction_id,previous_state,requested_state,
  resulting_state,reason_code,outcome,configuration_version)
 select v_actor,'NGO','CLAIM',p_claim,'CONFIRM_DELIVERY',v_l.donation_id,v_l.listing_id,
  p_claim,v_c.request_id,pg_current_xact_id()::text,'COLLECTED','DELIVERED','DELIVERED',
  'NGO_CONFIRMED','SUCCESS',config_version from public.coordination_config where singleton;
 return jsonb_build_object('outcome','SUCCESS','replayed',false);
end $$;

-- NGO location approval is trusted-admin only; no authenticated user can call it.
create or replace function public.verify_ngo_location(p_ngo uuid,p_verified boolean,
 p_reason text,p_road_node_id text default null)
returns void language plpgsql security definer
set search_path=public,pg_temp as $$
begin
 if auth.role() is distinct from 'service_role' then raise exception 'TRUSTED_VERIFIER_ONLY'; end if;
 if nullif(btrim(p_reason),'') is null then raise exception 'VERIFICATION_REASON_REQUIRED'; end if;
 update public.ngo_profiles set location_verified_at=
  case when p_verified then clock_timestamp() else null end,
  road_node_id=case when p_verified and exists(select 1 from public.road_network_nodes n
   join public.road_network_coverage c using(network_snapshot_id)
   where n.road_node_id=p_road_node_id and n.active_flag and c.active_flag
   and c.dataset_kind='OPERATIONAL' and c.approved_at is not null)
   then p_road_node_id else null end
 where user_id=p_ngo;
 if not found then raise exception 'NGO_NOT_FOUND'; end if;
 insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,
  request_id,transaction_id,requested_state,resulting_state,reason_code,outcome,details)
 values(null,'SYSTEM','NGO',p_ngo,'VERIFY_NGO_LOCATION',gen_random_uuid(),
  pg_current_xact_id()::text,case when p_verified then 'VERIFIED' else 'UNVERIFIED' end,
  case when p_verified then 'VERIFIED' else 'UNVERIFIED' end,p_reason,'SUCCESS',
  jsonb_build_object('road_node_id',case when p_verified then p_road_node_id end));
end $$;

-- Audit data for command exceptions that abort a PostgreSQL transaction cannot
-- be inserted in that same failed transaction. A trusted Edge Function should
-- call this after rollback using service_role and a sanitized request summary.
create table if not exists public.operation_failure_events (
 failure_id uuid primary key default gen_random_uuid(),
 request_id uuid,
 actor_user_id uuid,
 actor_role text,
 operation_name text not null,
 donation_id uuid,
 listing_id uuid,
 claim_id uuid,
 reason_code text not null,
 occurred_at timestamptz not null default clock_timestamp(),
 details jsonb not null default '{}'::jsonb
);
alter table public.operation_failure_events enable row level security;
revoke all on public.operation_failure_events from public,anon,authenticated;
create or replace function public.record_operation_failure(
 p_request uuid,p_actor uuid,p_actor_role text,p_operation text,
 p_donation uuid,p_listing uuid,p_claim uuid,p_reason text,p_details jsonb default '{}'::jsonb
) returns uuid language plpgsql security definer
set search_path=public,pg_temp as $$
declare v_id uuid;
begin
 if auth.role() is distinct from 'service_role' then raise exception 'SERVICE_ROLE_ONLY'; end if;
 insert into public.operation_failure_events(request_id,actor_user_id,actor_role,
  operation_name,donation_id,listing_id,claim_id,reason_code,details)
 values(p_request,p_actor,p_actor_role,p_operation,p_donation,p_listing,p_claim,
  coalesce(p_reason,'TRANSACTION_FAILED'),coalesce(p_details,'{}'::jsonb))
 returning failure_id into v_id;
 return v_id;
end $$;

create or replace function public.get_authorized_audit_events(
 p_entity_type text,p_entity_id uuid
) returns setof public.audit_events language plpgsql stable security definer
set search_path=public,pg_temp as $$
declare v_user uuid:=auth.uid(); v_role text; v_allowed boolean:=false;
begin
 if v_user is null then raise exception 'UNAUTHENTICATED'; end if;
 select role into v_role from public.user_profiles where user_id=v_user;
 if v_role='DONOR' then
  v_allowed:=exists(select 1 from public.donations d where d.donor_user_id=v_user
   and (d.donation_id=p_entity_id or exists(select 1 from public.listings l
    where l.listing_id=p_entity_id and l.donation_id=d.donation_id)));
 elsif v_role='NGO' then
  v_allowed:=exists(select 1 from public.donation_claims c join public.listings l using(listing_id)
   where c.ngo_user_id=v_user and (c.claim_id=p_entity_id or l.listing_id=p_entity_id
    or l.donation_id=p_entity_id));
 elsif v_role='HUB_ADMIN' then
  v_allowed:=exists(select 1 from public.community_hubs h where h.admin_user_id=v_user
   and (h.hub_id=p_entity_id or exists(select 1 from public.hub_reservations r
    where r.hub_id=h.hub_id and r.donation_id=p_entity_id)
    or exists(select 1 from public.hub_inventory i where i.hub_id=h.hub_id
    and i.donation_id=p_entity_id)));
 end if;
 if not v_allowed then raise exception 'AUDIT_NOT_FOUND_OR_FORBIDDEN'; end if;
 return query select a.* from public.audit_events a
 where (a.entity_id=p_entity_id or a.donation_id=p_entity_id or a.listing_id=p_entity_id)
 and (v_role<>'NGO' or a.event_type<>'DONOR_PRIVATE_DATA')
 order by a.occurred_at;
end $$;

-- Allow read/command RPCs only to authenticated users; trusted operations only
-- to service_role. Existing lifecycle grants from the base schema are retained.
revoke all on function public.geolock_app_capabilities() from public,anon;
revoke all on function public.get_my_profile() from public,anon;
revoke all on function public.get_active_donation_categories() from public,anon;
revoke all on function public.resolve_pickup_road_node(double precision,double precision) from public,anon;
revoke all on function public.get_my_donations() from public,anon;
revoke all on function public.get_my_donation_detail(uuid) from public,anon;
revoke all on function public.validate_my_donation_road_node(uuid) from public,anon;
revoke all on function public.get_my_claims() from public,anon;
revoke all on function public.get_claimed_listing_detail(uuid) from public,anon;
revoke all on function public.get_my_hubs() from public,anon;
revoke all on function public.get_my_hub_reservations(uuid) from public,anon;
revoke all on function public.get_my_hub_inventory(uuid) from public,anon;
revoke all on function public.get_my_hub_batches(uuid) from public,anon;
revoke all on function public.get_eligible_hubs(uuid) from public,anon;
revoke all on function public.release_claim(uuid,text) from public,anon;
revoke all on function public.cancel_donation(uuid,uuid) from public,anon;
revoke all on function public.confirm_delivery(uuid,boolean) from public,anon;
revoke all on function public.verify_ngo_location(uuid,boolean,text,text) from public,anon,authenticated;
revoke all on function public.record_operation_failure(uuid,uuid,text,text,uuid,uuid,uuid,text,jsonb) from public,anon,authenticated;
revoke all on function public.get_authorized_audit_events(text,uuid) from public,anon;
revoke all on function public.resolve_claim_reconciliation(uuid,boolean,text) from public,anon,authenticated;
grant execute on function public.geolock_app_capabilities() to authenticated;
grant execute on function public.get_my_profile() to authenticated;
grant execute on function public.get_active_donation_categories() to authenticated;
grant execute on function public.resolve_pickup_road_node(double precision,double precision) to authenticated;
grant execute on function public.get_my_donations() to authenticated;
grant execute on function public.get_my_donation_detail(uuid) to authenticated;
grant execute on function public.validate_my_donation_road_node(uuid) to authenticated;
grant execute on function public.get_my_claims() to authenticated;
grant execute on function public.get_claimed_listing_detail(uuid) to authenticated;
grant execute on function public.get_my_hubs() to authenticated;
grant execute on function public.get_my_hub_reservations(uuid) to authenticated;
grant execute on function public.get_my_hub_inventory(uuid) to authenticated;
grant execute on function public.get_my_hub_batches(uuid) to authenticated;
grant execute on function public.get_eligible_hubs(uuid) to authenticated;
grant execute on function public.release_claim(uuid,text) to authenticated;
grant execute on function public.cancel_donation(uuid,uuid) to authenticated;
grant execute on function public.confirm_delivery(uuid,boolean) to authenticated;
grant execute on function public.verify_ngo_location(uuid,boolean,text,text) to service_role;
grant execute on function public.record_operation_failure(uuid,uuid,text,text,uuid,uuid,uuid,text,jsonb) to service_role;
grant execute on function public.get_authorized_audit_events(text,uuid) to authenticated;
grant execute on function public.resolve_claim_reconciliation(uuid,boolean,text) to service_role;

commit;

-- Deployment preconditions:
-- 1. Populate road_network_nodes only with an independently validated, licensed,
--    operational road graph. Do not import benchmark/dataset/road_nodes.csv here.
-- 2. Deploy a trusted service that verifies NGO addresses and calls
--    verify_ngo_location. Self-selected coordinates remain ineligible otherwise.
-- 3. Add a trusted Edge Function failure logger for errors that roll back.
-- 4. Keep automatic lease renewal disabled; recovery remains service-role only.
