"""Static proposal checks only: no SQL, subprocess, database or network calls."""
import hashlib
import importlib.util
import json
from pathlib import Path
import unittest

ROOT=Path(__file__).resolve().parents[2]
HERE=ROOT/'docs/stage8/integration/reconciliation'
spec=importlib.util.spec_from_file_location('builder',HERE/'build_proposal.py')
builder=importlib.util.module_from_spec(spec);spec.loader.exec_module(builder)


class StaticTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sql,cls.combined,cls.pins,cls.insertion,cls.original,cls.revised=builder.render()

    def test_original_guard_and_migration_unchanged(self):
        self.assertEqual(hashlib.sha256((HERE.parent/'003_pickup_enforcement_proposal.sql').read_bytes()).hexdigest(),
            'e968ca18e5d70b70c91467dcef567b45ce8cb24aa075b1a6340e1f0c529b5ab7')
        self.assertNotIn('CREATE OR REPLACE FUNCTION routing_private.task_guard',self.sql)
        self.assertNotIn('DISABLE TRIGGER',self.sql.upper())

    def test_only_documented_changes_to_existing_reconciliation(self):
        recovered=self.revised.replace(self.insertion,'')
        recovered=recovered.replace('      perform routing_private.permit_reconciled_collection(p_claim);\n','')
        recovered=recovered.replace('      perform routing_private.finish_reconciled_collection(p_claim);\n','')
        self.assertEqual(recovered,self.original)

    def test_mixed_batch_and_participant_checks_precede_permit(self):
        self.assertLess(self.revised.index('MIXED_BATCH_DONATION_STATES'),self.revised.index('permit_reconciled_collection'))
        self.assertLess(self.revised.index('RECONCILIATION_PARTICIPANT_ONLY'),self.revised.index('permit_reconciled_collection'))
        self.assertIn('v_true=2',self.revised)

    def test_transaction_bound_existing_permit_only(self):
        self.assertIn('SET complete_xid=pg_current_xact_id()',self.sql)
        self.assertNotIn("set_config(",self.sql.lower())
        self.assertNotIn('SET dispatch_xid',self.sql)

    def test_hub_custody_join_uses_member_donation_not_listing_donation(self):
        for sql in (self.sql,self.combined):
            permit=next(m.group(3) for m in builder.PAT.finditer(sql)
                if m.group(1)=='routing_private.permit_reconciled_collection')
            self.assertIn('JOIN public.hub_batch_members m ON m.batch_id=l.batch_id',permit)
            self.assertIn('JOIN public.donations d ON d.donation_id=m.donation_id',permit)
            self.assertNotIn('USING(donation_id)',permit)
            self.assertIn("m.membership_status='ACTIVE'",permit)
            self.assertIn("d.donation_status<>'COLLECTED'",permit)

    def test_no_release_in_private_compatibility_helpers(self):
        helpers=self.sql.split('-- Rebased original RPC')[0]
        self.assertNotIn('DELETE FROM public.active_task_route_assignments',helpers)
        self.assertNotIn('SET closed_at',helpers)
        self.assertNotIn('SET released_at',helpers)

    def test_lock_order(self):
        self.assertLess(self.sql.index("'routing-ngo:'"),self.sql.index('lock_sources(ids)'))
        self.assertLess(self.sql.index('lock_sources(ids)'),self.sql.index('FROM public.vehicles WHERE vehicle_id='))
        self.assertLess(self.sql.index('FROM public.vehicles WHERE vehicle_id='),self.sql.index('FROM public.pickup_routes WHERE route_id='))

    def test_atomic_bundle_has_one_transaction(self):
        self.assertEqual(self.combined.count('\nBEGIN;'),1)
        self.assertEqual(self.combined.count('\nCOMMIT;'),1)
        self.assertLess(self.combined.index('CREATE TRIGGER routing_task_authority'),self.combined.index('permit_reconciled_collection'))

    def test_generated_artifacts_and_hashes_match(self):
        self.assertEqual((HERE/'003_reconciliation_compatibility_proposal.sql').read_text(),self.sql)
        self.assertEqual((HERE/'003_with_reconciliation_proposal.sql').read_text(),self.combined)
        m=json.loads((HERE/'proposal-manifest.json').read_text())
        for name,value in m['files'].items():self.assertEqual(hashlib.sha256((HERE/name).read_bytes()).hexdigest(),value)

    def test_replay_scoped_to_claim_actor_request_and_answer(self):
        self.assertIn('e.request_id=p_request and e.actor_user_id=v_actor',self.insertion)
        self.assertIn('rc.claim_id=p_claim',self.insertion)
        self.assertIn('is not distinct from p_handover_confirmed',self.insertion)

    def test_latest_recovery_pinned_and_not_replaced(self):
        self.assertEqual(self.pins['recovery_md5'],'5ff6d8719db9681aae6f444b89dfbaee')
        self.assertNotIn('CREATE OR REPLACE FUNCTION public.recover_expired_claims',self.sql)

    def test_private_helpers_not_granted_to_clients(self):
        self.assertIn('FROM PUBLIC,anon,authenticated,service_role,geolock_graph_worker,geolock_planner,geolock_validator',self.sql)
        self.assertNotIn('GRANT EXECUTE',self.sql)


if __name__=='__main__':unittest.main(verbosity=2)
