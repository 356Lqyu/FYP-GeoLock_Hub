-- LOCAL TEST HARNESS ONLY. Runs AFTER 10_fixtures_before_migration.sql and the migration.
-- Each DO block is its own committed transaction, so the deferred commit-time triggers
-- (minimum photo, donation lifecycle) fire exactly as they do for a real RPC call.
SET client_min_messages = warning;
\set ON_ERROR_STOP 1

-- Shared helpers for this suite --------------------------------------------------------
CREATE FUNCTION test_harness.counts(p_request uuid) RETURNS jsonb LANGUAGE sql SECURITY DEFINER AS $$
  SELECT jsonb_build_object(
    'requests', (SELECT count(*) FROM public.donation_create_requests WHERE request_id = p_request),
    'donations', (SELECT count(*) FROM public.donations),
    'items', (SELECT count(*) FROM public.donation_items),
    'images', (SELECT count(*) FROM public.donation_images),
    'audits', (SELECT count(*) FROM public.audit_events),
    'objects', (SELECT count(*) FROM storage.objects)) $$;
-- Expect an error AND prove the failed call left nothing behind.
CREATE FUNCTION test_harness.expect_rejected(p_name text, p_user text, p_request uuid, p_items jsonb, p_pattern text,
  p_title text DEFAULT 'Item photo donation') RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_before jsonb; v_after jsonb; v_err text;
BEGIN
  PERFORM test_harness.admin(); v_before := test_harness.counts(p_request);
  IF p_user = 'anon' THEN PERFORM test_harness.act_anon(); ELSE PERFORM test_harness.act(p_user); END IF;
  v_err := test_harness.error_of(format('SELECT test_harness.create_items(%L::uuid, %L::jsonb, %L)', p_request, p_items, p_title));
  PERFORM test_harness.admin(); v_after := test_harness.counts(p_request);
  PERFORM test_harness.ok(p_name, v_err ~ p_pattern AND v_before = v_after,
    v_err || CASE WHEN v_before <> v_after THEN ' | LEFTOVER ' || v_before::text || ' -> ' || v_after::text ELSE '' END);
END $$;
-- Build n items; photographed positions get a freshly staged object.
CREATE FUNCTION test_harness.build_items(p_user text, p_request uuid, p_n integer, p_photo_positions integer[],
  p_unit numeric DEFAULT 0.5) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v jsonb := '[]'; i integer; v_path text;
BEGIN
  FOR i IN 1..p_n LOOP
    IF i = ANY(p_photo_positions) THEN
      v_path := test_harness.stage(p_user, p_request);
      v := v || jsonb_build_array(test_harness.item(i, 'Item ' || i, CASE WHEN i % 2 = 0 THEN 'Clothing' ELSE 'Food' END,
                                                    1 + (i % 3), p_unit, test_harness.photo(v_path)));
    ELSE
      v := v || jsonb_build_array(test_harness.item(i, 'Item ' || i, CASE WHEN i % 2 = 0 THEN 'Clothing' ELSE 'Food' END,
                                                    1 + (i % 3), p_unit));
    END IF;
  END LOOP;
  RETURN v;
END $$;
CREATE FUNCTION test_harness.reversed(p jsonb) RETURNS jsonb LANGUAGE sql IMMUTABLE AS
  $$ SELECT coalesce(jsonb_agg(e ORDER BY o DESC), '[]') FROM jsonb_array_elements(p) WITH ORDINALITY x(e, o) $$;
-- Full structural check of one donation created by the new RPC.
CREATE FUNCTION test_harness.check_created(p_name text, p_donation uuid, p_request uuid, p_items jsonb) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE v_n integer := jsonb_array_length(p_items); v_k integer; v_bad text;
BEGIN
  SELECT count(*) INTO v_k FROM jsonb_array_elements(p_items) e WHERE jsonb_typeof(e->'photo') = 'object';
  PERFORM test_harness.ok(p_name || ': item count and positions 1..n',
    (SELECT count(*) = v_n AND min(item_position) = 1 AND max(item_position) = v_n AND count(DISTINCT item_position) = v_n
       FROM public.donation_items WHERE donation_id = p_donation));
  SELECT string_agg(e->>'item_position', ',') INTO v_bad FROM jsonb_array_elements(p_items) e
   WHERE NOT EXISTS (SELECT 1 FROM public.donation_items i WHERE i.donation_id = p_donation
       AND i.item_position = (e->>'item_position')::int AND i.item_name = e->>'item_name'
       AND i.quantity = (e->>'quantity')::int AND i.category_id = (e->>'category_id')::uuid);
  PERFORM test_harness.ok(p_name || ': each position holds the item sent for it', v_bad IS NULL, v_bad);
  PERFORM test_harness.ok(p_name || ': one image per photographed item, none for others',
    (SELECT count(*) FROM public.donation_images WHERE donation_id = p_donation) = v_k
    AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_items) e
      JOIN public.donation_items i ON i.donation_id = p_donation AND i.item_position = (e->>'item_position')::int
      LEFT JOIN public.donation_images img ON img.item_id = i.item_id
      WHERE coalesce(jsonb_typeof(e->'photo') = 'object', false) IS DISTINCT FROM (img.image_id IS NOT NULL)
         OR (img.image_id IS NOT NULL AND img.storage_path <> e->'photo'->>'storage_path')));
  PERFORM test_harness.ok(p_name || ': display_order 1..k follows item position; only first is primary',
    NOT EXISTS (SELECT 1 FROM (
       SELECT img.display_order, img.is_primary, row_number() OVER (ORDER BY i.item_position) AS rn
       FROM public.donation_images img JOIN public.donation_items i ON i.item_id = img.item_id
       WHERE img.donation_id = p_donation) x
     WHERE x.display_order <> x.rn OR x.is_primary <> (x.rn = 1)));
  PERFORM test_harness.ok(p_name || ': request row linked',
    (SELECT donation_id FROM public.donation_create_requests WHERE request_id = p_request) = p_donation);
  PERFORM test_harness.ok(p_name || ': audits CREATE_DONATION + DONATION_PHOTOS_ATTACHED once each',
    (SELECT count(*) FROM public.audit_events WHERE entity_id = p_donation AND event_type = 'CREATE_DONATION') = 1
    AND (SELECT count(*) FROM public.audit_events WHERE entity_id = p_donation AND event_type = 'DONATION_PHOTOS_ATTACHED'
         AND details = jsonb_build_object('request_id', p_request, 'photo_count', v_k, 'item_count', v_n, 'photo_mode', 'ITEM_LEVEL')
         AND requested_state = 'ITEM_PHOTOS' AND outcome = 'SUCCESS' AND actor_role = 'DONOR') = 1);
END $$;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA test_harness TO anon, authenticated;

-- A. Nothing existing changed ------------------------------------------------------------
DO $a$
DECLARE v_diff text;
BEGIN
  SELECT string_agg(b.key, '; ') INTO v_diff FROM test_harness.before_catalog b
  LEFT JOIN (
    SELECT 'function_acl:' || p.oid::regprocedure::text AS key, coalesce(p.proacl::text, 'default') AS value
      FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
    UNION ALL SELECT 'function_body:' || p.oid::regprocedure::text, md5(replace(p.prosrc, chr(13), ''))
      FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
    UNION ALL SELECT 'policy:' || schemaname || '.' || tablename || '.' || policyname,
         md5(concat_ws('|', permissive, roles::text, cmd, qual, with_check)) FROM pg_policies WHERE schemaname IN ('public','storage')
    UNION ALL SELECT 'table_acl:' || c.oid::regclass::text, coalesce(c.relacl::text, 'default')
      FROM pg_class c WHERE c.relnamespace IN ('public'::regnamespace, 'storage'::regnamespace) AND c.relkind = 'r'
    UNION ALL SELECT 'bucket:' || id, concat_ws('|', public, file_size_limit, allowed_mime_types::text) FROM storage.buckets
  ) a USING (key)
  WHERE a.value IS DISTINCT FROM b.value;
  PERFORM test_harness.ok('A1 every pre-existing function body, function grant, RLS policy, table grant and bucket unchanged',
    v_diff IS NULL, v_diff);
  PERFORM test_harness.ok('A1b pre-existing function count unchanged; exactly 6 functions added, get_donation_images_v2 not created',
    (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace)
      = (SELECT count(*) FROM test_harness.before_catalog WHERE key LIKE 'function_body:%') + 6
    AND to_regprocedure('public.get_donation_images_v2(uuid)') IS NULL);
  PERFORM test_harness.ok('A2 legacy photos byte-identical and not linked to any item',
    (SELECT count(*) FROM test_harness.before_images) = 4
    AND NOT EXISTS (SELECT image_id, donation_id, owner_user_id, storage_path, content_type, size_bytes, is_primary, display_order, created_at
                      FROM test_harness.before_images
                    EXCEPT SELECT image_id, donation_id, owner_user_id, storage_path, content_type, size_bytes, is_primary, display_order, created_at
                      FROM public.donation_images)
    AND NOT EXISTS (SELECT 1 FROM public.donation_images i JOIN test_harness.before_images b USING (image_id) WHERE i.item_id IS NOT NULL));
  PERFORM test_harness.ok('A3 legacy items unchanged; their position stays NULL (no backfill)',
    NOT EXISTS (SELECT item_id, donation_id, category_id, item_name, description, quantity, unit_label, unit_weight_kg, item_condition, created_at
                  FROM test_harness.before_items
                EXCEPT SELECT item_id, donation_id, category_id, item_name, description, quantity, unit_label, unit_weight_kg, item_condition, created_at
                  FROM public.donation_items)
    AND NOT EXISTS (SELECT 1 FROM public.donation_items i JOIN test_harness.before_items b USING (item_id) WHERE i.item_position IS NOT NULL));
