"""Final deadline wrapper only, NEW disposable loopback PostgreSQL.

No recovery function is invoked in these tests. cron.alter_job is the existing
transactional fixture double. No real pg_cron scheduling or DEV access.
"""
from pathlib import Path
import argparse
import datetime
import json
import os
import shutil
import unittest
import claim_recovery_e2e_isolated_test as fixture
import claim_recovery_final_activation_package as final


class FinalTests(fixture.E2ETests):
    def sql(self,name):
        manifest={**self.manifest,'max_activation_seconds':300,
          'deadline_mode':'server_clock_immediately_before_activation'}
        return final.artifacts(manifest)[name]

    def test_final_receipt_exact_300_seconds_commit_pause_no_business_changes(self):
        before=self.snapshot()
        receipt=json.loads(self.query(self.sql('03_activate.sql')))
        start=datetime.datetime.fromisoformat(receipt['activation_statement_utc'])
        stop=datetime.datetime.fromisoformat(receipt['pause_deadline_utc'])
        self.assertEqual((stop-start).total_seconds(),300)
        self.assertEqual(receipt['window_seconds'],300)
        self.assertFalse(receipt['committed'])
        self.assertEqual(self.query('select active from cron.job where jobid=3;'),'t')
        after=self.snapshot(); before.pop('cron.job'); after.pop('cron.job')
        self.assertEqual(before,after)
        self.query(self.sql('06_pause.sql'))
        self.assertEqual(self.query('select active from cron.job where jobid=3;'),'f')

    def test_final_wrong_window_rejected(self):
        before=self.snapshot()
        sql=self.sql('03_activate.sql').replace('"max_activation_seconds": 300','"max_activation_seconds": 301')
        self.query(sql,expect_error='REVIEWED_FRESH_MANIFEST_AND_PRESENT_OPERATOR_REQUIRED')
        self.assertEqual(before,self.snapshot())

    def test_final_postcondition_rolls_back_job_change(self):
        before=self.snapshot()
        sql=self.sql('03_activate.sql').replace('IF NOT EXISTS(SELECT 1 FROM cron.job WHERE jobid=3 AND active',
          'IF true OR NOT EXISTS(SELECT 1 FROM cron.job WHERE jobid=3 AND active')
        self.query(sql,expect_error='ACTIVATION_POSTCONDITION_FAILED')
        self.assertEqual(before,self.snapshot())

    def test_final_expired_runtime_deadline_rolls_back(self):
        before=self.snapshot()
        sql=self.sql('03_activate.sql').replace('IF clock_timestamp()>=v_pause_deadline',
          'IF true OR clock_timestamp()>=v_pause_deadline')
        self.query(sql,expect_error='ACTIVATION_WINDOW_ALREADY_ELAPSED')
        self.assertEqual(before,self.snapshot())

    def test_final_stale_baseline_still_rejected(self):
        self.manifest['baseline_at']='2000-01-01T00:00:00+00'
        before=self.snapshot()
        self.query(self.sql('03_activate.sql'),expect_error='REVIEWED_FRESH_MANIFEST_AND_PRESENT_OPERATOR_REQUIRED')
        self.assertEqual(before,self.snapshot())

    def test_final_wrong_operator_session_rejected(self):
        sql=self.sql('03_activate.sql').replace('BEGIN;','BEGIN;\nSET LOCAL ROLE service_role;',1)
        before=self.snapshot()
        self.query(sql,expect_error='CLEAN_POSTGRES_SESSION_REQUIRED')
        self.assertEqual(before,self.snapshot())


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--run-isolated',action='store_true')
    p.add_argument('--pg-bin',type=Path)
    a=p.parse_args()
    if not a.run_isolated:
        p.error('--run-isolated required; no external DSN supported')
    FinalTests.bins={n:str(a.pg_bin/(n+('.exe' if os.name=='nt' else ''))) if a.pg_bin else shutil.which(n)
      for n in ('initdb','pg_ctl','psql')}
    if any(not v or not Path(v).is_file() for v in FinalTests.bins.values()):
        p.error('initdb/pg_ctl/psql required')
    suite=unittest.TestSuite(FinalTests(n) for n in sorted(FinalTests.__dict__) if n.startswith('test_final_'))
    result=unittest.TextTestRunner(verbosity=2).run(suite)
    raise SystemExit(not result.wasSuccessful())
