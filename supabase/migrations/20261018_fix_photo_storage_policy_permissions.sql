-- GeoLock Hub: remove protected application-table reads from Storage RLS.
-- Apply only after the role-dashboard/image and photo-transition migrations.
-- No donation, claim, lease, routing, or coordination state is changed.
begin;

do $$
begin
  if to_regclass('public.donor_profiles') is null
     or to_regclass('public.donations') is null
     or to_regclass('public.donation_images') is null
     or to_regclass('public.hub_batches') is null
     or to_regclass('public.community_hubs') is null
     or to_regclass('public.hub_batch_images') is null
     or to_regclass('storage.objects') is null then
    raise exception 'Required V3, image metadata, and Storage objects are missing';
  end if;
  if not exists(select 1 from storage.buckets where id='geolock-donation-images'
    and not public and file_size_limit=5242880
    and allowed_mime_types=array['image/jpeg','image/png','image/webp']::text[]) then
    raise exception 'Expected private 5 MB GeoLock image bucket is missing or incompatible';
  end if;
  if not has_table_privilege(current_user,'public.donations','select')
     or not has_table_privilege(current_user,'public.donor_profiles','select')
     or not has_table_privilege(current_user,'public.donation_images','select')
     or not has_table_privilege(current_user,'public.hub_batches','select')
     or not has_table_privilege(current_user,'public.community_hubs','select')
     or not has_table_privilege(current_user,'public.hub_batch_images','select')
     or not has_table_privilege(current_user,'storage.buckets','select') then
    raise exception 'Run migration as a trusted owner with SELECT access to the ownership tables';
  end if;
  -- SECURITY DEFINER does not automatically bypass row security. The function
  -- owner must either have BYPASSRLS, or own every table these helpers inspect
  -- with FORCE ROW LEVEL SECURITY disabled. This prevents silent false denials
  -- and policy recursion under a limited deployment role.
  if not exists(select 1 from pg_roles r where r.rolname=current_user
       and (r.rolsuper or r.rolbypassrls))
     and exists(
       select 1 from pg_class c
       join pg_namespace n on n.oid=c.relnamespace
       where (n.nspname,c.relname) in
         (('public','donor_profiles'),('public','donations'),
          ('public','donation_images'),('public','hub_batches'),
          ('public','community_hubs'),('public','hub_batch_images'),
          ('storage','buckets'))
         and (c.relowner<>(select oid from pg_roles where rolname=current_user)
              or c.relforcerowsecurity)
     ) then
    raise exception 'Migration role cannot safely bypass RLS for SECURITY DEFINER ownership checks';
  end if;
  if to_regprocedure('public.can_read_geolock_donation_image(text)') is null
     or to_regprocedure('public.can_read_geolock_batch_image(text)') is null
     or not exists(select 1 from pg_proc p
       where p.oid='public.can_read_geolock_donation_image(text)'::regprocedure
         and p.prosecdef and exists(select 1 from unnest(coalesce(p.proconfig,'{}'::text[])) s(setting)
           where split_part(s.setting,'=',1)='search_path'
             and regexp_replace(split_part(s.setting,'=',2),'[[:space:]]','','g')='pg_catalog,public,extensions,pg_temp'))
     or not exists(select 1 from pg_proc p
       where p.oid='public.can_read_geolock_batch_image(text)'::regprocedure
         and p.prosecdef and exists(select 1 from unnest(coalesce(p.proconfig,'{}'::text[])) s(setting)
           where split_part(s.setting,'=',1)='search_path'
             and regexp_replace(split_part(s.setting,'=',2),'[[:space:]]','','g')='pg_catalog,public,extensions,pg_temp')) then
    raise exception 'Expected trusted donation and batch image read helpers are missing or incompatible';
  end if;
  -- Both readers query their corresponding metadata table. If the SECURITY
  -- DEFINER owner does not bypass RLS, it must own that table with FORCE RLS
  -- disabled; otherwise a metadata policy calling the reader would recurse.
  if not exists(select 1 from pg_proc p join pg_roles r on r.oid=p.proowner
       where p.oid='public.can_read_geolock_donation_image(text)'::regprocedure
         and (r.rolsuper or r.rolbypassrls or exists(select 1 from pg_class c
           where c.oid='public.donation_images'::regclass and c.relowner=p.proowner
             and not c.relforcerowsecurity)))
     or not exists(select 1 from pg_proc p join pg_roles r on r.oid=p.proowner
       where p.oid='public.can_read_geolock_batch_image(text)'::regprocedure
         and (r.rolsuper or r.rolbypassrls or exists(select 1 from pg_class c
           where c.oid='public.hub_batch_images'::regclass and c.relowner=p.proowner
             and not c.relforcerowsecurity))) then
    raise exception 'Photo reader owners would recurse through metadata-table RLS';
  end if;
