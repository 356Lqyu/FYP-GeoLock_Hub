"""Offline contracts for the live-state, approval-gated Stage 3I proposal."""
import unittest
import json
import hashlib
import claim_recovery_live_activation_package as live


class LiveActivationContracts(unittest.TestCase):
    def test_approved_recovery_is_only_scheduled_not_called(self):
        sql=live.activation_template()
        self.assertIn(live.BASE.FINGERPRINT,sql)
        self.assertNotRegex(sql,r'(?im)^\s*(perform|select) public\.recover_expired_claims\(')
        self.assertIn("recover_expired_claims(1); -- STAGE3I_ONE_USE_",sql)
        self.assertNotRegex(sql,r'(?i)create\s+(function|table|trigger|schema)\b')

    def test_approval_and_operator_precede_all_locks_and_mutation(self):
        sql=live.activation_template()
        self.assertLess(sql.index('EXPLICIT_EXECUTION_APPROVAL_AND_SUPERVISION_REQUIRED'),sql.index('LOCK TABLE'))
        self.assertLess(sql.index('LOCK TABLE'),sql.index('PERFORM cron.alter_job'))
        self.assertIn(live.CONFIRMATION,sql)
        self.assertIn(live.TOKEN,sql)

    def test_live_snapshot_is_read_under_locks_before_freshness_assertion(self):
        sql=live.activation_template()
        lock=sql.index('LOCK TABLE')
        read=sql.index('SELECT * INTO v FROM evidence;',lock)
        stamp=sql.index("jsonb_build_object('baseline_at',clock_timestamp())")
        self.assertLess(lock,read)
        self.assertLess(read,stamp)
        self.assertLess(stamp,sql.index('REVIEWED_FRESH_MANIFEST_AND_PRESENT_OPERATOR_REQUIRED'))
        self.assertIn("interval '3 minutes'",sql)
        self.assertIn('IN EXCLUSIVE MODE NOWAIT',sql)
        self.assertIn('cron.job IN SHARE ROW EXCLUSIVE MODE NOWAIT',sql)

    def test_all_original_guards_and_target_audit_fence_remain(self):
        sql=live.activation_template()
        for guard in ('SOURCE_OR_SECURITY_DRIFT','POST_CANARY_CRON_BASELINE_DRIFT',
          'WORKER_OR_CONCURRENCY_REVIEW_REQUIRED','TARGET_OR_SNAPSHOT_CHANGED',
          'SOLE_SAFE_CANDIDATE_REQUIRED','ACTIVATION_POSTCONDITION_FAILED',
          'TARGET_AUDIT_HISTORY_CHANGED','SOURCE_OR_SECURITY_CHANGED_DURING_ACTIVATION'):
            self.assertIn(guard,sql)
        for table in live.TABLES:
            self.assertIn('public.'+table,sql)

    def test_transaction_local_settings_and_five_minute_receipt(self):
        sql=live.activation_template()
        for token in ('BEGIN ISOLATION LEVEL READ COMMITTED;',"SET LOCAL TimeZone='UTC';",
          "lock_timeout='5s'","statement_timeout='10s'",'idle_in_transaction_session_timeout',
          'IS DISTINCT FROM 300',"'window_seconds',300",'pause_deadline_myt',"'committed',false"):
            self.assertIn(token,sql)
        self.assertLess(sql.index('AS activation_receipt;'),sql.index('\nCOMMIT;'))

    def test_replay_marker_is_retained_and_only_job_three_changes(self):
        sql=live.activation_template()
        self.assertEqual(sql.count('PERFORM cron.alter_job('),1)
        self.assertIn('cron.alter_job(3,command := v_worker_command,active := true)',sql)
        self.assertIn('AND command=v_worker_command',sql)
        self.assertIn('v_jobs IS DISTINCT FROM',sql)

    def test_readers_and_pause_preserved(self):
        ours=live.artifacts({})
        previous=live.final.artifacts({})
        for name in ('01_preflight.sql','04_monitor.sql','05_verify.sql','06_pause.sql'):
            self.assertEqual(ours[name],previous[name])

    def test_rendered_review_files_and_checksums_match_generator(self):
        root=live.BASE.DEST
        dest=root/'phase2_live_state_review_20261023'
        manifest=json.loads((root/'live_state_operator_manifest.json').read_text(encoding='utf-8'))
        self.assertIs(manifest['execution_approved'],False)
        self.assertEqual(manifest['claim_id'],'8161392c-e1e1-4723-a954-c80b6b61a8c7')
        for name,sql in live.artifacts(manifest).items():
            self.assertEqual((dest/name).read_bytes(),sql.encode())
        for line in (dest/'SHA256SUMS.txt').read_text(encoding='utf-8').splitlines():
            digest,name=line.split('  ',1)
            self.assertEqual(hashlib.sha256((dest/name).read_bytes()).hexdigest().upper(),digest)


if __name__=='__main__':
    unittest.main()
