-- =====================================================================================
-- Item-level donation photos (additive). Target: NEW KLSEL ppwmdsyoesvhgmqiaoxa.
--
-- Baseline: read-only audit rev2, 26 Nov 2026.
--   * 28/28 function bodies matched.
--   * The four 20261123210000 readers are present.
--   * donation_items.item_position and donation_images.item_id are absent.
--   * donation_images_order_range is 1..3.
--
-- What this migration does:
--   * Every donation item gets a stable, stored position. New rows only; existing items
--     keep NULL, because their original order cannot be recovered.
--   * A donation photo can belong to exactly one item of the SAME donation (composite
--     foreign key), and an item has at most one photo (partial unique index).
--   * create_donation_with_item_photos(): 1-30 items, 0-1 photo per item, at least one
--     photo per donation, same request-ID idempotency and the same Storage checks as
--     create_donation_with_images. The 10 kg classification still runs ONLY in the
--     unchanged create_and_validate_donation().
--   * Four item readers (donor, hub, NGO eligible listing, NGO claim) that return each item
--     with its own photo. The NGO and hub readers reuse the existing readers' authorisation
--     by calling them. Legacy galleries keep using the unchanged get_donation_images.
--
-- What it does NOT do:
--   * Does not change or replace any existing function, including
--     create_donation_with_images and create_and_validate_donation.
--   * Does not touch Storage buckets or policies.
--   * Does not touch claims, leases, routing, hub custody or the donation lifecycle.
--   * Does not delete, move or reassign any existing photo.
--   * Does not change any existing grant.
--
-- Thumbnail rule. New item photos get display_order 1..k in item-position order, and
-- is_primary is display_order = 1. So every existing card/cover reader shows the photo of
-- the first photographed item without modification.
-- =====================================================================================

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

-- 0. Refuse to run unless the database is exactly the audited baseline.
DO $guard$
DECLARE
  v_expected constant jsonb := jsonb_build_object(
    'create_and_validate_donation(text,text,text,double precision,double precision,jsonb,text)', 'd32f089f8a6750f099f8cfee63ac0f4d',
    'create_donation_with_images(uuid,text,text,text,double precision,double precision,jsonb,text,jsonb)', '102cadd77c875339cbe12e5677c7872c',
    'can_read_geolock_donation_image(text)', 'aaee6f68bf4084aa2a0bd3754950b863',
    'get_eligible_listing_constituents_v2(uuid)', 'd179dea87994e65d960f2fb8854f874f',
    'get_claimed_listing_constituents_v2(uuid)', '290c01184cd0f6e3138ea4dbf2464554',
    'get_my_hub_donation_detail(uuid,uuid)', '68ed3ebc4bfd41b39037ccee9eac1b03',
    'guard_donation_items()', '5a083d4ae35b8a9390ac478c6476484a',
    'require_donation_photo_before_commit()', 'e1af5b55edfbc9e867fbad499409eb59');
  v_key text; v_oid regprocedure;
BEGIN
  FOR v_key IN SELECT jsonb_object_keys(v_expected) LOOP
    v_oid := to_regprocedure('public.' || v_key);
    IF v_oid IS NULL THEN RAISE EXCEPTION 'ITEM_PHOTO_BASELINE_MISSING: %', v_key; END IF;
    IF (SELECT md5(replace(prosrc, chr(13), '')) FROM pg_proc WHERE oid = v_oid) <> v_expected->>v_key THEN
      RAISE EXCEPTION 'ITEM_PHOTO_BASELINE_CHANGED: %', v_key;
    END IF;
  END LOOP;
  IF EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.donation_items'::regclass
               AND attname = 'item_position' AND NOT attisdropped)
     OR EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.donation_images'::regclass
               AND attname = 'item_id' AND NOT attisdropped) THEN
    RAISE EXCEPTION 'ITEM_PHOTO_MIGRATION_ALREADY_APPLIED';
  END IF;
  IF (SELECT pg_get_constraintdef(oid) FROM pg_constraint
       WHERE conrelid = 'public.donation_images'::regclass AND conname = 'donation_images_order_range')
     IS DISTINCT FROM 'CHECK (((display_order >= 1) AND (display_order <= 3) AND (is_primary = (display_order = 1))))' THEN
    RAISE EXCEPTION 'ITEM_PHOTO_BASELINE_CHANGED: donation_images_order_range';
  END IF;
