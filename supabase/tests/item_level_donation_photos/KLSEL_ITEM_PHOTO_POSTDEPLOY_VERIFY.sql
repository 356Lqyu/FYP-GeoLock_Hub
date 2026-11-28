-- Read-only post-deployment check for 20261126120000_item_level_donation_photos.sql
-- on NEW KLSEL (ppwmdsyoesvhgmqiaoxa). Run in the SQL Editor right after deploying.
-- Returns one JSON document and writes nothing (READ ONLY + ROLLBACK). No personal data is read.
BEGIN TRANSACTION READ ONLY;
WITH
new_fn(sig, body_md5, secdef) AS (VALUES
  ('create_donation_with_item_photos(uuid,text,text,text,double precision,double precision,jsonb,text)', '96489d8f1ba4ea79bd733fb0034f9c2b', true),
  ('geolock_assign_donation_item_position()', 'cae08ec329a1ce1a77f41c3f666236c6', false),
  ('get_claimed_listing_items(uuid)', '1062a3dff9ebdc538fd450213ee9db87', true),
  ('get_eligible_listing_items(uuid)', '19e959cc924454f8dcc43c6c1747e594', true),
  ('get_my_donation_items(uuid)', '4b5457e3d35abab707d1a4b141519d7d', true),
  ('get_my_hub_donation_items(uuid,uuid)', '07f187d298c486e2705a47ce1a07a85f', true)),
unchanged(sig, body_md5) AS (VALUES
  ('create_donation_with_images(uuid,text,text,text,double precision,double precision,jsonb,text,jsonb)', '102cadd77c875339cbe12e5677c7872c'),
  ('create_and_validate_donation(text,text,text,double precision,double precision,jsonb,text)', 'd32f089f8a6750f099f8cfee63ac0f4d'),
  ('can_read_geolock_donation_image(text)', 'aaee6f68bf4084aa2a0bd3754950b863'),
  ('get_eligible_listing_constituents_v2(uuid)', 'd179dea87994e65d960f2fb8854f874f'),
  ('get_claimed_listing_constituents_v2(uuid)', '290c01184cd0f6e3138ea4dbf2464554'),
  ('get_my_hub_donation_detail(uuid,uuid)', '68ed3ebc4bfd41b39037ccee9eac1b03'),
  ('guard_donation_items()', '5a083d4ae35b8a9390ac478c6476484a'),
  ('require_donation_photo_before_commit()', 'e1af5b55edfbc9e867fbad499409eb59'),
  ('discover_eligible_listing_cards_v2()', 'af0c5398f184dd805d0cd78e36214589'),
  ('get_my_donation_dashboard_v3()', '13ddb11d30a04a872f908fa85107f4fa')),
nf AS (
  SELECT n.sig, to_regprocedure('public.' || n.sig) AS rp, n.body_md5, n.secdef FROM new_fn n),
nf_check AS (
  SELECT jsonb_agg(jsonb_build_object(
    'function', nf.sig, 'present', nf.rp IS NOT NULL,
    'body_matches', (SELECT md5(replace(p.prosrc, chr(13), '')) = nf.body_md5 FROM pg_proc p WHERE p.oid = nf.rp),
    'security_definer_ok', (SELECT p.prosecdef = nf.secdef FROM pg_proc p WHERE p.oid = nf.rp),
    'anon_execute', CASE WHEN nf.rp IS NOT NULL THEN has_function_privilege('anon', nf.rp, 'EXECUTE') END,
    'authenticated_execute', CASE WHEN nf.rp IS NOT NULL THEN has_function_privilege('authenticated', nf.rp, 'EXECUTE') END,
    'public_execute', (SELECT EXISTS (SELECT 1 FROM aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a WHERE a.grantee = 0)
                       FROM pg_proc p WHERE p.oid = nf.rp)) ORDER BY nf.sig) AS v FROM nf),
uc AS (
  SELECT jsonb_agg(jsonb_build_object('function', u.sig,
           'body_unchanged', (SELECT md5(replace(p.prosrc, chr(13), '')) = u.body_md5 FROM pg_proc p WHERE p.oid = to_regprocedure('public.' || u.sig)))
         ORDER BY u.sig) AS v FROM unchanged u),
