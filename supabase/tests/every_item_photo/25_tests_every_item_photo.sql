-- LOCAL TEST HARNESS ONLY. Runs AFTER 22_snapshot_before_every_item_photo.sql and
-- 20261128120000_require_photo_for_every_item.sql. Uses the helpers of 10_* and 20_*.
-- Revises the earlier 0-1-photo-per-item cases (B3, B5, B30b in 20_tests_after_migration.sql):
-- under the new rule each of them is now expected to be REJECTED (section R), while the
-- donations they created before the change stay readable and byte-identical (section L).
SET client_min_messages = warning;
\set ON_ERROR_STOP 1

-- A. Only create_donation_with_item_photos changed ---------------------------------------
DO $a$
DECLARE v_diff text; v_rows text;
BEGIN
  SELECT string_agg(coalesce(b.key, a.key), '; ') INTO v_diff
  FROM test_harness.every_photo_catalog b
  FULL JOIN (
    SELECT 'function:' || p.oid::regprocedure::text AS key,
           md5(concat_ws('|', replace(p.prosrc, chr(13), ''), p.prosecdef, p.proconfig::text,
                         coalesce(p.proacl::text, 'default'), p.proowner)) AS value
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'test_harness') AND n.nspname NOT LIKE 'pg_toast%'
    UNION ALL SELECT 'trigger:' || tgrelid::regclass::text || '.' || tgname, md5(pg_get_triggerdef(oid) || tgenabled::text)
      FROM pg_trigger WHERE NOT tgisinternal
    UNION ALL SELECT 'constraint:' || conrelid::regclass::text || '.' || conname, md5(pg_get_constraintdef(oid))
      FROM pg_constraint WHERE connamespace IN ('public'::regnamespace, 'storage'::regnamespace)
    UNION ALL SELECT 'index:' || indexrelid::regclass::text, md5(pg_get_indexdef(indexrelid))
      FROM pg_index i JOIN pg_class c ON c.oid = i.indrelid WHERE c.relnamespace IN ('public'::regnamespace, 'storage'::regnamespace)
    UNION ALL SELECT 'policy:' || schemaname || '.' || tablename || '.' || policyname,
           md5(concat_ws('|', permissive, roles::text, cmd, qual, with_check)) FROM pg_policies WHERE schemaname IN ('public', 'storage')
    UNION ALL SELECT 'table_acl:' || c.oid::regclass::text, coalesce(c.relacl::text, 'default')
      FROM pg_class c WHERE c.relnamespace IN ('public'::regnamespace, 'storage'::regnamespace) AND c.relkind = 'r'
    UNION ALL SELECT 'bucket:' || id, concat_ws('|', public, file_size_limit, allowed_mime_types::text) FROM storage.buckets
  ) a USING (key)
  WHERE a.value IS DISTINCT FROM b.value;
  PERFORM test_harness.ok('E-A1 only create_donation_with_item_photos changed (functions in all schemas, triggers, constraints, indexes, policies, grants, buckets)',
    v_diff = 'function:create_donation_with_item_photos(uuid,text,text,text,double precision,double precision,jsonb,text)', v_diff);
  PERFORM test_harness.ok('E-A2 create_donation_with_images (legacy RPC) body unchanged',
    (SELECT md5(replace(prosrc, chr(13), '')) FROM pg_proc
      WHERE oid = 'public.create_donation_with_images(uuid,text,text,text,double precision,double precision,jsonb,text,jsonb)'::regprocedure)
    = '102cadd77c875339cbe12e5677c7872c');
  SELECT string_agg(b.key, '; ') INTO v_rows FROM test_harness.every_photo_rows b
  LEFT JOIN (
    SELECT 'donation:' || donation_id AS key, md5(to_jsonb(d)::text) AS value FROM public.donations d
    UNION ALL SELECT 'item:' || item_id, md5(to_jsonb(i)::text) FROM public.donation_items i
    UNION ALL SELECT 'image:' || image_id, md5(to_jsonb(g)::text) FROM public.donation_images g
    UNION ALL SELECT 'request:' || request_id, md5(to_jsonb(r)::text) FROM public.donation_create_requests r
    UNION ALL SELECT 'listing:' || listing_id, md5(to_jsonb(l)::text) FROM public.listings l
  ) a USING (key) WHERE a.value IS DISTINCT FROM b.value;
  PERFORM test_harness.ok('E-A3 migration changed no existing donation, item, photo, request or listing row (no backfill)',
    v_rows IS NULL, v_rows);
  PERFORM test_harness.ok('E-A4 RPC still SECURITY DEFINER, pinned search_path, authenticated only',
    (SELECT prosecdef AND proconfig::text LIKE '%search_path=pg_catalog, public, extensions, storage, pg_temp%' FROM pg_proc
      WHERE oid = 'public.create_donation_with_item_photos(uuid,text,text,text,double precision,double precision,jsonb,text)'::regprocedure)
    AND has_function_privilege('authenticated', 'public.create_donation_with_item_photos(uuid,text,text,text,double precision,double precision,jsonb,text)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.create_donation_with_item_photos(uuid,text,text,text,double precision,double precision,jsonb,text)', 'EXECUTE'));