end $$;

-- These SECURITY DEFINER helpers return only a boolean. The function owner
-- performs narrowly-scoped ownership checks unavailable to authenticated
-- callers under direct table privileges and RLS.
create or replace function public.geolock_storage_can_upload_donation_image(
  p_bucket text,p_name text,p_metadata jsonb
) returns boolean language plpgsql volatile security definer
set search_path=pg_catalog,pg_temp as $$
declare
  v_actor uuid:=auth.uid();
  v_ext text:=lower(split_part(coalesce(p_name,''),'.',array_length(string_to_array(coalesce(p_name,''),'.'),1)));
  v_type text:=p_metadata->>'mimetype';
begin
  if v_actor is null or p_bucket<>'geolock-donation-images'
     or coalesce(v_type,'') not in ('image/jpeg','image/png','image/webp')
     or not exists(select 1 from storage.buckets b where b.id=p_bucket and not b.public
       and b.file_size_limit=5242880
       and b.allowed_mime_types=array['image/jpeg','image/png','image/webp']::text[])
     or (v_ext in ('jpg','jpeg') and v_type<>'image/jpeg')
     or (v_ext='png' and v_type<>'image/png')
     or (v_ext='webp' and v_type<>'image/webp')
     or v_ext not in ('jpg','jpeg','png','webp')
     or not exists(select 1 from public.donor_profiles dp where dp.user_id=v_actor) then
    return false;
  end if;
  -- Storage's pre-insert RLS probe supplies mimetype and contentLength; it does
  -- not reliably supply the final size key yet. The private bucket enforces the
  -- 5 MB transfer limit, and the create RPC checks stored metadata.size before
  -- attaching the object.
  if p_name ~ ('^'||v_actor::text||'/pending/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}[.](jpg|jpeg|png|webp)$') then
    return true;
  end if;
  -- Legacy path remains supported for an existing donor-owned donation.
  if p_name ~ ('^'||v_actor::text||'/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}[.](jpg|jpeg|png|webp)$') then
    return exists(select 1 from public.donations d
      where d.donation_id::text=split_part(p_name,'/',2) and d.donor_user_id=v_actor);
  end if;
  return false;
end;
$$;

create or replace function public.geolock_storage_can_upload_batch_image(
  p_bucket text,p_name text,p_metadata jsonb
) returns boolean language plpgsql volatile security definer
set search_path=pg_catalog,pg_temp as $$
declare
  v_actor uuid:=auth.uid();
  v_ext text:=lower(split_part(coalesce(p_name,''),'.',array_length(string_to_array(coalesce(p_name,''),'.'),1)));
  v_type text:=p_metadata->>'mimetype';
begin
  if v_actor is null or p_bucket<>'geolock-donation-images'
     or coalesce(v_type,'') not in ('image/jpeg','image/png','image/webp')
     or not exists(select 1 from storage.buckets b where b.id=p_bucket and not b.public
       and b.file_size_limit=5242880
       and b.allowed_mime_types=array['image/jpeg','image/png','image/webp']::text[])
     or (v_ext in ('jpg','jpeg') and v_type<>'image/jpeg')
     or (v_ext='png' and v_type<>'image/png')
     or (v_ext='webp' and v_type<>'image/webp')
     or v_ext not in ('jpg','jpeg','png','webp')
     or p_name !~ ('^'||v_actor::text||'/batches/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}[.](jpg|jpeg|png|webp)$') then
    return false;
  end if;
  return exists(select 1 from public.hub_batches b
    join public.community_hubs h using(hub_id)
    where b.batch_id::text=split_part(p_name,'/',3) and h.admin_user_id=v_actor)
    and not exists(select 1 from public.hub_batch_images i
      where i.batch_id::text=split_part(p_name,'/',3));