END
$guard$;

-- 1. Stable item position ------------------------------------------------------------
ALTER TABLE public.donation_items ADD COLUMN item_position smallint;
ALTER TABLE public.donation_items ADD CONSTRAINT donation_items_item_position_check
  CHECK (item_position IS NULL OR item_position >= 1);
CREATE UNIQUE INDEX ux_donation_items_position ON public.donation_items (donation_id, item_position)
  WHERE item_position IS NOT NULL;

-- Assigns 1, 2, 3, ... in insertion order for each donation. Items are only ever
-- inserted while their donation is still unclassified and invisible to other sessions
-- (guard_donation_items freezes them afterwards), so there is no concurrent writer.
-- create_donation_with_item_photos() additionally cross-checks every stored position.
CREATE FUNCTION public.geolock_assign_donation_item_position()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
begin
  if new.item_position is null then
    select coalesce(max(i.item_position), 0) + 1 into new.item_position
      from public.donation_items i where i.donation_id = new.donation_id;
  end if;
  return new;
end;
$function$;

-- Fires after trg_items_guard (BEFORE triggers run in name order).
CREATE TRIGGER trg_items_position BEFORE INSERT ON public.donation_items
  FOR EACH ROW EXECUTE FUNCTION public.geolock_assign_donation_item_position();

-- 2. Photo-to-item relationship ------------------------------------------------------
ALTER TABLE public.donation_images ADD COLUMN item_id uuid;
-- The existing UNIQUE (item_id, donation_id) on donation_items makes the photo and its
-- item belong to the same donation; an image can never point at another donation's item.
ALTER TABLE public.donation_images ADD CONSTRAINT donation_images_item_same_donation_fkey
  FOREIGN KEY (item_id, donation_id) REFERENCES public.donation_items (item_id, donation_id);
CREATE UNIQUE INDEX ux_donation_images_one_per_item ON public.donation_images (item_id)
  WHERE item_id IS NOT NULL;

-- 3. Allow up to 30 photos (one per item); every existing row (1..3) stays valid ------
ALTER TABLE public.donation_images DROP CONSTRAINT donation_images_order_range;
ALTER TABLE public.donation_images ADD CONSTRAINT donation_images_order_range
  CHECK (((display_order >= 1) AND (display_order <= 30) AND (is_primary = (display_order = 1))));

-- 4. Creation RPC ----------------------------------------------------------------------
CREATE FUNCTION public.create_donation_with_item_photos(
  p_request uuid, p_title text, p_description text, p_pickup_address text,
  p_latitude double precision, p_longitude double precision, p_items jsonb,
  p_pickup_road_node_id text DEFAULT NULL)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'extensions', 'storage', 'pg_temp'
