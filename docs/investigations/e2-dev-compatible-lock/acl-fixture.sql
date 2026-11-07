REVOKE EXECUTE ON FUNCTION public.cancel_claim(uuid,uuid) FROM PUBLIC; GRANT EXECUTE ON FUNCTION public.cancel_claim(uuid,uuid) TO authenticated,service_role;
REVOKE EXECUTE ON FUNCTION public.claim_listing(uuid,uuid) FROM PUBLIC; GRANT EXECUTE ON FUNCTION public.claim_listing(uuid,uuid) TO authenticated,service_role;
REVOKE EXECUTE ON FUNCTION public.submit_claim_reconciliation(uuid,boolean,uuid) FROM PUBLIC; GRANT EXECUTE ON FUNCTION public.submit_claim_reconciliation(uuid,boolean,uuid) TO authenticated,service_role;