schema_check AS (
  SELECT jsonb_build_object(
    'item_position_column', EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.donation_items'::regclass AND attname = 'item_position' AND NOT attisdropped),
    'item_id_column', EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.donation_images'::regclass AND attname = 'item_id' AND NOT attisdropped),
    'order_range', (SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid = 'public.donation_images'::regclass AND conname = 'donation_images_order_range'),
    'item_fk', (SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'donation_images_item_same_donation_fkey'),
    'position_check', (SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'donation_items_item_position_check'),
    'one_photo_per_item_index', (SELECT indexdef FROM pg_indexes WHERE schemaname = 'public' AND indexname = 'ux_donation_images_one_per_item'),
    'position_index', (SELECT indexdef FROM pg_indexes WHERE schemaname = 'public' AND indexname = 'ux_donation_items_position'),
    'get_donation_images_v2_absent', to_regprocedure('public.get_donation_images_v2(uuid)') IS NULL,
    'position_trigger_enabled', (SELECT tgenabled = 'O' FROM pg_trigger WHERE tgname = 'trg_items_position' AND tgrelid = 'public.donation_items'::regclass),
    'photo_trigger_still_enabled', (SELECT tgenabled = 'O' FROM pg_trigger WHERE tgname = 'donations_require_photo_at_commit')) AS v),
data_check AS (
  SELECT jsonb_build_object(
    'donations', (SELECT count(*) FROM public.donations),
    'items', (SELECT count(*) FROM public.donation_items),
    -- query_to_xml keeps this check runnable (reporting NULL) if the columns are absent.
    'items_with_position', CASE WHEN EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.donation_items'::regclass AND attname = 'item_position' AND NOT attisdropped)
      THEN (xpath('/row/c/text()', query_to_xml('SELECT count(*) AS c FROM public.donation_items WHERE item_position IS NOT NULL', false, true, '')))[1]::text::bigint END,
    'photos', (SELECT count(*) FROM public.donation_images),
    'photos_linked_to_item', CASE WHEN EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.donation_images'::regclass AND attname = 'item_id' AND NOT attisdropped)
      THEN (xpath('/row/c/text()', query_to_xml('SELECT count(*) AS c FROM public.donation_images WHERE item_id IS NOT NULL', false, true, '')))[1]::text::bigint END,
    'photos_without_storage_object', (SELECT count(*) FROM public.donation_images i WHERE NOT EXISTS (
       SELECT 1 FROM storage.objects o WHERE o.bucket_id = 'geolock-donation-images' AND o.name = i.storage_path)),
    'donations_without_photo', (SELECT count(*) FROM public.donations d WHERE NOT EXISTS (
       SELECT 1 FROM public.donation_images i WHERE i.donation_id = d.donation_id)),
    'bucket', (SELECT jsonb_build_object('public', public, 'file_size_limit', file_size_limit) FROM storage.buckets WHERE id = 'geolock-donation-images')) AS v)
SELECT jsonb_pretty(jsonb_build_object(
  'project_note', 'expect NEW KLSEL ppwmdsyoesvhgmqiaoxa',
  'checked_at', now(),
  'pass', coalesce((SELECT bool_and((e->>'present')::boolean AND (e->>'body_matches')::boolean AND (e->>'security_definer_ok')::boolean
                           AND NOT (e->>'anon_execute')::boolean AND NOT (e->>'public_execute')::boolean
                           AND ((e->>'authenticated_execute')::boolean = (e->>'function' <> 'geolock_assign_donation_item_position()')))
           FROM jsonb_array_elements((SELECT v FROM nf_check)) e)
          AND (SELECT bool_and((e->>'body_unchanged')::boolean) FROM jsonb_array_elements((SELECT v FROM uc)) e)
          AND (SELECT (v->>'item_position_column')::boolean AND (v->>'item_id_column')::boolean
                      AND (v->>'position_trigger_enabled')::boolean AND (v->>'get_donation_images_v2_absent')::boolean AND (v->>'photo_trigger_still_enabled')::boolean
                      AND v->>'order_range' = 'CHECK (((display_order >= 1) AND (display_order <= 30) AND (is_primary = (display_order = 1))))'
               FROM schema_check)
          AND (SELECT (v->>'photos_without_storage_object')::int = 0 AND (v->>'donations_without_photo')::int = 0 FROM data_check), false),
  'new_functions', (SELECT v FROM nf_check),
  'unchanged_functions', (SELECT v FROM uc),
  'schema', (SELECT v FROM schema_check),
  'data', (SELECT v FROM data_check))) AS klsel_item_photo_postdeploy;
ROLLBACK;
