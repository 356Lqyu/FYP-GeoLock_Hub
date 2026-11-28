-- LOCAL TEST HARNESS ONLY. Runs after 25_tests_every_item_photo.sql, a row snapshot
-- (36_ step in run_every_item_photo.sh) and the ROLLBACK file.
SET client_min_messages = warning;
\set ON_ERROR_STOP 1
CREATE TABLE test_harness.every_photo_rb_marker AS SELECT coalesce(max(seq), 0) AS seq FROM test_harness.results;
DO $rb$
DECLARE v_diff text; v_rows text; r uuid := gen_random_uuid(); v_new uuid;
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
  ) a USING (key) WHERE a.value IS DISTINCT FROM b.value;
  PERFORM test_harness.ok('E-RB1 rollback restores the exact pre-change catalogue (function body, owner, security, grants)', v_diff IS NULL, v_diff);
  SELECT string_agg(coalesce(b.key, a.key), '; ') INTO v_rows FROM test_harness.every_photo_rb_rows b
  FULL JOIN (
    SELECT 'donation:' || donation_id AS key, md5(to_jsonb(d)::text) AS value FROM public.donations d
    UNION ALL SELECT 'item:' || item_id, md5(to_jsonb(i)::text) FROM public.donation_items i
    UNION ALL SELECT 'image:' || image_id, md5(to_jsonb(g)::text) FROM public.donation_images g
    UNION ALL SELECT 'request:' || request_id, md5(to_jsonb(q)::text) FROM public.donation_create_requests q
  ) a USING (key) WHERE a.value IS DISTINCT FROM b.value;
  PERFORM test_harness.ok('E-RB2 rollback deletes or changes no donation, item, photo or request row', v_rows IS NULL, v_rows);
  PERFORM test_harness.act('donor1');
  v_new := test_harness.create_items(r, test_harness.build_items('donor1', r, 3, ARRAY[2]));
  PERFORM test_harness.admin();
  PERFORM test_harness.ok('E-RB3 after rollback the earlier rule applies again (partial photos accepted)', v_new IS NOT NULL);
END $rb$;
SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, name, left(coalesce(detail, ''), 160) AS detail
  FROM test_harness.results WHERE seq > (SELECT seq FROM test_harness.every_photo_rb_marker) ORDER BY seq;