END $a$;

-- V. Valid: a photo on every item (payloads sent in REVERSED array order) ------------------
DO $v$
DECLARE r uuid; v_items jsonb; d uuid; c record;
BEGIN
  FOR c IN SELECT * FROM (VALUES (1, 'E-V1 one item, one photo'), (3, 'E-V3 three items, three photos'),
                                 (30, 'E-V30 thirty items, thirty photos')) v(n, label) LOOP
    r := gen_random_uuid();
    v_items := test_harness.build_items('donor1', r, c.n, (SELECT array_agg(g) FROM generate_series(1, c.n) g));
    PERFORM test_harness.act('donor1');
    d := test_harness.create_items(r, test_harness.reversed(v_items), c.label);
    PERFORM test_harness.admin();
    PERFORM test_harness.set_fact(c.label, d::text);
    PERFORM test_harness.set_fact(c.label || ':request', r::text);
    PERFORM test_harness.set_fact(c.label || ':items', v_items::text);
  END LOOP;
END $v$;
DO $vcheck$
DECLARE c text; d uuid;
BEGIN
  FOREACH c IN ARRAY ARRAY['E-V1 one item, one photo', 'E-V3 three items, three photos', 'E-V30 thirty items, thirty photos'] LOOP
    d := test_harness.fact(c)::uuid;
    PERFORM test_harness.check_created(c, d, test_harness.fact(c || ':request')::uuid, test_harness.fact(c || ':items')::jsonb);
    PERFORM test_harness.ok(c || ': every item has exactly one photo',
      (SELECT count(*) FROM public.donation_items i WHERE i.donation_id = d
         AND (SELECT count(*) FROM public.donation_images g WHERE g.item_id = i.item_id) = 1)
      = (SELECT count(*) FROM public.donation_items WHERE donation_id = d));
    PERFORM test_harness.ok(c || ': cover (is_primary) is the photo of item 1',
      (SELECT g.storage_path FROM public.donation_images g WHERE g.donation_id = d AND g.is_primary)
      = test_harness.fact(c || ':items')::jsonb -> 0 -> 'photo' ->> 'storage_path');
  END LOOP;
END $vcheck$;

