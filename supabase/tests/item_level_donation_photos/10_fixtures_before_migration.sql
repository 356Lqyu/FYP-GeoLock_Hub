-- LOCAL TEST HARNESS ONLY. Runs on the disposable baseline BEFORE the migration.
-- It creates the test helpers, users, hubs and legacy donations (through the unchanged
-- legacy RPC), and snapshots everything the migration must not change.
SET client_min_messages = warning;

CREATE TABLE test_harness.results (seq bigserial PRIMARY KEY, name text NOT NULL, ok boolean NOT NULL, detail text);
CREATE TABLE test_harness.users (name text PRIMARY KEY, id uuid NOT NULL);
CREATE TABLE test_harness.facts (key text PRIMARY KEY, value text);
GRANT USAGE ON SCHEMA test_harness TO anon, authenticated;
GRANT SELECT, INSERT ON test_harness.results TO anon, authenticated;
GRANT USAGE ON SEQUENCE test_harness.results_seq_seq TO anon, authenticated;
GRANT SELECT ON test_harness.users, test_harness.facts TO anon, authenticated;

CREATE FUNCTION test_harness.ok(p_name text, p_cond boolean, p_detail text DEFAULT NULL) RETURNS void
LANGUAGE sql AS $$ INSERT INTO test_harness.results(name, ok, detail) VALUES (p_name, coalesce(p_cond, false), p_detail) $$;
CREATE FUNCTION test_harness.uid(p text) RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT id FROM test_harness.users WHERE name = p $$;
CREATE FUNCTION test_harness.fact(p text) RETURNS text LANGUAGE sql STABLE AS $$ SELECT value FROM test_harness.facts WHERE key = p $$;
CREATE FUNCTION test_harness.set_fact(p_key text, p_value text) RETURNS void LANGUAGE sql SECURITY DEFINER AS
  $$ INSERT INTO test_harness.facts VALUES (p_key, p_value) ON CONFLICT (key) DO UPDATE SET value = excluded.value $$;

