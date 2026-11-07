"""Source safety boundaries; behavior is covered by disposable PG suites."""
from pathlib import Path
import re
import unittest
ROOT=Path(__file__).resolve().parents[2]
SQL=(ROOT/'supabase/migrations/20261104130000_unstarted_released_route_cancellation.sql').read_text(encoding='utf-8')

def body(name):
    match=re.search(r'CREATE(?: OR REPLACE)? FUNCTION '+re.escape(name)+r'\([^$]+?AS \$\$(.*?)\$\$;',SQL,re.S)
    assert match,name
    return match.group(1)

class Contracts(unittest.TestCase):
    def test_single_forward_transaction_and_drift_guards(self):
        self.assertEqual(SQL.count('\nBEGIN;'),1);self.assertEqual(SQL.count('\nCOMMIT;'),1)
        self.assertIn('SAFE_CANCELLATION_SOURCE_DRIFT',SQL)
        self.assertNotIn('CREATE TABLE',SQL);self.assertNotIn('CREATE ROLE',SQL)
    def test_read_rpcs_and_eligibility_do_not_mutate(self):
        for name in ['public.get_my_claim_coordination','public.get_my_donation_coordination','public.get_my_authorized_route','routing_private.coord_blocker','routing_private.coord_can_cancel','routing_private.coord_safe_released','routing_private.coord_route_kind']:
            self.assertNotRegex(body(name),r'(?i)\b(INSERT INTO|UPDATE public\.|DELETE FROM)')
    def test_released_tasks_are_not_requeued(self):
        cancel=body('public.cancel_my_unstarted_route')
        self.assertIn('IF NOT all_released THEN',cancel)
        self.assertIn("AND released_at IS NULL",cancel)
        self.assertNotIn('UPDATE public.donation_claims',cancel)
        self.assertNotIn('UPDATE public.claim_leases',cancel)
    def test_evidence_history_and_receipt_compatibility(self):
        self.assertIn('CLAIM_EVIDENCE_IMMUTABLE',SQL)
        self.assertIn('ROUND_AWARE_CLIENT_REQUIRED',SQL)
        self.assertIn('COUNTERPART_ACCEPTANCE_REQUIRED',SQL)
        self.assertIn('REVIEW_CONTEXT_CHANGED',SQL)
        self.assertIn('RETURN e.response',body('public.submit_claim_reconciliation'))
        self.assertNotIn('DELETE FROM public.claim_reconciliation_evidence',SQL)
    def test_no_food_can_data_patch_or_client_private_grants(self):
        self.assertNotIn('53448e5f-85bd-482f-8904-e1237a70769e',SQL)
        self.assertNotRegex(SQL,r'GRANT EXECUTE ON FUNCTION routing_private[.]')
        self.assertIn('REVOKE ALL ON FUNCTION %s FROM PUBLIC,anon,authenticated,service_role',SQL)
    def test_transaction_bound_permits_and_vehicle_origin(self):
        self.assertIn('pg_current_xact_id()',body('routing_private.coord_release_allowed'))
        self.assertIn('VEHICLE_AT_DEPOT_CHECKPOINT_REQUIRED',SQL)
        self.assertIn('vehicle_version',body('routing_private.coord_checkpoint'))
        self.assertNotIn("'depot_return_confirmed',true",body('routing_private.coord_decide'))
if __name__=='__main__':unittest.main(verbosity=2)