end;
$$;

create or replace function public.geolock_storage_can_delete_unattached_image(
  p_bucket text,p_name text
) returns boolean language plpgsql volatile security definer
set search_path=pg_catalog,pg_temp as $$
declare v_actor uuid:=auth.uid();
begin
  if v_actor is null or p_bucket<>'geolock-donation-images' then return false; end if;
  if p_name ~ ('^'||v_actor::text||'/pending/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}[.](jpg|jpeg|png|webp)$') then
    return exists(select 1 from public.donor_profiles dp where dp.user_id=v_actor)
      and not exists(select 1 from public.donation_images i where i.storage_path=p_name)
      and not exists(select 1 from public.hub_batch_images i where i.storage_path=p_name);
  end if;
  if p_name ~ ('^'||v_actor::text||'/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}[.](jpg|jpeg|png|webp)$') then
    return exists(select 1 from public.donor_profiles dp where dp.user_id=v_actor)
      and exists(select 1 from public.donations d
        where d.donation_id::text=split_part(p_name,'/',2) and d.donor_user_id=v_actor)
      and not exists(select 1 from public.donation_images i where i.storage_path=p_name)
      and not exists(select 1 from public.hub_batch_images i where i.storage_path=p_name);
  end if;
  if p_name ~ ('^'||v_actor::text||'/batches/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}[.](jpg|jpeg|png|webp)$') then
    return exists(select 1 from public.hub_batches b
        join public.community_hubs h using(hub_id)
        where b.batch_id::text=split_part(p_name,'/',3) and h.admin_user_id=v_actor)
      and not exists(select 1 from public.donation_images i where i.storage_path=p_name)
      and not exists(select 1 from public.hub_batch_images i where i.storage_path=p_name);
  end if;
  return false;
end;
$$;

create or replace function public.geolock_storage_can_read_image(
  p_bucket text,p_name text
) returns boolean language plpgsql volatile security definer
set search_path=pg_catalog,pg_temp as $$
declare v_actor uuid:=auth.uid();
begin
  if v_actor is null or p_bucket<>'geolock-donation-images' then return false; end if;
  if p_name ~ ('^'||v_actor::text||'/pending/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}[.](jpg|jpeg|png|webp)$') then
    if exists(select 1 from public.donor_profiles dp where dp.user_id=v_actor) then
      return true;
    end if;
    -- Once attached, the same pending-path object can also be read by a
    -- permitted NGO claimant or hub admin through the existing role helper.
  end if;
  return public.can_read_geolock_donation_image(p_name)
    or public.can_read_geolock_batch_image(p_name);
end;
$$;

revoke all on function public.geolock_storage_can_upload_donation_image(text,text,jsonb) from public,anon;
revoke all on function public.geolock_storage_can_upload_batch_image(text,text,jsonb) from public,anon;
revoke all on function public.geolock_storage_can_delete_unattached_image(text,text) from public,anon;
revoke all on function public.geolock_storage_can_read_image(text,text) from public,anon;
grant execute on function public.geolock_storage_can_upload_donation_image(text,text,jsonb) to authenticated;
grant execute on function public.geolock_storage_can_upload_batch_image(text,text,jsonb) to authenticated;
grant execute on function public.geolock_storage_can_delete_unattached_image(text,text) to authenticated;
grant execute on function public.geolock_storage_can_read_image(text,text) to authenticated;

drop policy if exists donation_images_owner_read on public.donation_images;
create policy donation_images_owner_read on public.donation_images
for select to authenticated using (
  public.can_read_geolock_donation_image(storage_path)
);
drop policy if exists hub_batch_images_owner_read on public.hub_batch_images;
create policy hub_batch_images_owner_read on public.hub_batch_images
for select to authenticated using (
  public.can_read_geolock_batch_image(storage_path)
);
drop policy if exists geolock_donation_images_authenticated_read_guard on public.donation_images;
create policy geolock_donation_images_authenticated_read_guard on public.donation_images
as restrictive for select to authenticated using (
  public.can_read_geolock_donation_image(storage_path)
);
drop policy if exists geolock_hub_batch_images_authenticated_read_guard on public.hub_batch_images;
create policy geolock_hub_batch_images_authenticated_read_guard on public.hub_batch_images
as restrictive for select to authenticated using (
  public.can_read_geolock_batch_image(storage_path)
);

