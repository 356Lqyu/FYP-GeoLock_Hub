-- REVIEW ONLY: code rollback reintroduces the original deadlock risk.
-- No claim/history/data rollback. Use only after explicit operator approval.
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='30s';
DO $restore_claim_lock$
DECLARE
 target oid:=to_regprocedure('public.claim_listing(uuid,uuid)');
 body text; definition text; restored text; metadata jsonb; current_metadata jsonb;
 old_anchor constant text:='select * into v_l from public.listings where listing_id=p_listing for no key update;';
 new_anchor constant text:='select * into v_l from public.listings where listing_id=p_listing for update;';
BEGIN
 SELECT replace(prosrc,chr(13),''),pg_get_functiondef(oid),
   jsonb_build_object('oid',oid,'owner',proowner,'acl',proacl,'definer',prosecdef,'config',proconfig)
 INTO body,definition,metadata FROM pg_proc WHERE oid=target;
 IF body IS NULL OR md5(body)<>'c8d324772b12c843fba231e7ea733914'
   OR (length(definition)-length(replace(definition,old_anchor,'')))/length(old_anchor)<>1 THEN
   RAISE EXCEPTION 'CLAIM_LOCK_ROLLBACK_SOURCE_DRIFT';
 END IF;
 EXECUTE replace(definition,old_anchor,new_anchor);
 SELECT replace(prosrc,chr(13),''),
   jsonb_build_object('oid',oid,'owner',proowner,'acl',proacl,'definer',prosecdef,'config',proconfig)
 INTO restored,current_metadata FROM pg_proc WHERE oid=target;
 IF restored IS DISTINCT FROM replace(body,old_anchor,new_anchor)
   OR md5(restored)<>'2c1f60c876797c61b44b3cb43591bab8'
   OR current_metadata IS DISTINCT FROM metadata THEN
   RAISE EXCEPTION 'CLAIM_LOCK_ROLLBACK_POSTCONDITION_FAILED';
 END IF;
END $restore_claim_lock$;
COMMIT;
