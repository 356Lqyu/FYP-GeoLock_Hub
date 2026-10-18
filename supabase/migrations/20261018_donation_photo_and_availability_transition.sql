-- GeoLock Hub: donor availability retirement and ordered donation photos.
-- Forward-only additive proposal for the deployed V3 schema. Do not run the
-- fresh-install V3 schema or the unresolved Stage 1 migration against a live DB.
-- Depends on 20261017_role_dashboards_and_images.sql for the private bucket,
-- donation_images and hub_batch_images tables, and existing image RPCs.
-- This migration preserves the legacy availability columns and RPC signatures.
-- It does not change claim lease, atomic claim, hub capacity, custody, or routing.

begin;

do $$
begin
  if to_regclass('public.donations') is null
     or to_regclass('public.listings') is null
     or to_regclass('public.donation_images') is null
     or to_regclass('public.hub_batch_images') is null
     or to_regclass('storage.objects') is null then
    raise exception 'Required V3 schema and role_dashboards_and_images migration must be installed first';
  end if;
  if to_regprocedure('public.create_and_validate_donation(text,text,text,double precision,double precision,jsonb,text,timestamp with time zone,timestamp with time zone)') is null
     or to_regprocedure('public.discover_eligible_listings()') is null
     or to_regprocedure('public.claim_listing(uuid,uuid)') is null
     or to_regprocedure('public.get_my_hub_batches_dashboard(uuid)') is null then
    raise exception 'Expected V3 donation RPC signatures are missing; inspect live schema before applying';
  end if;
  if not exists(select 1 from information_schema.columns where table_schema='public' and table_name='donations' and column_name='availability_start')
     or not exists(select 1 from information_schema.columns where table_schema='public' and table_name='donations' and column_name='availability_end') then
    raise exception 'Expected legacy availability columns are missing; inspect live schema before applying';
  end if;
  if exists(select 1 from public.donation_images group by donation_id having count(*)>3) then
    raise exception 'Existing donation has more than three image records; reconcile before adding the photo cap';
  end if;
end $$;

-- Explicit reviewed V3-compatible definitions replace the prior dynamic body
-- substitutions. The signatures, security mode, authorization, geofence,
-- expiry, routing, idempotency, audit, and lease behavior are retained.
-- Legacy donor availability arguments remain accepted but are intentionally
-- ignored; new direct listings have no donor-supplied expiry.
create or replace function public.create_and_validate_donation(
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
 select donation_direct_min_kg into v_threshold from public.coordination_config where singleton;
 if v_threshold is null then raise exception 'DONATION_THRESHOLD_NOT_CONFIGURED'; end if;
 insert into public.donations(donor_user_id,title,description,pickup_address,latitude,longitude,
  pickup_road_node_id,availability_start,availability_end)
 values(v_actor,p_title,p_description,p_pickup_address,p_latitude,p_longitude,
  p_pickup_road_node_id,null,null)
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
      p_pickup_road_node_id,null);
 end if;
 insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,
  previous_state,requested_state,resulting_state,outcome,details,configuration_version)
 select v_actor,'DONOR','DONATION',v_donation,'CREATE_VALIDATE',
   null,'VALIDATED',case when v_path='DIRECT_PICKUP' then 'READY_FOR_PICKUP' else 'VALIDATED' end,
   'SUCCESS',jsonb_build_object('weight_kg',v_weight,'collection_path',v_path),config_version
 from public.coordination_config where singleton;
 return v_donation;
end $$;

create or replace function public.discover_eligible_listings()
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
   and d.donation_status='READY_FOR_PICKUP'))
 or (l.source_type='HUB_BATCH' and exists(
   select 1 from public.hub_batches b where b.batch_id=l.batch_id
   and b.batch_status='PUBLISHED')))
 order by l.created_at desc;
end $$;

create or replace function public.claim_listing(p_listing uuid,p_request uuid)
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
  and d.donation_status='READY_FOR_PICKUP')
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

-- Preserve all existing listing_expires_at values. V3 derived some of these
-- from donor availability_end, but clearing them could resurrect old/expired
-- listings. New direct listings are created with NULL by the wrapper above;
-- existing expiry timestamps remain authoritative until each listing closes.

comment on column public.donations.availability_start is
  'Deprecated compatibility column. Donor-defined availability is not used by current creation, discovery, or claim rules.';
comment on column public.donations.availability_end is
  'Deprecated compatibility column. Donor-defined availability is not used by current creation, discovery, or claim rules.';

-- Ordered photo metadata; existing rows become ordered by creation time and
-- remain intact. Unique order plus the range constraint caps each donation at 3.
alter table public.donation_images add column if not exists display_order smallint;
with ranked as (
  select image_id,row_number() over(partition by donation_id order by is_primary desc,created_at,image_id) as n
  from public.donation_images
)
update public.donation_images i set display_order=r.n::smallint
from ranked r where i.image_id=r.image_id and i.display_order is null;
alter table public.donation_images alter column display_order set not null;
create unique index if not exists ux_donation_images_display_order
  on public.donation_images(donation_id,display_order);
