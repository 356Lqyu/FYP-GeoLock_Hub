-- READ-ONLY post-deployment check for 20261128120000_require_photo_for_every_item.sql.
-- Run in the NEW KLSEL SQL Editor (ppwmdsyoesvhgmqiaoxa) right after deploying.
-- Expect pass = true. Then compare Q2 and Q3 with the pre-deployment audit output: they must match.
BEGIN TRANSACTION READ ONLY;

-- Q1 Verdict
WITH c AS (
  SELECT
    (SELECT md5(replace(prosrc, chr(13), '')) FROM pg_proc WHERE oid = to_regprocedure(
       'public.create_donation_with_item_photos(uuid,text,text,text,double precision,double precision,jsonb,text)'))
      = '199df942b0a4d00d63649985fda61a88' AS rpc_requires_photo_on_every_item,
    (SELECT prosecdef AND proconfig::text LIKE '%search_path=pg_catalog, public, extensions, storage, pg_temp%'
       FROM pg_proc WHERE oid = 'public.create_donation_with_item_photos(uuid,text,text,text,double precision,double precision,jsonb,text)'::regprocedure)
      AS rpc_security_and_search_path,
    NOT has_function_privilege('anon', 'public.create_donation_with_item_photos(uuid,text,text,text,double precision,double precision,jsonb,text)', 'EXECUTE')
      AND has_function_privilege('authenticated', 'public.create_donation_with_item_photos(uuid,text,text,text,double precision,double precision,jsonb,text)', 'EXECUTE')
      AS rpc_grants,
    (SELECT md5(replace(prosrc, chr(13), '')) FROM pg_proc WHERE oid = to_regprocedure(
       'public.create_donation_with_images(uuid,text,text,text,double precision,double precision,jsonb,text,jsonb)'))
      = '102cadd77c875339cbe12e5677c7872c' AS legacy_rpc_unchanged,
    (SELECT md5(replace(prosrc, chr(13), '')) FROM pg_proc WHERE oid = to_regprocedure(
       'public.create_and_validate_donation(text,text,text,double precision,double precision,jsonb,text)'))
      = 'd32f089f8a6750f099f8cfee63ac0f4d' AS validator_unchanged,
    to_regclass('public.ux_donation_images_one_per_item') IS NOT NULL
      AND EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.donation_images'::regclass
                    AND conname = 'donation_images_item_same_donation_fkey') AS item_photo_constraints)
SELECT *, rpc_requires_photo_on_every_item AND rpc_security_and_search_path AND rpc_grants
          AND legacy_rpc_unchanged AND validator_unchanged AND item_photo_constraints AS pass
FROM c;

-- Q2 Must equal pre-deployment Q2
SELECT p.proowner::regrole AS owner, p.prosecdef, p.proconfig, p.proacl
FROM pg_proc p
WHERE p.oid = 'public.create_donation_with_item_photos(uuid,text,text,text,double precision,double precision,jsonb,text)'::regprocedure;

-- Q3 Must equal pre-deployment Q3 (unless someone created a donation in between)
SELECT (SELECT count(*) FROM public.donations)                AS donations,
       (SELECT count(*) FROM public.donation_items)           AS items,
       (SELECT count(*) FROM public.donation_images)          AS images,
       (SELECT count(*) FROM public.donation_images WHERE item_id IS NOT NULL) AS item_photos,
       (SELECT count(*) FROM public.donation_create_requests) AS create_requests;

ROLLBACK;
