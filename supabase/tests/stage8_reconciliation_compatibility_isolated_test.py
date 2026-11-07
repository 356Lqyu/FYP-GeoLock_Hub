"""PREPARED ONLY. Explicit future approval required even for loopback writes.

Uses existing disposable-cluster runner; synthetic auth/roads and reduced schema.
No external DSN, account, Supabase client or network service is accepted.
"""
import argparse
from contextlib import contextmanager
import importlib.util
import json
from pathlib import Path
import re
import shutil
import sys
import subprocess
import tempfile
import time
from datetime import datetime, timezone
import unittest

import stage8_integration_isolated_test as source
from isolated_psql_sqlfile import SqlFiles

ROOT = source.ROOT
HERE = ROOT/'docs/stage8/integration/reconciliation'
spec = importlib.util.spec_from_file_location('reconciliation_builder', HERE/'build_proposal.py')
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)
ALLOW_ISOLATED_WRITES = False
EVIDENCE_DIR = None
DONOR = source.base.DONOR


def validate_process(cls,args):
    """Refuse remote/service/DSN connections before subprocess execution."""
    exe=Path(args[0]).resolve()
    known={Path(p).resolve():name for name,p in cls.bins.items() if p}
    if exe not in known:raise RuntimeError('UNAPPROVED_EXECUTABLE')
    if known[exe]=='psql':
        def value(flag):return args[args.index(flag)+1]
        if any(args.count(flag)!=1 for flag in ('-h','-p','-U','-d')):
            raise RuntimeError('ONE_EXPLICIT_CONNECTION_TARGET_REQUIRED')
        if value('-h')!='127.0.0.1' or value('-p')!=str(cls.port) or value('-U')!='postgres':
            raise RuntimeError('LOCAL_DISPOSABLE_CONNECTION_REQUIRED')
        if value('-d') not in ('postgres','template1') and not re.fullmatch(r'routing_test_[0-9a-f]{32}',value('-d')):
            raise RuntimeError('DISPOSABLE_DATABASE_NAME_REQUIRED')
        if '-X' not in args or '--no-password' not in args:raise RuntimeError('ISOLATED_PSQL_OPTIONS_REQUIRED')
        cls.sql_files.path(args)
    else:
        target=Path(args[args.index('-D')+1]).resolve()
        if target!=cls.data.resolve() or not target.is_relative_to(cls.folder.resolve()):
            raise RuntimeError('DISPOSABLE_DATA_DIRECTORY_REQUIRED')

FIXTURE = '''
CREATE FUNCTION auth.role() RETURNS text LANGUAGE sql STABLE AS
$$ SELECT coalesce(nullif(current_setting('request.jwt.claim.role',true),''),current_user) $$;
ALTER TABLE public.community_hubs ADD COLUMN IF NOT EXISTS admin_user_id uuid;
ALTER TABLE public.donations ADD COLUMN IF NOT EXISTS donor_user_id uuid;
CREATE TABLE IF NOT EXISTS public.coordination_config(singleton boolean PRIMARY KEY,config_version text);
INSERT INTO public.coordination_config VALUES(true,'ISOLATED-ONLY') ON CONFLICT DO NOTHING;
CREATE TABLE public.claim_reconciliation_cases(case_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 claim_id uuid UNIQUE,listing_id uuid,donation_id uuid,source_type text,case_status text,
 opened_at timestamptz DEFAULT clock_timestamp(),resolved_at timestamptz,resolution_reason text);
CREATE TABLE public.claim_reconciliation_evidence(request_id uuid PRIMARY KEY,case_id uuid,
 actor_user_id uuid,handover_confirmed boolean,response jsonb,
 UNIQUE(case_id,actor_user_id));
REVOKE ALL ON public.claim_reconciliation_cases,public.claim_reconciliation_evidence FROM PUBLIC,anon,authenticated,service_role;
ALTER TABLE public.audit_events ADD COLUMN IF NOT EXISTS request_id uuid;
ALTER TABLE public.audit_events ADD COLUMN IF NOT EXISTS correlation_id uuid;
ALTER TABLE public.audit_events ADD COLUMN IF NOT EXISTS previous_state text;
ALTER TABLE public.audit_events ADD COLUMN IF NOT EXISTS reason_code text;
ALTER TABLE public.audit_events ADD COLUMN IF NOT EXISTS software_version text;
ALTER TABLE public.audit_events ADD COLUMN IF NOT EXISTS configuration_version text;
'''


