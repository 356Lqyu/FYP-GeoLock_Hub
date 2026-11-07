"""Stage 3I offline artifact safety contracts; no DB connections."""
from pathlib import Path
import re
import unittest
import claim_recovery_e2e_package as package


class E2EContracts(unittest.TestCase):
    def test_generated_files_match_reviewed_source(self):
        for name,sql in package.artifacts().items():
            self.assertEqual((package.DEST/name).read_text(encoding='utf-8'),sql)

    def test_readonly_artifacts_have_no_mutation_or_business_rpc_call(self):
        for name in ('01_preflight.sql','04_monitor.sql','05_verify.sql'):
            sql=package.artifacts()[name]
            code=re.sub(r'--[^\n]*','',sql)
            code=re.sub(r"'(?:''|[^'])*'","''",code)
            self.assertNotRegex(code,r'(?i)\b(insert|update|delete|create|alter|drop|call|do|grant|revoke|truncate)\b')
            self.assertNotRegex(code,r'(?i)(recover_expired_claims|claim_listing|create_donation_with_images)\s*\(')

    def test_activation_uses_approved_postcanary_baseline_and_only_cron_mutation(self):
        sql=package.ACTIVATE
        for required in (package.FINGERPRINT,'3137','SOLE_SAFE_CANDIDATE_REQUIRED',
          'TARGET_OR_SNAPSHOT_CHANGED','WORKER_OR_CONCURRENCY_REVIEW_REQUIRED',
          'POST_CANARY_CRON_BASELINE_DRIFT','ACTIVATION_POSTCONDITION_FAILED'):
            self.assertIn(required,sql)
        self.assertEqual(re.findall(r'PERFORM cron\.\w+\([^;]+;',sql),['PERFORM cron.alter_job(3,active := true);'])
        self.assertNotRegex(sql,r'(?im)^\s*(perform|select) public\.recover_expired_claims\(')

    def test_natural_360_minute_expiry_and_human_deadline(self):
        self.assertIn('21600',package.ACTIVATE)
        self.assertIn('IS DISTINCT FROM 360',package.ACTIVATE)
        self.assertIn("interval '5 minutes'",package.ACTIVATE)
        self.assertIn("interval '3 minutes'",package.ACTIVATE)
        self.assertIn('NOT automatic cron deactivation',package.ACTIVATE)
        workflow=(package.DEST/'02_fixture_workflow.md').read_text(encoding='utf-8')
        self.assertIn('full six-hour lease',workflow)

    def test_renderer_quotes_manifest_without_connecting_or_executing(self):
        sql=package.render(package.ACTIVATE,{'operator':"O'Neil",'approval_ref':'test'})
        self.assertIn("O''Neil",sql)
        self.assertNotIn(package.MARKER,sql)
        self.assertIn('REVIEWED_FRESH_MANIFEST_AND_PRESENT_OPERATOR_REQUIRED',sql)

    def test_verification_requires_real_outcomes_not_row_count_message(self):
        for required in ('recovery_audit_ok','donation_audit_ok','refresh_completed',
          'unrelated_unchanged','recovery_paused','scheduler_success','scheduler_no_errors'):
            self.assertIn(required,package.VERIFY)
        self.assertIn("a.lease_id=leid",package.VERIFY)
        self.assertNotIn("return_message='1 row'",package.VERIFY)


if __name__=='__main__':
    unittest.main()
