-- FAILED LOCAL CANDIDATE: this claim-only change does NOT remove deadlocks.
-- DO NOT DEPLOY. Shared geolock_lock_listing_donations still upgrades to FOR UPDATE.
-- Retained for review/evidence; further correction requires wider authorization.
-- Proposed forward version: 20261105120000. Not placed in deployable migrations.
-- Business-function diff: one listing row lock; all other source is preserved.
BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '30s';
DO $claim_lock_patch$
DECLARE
  target oid := to_regprocedure('public.claim_listing(uuid,uuid)');
  before_body text;
  definition text;
  after_body text;
  before_metadata jsonb;
  after_metadata jsonb;
  old_anchor constant text := 'select * into v_l from public.listings where listing_id=p_listing for update;';
  new_anchor constant text := 'select * into v_l from public.listings where listing_id=p_listing for no key update;';
BEGIN
  IF target IS NULL THEN RAISE EXCEPTION 'CLAIM_LOCK_PATCH_MISSING_FUNCTION'; END IF;
  SELECT replace(prosrc,chr(13),''), pg_get_functiondef(oid),
    jsonb_build_object('oid',oid,'owner',proowner,'acl',proacl,'definer',prosecdef,'config',proconfig)
    INTO before_body,definition,before_metadata FROM pg_proc WHERE oid=target;
  IF md5(before_body) <> '2c1f60c876797c61b44b3cb43591bab8'
    OR (length(before_body)-length(replace(before_body,old_anchor,'')))/length(old_anchor) <> 1
    OR position(new_anchor IN before_body)>0 THEN
    RAISE EXCEPTION 'CLAIM_LOCK_PATCH_SOURCE_DRIFT';
  END IF;
  IF (SELECT proowner<> 'postgres'::regrole OR NOT prosecdef OR proconfig IS DISTINCT FROM
      ARRAY['search_path=pg_catalog, public, extensions, pg_temp'] FROM pg_proc WHERE oid=target) THEN
    RAISE EXCEPTION 'CLAIM_LOCK_PATCH_AUTH_METADATA_DRIFT';
  END IF;
  -- These are the only listing columns changed by the pinned claim body.
  -- Do not use the weaker lock if either becomes a unique/index/FK key.
  IF EXISTS (
    SELECT 1 FROM pg_index i JOIN pg_attribute a ON a.attrelid=i.indrelid
      AND a.attnum=ANY(i.indkey::smallint[])
    WHERE i.indrelid='public.listings'::regclass AND i.indisunique
      AND a.attname IN ('listing_status','listing_version')
  ) OR EXISTS (
    SELECT 1 FROM pg_constraint c JOIN pg_attribute a ON a.attrelid=c.confrelid AND a.attnum=ANY(c.confkey)
    WHERE c.contype='f' AND c.confrelid='public.listings'::regclass
      AND a.attname IN ('listing_status','listing_version')
  ) THEN RAISE EXCEPTION 'CLAIM_LOCK_PATCH_LISTING_KEY_DRIFT'; END IF;
  -- Reject unknown listing triggers. Review new trigger behavior before patching.
  IF (SELECT count(*) FROM pg_trigger WHERE tgrelid='public.listings'::regclass AND NOT tgisinternal)<>1
    OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid='public.listings'::regclass
      AND NOT tgisinternal AND tgname='trg_listing_transition'
      AND tgfoid='public.enforce_listing_transition()'::regprocedure AND tgenabled='O') THEN
    RAISE EXCEPTION 'CLAIM_LOCK_PATCH_LISTING_TRIGGER_DRIFT';
  END IF;
  -- Trigger body fingerprint is checked against the reviewed local dependency.
  IF md5((SELECT replace(prosrc,chr(13),'') FROM pg_proc
    WHERE oid='public.enforce_listing_transition()'::regprocedure)) <> 'c65f4b675734d8c28816066ea9f05603' THEN
    RAISE EXCEPTION 'CLAIM_LOCK_PATCH_LISTING_TRIGGER_SOURCE_DRIFT';
  END IF;
  IF (length(definition)-length(replace(definition,old_anchor,'')))/length(old_anchor)<>1 THEN
    RAISE EXCEPTION 'CLAIM_LOCK_PATCH_DEFINITION_ANCHOR_DRIFT';
  END IF;
  EXECUTE replace(definition,old_anchor,new_anchor);
  SELECT replace(prosrc,chr(13),''),
    jsonb_build_object('oid',oid,'owner',proowner,'acl',proacl,'definer',prosecdef,'config',proconfig)
    INTO after_body,after_metadata FROM pg_proc WHERE oid=target;
  IF after_body IS DISTINCT FROM replace(before_body,old_anchor,new_anchor)
    OR md5(after_body)<>'c8d324772b12c843fba231e7ea733914'
    OR after_metadata IS DISTINCT FROM before_metadata THEN
    RAISE EXCEPTION 'CLAIM_LOCK_PATCH_POSTCONDITION_FAILED';
  END IF;
END $claim_lock_patch$;
COMMIT;