-- Replace known GeoLock write policies only. Storage policies are permissive
-- ORs, so deployment verification must inspect every other storage.objects policy.
drop policy if exists geolock_donation_image_owner_insert on storage.objects;
create policy geolock_donation_image_owner_insert on storage.objects
for insert to authenticated with check (
  public.geolock_storage_can_upload_donation_image(bucket_id,name,metadata)
);
drop policy if exists geolock_batch_image_owner_insert on storage.objects;
create policy geolock_batch_image_owner_insert on storage.objects
for insert to authenticated with check (
  public.geolock_storage_can_upload_batch_image(bucket_id,name,metadata)
);

drop policy if exists geolock_donation_image_owner_delete on storage.objects;
drop policy if exists geolock_pending_donation_image_delete on storage.objects;
drop policy if exists geolock_unattached_donation_image_delete on storage.objects;
create policy geolock_unattached_donation_image_delete on storage.objects
for delete to authenticated using (
  public.geolock_storage_can_delete_unattached_image(bucket_id,name)
);
drop policy if exists geolock_batch_image_owner_delete on storage.objects;
drop policy if exists geolock_unattached_batch_image_delete on storage.objects;
create policy geolock_unattached_batch_image_delete on storage.objects
for delete to authenticated using (
  public.geolock_storage_can_delete_unattached_image(bucket_id,name)
);

-- Restrictive guards stop any other permissive policy from accidentally
-- broadening access to this private bucket. Other Storage buckets are unaffected.
drop policy if exists geolock_donation_images_authenticated_insert_guard on storage.objects;
create policy geolock_donation_images_authenticated_insert_guard on storage.objects
as restrictive for insert to authenticated with check (
  bucket_id<>'geolock-donation-images'
  or public.geolock_storage_can_upload_donation_image(bucket_id,name,metadata)
  or public.geolock_storage_can_upload_batch_image(bucket_id,name,metadata)
);
drop policy if exists geolock_donation_images_authenticated_select_guard on storage.objects;
create policy geolock_donation_images_authenticated_select_guard on storage.objects
as restrictive for select to authenticated using (
  bucket_id<>'geolock-donation-images'
  or public.geolock_storage_can_read_image(bucket_id,name)
);
drop policy if exists geolock_donation_images_authenticated_delete_guard on storage.objects;
create policy geolock_donation_images_authenticated_delete_guard on storage.objects
as restrictive for delete to authenticated using (
  bucket_id<>'geolock-donation-images'
  or public.geolock_storage_can_delete_unattached_image(bucket_id,name)
);
drop policy if exists geolock_donation_images_authenticated_update_guard on storage.objects;
create policy geolock_donation_images_authenticated_update_guard on storage.objects
as restrictive for update to authenticated using (
  bucket_id<>'geolock-donation-images'
) with check (bucket_id<>'geolock-donation-images');

-- A public/anonymous permissive policy must not expose this private bucket.
drop policy if exists geolock_donation_images_anon_insert_guard on storage.objects;
create policy geolock_donation_images_anon_insert_guard on storage.objects
as restrictive for insert to anon with check (bucket_id<>'geolock-donation-images');
drop policy if exists geolock_donation_images_anon_select_guard on storage.objects;
create policy geolock_donation_images_anon_select_guard on storage.objects
as restrictive for select to anon using (bucket_id<>'geolock-donation-images');
drop policy if exists geolock_donation_images_anon_delete_guard on storage.objects;
create policy geolock_donation_images_anon_delete_guard on storage.objects
as restrictive for delete to anon using (bucket_id<>'geolock-donation-images');
drop policy if exists geolock_donation_images_anon_update_guard on storage.objects;
create policy geolock_donation_images_anon_update_guard on storage.objects
as restrictive for update to anon using (bucket_id<>'geolock-donation-images')
with check (bucket_id<>'geolock-donation-images');

notify pgrst,'reload schema';
commit;
