-- GeoLock Hub role dashboard reads and donor photo metadata.
-- Additive proposal for the installed V3_10kg_360min schema only.
-- Review and run manually in a development project before any production use.
-- No donation, listing, claim, custody, or hub state is changed here.

begin;

create table if not exists public.donation_images (
  image_id uuid primary key default gen_random_uuid(),
  donation_id uuid not null references public.donations(donation_id) on delete cascade,
  owner_user_id uuid not null references auth.users(id),
  storage_path text not null unique,
  content_type text not null check (content_type in ('image/jpeg','image/png','image/webp')),
  size_bytes integer not null check (size_bytes between 1 and 5242880),
  is_primary boolean not null default false,
  created_at timestamptz not null default clock_timestamp()
);
create index if not exists idx_donation_images_owner_donation
  on public.donation_images(owner_user_id, donation_id, created_at);
create unique index if not exists ux_donation_images_primary
  on public.donation_images(donation_id) where is_primary;
alter table public.donation_images enable row level security;
revoke all on public.donation_images from public, anon, authenticated;
grant select on public.donation_images to authenticated;
drop policy if exists donation_images_owner_read on public.donation_images;
create policy donation_images_owner_read on public.donation_images
for select to authenticated
using (
  owner_user_id=auth.uid()
  and exists (
    select 1 from public.donations d
    where d.donation_id=donation_images.donation_id
      and d.donor_user_id=auth.uid()
  )
);

create table if not exists public.hub_batch_images (
  image_id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references public.hub_batches(batch_id) on delete cascade,
  owner_user_id uuid not null references auth.users(id),
  storage_path text not null unique,
  content_type text not null check (content_type in ('image/jpeg','image/png','image/webp')),
  size_bytes integer not null check (size_bytes between 1 and 5242880),
  is_primary boolean not null default false,
  created_at timestamptz not null default clock_timestamp()
);
create unique index if not exists ux_hub_batch_images_primary
  on public.hub_batch_images(batch_id) where is_primary;
alter table public.hub_batch_images enable row level security;
revoke all on public.hub_batch_images from public,anon,authenticated;
grant select on public.hub_batch_images to authenticated;
drop policy if exists hub_batch_images_owner_read on public.hub_batch_images;
create policy hub_batch_images_owner_read on public.hub_batch_images
for select to authenticated
using (
  owner_user_id=auth.uid()
  and exists (
    select 1 from public.hub_batches b
    join public.community_hubs h using(hub_id)
    where b.batch_id=hub_batch_images.batch_id and h.admin_user_id=auth.uid()
  )
);

-- Keep the image bucket private. Refuse to silently repurpose a public bucket.
do $$
begin
  if exists (
    select 1 from storage.buckets
    where id='geolock-donation-images'
      and (public
        or file_size_limit is distinct from 5242880
        or allowed_mime_types is distinct from array['image/jpeg','image/png','image/webp']::text[])
  ) then
    raise exception 'geolock-donation-images exists with incompatible visibility or upload limits';
  end if;
  insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
  values ('geolock-donation-images','geolock-donation-images',false,5242880,
    array['image/jpeg','image/png','image/webp'])
  on conflict (id) do nothing;
end $$;

drop policy if exists geolock_donation_image_owner_insert on storage.objects;
create policy geolock_donation_image_owner_insert on storage.objects
for insert to authenticated
with check (
  bucket_id='geolock-donation-images'
  and metadata->>'mimetype' in ('image/jpeg','image/png','image/webp')
  and case when coalesce(metadata->>'size','') ~ '^[0-9]+$'
    then (metadata->>'size')::bigint between 1 and 5242880 else false end
  and (storage.foldername(name))[1]=auth.uid()::text
  and name ~ ('^'||auth.uid()::text||'/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}[.](jpg|jpeg|png|webp)$')
  and exists (
    select 1 from public.donations d
    where d.donation_id::text=(storage.foldername(name))[2]
      and d.donor_user_id=auth.uid()
  )
);