END $a$;
DO $a4$
DECLARE v1 jsonb; v2 jsonb; v3 jsonb; v4 jsonb;
BEGIN
  PERFORM test_harness.act('donor_legacy');
  v1 := test_harness.rows_json('SELECT * FROM public.get_donation_images(' || quote_literal(test_harness.fact('legacy_direct')) || ')');
  v2 := test_harness.rows_json('SELECT * FROM public.get_my_donation_dashboard_v3()');
  v3 := test_harness.rows_json('SELECT * FROM public.get_my_donation_dashboard_v2()');
  v4 := to_jsonb(public.get_my_donation_detail(test_harness.fact('legacy_direct')::uuid));
  PERFORM test_harness.admin();
  PERFORM test_harness.ok('A4 legacy gallery get_donation_images output identical',
    v1 = (SELECT output FROM test_harness.before_reader_output WHERE reader = 'get_donation_images') AND jsonb_array_length(v1) = 3);
  PERFORM test_harness.ok('A4 legacy dashboard v3 output identical', v2 = (SELECT output FROM test_harness.before_reader_output WHERE reader = 'get_my_donation_dashboard_v3'));
  PERFORM test_harness.ok('A4 legacy dashboard v2 output identical', v3 = (SELECT output FROM test_harness.before_reader_output WHERE reader = 'get_my_donation_dashboard_v2'));
  PERFORM test_harness.ok('A4 legacy get_my_donation_detail output identical', v4 = (SELECT output FROM test_harness.before_reader_output WHERE reader = 'get_my_donation_detail'));
END $a4$;
DO $a5$
DECLARE v jsonb;
BEGIN
  PERFORM test_harness.act('donor_legacy');
  v := test_harness.rows_json('SELECT * FROM public.get_my_donation_items(' || quote_literal(test_harness.fact('legacy_direct')) || ')');
  PERFORM test_harness.admin();
  PERFORM test_harness.ok('A5 legacy donation via get_my_donation_items: both items, no item photo, no position (Donate Again copies items only)',
    jsonb_array_length(v) = 2
    AND (SELECT bool_and(e->'photo_path' = 'null' AND e->'photo_image_id' = 'null' AND e->'item_position' = 'null') FROM jsonb_array_elements(v) e), v::text);
END $a5$;
DO $a6$
DECLARE r record; v_bad text := '';
BEGIN
  FOR r IN SELECT p.oid::regprocedure AS f FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
             AND p.proname IN ('create_donation_with_item_photos','get_my_donation_items',
                               'get_my_hub_donation_items','get_eligible_listing_items','get_claimed_listing_items',
                               'geolock_assign_donation_item_position') LOOP
    IF has_function_privilege('anon', r.f, 'EXECUTE') THEN v_bad := v_bad || 'anon:' || r.f || ' '; END IF;
    IF EXISTS (SELECT 1 FROM pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
               WHERE p.oid = r.f AND a.grantee = 0) THEN v_bad := v_bad || 'PUBLIC:' || r.f || ' '; END IF;
  END LOOP;
  PERFORM test_harness.ok('A6 no new function executable by anon or PUBLIC', v_bad = '', v_bad);
  PERFORM test_harness.ok('A6b trigger function not executable by authenticated',
    NOT has_function_privilege('authenticated', 'public.geolock_assign_donation_item_position()'::regprocedure, 'EXECUTE'));
  PERFORM test_harness.ok('A6c new RPC/readers are SECURITY DEFINER with pinned search_path',
    (SELECT bool_and(p.prosecdef AND p.proconfig::text LIKE '%search_path=pg_catalog%') FROM pg_proc p
      WHERE p.pronamespace = 'public'::regnamespace AND p.proname IN ('create_donation_with_item_photos',
        'get_my_donation_items','get_my_hub_donation_items','get_eligible_listing_items','get_claimed_listing_items')));
END $a6$;

-- B. Creation with 1, 3, 5 and 30 items (payloads sent in REVERSED array order) ------------
DO $b$
DECLARE r uuid; v_items jsonb; d uuid; c record;
BEGIN
  FOR c IN SELECT * FROM (VALUES (1, ARRAY[1], 'B1 one item'), (3, ARRAY[2,3], 'B3 three items, item 1 unphotographed'),
                                 (5, ARRAY[1,3,5], 'B5 five items, alternate photos'),
                                 (30, (SELECT array_agg(g) FROM generate_series(1,30) g), 'B30 thirty items, thirty photos'),
                                 (30, ARRAY[30], 'B30b thirty items, only the last photographed')) v(n, ph, label) LOOP
    r := gen_random_uuid();
    v_items := test_harness.build_items('donor1', r, c.n, c.ph);
    PERFORM test_harness.act('donor1');
    d := test_harness.create_items(r, test_harness.reversed(v_items), c.label);
    PERFORM test_harness.admin();
    PERFORM test_harness.set_fact(c.label, d::text);
    PERFORM test_harness.set_fact(c.label || ':request', r::text);
    PERFORM test_harness.set_fact(c.label || ':items', v_items::text);
  END LOOP;
END $b$;
-- Checks run in a later transaction, i.e. after the commit-time triggers accepted the donations.
DO $bcheck$
DECLARE c text;
BEGIN
  FOREACH c IN ARRAY ARRAY['B1 one item','B3 three items, item 1 unphotographed','B5 five items, alternate photos',
                           'B30 thirty items, thirty photos','B30b thirty items, only the last photographed'] LOOP
    PERFORM test_harness.check_created(c, test_harness.fact(c)::uuid, test_harness.fact(c || ':request')::uuid,
                                       test_harness.fact(c || ':items')::jsonb);
  END LOOP;
  PERFORM test_harness.ok('B30 thirty photos allowed (display_order up to 30)',
    (SELECT max(display_order) FROM public.donation_images WHERE donation_id = test_harness.fact('B30 thirty items, thirty photos')::uuid) = 30);
END $bcheck$;

