-- =====================================================================================
-- ROLLBACK for 20261126120000_item_level_donation_photos.sql. Do not run unless asked.
--
-- Step 1 (always) disables the feature. It drops the new RPC, the four readers and the
--   position trigger, so no new item-linked photo can be created. Existing photos and
--   rows stay untouched.
--
-- Step 2 (only when it loses nothing that matters) restores the exact pre-migration
--   schema. Conditions:
--     * no photo is linked to an item;
--     * no donation has a display_order above 3.
--   When both hold, it drops item_id, its FK and unique index, item_position, its CHECK
--   and unique index, and restores donation_images_order_range to 1..3. Positions
--   assigned to items since deployment are then discarded; no existing reader uses them.
--   Otherwise it keeps the schema and data and raises a NOTICE. All existing functions
--   keep working with the extra columns present, and nothing is deleted or reassigned.
-- =====================================================================================
BEGIN;
SET LOCAL lock_timeout = '5s';

DROP FUNCTION IF EXISTS public.create_donation_with_item_photos(uuid,text,text,text,double precision,double precision,jsonb,text);
DROP FUNCTION IF EXISTS public.get_my_donation_items(uuid);
DROP FUNCTION IF EXISTS public.get_my_hub_donation_items(uuid,uuid);
DROP FUNCTION IF EXISTS public.get_eligible_listing_items(uuid);
DROP FUNCTION IF EXISTS public.get_claimed_listing_items(uuid);
DROP TRIGGER IF EXISTS trg_items_position ON public.donation_items;
DROP FUNCTION IF EXISTS public.geolock_assign_donation_item_position();

DO $schema$
DECLARE v_linked bigint := 0; v_high bigint;
BEGIN
  IF EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.donation_images'::regclass
               AND attname = 'item_id' AND NOT attisdropped) THEN
    EXECUTE 'SELECT count(*) FROM public.donation_images WHERE item_id IS NOT NULL' INTO v_linked;
  END IF;
  SELECT count(*) INTO v_high FROM public.donation_images WHERE display_order > 3;
  IF v_linked > 0 OR v_high > 0 THEN
    RAISE NOTICE 'ITEM_PHOTO_ROLLBACK_SCHEMA_KEPT: % item-linked photos, % photos above display_order 3. Feature disabled; schema and data kept.',
      v_linked, v_high;
    RETURN;
  END IF;
  ALTER TABLE public.donation_images DROP CONSTRAINT IF EXISTS donation_images_item_same_donation_fkey;
  DROP INDEX IF EXISTS public.ux_donation_images_one_per_item;
  ALTER TABLE public.donation_images DROP COLUMN IF EXISTS item_id;
  DROP INDEX IF EXISTS public.ux_donation_items_position;
  ALTER TABLE public.donation_items DROP CONSTRAINT IF EXISTS donation_items_item_position_check;
  ALTER TABLE public.donation_items DROP COLUMN IF EXISTS item_position;
  ALTER TABLE public.donation_images DROP CONSTRAINT donation_images_order_range;
  ALTER TABLE public.donation_images ADD CONSTRAINT donation_images_order_range
    CHECK (((display_order >= 1) AND (display_order <= 3) AND (is_primary = (display_order = 1))));
  RAISE NOTICE 'ITEM_PHOTO_ROLLBACK_SCHEMA_RESTORED';
END
$schema$;

COMMIT;
