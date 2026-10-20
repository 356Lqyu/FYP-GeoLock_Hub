-- Restrict the protected claim RPC to authenticated application callers.
-- This migration intentionally changes only the anon EXECUTE privilege.
BEGIN;

DO $$
BEGIN
  IF to_regprocedure('public.claim_listing(uuid,uuid)') IS NULL THEN
    RAISE EXCEPTION 'Required function public.claim_listing(uuid,uuid) is missing';
  END IF;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.claim_listing(uuid, uuid) FROM anon;

COMMIT;