class CompatibilityTests(source.IntegrationTests):
    @classmethod
    def args(cls,sql):
        args=source.IntegrationTests.args.__func__(cls,sql)
        if not hasattr(cls,'sql_files'):cls.sql_files=SqlFiles(cls.folder/'sql-input')
        args=cls.sql_files.command(args)
        try:
            validate_process(cls,args)
            return args
        except BaseException:
            cls.sql_files.remove(args)
            raise

    @classmethod
    def query(cls,sql,expect_error=None):
        cls._expected_sql_error=expect_error
        try:return source.base.FleetTests.query.__func__(cls,sql,expect_error)
        finally:cls._expected_sql_error=None

    @classmethod
    def run_process(cls,args):
        cls.env={k:v for k,v in cls.env.items() if not k.upper().startswith(('GEOLOCK_','SUPABASE_')) and k.upper()!='DATABASE_URL'}
        cls.env['PGCLIENTENCODING']='UTF8'
        record=dict(executable=Path(args[0]).name,expected_error=getattr(cls,'_expected_sql_error',None))
        start=time.monotonic()
        try:
            validate_process(cls,args)
            if '-f' in args:
                path=cls.sql_files.path(args)
                record['sql_sha256']=cls.sql_files.owned[path]
                record['sql_bytes']=path.stat().st_size
                record['transport']='UTF8_FILE'
            result=source.base.FleetTests.run_process.__func__(cls,args)
            record['success']=True
            return result
        except Exception as error:
            record.update(success=False,error_type=type(error).__name__,error=str(error))
            raise
        finally:
            try:
                if hasattr(cls,'sql_files'):cls.sql_files.remove(args)
            except Exception as cleanup_error:
                record['cleanup_error']=str(cleanup_error)
                raise
            finally:
                record['elapsed_seconds']=time.monotonic()-start
                if EVIDENCE_DIR:
                    with (EVIDENCE_DIR/'operations.jsonl').open('a',encoding='utf-8') as f:f.write(json.dumps(record)+'\n')

    @classmethod
    def cleanup(cls):
        try:
            if EVIDENCE_DIR and (cls.folder/'server.log').exists():
                shutil.copyfile(cls.folder/'server.log',EVIDENCE_DIR/'postgresql-server.log')
        finally:
            try:
                if hasattr(cls,'sql_files'):cls.sql_files.cleanup()
            finally:source.base.FleetTests.cleanup.__func__(cls)

    @contextmanager
    def concurrent(self,sql):
        command=self.args(sql)
        try:
            with tempfile.TemporaryFile(mode='w+',encoding='utf-8') as out:
                proc=subprocess.Popen(command,env=dict(self.env,PGAPPNAME='c1-fleet-race'),
                    creationflags=self.flags,stdout=out,stderr=out)
                try:
                    for _ in range(150):
                        if self.query("SELECT exists(SELECT 1 FROM pg_stat_activity WHERE application_name='c1-fleet-race' AND wait_event='PgSleep');")=='t':break
                        time.sleep(.02)
                    else:self.fail('Concurrent transaction did not reach guarded pause')
                    yield
                finally:
                    try:proc.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        proc.kill();proc.wait(timeout=10)
                        raise
                    finally:
                        out.seek(0);message=out.read()
                    self.assertEqual(proc.returncode,0,message)
        finally:self.sql_files.remove(command)

    @classmethod
    def setUpClass(cls):
        if not ALLOW_ISOLATED_WRITES:
            raise unittest.SkipTest('Prepared only: isolated SQL writes require explicit approval')
        if not all(cls.bins.values()):raise RuntimeError('Local PostgreSQL binaries required')
        # Reuse the disposable cluster/schema foundation, but DO NOT install
        # original 003 or the standalone fix. Exercise the atomic bundle itself.
        base=source.base
        base.SQL=(base.FOLDER/'proposed_migration_v2.sql').read_text()
        base.FIXTURE=base.FIXTURE.replace('synthetic-operational-fixture','OSM-OPS-ISOLATED-SYNTHETIC')+source.fixture_extension()
        base.FleetTests.setUpClass.__func__(cls)
        cls.db='postgres'
        for name in ('001_authority_proposal.sql','002_publication_proposal.sql'):
            cls.query((source.HERE/name).read_text())
        cls.query(FIXTURE)
        cls.query(builder.function(ROOT/'supabase/migrations/20261027_persisted_donation_lifecycle.sql',
            'public.submit_claim_reconciliation').group(0))
        cls.query(builder.function(ROOT/'supabase/migrations/20261030_fix_claim_recovery_unresolved_reconciliation.sql',
            'public.recover_expired_claims').group(0))
        cls.query('REVOKE ALL ON FUNCTION public.submit_claim_reconciliation(uuid,boolean,uuid) FROM PUBLIC,anon,service_role; '
                  'GRANT EXECUTE ON FUNCTION public.submit_claim_reconciliation(uuid,boolean,uuid) TO authenticated; '
                  'REVOKE ALL ON FUNCTION public.recover_expired_claims(integer) FROM PUBLIC,anon,authenticated; '
                  'GRANT EXECUTE ON FUNCTION public.recover_expired_claims(integer) TO service_role;')
        cls.query((HERE/'003_with_reconciliation_proposal.sql').read_text())
        if EVIDENCE_DIR:
            inventory=cls.query("""SELECT jsonb_build_object('server_version',version(),
              'listen_addresses',current_setting('listen_addresses'),'port',current_setting('port'),
              'database',current_database(),'data_directory',current_setting('data_directory'),
              'extensions',(SELECT jsonb_agg(extname) FROM pg_extension),
              'roles',(SELECT jsonb_agg(rolname) FROM pg_roles WHERE rolname IN ('anon','authenticated','service_role','geolock_graph_worker','geolock_planner','geolock_validator')),
              'authority_trigger_enabled',(SELECT tgenabled='O' FROM pg_trigger WHERE tgname='routing_task_authority'),
              'authority_guard_md5',(SELECT md5(replace(prosrc,E'\\r\\n',E'\\n')) FROM pg_proc WHERE oid='routing_private.task_guard()'::regprocedure),
              'helper_client_execute',(SELECT bool_or(has_function_privilege(r.oid,p.oid,'EXECUTE')) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace CROSS JOIN pg_roles r WHERE n.nspname='routing_private' AND p.proname IN ('reconciliation_participant','lock_reconciliation_scope','permit_reconciled_collection','finish_reconciled_collection') AND r.rolname IN ('anon','authenticated','service_role','geolock_graph_worker','geolock_planner','geolock_validator')));""")
            (EVIDENCE_DIR/'environment.json').write_text(json.dumps(json.loads(inventory),indent=2)+'\n')
        cls.db='template1'

    def managed(self, started=True, expired=False, hub=False):
        f=self.prepare(hub=hub);rid=self.authorize()
        self.query(f"UPDATE public.donations SET donor_user_id='{DONOR}' WHERE donation_id='{f['donation']}';")
        if hub:
            self.query(f"UPDATE public.user_profiles SET role='HUB_ADMIN' WHERE user_id='{DONOR}'; UPDATE public.community_hubs SET admin_user_id='{DONOR}';")
        if started:self.rpc(f"public.start_pickup('{f['claim']}')")
        self.query(f"""UPDATE public.donation_claims SET claim_status='RECONCILIATION_REQUIRED' WHERE claim_id='{f['claim']}';
         UPDATE public.claim_leases SET lease_status='RECONCILIATION_REQUIRED'
         {",expires_at=clock_timestamp()-interval '1 minute'" if expired else ''} WHERE claim_id='{f['claim']}';
         INSERT INTO public.claim_reconciliation_cases(claim_id,listing_id,donation_id,source_type,case_status)
         SELECT c.claim_id,l.listing_id,l.donation_id,l.source_type,'OPEN'
         FROM public.donation_claims c JOIN public.listings l USING(listing_id) WHERE c.claim_id='{f['claim']}';""")
        return f,rid

    def evidence(self,f,user,answer=True,request=None):
        return self.jrpc(f"public.submit_claim_reconciliation('{f['claim']}',{str(answer).lower()},'{request or self.req()}')",user=user)

    def assert_held(self,f):
        self.assertEqual(self.query(f"SELECT fleet_private.vehicle_has_hold('{f['vehicle']['vehicle_id']}');"),'t')
        self.assertEqual(self.query('SELECT count(*) FROM public.active_task_route_assignments;'),'1')

    def test_successful_managed_reconciliation_keeps_depot_hold(self):
        f,rid=self.managed()
        self.assertEqual(self.evidence(f,source.A)['outcome'],'AWAITING_COUNTERPART')
        self.assertEqual(self.evidence(f,DONOR)['outcome'],'SUCCESS')
        self.assertEqual(self.query(f"SELECT collected_at IS NOT NULL FROM routing_private.items WHERE task_id='{f['task']}';"),'t')
        self.assert_held(f)
        self.rpc(f"public.close_my_collected_route('{rid}',false)",error='DEPOT_RETURN_CONFIRMATION_REQUIRED')
        self.rpc(f"public.close_my_collected_route('{rid}',true)")
        self.assertEqual(self.query('SELECT count(*) FROM public.active_task_route_assignments;'),'0')

    def test_conflicting_evidence_never_mints_permit(self):
        f,_=self.managed();self.evidence(f,source.A)
        self.assertEqual(self.evidence(f,DONOR,False)['outcome'],'RECONCILIATION_REQUIRED')
        self.assertEqual(self.query('SELECT complete_xid IS NULL AND collected_at IS NULL FROM routing_private.items;'),'t')
        self.assertEqual(self.query('SELECT case_status FROM public.claim_reconciliation_cases;'),'MANUAL_REVIEW')
        self.assert_held(f)

    def test_unauthorized_participant_and_private_helper_denied(self):
        f,_=self.managed()
        self.rpc(f"public.submit_claim_reconciliation('{f['claim']}',true,'{self.req()}')",user=source.B,error='RECONCILIATION_PARTICIPANT_ONLY')
        for role in ('authenticated','anon','service_role'):
            self.rpc(f"routing_private.permit_reconciled_collection('{f['claim']}')",role=role,error='permission denied')
        self.assertEqual(self.query('SELECT count(*) FROM public.claim_reconciliation_evidence;'),'0')

    def test_expired_lease_is_not_new_dispatch_authority(self):
        f,_=self.managed(expired=True)
        self.rpc(f"public.complete_pickup('{f['claim']}',true)",error='NOT_ACTIVE_CLAIM_HOLDER')
        self.evidence(f,source.A)
        self.assertEqual(self.evidence(f,DONOR)['outcome'],'SUCCESS')
        self.rpc(f"public.start_pickup('{f['claim']}')",error='STOP_ORDER_REQUIRED')
        self.assert_held(f)

    def test_planned_reserved_route_cannot_be_collected_by_evidence(self):
        f,_=self.managed(started=False);self.evidence(f,source.A)
        self.assertEqual(self.evidence(f,DONOR)['reason_code'],'HANDOVER_EVIDENCE_CONFLICTS_WITH_TASK_STATE')
        self.assertEqual(self.query('SELECT complete_xid IS NULL AND collected_at IS NULL FROM routing_private.items;'),'t')
        self.assert_held(f)

    def test_resolved_retry_returns_cached_response_without_new_audit(self):
        f,_=self.managed();self.evidence(f,source.A);request=self.req()
        expected=self.evidence(f,DONOR,request=request)
        before=self.query('SELECT count(*) FROM public.audit_events;')
        stamp=self.query('SELECT collected_at FROM routing_private.items;')
        self.assertEqual(self.evidence(f,DONOR,request=request),expected)
        self.assertEqual(self.query('SELECT count(*) FROM public.audit_events;'),before)
        self.assertEqual(self.query('SELECT collected_at FROM routing_private.items;'),stamp)

    def test_hub_counterpart_authorization(self):
        f,_=self.managed(hub=True);self.evidence(f,source.A)
        self.assertEqual(self.evidence(f,DONOR)['outcome'],'SUCCESS')
        self.assertEqual(self.query('SELECT inventory_status FROM public.hub_inventory;'),'COLLECTED')
        self.assert_held(f)

    def test_mixed_hub_batch_retains_manual_review(self):
        f,_=self.managed(hub=True);other=self.req()
        # Deliberately inconsistent synthetic custody fixture, not a permitted
        # live edit to published membership. No authority trigger is disabled.
        self.query(f"""INSERT INTO public.donations SELECT (jsonb_populate_record(NULL::public.donations,
          to_jsonb(d)||jsonb_build_object('donation_id','{other}','donation_status','CLAIMED'))).* FROM public.donations d WHERE donation_id='{f['donation']}';
          INSERT INTO public.hub_batch_members(batch_id,hub_id,donation_id,membership_status)
          SELECT batch_id,hub_id,'{other}','ACTIVE' FROM public.hub_batches;
          INSERT INTO public.hub_inventory(donation_id,hub_id,inventory_status) SELECT '{other}',hub_id,'BATCHED' FROM public.hub_batches;
          UPDATE public.hub_batches SET batch_donation_count=2;""")
        self.evidence(f,source.A)
        self.assertEqual(self.evidence(f,DONOR)['reason_code'],'MIXED_BATCH_DONATION_STATES')
        self.assertEqual(self.query('SELECT complete_xid IS NULL AND collected_at IS NULL FROM routing_private.items;'),'t')

    def test_cutover_legacy_dispatched_task_can_reconcile(self):
        f=self.prepare()
        # Model exactly a pre-existing DISPATCHED row captured at cutover.
        # Fixture INSERT, not a bypass of the UPDATE enforcement trigger.
        self.query(f"""WITH old AS (DELETE FROM public.pickup_tasks WHERE task_id='{f['task']}' RETURNING *)
          INSERT INTO public.pickup_tasks SELECT (jsonb_populate_record(NULL::public.pickup_tasks,
          to_jsonb(o)||jsonb_build_object('task_status','DISPATCHED'))).* FROM old o;
          INSERT INTO routing_private.legacy_inflight(task_id) VALUES('{f['task']}');
          UPDATE public.donations SET donor_user_id='{DONOR}',donation_status='PICKUP_IN_PROGRESS' WHERE donation_id='{f['donation']}';
          UPDATE public.donation_claims SET claim_status='RECONCILIATION_REQUIRED' WHERE claim_id='{f['claim']}';
          UPDATE public.claim_leases SET lease_status='RECONCILIATION_REQUIRED',expires_at=clock_timestamp()-interval '1 minute' WHERE claim_id='{f['claim']}';
          INSERT INTO public.claim_reconciliation_cases(claim_id,listing_id,donation_id,source_type,case_status)
          SELECT c.claim_id,l.listing_id,l.donation_id,l.source_type,'OPEN' FROM public.donation_claims c JOIN public.listings l USING(listing_id) WHERE c.claim_id='{f['claim']}';""")
        self.evidence(f,source.A)
        self.assertEqual(self.evidence(f,DONOR)['outcome'],'SUCCESS')
        self.assertEqual(self.query('SELECT complete_xid IS NOT NULL FROM routing_private.legacy_inflight;'),'t')
        self.assertEqual(self.query('SELECT count(*) FROM routing_private.items;'),'0')

    def test_recovery_retains_reserved_task_and_cases(self):
        f=self.prepare();self.authorize()
        self.query(f"UPDATE public.claim_leases SET expires_at=clock_timestamp()-interval '1 minute' WHERE claim_id='{f['claim']}';")
        self.assertEqual(self.query('SELECT public.recover_expired_claims(100);'),'1')
        self.assertEqual(self.query('SELECT task_status FROM public.pickup_tasks;'),'PLANNED')
        self.assertEqual(self.query('SELECT claim_status FROM public.donation_claims;'),'RECONCILIATION_REQUIRED')
        self.assertEqual(self.query('SELECT public.recover_expired_claims(100);'),'0')
        self.assert_held(f)

    def test_concurrent_participants_serialize_without_duplicate_evidence(self):
        f,_=self.managed();request=self.req()
        with self.concurrent(f"BEGIN; SET LOCAL ROLE authenticated; SET LOCAL request.jwt.claim.sub='{source.A}'; SELECT public.submit_claim_reconciliation('{f['claim']}',true,'{request}'); SELECT pg_sleep(1.2); COMMIT;"):
            self.assertEqual(self.evidence(f,DONOR)['outcome'],'SUCCESS')
        self.assertEqual(self.query('SELECT count(*) FROM public.claim_reconciliation_evidence;'),'2')

    def test_concurrent_depot_closure_waits_for_reconciliation_commit(self):
        f,rid=self.managed();self.evidence(f,source.A)
        with self.concurrent(f"BEGIN; SET LOCAL ROLE authenticated; SET LOCAL request.jwt.claim.sub='{DONOR}'; SELECT public.submit_claim_reconciliation('{f['claim']}',true,'{self.req()}'); SELECT pg_sleep(1.2); COMMIT;"):
            self.rpc(f"public.close_my_collected_route('{rid}',true)")
        self.assertEqual(self.query('SELECT route_status FROM public.pickup_routes;'),'COMPLETED')

    def test_concurrent_duplicate_final_request_is_idempotent(self):
        f,_=self.managed();self.evidence(f,source.A);request=self.req()
        with self.concurrent(f"BEGIN; SET LOCAL ROLE authenticated; SET LOCAL request.jwt.claim.sub='{DONOR}'; SELECT public.submit_claim_reconciliation('{f['claim']}',true,'{request}'); SELECT pg_sleep(1.2); COMMIT;"):
            self.assertEqual(self.evidence(f,DONOR,request=request)['outcome'],'SUCCESS')
        self.assertEqual(self.query('SELECT count(*) FROM public.claim_reconciliation_evidence;'),'2')
        self.assertEqual(self.query("SELECT count(*) FROM public.audit_events WHERE event_type='CLAIM_RECONCILIATION_EVIDENCE';"),'2')

    def test_recovery_then_evidence_lock_order(self):
        f=self.prepare();self.authorize();self.rpc(f"public.start_pickup('{f['claim']}')")
        self.query(f"UPDATE public.donations SET donor_user_id='{DONOR}' WHERE donation_id='{f['donation']}'; UPDATE public.claim_leases SET expires_at=clock_timestamp()-interval '1 minute' WHERE claim_id='{f['claim']}';")
        with self.concurrent('BEGIN; SELECT public.recover_expired_claims(100); SELECT pg_sleep(1.2); COMMIT;'):
            self.assertEqual(self.evidence(f,DONOR)['outcome'],'AWAITING_COUNTERPART')
        self.assertEqual(self.evidence(f,source.A)['outcome'],'SUCCESS')

    def test_permit_does_not_survive_into_next_transaction(self):
        f,_=self.managed();self.evidence(f,source.A);self.evidence(f,DONOR)
        self.assertEqual(self.query('SELECT complete_xid IS DISTINCT FROM pg_current_xact_id() FROM routing_private.items;'),'t')

    def test_concurrent_cancellation_cannot_release_started_route(self):
        f,rid=self.managed()
        with self.concurrent(f"BEGIN; SET LOCAL ROLE authenticated; SET LOCAL request.jwt.claim.sub='{source.A}'; SELECT public.submit_claim_reconciliation('{f['claim']}',true,'{self.req()}'); SELECT pg_sleep(1.2); COMMIT;"):
            self.rpc(f"public.cancel_my_unstarted_route('{rid}')",error='STARTED_ROUTE_REQUIRES_RECONCILIATION')
        self.assert_held(f)

    def test_concurrent_completion_cannot_bypass_reconciliation(self):
        f,_=self.managed()
        with self.concurrent(f"BEGIN; SET LOCAL ROLE authenticated; SET LOCAL request.jwt.claim.sub='{DONOR}'; SELECT public.submit_claim_reconciliation('{f['claim']}',true,'{self.req()}'); SELECT pg_sleep(1.2); COMMIT;"):
            self.rpc(f"public.complete_pickup('{f['claim']}',true)",error='NOT_ACTIVE_CLAIM_HOLDER')
        self.assert_held(f)