drop policy if exists geolock_batch_image_owner_insert on storage.objects;
create policy geolock_batch_image_owner_insert on storage.objects
for insert to authenticated
with check (
  bucket_id='geolock-donation-images'
  and metadata->>'mimetype' in ('image/jpeg','image/png','image/webp')
  and case when coalesce(metadata->>'size','') ~ '^[0-9]+$'
    then (metadata->>'size')::bigint between 1 and 5242880 else false end
  and (storage.foldername(name))[1]=auth.uid()::text
  and (storage.foldername(name))[2]='batches'
  and name ~ ('^'||auth.uid()::text||'/batches/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}[.](jpg|jpeg|png|webp)$')
  and exists (
    select 1 from public.hub_batches b
    join public.community_hubs h using(hub_id)
    where b.batch_id::text=(storage.foldername(name))[3]
      and h.admin_user_id=auth.uid()
  )
);

drop policy if exists geolock_donation_image_owner_select on storage.objects;
create policy geolock_donation_image_owner_select on storage.objects
for select to authenticated
using (
  bucket_id='geolock-donation-images'
  and exists (
    select 1 from public.donation_images i
    where i.storage_path=name and i.owner_user_id=auth.uid()
  )
);

drop policy if exists geolock_batch_image_owner_select on storage.objects;
create policy geolock_batch_image_owner_select on storage.objects
for select to authenticated
using (
  bucket_id='geolock-donation-images'
  and exists (
    select 1 from public.hub_batch_images i
    where i.storage_path=name and i.owner_user_id=auth.uid()
  )
);

drop policy if exists geolock_donation_image_owner_delete on storage.objects;
create policy geolock_donation_image_owner_delete on storage.objects
for delete to authenticated
using (
  bucket_id='geolock-donation-images'
  and (storage.foldername(name))[1]=auth.uid()::text
  and exists (
    select 1 from public.donations d
    where d.donation_id::text=(storage.foldername(name))[2]
      and d.donor_user_id=auth.uid()
  )
);

drop policy if exists geolock_batch_image_owner_delete on storage.objects;
create policy geolock_batch_image_owner_delete on storage.objects
for delete to authenticated
using (
  bucket_id='geolock-donation-images'
  and (storage.foldername(name))[1]=auth.uid()::text
  and (storage.foldername(name))[2]='batches'
  and exists (
    select 1 from public.hub_batches b
    join public.community_hubs h using(hub_id)
    where b.batch_id::text=(storage.foldername(name))[3]
      and h.admin_user_id=auth.uid()
  )
);

create or replace function public.add_donation_image(
  p_donation uuid, p_storage_path text, p_content_type text, p_size_bytes integer
) returns uuid
language plpgsql security definer
set search_path=pg_catalog, public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_image uuid;
  v_primary boolean;
  v_role text;
begin
  if v_actor is null then raise exception 'UNAUTHENTICATED'; end if;
  if p_size_bytes is null or p_size_bytes not between 1 and 5242880
     or p_content_type is null
     or p_content_type not in ('image/jpeg','image/png','image/webp') then
    raise exception 'INVALID_IMAGE_METADATA';
  end if;
  if p_storage_path is null or p_storage_path !~ (
    '^'||v_actor::text||'/'||p_donation::text||'/[0-9a-fA-F-]{36}\.(jpg|jpeg|png|webp)$'
  ) then
    raise exception 'INVALID_IMAGE_PATH';
  end if;
  if not exists (
    select 1 from public.donations d
    where d.donation_id=p_donation and d.donor_user_id=v_actor
  ) then raise exception 'DONATION_NOT_FOUND_OR_FORBIDDEN'; end if;

  v_primary := not exists (
    select 1 from public.donation_images i
    where i.donation_id=p_donation and i.is_primary
  );
  insert into public.donation_images(
    donation_id, owner_user_id, storage_path, content_type, size_bytes, is_primary
  ) values (
    p_donation, v_actor, p_storage_path, p_content_type, p_size_bytes, v_primary
  ) returning image_id into v_image;

  select p.role into v_role from public.user_profiles p where p.user_id=v_actor;
  insert into public.audit_events(
    actor_user_id, actor_role, entity_type, entity_id, event_type,
    requested_state, resulting_state, outcome, details, configuration_version
  ) values (
    v_actor, v_role, 'DONATION', p_donation, 'DONATION_IMAGE_ADDED',
    'IMAGE_ATTACHED', 'IMAGE_ATTACHED', 'SUCCESS',
    jsonb_build_object('image_id',v_image,'content_type',p_content_type,'size_bytes',p_size_bytes),
    (select c.config_version from public.coordination_config c where c.singleton)
  );
  return v_image;