AS $function$
declare
  v_actor uuid := auth.uid();
  v_digest text;
  v_existing public.donation_create_requests%rowtype;
  v_donation uuid;
  v_item jsonb;
  v_photo jsonb;
  v_n integer;
  v_pos integer;
  v_photos integer := 0;
  v_order integer := 0;
  v_canonical jsonb;
  v_items_for_validation jsonb;
  v_paths text[] := '{}';
  v_path text;
  v_type text;
  v_size integer;
  v_ext text;
  v_stored_size bigint;
  v_stored_type text;
  v_item_id uuid;
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
  if jsonb_typeof(p_items) is distinct from 'array'
     or jsonb_array_length(p_items) not between 1 and 30 then
    raise exception 'ONE_TO_THIRTY_ITEMS_REQUIRED';
  end if;
  v_n := jsonb_array_length(p_items);

  -- Explicit positions 1..n (never inferred from array order) and at most one photo object per item.
  for v_item in select e.value from jsonb_array_elements(p_items) e loop
    if jsonb_typeof(v_item) is distinct from 'object' then raise exception 'INVALID_DONATION_ITEM'; end if;
    if jsonb_typeof(v_item->'item_position') is distinct from 'number'
       or (v_item->>'item_position') !~ '^[1-9][0-9]?$' then
      raise exception 'INVALID_ITEM_POSITIONS';
    end if;
    v_photo := v_item->'photo';
    if v_photo is not null and jsonb_typeof(v_photo) <> 'null' then
      if jsonb_typeof(v_photo) <> 'object' then raise exception 'ONE_PHOTO_PER_ITEM'; end if;
      v_photos := v_photos + 1;
    end if;
  end loop;
  if (select count(distinct (e->>'item_position')::integer) from jsonb_array_elements(p_items) e) <> v_n
     or exists(select 1 from jsonb_array_elements(p_items) e
               where (e->>'item_position')::integer not between 1 and v_n) then
    raise exception 'INVALID_ITEM_POSITIONS';
  end if;
  if v_photos = 0 then raise exception 'AT_LEAST_ONE_ITEM_PHOTO_REQUIRED'; end if;

  -- Same idempotency contract as create_donation_with_images. The mode tag keeps a
  -- request ID from ever matching a legacy-RPC payload.
  select jsonb_agg(e order by (e->>'item_position')::integer) into v_canonical
    from jsonb_array_elements(p_items) e;
  v_digest := md5(jsonb_build_object(
    'mode','ITEM_PHOTOS_V1','title',btrim(p_title),'description',p_description,
    'address',p_pickup_address,'lat',p_latitude,'lon',p_longitude,
    'items',v_canonical,'road_node',p_pickup_road_node_id)::text);
  insert into public.donation_create_requests(request_id,donor_user_id,request_digest)
  values(p_request,v_actor,v_digest) on conflict(request_id) do nothing;
  select * into v_existing from public.donation_create_requests
  where request_id=p_request for update;
  if v_existing.donor_user_id<>v_actor or v_existing.request_digest<>v_digest then
    raise exception 'IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD';
  end if;
  if v_existing.donation_id is not null then return v_existing.donation_id; end if;

  -- Same staged-upload checks as create_donation_with_images, per item.
  for v_item in select e from jsonb_array_elements(v_canonical) e loop
    v_pos := (v_item->>'item_position')::integer;
    v_photo := v_item->'photo';
    continue when v_photo is null or jsonb_typeof(v_photo) = 'null';
    if exists(select 1 from jsonb_object_keys(v_photo) k
              where k not in ('storage_path','content_type','size_bytes')) then
      raise exception 'INVALID_ITEM_PHOTO_%', v_pos;
    end if;
    v_path := v_photo->>'storage_path';
    v_type := v_photo->>'content_type';
    v_size := case when jsonb_typeof(v_photo->'size_bytes') = 'number'
                     and (v_photo->>'size_bytes') ~ '^[0-9]{1,9}$'
                   then (v_photo->>'size_bytes')::integer end;
    v_ext := lower(split_part(v_path,'.',array_length(string_to_array(v_path,'.'),1)));
    if v_path is null
       or v_path !~ ('^'||v_actor::text||'/pending/'||p_request::text||'/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}[.](jpg|jpeg|png|webp)$')
       or v_size is null or v_size not between 1 and 5242880
       or v_type is null or v_type not in ('image/jpeg','image/png','image/webp')
       or (v_ext in ('jpg','jpeg') and v_type<>'image/jpeg')
       or (v_ext='png' and v_type<>'image/png')
       or (v_ext='webp' and v_type<>'image/webp') then
      raise exception 'INVALID_ITEM_PHOTO_%', v_pos;
    end if;
    if v_path = any(v_paths) then raise exception 'DUPLICATE_ITEM_PHOTO_%', v_pos; end if;
    v_paths := v_paths || v_path;
    if exists(select 1 from public.donation_images i where i.storage_path = v_path)
       or exists(select 1 from public.hub_batch_images i where i.storage_path = v_path) then
      raise exception 'ITEM_PHOTO_ALREADY_ATTACHED_%', v_pos;
    end if;
    select nullif(o.metadata->>'size','')::bigint, o.metadata->>'mimetype'
      into v_stored_size, v_stored_type
    from storage.objects o
    where o.bucket_id='geolock-donation-images' and o.name=v_path;
    if not found or v_stored_size is null or v_stored_size<>v_size or v_stored_type<>v_type then
      raise exception 'STAGED_ITEM_PHOTO_MISSING_OR_MISMATCHED_%', v_pos;
    end if;
  end loop;

  -- Unchanged validation, weight and 10 kg classification, listing creation and
  -- CREATE_DONATION audit. Items are passed in explicit position order.
  select jsonb_agg((e - 'photo' - 'item_position') order by (e->>'item_position')::integer)
    into v_items_for_validation from jsonb_array_elements(p_items) e;
  v_donation := public.create_and_validate_donation(
    p_title,p_description,p_pickup_address,p_latitude,p_longitude,
    v_items_for_validation,p_pickup_road_node_id);

  -- Prove every stored position holds the item the client sent for that position.
  if (select count(*) from public.donation_items i where i.donation_id=v_donation) <> v_n
     or exists(
       select 1 from jsonb_array_elements(p_items) e
       left join public.donation_items i
         on i.donation_id=v_donation and i.item_position=(e->>'item_position')::integer
       where i.item_id is null
          or i.item_name is distinct from e->>'item_name'
          or i.category_id is distinct from (e->>'category_id')::uuid
          or i.quantity is distinct from (e->>'quantity')::integer
          or i.unit_weight_kg is distinct from (e->>'unit_weight_kg')::numeric(12,3)) then
    raise exception 'ITEM_POSITION_MISMATCH';
  end if;

  -- One image per photographed item; display_order follows item position.
  for v_item in select e from jsonb_array_elements(v_canonical) e
                where jsonb_typeof(e->'photo') = 'object' loop
    v_order := v_order + 1;
    select i.item_id into v_item_id from public.donation_items i
    where i.donation_id=v_donation and i.item_position=(v_item->>'item_position')::integer;
    insert into public.donation_images(
      donation_id,owner_user_id,storage_path,content_type,size_bytes,is_primary,display_order,item_id
    ) values(
      v_donation,v_actor,v_item->'photo'->>'storage_path',v_item->'photo'->>'content_type',
      (v_item->'photo'->>'size_bytes')::integer,v_order=1,v_order::smallint,v_item_id
    );
  end loop;

  update public.donation_create_requests set donation_id=v_donation
  where request_id=p_request;
  select role into v_role from public.user_profiles where user_id=v_actor;
  insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,
    requested_state,resulting_state,outcome,details,configuration_version)
  values(v_actor,v_role,'DONATION',v_donation,'DONATION_PHOTOS_ATTACHED',
    'ITEM_PHOTOS','ITEM_PHOTOS','SUCCESS',
    jsonb_build_object('request_id',p_request,'photo_count',v_order,'item_count',v_n,
      'photo_mode','ITEM_LEVEL'),
    (select config_version from public.coordination_config where singleton));
  return v_donation;
