-- LOCAL TEST HARNESS ONLY. Run after the rollback file. Two scenarios, chosen with -v scenario=used|unused:
--   used   : rollback after the full test suite (item photos exist) -> feature off, schema and data kept
--   unused : rollback right after the migration (no item photos)    -> exact pre-migration catalog
\set ON_ERROR_STOP 1
SET client_min_messages = warning;
CREATE TABLE IF NOT EXISTS test_harness.rollback_results (name text, ok boolean, detail text);
SELECT set_config('test.scenario', :'scenario', false);
DO $r$
DECLARE v_diff text; v_scn text := current_setting('test.scenario');
        v_new int; r uuid := gen_random_uuid(); d uuid; v_p text;
BEGIN
  SELECT count(*) INTO v_new FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname IN
    ('create_donation_with_item_photos','get_my_donation_items','get_my_hub_donation_items',
     'get_eligible_listing_items','get_claimed_listing_items','geolock_assign_donation_item_position');
  INSERT INTO test_harness.rollback_results VALUES ('R1 [' || v_scn || '] all 6 new functions and the trigger removed',
    v_new = 0 AND NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_items_position'), v_new::text);
  SELECT string_agg(b.key, '; ') INTO v_diff FROM test_harness.before_catalog b
  LEFT JOIN (
    SELECT 'function_acl:' || p.oid::regprocedure::text AS key, coalesce(p.proacl::text, 'default') AS value FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
    UNION ALL SELECT 'function_body:' || p.oid::regprocedure::text, md5(replace(p.prosrc, chr(13), '')) FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
    UNION ALL SELECT 'policy:' || schemaname || '.' || tablename || '.' || policyname, md5(concat_ws('|', permissive, roles::text, cmd, qual, with_check)) FROM pg_policies WHERE schemaname IN ('public','storage')
    UNION ALL SELECT 'table_acl:' || c.oid::regclass::text, coalesce(c.relacl::text, 'default') FROM pg_class c WHERE c.relnamespace IN ('public'::regnamespace, 'storage'::regnamespace) AND c.relkind = 'r'
    UNION ALL SELECT 'bucket:' || id, concat_ws('|', public, file_size_limit, allowed_mime_types::text) FROM storage.buckets) a USING (key)
  WHERE a.value IS DISTINCT FROM b.value;
  INSERT INTO test_harness.rollback_results VALUES ('R2 [' || v_scn || '] every pre-existing function, grant, policy and bucket identical to before the migration',
    v_diff IS NULL AND (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace)
                       = (SELECT count(*) FROM test_harness.before_catalog WHERE key LIKE 'function_body:%'), v_diff);
  IF v_scn = 'unused' THEN
    INSERT INTO test_harness.rollback_results VALUES ('R3 [unused] item columns gone and order range back to exactly 1..3',
      NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.donation_items'::regclass AND attname = 'item_position' AND NOT attisdropped)
      AND NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.donation_images'::regclass AND attname = 'item_id' AND NOT attisdropped)
      AND (SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'donation_images_order_range')
          = 'CHECK (((display_order >= 1) AND (display_order <= 3) AND (is_primary = (display_order = 1))))', NULL);
  ELSE
    INSERT INTO test_harness.rollback_results VALUES ('R3 [used] item-linked photos and positions kept, nothing deleted or reassigned',
      (SELECT count(*) FROM public.donation_images WHERE item_id IS NOT NULL) > 0
      AND NOT EXISTS (SELECT 1 FROM test_harness.before_images b WHERE NOT EXISTS (SELECT 1 FROM public.donation_images i WHERE i.image_id = b.image_id)), NULL);
  END IF;
  -- Legacy RPC still works after rollback
  v_p := test_harness.stage('donor2', r);
  PERFORM test_harness.act('donor2');
  d := test_harness.create_legacy(r, jsonb_build_array(test_harness.legacy_item('After rollback', 'Food', 1, 1)),
                                  jsonb_build_array(test_harness.legacy_photo(v_p)), 'Created after rollback');
  PERFORM test_harness.admin();
  INSERT INTO test_harness.rollback_results VALUES ('R4 [' || v_scn || '] legacy create_donation_with_images works after rollback', d IS NOT NULL, NULL);
END $r$;
SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, name, detail FROM test_harness.rollback_results;
