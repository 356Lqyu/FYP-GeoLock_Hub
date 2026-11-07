"""Offline final timing wrapper contracts, no DB connections."""
import re
import unittest
import claim_recovery_final_activation_package as final


class FinalActivationContracts(unittest.TestCase):
    def test_preserves_approved_guards_and_only_job3_cron_mutation(self):
        sql=final.activation_template()
        for required in ('5ff6d8719db9681aae6f444b89dfbaee','SOURCE_OR_SECURITY_DRIFT',
          'POST_CANARY_CRON_BASELINE_DRIFT','TARGET_OR_SNAPSHOT_CHANGED',
          'SOLE_SAFE_CANDIDATE_REQUIRED','WORKER_OR_CONCURRENCY_REVIEW_REQUIRED',
          "interval '3 minutes'",'v_jobs IS DISTINCT FROM'):
            self.assertIn(required,sql)
        self.assertEqual(re.findall(r'PERFORM cron\.\w+\([^;]+;',sql),['PERFORM cron.alter_job(3,active := true);'])
        self.assertNotRegex(sql,r'(?im)^\s*(perform|select) public\.recover_expired_claims\(')

    def test_runtime_anchor_and_receipt_are_inside_atomic_transaction(self):
        sql=final.activation_template()
        self.assertLess(sql.index('v_activation_at:=clock_timestamp()'),sql.index('PERFORM cron.alter_job'))
        self.assertIn("IS DISTINCT FROM 300",sql)
        self.assertIn('ACTIVATION_WINDOW_ALREADY_ELAPSED',sql)
        self.assertIn("'committed',false",sql)
        self.assertLess(sql.index('AS activation_receipt;'),sql.index('\nCOMMIT;'))
        self.assertIn("'Asia/Kuala_Lumpur'",sql)
        self.assertIn("idle_in_transaction_session_timeout='10s'",sql)
        self.assertNotRegex(sql,r'(?i)create\s+(temp|temporary|table|function)\b')

    def test_receipt_is_explicitly_transaction_local_and_not_commit_proof(self):
        sql=final.activation_template()
        self.assertIn('current_setting(\'geolock.stage3i_receipt\')',sql)
        self.assertIn('::text,true)',sql)
        self.assertIn('Receipt is NOT commit proof',sql)
        self.assertIn('If no receipt is visible, pause immediately',sql)

    def test_readers_and_pause_are_preserved_except_monitor_deadline_label(self):
        empty=final.artifacts({})
        for name in ('01_preflight.sql','05_verify.sql','06_pause.sql'):
            self.assertEqual(empty[name],final.base.render(final.base.artifacts()[name],{}))
        self.assertIn('Use saved activation_receipt absolute deadline',empty['04_monitor.sql'])


if __name__=='__main__':
    unittest.main()
