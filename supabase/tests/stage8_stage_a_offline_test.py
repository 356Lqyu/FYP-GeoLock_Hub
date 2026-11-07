"""Current routing composition checks. No SQL, network, credentials or subprocesses.

These verify the NEW Stage A forward package, not execution of historical proposals.
They do not establish SQL compilation, real permissions, JWTs or live acceptance.
"""
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
HERE = ROOT/'docs/stage8/stage-a'
spec = importlib.util.spec_from_file_location('stage_a_builder',HERE/'build_package.py')
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


class StageAContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sql = builder.render()
        cls.current = builder.CURRENT.read_text()
        cls.final = cls.sql[builder.OUTPUTS[2]]

    def test_forward_files_equal_reproducible_render(self):
        for name,sql in self.sql.items():
            self.assertEqual((HERE/'forward-migrations'/name).read_text(),sql)

    def test_forward_manifest_records_local_not_dev_expectations(self):
        manifest = json.loads((HERE/'package-manifest.json').read_text())
        self.assertEqual(manifest['authoritative_sha256'],builder.sha(builder.CURRENT))
        self.assertEqual(manifest['source_pins'],builder.PINS)
        self.assertEqual(manifest['runtime_sql_validation'],'NOT_EXECUTED_STAGE_B_APPROVAL_REQUIRED')
        for name,digest in manifest['files'].items():
            self.assertEqual(digest,builder.sha(HERE/'forward-migrations'/name))

    def test_historical_inputs_and_live_guards_are_unchanged(self):
        for path,digest in json.loads((HERE/'preserved-inputs.json').read_text()).items():
            self.assertEqual(builder.sha(ROOT/path),digest,path)

    def test_private_pickup_bodies_equal_complete_current_bodies(self):
        for name in ('start_pickup','complete_pickup'):
            self.assertEqual(builder.function(self.final,'routing_private.legacy_'+name)[5],
                             builder.function(self.current,'public.'+name)[5])

    def test_start_retains_six_argument_claim_audit_context(self):
        body=builder.function(self.final,'routing_private.legacy_start_pickup')[5]
        self.assertIn("'PICKUP_IN_PROGRESS',p_claim,NULL,'PICKUP_STARTED'",body)
        self.assertNotIn("'CLAIMED','PICKUP_IN_PROGRESS');",body)

    def test_completion_retains_six_argument_claim_audit_context(self):
        body=builder.function(self.final,'routing_private.legacy_complete_pickup')[5]
        self.assertIn("'COLLECTED',p_claim,NULL,'PICKUP_COLLECTED'",body)
        self.assertNotIn("'PICKUP_IN_PROGRESS','COLLECTED');",body)

    def test_both_original_owner_lease_task_and_handover_checks_survive(self):
        for name in ('start_pickup','complete_pickup'):
            body=builder.function(self.final,'routing_private.legacy_'+name)[5]
            for token in ('NOT_ACTIVE_CLAIM_HOLDER','STALE_OR_EXPIRED_LEASE',
                          "v_lease.expires_at<=clock_timestamp()",'LISTING_NOT_CLAIMED'):
                self.assertIn(token,body)
        self.assertIn('HANDOVER_NOT_CONFIRMED',builder.function(self.final,'routing_private.legacy_complete_pickup')[5])

    def test_public_lifecycle_replacement_scope_is_explicit(self):
        names={m[1] for sql in self.sql.values() for m in builder.PAT.finditer(sql)
               if m[0].upper().startswith('CREATE OR REPLACE FUNCTION PUBLIC.')}
        self.assertEqual(names,{'public.assign_task_to_route','public.start_pickup',
                              'public.complete_pickup','public.submit_claim_reconciliation'})

    def test_claim_idempotency_and_failure_ledger_are_not_replaced(self):
        all_sql='\n'.join(self.sql.values())
        self.assertNotIn('CREATE OR REPLACE FUNCTION public.claim_listing',all_sql)
        self.assertNotRegex(all_sql,r'(?i)(?:UPDATE|DELETE FROM|INSERT INTO)\s+public\.operation_failure_events')
        self.assertNotIn('CREATE UNIQUE INDEX operation_failure_claim_request_unique',all_sql)

    def test_no_new_donation_states_or_lease_renewal(self):
        all_sql='\n'.join(self.sql.values())
        self.assertNotRegex(all_sql,r'(?i)ALTER TABLE public\.donations')
        self.assertNotRegex(all_sql,r'(?i)SET\s+expires_at\s*=')
        self.assertNotRegex(all_sql,r'(?i)CREATE (?:OR REPLACE )?FUNCTION [\w.]*renew')
        self.assertIn('claim_lease_minutes=360',all_sql)

    def test_reconciliation_only_adds_three_reviewed_hooks(self):
        revised=builder.function(self.final,'public.submit_claim_reconciliation')[0]
        _,replay=builder.reconciliation(self.current)
        recovered=revised.replace(replay,'')
        recovered=recovered.replace('      perform routing_private.permit_reconciled_collection(p_claim);\n','')
        recovered=recovered.replace('      perform routing_private.finish_reconciled_collection(p_claim);\n','')
        self.assertEqual(recovered,builder.function(self.current,'public.submit_claim_reconciliation')[0])

    def test_resolved_replay_is_authorized_before_return(self):
        _,replay=builder.reconciliation(self.current)
        self.assertLess(replay.index('lock_reconciliation_scope'),replay.index('return v_result'))
        for token in ('e.actor_user_id=v_actor','e.request_id=p_request','rc.claim_id=p_claim',
                      'is not distinct from p_handover_confirmed'):
            self.assertIn(token,replay)
        helper=builder.function(self.final,'routing_private.lock_reconciliation_scope')[5]
        self.assertLess(helper.index('reconciliation_participant'),helper.index('pg_advisory_xact_lock'))

    def test_reconciliation_preserves_current_audit_calls(self):
        body=builder.function(self.final,'public.submit_claim_reconciliation')[5]
        original=builder.function(self.current,'public.submit_claim_reconciliation')[5]
        self.assertIn("p_claim,p_request,'RECONCILED_NO_HANDOVER'",body)
        inserts=lambda sql: re.findall(r'insert into public.audit_events\(.*?;',sql,re.S)
        self.assertEqual(len(inserts(original)),3)
        self.assertEqual(inserts(body),inserts(original))

    def test_guard_and_reconciliation_install_in_one_transaction(self):
        self.assertEqual(len(re.findall(r'^BEGIN;',self.final,re.M)),1)
        self.assertEqual(len(re.findall(r'^COMMIT;',self.final,re.M)),1)
        self.assertLess(self.final.index('CREATE TRIGGER routing_task_authority'),
                        self.final.index('CREATE FUNCTION routing_private.reconciliation_participant'))
        self.assertLess(self.final.index('CREATE OR REPLACE FUNCTION public.submit_claim_reconciliation'),self.final.rindex('COMMIT;'))

    def test_recovery_source_pin_is_current_and_function_is_not_replaced(self):
        self.assertIn(builder.PINS['recover_expired_claims'],self.final)
        self.assertNotIn('CREATE OR REPLACE FUNCTION public.recover_expired_claims',self.final)
        self.assertIn("case_status in ('OPEN','MANUAL_REVIEW')",builder.function(self.current,'public.recover_expired_claims')[5])

    def test_old_source_pin_is_not_blindly_replaced(self):
        changed=self.current.replace("p_claim,NULL,'PICKUP_STARTED'","NULL,NULL,'PICKUP_STARTED'",1)
        with self.assertRaisesRegex(ValueError,'REVIEWED_20261031_SOURCE_DRIFT'):
            builder.source_guard(changed)

    def test_assignment_guard_tracks_publication_dependency_order(self):
        first=builder.source_guard(self.current,first=True)
        final=builder.source_guard(self.current,first=False)
        published=builder.function((builder.OLD/'002_publication_proposal.sql').read_text(),'public.assign_task_to_route')
        self.assertIn('pg_get_functiondef',first)
        self.assertIn('POST_PUBLICATION_ASSIGNMENT_SOURCE_DRIFT',final)
        self.assertIn(builder.md5(published[5]),final)
        self.assertNotIn('pg_get_functiondef',final)

    def test_lifecycle_guard_checks_source_and_security_and_private_helper(self):
        guard=builder.source_guard(self.current)
        for token in ('p.proowner','p.prosecdef','p.provolatile','p.proconfig',
                      'pg_get_function_result','p.prosrc','CURRENT_SIX_ARGUMENT_AUDIT_HELPER_REQUIRED',
                      'PRIVATE_AUDIT_HELPER_PRIVILEGE_DRIFT','session_user'):
            self.assertIn(token,guard)

    def test_authority_rebase_changes_only_reviewed_source_guard(self):
        strip=lambda sql: re.sub(r'DO \$(?:pin|stage_a_source_guard)\$ BEGIN.*?END \$(?:pin|stage_a_source_guard)\$;\n?', '',sql,flags=re.S)
        new=self.sql[builder.OUTPUTS[0]].split('\n',1)[1]
        self.assertEqual(strip(new),strip((builder.OLD/'001_authority_proposal.sql').read_text()))

    def test_publication_architecture_is_preserved_exactly(self):
        self.assertEqual(self.sql[builder.OUTPUTS[1]].split('\n',1)[1],
                         (builder.OLD/'002_publication_proposal.sql').read_text())

    def test_database_cutover_is_required_before_publication(self):
        self.assertIn('DISPATCH_CUTOVER_REQUIRED_BEFORE_AUTHORIZATION',self.sql[builder.OUTPUTS[1]])
        self.assertIn('DATABASE_DISPATCH_AUTHORIZATION_REQUIRED',self.final)
        self.assertIn('dispatch_xid=pg_current_xact_id()',self.final)

    def test_reconciliation_permit_is_transaction_bound_not_a_guc_bypass(self):
        helper=builder.function(self.final,'routing_private.permit_reconciled_collection')[5]
        self.assertIn('VALIDATED_TWO_PARTY_HANDOVER_REQUIRED',helper)
        self.assertIn('SET complete_xid=pg_current_xact_id()',helper)
        self.assertNotIn('set_config(',helper)

    def test_hub_member_and_inventory_logic_is_not_replaced_by_individual_tasks(self):
        body=builder.function(self.final,'routing_private.legacy_complete_pickup')[5]
        for token in ("v_l.source_type='HUB_BATCH'",'public.hub_batch_members',
                      "membership_status='ACTIVE'","inventory_status='COLLECTED'","batch_status='COLLECTED'"):
            self.assertIn(token,body)

    def test_vehicle_release_requires_explicit_depot_closure(self):
        complete=builder.function(self.final,'public.complete_pickup')[5]
        self.assertNotIn('SET released_at',complete)
        close=builder.function(self.final,'public.close_my_collected_route')[5]
        self.assertIn('DEPOT_RETURN_CONFIRMATION_REQUIRED',close)

    def test_private_legacy_functions_remain_inaccessible_to_clients(self):
        self.assertIn('REVOKE ALL ON ALL FUNCTIONS IN SCHEMA routing_private FROM PUBLIC,anon,authenticated,service_role;',self.final)
        self.assertNotIn('GRANT EXECUTE ON FUNCTION routing_private.legacy_',self.final)

    def test_flutter_production_bypass_stays_disabled(self):
        ui=(ROOT/'frontend/geolock_hub_app/lib/donation_pages.dart').read_text()
        self.assertIn("'START_PICKUP' => widget.actionRunner != null && card.canStart",ui)
        self.assertIn('Open an authorized route to perform pickup actions.',ui)

    def test_catalog_verifier_contains_only_select_statements(self):
        sql=(HERE/'postdeployment_catalog.sql').read_text()
        sql=re.sub(r'--[^\n]*','',sql)
        for statement in sql.split(';'):
            if statement.strip():self.assertTrue(statement.strip().upper().startswith('SELECT'))
        self.assertNotIn('public.start_pickup(',sql.replace("'public.start_pickup(uuid)'",''))

    def test_pilot_manifest_is_unapproved_and_contains_no_business_row_seed(self):
        data=json.loads((HERE/'direct-pickup-manifest.template.json').read_text())
        self.assertFalse(data['approved'])
        self.assertEqual(data['project_ref'],'rcgyuwiidqvrgbxswhqj')
        self.assertEqual(data['required_counts'],{'ngos':1,'vehicles':1,'eligible_owned_tasks':1,'direct_listings':1})
        self.assertEqual(data['fixture_creation'],'Protected Auth, donation/photo and claim workflows only')


if __name__=='__main__':
    unittest.main(verbosity=2)
