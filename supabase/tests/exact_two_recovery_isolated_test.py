"""Opt-in disposable loopback PostgreSQL tests. No external DSNs or Supabase clients."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import unittest
import uuid

import stage8_reconciliation_compatibility_isolated_test as transport
import claim_recovery_expiration_isolated_test as lifecycle

ROOT=Path(__file__).resolve().parents[2]
HERE=ROOT/'docs/stage8/integration/reconciliation'
PROPOSAL=(HERE/'exact_two_recovery_transaction_proposal.sql').read_text()
C1='b4bea793-9755-470a-95bb-6b02bc0c4443'
C2='dd1be70f-0e42-4b75-9124-cac3702d76f6'
H='8161392c-e1e1-4723-a954-c80b6b61a8c7'
T1='521ad842-5d79-4157-97f9-9fb1c73ca632'
T2='bbbf6b10-cb79-42ed-82cc-8b2246bf8bcb'
HT='270caa8b-5a6d-481c-b199-c9a47156dda2'

def uid(n):return str(uuid.UUID(int=n))

EXTRA="""
ALTER TABLE public.donation_claims ADD ngo_user_id uuid;
ALTER TABLE public.pickup_tasks ADD ngo_user_id uuid;
CREATE SCHEMA routing_private;
CREATE TABLE routing_private.items(route_id uuid,task_id uuid,released_at timestamptz);
CREATE TABLE routing_private.bindings(route_id uuid,closed_at timestamptz,started_at timestamptz);
CREATE TABLE routing_private.legacy_inflight(task_id uuid);
CREATE TABLE routing_private.cancelled_stop_history(task_id uuid);
CREATE TABLE public.pickup_routes(route_id uuid,route_status text,vehicle_id uuid);
CREATE TABLE public.claim_reconciliation_evidence(case_id uuid);
CREATE SCHEMA cron;
CREATE TABLE cron.job(jobid integer,jobname text,active boolean,command text);
INSERT INTO cron.job VALUES(3,'geolock-expired-claim-recovery',false,'select public.recover_expired_claims(100);');
"""

class ExactTwoTests(transport.CompatibilityTests):
    @classmethod
    def setUpClass(cls):
        if not ENABLED:raise unittest.SkipTest('Explicit --run-isolated required')
        if not all(cls.bins.values()):raise RuntimeError('Local PostgreSQL binaries required')
        cls.tmp=tempfile.TemporaryDirectory(prefix='geolock-exact-two-isolated-')
        cls.folder=Path(cls.tmp.name);cls.data=cls.folder/'data';cls.db='postgres'
        cls.env={k:v for k,v in os.environ.items() if not k.upper().startswith('PG')}
        cls.env.update(PGCONNECT_TIMEOUT='3',PGPASSFILE=str(cls.folder/'absent-password-file'))
        cls.flags=subprocess.CREATE_NO_WINDOW if os.name=='nt' else 0
        cls.addClassCleanup(cls.cleanup)
        cls.run_process([cls.bins['initdb'],'-D',str(cls.data),'-U','postgres','-A','trust','--no-locale','--encoding=UTF8'])
        with socket.socket() as s:s.bind(('127.0.0.1',0));cls.port=s.getsockname()[1]
        cls.run_process([cls.bins['pg_ctl'],'-D',str(cls.data),'-l',str(cls.folder/'server.log'),'-w','-t','20',
                         '-o',f'-h 127.0.0.1 -p {cls.port}','start'])
        cls.query(lifecycle.SCHEMA+EXTRA)
        for name in ('geolock_lock_listing_donations','geolock_transition_listing_donations',
                     'geolock_assert_donation_lifecycle','geolock_validate_donation_at_commit',
                     'enforce_donation_transition','enforce_listing_transition'):
            cls.query(lifecycle.routine(name))
        cls.query("""
