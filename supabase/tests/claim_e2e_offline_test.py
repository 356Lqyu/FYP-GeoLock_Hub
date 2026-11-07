"""Current-contract regressions. All external HTTP is forbidden in these tests."""
import copy
import hashlib
import json
import sys
import tempfile
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch

import claim_concurrency_test as common
import claim_two_actor_acceptance as suite
import claim_fault_injection_dev_test as fault
import claim_e2e_contract as contract

ACTOR, LISTING, DONATION, REQUEST, FAILURE = [str(uuid.UUID(int=i)) for i in range(1,6)]


class ContractTests(unittest.TestCase):
    def setUp(self):
        self.transport = patch('urllib.request.urlopen', side_effect=AssertionError('OFFLINE_NETWORK_FORBIDDEN'))
        self.transport.start()
        self.addCleanup(self.transport.stop)

    def receipt(self):
        return dict(outcome='ERROR', rollback_confirmed=True, claim_id=None, replayed=False,
                    failure_audit_id=FAILURE, reason_code=contract.ROLLBACK_REASON)

    def row(self):
        return dict(failure_id=FAILURE, actor_user_id=ACTOR, actor_role='NGO', request_id=REQUEST,
                    listing_id=LISTING, donation_id=DONATION, claim_id=None, operation_name='claim_listing',
                    reason_code=contract.ROLLBACK_REASON, occurred_at='2026-10-25T00:00:00Z',
                    details=dict(rollback_confirmed=True, outcome='ERROR', lease_id=None, correlation_id=REQUEST,
                                 software_version=contract.VERSION, transaction_id='123', sqlstate='P0001'))

    def manifest(self):
        return dict(project_ref=common.DEV_PROJECT_REF, purpose='fault_injection', approval_ref='local-test-review',
                    operator='local tester', actor_ids=[ACTOR], fixture_label='STAGE3J-local-test',
                    fixtures=[dict(listing_id=LISTING, donation_id=DONATION)],
                    health_baseline=dict(migration_sha256=hashlib.sha256(contract.MIGRATION.read_bytes()).hexdigest(),
                        other_functions_md5='a'*32, function_acls={},
                        recovery_history=dict(total=17, failed=0, unfinished=0)))

    def test_saved_fingerprints_match_actual_migration_definitions(self):
        expected = json.loads((contract.PACKAGE/'approved_functions.json').read_text())
        actual = [dict(f, acl='explicit-local-test-ACL') for f in expected]
        contract.validate_function_contract(actual)
        current = {f['identity']: f['body_md5'] for f in contract.source_functions()}
        self.assertNotEqual(current['claim_listing(uuid,uuid)'],'a883341a6dd72ccb08991a7f89dffa9a')
        self.assertNotEqual(current['recover_expired_claims(integer)'],'5ff6d8719db9681aae6f444b89dfbaee')

    def test_source_security_or_overload_drift_is_not_auto_adopted(self):
        expected = json.loads((contract.PACKAGE/'approved_functions.json').read_text())
        for key, value in [('body_md5','0'*32),('security_definer',False),('owner','other')]:
            actual = copy.deepcopy(expected); actual[0][key] = value
            with self.subTest(key=key), self.assertRaises(RuntimeError):
                contract.validate_function_contract(actual)
        with self.assertRaises(RuntimeError):
            contract.validate_function_contract(expected + [expected[0]])

    def test_confirmed_receipt_has_authoritative_shape(self):
        contract.confirmed_receipt(200,self.receipt(),contract.ROLLBACK_REASON)
        self.assertEqual(contract.classify(200,self.receipt()),'CONFIRMED_ROLLBACK')
        self.assertEqual(contract.classify(200,{'outcome':'CONFLICT'}),'BUSINESS_REJECTION')
        self.assertEqual(contract.classify(503,self.receipt()),'UNCONFIRMED')

    def test_http_error_does_not_prove_confirmed_rollback(self):
        for status in (400,401,403,500,503):
            with self.subTest(status=status), self.assertRaisesRegex(RuntimeError,'UNCONFIRMED'):
                contract.confirmed_receipt(status,self.receipt())

    def test_malformed_or_forged_receipts_are_rejected(self):
        for key,value in [('rollback_confirmed',False),('rollback_confirmed','true'),('claim_id',ACTOR),
                          ('failure_audit_id','bad'),('reason_code','NETWORK_UNKNOWN'),('replayed',True)]:
            receipt = self.receipt(); receipt[key] = value
            with self.subTest(key=key), self.assertRaises(RuntimeError):
                contract.confirmed_receipt(200,receipt)

    def test_failure_record_exact_key_and_linkage(self):
        contract.failure_record(self.receipt(),[self.row()],ACTOR,LISTING,REQUEST,DONATION)

    def test_failure_deduplication_and_wrong_actor_cannot_pass(self):
        for rows in ([], [self.row(),self.row()], [dict(self.row(),actor_user_id=FAILURE)],
                     [dict(self.row(),claim_id=ACTOR)]):
            with self.subTest(rows=len(rows)), self.assertRaises(RuntimeError):
                contract.failure_record(self.receipt(),rows,ACTOR,LISTING,REQUEST,DONATION)

    def test_failure_append_cannot_rewrite_historical_evidence(self):
        old = self.row(); new = dict(self.row(),failure_id=ACTOR)
        contract.failure_append([old],[old,new],ACTOR)
        with self.assertRaises(RuntimeError):
            contract.failure_append([old],[dict(old,reason_code='changed'),new],ACTOR)

    def test_network_failure_is_uncertain_and_redacts_exception(self):
        import urllib.error
        with patch('urllib.request.urlopen',side_effect=urllib.error.URLError('SECRET_PASSWORD')):
            with self.assertRaisesRegex(RuntimeError,'UNCONFIRMED') as error:
                common.http_call('https://unused','secret','secret','rpc/claim_listing',{})
        self.assertNotIn('SECRET_PASSWORD',str(error.exception))

    def test_structured_error_is_returned_with_timing_not_raised_as_http_failure(self):
        with patch.object(common,'rpc',return_value=(200,self.receipt())):
            response = common.claim_attempt('unused','key',LISTING,'token',REQUEST)
        self.assertEqual(response['failure_audit_id'],FAILURE)
        self.assertGreaterEqual(response['client_timing']['elapsed_ms'],0)

    def test_changed_payload_requires_structured_durable_receipt(self):
        receipt = dict(self.receipt(),reason_code=contract.REUSE_REASON)
        with patch.object(common,'rpc',return_value=(200,receipt)):
            self.assertEqual(common.expect_payload_rejection('b','k','t',LISTING,REQUEST)['failure_audit_id'],FAILURE)
        with patch.object(common,'rpc',return_value=(400,{'message':contract.REUSE_REASON})):
            with self.assertRaisesRegex(RuntimeError,'UNCONFIRMED'):
                common.expect_payload_rejection('b','k','t',LISTING,REQUEST)

    def test_live_recovery_cannot_be_called_through_harness(self):
        with self.assertRaisesRegex(RuntimeError,'recovery remains disabled'):
            common.rpc('unused','key','token','recover_expired_claims',{'p_limit':1})

    def test_manifest_matches_canonical_approved_fixture_mapping(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)/'manifest.json'; path.write_text(json.dumps(self.manifest()))
            contract.load_manifest(path,[ACTOR],[LISTING],[DONATION],'STAGE3J-local-test','fault_injection')

    def test_manifest_drift_blocks_before_transport(self):
        for key,value in [('project_ref',common.BLOCKED_PROJECT_REF),('actor_ids',[FAILURE]),
                          ('fixtures',[]),('approval_ref',''),('purpose','recovery')]:
            with tempfile.TemporaryDirectory() as folder:
                manifest = self.manifest(); manifest[key] = value
                path = Path(folder)/'manifest.json'; path.write_text(json.dumps(manifest))
                with self.subTest(key=key), self.assertRaises(RuntimeError):
                    contract.load_manifest(path,[ACTOR],[LISTING],[DONATION],'STAGE3J-local-test','fault_injection')

    def test_migration_file_drift_invalidates_reviewed_manifest(self):
        manifest = self.manifest(); manifest['health_baseline']['migration_sha256']='0'*64
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)/'manifest.json'; path.write_text(json.dumps(manifest))
            with self.assertRaisesRegex(RuntimeError,'migration hash'):
                contract.load_manifest(path,[ACTOR],[LISTING],[DONATION],'STAGE3J-local-test','fault_injection')

    def test_all_mutating_entry_points_require_explicit_cli_approval(self):
        for runner in (suite,common,fault):
            with patch.object(sys,'argv',['runner','--env-file','unused','--manifest','unused',
                '--output-dir','unused','--execute']), patch.object(suite,'prepare') as prepare:
                with self.subTest(runner=runner.__name__), self.assertRaisesRegex(RuntimeError,'approval'):
                    runner.main()
                prepare.assert_not_called()

    def test_concurrency_default_is_preflight_only(self):
        with tempfile.TemporaryDirectory() as folder:
            journal = suite.Journal(Path(folder)/'journal')
            ctx = ('b','k','s',[],[],[],None,None,None,journal,{})
            with patch.object(sys,'argv',['runner','--env-file','unused','--manifest','unused',
                    '--output-dir',str(Path(folder)/'unused')]), patch.object(suite,'prepare',return_value=ctx), \
                 patch.object(common,'run_race') as race, patch.object(common,'run_delayed_race') as delayed:
                self.assertEqual(common.main(),0)
                race.assert_not_called(); delayed.assert_not_called()

    def test_receipt_authorization_does_not_accept_permission_or_transport_errors(self):
        own = (200,[dict(event_id=FAILURE,event_type='CLAIM_FAILURE',outcome='ERROR',lease_id=None)])
        for other in [(403,{'code':'42501','message':'permission denied'}), (200,[]), (503,{})]:
            with patch.object(common,'rpc',side_effect=[own,other]), self.assertRaises(RuntimeError):
                fault.verify_failure_authorization('b','k',['a','b'],LISTING,self.receipt())

    def test_entitled_other_ngo_receives_filtered_audits_without_foreign_receipt(self):
        own = dict(event_id=FAILURE,event_type='CLAIM_FAILURE',actor_user_id=ACTOR,outcome='ERROR')
        for other in [(200,[dict(event_id=REQUEST,event_type='CLAIM_ATTEMPT')]),
                      (400,dict(code='P0001',message='AUDIT_NOT_FOUND_OR_FORBIDDEN'))]:
            with patch.object(common,'rpc',side_effect=[(200,[own]),other]), \
                 patch.object(common,'jwt_subject',return_value=ACTOR):
                common.verify_receipt_visibility('b','k','own','other',LISTING,self.receipt())

    def test_foreign_failure_projection_is_never_allowed(self):
        own = dict(event_id=FAILURE,event_type='CLAIM_FAILURE',actor_user_id=ACTOR,outcome='ERROR')
        with patch.object(common,'rpc',side_effect=[(200,[own]),(200,[own])]), \
             patch.object(common,'jwt_subject',return_value=ACTOR), self.assertRaisesRegex(RuntimeError,'Foreign NGO'):
            common.verify_receipt_visibility('b','k','own','other',LISTING,self.receipt())


if __name__ == '__main__':
    unittest.main(verbosity=2)