def load_tests(loader, tests, pattern):
    # Focused cases only, not the inherited Stage 8 suite.
    return unittest.TestSuite(CompatibilityTests(name) for name in CompatibilityTests.__dict__ if name.startswith('test_'))


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run-isolated',required=True,action='store_true')
    parser.add_argument('--output-dir',type=Path)
    args=parser.parse_args()
    EVIDENCE_DIR=(args.output_dir or ROOT/'results/stage8-reconciliation-isolated'/datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')).resolve()
    if not EVIDENCE_DIR.is_relative_to(ROOT.resolve()):parser.error('Evidence directory must be inside this workspace')
    EVIDENCE_DIR.mkdir(parents=True,exist_ok=False)
    ALLOW_ISOLATED_WRITES=True
    suite=load_tests(None,None,None)
    class Tee:
        def __init__(self,log):self.log=log
        def write(self,value):sys.stderr.write(value);self.log.write(value);self.log.flush()
        def flush(self):sys.stderr.flush();self.log.flush()
    with (EVIDENCE_DIR/'test-run.log').open('x',encoding='utf-8') as log:
        result=unittest.TextTestRunner(stream=Tee(log),verbosity=2).run(suite)
    summary=dict(status='PASS' if result.wasSuccessful() else 'FAIL',tests_run=result.testsRun,
       failures=[dict(test=str(t),traceback=message) for t,message in result.failures],
       errors=[dict(test=str(t),traceback=message) for t,message in result.errors],
       skipped=[dict(test=str(t),reason=reason) for t,reason in result.skipped],
       proposal_file='003_with_reconciliation_proposal.sql',
       proposal_sha256=__import__('hashlib').sha256((HERE/'003_with_reconciliation_proposal.sql').read_bytes()).hexdigest(),
       target='NEW_DISPOSABLE_LOOPBACK_CLUSTER_ONLY',supabase_connections=0)
    (EVIDENCE_DIR/'results.json').write_text(json.dumps(summary,indent=2)+'\n')
    print('Evidence:',EVIDENCE_DIR)
    sys.exit(0 if result.wasSuccessful() else 1)