do $$
begin
  if not exists(select 1 from pg_constraint where conrelid='public.donation_images'::regclass and conname='donation_images_order_range') then
    alter table public.donation_images add constraint donation_images_order_range
      check(display_order between 1 and 3) not valid;
  end if;
  if not exists(select 1 from pg_constraint where conrelid='public.donations'::regclass and conname='donations_title_length') then
    alter table public.donations add constraint donations_title_length
      check(char_length(btrim(title)) between 1 and 80) not valid;
  end if;
  if not exists(select 1 from pg_constraint where conrelid='public.donations'::regclass and conname='donations_description_length') then
    alter table public.donations add constraint donations_description_length
      check(description is null or char_length(description)<=1000) not valid;
  end if;
end $$;
update public.donation_images set is_primary=(display_order=1)
where is_primary is distinct from (display_order=1);

create table if not exists public.donation_create_requests (
  request_id uuid primary key,
  donor_user_id uuid not null references auth.users(id),
  request_digest text not null,
  donation_id uuid unique references public.donations(donation_id),
  created_at timestamptz not null default clock_timestamp()
);
alter table public.donation_create_requests enable row level security;
revoke all on public.donation_create_requests from public,anon,authenticated;

-- New Flutter onboarding path: staged objects are verified, the existing V3
-- creation transaction is invoked with NULL legacy dates, and all ordered image
-- rows are inserted before the outer RPC commits. A failure rolls back the
-- donation/listing and image metadata together. The request key makes uncertain
-- responses safe to retry without creating a second donation.
create or replace function public.create_donation_with_images(
  p_request uuid,
  p_title text,
  p_description text,
  p_pickup_address text,
  p_latitude double precision,
  p_longitude double precision,
  p_items jsonb,
  p_pickup_road_node_id text,
  p_images jsonb
) returns uuid
language plpgsql security definer
set search_path=pg_catalog,public,extensions,storage,pg_temp
as $$
declare
  v_actor uuid:=auth.uid();
  v_digest text;
  v_existing public.donation_create_requests%rowtype;
  v_donation uuid;
  v_image jsonb;
  v_order integer:=0;
  v_path text;
  v_type text;
  v_size integer;
  v_ext text;
  v_stored_size bigint;
  v_stored_type text;
  v_role text;
begin
  if v_actor is null then raise exception 'UNAUTHENTICATED'; end if;
  if p_request is null then raise exception 'REQUEST_ID_REQUIRED'; end if;
  if nullif(btrim(p_title),'') is null or char_length(btrim(p_title))>80 then
    raise exception 'INVALID_DONATION_TITLE';
  end if;
  if p_description is not null and char_length(p_description)>1000 then
    raise exception 'DONATION_DESCRIPTION_TOO_LONG';
  end if;
  if jsonb_typeof(p_images) is distinct from 'array'
     or jsonb_array_length(p_images) not between 1 and 3 then
    raise exception 'ONE_TO_THREE_PHOTOS_REQUIRED';
  end if;
  v_digest:=md5(jsonb_build_object(
    'title',btrim(p_title),'description',p_description,'address',p_pickup_address,
    'lat',p_latitude,'lon',p_longitude,'items',p_items,'road_node',p_pickup_road_node_id,
    'images',p_images
  )::text);
  insert into public.donation_create_requests(request_id,donor_user_id,request_digest)
  values(p_request,v_actor,v_digest) on conflict(request_id) do nothing;
  select * into v_existing from public.donation_create_requests
  where request_id=p_request for update;
  if v_existing.donor_user_id<>v_actor or v_existing.request_digest<>v_digest then
    raise exception 'IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD';
  end if;
  if v_existing.donation_id is not null then return v_existing.donation_id; end if;

  for v_image in select value from jsonb_array_elements(p_images) loop
    v_order:=v_order+1;
    v_path:=v_image->>'storage_path';
    v_type:=v_image->>'content_type';
    v_size:=nullif(v_image->>'size_bytes','')::integer;
    v_ext:=lower(split_part(v_path,'.',array_length(string_to_array(v_path,'.'),1)));
    if v_path !~ ('^'||v_actor::text||'/pending/'||p_request::text||'/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}[.](jpg|jpeg|png|webp)$')
       or v_size is null or v_size not between 1 and 5242880
       or v_type not in ('image/jpeg','image/png','image/webp')
       or (v_ext in ('jpg','jpeg') and v_type<>'image/jpeg')
       or (v_ext='png' and v_type<>'image/png')
       or (v_ext='webp' and v_type<>'image/webp') then
      raise exception 'INVALID_DONATION_IMAGE_%',v_order;
    end if;
    select nullif(o.metadata->>'size','')::bigint,o.metadata->>'mimetype'
      into v_stored_size,v_stored_type
    from storage.objects o
    where o.bucket_id='geolock-donation-images' and o.name=v_path;
    if not found or v_stored_size is null or v_stored_size<>v_size
       or v_stored_type<>v_type then
      raise exception 'STAGED_DONATION_IMAGE_MISSING_OR_MISMATCHED_%',v_order;
    end if;
  end loop;

  v_donation:=public.create_and_validate_donation(
    p_title,p_description,p_pickup_address,p_latitude,p_longitude,
    p_items,p_pickup_road_node_id,null,null
  );
  v_order:=0;
  for v_image in select value from jsonb_array_elements(p_images) loop
    v_order:=v_order+1;
    insert into public.donation_images(
      donation_id,owner_user_id,storage_path,content_type,size_bytes,is_primary,display_order
    ) values(
      v_donation,v_actor,v_image->>'storage_path',v_image->>'content_type',
      (v_image->>'size_bytes')::integer,v_order=1,v_order::smallint
    );
  end loop;
  update public.donation_create_requests set donation_id=v_donation
  where request_id=p_request;
  select role into v_role from public.user_profiles where user_id=v_actor;
  insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,
    requested_state,resulting_state,outcome,details,configuration_version)
  values(v_actor,v_role,'DONATION',v_donation,'DONATION_PHOTOS_ATTACHED',
    'ONE_TO_THREE_PHOTOS','ONE_TO_THREE_PHOTOS','SUCCESS',
    jsonb_build_object('request_id',p_request,'photo_count',v_order),
    (select config_version from public.coordination_config where singleton));
  return v_donation;