-- C. Rejections: each leaves no request row, donation, item, image or audit behind --------
DO $c$
DECLARE r uuid; v jsonb; p1 text; p2 text; v_other uuid := gen_random_uuid();
BEGIN
  r := gen_random_uuid();
  PERFORM test_harness.expect_rejected('C01 31 items rejected', 'donor1', r, test_harness.build_items('donor1', r, 31, ARRAY[1]), '^ONE_TO_THIRTY_ITEMS_REQUIRED$');
  PERFORM test_harness.expect_rejected('C02 zero items rejected', 'donor1', gen_random_uuid(), '[]', '^ONE_TO_THIRTY_ITEMS_REQUIRED$');
  PERFORM test_harness.expect_rejected('C03 items not an array', 'donor1', gen_random_uuid(), '{"a":1}', '^ONE_TO_THIRTY_ITEMS_REQUIRED$');
  r := gen_random_uuid();
  PERFORM test_harness.expect_rejected('C04 no photographed item rejected', 'donor1', r, test_harness.build_items('donor1', r, 3, ARRAY[]::int[]), '^AT_LEAST_ONE_ITEM_PHOTO_REQUIRED$');
  r := gen_random_uuid(); p1 := test_harness.stage('donor1', r); p2 := test_harness.stage('donor1', r);
  v := jsonb_build_array(test_harness.item(1, 'A', 'Food', 1, 1) || jsonb_build_object('photo', jsonb_build_array(test_harness.photo(p1), test_harness.photo(p2))));
  PERFORM test_harness.expect_rejected('C05 two photos for one item (array) rejected', 'donor1', r, v, '^ONE_PHOTO_PER_ITEM$');
  v := jsonb_build_array(test_harness.item(1, 'A', 'Food', 1, 1) || '{"photo":"x"}');
  PERFORM test_harness.expect_rejected('C06 photo given as a string rejected', 'donor1', r, v, '^ONE_PHOTO_PER_ITEM$');
  v := jsonb_build_array(test_harness.item(1, 'A', 'Food', 1, 1, test_harness.photo(p1)), test_harness.item(2, 'B', 'Food', 1, 1, test_harness.photo(p1)));
  PERFORM test_harness.expect_rejected('C07 same photo on two items rejected', 'donor1', r, v, '^DUPLICATE_ITEM_PHOTO_2$');
  -- Positions
  v := jsonb_build_array(test_harness.item(1, 'A', 'Food', 1, 1, test_harness.photo(p1)) - 'item_position');
  PERFORM test_harness.expect_rejected('C08 missing item_position rejected', 'donor1', r, v, '^INVALID_ITEM_POSITIONS$');
  v := jsonb_build_array(test_harness.item(1, 'A', 'Food', 1, 1, test_harness.photo(p1)), test_harness.item(1, 'B', 'Food', 1, 1));
  PERFORM test_harness.expect_rejected('C09 duplicate positions rejected', 'donor1', r, v, '^INVALID_ITEM_POSITIONS$');
  v := jsonb_build_array(test_harness.item(1, 'A', 'Food', 1, 1, test_harness.photo(p1)), test_harness.item(3, 'B', 'Food', 1, 1));
  PERFORM test_harness.expect_rejected('C10 gap in positions rejected', 'donor1', r, v, '^INVALID_ITEM_POSITIONS$');
  v := jsonb_build_array(test_harness.item(0, 'A', 'Food', 1, 1, test_harness.photo(p1)));
  PERFORM test_harness.expect_rejected('C11 position 0 rejected', 'donor1', r, v, '^INVALID_ITEM_POSITIONS$');
  v := jsonb_build_array(jsonb_set(test_harness.item(1, 'A', 'Food', 1, 1, test_harness.photo(p1)), '{item_position}', '"1"'));
  PERFORM test_harness.expect_rejected('C12 position as string rejected', 'donor1', r, v, '^INVALID_ITEM_POSITIONS$');
  v := jsonb_build_array(jsonb_set(test_harness.item(1, 'A', 'Food', 1, 1, test_harness.photo(p1)), '{item_position}', '1.5'));
  PERFORM test_harness.expect_rejected('C13 fractional position rejected', 'donor1', r, v, '^INVALID_ITEM_POSITIONS$');
  -- Paths, types, sizes, Storage metadata
  v := jsonb_build_array(test_harness.item(1, 'A', 'Food', 1, 1, test_harness.photo(test_harness.stage('donor2', r))));
  PERFORM test_harness.expect_rejected('C14 another user''s upload rejected', 'donor1', r, v, '^INVALID_ITEM_PHOTO_1$');
  v := jsonb_build_array(test_harness.item(1, 'A', 'Food', 1, 1, test_harness.photo(test_harness.stage('donor1', v_other))));
  PERFORM test_harness.expect_rejected('C15 upload from a different request rejected', 'donor1', r, v, '^INVALID_ITEM_PHOTO_1$');
  v := jsonb_build_array(test_harness.item(1, 'A', 'Food', 1, 1, test_harness.photo(test_harness.uid('donor1') || '/pending/' || r || '/../x.jpg')));
  PERFORM test_harness.expect_rejected('C16 path traversal rejected', 'donor1', r, v, '^INVALID_ITEM_PHOTO_1$');
  v := jsonb_build_array(test_harness.item(1, 'A', 'Food', 1, 1, test_harness.photo(test_harness.stage('donor1', r, 'gif', 1234, 'image/gif'), 1234, 'image/gif')));
  PERFORM test_harness.expect_rejected('C17 gif rejected', 'donor1', r, v, '^INVALID_ITEM_PHOTO_1$');
  v := jsonb_build_array(test_harness.item(1, 'A', 'Food', 1, 1, test_harness.photo(test_harness.stage('donor1', r, 'png', 1234, 'image/jpeg'))));
  PERFORM test_harness.expect_rejected('C18 extension/content-type mismatch rejected', 'donor1', r, v, '^INVALID_ITEM_PHOTO_1$');
  v := jsonb_build_array(test_harness.item(1, 'A', 'Food', 1, 1, test_harness.photo(test_harness.stage('donor1', r, 'jpg', 5242881), 5242881)));
  PERFORM test_harness.expect_rejected('C19 over 5 MB rejected', 'donor1', r, v, '^INVALID_ITEM_PHOTO_1$');
  v := jsonb_build_array(test_harness.item(1, 'A', 'Food', 1, 1, test_harness.photo(p1, 0)));
  PERFORM test_harness.expect_rejected('C20 zero bytes rejected', 'donor1', r, v, '^INVALID_ITEM_PHOTO_1$');
  v := jsonb_build_array(test_harness.item(1, 'A', 'Food', 1, 1, test_harness.photo(p1, 999)));
  PERFORM test_harness.expect_rejected('C21 size differs from Storage metadata rejected', 'donor1', r, v, '^STAGED_ITEM_PHOTO_MISSING_OR_MISMATCHED_1$');
  v := jsonb_build_array(test_harness.item(1, 'A', 'Food', 1, 1, test_harness.photo(test_harness.uid('donor1') || '/pending/' || r || '/' || gen_random_uuid() || '.jpg')));
  PERFORM test_harness.expect_rejected('C22 photo never uploaded rejected', 'donor1', r, v, '^STAGED_ITEM_PHOTO_MISSING_OR_MISMATCHED_1$');
  v := jsonb_build_array(test_harness.item(1, 'A', 'Food', 1, 1, test_harness.photo(p1) || '{"item_id":"00000000-0000-0000-0000-000000000000"}'));
  PERFORM test_harness.expect_rejected('C23 extra photo key (client-chosen item_id) rejected', 'donor1', r, v, '^INVALID_ITEM_PHOTO_1$');
  v := jsonb_build_array(test_harness.item(1, 'A', 'Food', 1, 1, jsonb_build_object('storage_path', p1, 'content_type', 'image/jpeg', 'size_bytes', '1234')));
  PERFORM test_harness.expect_rejected('C24 size as string rejected', 'donor1', r, v, '^INVALID_ITEM_PHOTO_1$');
  -- Second photo in position order is the one reported
  v := jsonb_build_array(test_harness.item(1, 'A', 'Food', 1, 1, test_harness.photo(p1)), test_harness.item(2, 'B', 'Food', 1, 1, test_harness.photo(p2, 1)));
  PERFORM test_harness.expect_rejected('C25 error names the failing position', 'donor1', r, v, '^STAGED_ITEM_PHOTO_MISSING_OR_MISMATCHED_2$');
  -- Errors raised by the UNCHANGED create_and_validate_donation also roll everything back
  v := jsonb_build_array(test_harness.item(1, 'A', 'Food', 0, 1, test_harness.photo(p1)));
  PERFORM test_harness.expect_rejected('C26 invalid quantity (raised by create_and_validate_donation) rolls back request row', 'donor1', r, v, '^INVALID_DONATION_ITEM$');
  v := jsonb_build_array(test_harness.item(1, 'A', 'Food', 1, 1, test_harness.photo(p1)));
  PERFORM test_harness.expect_rejected('C27 blank title rejected', 'donor1', r, v, '^INVALID_DONATION_TITLE$', '  ');
  PERFORM test_harness.expect_rejected('C28 NGO caller rejected (DONOR_ONLY from unchanged validator)', 'ngo_eligible', r,
    jsonb_build_array(test_harness.item(1, 'A', 'Food', 1, 1, test_harness.photo(test_harness.stage('ngo_eligible', r)))), 'DONOR_ONLY');
  PERFORM test_harness.expect_rejected('C29 signed-in user with no profile rejected', 'no_profile', r,
    jsonb_build_array(test_harness.item(1, 'A', 'Food', 1, 1, test_harness.photo(test_harness.stage('no_profile', r)))), 'DONOR_ONLY');
  PERFORM test_harness.expect_rejected('C30 anon cannot execute the RPC', 'anon', r, v, 'permission denied for function create_donation_with_item_photos');
END $c$;
-- C31: a NULL request ID
DO $c31$
BEGIN
  PERFORM test_harness.act('donor1');
  PERFORM test_harness.expect_error('C31 request ID required', 'SELECT test_harness.create_items(NULL, ''[]'')', '^REQUEST_ID_REQUIRED$');
  PERFORM test_harness.admin();
END $c31$;

-- D. Idempotency and retry ----------------------------------------------------------------
DO $d$
DECLARE r uuid := gen_random_uuid(); v jsonb; d1 uuid; d2 uuid; d3 uuid; v_before jsonb;
BEGIN
  v := test_harness.build_items('donor1', r, 4, ARRAY[2,4]);
  -- A failed first attempt (bad size) must not consume the request ID
  PERFORM test_harness.expect_rejected('D1 failed attempt rolls back', 'donor1', r,
    jsonb_set(v, '{1,photo,size_bytes}', '77'), '^STAGED_ITEM_PHOTO_MISSING_OR_MISMATCHED_2$');
  PERFORM test_harness.act('donor1');
  d1 := test_harness.create_items(r, v);
  PERFORM test_harness.admin();
  PERFORM test_harness.set_fact('D:donation', d1::text); PERFORM test_harness.set_fact('D:request', r::text);
  PERFORM test_harness.set_fact('D:items', v::text);
  v_before := test_harness.counts(r);
  PERFORM test_harness.act('donor1');
  d2 := test_harness.create_items(r, v);
  d3 := test_harness.create_items(r, test_harness.reversed(v));
  PERFORM test_harness.admin();
  PERFORM test_harness.ok('D2 identical retry returns the same donation and writes nothing',
    d1 = d2 AND test_harness.counts(r) = v_before);
  PERFORM test_harness.ok('D3 retry with the same items in a different array order is the same request', d1 = d3);