-- Act as a signed-in user / anon / back to the harness superuser (transaction-local).
CREATE FUNCTION test_harness.act(p_user text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('role', 'authenticated', true);
  PERFORM set_config('request.jwt.claim.sub', test_harness.uid(p_user)::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
END $$;
CREATE FUNCTION test_harness.act_anon() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('role', 'anon', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);
  PERFORM set_config('request.jwt.claim.role', 'anon', true);
END $$;
CREATE FUNCTION test_harness.admin() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('role', 'none', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);
  PERFORM set_config('request.jwt.claim.role', '', true);
END $$;

-- Run SQL as the current role; deferred constraint triggers are forced to fire inside.
CREATE FUNCTION test_harness.error_of(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  -- Run the statement exactly as a client would, then fire the commit-time (deferred) checks
  -- inside the same subtransaction. The only deferred triggers are the two INITIALLY DEFERRED
  -- donation checks, so switching back to DEFERRED restores the original state exactly.
  BEGIN
    EXECUTE p_sql;
    EXECUTE 'SET CONSTRAINTS ALL IMMEDIATE';
    EXECUTE 'SET CONSTRAINTS ALL DEFERRED';
    RETURN 'OK';
  EXCEPTION WHEN OTHERS THEN
    EXECUTE 'SET CONSTRAINTS ALL DEFERRED';
    RETURN SQLERRM;
  END;
END $$;
CREATE FUNCTION test_harness.expect_error(p_name text, p_sql text, p_pattern text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v text := test_harness.error_of(p_sql);
BEGIN
  PERFORM test_harness.ok(p_name, v <> 'OK' AND v ~ p_pattern, v);
END $$;
-- Rows of a query as JSON, or {"error": message}.
CREATE FUNCTION test_harness.rows_json(p_sql text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v jsonb;
BEGIN
  BEGIN
    EXECUTE 'SELECT coalesce(jsonb_agg(to_jsonb(t)), ''[]''::jsonb) FROM (' || p_sql || ') t' INTO v;
    RETURN v;
  EXCEPTION WHEN OTHERS THEN RETURN jsonb_build_object('error', SQLERRM);
  END;
END $$;

-- Fixture builders (run as the harness superuser).
CREATE FUNCTION test_harness.make_user(p_name text, p_role text, p_verified boolean DEFAULT true) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v uuid := gen_random_uuid();
BEGIN
  INSERT INTO auth.users(id, email) VALUES (v, p_name || '@test.invalid');
  INSERT INTO test_harness.users VALUES (p_name, v);
  IF p_role IS NULL THEN RETURN v; END IF;
  INSERT INTO public.user_profiles(user_id, full_name, role) VALUES (v, 'Test ' || p_name, p_role);
  IF p_role = 'DONOR' THEN
    INSERT INTO public.donor_profiles(user_id) VALUES (v);
  ELSIF p_role = 'NGO' THEN
    INSERT INTO public.ngo_profiles(user_id, ngo_name, operating_address, latitude, longitude, road_node_id,
                                    active_flag, location_verified_at)
    VALUES (v, 'NGO ' || p_name, 'NGO address', 3.1, 101.6, 'TN-ngo', true, CASE WHEN p_verified THEN now() END);
  ELSIF p_role = 'HUB_ADMIN' THEN
    INSERT INTO public.hub_admin_profiles(user_id, hub_address, latitude, longitude, verified_at)
    VALUES (v, 'Hub address', 3.1, 101.6, now());
  END IF;
  RETURN v;
END $$;
CREATE FUNCTION test_harness.cat(p_name text) RETURNS uuid LANGUAGE sql STABLE AS
  $$ SELECT category_id FROM public.donation_categories WHERE category_name = p_name $$;
-- Stage an uploaded object exactly as Supabase Storage records it (metadata size + mimetype).
CREATE FUNCTION test_harness.stage(p_owner text, p_request uuid, p_ext text DEFAULT 'jpg', p_size integer DEFAULT 1234,
  p_mime text DEFAULT 'image/jpeg', p_legacy_donation uuid DEFAULT NULL) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_path text;
BEGIN
  v_path := test_harness.uid(p_owner)::text || '/' ||
            CASE WHEN p_legacy_donation IS NULL THEN 'pending/' || p_request::text ELSE p_legacy_donation::text END ||
            '/' || gen_random_uuid()::text || '.' || p_ext;
  INSERT INTO storage.objects(bucket_id, name, owner, metadata)
  VALUES ('geolock-donation-images', v_path, test_harness.uid(p_owner),
          jsonb_build_object('size', p_size, 'mimetype', p_mime));
  RETURN v_path;
END $$;
CREATE FUNCTION test_harness.photo(p_path text, p_size integer DEFAULT 1234, p_mime text DEFAULT 'image/jpeg') RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$ SELECT jsonb_build_object('storage_path', p_path, 'content_type', p_mime, 'size_bytes', p_size) $$;
CREATE FUNCTION test_harness.item(p_pos integer, p_name text, p_cat text, p_qty integer, p_unit numeric, p_photo jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object('item_position', p_pos, 'item_name', p_name, 'category_id', test_harness.cat(p_cat),
    'quantity', p_qty, 'unit_weight_kg', p_unit, 'unit_label', 'piece', 'item_condition', 'GOOD')
    || CASE WHEN p_photo IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('photo', p_photo) END $$;
-- Legacy item payload (no position, no photo).
CREATE FUNCTION test_harness.legacy_item(p_name text, p_cat text, p_qty integer, p_unit numeric) RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object('item_name', p_name, 'category_id', test_harness.cat(p_cat), 'quantity', p_qty,
    'unit_weight_kg', p_unit, 'unit_label', 'piece', 'item_condition', 'GOOD') $$;
-- Call the RPCs as the current role, with a fixed pickup location.
CREATE FUNCTION test_harness.create_items(p_request uuid, p_items jsonb, p_title text DEFAULT 'Item photo donation')
RETURNS uuid LANGUAGE plpgsql AS $$
BEGIN
  RETURN public.create_donation_with_item_photos(p_request, p_title, 'Test description'::text, 'Pickup address 1'::text,
    3.10::double precision, 101.60::double precision, p_items, NULL::text);
END $$;
CREATE FUNCTION test_harness.create_legacy(p_request uuid, p_items jsonb, p_images jsonb, p_title text DEFAULT 'Legacy donation')
RETURNS uuid LANGUAGE plpgsql AS $$
BEGIN
  RETURN public.create_donation_with_images(p_request, p_title, 'Test description'::text, 'Pickup address 1'::text,
    3.10::double precision, 101.60::double precision, p_items, NULL::text, p_images);
END $$;
CREATE FUNCTION test_harness.legacy_photo(p_path text, p_size integer DEFAULT 1234, p_mime text DEFAULT 'image/jpeg') RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$ SELECT jsonb_build_object('storage_path', p_path, 'content_type', p_mime, 'size_bytes', p_size) $$;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA test_harness TO anon, authenticated;

-- Users and hubs ----------------------------------------------------------------------
SELECT test_harness.make_user('donor1', 'DONOR');
SELECT test_harness.make_user('donor2', 'DONOR');
SELECT test_harness.make_user('donor_legacy', 'DONOR');
SELECT test_harness.make_user('ngo_eligible', 'NGO');
SELECT test_harness.make_user('ngo_far', 'NGO');
SELECT test_harness.make_user('ngo_unverified', 'NGO', false);
SELECT test_harness.make_user('ngo_claimant', 'NGO');
SELECT test_harness.make_user('ngo_other', 'NGO');
SELECT test_harness.make_user('hub_admin_a', 'HUB_ADMIN');
SELECT test_harness.make_user('hub_admin_b', 'HUB_ADMIN');
SELECT test_harness.make_user('no_profile', NULL);
DO $hubs$
DECLARE v_a uuid; v_b uuid;
BEGIN
  INSERT INTO public.community_hubs(admin_user_id, hub_name, address_text, latitude, longitude, capacity_kg)
  VALUES (test_harness.uid('hub_admin_a'), 'Hub A', 'Hub A address', 3.11, 101.61, 100) RETURNING hub_id INTO v_a;
  INSERT INTO public.community_hubs(admin_user_id, hub_name, address_text, latitude, longitude, capacity_kg)
  VALUES (test_harness.uid('hub_admin_b'), 'Hub B', 'Hub B address', 3.12, 101.62, 100) RETURNING hub_id INTO v_b;
  PERFORM test_harness.set_fact('hub_a', v_a::text);
  PERFORM test_harness.set_fact('hub_b', v_b::text);
END $hubs$;

-- Legacy donations created by the UNCHANGED legacy RPC, before the migration ----------
DO $legacy$
DECLARE r uuid := gen_random_uuid(); d uuid; p1 text; p2 text; p3 text;
BEGIN
  p1 := test_harness.stage('donor_legacy', r); p2 := test_harness.stage('donor_legacy', r, 'png', 2222, 'image/png');
  p3 := test_harness.stage('donor_legacy', r, 'webp', 3333, 'image/webp');
  PERFORM test_harness.act('donor_legacy');
  d := test_harness.create_legacy(r,
         jsonb_build_array(test_harness.legacy_item('Rice', 'Food', 2, 5.5), test_harness.legacy_item('Notebooks', 'School Supplies', 10, 0.2)),
         jsonb_build_array(test_harness.legacy_photo(p1), test_harness.legacy_photo(p2, 2222, 'image/png'),
                           test_harness.legacy_photo(p3, 3333, 'image/webp')), 'Legacy three-photo donation');
  PERFORM test_harness.admin();
  PERFORM test_harness.set_fact('legacy_direct', d::text);
  PERFORM test_harness.set_fact('legacy_direct_request', r::text);
END $legacy$;
DO $legacy2$
DECLARE r uuid := gen_random_uuid(); d uuid; p1 text;
BEGIN
  p1 := test_harness.stage('donor_legacy', r);
  PERFORM test_harness.act('donor_legacy');
  d := test_harness.create_legacy(r, jsonb_build_array(test_harness.legacy_item('Shirt', 'Clothing', 3, 0.5)),
                                  jsonb_build_array(test_harness.legacy_photo(p1)), 'Legacy one-photo hub donation');
  PERFORM test_harness.admin();
  PERFORM test_harness.set_fact('legacy_hub', d::text);
END $legacy2$;

-- Snapshot of everything the migration must leave unchanged ---------------------------
CREATE TABLE test_harness.before_images AS
  SELECT image_id, donation_id, owner_user_id, storage_path, content_type, size_bytes, is_primary, display_order, created_at
  FROM public.donation_images;
CREATE TABLE test_harness.before_items AS
  SELECT item_id, donation_id, category_id, item_name, description, quantity, unit_label, unit_weight_kg, item_condition, created_at
  FROM public.donation_items;
CREATE TABLE test_harness.before_reader_output (reader text, output jsonb);
DO $snap$
DECLARE v1 jsonb; v2 jsonb; v3 jsonb; v4 jsonb;
BEGIN
  PERFORM test_harness.act('donor_legacy');
  v1 := test_harness.rows_json('SELECT * FROM public.get_donation_images(' || quote_literal(test_harness.fact('legacy_direct')) || ')');
  v2 := test_harness.rows_json('SELECT * FROM public.get_my_donation_dashboard_v3()');
  v3 := test_harness.rows_json('SELECT * FROM public.get_my_donation_dashboard_v2()');
  v4 := to_jsonb(public.get_my_donation_detail(test_harness.fact('legacy_direct')::uuid));
  PERFORM test_harness.admin();
  INSERT INTO test_harness.before_reader_output VALUES
    ('get_donation_images', v1), ('get_my_donation_dashboard_v3', v2),
    ('get_my_donation_dashboard_v2', v3), ('get_my_donation_detail', v4);
END $snap$;
CREATE TABLE test_harness.before_catalog AS
  SELECT 'function_acl:' || p.oid::regprocedure::text AS key, coalesce(p.proacl::text, 'default') AS value
    FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
  UNION ALL
  SELECT 'function_body:' || p.oid::regprocedure::text, md5(replace(p.prosrc, chr(13), ''))
    FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
  UNION ALL
  SELECT 'policy:' || schemaname || '.' || tablename || '.' || policyname,
         md5(concat_ws('|', permissive, roles::text, cmd, qual, with_check))
    FROM pg_policies WHERE schemaname IN ('public', 'storage')
  UNION ALL
  SELECT 'table_acl:' || c.oid::regclass::text, coalesce(c.relacl::text, 'default')
    FROM pg_class c WHERE c.relnamespace IN ('public'::regnamespace, 'storage'::regnamespace) AND c.relkind = 'r'
  UNION ALL
  SELECT 'bucket:' || id, concat_ws('|', public, file_size_limit, allowed_mime_types::text) FROM storage.buckets;
SELECT 'FIXTURES_READY' AS status, (SELECT count(*) FROM public.donations) AS donations,
       (SELECT count(*) FROM public.donation_images) AS images;
