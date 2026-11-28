-- LOCAL TEST HARNESS ONLY. Runs after 20_tests_after_migration.sql (the 20261126120000 state,
-- including donations committed under the earlier "at least one photo" rule) and BEFORE
-- 20261128120000_require_photo_for_every_item.sql. Snapshots what that migration must not change.
SET client_min_messages = warning;
\set ON_ERROR_STOP 1

CREATE TABLE test_harness.every_photo_marker AS SELECT coalesce(max(seq), 0) AS seq FROM test_harness.results;

-- Catalogue in every non-system schema: function bodies, settings and grants; triggers;
-- constraints; indexes; RLS policies; table grants; Storage buckets.
CREATE TABLE test_harness.every_photo_catalog AS
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
  UNION ALL SELECT 'bucket:' || id, concat_ws('|', public, file_size_limit, allowed_mime_types::text) FROM storage.buckets;

-- Every existing donation, item, photo and request row, byte for byte.
CREATE TABLE test_harness.every_photo_rows AS
  SELECT 'donation:' || donation_id AS key, md5(to_jsonb(d)::text) AS value FROM public.donations d
  UNION ALL SELECT 'item:' || item_id, md5(to_jsonb(i)::text) FROM public.donation_items i
  UNION ALL SELECT 'image:' || image_id, md5(to_jsonb(g)::text) FROM public.donation_images g
  UNION ALL SELECT 'request:' || request_id, md5(to_jsonb(r)::text) FROM public.donation_create_requests r
  UNION ALL SELECT 'listing:' || listing_id, md5(to_jsonb(l)::text) FROM public.listings l;

-- What the donor sees for a legacy donation and for a donation made under the earlier rule.
CREATE TABLE test_harness.every_photo_reader_output (reader text, output jsonb);
GRANT SELECT, INSERT ON test_harness.every_photo_reader_output TO authenticated, anon;
GRANT SELECT ON test_harness.every_photo_marker, test_harness.every_photo_catalog, test_harness.every_photo_rows TO authenticated, anon;
DO $snap$
DECLARE v_partial text := test_harness.fact('B3 three items, item 1 unphotographed');
BEGIN
  PERFORM test_harness.act('donor_legacy');
  INSERT INTO test_harness.every_photo_reader_output VALUES
    ('legacy:get_donation_images', test_harness.rows_json('SELECT * FROM public.get_donation_images(' || quote_literal(test_harness.fact('legacy_direct')) || ')')),
    ('legacy:get_my_donation_items', test_harness.rows_json('SELECT * FROM public.get_my_donation_items(' || quote_literal(test_harness.fact('legacy_direct')) || ')')),
    ('legacy:get_my_donation_detail', to_jsonb(public.get_my_donation_detail(test_harness.fact('legacy_direct')::uuid))),
    ('legacy:dashboard_v3', test_harness.rows_json('SELECT * FROM public.get_my_donation_dashboard_v3()'));
  PERFORM test_harness.act('donor1');
  INSERT INTO test_harness.every_photo_reader_output VALUES
    ('partial:get_my_donation_items', test_harness.rows_json('SELECT * FROM public.get_my_donation_items(' || quote_literal(v_partial) || ')')),
    ('partial:get_my_donation_detail', to_jsonb(public.get_my_donation_detail(v_partial::uuid))),
    ('partial:get_donation_images', test_harness.rows_json('SELECT * FROM public.get_donation_images(' || quote_literal(v_partial) || ')'));
  PERFORM test_harness.admin();
END $snap$;