END $d$;
DO $d4$
DECLARE r uuid := test_harness.fact('D:request')::uuid; v jsonb := test_harness.fact('D:items')::jsonb; lr uuid; lp text;
BEGIN
  PERFORM test_harness.expect_rejected('D4 same request ID, different payload', 'donor1', r,
    jsonb_set(v, '{0,item_name}', '"Changed"'), '^IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD$');
  PERFORM test_harness.expect_rejected('D5 same request ID, different title', 'donor1', r, v,
    '^IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD$', 'Another title');
  PERFORM test_harness.expect_rejected('D6 another donor cannot replay a request ID', 'donor2', r, v,
    '^IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD$');
  -- Legacy request ID reused on the new RPC, and the reverse
  lr := test_harness.fact('legacy_direct_request')::uuid;
  PERFORM test_harness.expect_rejected('D7 legacy-RPC request ID cannot be replayed on the new RPC', 'donor_legacy', lr,
    jsonb_build_array(test_harness.item(1, 'Rice', 'Food', 2, 5.5, test_harness.photo(test_harness.stage('donor_legacy', lr)))),
    '^IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD$');
  PERFORM test_harness.act('donor1');
  PERFORM test_harness.expect_error('D8 new-RPC request ID cannot be replayed on the legacy RPC',
    format('SELECT test_harness.create_legacy(%L::uuid, %L::jsonb, %L::jsonb)', r,
      jsonb_build_array(test_harness.legacy_item('Item 1', 'Food', 2, 0.5)),
      jsonb_build_array(v->1->'photo')), '^IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD$');
  PERFORM test_harness.admin();
END $d4$;
DO $dcheck$
BEGIN
  PERFORM test_harness.check_created('D idempotent donation', test_harness.fact('D:donation')::uuid,
    test_harness.fact('D:request')::uuid, test_harness.fact('D:items')::jsonb);
END $dcheck$;

-- E. Constraints hold even for writes that bypass the RPC (harness superuser) --------------
DO $e$
DECLARE d_a uuid := test_harness.fact('B3 three items, item 1 unphotographed')::uuid;
        d_b uuid := test_harness.fact('B5 five items, alternate photos')::uuid;
        v_item_b uuid; v_item_a1 uuid; v_item_a2 uuid;