end;
$function$;

-- 5. Readers -------------------------------------------------------------------------
-- 5a. Donor: own donation only (same checks as get_my_donation_detail).
CREATE FUNCTION public.get_my_donation_items(p_donation uuid)
 RETURNS TABLE(donation_id uuid, item_id uuid, item_position smallint, item_name text,
               category_name text, quantity integer, unit_label text, unit_weight_kg numeric,
               item_condition text, item_description text, photo_image_id uuid,
               photo_path text, photo_content_type text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
#variable_conflict use_column
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  if not exists(select 1 from public.donor_profiles dp where dp.user_id=auth.uid()) then
    raise exception 'DONOR_ONLY';
  end if;
  if not exists(select 1 from public.donations d
                where d.donation_id=p_donation and d.donor_user_id=auth.uid()) then
    raise exception 'DONATION_NOT_FOUND_OR_FORBIDDEN';
  end if;
  return query
  select i.donation_id, i.item_id, i.item_position, i.item_name, c.category_name, i.quantity,
         i.unit_label, i.unit_weight_kg, i.item_condition, i.description, img.image_id,
         case when public.can_read_geolock_donation_image(img.storage_path) then img.storage_path end,
         case when public.can_read_geolock_donation_image(img.storage_path) then img.content_type end
  from public.donation_items i
  join public.donation_categories c on c.category_id = i.category_id
  left join public.donation_images img on img.item_id = i.item_id
  where i.donation_id = p_donation
  order by i.item_position nulls last, i.created_at, i.item_id;
end;
$function$;

-- 5b. Hub admin: authorised exactly as get_my_hub_donation_detail (it is called first and
--     raises for the wrong hub or a donation that never came to this hub). The photo path
--     is returned only where Storage would also allow the read (can_read_geolock_donation_image).
CREATE FUNCTION public.get_my_hub_donation_items(p_hub uuid, p_donation uuid)
 RETURNS TABLE(donation_id uuid, item_id uuid, item_position smallint, item_name text,
               category_name text, quantity integer, unit_label text, unit_weight_kg numeric,
               item_condition text, item_description text, photo_image_id uuid,
               photo_path text, photo_content_type text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
#variable_conflict use_column
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  if public.get_my_hub_donation_detail(p_hub, p_donation) is null then
    raise exception 'DONATION_NOT_AT_THIS_HUB';
  end if;
  return query
  select i.donation_id, i.item_id, i.item_position, i.item_name, c.category_name, i.quantity,
         i.unit_label, i.unit_weight_kg, i.item_condition, i.description, img.image_id,
         case when public.can_read_geolock_donation_image(img.storage_path) then img.storage_path end,
         case when public.can_read_geolock_donation_image(img.storage_path) then img.content_type end
  from public.donation_items i
  join public.donation_categories c on c.category_id = i.category_id
  left join public.donation_images img on img.item_id = i.item_id
  where i.donation_id = p_donation
  order by i.item_position nulls last, i.created_at, i.item_id;
end;
$function$;

-- 5c. NGO, eligible listing: the authorised donations are EXACTLY those that
--     get_eligible_listing_constituents_v2 returns for this caller (same exceptions:
--     UNAUTHENTICATED, VERIFIED_NGO_ONLY, LISTING_NOT_ELIGIBLE). No donor identity
--     and no free-text item description are returned.
CREATE FUNCTION public.get_eligible_listing_items(p_listing uuid)
 RETURNS TABLE(donation_id uuid, item_id uuid, item_position smallint, item_name text,
               category_name text, quantity integer, unit_label text, unit_weight_kg numeric,
               item_condition text, photo_image_id uuid, photo_path text, photo_content_type text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
#variable_conflict use_column
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  return query
  with allowed as materialized (
    select distinct c.donation_id from public.get_eligible_listing_constituents_v2(p_listing) c
  )
  select i.donation_id, i.item_id, i.item_position, i.item_name, cat.category_name, i.quantity,
         i.unit_label, i.unit_weight_kg, i.item_condition, img.image_id,
         case when public.can_read_geolock_donation_image(img.storage_path) then img.storage_path end,
         case when public.can_read_geolock_donation_image(img.storage_path) then img.content_type end
  from allowed a
  join public.donation_items i on i.donation_id = a.donation_id
  join public.donation_categories cat on cat.category_id = i.category_id
  left join public.donation_images img on img.item_id = i.item_id
  order by i.donation_id, i.item_position nulls last, i.created_at, i.item_id;
end;
$function$;

-- 5d. NGO, own claim: the authorised donations are EXACTLY those that
--     get_claimed_listing_constituents_v2 returns (same claim and lease rules, same
--     CLAIM_NOT_FOUND_OR_FORBIDDEN for expired or foreign claims).
CREATE FUNCTION public.get_claimed_listing_items(p_claim uuid)
 RETURNS TABLE(donation_id uuid, item_id uuid, item_position smallint, item_name text,
               category_name text, quantity integer, unit_label text, unit_weight_kg numeric,
               item_condition text, photo_image_id uuid, photo_path text, photo_content_type text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
#variable_conflict use_column
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  return query
  with allowed as materialized (
    select distinct c.donation_id from public.get_claimed_listing_constituents_v2(p_claim) c
  )
  select i.donation_id, i.item_id, i.item_position, i.item_name, cat.category_name, i.quantity,
         i.unit_label, i.unit_weight_kg, i.item_condition, img.image_id,
         case when public.can_read_geolock_donation_image(img.storage_path) then img.storage_path end,
         case when public.can_read_geolock_donation_image(img.storage_path) then img.content_type end
  from allowed a
  join public.donation_items i on i.donation_id = a.donation_id
  join public.donation_categories cat on cat.category_id = i.category_id
  left join public.donation_images img on img.item_id = i.item_id
  order by i.donation_id, i.item_position nulls last, i.created_at, i.item_id;
end;
$function$;

-- 6. Grants: new functions are callable by signed-in users only; never by anon --------
REVOKE ALL ON FUNCTION public.geolock_assign_donation_item_position() FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.create_donation_with_item_photos(uuid,text,text,text,double precision,double precision,jsonb,text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.create_donation_with_item_photos(uuid,text,text,text,double precision,double precision,jsonb,text) TO authenticated;
REVOKE ALL ON FUNCTION public.get_my_donation_items(uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_my_donation_items(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.get_my_hub_donation_items(uuid,uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_my_hub_donation_items(uuid,uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.get_eligible_listing_items(uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_eligible_listing_items(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.get_claimed_listing_items(uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_claimed_listing_items(uuid) TO authenticated;

-- 7. Fail the whole migration if anything above did not take effect ------------------
DO $verify$
DECLARE r record;
BEGIN
  FOR r IN SELECT unnest(ARRAY[
      'public.create_donation_with_item_photos(uuid,text,text,text,double precision,double precision,jsonb,text)',
      'public.get_my_donation_items(uuid)',
      'public.get_my_hub_donation_items(uuid,uuid)', 'public.get_eligible_listing_items(uuid)',
      'public.get_claimed_listing_items(uuid)']) AS f LOOP
    IF has_function_privilege('anon', r.f::regprocedure, 'EXECUTE') THEN
      RAISE EXCEPTION 'ITEM_PHOTO_GRANT_LEAK_ANON: %', r.f; END IF;
    IF NOT has_function_privilege('authenticated', r.f::regprocedure, 'EXECUTE') THEN
      RAISE EXCEPTION 'ITEM_PHOTO_GRANT_MISSING_AUTHENTICATED: %', r.f; END IF;
    IF EXISTS (SELECT 1 FROM pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
               WHERE p.oid = r.f::regprocedure AND a.grantee = 0) THEN
      RAISE EXCEPTION 'ITEM_PHOTO_GRANT_LEAK_PUBLIC: %', r.f; END IF;
  END LOOP;
  IF has_function_privilege('anon', 'public.geolock_assign_donation_item_position()'::regprocedure, 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.geolock_assign_donation_item_position()'::regprocedure, 'EXECUTE') THEN
    RAISE EXCEPTION 'ITEM_PHOTO_GRANT_LEAK_TRIGGER_FUNCTION';
  END IF;
END
$verify$;

COMMIT;