end;
$$;

-- Legacy image RPC keeps its signature. It serializes per-donation appends,
-- caps the count, and orders covers; it never overwrites or reorders photos.
create or replace function public.add_donation_image(
  p_donation uuid,p_storage_path text,p_content_type text,p_size_bytes integer
) returns uuid language plpgsql security definer
set search_path=pg_catalog,public,pg_temp
as $$
declare
  v_actor uuid:=auth.uid();
  v_d public.donations%rowtype;
  v_count integer;
  v_order smallint;
  v_image uuid;
  v_role text;
  v_actual_size bigint;
  v_actual_type text;
  v_ext text;
begin
  if v_actor is null then raise exception 'UNAUTHENTICATED'; end if;
  select * into v_d from public.donations where donation_id=p_donation for update;
  if not found or v_d.donor_user_id<>v_actor then raise exception 'DONATION_NOT_FOUND_OR_FORBIDDEN'; end if;
  -- Adding an image does not mutate structured donation items or operational
  -- state. This compatibility RPC may append photos to older records; it cannot
  -- overwrite, reorder, or remove the existing cover.
  select count(*) into v_count from public.donation_images where donation_id=p_donation;
  if v_count>=3 then raise exception 'MAXIMUM_THREE_DONATION_PHOTOS'; end if;
  v_ext:=lower(split_part(p_storage_path,'.',array_length(string_to_array(p_storage_path,'.'),1)));
  if p_storage_path !~ ('^'||v_actor::text||'/'||p_donation::text||'/[0-9a-fA-F-]{36}[.](jpg|jpeg|png|webp)$')
     or p_content_type not in ('image/jpeg','image/png','image/webp')
     or p_size_bytes is null or p_size_bytes not between 1 and 5242880
     or (v_ext in ('jpg','jpeg') and p_content_type<>'image/jpeg')
     or (v_ext='png' and p_content_type<>'image/png')
     or (v_ext='webp' and p_content_type<>'image/webp') then raise exception 'INVALID_IMAGE_METADATA'; end if;
  select nullif(o.metadata->>'size','')::bigint,o.metadata->>'mimetype'
    into v_actual_size,v_actual_type from storage.objects o
    where o.bucket_id='geolock-donation-images' and o.name=p_storage_path;
  if not found or v_actual_size is distinct from p_size_bytes::bigint
     or v_actual_type is distinct from p_content_type then
    raise exception 'STORED_IMAGE_MISSING_OR_MISMATCHED';
  end if;
  v_order:=(v_count+1)::smallint;
  insert into public.donation_images(donation_id,owner_user_id,storage_path,content_type,size_bytes,is_primary,display_order)
  values(p_donation,v_actor,p_storage_path,p_content_type,p_size_bytes,v_order=1,v_order)
  returning image_id into v_image;
  select role into v_role from public.user_profiles where user_id=v_actor;
  insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,
    requested_state,resulting_state,outcome,details,configuration_version)
  values(v_actor,v_role,'DONATION',p_donation,'DONATION_IMAGE_ADDED','IMAGE_ATTACHED','IMAGE_ATTACHED','SUCCESS',
    jsonb_build_object('image_id',v_image,'display_order',v_order),
    (select config_version from public.coordination_config where singleton));
  return v_image;
end;
$$;

