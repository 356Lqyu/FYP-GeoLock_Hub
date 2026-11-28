-- ROLLBACK for 20261128120000_require_photo_for_every_item.sql. NOT a migration; run only if asked.
-- Restores the exact 20261126120000 body of create_donation_with_item_photos (at least one
-- photo per donation, 0-1 per item). Deletes nothing: donations created with a photo on every
-- item remain valid under the earlier rule. Owner, security, settings and grants are kept.
-- Refuses to run unless the current body is exactly the 20261128120000 body.

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

DO $guard$
DECLARE v_md5 text; v_fn regprocedure := to_regprocedure('public.create_donation_with_item_photos(uuid,text,text,text,double precision,double precision,jsonb,text)');
BEGIN
  IF v_fn IS NULL THEN RAISE EXCEPTION 'EVERY_ITEM_PHOTO_ROLLBACK_BASELINE_MISSING: create_donation_with_item_photos'; END IF;
  SELECT md5(replace(prosrc, chr(13), '')) INTO v_md5 FROM pg_proc WHERE oid = v_fn;
  IF v_md5 = '96489d8f1ba4ea79bd733fb0034f9c2b' THEN RAISE EXCEPTION 'EVERY_ITEM_PHOTO_ROLLBACK_ALREADY_APPLIED (body is already the 20261126120000 body)'; END IF;
  IF v_md5 <> '199df942b0a4d00d63649985fda61a88' THEN RAISE EXCEPTION 'EVERY_ITEM_PHOTO_ROLLBACK_BASELINE_CHANGED: create_donation_with_item_photos %', v_md5; END IF;
  -- The photo-to-item relationship from 20261126120000 must be in place, unchanged.
  IF to_regclass('public.ux_donation_images_one_per_item') IS NULL
     OR to_regclass('public.ux_donation_items_position') IS NULL
     OR NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.donation_images'::regclass
                      AND conname = 'donation_images_item_same_donation_fkey')
     OR (SELECT pg_get_constraintdef(oid) FROM pg_constraint
          WHERE conrelid = 'public.donation_images'::regclass AND conname = 'donation_images_order_range')
        IS DISTINCT FROM 'CHECK (((display_order >= 1) AND (display_order <= 30) AND (is_primary = (display_order = 1))))' THEN
    RAISE EXCEPTION 'EVERY_ITEM_PHOTO_ROLLBACK_BASELINE_CHANGED: item photo constraints';
  END IF;
  -- Remember owner, security, settings and grants; CREATE OR REPLACE must keep all of them.
  CREATE TEMP TABLE geolock_fn_before ON COMMIT DROP AS
    SELECT proowner, prosecdef, proconfig::text AS cfg, coalesce(proacl::text, 'default') AS acl
      FROM pg_proc WHERE oid = v_fn;
END
$guard$;

CREATE OR REPLACE FUNCTION public.create_donation_with_item_photos(
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

DO $verify$
DECLARE v_fn regprocedure := 'public.create_donation_with_item_photos(uuid,text,text,text,double precision,double precision,jsonb,text)'::regprocedure;
BEGIN
  IF (SELECT md5(replace(prosrc, chr(13), '')) FROM pg_proc WHERE oid = v_fn) <> '96489d8f1ba4ea79bd733fb0034f9c2b' THEN
    RAISE EXCEPTION 'EVERY_ITEM_PHOTO_ROLLBACK_BODY_NOT_AS_REVIEWED'; END IF;
  IF EXISTS (SELECT proowner, prosecdef, proconfig::text, coalesce(proacl::text, 'default') FROM pg_proc WHERE oid = v_fn
             EXCEPT SELECT proowner, prosecdef, cfg, acl FROM geolock_fn_before) THEN
    RAISE EXCEPTION 'EVERY_ITEM_PHOTO_ROLLBACK_OWNER_SECURITY_OR_GRANTS_CHANGED'; END IF;
  IF has_function_privilege('anon', v_fn, 'EXECUTE')
     OR NOT has_function_privilege('authenticated', v_fn, 'EXECUTE') THEN
    RAISE EXCEPTION 'EVERY_ITEM_PHOTO_ROLLBACK_GRANTS_CHANGED'; END IF;
END
$verify$;

COMMIT;