CREATE TRIGGER trg_donation_transition BEFORE UPDATE ON public.donations FOR EACH ROW EXECUTE FUNCTION public.enforce_donation_transition();
CREATE TRIGGER trg_listing_transition BEFORE UPDATE ON public.listings FOR EACH ROW EXECUTE FUNCTION public.enforce_listing_transition();
CREATE CONSTRAINT TRIGGER donations_lifecycle_at_commit AFTER INSERT OR UPDATE ON public.donations
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.geolock_validate_donation_at_commit();
""")
        cls.query(transport.builder.function(ROOT/'supabase/migrations/20261030_fix_claim_recovery_unresolved_reconciliation.sql',
                                           'public.recover_expired_claims').group(0))
        cls.query('REVOKE ALL ON FUNCTION public.recover_expired_claims(integer) FROM PUBLIC,anon,authenticated; '
                  'GRANT EXECUTE ON FUNCTION public.recover_expired_claims(integer) TO service_role;')
        environment=json.loads(cls.query("SELECT json_build_object('version',version(),'host',inet_server_addr(),"
                                        "'port',inet_server_port(),'data_directory',current_setting('data_directory'),"
                                        "'recovery_md5',(SELECT md5(prosrc) FROM pg_proc WHERE oid='public.recover_expired_claims(integer)'::regprocedure));"))
        assert environment['host']=='127.0.0.1' and environment['port']==cls.port
        (OUT/'environment.json').write_text(json.dumps(environment,indent=2))
        cls.db='template1'

    def setUp(self):
        # Clone the isolated template. The inherited connection guard only permits these names.
        transport.source.IntegrationTests.setUp(self)
        sql=['BEGIN;']
        for i,(claim,task) in enumerate(((C1,T1),(C2,T2)),1):
            sql += [f"INSERT INTO public.donations(donation_id,collection_path,donation_status,total_weight_kg) VALUES('{uid(i)}','DIRECT_PICKUP','CLAIMED',20);",
                    f"INSERT INTO public.listings VALUES('{uid(i+10)}','DIRECT_DONATION','{uid(i)}',NULL,'CLAIMED',clock_timestamp()+interval '1 day',1);",
                    f"INSERT INTO public.donation_claims(claim_id,listing_id,claim_status,claimed_at,ngo_user_id) VALUES('{claim}','{uid(i+10)}','ACTIVE',clock_timestamp()-interval '1 day','{uid(99)}');",
                    f"INSERT INTO public.claim_leases VALUES('{uid(i+20)}','{claim}','ACTIVE',clock_timestamp()-interval '2 days',clock_timestamp()-interval '1 day',NULL,NULL);",
                    f"INSERT INTO public.pickup_tasks(task_id,claim_id,listing_id,task_status,ngo_user_id) VALUES('{task}','{claim}','{uid(i+10)}','CONFIRMED','{uid(99)}');"]
        sql += [f"INSERT INTO public.donation_claims(claim_id,listing_id,claim_status,claimed_at,closed_at,close_reason,ngo_user_id) VALUES('{H}','{uid(12)}','RELEASED',clock_timestamp()-interval '3 days',clock_timestamp()-interval '2 days','EXPIRED_SAFE_RELEASE','{uid(98)}');",
                f"INSERT INTO public.claim_leases VALUES('{uid(23)}','{H}','RELEASED',clock_timestamp()-interval '4 days',clock_timestamp()-interval '3 days',clock_timestamp()-interval '2 days','EXPIRED_SAFE_RELEASE');",
                f"INSERT INTO public.pickup_tasks(task_id,claim_id,listing_id,task_status,ngo_user_id) VALUES('{HT}','{H}','{uid(12)}','STALE','{uid(98)}');",
                "INSERT INTO public.audit_events(event_type,entity_type,outcome,details) VALUES('UNRELATED_HISTORY','OTHER','SUCCESS','{\"preserve\":true}');",
                'COMMIT;']
        self.query('\n'.join(sql))

    def snapshot(self):
        tables=('public.donation_claims','public.claim_leases','public.pickup_tasks','public.listings','public.donations',
                'public.claim_reconciliation_cases','public.audit_events','routing_private.items','cron.job')
        return {t:self.query(f"SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb) FROM {t} x;") for t in tables}

    def aborts_unchanged(self,error,before=None):
        before=self.snapshot() if before is None else before
        message=self.query(PROPOSAL,error)
        self.assertEqual(before,self.snapshot())
        (OUT/(self._testMethodName+'.json')).write_text(json.dumps({'expected_error':error,'sql_output':message,'rollback_unchanged':True},indent=2))

    def test_success_exact_file(self):
        before=self.snapshot();start=time.monotonic()
        output=self.query(PROPOSAL)
        elapsed=time.monotonic()-start
        states=self.query("SELECT string_agg(c.claim_status||'/'||le.lease_status||'/'||t.task_status||'/'||l.listing_status||'/'||d.donation_status,',' ORDER BY c.claim_id) FROM public.donation_claims c JOIN public.claim_leases le USING(claim_id) JOIN public.pickup_tasks t USING(claim_id) JOIN public.listings l ON l.listing_id=c.listing_id JOIN public.donations d ON d.donation_id=l.donation_id WHERE c.claim_id IN ('"+C1+"','"+C2+"');")
        self.assertEqual(states,','.join(['RELEASED/RELEASED/STALE/AVAILABLE/AVAILABLE']*2))
        after=self.snapshot()
        for table,key in (('public.donation_claims','claim_id'),('public.claim_leases','claim_id'),('public.pickup_tasks','claim_id')):
            self.assertEqual([r for r in json.loads(before[table]) if r[key]==H],[r for r in json.loads(after[table]) if r[key]==H])
        self.assertEqual(self.query("SELECT string_agg(event_type||':'||n,',' ORDER BY event_type) FROM (SELECT event_type,count(*) n FROM public.audit_events GROUP BY event_type) s;"),
                         'DONATION_STATUS_CHANGED:2,LEASE_RECOVERY:2,UNRELATED_HISTORY:1')
        self.query((HERE/'exact_two_recovery_postflight_readonly.sql').read_text())
        (OUT/'success.json').write_text(json.dumps({'elapsed_seconds':elapsed,'output':output,'states':states,'after':after},indent=2))

    def test_unrelated_active_pair(self):
        # Independent valid source; no reliance on violated constraints.
        self.query(f"BEGIN; INSERT INTO public.donations(donation_id,collection_path,donation_status,total_weight_kg) VALUES('{uid(63)}','DIRECT_PICKUP','CLAIMED',20); INSERT INTO public.listings VALUES('{uid(64)}','DIRECT_DONATION','{uid(63)}',NULL,'CLAIMED',NULL,1); INSERT INTO public.donation_claims(claim_id,listing_id,claim_status) VALUES('{uid(60)}','{uid(64)}','ACTIVE'); INSERT INTO public.claim_leases VALUES('{uid(61)}','{uid(60)}','ACTIVE',now(),now()+interval '1 day',NULL,NULL); INSERT INTO public.pickup_tasks(task_id,claim_id,listing_id,task_status) VALUES('{uid(62)}','{uid(60)}','{uid(64)}','CONFIRMED'); COMMIT;")
        self.aborts_unchanged('QUEUE_NOT_EXACTLY_TWO_TARGETS')

    def test_existing_row_lock(self):
        before=self.snapshot()
        with self.concurrent(f"BEGIN; SELECT 1 FROM public.donation_claims WHERE claim_id='{C1}' FOR UPDATE; SELECT pg_sleep(5); COMMIT;"):
            self.aborts_unchanged('could not obtain lock on row',before)

    def test_routing_reference(self):
        self.query(f"INSERT INTO routing_private.items VALUES('{uid(70)}','{T1}',NULL);")
        self.aborts_unchanged('ROUTING_REFERENCE_REQUIRES_REVIEW')

    def test_unresolved_case(self):
        self.query(f"INSERT INTO public.claim_reconciliation_cases(claim_id,listing_id,source_type,case_status) VALUES('{C1}','{uid(11)}','DIRECT_DONATION','OPEN');")
        self.aborts_unchanged('OWNERSHIP_OR_RECONCILIATION_CONFLICT')

    def test_unexpected_recovery_outcome(self):
        # Test-only trigger leaves released lease intact but changes claim outcome.
        self.query(f"CREATE FUNCTION public.test_wrong_outcome() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.claim_id='{C1}' AND NEW.claim_status='RELEASED' THEN NEW.claim_status:='RECONCILIATION_REQUIRED'; END IF; RETURN NEW; END $$; CREATE TRIGGER test_outcome BEFORE UPDATE ON public.donation_claims FOR EACH ROW EXECUTE FUNCTION public.test_wrong_outcome();")
        self.aborts_unchanged('SAFE_RELEASE_POSTCONDITION_FAILED')

    def test_active_writer_lock(self):
        before=self.snapshot()
        with self.concurrent(f"BEGIN; UPDATE public.claim_leases SET expires_at=expires_at WHERE claim_id='{C1}'; SELECT pg_sleep(5); COMMIT;"):
            self.aborts_unchanged('could not obtain lock on relation',before)

    def test_source_fingerprint_drift(self):
        self.query("COMMENT ON FUNCTION public.recover_expired_claims(integer) IS 'test metadata';")
        # Modify only source formatting; never relax the proposal's actual pin.
        body=transport.builder.function(ROOT/'supabase/migrations/20261030_fix_claim_recovery_unresolved_reconciliation.sql','public.recover_expired_claims').group(0)
        self.query(body.replace('declare\n','declare\n-- isolated drift\n',1))
        self.aborts_unchanged('RECOVERY_SOURCE_OR_SECURITY_DRIFT')

    def test_historical_row_tamper_rolls_back(self):
        self.query(f"CREATE FUNCTION public.test_history_tamper() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.claim_status='RELEASED' THEN UPDATE public.pickup_tasks SET route_snapshot='UNEXPECTED' WHERE task_id='{HT}'; END IF; RETURN NEW; END $$; CREATE TRIGGER test_history BEFORE UPDATE ON public.donation_claims FOR EACH ROW EXECUTE FUNCTION public.test_history_tamper();")
        self.aborts_unchanged('HISTORICAL_ROWS_CHANGED')

    def test_unrelated_audit_update_rolls_back(self):
        self.query("CREATE FUNCTION public.test_audit_tamper() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN UPDATE public.audit_events SET details='{\"tampered\":true}' WHERE event_type='UNRELATED_HISTORY'; RETURN NEW; END $$; CREATE TRIGGER test_audit BEFORE UPDATE ON public.claim_leases FOR EACH ROW EXECUTE FUNCTION public.test_audit_tamper();")
        self.aborts_unchanged('EXISTING_AUDIT_CHANGED')

    def test_unrelated_audit_delete_rolls_back(self):
        self.query("CREATE FUNCTION public.test_audit_delete() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN DELETE FROM public.audit_events WHERE event_type='UNRELATED_HISTORY'; RETURN NEW; END $$; CREATE TRIGGER test_audit BEFORE UPDATE ON public.claim_leases FOR EACH ROW EXECUTE FUNCTION public.test_audit_delete();")
        self.aborts_unchanged('EXISTING_AUDIT_CHANGED')

    def test_unexpected_new_audit_rolls_back(self):
        self.query("CREATE FUNCTION public.test_extra_audit() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN INSERT INTO public.audit_events(event_type,outcome) VALUES('UNEXPECTED','SUCCESS'); RETURN NEW; END $$; CREATE TRIGGER test_audit BEFORE UPDATE ON public.claim_leases FOR EACH ROW EXECUTE FUNCTION public.test_extra_audit();")
        self.aborts_unchanged('RECOVERY_AUDIT_MISMATCH')

    def test_large_unrelated_audit_history(self):
        self.query("INSERT INTO public.audit_events(event_type,outcome,details) SELECT 'BULK_UNRELATED','SUCCESS',jsonb_build_object('i',s,'payload',repeat('x',4096)) FROM generate_series(1,5000) s;")
        fingerprint="SELECT count(*)||':'||md5(string_agg(md5(to_jsonb(a)::text),'' ORDER BY event_id)) FROM public.audit_events a WHERE event_type='BULK_UNRELATED';"
        before=self.query(fingerprint);start=time.monotonic()
        self.query(PROPOSAL)
        elapsed=time.monotonic()-start
        self.assertEqual(before,self.query(fingerprint))
        self.assertEqual(self.query("SELECT count(*) FROM public.audit_events WHERE event_type IN ('DONATION_STATUS_CHANGED','LEASE_RECOVERY');"),'4')
        (OUT/'large-audit-history.json').write_text(json.dumps({'prior_bulk_rows':5000,'payload_bytes_per_row':4096,'elapsed_seconds':elapsed,'bulk_fingerprint_unchanged':True},indent=2))

    def test_listing_expires_during_recovery_rolls_back(self):
        self.query(f"CREATE FUNCTION public.test_expiry_race() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN UPDATE public.listings SET listing_expires_at=clock_timestamp()-interval '1 second' WHERE listing_id='{uid(11)}'; RETURN NEW; END $$; CREATE TRIGGER test_expiry BEFORE UPDATE ON public.claim_leases FOR EACH ROW EXECUTE FUNCTION public.test_expiry_race();")
        self.aborts_unchanged('SAFE_RELEASE_POSTCONDITION_FAILED')

ENABLED=False
if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run-isolated',action='store_true',required=True)
    parser.add_argument('--output-dir',type=Path,required=True)
    args=parser.parse_args();ENABLED=True;OUT=args.output_dir.resolve()
    if not OUT.is_relative_to(ROOT):parser.error('Evidence must remain within workspace')
    OUT.mkdir(parents=True,exist_ok=False);transport.EVIDENCE_DIR=OUT
    (OUT/'proposal-input.sql').write_text(PROPOSAL,encoding='utf-8',newline='\n')
    (OUT/'harness-input.py').write_text(Path(__file__).read_text(),encoding='utf-8',newline='\n')
    suite=unittest.TestSuite(ExactTwoTests(n) for n in ExactTwoTests.__dict__ if n.startswith('test_'))
    with (OUT/'test-run.log').open('w',encoding='utf-8') as log:
        class Tee:
            def write(self,s):print(s,end='',file=__import__('sys').stderr);log.write(s);log.flush()
            def flush(self):log.flush()
        result=unittest.TextTestRunner(stream=Tee(),verbosity=2).run(suite)
    report={'status':'PASS' if result.wasSuccessful() else 'FAIL','tests_run':result.testsRun,
            'failures':[{'test':str(t),'traceback':s} for t,s in result.failures],
            'errors':[{'test':str(t),'traceback':s} for t,s in result.errors],
            'proposal_sha256':hashlib.sha256((HERE/'exact_two_recovery_transaction_proposal.sql').read_bytes()).hexdigest(),
            'target':'NEW_DISPOSABLE_LOOPBACK_CLUSTER_ONLY','supabase_connections':0}
    (OUT/'results.json').write_text(json.dumps(report,indent=2))
    raise SystemExit(not result.wasSuccessful())
