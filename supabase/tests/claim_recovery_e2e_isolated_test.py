"""Stage 3I: actual prepared scripts/recovery in NEW loopback PostgreSQL ONLY.

No external DSN accepted. cron.alter_job is a transactional table double inherited
from Stage 3G; scheduler ticks are simulated, NOT actual pg_cron scheduler runs.
Reduced tables, auth and routing doubles remain explicit. DEV never connected.
"""
from pathlib import Path
import argparse
import json
import os
import shutil
import unittest
import claim_recovery_canary_isolated_test as canary
import claim_recovery_e2e_package as package


class E2ETests(canary.CanaryTests):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.query("""alter table public.donations add column title text;
          alter table public.donations add column donor_user_id uuid;
          alter table public.listing_eligibility_refresh_jobs add column last_error_code text;""")

    def setUp(self):
        super().setUp()
        self.query("""insert into cron.job_run_details(jobid,status,runid,start_time,end_time)
          select 3,'succeeded',r,now()-interval '1 day',now()-interval '1 day'+interval '10 milliseconds'
          from unnest(ARRAY[3104,3107,3110,3113,3116,3119,3122,3125,3128,3131,3134,3137]) r;
          update cron.job set command='set lock_timeout = ''5s''; set statement_timeout = ''50s''; select public.recover_expired_claims(1);' where jobid=3;""")
        self.f=self.fixture()
        self.query(f"""update public.donations set title='STAGE3I-E2E-isolated',
          donor_user_id='22222222-2222-2222-2222-222222222222' where donation_id='{self.f['donation']}';""")
        self.manifest=dict(claim_id=self.f['claim'],lease_id=self.f['lease'],listing_id=self.f['listing'],
          donation_id=self.f['donation'],task_id=self.f['task'],
          donor_user_id='22222222-2222-2222-2222-222222222222',
          ngo_user_id=canary.guard.automatic.OWNER,fixture_title='STAGE3I-E2E-isolated',
          approval_ref='ISOLATED-ONLY',operator='local-fixture',maintenance_confirmed=True)
        self.refresh_manifest()

    def sql(self,name):
        # Read actual on-disk artifact, not generator text, for execution.
        return package.render((package.DEST/name).read_text(encoding='utf-8'),self.manifest)

    def refresh_manifest(self):
        data=self.json_row('01_preflight.sql')
        self.manifest=data['proposed_manifest']
        self.manifest['stop_at']=self.query("select (clock_timestamp()+interval '4 minutes')::text;")
        self.assertTrue(data['target_is_overdue'])
        self.assertEqual([x['jobid'] for x in data['cron']],[1,2,3])
        self.assertEqual(data['recovery_body_md5'],package.FINGERPRINT)

    def activate(self):
        self.query(self.sql('03_activate.sql'))

    def pause(self):
        self.query(self.sql('06_pause.sql'))

    def tick(self):
        # Explicit scheduler double. Actual deployed patched function executes.
        result=self.query(package.COMMAND)
        self.query("""insert into cron.job_run_details(jobid,status,runid,start_time,end_time)
          select 3,'succeeded',coalesce(max(runid),3137)+1,now(),now() from cron.job_run_details;""")
        return result

    def result(self):
        return self.json_row('05_verify.sql')

    def json_row(self,name):
        sql=self.sql(name).rstrip().removesuffix(';')
        return json.loads(self.query('select to_jsonb(x) from ('+sql+') x;'))

    def reject_activation(self,error):
        before=self.snapshot()
        self.query(self.sql('03_activate.sql'),expect_error=error)
        self.assertEqual(before,self.snapshot())

    def test_e2e_safe_tick_repeat_pause_and_complete_verification(self):
        self.activate()
        self.assertEqual(self.tick(),'1')
        after=self.snapshot()
        self.assertEqual(self.tick(),'0')
        self.assertEqual(after,self.snapshot())
        # Explicit async completion double; actual refresh worker NOT tested.
        self.query("update public.listing_eligibility_refresh_jobs set job_status='COMPLETED';")
        self.pause()
        self.assertTrue(self.result()['all_checks_pass'])

    def test_e2e_unrelated_record_guard_and_rollback(self):
        self.query("insert into public.donations values('33333333-3333-3333-3333-333333333333','HUB_COLLECTION','SUBMITTED',5,now(),'untouched',null);")
        self.reject_activation('TARGET_OR_SNAPSHOT_CHANGED')

    def test_e2e_activation_postcondition_rollback(self):
        before=self.snapshot()
        sql=self.sql('03_activate.sql').replace(
          "IF NOT EXISTS(SELECT 1 FROM cron.job WHERE jobid=3 AND active",
          "IF true OR NOT EXISTS(SELECT 1 FROM cron.job WHERE jobid=3 AND active")
        self.query(sql,expect_error='ACTIVATION_POSTCONDITION_FAILED')
        self.assertEqual(before,self.snapshot())

    def test_e2e_stale_manifest_rejected(self):
        self.manifest['baseline_at']='2000-01-01T00:00:00+00'
        self.reject_activation('REVIEWED_FRESH_MANIFEST_AND_PRESENT_OPERATOR_REQUIRED')

    def test_e2e_unresolved_case_rejected_before_activation(self):
        self.case(self.f,'MANUAL_REVIEW')
        self.refresh_manifest()
        self.reject_activation('SOLE_SAFE_CANDIDATE_REQUIRED')

    def test_e2e_custody_after_activation_fences_reopening(self):
        self.activate()
        self.query(f"insert into public.pickup_route_stops(task_id) values('{self.f['task']}');")
        self.assertEqual(self.tick(),'1')
        self.assert_reconciliation()
        self.pause()
        self.assertFalse(self.result()['all_checks_pass'])

    def test_e2e_case_after_activation_fences_reopening(self):
        self.activate()
        self.case(self.f,'OPEN')
        self.assertEqual(self.tick(),'1')
        self.assert_reconciliation()
        self.pause()
        self.assertFalse(self.result()['all_checks_pass'])

    def test_e2e_audit_failure_rolls_back_and_pause_still_works(self):
        self.activate()
        self.query("""create function public.auto_fail() returns trigger language plpgsql as $$
          begin if new.event_type='LEASE_RECOVERY' then raise exception 'TEST_AUDIT_FAILURE';
          end if; return new; end $$;
          create trigger auto_fail before insert on public.audit_events for each row execute function public.auto_fail();""")
        before=self.snapshot()
        self.query(package.COMMAND,expect_error='TEST_AUDIT_FAILURE')
        self.assertEqual(before,self.snapshot())
        self.pause()
        self.assertEqual(self.query('select active from cron.job where jobid=3;'),'f')

    def test_e2e_empty_manifest_and_wrong_history_fail_closed(self):
        self.query((package.DEST/'03_activate.sql').read_text(encoding='utf-8'),
          expect_error='REVIEWED_FRESH_MANIFEST_AND_PRESENT_OPERATOR_REQUIRED')
        self.query("insert into cron.job_run_details(jobid,status,runid,start_time,end_time) values(3,'succeeded',9999,now(),now());")
        self.reject_activation('POST_CANARY_CRON_BASELINE_DRIFT')

    def test_e2e_second_active_claim_prevents_activation(self):
        self.fixture(2)
        self.refresh_manifest()
        self.reject_activation('SOLE_SAFE_CANDIDATE_REQUIRED')

    def test_e2e_no_success_until_refresh_complete_and_paused(self):
        self.activate()
        self.assertEqual(self.tick(),'1')
        self.assertFalse(self.result()['all_checks_pass'])
        self.pause()
        self.assertFalse(self.result()['all_checks_pass'])
        self.query("update public.listing_eligibility_refresh_jobs set job_status='COMPLETED';")
        self.assertTrue(self.result()['all_checks_pass'])


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run-isolated',action='store_true')
    parser.add_argument('--pg-bin',type=Path)
    args=parser.parse_args()
    if not args.run_isolated:
        parser.error('--run-isolated required; no external connections supported')
    E2ETests.bins={n:str(args.pg_bin/(n+('.exe' if os.name=='nt' else ''))) if args.pg_bin else shutil.which(n)
      for n in ('initdb','pg_ctl','psql')}
    if any(not v or not Path(v).is_file() for v in E2ETests.bins.values()):
        parser.error('initdb, pg_ctl and psql required')
    suite=unittest.TestSuite(E2ETests(n) for n in sorted(E2ETests.__dict__) if n.startswith('test_e2e_'))
    result=unittest.TextTestRunner(verbosity=2).run(suite)
    raise SystemExit(not result.wasSuccessful())