-- R. Rejected: any item without a photo. Each leaves no request row, donation, item, image,
-- audit or Storage change behind (expect_rejected compares all counts).
DO $r$
DECLARE r uuid; v jsonb;
BEGIN
  r := gen_random_uuid();
  PERFORM test_harness.expect_rejected('E-R1 one item without a photo rejected', 'donor1', r,
    test_harness.build_items('donor1', r, 1, ARRAY[]::int[]), '^AT_LEAST_ONE_ITEM_PHOTO_REQUIRED$');
  r := gen_random_uuid();
  PERFORM test_harness.expect_rejected('E-R2 three items, only two photos (item 2 missing) rejected', 'donor1', r,
    test_harness.build_items('donor1', r, 3, ARRAY[1,3]), '^ITEM_PHOTO_REQUIRED_2$');
  r := gen_random_uuid();
  PERFORM test_harness.expect_rejected('E-R3 three items, item 1 missing, reversed array: error names position 1', 'donor1', r,
    test_harness.reversed(test_harness.build_items('donor1', r, 3, ARRAY[2,3])), '^ITEM_PHOTO_REQUIRED_1$');
  r := gen_random_uuid();
  PERFORM test_harness.expect_rejected('E-R4 thirty items, item 30 missing rejected', 'donor1', r,
    test_harness.build_items('donor1', r, 30, (SELECT array_agg(g) FROM generate_series(1, 29) g)), '^ITEM_PHOTO_REQUIRED_30$');
  r := gen_random_uuid();
  v := test_harness.build_items('donor1', r, 2, ARRAY[1,2]);
  PERFORM test_harness.expect_rejected('E-R5 explicit "photo": null counts as missing', 'donor1', r,
    jsonb_set(v, '{1,photo}', 'null'), '^ITEM_PHOTO_REQUIRED_2$');
  -- The earlier 0-1-per-item cases from 20_tests_after_migration.sql, now revised to rejections.
  r := gen_random_uuid();
  PERFORM test_harness.expect_rejected('E-R6 revised B3: three items, item 1 unphotographed now rejected', 'donor1', r,
    test_harness.build_items('donor1', r, 3, ARRAY[2,3]), '^ITEM_PHOTO_REQUIRED_1$');
  r := gen_random_uuid();
  PERFORM test_harness.expect_rejected('E-R7 revised B5: five items, alternate photos now rejected', 'donor1', r,
    test_harness.build_items('donor1', r, 5, ARRAY[1,3,5]), '^ITEM_PHOTO_REQUIRED_2$');
  r := gen_random_uuid();
  PERFORM test_harness.expect_rejected('E-R8 revised B30b: thirty items, only the last photographed now rejected', 'donor1', r,
    test_harness.build_items('donor1', r, 30, ARRAY[30]), '^ITEM_PHOTO_REQUIRED_1$');
  -- Existing rules still apply first and unchanged.
  r := gen_random_uuid();
  PERFORM test_harness.expect_rejected('E-R9 31 items still ONE_TO_THIRTY_ITEMS_REQUIRED', 'donor1', r,
    test_harness.build_items('donor1', r, 31, (SELECT array_agg(g) FROM generate_series(1, 31) g)), '^ONE_TO_THIRTY_ITEMS_REQUIRED$');
  r := gen_random_uuid();
  v := test_harness.build_items('donor1', r, 2, ARRAY[1,2]);
  PERFORM test_harness.expect_rejected('E-R10 bad photo on a complete payload still INVALID_ITEM_PHOTO_2', 'donor1', r,
    jsonb_set(v, '{1,photo,content_type}', '"image/gif"'), '^INVALID_ITEM_PHOTO_2$');
  PERFORM test_harness.expect_rejected('E-R11 photo missing from Storage still STAGED_ITEM_PHOTO_MISSING_OR_MISMATCHED_1', 'donor1', r,
    jsonb_set(v, '{0,photo,storage_path}', to_jsonb(test_harness.uid('donor1') || '/pending/' || r || '/' || gen_random_uuid() || '.jpg')),
    '^STAGED_ITEM_PHOTO_MISSING_OR_MISMATCHED_1$');
  PERFORM test_harness.expect_rejected('E-R12 two photo objects for one item still ONE_PHOTO_PER_ITEM', 'donor1', r,
    jsonb_set(v, '{0,photo}', jsonb_build_array(v->0->'photo', v->1->'photo')), '^ONE_PHOTO_PER_ITEM$');
  PERFORM test_harness.expect_rejected('E-R13 same photo on two items still DUPLICATE_ITEM_PHOTO_2', 'donor1', r,
    jsonb_set(v, '{1,photo}', v->0->'photo'), '^DUPLICATE_ITEM_PHOTO_2$');
  PERFORM test_harness.expect_rejected('E-R14 error in the unchanged validator still rolls back (INVALID_DONATION_ITEM)', 'donor1', r,
    jsonb_set(v, '{0,quantity}', '0'), '^INVALID_DONATION_ITEM$');
END $r$;