end;
$$;

create or replace function public.add_hub_batch_image(
  p_batch uuid, p_storage_path text, p_content_type text, p_size_bytes integer
) returns uuid
language plpgsql security definer
set search_path=pg_catalog, public, pg_temp
as $$
declare
  v_actor uuid:=auth.uid();
  v_image uuid;
  v_primary boolean;
  v_role text;
begin
  if v_actor is null then raise exception 'UNAUTHENTICATED'; end if;
  if p_size_bytes is null or p_size_bytes not between 1 and 5242880
     or p_content_type not in ('image/jpeg','image/png','image/webp') then
    raise exception 'INVALID_IMAGE_METADATA';
  end if;
  if p_storage_path is null or p_storage_path !~ (
    '^'||v_actor::text||'/batches/'||p_batch::text||'/[0-9a-fA-F-]{36}[.](jpg|jpeg|png|webp)$'
  ) then raise exception 'INVALID_IMAGE_PATH'; end if;
  if not exists (
    select 1 from public.hub_batches b
    join public.community_hubs h using(hub_id)
    where b.batch_id=p_batch and h.admin_user_id=v_actor
  ) then raise exception 'BATCH_NOT_FOUND_OR_FORBIDDEN'; end if;
  v_primary:=not exists(select 1 from public.hub_batch_images i
    where i.batch_id=p_batch and i.is_primary);
  insert into public.hub_batch_images(
    batch_id,owner_user_id,storage_path,content_type,size_bytes,is_primary
  ) values(p_batch,v_actor,p_storage_path,p_content_type,p_size_bytes,v_primary)
  returning image_id into v_image;
  select p.role into v_role from public.user_profiles p where p.user_id=v_actor;
  insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,
    requested_state,resulting_state,outcome,details,configuration_version)
  values(v_actor,v_role,'BATCH',p_batch,'BATCH_IMAGE_ADDED','IMAGE_ATTACHED','IMAGE_ATTACHED',
    'SUCCESS',jsonb_build_object('image_id',v_image,'content_type',p_content_type,'size_bytes',p_size_bytes),
    (select c.config_version from public.coordination_config c where c.singleton));
  return v_image;
end;
$$;

create or replace function public.get_my_hub_batches_dashboard(p_hub uuid)
returns table(
  batch_id uuid,batch_status text,batch_weight_kg numeric,
  batch_donation_count integer,category_name text,published_at timestamptz,
  primary_image_path text
)
language plpgsql stable security definer
set search_path=pg_catalog,public,pg_temp
as $$
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  if not exists(select 1 from public.community_hubs h
    where h.hub_id=p_hub and h.admin_user_id=auth.uid()) then
    raise exception 'HUB_NOT_FOUND_OR_FORBIDDEN';
  end if;
  return query
  select b.batch_id,b.batch_status,b.batch_weight_kg,b.batch_donation_count,
    c.category_name,b.published_at,i.storage_path
  from public.hub_batches b
  left join public.donation_categories c on c.category_id=b.batch_category_id
  left join lateral (
    select x.storage_path from public.hub_batch_images x
    where x.batch_id=b.batch_id and x.owner_user_id=auth.uid() and x.is_primary
    limit 1
  ) i on true
  where b.hub_id=p_hub and b.batch_status<>'DRAFT'
  order by b.created_at desc;
