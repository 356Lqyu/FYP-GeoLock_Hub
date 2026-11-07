"""Offline contracts: permission-compatible wrapper only; no DB connections."""
import unittest
import hashlib
import json
import claim_recovery_permission_activation_package as package


class PermissionContracts(unittest.TestCase):
    def test_no_unsupported_cron_locks_or_privilege_changes(self):
        sql=package.activation_template()
        self.assertNotRegex(sql,r'(?i)lock\s+table\s+cron\.')
        self.assertNotRegex(sql,r'(?i)\b(grant|revoke|create\s+function|alter\s+role|set\s+role)\b')
        self.assertNotRegex(sql,r'(?i)from\s+cron\.job[^;]*for\s+(?:update|share)')

    def test_business_locks_precede_first_snapshot(self):
        sql=package.activation_template()
        self.assertIn('BEGIN ISOLATION LEVEL REPEATABLE READ;',sql)
        self.assertLess(sql.index('LOCK TABLE public.'),sql.index('DO $stage3i$'))
        self.assertNotRegex(sql[:sql.index('LOCK TABLE public.')],r'(?im)^\s*(select|do)\b')
        for table in package.previous.TABLES:
            self.assertIn('public.'+table,sql[:sql.index('DO $stage3i$')])

    def test_approval_precedes_both_supported_api_calls(self):
        sql=package.activation_template()
        self.assertLess(sql.index('EXPLICIT_EXECUTION_APPROVAL_AND_SUPERVISION_REQUIRED'),
                        sql.index('PERFORM cron.alter_job'))
        self.assertEqual(sql.count('PERFORM cron.alter_job('),2)
        self.assertIn('PERFORM cron.alter_job(3,active := false);',sql)
        self.assertIn('PERFORM cron.alter_job(3,command := v_worker_command,active := true);',sql)

    def test_supported_row_lock_is_asserted_and_one_use_marker_is_preserved(self):
        sql=package.activation_template()
        self.assertIn('SUPPORTED_JOB3_ROW_LOCK_NOT_CONFIRMED',sql)
        self.assertIn("mode='RowExclusiveLock' AND granted",sql)
        self.assertIn('cj.xmin::text=',sql)
        self.assertIn(package.TOKEN,sql)
        self.assertIn('RECOVERY_ACTIVATION_PROTOCOL_BUSY',sql)

    def test_original_safety_assertions_remain(self):
        sql=package.activation_template()
        for token in ('SOURCE_OR_SECURITY_DRIFT','POST_CANARY_CRON_BASELINE_DRIFT',
          'WORKER_OR_CONCURRENCY_REVIEW_REQUIRED','TARGET_OR_SNAPSHOT_CHANGED',
          'SOLE_SAFE_CANDIDATE_REQUIRED','TARGET_AUDIT_HISTORY_CHANGED',
          'ACTIVATION_POSTCONDITION_FAILED','SOURCE_OR_SECURITY_CHANGED_DURING_ACTIVATION',
          package.BASE.FINGERPRINT,"IS DISTINCT FROM 300",'pause_deadline_myt',
          "interval '3 minutes'",'v_jobs IS DISTINCT FROM'):
            self.assertIn(token,sql)
        self.assertNotRegex(sql,r'(?im)^\s*(perform|select) public\.recover_expired_claims\(')

    def test_pause_is_unchanged_and_never_waits_on_advisory_lock(self):
        files=package.artifacts({})
        self.assertEqual(files['06_pause.sql'],package.previous.artifacts({})['06_pause.sql'])
        self.assertNotIn('advisory',files['06_pause.sql'])
        self.assertIn('recovery_schedule_count',files['04_monitor.sql'])
        self.assertIn('recovery_schedule_count',files['07_schedule_monitor.sql'])
        self.assertIn(package.MARKED_COMMAND.replace("'","''"),files['05_verify.sql'])

    def test_review_artifacts_false_approval_pins_and_checksums(self):
        root=package.BASE.DEST
        manifest=json.loads((root/'permission_compatible_operator_manifest.json').read_text(encoding='utf-8'))
        original=json.loads((root/'live_state_operator_manifest.json').read_text(encoding='utf-8'))
        self.assertIs(manifest['execution_approved'],False)
        self.assertEqual({k for k in original if original[k]!=manifest[k]},
                         {'phase','approval_ref','activation_token'})
        dest=root/'phase2_permission_compatible_review_20261023'
        for name,sql in package.artifacts(manifest).items():
            self.assertEqual((dest/name).read_bytes(),sql.encode())
        for line in (dest/'SHA256SUMS.txt').read_text(encoding='utf-8').splitlines():
            digest,name=line.split('  ',1)
            self.assertEqual(hashlib.sha256((dest/name).read_bytes()).hexdigest().upper(),digest)


if __name__=='__main__':
    unittest.main()