BEGIN
  SELECT item_id INTO v_item_b FROM public.donation_items WHERE donation_id = d_b AND item_position = 2;
  SELECT item_id INTO v_item_a1 FROM public.donation_items WHERE donation_id = d_a AND item_position = 1;
  SELECT item_id INTO v_item_a2 FROM public.donation_items WHERE donation_id = d_a AND item_position = 2;
  PERFORM test_harness.expect_error('E1 photo cannot point at another donation''s item (composite FK)',
    format('INSERT INTO public.donation_images(donation_id, owner_user_id, storage_path, content_type, size_bytes, is_primary, display_order, item_id)
            VALUES (%L, %L, %L, ''image/jpeg'', 1, false, 9, %L)', d_a, test_harness.uid('donor1'), 'x/e1.jpg', v_item_b),
    'donation_images_item_same_donation_fkey');
  PERFORM test_harness.expect_error('E2 an item cannot have two photos',
    format('INSERT INTO public.donation_images(donation_id, owner_user_id, storage_path, content_type, size_bytes, is_primary, display_order, item_id)
            VALUES (%L, %L, %L, ''image/jpeg'', 1, false, 9, %L)', d_a, test_harness.uid('donor1'), 'x/e2.jpg', v_item_a2),
    'ux_donation_images_one_per_item');
  PERFORM test_harness.expect_error('E3 display_order above 30 rejected',
    format('INSERT INTO public.donation_images(donation_id, owner_user_id, storage_path, content_type, size_bytes, is_primary, display_order, item_id)
            VALUES (%L, %L, %L, ''image/jpeg'', 1, false, 31, %L)', d_a, test_harness.uid('donor1'), 'x/e3.jpg', v_item_a1),
    'donation_images_order_range');
  PERFORM test_harness.expect_error('E4 two primary photos impossible (display_order 1 is the only primary)',
    format('INSERT INTO public.donation_images(donation_id, owner_user_id, storage_path, content_type, size_bytes, is_primary, display_order, item_id)
            VALUES (%L, %L, %L, ''image/jpeg'', 1, true, 2, %L)', d_a, test_harness.uid('donor1'), 'x/e4.jpg', v_item_a1),
    'donation_images_order_range');
  -- E5/E6 bypass the existing item-freeze trigger (session_replication_role = replica) so that the
  -- new index and CHECK themselves are exercised; both are enforced regardless of that setting.
  SET LOCAL session_replication_role = replica;
  PERFORM test_harness.expect_error('E5 duplicate item position in one donation rejected (unique index)',
    format('INSERT INTO public.donation_items(donation_id, category_id, item_name, quantity, unit_label, unit_weight_kg, item_condition, item_position)
            VALUES (%L, %L, ''dup'', 1, ''piece'', 1, ''GOOD'', 1)', d_a, test_harness.cat('Food')),
    'ux_donation_items_position');
  PERFORM test_harness.expect_error('E6 position below 1 rejected (CHECK)',
    'UPDATE public.donation_items SET item_position = 0 WHERE item_id = ' || quote_literal(v_item_a1), 'donation_items_item_position_check');
  SET LOCAL session_replication_role = origin;
  PERFORM test_harness.expect_error('E7 items of a classified donation stay frozen (existing guard), so a photographed item cannot be deleted',
    'DELETE FROM public.donation_items WHERE item_id = ' || quote_literal(v_item_a2), 'DONATION_ITEMS_FROZEN');
  PERFORM test_harness.ok('E7b item FK is ON DELETE NO ACTION / ON UPDATE NO ACTION (never cascades photos away)',
    (SELECT confdeltype = 'a' AND confupdtype = 'a' FROM pg_constraint WHERE conname = 'donation_images_item_same_donation_fkey'));
END $e$;
DO $e8$
DECLARE v_rows bigint;
BEGIN
  PERFORM test_harness.act('donor1');
  PERFORM test_harness.expect_error('E8 a donor cannot insert photos directly (RLS), only through the RPC',
    format('INSERT INTO public.donation_images(donation_id, owner_user_id, storage_path, content_type, size_bytes, is_primary, display_order)
            VALUES (%L, %L, ''x/e8.jpg'', ''image/jpeg'', 1, false, 9)', test_harness.fact('B1 one item'), test_harness.uid('donor1')),
    '(row-level security|permission denied)');
  -- Counted with GET DIAGNOSTICS: RLS has no UPDATE/DELETE policy, so direct writes match no rows.
  EXECUTE 'UPDATE public.donation_images SET item_id = NULL WHERE donation_id = ' || quote_literal(test_harness.fact('B1 one item'));
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  PERFORM test_harness.ok('E9 a donor cannot re-link or unlink a photo directly (RLS: 0 rows updated)', v_rows = 0, v_rows::text);
  EXECUTE 'DELETE FROM public.donation_images WHERE donation_id = ' || quote_literal(test_harness.fact('B1 one item'));
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  PERFORM test_harness.ok('E10 a donor cannot delete a photo directly (RLS: 0 rows deleted)', v_rows = 0, v_rows::text);
  PERFORM test_harness.admin();
  PERFORM test_harness.ok('E9b photo links unchanged after the attempted direct update',
    (SELECT count(*) FROM public.donation_images WHERE donation_id = test_harness.fact('B1 one item')::uuid AND item_id IS NOT NULL) = 1);
END $e8$;

-- F. Classification and audit equivalence with the legacy RPC ------------------------------
DO $f$
DECLARE c record; r_new uuid; r_old uuid; d_new uuid; d_old uuid; v_items jsonb; v_legacy jsonb; v_photo text; v_lphoto text;
BEGIN
  FOR c IN SELECT * FROM (VALUES ('F1 9.999 kg', 3, 3.333), ('F2 exactly 10.000 kg', 4, 2.5), ('F3 10.001 kg', 1, 10.001),
                                 ('F4 heavy 30 items', 30, 1.25)) v(label, n, unit) LOOP
    r_new := gen_random_uuid(); r_old := gen_random_uuid();
    v_photo := test_harness.stage('donor2', r_new); v_lphoto := test_harness.stage('donor2', r_old);
    SELECT jsonb_agg(test_harness.item(g, 'Thing ' || g, 'Household Essentials', CASE WHEN c.n = 3 THEN 1 ELSE 1 END, c.unit,
                       CASE WHEN g = 1 THEN test_harness.photo(v_photo) END) ORDER BY g),
           jsonb_agg(test_harness.legacy_item('Thing ' || g, 'Household Essentials', 1, c.unit) ORDER BY g)
      INTO v_items, v_legacy FROM generate_series(1, c.n) g;
    PERFORM test_harness.act('donor2');
    d_new := test_harness.create_items(r_new, v_items, c.label);
    d_old := test_harness.create_legacy(r_old, v_legacy, jsonb_build_array(test_harness.legacy_photo(v_lphoto)), c.label);
    PERFORM test_harness.admin();
    PERFORM test_harness.set_fact(c.label || ':new', d_new::text); PERFORM test_harness.set_fact(c.label || ':old', d_old::text);
  END LOOP;
END $f$;
DO $fcheck$
DECLARE c text; d_new uuid; d_old uuid; s_new jsonb; s_old jsonb;
BEGIN
  FOREACH c IN ARRAY ARRAY['F1 9.999 kg', 'F2 exactly 10.000 kg', 'F3 10.001 kg', 'F4 heavy 30 items'] LOOP
    d_new := test_harness.fact(c || ':new')::uuid; d_old := test_harness.fact(c || ':old')::uuid;
    SELECT jsonb_build_object('status', d.donation_status, 'path', d.collection_path, 'weight', d.total_weight_kg,
             'listing', (SELECT jsonb_agg(jsonb_build_object('type', l.source_type, 'status', l.listing_status)) FROM public.listings l WHERE l.donation_id = d.donation_id),
             'create_audit', (SELECT jsonb_agg(jsonb_build_object('role', a.actor_role, 'req', a.requested_state, 'res', a.resulting_state,
                                'outcome', a.outcome, 'details', a.details, 'cfg', a.configuration_version))
                              FROM public.audit_events a WHERE a.entity_id = d.donation_id AND a.event_type = 'CREATE_DONATION'),
             'items', (SELECT jsonb_agg(jsonb_build_object('n', i.item_name, 'q', i.quantity, 'w', i.unit_weight_kg, 'c', i.category_id) ORDER BY i.item_name)
                       FROM public.donation_items i WHERE i.donation_id = d.donation_id))
      INTO s_new FROM public.donations d WHERE d.donation_id = d_new;
    SELECT jsonb_build_object('status', d.donation_status, 'path', d.collection_path, 'weight', d.total_weight_kg,
             'listing', (SELECT jsonb_agg(jsonb_build_object('type', l.source_type, 'status', l.listing_status)) FROM public.listings l WHERE l.donation_id = d.donation_id),
             'create_audit', (SELECT jsonb_agg(jsonb_build_object('role', a.actor_role, 'req', a.requested_state, 'res', a.resulting_state,
                                'outcome', a.outcome, 'details', a.details, 'cfg', a.configuration_version))
                              FROM public.audit_events a WHERE a.entity_id = d.donation_id AND a.event_type = 'CREATE_DONATION'),
             'items', (SELECT jsonb_agg(jsonb_build_object('n', i.item_name, 'q', i.quantity, 'w', i.unit_weight_kg, 'c', i.category_id) ORDER BY i.item_name)
                       FROM public.donation_items i WHERE i.donation_id = d.donation_id))
      INTO s_old FROM public.donations d WHERE d.donation_id = d_old;
    PERFORM test_harness.ok(c || ': classification, listing, weight, items and CREATE_DONATION audit identical to legacy RPC',
      s_new = s_old, 'new=' || s_new::text || ' old=' || s_old::text);
    PERFORM test_harness.set_fact(c || ':summary', (s_new - 'items' - 'create_audit')::text);
  END LOOP;
  PERFORM test_harness.ok('F1 below 10 kg -> HUB_COLLECTION, no listing',
    test_harness.fact('F1 9.999 kg:summary')::jsonb @> '{"path":"HUB_COLLECTION","status":"SUBMITTED","listing":null}');
  PERFORM test_harness.ok('F2 exactly 10 kg -> DIRECT_PICKUP with AVAILABLE listing',
    test_harness.fact('F2 exactly 10.000 kg:summary')::jsonb @> '{"path":"DIRECT_PICKUP","status":"AVAILABLE","listing":[{"type":"DIRECT_DONATION","status":"AVAILABLE"}]}');
  PERFORM test_harness.ok('F5 legacy RPC still works after migration; its items now get positions 1..n; photos not item-linked',
    (SELECT count(*) = 30 AND min(item_position) = 1 AND max(item_position) = 30 FROM public.donation_items
       WHERE donation_id = test_harness.fact('F4 heavy 30 items:old')::uuid)
    AND NOT EXISTS (SELECT 1 FROM public.donation_images WHERE donation_id = test_harness.fact('F4 heavy 30 items:old')::uuid AND item_id IS NOT NULL));
END $fcheck$;
DO $f6$
DECLARE r uuid := gen_random_uuid(); v jsonb := '[]';
BEGIN
  FOR i IN 1..4 LOOP v := v || jsonb_build_array(test_harness.legacy_photo(test_harness.stage('donor2', r))); END LOOP;
  PERFORM test_harness.act('donor2');
  PERFORM test_harness.expect_error('F6 legacy RPC still limited to 3 photos',
    format('SELECT test_harness.create_legacy(%L::uuid, %L::jsonb, %L::jsonb)', r,
      jsonb_build_array(test_harness.legacy_item('X', 'Food', 1, 1)), v), '.+');
  PERFORM test_harness.admin();
END $f6$;

-- Unchanged compatibility RPC add_donation_image (not called by Flutter) on item-photo donations
DO $f7$
DECLARE d1 uuid := test_harness.fact('B1 one item')::uuid; d5 uuid := test_harness.fact('B5 five items, alternate photos')::uuid;
        v_path text; v_img text;
BEGIN
  v_path := test_harness.stage('donor1', NULL, 'jpg', 1234, 'image/jpeg', d5);
  PERFORM test_harness.act('donor1');
  PERFORM test_harness.expect_error('F7 add_donation_image still refuses a 4th photo (item donation with 3 photos)',
    format('SELECT public.add_donation_image(%L::uuid, %L, ''image/jpeg'', 1234)', d5, v_path), '^MAXIMUM_THREE_DONATION_PHOTOS$');
  PERFORM test_harness.admin();
  v_path := test_harness.stage('donor1', NULL, 'jpg', 1234, 'image/jpeg', d1);
  PERFORM test_harness.act('donor1');
  v_img := test_harness.error_of(format('SELECT public.add_donation_image(%L::uuid, %L, ''image/jpeg'', 1234)', d1, v_path));
  PERFORM test_harness.admin();
  PERFORM test_harness.ok('F8 add_donation_image appends an UNLINKED photo after item photos; item cover unchanged',
    v_img = 'OK'
    AND (SELECT item_id IS NULL AND display_order = 2 AND NOT is_primary FROM public.donation_images WHERE storage_path = v_path)
    AND (SELECT item_id IS NOT NULL AND is_primary FROM public.donation_images WHERE donation_id = d1 AND display_order = 1), v_img);
END $f7$;

-- G/H. Access fixture: a DIRECT donation (>= 10 kg) whose item 1 has NO photo -------------
DO $h0$
DECLARE r uuid := gen_random_uuid(); v jsonb; d uuid; l uuid;
BEGIN
  v := jsonb_build_array(
    test_harness.item(1, 'Rice sack', 'Food', 1, 6),
    test_harness.item(2, 'Blanket', 'Household Essentials', 2, 2, test_harness.photo(test_harness.stage('donor1', r))),
    test_harness.item(3, 'Shoes', 'Clothing', 1, 1, test_harness.photo(test_harness.stage('donor1', r, 'png', 4321, 'image/png'), 4321, 'image/png')))
    || '[]';
  v := jsonb_set(v, '{0,description}', '"secret item note"');
  PERFORM test_harness.act('donor1');
  d := test_harness.create_items(r, v, 'Access test direct');
  PERFORM test_harness.admin();
  SELECT listing_id INTO l FROM public.listings WHERE donation_id = d;
  PERFORM test_harness.set_fact('X', d::text); PERFORM test_harness.set_fact('X:listing', l::text);
  INSERT INTO test_harness.road_eligibility VALUES (test_harness.uid('ngo_eligible'), l, 5), (test_harness.uid('ngo_claimant'), l, 6),
                                                   (test_harness.uid('ngo_unverified'), l, 4);
END $h0$;
DO $g$
DECLARE d uuid := test_harness.fact('X')::uuid; v_p2 text; v_dash jsonb; v_gal jsonb; v_cards jsonb; v_const jsonb;
BEGIN
  SELECT img.storage_path INTO v_p2 FROM public.donation_images img JOIN public.donation_items i USING (item_id)
   WHERE i.donation_id = d AND i.item_position = 2;
  PERFORM test_harness.act('donor1');
  v_dash := test_harness.rows_json('SELECT primary_image_path FROM public.get_my_donation_dashboard_v3() WHERE donation_id = ' || quote_literal(d));
  v_gal := test_harness.rows_json('SELECT storage_path, display_order, is_cover FROM public.get_donation_images(' || quote_literal(d) || ')');
  PERFORM test_harness.act('ngo_eligible');
  v_cards := test_harness.rows_json('SELECT primary_image_path FROM public.discover_eligible_listing_cards_v2() WHERE donation_id = ' || quote_literal(d));
  v_const := test_harness.rows_json('SELECT primary_image_path FROM public.get_eligible_listing_constituents_v2(' || quote_literal(test_harness.fact('X:listing')) || ')');
  PERFORM test_harness.admin();
  PERFORM test_harness.ok('G1 donor dashboard v3 thumbnail = photo of item 2 (item 1 has none)', v_dash->0->>'primary_image_path' = v_p2, v_dash::text);
  PERFORM test_harness.ok('G2 unchanged get_donation_images: item 2 photo is the cover, then item 3',
    v_gal->0->>'storage_path' = v_p2 AND (v_gal->0->>'is_cover')::boolean AND (v_gal->0->>'display_order')::int = 1
    AND v_gal->1->>'storage_path' = (SELECT img.storage_path FROM public.donation_images img JOIN public.donation_items i USING (item_id)
                                      WHERE i.donation_id = d AND i.item_position = 3)
    AND jsonb_array_length(v_gal) = 2, v_gal::text);
  PERFORM test_harness.ok('G3 NGO discovery card v2 thumbnail = item 2 photo', v_cards->0->>'primary_image_path' = v_p2, v_cards::text);
  PERFORM test_harness.ok('G4 NGO constituents v2 thumbnail = item 2 photo', v_const->0->>'primary_image_path' = v_p2, v_const::text);
END $g$;

-- H. Role-based reads -------------------------------------------------------------------
-- outcome(): the reader's error, or the donation_ids it returned plus whether photo paths were visible.
CREATE FUNCTION test_harness.outcome(p_sql text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v jsonb := test_harness.rows_json(p_sql);
BEGIN
  IF v ? 'error' THEN RETURN jsonb_build_object('error', v->>'error'); END IF;
  RETURN jsonb_build_object('donations', (SELECT coalesce(jsonb_agg(DISTINCT e->'donation_id'), '[]') FROM jsonb_array_elements(v) e),
                            'rows', jsonb_array_length(v),
                            'paths', (SELECT count(*) FROM jsonb_array_elements(v) e WHERE coalesce(e->>'photo_path', e->>'storage_path') IS NOT NULL));
END $$;
CREATE FUNCTION test_harness.as_user(p_user text, p_sql text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v jsonb;
BEGIN
  IF p_user = 'anon' THEN PERFORM test_harness.act_anon(); ELSE PERFORM test_harness.act(p_user); END IF;
  v := test_harness.outcome(p_sql);
  PERFORM test_harness.admin();
  RETURN v;
END $$;
-- Same caller, same listing/claim: new reader must authorise exactly like the existing v2 reader.
CREATE FUNCTION test_harness.same_auth(p_name text, p_user text, p_new text, p_old text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE a jsonb := test_harness.as_user(p_user, p_new); b jsonb := test_harness.as_user(p_user, p_old);
BEGIN
  PERFORM test_harness.ok(p_name, (a->'error') IS NOT DISTINCT FROM (b->'error') AND (a->'donations') IS NOT DISTINCT FROM (b->'donations'),
                          'new=' || a::text || ' existing=' || b::text);
END $$;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA test_harness TO anon, authenticated;

DO $h1$
DECLARE d text := quote_literal(test_harness.fact('X')); l text := quote_literal(test_harness.fact('X:listing')); v jsonb; u text;
BEGIN
  -- Donor reader
  PERFORM test_harness.act('donor1');
  v := test_harness.rows_json('SELECT * FROM public.get_my_donation_items(' || d || ')');
  PERFORM test_harness.admin();
  PERFORM test_harness.ok('H01 owner sees 3 items in position order, photo paths for items 2-3 only, item description visible',
    jsonb_array_length(v) = 3 AND (v->0->>'item_position')::int = 1 AND v->0->'photo_path' = 'null'
    AND v->0->>'item_description' = 'secret item note' AND v->1->>'photo_path' IS NOT NULL AND v->2->>'photo_content_type' = 'image/png', v::text);
  PERFORM test_harness.ok('H02 another donor is refused', test_harness.as_user('donor2', 'SELECT * FROM public.get_my_donation_items(' || d || ')')
    ->>'error' = 'DONATION_NOT_FOUND_OR_FORBIDDEN');
  PERFORM test_harness.ok('H03 an NGO is refused the donor reader', test_harness.as_user('ngo_eligible', 'SELECT * FROM public.get_my_donation_items(' || d || ')')
    ->>'error' = 'DONOR_ONLY');
  PERFORM test_harness.ok('H04 anon is refused every new reader (4)',
    (SELECT bool_and(test_harness.as_user('anon', q)->>'error' LIKE 'permission denied for function%') FROM unnest(ARRAY[
      'SELECT * FROM public.get_my_donation_items(' || d || ')',
      'SELECT * FROM public.get_eligible_listing_items(' || l || ')', 'SELECT * FROM public.get_claimed_listing_items(' || l || ')',
      'SELECT * FROM public.get_my_hub_donation_items(' || l || ',' || d || ')']) q));
  -- Gallery v2 follows the per-photo Storage rule
  PERFORM test_harness.ok('H05 unchanged get_donation_images on item photos: owner 2, eligible NGO 2, other donor 0, out-of-range NGO 0, unverified NGO 0, hub admin 0',
    (test_harness.as_user('donor1', 'SELECT * FROM public.get_donation_images(' || d || ')')->>'rows')::int = 2
    AND (test_harness.as_user('ngo_eligible', 'SELECT * FROM public.get_donation_images(' || d || ')')->>'rows')::int = 2
    AND (test_harness.as_user('donor2', 'SELECT * FROM public.get_donation_images(' || d || ')')->>'rows')::int = 0
    AND (test_harness.as_user('ngo_far', 'SELECT * FROM public.get_donation_images(' || d || ')')->>'rows')::int = 0
    AND (test_harness.as_user('ngo_unverified', 'SELECT * FROM public.get_donation_images(' || d || ')')->>'rows')::int = 0
    AND (test_harness.as_user('hub_admin_a', 'SELECT * FROM public.get_donation_images(' || d || ')')->>'rows')::int = 0);
  -- Eligible-listing reader == get_eligible_listing_constituents_v2, caller by caller
  FOREACH u IN ARRAY ARRAY['ngo_eligible','ngo_claimant','ngo_far','ngo_unverified','ngo_other','donor1','hub_admin_a','no_profile'] LOOP
    PERFORM test_harness.same_auth('H06 eligible-listing authorisation identical to constituents_v2 for ' || u, u,
      'SELECT * FROM public.get_eligible_listing_items(' || l || ')', 'SELECT * FROM public.get_eligible_listing_constituents_v2(' || l || ')');
  END LOOP;
  PERFORM test_harness.act('ngo_eligible');
  v := test_harness.rows_json('SELECT * FROM public.get_eligible_listing_items(' || l || ')');
  PERFORM test_harness.admin();
  PERFORM test_harness.ok('H07 eligible NGO sees all 3 items, 2 photo paths, and no item-description or donor columns',
    jsonb_array_length(v) = 3 AND (SELECT count(*) FROM jsonb_array_elements(v) e WHERE e->>'photo_path' IS NOT NULL) = 2
    AND NOT (v->0 ? 'item_description') AND NOT (v->0 ? 'donor_user_id'), v::text);
  PERFORM test_harness.ok('H08 out-of-range NGO refused with LISTING_NOT_ELIGIBLE',
    test_harness.as_user('ngo_far', 'SELECT * FROM public.get_eligible_listing_items(' || l || ')')->>'error' = 'LISTING_NOT_ELIGIBLE');
  PERFORM test_harness.ok('H09 unverified NGO refused with VERIFIED_NGO_ONLY',
    test_harness.as_user('ngo_unverified', 'SELECT * FROM public.get_eligible_listing_items(' || l || ')')->>'error' = 'VERIFIED_NGO_ONLY');
END $h1$;

-- Claim lifecycle. claim_listing() itself needs the pgRouting eligibility pipeline, which this
-- harness does not have, so the fixture writes the same rows claim_listing() writes on success
-- (request, claim, 360-minute lease, listing CLAIMED, pickup task, donation transition) as the harness superuser.
DO $h2$
DECLARE v_req uuid := gen_random_uuid(); v_claim uuid; l uuid := test_harness.fact('X:listing')::uuid; v_ngo uuid := test_harness.uid('ngo_claimant');
BEGIN
  INSERT INTO public.claim_requests(request_id, listing_id, ngo_user_id, request_digest) VALUES (v_req, l, v_ngo, md5(l::text || ':' || v_ngo::text));
  INSERT INTO public.donation_claims(listing_id, ngo_user_id, request_id) VALUES (l, v_ngo, v_req) RETURNING claim_id INTO v_claim;
  INSERT INTO public.claim_leases(claim_id, expires_at)
    VALUES (v_claim, clock_timestamp() + make_interval(mins => (SELECT claim_lease_minutes FROM public.coordination_config WHERE singleton)));
  UPDATE public.listings SET listing_status = 'CLAIMED', listing_version = listing_version + 1 WHERE listing_id = l;
  INSERT INTO public.pickup_tasks(claim_id, listing_id, ngo_user_id, pickup_road_node_id, load_kg)
    SELECT v_claim, l, v_ngo, pickup_road_node_id, listing_weight_kg FROM public.listings WHERE listing_id = l;
  PERFORM public.geolock_transition_listing_donations(l, 'AVAILABLE', 'CLAIMED', v_claim, v_req, 'CLAIM_ACCEPTED');
  UPDATE public.claim_requests SET outcome = 'SUCCESS', result_claim_id = v_claim, completed_at = clock_timestamp() WHERE request_id = v_req;
  PERFORM test_harness.set_fact('X:claim', v_claim::text);
END $h2$;
DO $h3$
DECLARE c text := quote_literal(test_harness.fact('X:claim')); l text := quote_literal(test_harness.fact('X:listing')); u text; v jsonb;
BEGIN
  PERFORM test_harness.ok('H10 claim fixture has an ACTIVE claim, ACTIVE lease and CLAIMED listing',
    (SELECT c2.claim_status = 'ACTIVE' AND le.lease_status = 'ACTIVE' FROM public.donation_claims c2 JOIN public.claim_leases le USING (claim_id)
      WHERE c2.claim_id = test_harness.fact('X:claim')::uuid));
  FOREACH u IN ARRAY ARRAY['ngo_claimant','ngo_eligible','ngo_other','donor1','hub_admin_a'] LOOP
    PERFORM test_harness.same_auth('H11 active claim: claimed-listing authorisation identical to claimed_constituents_v2 for ' || u, u,
      'SELECT * FROM public.get_claimed_listing_items(' || c || ')', 'SELECT * FROM public.get_claimed_listing_constituents_v2(' || c || ')');
    PERFORM test_harness.same_auth('H12 claimed listing: eligible-listing authorisation identical to constituents_v2 for ' || u, u,
      'SELECT * FROM public.get_eligible_listing_items(' || l || ')', 'SELECT * FROM public.get_eligible_listing_constituents_v2(' || l || ')');
  END LOOP;
  PERFORM test_harness.act('ngo_claimant');
  v := test_harness.rows_json('SELECT * FROM public.get_claimed_listing_items(' || c || ')');
  PERFORM test_harness.admin();
  PERFORM test_harness.ok('H13 claimant with active lease sees 3 items and both photos', jsonb_array_length(v) = 3
    AND (SELECT count(*) FROM jsonb_array_elements(v) e WHERE e->>'photo_path' IS NOT NULL) = 2, v::text);
  PERFORM test_harness.ok('H14 another NGO cannot use the claim ID',
    test_harness.as_user('ngo_other', 'SELECT * FROM public.get_claimed_listing_items(' || c || ')')->>'error' = 'CLAIM_NOT_FOUND_OR_FORBIDDEN');
  PERFORM test_harness.ok('H15 after claiming, the formerly eligible NGO loses item photos',
    test_harness.as_user('ngo_eligible', 'SELECT * FROM public.get_eligible_listing_items(' || l || ')')->>'error' = 'LISTING_NOT_ELIGIBLE'
    AND (test_harness.as_user('ngo_eligible', 'SELECT * FROM public.get_donation_images(' || quote_literal(test_harness.fact('X')) || ')')->>'rows')::int = 0);
END $h3$;
-- Lease time runs out (still ACTIVE rows, not yet recovered)
UPDATE public.claim_leases SET issued_at = now() - interval '7 hours', expires_at = now() - interval '1 hour'
 WHERE claim_id = test_harness.fact('X:claim')::uuid;
DO $h4$
DECLARE c text := quote_literal(test_harness.fact('X:claim'));
BEGIN
  PERFORM test_harness.same_auth('H16 lapsed lease: identical to claimed_constituents_v2 for claimant', 'ngo_claimant',
    'SELECT * FROM public.get_claimed_listing_items(' || c || ')', 'SELECT * FROM public.get_claimed_listing_constituents_v2(' || c || ')');
  PERFORM test_harness.ok('H17 lapsed lease: claimant refused and photos no longer readable',
    test_harness.as_user('ngo_claimant', 'SELECT * FROM public.get_claimed_listing_items(' || c || ')')->>'error' = 'CLAIM_NOT_FOUND_OR_FORBIDDEN'
    AND (test_harness.as_user('ngo_claimant', 'SELECT * FROM public.get_donation_images(' || quote_literal(test_harness.fact('X')) || ')')->>'rows')::int = 0);
END $h4$;
-- Recovered as EXPIRED
UPDATE public.claim_leases SET lease_status = 'EXPIRED', closed_at = now() WHERE claim_id = test_harness.fact('X:claim')::uuid;
UPDATE public.donation_claims SET claim_status = 'EXPIRED', closed_at = now() WHERE claim_id = test_harness.fact('X:claim')::uuid;
DO $h5$
DECLARE c text := quote_literal(test_harness.fact('X:claim'));
BEGIN
  PERFORM test_harness.same_auth('H18 EXPIRED claim: identical to claimed_constituents_v2', 'ngo_claimant',
    'SELECT * FROM public.get_claimed_listing_items(' || c || ')', 'SELECT * FROM public.get_claimed_listing_constituents_v2(' || c || ')');
  PERFORM test_harness.ok('H19 EXPIRED claim refused',
    test_harness.as_user('ngo_claimant', 'SELECT * FROM public.get_claimed_listing_items(' || c || ')')->>'error' = 'CLAIM_NOT_FOUND_OR_FORBIDDEN');
END $h5$;
-- COMPLETED keeps read access (as the existing readers and Storage rule do)
UPDATE public.donation_claims SET claim_status = 'COMPLETED' WHERE claim_id = test_harness.fact('X:claim')::uuid;
DO $h6$
DECLARE c text := quote_literal(test_harness.fact('X:claim'));
BEGIN
  PERFORM test_harness.same_auth('H20 COMPLETED claim: identical to claimed_constituents_v2', 'ngo_claimant',
    'SELECT * FROM public.get_claimed_listing_items(' || c || ')', 'SELECT * FROM public.get_claimed_listing_constituents_v2(' || c || ')');
  PERFORM test_harness.ok('H21 COMPLETED claim: claimant still sees items and both photos',
    (test_harness.as_user('ngo_claimant', 'SELECT * FROM public.get_claimed_listing_items(' || c || ')')->>'paths')::int = 2);
END $h6$;
UPDATE public.donation_claims SET claim_status = 'RECONCILIATION_REQUIRED' WHERE claim_id = test_harness.fact('X:claim')::uuid;
DO $h7$
DECLARE c text := quote_literal(test_harness.fact('X:claim'));
BEGIN
  PERFORM test_harness.same_auth('H22 RECONCILIATION_REQUIRED claim: identical to claimed_constituents_v2', 'ngo_claimant',
    'SELECT * FROM public.get_claimed_listing_items(' || c || ')', 'SELECT * FROM public.get_claimed_listing_constituents_v2(' || c || ')');
END $h7$;
-- Restore the fixture to its real state (COMPLETED) so later checks see a consistent claim.
UPDATE public.donation_claims SET claim_status = 'COMPLETED' WHERE claim_id = test_harness.fact('X:claim')::uuid;

-- Hub admin reads
UPDATE public.community_hubs SET operating_hours =
  '{"mon":[{"open":"00:00","close":"24:00"}],"tue":[{"open":"00:00","close":"24:00"}],"wed":[{"open":"00:00","close":"24:00"}],"thu":[{"open":"00:00","close":"24:00"}],"fri":[{"open":"00:00","close":"24:00"}],"sat":[{"open":"00:00","close":"24:00"}],"sun":[{"open":"00:00","close":"24:00"}]}';
INSERT INTO public.hub_accepted_categories(hub_id, category_id)
  SELECT h.hub_id, c.category_id FROM public.community_hubs h CROSS JOIN public.donation_categories c ON CONFLICT DO NOTHING;
DO $h8$
DECLARE r uuid := gen_random_uuid(); v jsonb; d uuid;
BEGIN
  v := test_harness.build_items('donor1', r, 4, ARRAY[1,4], 0.4);
  PERFORM test_harness.act('donor1');
  d := test_harness.create_items(r, v, 'Access test hub');
  PERFORM test_harness.admin();
  PERFORM test_harness.set_fact('H', d::text);
END $h8$;
-- reserve_hub_capacity() needs PostGIS (not in this harness), so the fixture writes the
-- reservation row it would write. Only that INSERT skips the hub route/opening-hours triggers;
-- the donation status change below runs with all triggers, including the lifecycle check.
SET session_replication_role = replica;
INSERT INTO public.hub_reservations(donation_id, hub_id, reserved_weight_kg, expires_at)
  SELECT d.donation_id, test_harness.fact('hub_a')::uuid, d.total_weight_kg, now() + interval '1 day'
    FROM public.donations d WHERE d.donation_id = test_harness.fact('H')::uuid;
SET session_replication_role = origin;
UPDATE public.donations SET donation_status = 'HUB_ASSIGNED' WHERE donation_id = test_harness.fact('H')::uuid;
DO $h10$
DECLARE d text := quote_literal(test_harness.fact('H')); ha text := quote_literal(test_harness.fact('hub_a'));
        hb text := quote_literal(test_harness.fact('hub_b')); v jsonb; v_detail jsonb;
BEGIN
  PERFORM test_harness.act('hub_admin_a');
  v := test_harness.rows_json('SELECT * FROM public.get_my_hub_donation_items(' || ha || ',' || d || ')');
  v_detail := public.get_my_hub_donation_detail(test_harness.fact('hub_a')::uuid, test_harness.fact('H')::uuid);
  PERFORM test_harness.admin();
  PERFORM test_harness.ok('H23 hub admin with an active reservation sees 4 items in order with photos on 1 and 4',
    jsonb_array_length(v) = 4 AND v->0->>'photo_path' IS NOT NULL AND v->1->'photo_path' = 'null' AND v->3->>'photo_path' IS NOT NULL
    AND (SELECT array_agg((e->>'item_position')::int) FROM jsonb_array_elements(v) e) = ARRAY[1,2,3,4], v::text);
  PERFORM test_harness.ok('H24 hub item photo paths = the legacy detail image_paths (same photos, same order)',
    (SELECT jsonb_agg(e->'photo_path') FROM jsonb_array_elements(v) e WHERE e->>'photo_path' IS NOT NULL) = v_detail->'image_paths');
  PERFORM test_harness.ok('H25 other hub''s admin refused on Hub A (same error as get_my_hub_donation_detail)',
    test_harness.as_user('hub_admin_b', 'SELECT * FROM public.get_my_hub_donation_items(' || ha || ',' || d || ')')->>'error'
      = test_harness.as_user('hub_admin_b', 'SELECT public.get_my_hub_donation_detail(' || ha || ',' || d || ') AS donation_id')->>'error'
    AND test_harness.as_user('hub_admin_b', 'SELECT * FROM public.get_my_hub_donation_items(' || ha || ',' || d || ')')->>'error' = 'HUB_NOT_FOUND_OR_FORBIDDEN');
  PERFORM test_harness.ok('H26 Hub B admin on own hub refused for a donation not at Hub B',
    test_harness.as_user('hub_admin_b', 'SELECT * FROM public.get_my_hub_donation_items(' || hb || ',' || d || ')')->>'error' = 'DONATION_NOT_AT_THIS_HUB');
  PERFORM test_harness.ok('H27 hub admin refused for a donation never sent to the hub',
    test_harness.as_user('hub_admin_a', 'SELECT * FROM public.get_my_hub_donation_items(' || ha || ',' || quote_literal(test_harness.fact('X')) || ')')->>'error' = 'DONATION_NOT_AT_THIS_HUB');
  PERFORM test_harness.ok('H28 donor and NGO refused the hub reader',
    test_harness.as_user('donor1', 'SELECT * FROM public.get_my_hub_donation_items(' || ha || ',' || d || ')')->>'error' = 'HUB_NOT_FOUND_OR_FORBIDDEN'
    AND test_harness.as_user('ngo_eligible', 'SELECT * FROM public.get_my_hub_donation_items(' || ha || ',' || d || ')')->>'error' = 'HUB_NOT_FOUND_OR_FORBIDDEN');
END $h10$;
-- Reservation lapses: the hub keeps the item list (like the legacy detail) but Storage refuses the photos
SET session_replication_role = replica;
UPDATE public.hub_reservations SET reserved_at = now() - interval '3 days', expires_at = now() - interval '1 day'
 WHERE donation_id = test_harness.fact('H')::uuid;
SET session_replication_role = origin;
DO $h11$
DECLARE d text := quote_literal(test_harness.fact('H')); ha text := quote_literal(test_harness.fact('hub_a')); v jsonb;
BEGIN
  v := test_harness.as_user('hub_admin_a', 'SELECT * FROM public.get_my_hub_donation_items(' || ha || ',' || d || ')');
  PERFORM test_harness.ok('H29 lapsed reservation: items still listed, photo paths withheld (matches Storage rule)',
    (v->>'rows')::int = 4 AND (v->>'paths')::int = 0, v::text);
END $h11$;

-- I. Live anon probe of every pre-existing anon-executable function ---------------------
-- Each call runs in a subtransaction that is always rolled back, so nothing can persist.
CREATE TABLE test_harness.anon_probe (fn text, probe text, outcome text, returned text);
DO $i$
DECLARE r record; v_probe record; v_args text; v_sql text; v_out text; v_ret text; v_n bigint; v_any jsonb;
BEGIN
  FOR r IN SELECT p.oid, p.oid::regprocedure::text AS fn, p.proretset, p.prorettype, pg_get_function_identity_arguments(p.oid) AS args,
                  p.proargtypes
             FROM pg_proc p
            WHERE p.pronamespace = 'public'::regnamespace AND p.prokind = 'f'
              AND has_function_privilege('anon', p.oid, 'EXECUTE')
              AND EXISTS (SELECT 1 FROM test_harness.before_catalog b WHERE b.key = 'function_body:' || p.oid::regprocedure::text)
            ORDER BY 2 LOOP
    FOR v_probe IN SELECT * FROM (VALUES ('nulls', NULL::text), ('donation', test_harness.fact('X')), ('listing', test_harness.fact('X:listing')),
                                         ('claim', test_harness.fact('X:claim')), ('hub', test_harness.fact('hub_a'))) x(name, id) LOOP
      SELECT coalesce(string_agg(CASE WHEN t = 'uuid'::regtype AND v_probe.id IS NOT NULL THEN quote_literal(v_probe.id) || '::uuid'
                                      ELSE 'NULL::' || format_type(t, NULL) END, ', ' ORDER BY o), '')
        INTO v_args FROM unnest(r.proargtypes::oid[]) WITH ORDINALITY u(t, o);
      CONTINUE WHEN v_probe.name <> 'nulls' AND v_args NOT LIKE '%::uuid%' OR (v_probe.name <> 'nulls' AND v_args LIKE '%NULL::uuid%' AND v_args NOT LIKE '%''::uuid%');
      v_sql := 'SELECT count(*), jsonb_agg(to_jsonb(t)) FROM ' || r.oid::regproc::text || '(' || v_args || ') t';
      v_out := NULL; v_ret := NULL;
      BEGIN
        PERFORM test_harness.act_anon();
        EXECUTE v_sql INTO v_n, v_any;
        PERFORM test_harness.admin();
        v_out := 'RETURNED ' || v_n || ' row(s)'; v_ret := left(v_any::text, 300);
        RAISE EXCEPTION 'PROBE_ROLLBACK';
      EXCEPTION WHEN OTHERS THEN
        PERFORM test_harness.admin();
        IF SQLERRM <> 'PROBE_ROLLBACK' THEN v_out := 'ERROR ' || SQLERRM; END IF;
      END;
      INSERT INTO test_harness.anon_probe VALUES (r.fn, v_probe.name, v_out, v_ret);
    END LOOP;
  END LOOP;
END $i$;
DO $icheck$
DECLARE v_leak text; v_n int; v_audited int;
BEGIN
  SELECT count(DISTINCT fn) INTO v_n FROM test_harness.anon_probe;
  SELECT count(DISTINCT fn) INTO v_audited FROM test_harness.anon_probe
   WHERE split_part(fn, '(', 1) = ANY (ARRAY['create_donation_with_images','create_and_validate_donation','add_donation_image',
     'require_donation_photo_before_commit','geolock_validate_donation_at_commit','guard_donation_items','can_read_geolock_donation_image',
     'can_read_geolock_batch_image','geolock_storage_can_upload_donation_image','geolock_storage_can_upload_batch_image',
     'geolock_storage_can_delete_unattached_image','geolock_storage_can_read_image','get_donation_images','get_batch_images',
     'add_hub_batch_image','get_my_donation_detail','get_my_hub_donation_detail','get_eligible_listing_constituents',
     'get_claimed_listing_constituents','get_claimed_listing_detail','discover_eligible_listing_cards','get_my_donation_dashboard_v2',
     'get_my_claim_cards','get_hub_donation_covers','discover_eligible_listing_cards_v2','get_eligible_listing_constituents_v2',
     'get_claimed_listing_constituents_v2','get_my_donation_dashboard_v3']);
  -- A "leak" is any probe that returned a row containing a non-null, non-false value.
  SELECT string_agg(DISTINCT fn || ' [' || probe || '] ' || returned, '; ') INTO v_leak FROM test_harness.anon_probe
   WHERE outcome LIKE 'RETURNED%' AND returned IS NOT NULL
     AND returned !~ '^\[(null|false|\{"[a-z_]+": (null|false)\})\]$' AND returned <> '[]';
  PERFORM test_harness.ok('I1 anon-executable among the 28 audited functions = 18 (same as KLSEL)', v_audited = 18, v_audited::text);
  PERFORM test_harness.ok('I1b all pre-existing anon-executable public functions probed (38 in baseline)', v_n = 38, v_n::text);
  PERFORM test_harness.ok('I2 no anon probe returned data (each raised, or returned only null/false/no rows)', v_leak IS NULL, v_leak);
END $icheck$;

-- Final post-test integrity: every committed donation still satisfies the existing rules
DO $z$
BEGIN
  PERFORM test_harness.ok('Z1 every donation has at least one photo',
    NOT EXISTS (SELECT 1 FROM public.donations d WHERE NOT EXISTS (SELECT 1 FROM public.donation_images i WHERE i.donation_id = d.donation_id)));
  PERFORM test_harness.ok('Z2 every item-linked photo belongs to its own donation and items have at most one photo',
    NOT EXISTS (SELECT 1 FROM public.donation_images i JOIN public.donation_items it USING (item_id) WHERE it.donation_id <> i.donation_id)
    AND NOT EXISTS (SELECT item_id FROM public.donation_images WHERE item_id IS NOT NULL GROUP BY item_id HAVING count(*) > 1));
  PERFORM test_harness.ok('Z3 every image row has a Storage object',
    NOT EXISTS (SELECT 1 FROM public.donation_images i WHERE NOT EXISTS (SELECT 1 FROM storage.objects o
                 WHERE o.bucket_id = 'geolock-donation-images' AND o.name = i.storage_path)));
  PERFORM test_harness.ok('Z4 no donation from the new RPC has more photos than items',
    NOT EXISTS (SELECT 1 FROM public.donations d WHERE (SELECT count(*) FROM public.donation_images i WHERE i.donation_id = d.donation_id AND i.item_id IS NOT NULL)
                 > (SELECT count(*) FROM public.donation_items it WHERE it.donation_id = d.donation_id)));
END $z$;

\pset pager off
SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, name, CASE WHEN NOT ok THEN left(detail, 400) END AS detail
  FROM test_harness.results ORDER BY seq;
SELECT count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed, count(*) AS total FROM test_harness.results;