-- Before the operational road graph has been approved, available-listing photos
-- are not exposed to NGOs. Owners, authorized hub admins, and NGOs with a live
-- claim (or a completed/reconciliation claim) can read their associated image.
create or replace function public.can_read_geolock_donation_image(p_path text)
returns boolean language sql volatile security definer
set search_path=pg_catalog,public,extensions,pg_temp
as $$
  select auth.uid() is not null and exists(
    select 1 from public.donation_images i
    join public.donations d using(donation_id)
    where i.storage_path=p_path and (
      d.donor_user_id=auth.uid()
      or exists(
        select 1 from public.ngo_profiles n
        join public.coordination_config cfg on cfg.singleton
        join public.listings l on l.donation_id=d.donation_id and l.source_type='DIRECT_DONATION'
        where n.user_id=auth.uid() and n.active_flag and n.location_verified_at is not null
          and exists(select 1 from public.donation_claims c
                left join public.claim_leases le using(claim_id)
                where c.listing_id=l.listing_id and c.ngo_user_id=auth.uid()
                  and (c.claim_status in ('COMPLETED','RECONCILIATION_REQUIRED')
                       or (c.claim_status='ACTIVE' and le.lease_status='ACTIVE' and le.expires_at>clock_timestamp())))
          and extensions.ST_DWithin(
            extensions.ST_SetSRID(extensions.ST_MakePoint(n.longitude,n.latitude),4326)::extensions.geography,
            extensions.ST_SetSRID(extensions.ST_MakePoint(l.pickup_longitude,l.pickup_latitude),4326)::extensions.geography,
            cfg.geofence_radius_m)
      )
      or exists(
        select 1 from public.ngo_profiles n
        join public.coordination_config cfg on cfg.singleton
        join public.hub_batch_members m on m.donation_id=d.donation_id and m.membership_status='ACTIVE'
        join public.listings l on l.batch_id=m.batch_id and l.source_type='HUB_BATCH'
        join public.hub_batches b on b.batch_id=m.batch_id and b.batch_status='PUBLISHED'
        where n.user_id=auth.uid() and n.active_flag and n.location_verified_at is not null
          and exists(select 1 from public.donation_claims c
                left join public.claim_leases le using(claim_id)
                where c.listing_id=l.listing_id and c.ngo_user_id=auth.uid()
                  and (c.claim_status in ('COMPLETED','RECONCILIATION_REQUIRED')
                       or (c.claim_status='ACTIVE' and le.lease_status='ACTIVE' and le.expires_at>clock_timestamp())))
          and extensions.ST_DWithin(
            extensions.ST_SetSRID(extensions.ST_MakePoint(n.longitude,n.latitude),4326)::extensions.geography,
            extensions.ST_SetSRID(extensions.ST_MakePoint(l.pickup_longitude,l.pickup_latitude),4326)::extensions.geography,
            cfg.geofence_radius_m)
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
returns boolean language sql volatile security definer
set search_path=pg_catalog,public,extensions,pg_temp
as $$
  select auth.uid() is not null and exists(
    select 1 from public.hub_batch_images i
    join public.hub_batches b using(batch_id)
    where i.storage_path=p_path and (
      exists(select 1 from public.community_hubs h where h.hub_id=b.hub_id and h.admin_user_id=auth.uid())
      or exists(
        select 1 from public.ngo_profiles n
        join public.coordination_config cfg on cfg.singleton
        join public.listings l on l.batch_id=b.batch_id and l.source_type='HUB_BATCH'
        where n.user_id=auth.uid() and n.active_flag and n.location_verified_at is not null
          and exists(select 1 from public.donation_claims c left join public.claim_leases le using(claim_id)
                where c.listing_id=l.listing_id and c.ngo_user_id=auth.uid()
                  and (c.claim_status in ('COMPLETED','RECONCILIATION_REQUIRED')
                       or (c.claim_status='ACTIVE' and le.lease_status='ACTIVE' and le.expires_at>clock_timestamp())))
          and extensions.ST_DWithin(
            extensions.ST_SetSRID(extensions.ST_MakePoint(n.longitude,n.latitude),4326)::extensions.geography,
            extensions.ST_SetSRID(extensions.ST_MakePoint(l.pickup_longitude,l.pickup_latitude),4326)::extensions.geography,
            cfg.geofence_radius_m)
      )
    )
  );
$$;

create or replace function public.get_donation_images(p_donation uuid)
returns table(image_id uuid,storage_path text,display_order smallint,is_cover boolean,content_type text)
language plpgsql volatile security definer
set search_path=pg_catalog,public,pg_temp
as $$
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  if not exists(select 1 from public.donation_images i
    where i.donation_id=p_donation and public.can_read_geolock_donation_image(i.storage_path)) then
    raise exception 'DONATION_IMAGES_NOT_FOUND_OR_FORBIDDEN';
  end if;
  return query select i.image_id,i.storage_path,i.display_order,i.display_order=1,i.content_type
  from public.donation_images i where i.donation_id=p_donation order by i.display_order;
end;
$$;

create or replace function public.get_batch_images(p_batch uuid)
returns table(image_id uuid,storage_path text,is_cover boolean,content_type text)
language plpgsql volatile security definer
set search_path=pg_catalog,public,pg_temp
as $$
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  if not exists(select 1 from public.hub_batch_images i
    where i.batch_id=p_batch and public.can_read_geolock_batch_image(i.storage_path)) then
    raise exception 'BATCH_IMAGES_NOT_FOUND_OR_FORBIDDEN';
  end if;
  return query select i.image_id,i.storage_path,i.is_primary,i.content_type
  from public.hub_batch_images i where i.batch_id=p_batch order by i.created_at,i.image_id;
end;
$$;

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
  join public.coordination_config cfg on cfg.singleton
  where l.listing_id=p_listing and l.listing_status='AVAILABLE'
    and (l.listing_expires_at is null or l.listing_expires_at>clock_timestamp())
    and extensions.ST_DWithin(
      extensions.ST_SetSRID(extensions.ST_MakePoint(v_ngo.longitude,v_ngo.latitude),4326)::extensions.geography,
      extensions.ST_SetSRID(extensions.ST_MakePoint(l.pickup_longitude,l.pickup_latitude),4326)::extensions.geography,
      cfg.geofence_radius_m)
    and ((l.source_type='DIRECT_DONATION' and exists(select 1 from public.donations d
      where d.donation_id=l.donation_id and d.donation_status='READY_FOR_PICKUP'))
      or (l.source_type='HUB_BATCH' and exists(select 1 from public.hub_batches b
        where b.batch_id=l.batch_id and b.batch_status='PUBLISHED')));
  if not found then raise exception 'LISTING_NOT_ELIGIBLE'; end if;
  return query
  -- Listing photos remain withheld until an approved graph can establish that
  -- discovery eligibility includes trusted road-node validation.
  select d.donation_id,d.title,d.total_weight_kg,d.donation_status,null::text
  from public.donations d
  left join lateral(select x.storage_path from public.donation_images x
    where x.donation_id=d.donation_id and x.display_order=1 limit 1) i on true
  where (v_listing.source_type='DIRECT_DONATION' and d.donation_id=v_listing.donation_id)
     or (v_listing.source_type='HUB_BATCH' and exists(select 1 from public.hub_batch_members m
       where m.batch_id=v_listing.batch_id and m.donation_id=d.donation_id and m.membership_status='ACTIVE'))
  order by d.created_at,d.donation_id;
end;
$$;

create or replace function public.get_hub_donation_covers(p_hub uuid)
returns table(donation_id uuid,primary_image_path text)
language plpgsql volatile security definer
set search_path=pg_catalog,public,pg_temp
as $$
begin
  if auth.uid() is null or not exists(select 1 from public.community_hubs h
    where h.hub_id=p_hub and h.admin_user_id=auth.uid()) then
    raise exception 'HUB_NOT_FOUND_OR_FORBIDDEN';
  end if;
  return query select distinct d.donation_id,i.storage_path
  from public.donations d
  join public.donation_images i on i.donation_id=d.donation_id and i.display_order=1
  where exists(select 1 from public.hub_reservations r where r.donation_id=d.donation_id and r.hub_id=p_hub
                 and r.reservation_status='ACTIVE' and r.expires_at>clock_timestamp())
     or exists(select 1 from public.hub_inventory hi where hi.donation_id=d.donation_id and hi.hub_id=p_hub);
end;
$$;

-- New eligible-listing card read exposes no donor name/address/coordinate.
-- A present road-node ID is still UNVERIFIED without approved graph coverage.
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
  select * into v_ngo from public.ngo_profiles where user_id=auth.uid() and active_flag;
  if not found or v_ngo.location_verified_at is null then return; end if;
  return query
  select l.listing_id,l.source_type,
    case when l.source_type='DIRECT_DONATION' then d.title else 'Community Hub Batch' end,
    l.listing_weight_kg,l.created_at,
    case when l.source_type='DIRECT_DONATION' then d.collection_path else 'HUB_COLLECTION' end,
    extensions.ST_Distance(
      extensions.ST_SetSRID(extensions.ST_MakePoint(v_ngo.longitude,v_ngo.latitude),4326)::extensions.geography,
      extensions.ST_SetSRID(extensions.ST_MakePoint(l.pickup_longitude,l.pickup_latitude),4326)::extensions.geography),
    case when l.pickup_road_node_id is null then 'PENDING_NODE' else 'UNVERIFIED' end,
    null::text,l.batch_id,l.donation_id
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
    and extensions.ST_DWithin(
      extensions.ST_SetSRID(extensions.ST_MakePoint(v_ngo.longitude,v_ngo.latitude),4326)::extensions.geography,
      extensions.ST_SetSRID(extensions.ST_MakePoint(l.pickup_longitude,l.pickup_latitude),4326)::extensions.geography,
      cfg.geofence_radius_m)
    and ((l.source_type='DIRECT_DONATION' and d.donation_status='READY_FOR_PICKUP')
      or (l.source_type='HUB_BATCH' and b.batch_status='PUBLISHED'))
  order by l.created_at desc;
end;
$$;

create or replace function public.get_my_claim_cards()
returns table(claim_id uuid,listing_id uuid,claim_status text,claimed_at timestamptz,
  lease_id uuid,lease_status text,lease_expires_at timestamptz,task_status text,
  source_type text,listing_weight_kg numeric,title text,primary_image_path text)
language plpgsql volatile security definer
set search_path=pg_catalog,public,pg_temp
as $$
begin
  if auth.uid() is null or not exists(select 1 from public.ngo_profiles
    where user_id=auth.uid() and active_flag) then raise exception 'ACTIVE_NGO_ONLY'; end if;
  return query
  select c.claim_id,c.listing_id,c.claim_status,c.claimed_at,le.lease_id,le.lease_status,
    le.expires_at,pt.task_status,l.source_type,l.listing_weight_kg,
    case when l.source_type='DIRECT_DONATION' then d.title else 'Community Hub Batch' end,
    case when di.storage_path is not null and public.can_read_geolock_donation_image(di.storage_path)
      then di.storage_path
      when bi.storage_path is not null and public.can_read_geolock_batch_image(bi.storage_path)
      then bi.storage_path
      when member_img.storage_path is not null and public.can_read_geolock_donation_image(member_img.storage_path)
      then member_img.storage_path end
  from public.donation_claims c join public.listings l using(listing_id)
  left join public.donations d on d.donation_id=l.donation_id
  left join public.hub_batches b on b.batch_id=l.batch_id
  left join public.claim_leases le using(claim_id)
  left join public.pickup_tasks pt using(claim_id)
  left join lateral(select i.storage_path from public.donation_images i
    where i.donation_id=d.donation_id and i.display_order=1 limit 1) di on true
  left join lateral(select i.storage_path from public.hub_batch_images i
    where i.batch_id=b.batch_id and i.is_primary limit 1) bi on true
  left join lateral(select i.storage_path from public.hub_batch_members m
    join public.donation_images i on i.donation_id=m.donation_id and i.display_order=1
    join public.donations md on md.donation_id=m.donation_id
    where m.batch_id=b.batch_id and m.membership_status='ACTIVE'
    order by md.created_at,md.donation_id limit 1) member_img on true
  where c.ngo_user_id=auth.uid() order by c.claimed_at desc;
end;
$$;

create or replace function public.get_claimed_listing_constituents(p_claim uuid)
returns table(donation_id uuid,title text,total_weight_kg numeric,donation_status text,
  primary_image_path text,batch_cover_path text)
language plpgsql volatile security definer
set search_path=pg_catalog,public,pg_temp
as $$
declare v_listing public.listings%rowtype;
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  select l.* into v_listing from public.donation_claims c
  join public.listings l using(listing_id)
  where c.claim_id=p_claim and c.ngo_user_id=auth.uid()
    and (c.claim_status in ('COMPLETED','RECONCILIATION_REQUIRED')
      or (c.claim_status='ACTIVE' and exists(select 1 from public.claim_leases le
          where le.claim_id=c.claim_id and le.lease_status='ACTIVE'
            and le.expires_at>clock_timestamp())));
  if not found then raise exception 'CLAIM_NOT_FOUND_OR_FORBIDDEN'; end if;
  return query
  select d.donation_id,d.title,d.total_weight_kg,d.donation_status,di.storage_path,bi.storage_path
  from public.donations d
  left join lateral(select i.storage_path from public.donation_images i
    where i.donation_id=d.donation_id and i.display_order=1 limit 1) di on true
  left join lateral(select i.storage_path from public.hub_batch_images i
    where i.batch_id=v_listing.batch_id and i.is_primary limit 1) bi on true
  where (v_listing.source_type='DIRECT_DONATION' and d.donation_id=v_listing.donation_id)
     or (v_listing.source_type='HUB_BATCH' and exists(
       select 1 from public.hub_batch_members m where m.batch_id=v_listing.batch_id
         and m.donation_id=d.donation_id and m.membership_status='ACTIVE'))
  order by d.created_at,d.donation_id;
end;
$$;

create or replace function public.get_hub_batch_details(p_hub uuid,p_batch uuid)
returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,pg_temp
as $$
declare v_result jsonb;
begin
  if auth.uid() is null or not exists(select 1 from public.community_hubs
    where hub_id=p_hub and admin_user_id=auth.uid()) then raise exception 'HUB_NOT_FOUND_OR_FORBIDDEN'; end if;
  select jsonb_build_object(
    'batch_id',b.batch_id,'batch_status',b.batch_status,'batch_weight_kg',b.batch_weight_kg,
    'batch_cover_path',coalesce(bi.storage_path,member_img.storage_path),
    'donations',coalesce((select jsonb_agg(jsonb_build_object(
      'donation_id',d.donation_id,'title',d.title,'weight_kg',d.total_weight_kg,
      'donation_status',d.donation_status,'primary_image_path',di.storage_path)
      order by d.created_at,d.donation_id)
      from public.hub_batch_members m join public.donations d using(donation_id)
      left join lateral(select i.storage_path from public.donation_images i
        where i.donation_id=d.donation_id and i.display_order=1 limit 1) di on true
      where m.batch_id=b.batch_id and m.membership_status='ACTIVE'),'[]'::jsonb)
  ) into v_result
  from public.hub_batches b
  left join lateral(select i.storage_path from public.hub_batch_images i
    where i.batch_id=b.batch_id and i.is_primary limit 1) bi on true
  left join lateral(select i.storage_path from public.hub_batch_members m
    join public.donations d using(donation_id)
    join public.donation_images i on i.donation_id=d.donation_id and i.display_order=1
    where m.batch_id=b.batch_id and m.membership_status='ACTIVE'
    order by d.created_at,d.donation_id limit 1) member_img on true
  where b.hub_id=p_hub and b.batch_id=p_batch;
  if v_result is null then raise exception 'BATCH_NOT_FOUND_OR_FORBIDDEN'; end if;
  return v_result;
end;
$$;

-- Keep the existing batch-dashboard return type. Prefer a true batch photo;
-- fallback to the first constituent donation cover is only a thumbnail choice.
create or replace function public.get_my_hub_batches_dashboard(p_hub uuid)
returns table(batch_id uuid,batch_status text,batch_weight_kg numeric,
  batch_donation_count integer,category_name text,published_at timestamptz,
  primary_image_path text)
language plpgsql stable security definer
set search_path=pg_catalog,public,pg_temp
as $$
begin
  if auth.uid() is null or not exists(select 1 from public.community_hubs
    where hub_id=p_hub and admin_user_id=auth.uid()) then raise exception 'HUB_NOT_FOUND_OR_FORBIDDEN'; end if;
  return query
  select b.batch_id,b.batch_status,b.batch_weight_kg,b.batch_donation_count,c.category_name,
    b.published_at,coalesce(bi.storage_path,member_img.storage_path)
  from public.hub_batches b
  left join public.donation_categories c on c.category_id=b.batch_category_id
  left join lateral(select i.storage_path from public.hub_batch_images i
    where i.batch_id=b.batch_id and i.is_primary limit 1) bi on true
  left join lateral(select i.storage_path from public.hub_batch_members m
    join public.donations d using(donation_id)
    join public.donation_images i on i.donation_id=d.donation_id and i.display_order=1
    where m.batch_id=b.batch_id and m.membership_status='ACTIVE'
    order by d.created_at,d.donation_id limit 1) member_img on true
  where b.hub_id=p_hub and b.batch_status<>'DRAFT' order by b.created_at desc;
end;
$$;

-- A batch has one optional photo of the physical assembly. Constituent donor
-- photos remain in donation_images and are never copied into this table.
create or replace function public.add_hub_batch_image(
  p_batch uuid,p_storage_path text,p_content_type text,p_size_bytes integer
) returns uuid language plpgsql security definer
set search_path=pg_catalog,public,pg_temp
as $$
declare v_actor uuid:=auth.uid();v_image uuid;v_role text;v_ext text;v_actual_size bigint;v_actual_type text;
begin
  if v_actor is null then raise exception 'UNAUTHENTICATED'; end if;
  if p_size_bytes is null or p_size_bytes not between 1 and 5242880
     or p_content_type not in ('image/jpeg','image/png','image/webp') then
    raise exception 'INVALID_IMAGE_METADATA';
  end if;
  v_ext:=lower(split_part(p_storage_path,'.',array_length(string_to_array(p_storage_path,'.'),1)));
  if p_storage_path !~ ('^'||v_actor::text||'/batches/'||p_batch::text||'/[0-9a-fA-F-]{36}[.](jpg|jpeg|png|webp)$')
     or (v_ext in ('jpg','jpeg') and p_content_type<>'image/jpeg')
     or (v_ext='png' and p_content_type<>'image/png')
     or (v_ext='webp' and p_content_type<>'image/webp') then
    raise exception 'INVALID_IMAGE_PATH';
  end if;
  select nullif(o.metadata->>'size','')::bigint,o.metadata->>'mimetype'
    into v_actual_size,v_actual_type from storage.objects o
    where o.bucket_id='geolock-donation-images' and o.name=p_storage_path;
  if not found or v_actual_size is distinct from p_size_bytes::bigint
     or v_actual_type is distinct from p_content_type then
    raise exception 'STORED_IMAGE_MISSING_OR_MISMATCHED';
  end if;
  if not exists(select 1 from public.hub_batches b join public.community_hubs h using(hub_id)
      where b.batch_id=p_batch and h.admin_user_id=v_actor) then
    raise exception 'BATCH_NOT_FOUND_OR_FORBIDDEN';
  end if;
  if exists(select 1 from public.hub_batch_images where batch_id=p_batch) then
    raise exception 'BATCH_PHOTO_ALREADY_SET';
  end if;
  insert into public.hub_batch_images(batch_id,owner_user_id,storage_path,content_type,size_bytes,is_primary)
  values(p_batch,v_actor,p_storage_path,p_content_type,p_size_bytes,true)
  returning image_id into v_image;
  select role into v_role from public.user_profiles where user_id=v_actor;
  insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,
    requested_state,resulting_state,outcome,details,configuration_version)
  values(v_actor,v_role,'BATCH',p_batch,'BATCH_IMAGE_ADDED','IMAGE_ATTACHED','IMAGE_ATTACHED','SUCCESS',
    jsonb_build_object('image_id',v_image,'content_type',p_content_type,'size_bytes',p_size_bytes),
    (select config_version from public.coordination_config where singleton));
  return v_image;
end;
$$;

-- Staged uploads are visible only to their owner. A signed URL for a committed
-- image is checked by the secure helper policies below. No public bucket access.
drop policy if exists geolock_donation_image_owner_insert on storage.objects;
create policy geolock_donation_image_owner_insert on storage.objects
for insert to authenticated with check (
  bucket_id='geolock-donation-images'
  and metadata->>'mimetype' in ('image/jpeg','image/png','image/webp')
  and case when coalesce(metadata->>'size','') ~ '^[0-9]+$'
      then (metadata->>'size')::bigint between 1 and 5242880 else false end
  and (storage.foldername(name))[1]=auth.uid()::text
  and (
    ((storage.foldername(name))[2]='pending'
      and name ~ ('^'||auth.uid()::text||'/pending/[0-9a-f-]{36}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}[.](jpg|jpeg|png|webp)$'))
    or
    (name ~ ('^'||auth.uid()::text||'/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-fA-F-]{36}[.](jpg|jpeg|png|webp)$')
      and exists(select 1 from public.donations d where d.donation_id::text=(storage.foldername(name))[2] and d.donor_user_id=auth.uid()))
  )
);
drop policy if exists geolock_donation_image_owner_select on storage.objects;
create policy geolock_donation_image_owner_select on storage.objects
for select to authenticated using (
  bucket_id='geolock-donation-images'
  and ((storage.foldername(name))[1]=auth.uid()::text and (storage.foldername(name))[2]='pending'
       or public.can_read_geolock_donation_image(name))
);
drop policy if exists geolock_batch_image_owner_select on storage.objects;
create policy geolock_batch_image_owner_select on storage.objects
for select to authenticated using (
  bucket_id='geolock-donation-images'
  and (public.can_read_geolock_batch_image(name) or public.can_read_geolock_donation_image(name))
);

drop policy if exists geolock_donation_image_owner_delete on storage.objects;
drop policy if exists geolock_pending_donation_image_delete on storage.objects;
drop policy if exists geolock_unattached_donation_image_delete on storage.objects;
create policy geolock_unattached_donation_image_delete on storage.objects
for delete to authenticated using (
  bucket_id='geolock-donation-images'
  and (storage.foldername(name))[1]=auth.uid()::text
  and not exists(select 1 from public.donation_images i where i.storage_path=name)
  and (
    (storage.foldername(name))[2]='pending'
    or exists(select 1 from public.donations d
      where d.donation_id::text=(storage.foldername(name))[2] and d.donor_user_id=auth.uid())
  )
);
drop policy if exists geolock_batch_image_owner_delete on storage.objects;
drop policy if exists geolock_unattached_batch_image_delete on storage.objects;
create policy geolock_unattached_batch_image_delete on storage.objects
for delete to authenticated using (
  bucket_id='geolock-donation-images'
  and (storage.foldername(name))[1]=auth.uid()::text
  and (storage.foldername(name))[2]='batches'
  and not exists(select 1 from public.hub_batch_images i where i.storage_path=name)
  and exists(select 1 from public.hub_batches b
    join public.community_hubs h using(hub_id)
    where b.batch_id::text=(storage.foldername(name))[3] and h.admin_user_id=auth.uid())
);

revoke all on function public.create_donation_with_images(uuid,text,text,text,double precision,double precision,jsonb,text,jsonb) from public,anon;
revoke all on function public.add_donation_image(uuid,text,text,integer) from public,anon;
revoke all on function public.add_hub_batch_image(uuid,text,text,integer) from public,anon;
revoke all on function public.can_read_geolock_donation_image(text) from public,anon;
revoke all on function public.can_read_geolock_batch_image(text) from public,anon;
revoke all on function public.get_donation_images(uuid) from public,anon;
revoke all on function public.get_batch_images(uuid) from public,anon;
revoke all on function public.get_eligible_listing_constituents(uuid) from public,anon;
revoke all on function public.get_hub_donation_covers(uuid) from public,anon;
revoke all on function public.discover_eligible_listing_cards() from public,anon;
revoke all on function public.get_my_claim_cards() from public,anon;
revoke all on function public.get_claimed_listing_constituents(uuid) from public,anon;
revoke all on function public.get_hub_batch_details(uuid,uuid) from public,anon;
revoke all on function public.get_my_hub_batches_dashboard(uuid) from public,anon;
grant execute on function public.create_donation_with_images(uuid,text,text,text,double precision,double precision,jsonb,text,jsonb) to authenticated;
grant execute on function public.add_donation_image(uuid,text,text,integer) to authenticated;
grant execute on function public.add_hub_batch_image(uuid,text,text,integer) to authenticated;
grant execute on function public.can_read_geolock_donation_image(text) to authenticated;
grant execute on function public.can_read_geolock_batch_image(text) to authenticated;
grant execute on function public.get_donation_images(uuid) to authenticated;
grant execute on function public.get_batch_images(uuid) to authenticated;
grant execute on function public.get_eligible_listing_constituents(uuid) to authenticated;
grant execute on function public.get_hub_donation_covers(uuid) to authenticated;
grant execute on function public.discover_eligible_listing_cards() to authenticated;
grant execute on function public.get_my_claim_cards() to authenticated;
grant execute on function public.get_claimed_listing_constituents(uuid) to authenticated;
grant execute on function public.get_hub_batch_details(uuid,uuid) to authenticated;
grant execute on function public.get_my_hub_batches_dashboard(uuid) to authenticated;

notify pgrst,'reload schema';
commit;

-- Stage 2 photo enforcement is intentionally separate so old clients can be
-- upgraded without interruption. After every client uses create_donation_with_images,
-- apply 20261018_enforce_required_donation_photos.sql. Historical rows are exempt.
-- Availability columns are retained for compatibility; drop them only after all
-- deployed RPCs/views no longer reference them and a dependency scan is clean.