-- I. Idempotency and retry ----------------------------------------------------------------
DO $i$
DECLARE r uuid := gen_random_uuid(); v jsonb; d1 uuid; d2 uuid; d3 uuid; v_before jsonb;
BEGIN
  v := test_harness.build_items('donor1', r, 3, ARRAY[1,2,3]);
  -- A failed attempt with a missing photo must not consume the request ID.
  PERFORM test_harness.expect_rejected('E-I1 attempt with a removed photo fails and does not consume the request ID', 'donor1', r,
    v #- '{1,photo}', '^ITEM_PHOTO_REQUIRED_2$');
  PERFORM test_harness.act('donor1');
  d1 := test_harness.create_items(r, v);
  PERFORM test_harness.admin();
  v_before := test_harness.counts(r);
  PERFORM test_harness.act('donor1');
  d2 := test_harness.create_items(r, v);
  d3 := test_harness.create_items(r, test_harness.reversed(v));
  PERFORM test_harness.admin();
  PERFORM test_harness.ok('E-I2 same request ID after the photo is re-added creates the donation', d1 IS NOT NULL);
  PERFORM test_harness.ok('E-I3 identical retry returns the same donation and writes nothing',
    d1 = d2 AND d1 = d3 AND test_harness.counts(r) = v_before);
  PERFORM test_harness.ok('E-I4 exactly one donation for the request',
    (SELECT count(*) FROM public.donation_create_requests WHERE request_id = r AND donation_id = d1) = 1);
  PERFORM test_harness.expect_rejected('E-I5 same request ID with a photo removed: still reported as a different payload', 'donor1', r,
    v #- '{2,photo}', '^IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD$');
  PERFORM test_harness.expect_rejected('E-I6 same request ID, different payload', 'donor1', r,
    jsonb_set(v, '{0,item_name}', '"Changed"'), '^IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD$');
END $i$;
-- A retry of a donation committed under the earlier rule (some items without a photo) keeps
-- returning that donation and writes nothing.
DO $i7$
DECLARE c text; r uuid; v jsonb; d uuid; v_before jsonb; t text;
BEGIN
  FOREACH c IN ARRAY ARRAY['B3 three items, item 1 unphotographed', 'B5 five items, alternate photos',
                           'D idempotent donation'] LOOP
    IF c = 'D idempotent donation' THEN
      r := test_harness.fact('D:request')::uuid; v := test_harness.fact('D:items')::jsonb;
      d := test_harness.fact('D:donation')::uuid; t := 'Item photo donation';
    ELSE
      r := test_harness.fact(c || ':request')::uuid; v := test_harness.reversed(test_harness.fact(c || ':items')::jsonb);
      d := test_harness.fact(c)::uuid; t := c;
    END IF;
    v_before := test_harness.counts(r);
    PERFORM test_harness.act('donor1');
    PERFORM test_harness.ok('E-I7 retry of pre-change donation "' || c || '" returns it unchanged',
      test_harness.create_items(r, v, t) = d);
    PERFORM test_harness.admin();
    PERFORM test_harness.ok('E-I7 retry of pre-change donation "' || c || '" writes nothing', test_harness.counts(r) = v_before);
  END LOOP;
END $i7$;

-- L. Legacy and pre-change donations stay readable and unchanged --------------------------
DO $l$
DECLARE v_partial text := test_harness.fact('B3 three items, item 1 unphotographed'); v jsonb;
BEGIN
  PERFORM test_harness.act('donor_legacy');
  PERFORM test_harness.ok('E-L1 legacy gallery (get_donation_images) identical',
    test_harness.rows_json('SELECT * FROM public.get_donation_images(' || quote_literal(test_harness.fact('legacy_direct')) || ')')
    = (SELECT output FROM test_harness.every_photo_reader_output WHERE reader = 'legacy:get_donation_images'));
  PERFORM test_harness.ok('E-L2 legacy items (get_my_donation_items) identical, still no item photo',
    test_harness.rows_json('SELECT * FROM public.get_my_donation_items(' || quote_literal(test_harness.fact('legacy_direct')) || ')')
    = (SELECT output FROM test_harness.every_photo_reader_output WHERE reader = 'legacy:get_my_donation_items'));
  PERFORM test_harness.ok('E-L3 legacy detail identical',
    to_jsonb(public.get_my_donation_detail(test_harness.fact('legacy_direct')::uuid))
    = (SELECT output FROM test_harness.every_photo_reader_output WHERE reader = 'legacy:get_my_donation_detail'));
  PERFORM test_harness.ok('E-L4 legacy dashboard identical',
    test_harness.rows_json('SELECT * FROM public.get_my_donation_dashboard_v3()')
    = (SELECT output FROM test_harness.every_photo_reader_output WHERE reader = 'legacy:dashboard_v3'));
  PERFORM test_harness.act('donor1');
  v := test_harness.rows_json('SELECT * FROM public.get_my_donation_items(' || quote_literal(v_partial) || ')');
  PERFORM test_harness.ok('E-L5 pre-change donation with an unphotographed item reads as before',
    v = (SELECT output FROM test_harness.every_photo_reader_output WHERE reader = 'partial:get_my_donation_items')
    AND (SELECT count(*) FROM jsonb_array_elements(v) e WHERE e->'photo_path' = 'null') = 1);
  PERFORM test_harness.ok('E-L6 pre-change donation detail and gallery identical',
    to_jsonb(public.get_my_donation_detail(v_partial::uuid))
      = (SELECT output FROM test_harness.every_photo_reader_output WHERE reader = 'partial:get_my_donation_detail')
    AND test_harness.rows_json('SELECT * FROM public.get_donation_images(' || quote_literal(v_partial) || ')')
      = (SELECT output FROM test_harness.every_photo_reader_output WHERE reader = 'partial:get_donation_images'));
  PERFORM test_harness.admin();
END $l$;
-- The legacy RPC still accepts donation-level photos exactly as before.
DO $l7$
DECLARE r uuid := gen_random_uuid(); d uuid; p text;
BEGIN
  PERFORM test_harness.act('donor_legacy');
  p := test_harness.stage('donor_legacy', r);
  d := test_harness.create_legacy(r, jsonb_build_array(test_harness.legacy_item('Rice', 'Food', 2, 1),
                                                       test_harness.legacy_item('Shirt', 'Clothing', 1, 1)),
                                  jsonb_build_array(test_harness.legacy_photo(p)));
  PERFORM test_harness.admin();
  PERFORM test_harness.ok('E-L7 create_donation_with_images still creates a donation-level-photo donation',
    (SELECT count(*) FROM public.donation_images WHERE donation_id = d AND item_id IS NULL) = 1
    AND (SELECT count(*) FROM public.donation_items WHERE donation_id = d) = 2);
END $l7$;

-- K. 10 kg classification unchanged (runs in the unchanged create_and_validate_donation).
-- Item quantities are 2 and 3 (build_items): 1.0 kg units = 5 kg, 5.0 kg units = 25 kg.
DO $k$
DECLARE r1 uuid := gen_random_uuid(); r2 uuid := gen_random_uuid(); d1 uuid; d2 uuid;
BEGIN
  PERFORM test_harness.act('donor1');
  d1 := test_harness.create_items(r1, test_harness.build_items('donor1', r1, 2, ARRAY[1,2], 1.0), 'Below 10 kg');
  d2 := test_harness.create_items(r2, test_harness.build_items('donor1', r2, 2, ARRAY[1,2], 5.0), 'At or above 10 kg');
  PERFORM test_harness.admin();
  PERFORM test_harness.set_fact('E-K:below', d1::text); PERFORM test_harness.set_fact('E-K:above', d2::text);
END $k$;
DO $kcheck$
BEGIN
  PERFORM test_harness.ok('E-K1 below 10 kg follows the hub path (HUB_COLLECTION, SUBMITTED)',
    (SELECT collection_path = 'HUB_COLLECTION' AND donation_status = 'SUBMITTED' FROM public.donations
      WHERE donation_id = test_harness.fact('E-K:below')::uuid));
  PERFORM test_harness.ok('E-K2 10 kg or more follows the direct path (DIRECT_PICKUP, AVAILABLE, listing created)',
    (SELECT collection_path = 'DIRECT_PICKUP' AND donation_status = 'AVAILABLE' FROM public.donations
      WHERE donation_id = test_harness.fact('E-K:above')::uuid)
    AND EXISTS (SELECT 1 FROM public.listings WHERE donation_id = test_harness.fact('E-K:above')::uuid AND listing_status = 'AVAILABLE'));
END $kcheck$;

-- Z. Invariant over every donation the item-photo RPC created after the change ------------
DO $z$
BEGIN
  PERFORM test_harness.ok('E-Z1 every donation created after the change has exactly one photo per item',
    NOT EXISTS (
      SELECT 1 FROM public.donation_create_requests q
      JOIN public.donation_items i ON i.donation_id = q.donation_id
      WHERE q.request_id NOT IN (SELECT substr(key, 9)::uuid FROM test_harness.every_photo_rows WHERE key LIKE 'request:%')
        AND EXISTS (SELECT 1 FROM public.donation_images g WHERE g.donation_id = q.donation_id AND g.item_id IS NOT NULL)
        AND (SELECT count(*) FROM public.donation_images g WHERE g.item_id = i.item_id) <> 1));
END $z$;

SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, name, left(coalesce(detail, ''), 160) AS detail
  FROM test_harness.results WHERE seq > (SELECT seq FROM test_harness.every_photo_marker) ORDER BY seq;
SELECT count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed, count(*) AS total
  FROM test_harness.results WHERE seq > (SELECT seq FROM test_harness.every_photo_marker);
