-- READ-ONLY pre-deployment audit for 20261128120000_require_photo_for_every_item.sql.
-- Run in the Supabase SQL Editor of NEW KLSEL only. Check the address bar shows
-- ppwmdsyoesvhgmqiaoxa first. Changes nothing (READ ONLY transaction, ROLLBACK at the end).
-- Keep the output: the post-deployment check compares owner, settings, grants and counts with it.
BEGIN TRANSACTION READ ONLY;

-- Q1 Verdict. Every column must be true before deploying.
WITH f AS (
  SELECT p.*, md5(replace(p.prosrc, chr(13), '')) AS body_md5 FROM pg_proc p
  WHERE p.oid = to_regprocedure('public.create_donation_with_item_photos(uuid,text,text,text,double precision,double precision,jsonb,text)'))
SELECT
  (SELECT body_md5 FROM f) = '96489d8f1ba4ea79bd733fb0034f9c2b'                AS rpc_body_is_20261126120000,
  (SELECT body_md5 FROM f) IS DISTINCT FROM '199df942b0a4d00d63649985fda61a88' AS not_yet_applied,
  (SELECT prosecdef FROM f)                                                     AS rpc_security_definer,
  (SELECT md5(replace(prosrc, chr(13), '')) FROM pg_proc WHERE oid = to_regprocedure(
     'public.create_donation_with_images(uuid,text,text,text,double precision,double precision,jsonb,text,jsonb)'))
    = '102cadd77c875339cbe12e5677c7872c'                                        AS legacy_rpc_unchanged,
  (SELECT md5(replace(prosrc, chr(13), '')) FROM pg_proc WHERE oid = to_regprocedure(
     'public.create_and_validate_donation(text,text,text,double precision,double precision,jsonb,text)'))
    = 'd32f089f8a6750f099f8cfee63ac0f4d'                                        AS validator_unchanged,
  to_regclass('public.ux_donation_images_one_per_item') IS NOT NULL             AS one_photo_per_item_index,
  to_regclass('public.ux_donation_items_position') IS NOT NULL                  AS item_position_index,
  EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.donation_images'::regclass
            AND conname = 'donation_images_item_same_donation_fkey')            AS same_donation_fk,
  (SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid = 'public.donation_images'::regclass
     AND conname = 'donation_images_order_range')
    = 'CHECK (((display_order >= 1) AND (display_order <= 30) AND (is_primary = (display_order = 1))))' AS order_range_1_to_30,
  NOT has_function_privilege('anon', 'public.create_donation_with_item_photos(uuid,text,text,text,double precision,double precision,jsonb,text)', 'EXECUTE') AS anon_cannot_execute,
  has_function_privilege('authenticated', 'public.create_donation_with_item_photos(uuid,text,text,text,double precision,double precision,jsonb,text)', 'EXECUTE') AS authenticated_can_execute;

-- Q2 Owner, settings and grants to compare after deployment (must be identical).
SELECT p.proowner::regrole AS owner, p.prosecdef, p.proconfig, p.proacl
FROM pg_proc p
WHERE p.oid = 'public.create_donation_with_item_photos(uuid,text,text,text,double precision,double precision,jsonb,text)'::regprocedure;

-- Q3 Row counts to compare after deployment (the migration writes no rows).
SELECT (SELECT count(*) FROM public.donations)                AS donations,
       (SELECT count(*) FROM public.donation_items)           AS items,
       (SELECT count(*) FROM public.donation_images)          AS images,
       (SELECT count(*) FROM public.donation_images WHERE item_id IS NOT NULL) AS item_photos,
       (SELECT count(*) FROM public.donation_create_requests) AS create_requests;

-- Q4 Donations made under the earlier rule that have an item without a photo. They stay as
-- they are; this only tells you how many exist.
SELECT count(DISTINCT i.donation_id) AS donations_with_an_unphotographed_item
FROM public.donation_items i
WHERE i.item_position IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM public.donation_images g WHERE g.item_id = i.item_id);

ROLLBACK;