end;
$$;

create or replace function public.get_my_donation_dashboard()
returns table(
  donation_id uuid, title text, donation_status text, collection_path text,
  total_weight_kg numeric, created_at timestamptz, hub_name text,
  reservation_status text, listing_status text, receipt_status text,
  inventory_status text, item_count bigint, primary_image_path text
)
language plpgsql stable security definer
set search_path=pg_catalog, public, pg_temp
as $$
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  if not exists(select 1 from public.donor_profiles dp where dp.user_id=auth.uid()) then
    raise exception 'DONOR_ONLY';
  end if;
  return query
  select d.donation_id,d.title,d.donation_status,d.collection_path,
    d.total_weight_kg,d.created_at,latest.hub_name,latest.reservation_status,
    l.listing_status,latest.receipt_status,hi.inventory_status,
    (select count(*) from public.donation_items di where di.donation_id=d.donation_id),
    img.storage_path
  from public.donations d
  left join public.listings l on l.donation_id=d.donation_id
    and l.source_type='DIRECT_DONATION'
  left join public.hub_inventory hi on hi.donation_id=d.donation_id
  left join lateral (
    select h.hub_name,r.reservation_status,hr.receipt_status
    from public.hub_reservations r
    join public.community_hubs h using(hub_id)
    left join public.hub_receipts hr on hr.reservation_id=r.reservation_id
    where r.donation_id=d.donation_id
    order by r.reserved_at desc limit 1
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

create or replace function public.get_hub_dashboard(p_hub uuid)
returns jsonb
language plpgsql stable security definer
set search_path=pg_catalog, public, pg_temp
as $$
declare
  v_hub public.community_hubs%rowtype;
  v_stored numeric;
  v_reserved numeric;
  v_awaiting bigint;
  v_stored_count bigint;
  v_published bigint;
  v_collections bigint;
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  select h.* into v_hub from public.community_hubs h
  where h.hub_id=p_hub and h.admin_user_id=auth.uid();
  if not found then raise exception 'HUB_NOT_FOUND_OR_FORBIDDEN'; end if;

  select coalesce(sum(hr.received_weight_kg),0) into v_stored
  from public.hub_inventory hi
  join public.hub_receipts hr using(donation_id)
  where hi.hub_id=p_hub
    and hi.inventory_status in ('STORED','BATCHED','RECONCILIATION_REQUIRED');
  select coalesce(sum(r.reserved_weight_kg),0),
    count(*) filter(where r.reservation_status='ACTIVE'
      and r.expires_at>statement_timestamp()
      and not exists(select 1 from public.hub_receipts hr where hr.reservation_id=r.reservation_id))
  into v_reserved,v_awaiting
  from public.hub_reservations r
  where r.hub_id=p_hub and r.reservation_status='ACTIVE'
    and r.expires_at>statement_timestamp()
    and not exists(select 1 from public.hub_receipts hr where hr.reservation_id=r.reservation_id);
  select count(*) into v_stored_count from public.hub_inventory hi
  where hi.hub_id=p_hub and hi.inventory_status in ('STORED','BATCHED','RECONCILIATION_REQUIRED');
  select count(*) into v_published from public.hub_batches b
  where b.hub_id=p_hub and b.batch_status='PUBLISHED';
  select count(distinct pt.task_id) into v_collections
  from public.pickup_tasks pt
  join public.listings l using(listing_id)
  join public.hub_batches b on b.batch_id=l.batch_id
  where b.hub_id=p_hub and b.batch_status in ('PUBLISHED','CLAIMED')
    and pt.task_status in ('CONFIRMED','PLANNED','DISPATCHED');

  return jsonb_build_object(
    'hub_id',v_hub.hub_id,'hub_name',v_hub.hub_name,
    'capacity_kg',v_hub.capacity_kg,
    'committed_capacity_kg',v_stored+v_reserved,
    'available_capacity_kg',greatest(0,v_hub.capacity_kg-v_stored-v_reserved),
    'awaiting_dropoff_count',v_awaiting,
    'stored_donation_count',v_stored_count,
    'published_batch_count',v_published,
    'upcoming_collection_count',v_collections
  );
end;
$$;

-- These role-owned reads are included here so the new dashboards do not depend
-- on the unapproved Stage 1 migration proposal.
create or replace function public.get_my_hubs()
returns table(hub_id uuid,hub_name text,address_text text,latitude double precision,
  longitude double precision,capacity_kg numeric,active_flag boolean)
language plpgsql stable security definer
set search_path=pg_catalog,public,pg_temp
as $$
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  if not exists(select 1 from public.hub_admin_profiles where user_id=auth.uid()) then
    raise exception 'HUB_ADMIN_ONLY';
  end if;
  return query select h.hub_id,h.hub_name,h.address_text,h.latitude,h.longitude,
    h.capacity_kg,h.active_flag from public.community_hubs h
  where h.admin_user_id=auth.uid() order by h.created_at desc;
end;
$$;

create or replace function public.get_my_hub_reservations(p_hub uuid)
returns table(reservation_id uuid,donation_id uuid,title text,reserved_weight_kg numeric,
  status text,expires_at timestamptz)
language plpgsql stable security definer
set search_path=pg_catalog,public,pg_temp
as $$
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  if not exists(select 1 from public.community_hubs h
    where h.hub_id=p_hub and h.admin_user_id=auth.uid()) then
    raise exception 'HUB_NOT_FOUND_OR_FORBIDDEN';
  end if;
  return query select r.reservation_id,r.donation_id,d.title,r.reserved_weight_kg,
    r.reservation_status,r.expires_at
  from public.hub_reservations r join public.donations d using(donation_id)
  where r.hub_id=p_hub order by r.reserved_at desc;
end;
$$;

create or replace function public.get_my_hub_inventory(p_hub uuid)
returns table(donation_id uuid,title text,donation_status text,received_weight_kg numeric,
  inventory_status text,category_ids uuid[],category_name text)
language plpgsql stable security definer
set search_path=pg_catalog,public,pg_temp
as $$
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  if not exists(select 1 from public.community_hubs h
    where h.hub_id=p_hub and h.admin_user_id=auth.uid()) then
    raise exception 'HUB_NOT_FOUND_OR_FORBIDDEN';
  end if;
  return query
  select d.donation_id,d.title,d.donation_status,hr.received_weight_kg,
    hi.inventory_status,array_agg(distinct di.category_id),
    case when count(distinct di.category_id)=1 then min(cat.category_name)
      else 'Mixed categories' end
  from public.hub_inventory hi
  join public.donations d using(donation_id)
  join public.hub_receipts hr using(donation_id)
  left join public.donation_items di using(donation_id)
  left join public.donation_categories cat using(category_id)
  where hi.hub_id=p_hub
  group by d.donation_id,hr.received_weight_kg,hi.inventory_status
  order by min(hr.received_at) desc;
end;
$$;

create or replace function public.get_my_claims()
returns table(claim_id uuid,listing_id uuid,claim_status text,claimed_at timestamptz,
  lease_id uuid,lease_status text,lease_expires_at timestamptz,task_status text,
  source_type text,listing_weight_kg numeric)
language plpgsql stable security definer
set search_path=pg_catalog,public,pg_temp
as $$
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  if not exists(select 1 from public.ngo_profiles where user_id=auth.uid() and active_flag) then
    raise exception 'ACTIVE_NGO_ONLY';
  end if;
  return query select c.claim_id,c.listing_id,c.claim_status,c.claimed_at,
    le.lease_id,le.lease_status,le.expires_at,pt.task_status,l.source_type,l.listing_weight_kg
  from public.donation_claims c
  join public.listings l using(listing_id)
  left join public.claim_leases le using(claim_id)
  left join public.pickup_tasks pt using(claim_id)
  where c.ngo_user_id=auth.uid()
  order by c.claimed_at desc;
end;
$$;

create or replace function public.get_claimed_listing_detail(p_claim uuid)
returns jsonb
language plpgsql stable security definer
set search_path=pg_catalog,public,pg_temp
as $$
declare v jsonb;
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  select jsonb_build_object(
    'claim_id',c.claim_id,'claim_status',c.claim_status,
    'listing_id',l.listing_id,'listing_status',l.listing_status,
    'source_type',l.source_type,
    'pickup_address',case when l.source_type='DIRECT_DONATION' then d.pickup_address else h.address_text end,
    'latitude',l.pickup_latitude,'longitude',l.pickup_longitude,
    'listing_weight_kg',l.listing_weight_kg,'lease_status',le.lease_status,
    'lease_expires_at',le.expires_at,
    'donation_ids',coalesce((select jsonb_agg(m.donation_id)
      from public.hub_batch_members m
      where m.batch_id=l.batch_id and m.membership_status='ACTIVE'),
      case when d.donation_id is null then '[]'::jsonb else jsonb_build_array(d.donation_id) end)
  ) into v
  from public.donation_claims c
  join public.listings l using(listing_id)
  left join public.donations d on d.donation_id=l.donation_id
  left join public.hub_batches b on b.batch_id=l.batch_id
  left join public.community_hubs h on h.hub_id=b.hub_id
  left join public.claim_leases le using(claim_id)
  where c.claim_id=p_claim and c.ngo_user_id=auth.uid();
  if v is null then raise exception 'CLAIM_NOT_FOUND_OR_FORBIDDEN'; end if;
  return v;
end;
$$;

revoke all on function public.add_donation_image(uuid,text,text,integer) from public,anon;
revoke all on function public.add_hub_batch_image(uuid,text,text,integer) from public,anon;
revoke all on function public.get_my_donation_dashboard() from public,anon;
revoke all on function public.get_hub_dashboard(uuid) from public,anon;
revoke all on function public.get_my_hub_batches_dashboard(uuid) from public,anon;
revoke all on function public.get_my_hubs() from public,anon;
revoke all on function public.get_my_hub_reservations(uuid) from public,anon;
revoke all on function public.get_my_hub_inventory(uuid) from public,anon;
revoke all on function public.get_my_claims() from public,anon;
revoke all on function public.get_claimed_listing_detail(uuid) from public,anon;
grant execute on function public.add_donation_image(uuid,text,text,integer) to authenticated;
grant execute on function public.add_hub_batch_image(uuid,text,text,integer) to authenticated;
grant execute on function public.get_my_donation_dashboard() to authenticated;
grant execute on function public.get_hub_dashboard(uuid) to authenticated;
grant execute on function public.get_my_hub_batches_dashboard(uuid) to authenticated;
grant execute on function public.get_my_hubs() to authenticated;
grant execute on function public.get_my_hub_reservations(uuid) to authenticated;
grant execute on function public.get_my_hub_inventory(uuid) to authenticated;
grant execute on function public.get_my_claims() to authenticated;
grant execute on function public.get_claimed_listing_detail(uuid) to authenticated;
notify pgrst,'reload schema';
commit;

-- NGO image delivery intentionally has no read policy here. V3 does not carry
-- trusted road-node verification state, and the base discovery RPC does not
-- prove it. Add NGO image access only with the approved operational graph and
-- a server read path that filters on that graph.
