"""Opt-in NEW loopback PostgreSQL only; no external URL/DSN accepted.

Runs corrected delayed harness and complete two-actor sequence with actual
captured claim/start/complete/cancel bodies, lifecycle helpers and listing triggers.
HTTP/PostgREST/JWT, road, cron health and photos are explicit reduced-fixture
dependencies. No recovery invocation, installed server, Supabase or live fixture.
"""
import argparse
import base64
import json
import os
import re
import shutil
import tempfile
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch

import psycopg
from psycopg import sql
from psycopg.rows import dict_row
import claim_recovery_automatic_isolated_test as reused
import claim_concurrency_test as common
import claim_two_actor_acceptance as suite
import claim_e2e_contract as contract
import claim_fault_injection_dev_test as fault
import sys

CONNECT = psycopg.connect
ACTORS = [reused.OWNER, '22222222-2222-2222-2222-222222222222']
FAKE_DEV_DSN = ('postgresql://postgres.rcgyuwiidqvrgbxswhqj:unused@'
                'aws-0-ap-northeast-2.pooler.supabase.com:5432/postgres?sslmode=require')


class TwoActorIsolatedTests(unittest.TestCase):
    run_process = reused.AutomaticRecoveryTests.__dict__['run_process']
    query = reused.AutomaticRecoveryTests.__dict__['query']
    cleanup_cluster = reused.AutomaticRecoveryTests.__dict__['cleanup_cluster']

    @classmethod
    def setUpClass(cls):
        reused.AutomaticRecoveryTests.setUpClass.__func__(cls)
        # Reuse infrastructure only. No old recovery test or recovery call runs.
        cls.query("""
          insert into public.ngo_profiles values('22222222-2222-2222-2222-222222222222',true,now(),'isolated-road-node');
          insert into public.user_profiles values('22222222-2222-2222-2222-222222222222','NGO');
          alter table public.donations add column title text default 'STAGE3J-2A-isolated-fixture';
          create table public.donation_images(image_id uuid default gen_random_uuid(),donation_id uuid);
          create table public.donation_items(item_id uuid default gen_random_uuid(),donation_id uuid);
          alter table cron.job_run_details add column end_time timestamptz;
          alter table cron.job_run_details add column start_time timestamptz;
          create table public.claim_reconciliation_evidence(request_id uuid primary key,
            case_id uuid,actor_user_id uuid,handover_confirmed boolean,response jsonb);
          alter table public.claim_reconciliation_cases add resolved_at timestamptz;
          alter table public.claim_reconciliation_cases add resolution_reason text;
          create function public.recover_expired_claims(integer default 100) returns integer
            language plpgsql as $$ begin raise exception 'RECOVERY_MUST_NOT_RUN'; end $$;
        """)
        # Install actual revised bodies only in this new disposable loopback cluster.
        source = contract.MIGRATION.read_text(encoding='utf-8')
        table = re.search(r'create table if not exists public.operation_failure_events.*?\n\);', source, re.S)[0]
        cls.query(table)
        for m in re.finditer(r'CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION\s+public\.\w+\s*\(.*?\bAS\s+(\$\w*\$).*?\1\s*;', source, re.S|re.I):
            cls.query(m[0])
        cls.query("ALTER TABLE public.operation_failure_events ENABLE ROW LEVEL SECURITY; "
                  "REVOKE ALL ON public.operation_failure_events FROM PUBLIC,anon,authenticated; "
                  "REVOKE ALL ON FUNCTION public.geolock_transition_listing_donations(uuid,text,text,uuid,uuid,text) FROM PUBLIC,anon,authenticated,service_role; "
                  "CREATE UNIQUE INDEX operation_failure_claim_request_unique ON public.operation_failure_events(actor_user_id,request_id,listing_id,operation_name,reason_code) WHERE operation_name='claim_listing' AND actor_user_id IS NOT NULL AND request_id IS NOT NULL AND listing_id IS NOT NULL;")

    def local(self, **kwargs):
        return CONNECT(host='127.0.0.1', port=self.port, user='postgres', dbname='postgres',
                       connect_timeout=3, **kwargs)

    def setUp(self):
        self.query("""truncate public.operation_failure_events,public.audit_events,public.claim_requests,public.claim_cancellation_requests,
          public.pickup_tasks,public.claim_leases,public.donation_claims,public.listings,public.donations,
          public.claim_reconciliation_cases,public.active_task_route_assignments,public.pickup_route_stops,
          public.listing_eligibility_refresh_jobs,public.ngo_listing_road_eligibility,
          public.donation_images,public.donation_items cascade;""")
        self.listings = [str(uuid.uuid4()), str(uuid.uuid4())]
        self.donations = [str(uuid.uuid4()), str(uuid.uuid4())]
        for listing, donation in zip(self.listings, self.donations):
            self.query(f"""begin;
              insert into public.donations(donation_id,collection_path,donation_status,total_weight_kg)
                values('{donation}','DIRECT_PICKUP','AVAILABLE',20);
              insert into public.listings(listing_id,donation_id,source_type,listing_status)
                values('{listing}','{donation}','DIRECT_DONATION','AVAILABLE');
              insert into public.donation_images(donation_id) values('{donation}');
              insert into public.donation_items(donation_id) values('{donation}');
              update public.listing_eligibility_refresh_jobs set job_status='COMPLETED';
              commit;""")
        self.tokens = ['header.' + base64.urlsafe_b64encode(json.dumps({'sub': a}).encode()).decode().rstrip('=')
                       + '.fixture-not-a-real-jwt' for a in ACTORS]

    def rpc(self, base, key, token, name, params):
        names = {'claim_listing': ['p_listing', 'p_request'], 'cancel_claim': ['p_claim', 'p_request'],
                 'start_pickup': ['p_claim'], 'complete_pickup': ['p_claim', 'p_handover_confirmed'],
                 'get_authorized_audit_events': ['p_entity_type','p_entity_id']}
        self.assertIn(name, names)  # Recovery is impossible through this adapter.
        try:
            with self.local() as conn, conn.cursor() as cur:
                cur.execute('SET LOCAL ROLE authenticated')
                cur.execute("SELECT set_config('request.jwt.claim.sub',%s,true)", (common.jwt_subject(token),))
                template = ('SELECT coalesce(jsonb_agg(to_jsonb(a)),\'[]\'::jsonb) FROM public.{}({}) a'
                            if name == 'get_authorized_audit_events' else 'SELECT public.{}({})')
                cur.execute(sql.SQL(template).format(sql.Identifier(name),
                            sql.SQL(',').join(sql.Placeholder() for _ in names[name])),
                            [params[n] for n in names[name]])
                result = cur.fetchone()[0]
            return 200, result
        except psycopg.Error as error:
            return 400, {'code': error.sqlstate, 'message': error.diag.message_primary}

    def rest(self, base, service, table_query):
        table, _, query = table_query.partition('?')
        self.assertIn(table, ('donation_claims', 'listings', 'claim_requests', 'audit_events', 'claim_leases', 'pickup_tasks', 'operation_failure_events', 'donations'))
        params = dict(common.urllib.parse.parse_qsl(query))
        columns = params.pop('select').split(',')
        self.assertTrue(all(re.fullmatch('[a-z_]+', c) for c in columns))
        filters, values = [], []
        for key, value in params.items():
            if key == 'or':
                listing = re.search(r'listing_id\.eq\.([a-f0-9-]+)', value).group(1)
                filters.append(sql.SQL('listing_id={}').format(sql.Placeholder())); values.append(listing)
            elif value.startswith('eq.'):
                filters.append(sql.SQL('{}={}').format(sql.Identifier(key), sql.Placeholder()))
                values.append(value[3:])
            elif value.startswith('in.'):
                filters.append(sql.SQL('{}::text=ANY({})').format(sql.Identifier(key), sql.Placeholder()))
                values.append(value[4:-1].split(','))
            else:
                self.fail('Unexpected fixture REST filter')
        with self.local(row_factory=dict_row) as conn, conn.cursor() as cur:
            cur.execute(sql.SQL('SELECT {} FROM public.{} WHERE {}').format(
                sql.SQL(',').join(map(sql.Identifier, columns)), sql.Identifier(table),
                sql.SQL(' AND ').join(filters)), values)
            return json.loads(json.dumps(cur.fetchall(), default=str))

    def read(self, listing):
        with self.local() as conn, conn.cursor() as cur:
            cur.execute('SET TRANSACTION READ ONLY')
            cur.execute((suite.PACKAGE/'02_fixture.sql').read_text(encoding='utf-8'), {'listing': listing})
            return cur.fetchone()[0]

    def healthy(self):
        return dict(functions=json.loads((suite.PACKAGE/'approved_functions.json').read_text(encoding='utf-8')),
                    other_functions_md5='6991083a881075cdf0e75d0c266396f0',
                    jobs=[{'jobid': 1, 'active': True}, {'jobid': 2, 'active': True}, {'jobid': 3, 'active': False}],
                    recovery_history={'total': 17, 'failed': 0, 'unfinished': 0}, healthy_eligibility_jobs=2,
                    lease_minutes=360, unresolved_cases=0, overdue_active_pairs=0, failure_contract_ok=True, active_recovery_jobs=0)

    def baseline(self):
        h = self.healthy()
        return dict(other_functions_md5=h['other_functions_md5'], recovery_history=h['recovery_history'],
                    function_acls={f['identity']: f.get('acl') for f in h['functions']})

    def test_corrected_delayed_harness_observes_real_pg_waiters(self):
        with patch.object(common, 'rpc', side_effect=self.rpc), patch.object(common, 'rest_rows', side_effect=self.rest), \
             patch.object(psycopg, 'connect', side_effect=lambda *a, **kw: self.local()):
            common.run_delayed_race('fixture', 'key', 'read-only', FAKE_DEV_DSN,
                                    self.listings[0], self.tokens, ACTORS)
        self.assertEqual(len(self.read(self.listings[0])['claims']), 1)

    def test_complete_two_actor_sequence_commits_and_has_no_recovery(self):
        for listing, donation in zip(self.listings, self.donations):
            suite.validate_fixture(self.read(listing), listing, donation, 'STAGE3J-2A-isolated')
        with tempfile.TemporaryDirectory() as folder:
            journal = suite.Journal(Path(folder)/'result')
            with patch.object(common, 'rpc', side_effect=self.rpc), patch.object(common, 'rest_rows', side_effect=self.rest), \
                 patch.object(psycopg, 'connect', side_effect=lambda *a, **kw: self.local()), suite.record_rpcs(journal):
                suite.run_acceptance('fixture', 'key', 'read-only', self.tokens, ACTORS,
                                     self.listings, FAKE_DEV_DSN, self.healthy, self.read, journal, self.baseline())
            events = (journal.folder/'events.jsonl').read_text()
            self.assertIn('TWO_ACTOR_ACCEPTANCE_PASS', events)
        for listing in self.listings:
            s = self.read(listing)
            self.assertEqual(s['listing']['listing_status'], 'AVAILABLE')
            self.assertEqual(s['listing']['listing_version'], 3)
            self.assertEqual(s['listing']['eligibility_generation'], 2)
            self.assertEqual(s['claims'][0]['claim_status'], 'RELEASED')
            self.assertEqual(len(s['audits']), 5)  # 2 attempts + transition + cancel + transition.
            self.assertFalse(s['cases'])
            self.assertFalse(any(a['event_type'] == 'LEASE_RECOVERY' for a in s['audits']))

    def test_claim_audit_failure_rolls_back_all_required_writes(self):
        before = self.read(self.listings[0])
        self.query("""create function public.stage3j_fail_audit() returns trigger language plpgsql as $$
          begin raise exception 'ISOLATED_AUDIT_FAILURE'; end $$;
          create trigger stage3j_fail before insert on public.audit_events for each row
          execute function public.stage3j_fail_audit();""")
        try:
            status, result = self.rpc('', '', self.tokens[0], 'claim_listing',
                {'p_listing': self.listings[0], 'p_request': str(uuid.uuid4())})
            contract.confirmed_receipt(status, result, contract.ROLLBACK_REASON)
            after = self.read(self.listings[0])
            self.assertEqual(len(after['failures']), 1)
            contract.failure_record(result, after['failures'], ACTORS[0], self.listings[0],
                                    after['failures'][0]['request_id'], self.donations[0])
            suite.assert_stable_unchanged(dict(before, failures=after['failures']), after)
            self.assertEqual(self.query('select count(*) from public.claim_requests;'), '0')
        finally:
            self.query('drop trigger stage3j_fail on public.audit_events; drop function public.stage3j_fail_audit();')

    def test_current_health_sql_parses_readonly_and_does_not_fabricate_approval(self):
        with self.local() as conn, conn.cursor() as cur:
            cur.execute('SET TRANSACTION READ ONLY')
            cur.execute((suite.PACKAGE/'01_health.sql').read_text(encoding='utf-8'))
            actual = cur.fetchone()[0]
        with self.assertRaises(RuntimeError):
            suite.validate_health(actual, self.baseline())  # Deliberately not a full DEV schema/security fixture.

    def test_actual_local_catalog_matches_all_nine_revised_source_definitions(self):
        with self.local() as conn, conn.cursor() as cur:
            cur.execute('SET TRANSACTION READ ONLY')
            cur.execute((suite.PACKAGE/'01_health.sql').read_text())
            actual = {f['identity']: f for f in cur.fetchone()[0]['functions']}
        for expected in contract.source_functions():
            self.assertEqual({k: actual[expected['identity']][k] for k in expected}, expected)

    def test_ten_distinct_ngo_race_current_contract(self):
        actors = ACTORS + [str(uuid.UUID(int=900+i)) for i in range(8)]
        for actor in actors[2:]:
            self.query(f"INSERT INTO public.ngo_profiles VALUES('{actor}',true,now(),'isolated-road-node'); "
                       f"INSERT INTO public.user_profiles VALUES('{actor}','NGO');")
        tokens = ['header.' + base64.urlsafe_b64encode(json.dumps({'sub': a}).encode()).decode().rstrip('=')
                  + '.local-test' for a in actors]
        with patch.object(common, 'rpc', side_effect=self.rpc), patch.object(common, 'rest_rows', side_effect=self.rest):
            attempts, responses, state = common.run_race('fixture','key','read',self.listings[0],tokens,actors,10,'local ten-NGO')
        self.assertEqual(sum(r['outcome']=='SUCCESS' for r in responses),1)
        self.assertEqual(sum(r['outcome']=='CONFLICT' for r in responses),9)
        self.assertEqual(len(state['audits']),10)
        self.assertEqual(len(state['transitions']),1)
        self.assertTrue(all(r['client_timing']['elapsed_ms'] >= 0 for r in responses))

    def test_fault_runner_uncertainty_preserves_request_registration(self):
        self.query((suite.ROOT/'supabase/tests/claim_write_failpoints_dev.sql').read_text())
        try:
            with self.local() as conn:
                hooks = fault.verify_hooks(conn)
            with tempfile.TemporaryDirectory() as folder:
                manifest = Path(folder)/'manifest.json'
                manifest.write_text(json.dumps({'fault_hooks': hooks}))
                journal = suite.Journal(Path(folder)/'journal')
                ctx = ('fixture','key','read',self.tokens,ACTORS,[self.listings[0]],FAKE_DEV_DSN,
                       self.healthy,self.read,journal,self.baseline())
                with patch.object(sys,'argv',['fault','--env-file','unused','--manifest',str(manifest),
                    '--output-dir',str(Path(folder)/'unused'),'--execute',
                    '--execution-approval','I_APPROVE_DEV_CLAIM_FAULT_INJECTION']), \
                     patch.object(suite,'prepare',return_value=ctx), \
                     patch.object(common,'rpc',return_value=(503,{})), \
                     patch.object(psycopg,'connect',side_effect=lambda *a,**kw:self.local(autocommit=kw.get('autocommit',False))):
                    with self.assertRaisesRegex(RuntimeError,'UNCONFIRMED'):
                        fault.main()
                self.assertIn('STOP_REVIEW_REQUIRED',(journal.folder/'events.jsonl').read_text())
            self.assertEqual(self.query('SELECT count(*) FROM geolock_stage2_test.claim_write_failpoints;'),'1')
            self.assertFalse(self.read(self.listings[0])['claims'])
        finally:
            # Explicit cleanup of this disposable local cluster, never live error handling.
            self.query((suite.ROOT/'supabase/tests/claim_write_failpoints_dev_cleanup.sql').read_text())

    def test_fault_runner_all_seven_failpoints_receipts_retries_and_authorization(self):
        self.query((suite.ROOT/'supabase/tests/claim_write_failpoints_dev.sql').read_text())
        try:
            with self.local() as conn:
                hooks = fault.verify_hooks(conn)
            with tempfile.TemporaryDirectory() as folder:
                manifest = Path(folder)/'manifest.json'
                manifest.write_text(json.dumps({'fault_hooks': hooks}))
                journal = suite.Journal(Path(folder)/'journal')
                ctx = ('fixture','key','read',self.tokens,ACTORS,[self.listings[0]],FAKE_DEV_DSN,
                       self.healthy,self.read,journal,self.baseline())
                with patch.object(sys,'argv',['fault','--env-file','unused','--manifest',str(manifest),
                    '--output-dir',str(Path(folder)/'unused'),'--execute',
                    '--execution-approval','I_APPROVE_DEV_CLAIM_FAULT_INJECTION']), \
                     patch.object(suite,'prepare',return_value=ctx), \
                     patch.object(common,'rpc',side_effect=self.rpc), patch.object(common,'rest_rows',side_effect=self.rest), \
                     patch.object(psycopg,'connect',side_effect=lambda *a,**kw:self.local(autocommit=kw.get('autocommit',False))):
                    self.assertEqual(fault.main(),0)
                events = [json.loads(line) for line in (journal.folder/'events.jsonl').read_text().splitlines()]
                self.assertEqual(sum(e['event']=='ROLLBACK_VERIFIED' for e in events),7)
            final = self.read(self.listings[0])
            self.assertEqual(len(final['failures']),7)
            self.assertEqual(len(final['claims']),1)
            self.assertEqual(self.query('SELECT count(*) FROM geolock_stage2_test.claim_write_failpoints;'),'0')
        finally:
            self.query((suite.ROOT/'supabase/tests/claim_write_failpoints_dev_cleanup.sql').read_text())


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run-isolated', action='store_true')
    parser.add_argument('--pg-bin', type=Path, required=True)
    args = parser.parse_args()
    if not args.run_isolated:
        parser.error('--run-isolated is required; no external connection parameter exists')
    bins = {n: str(args.pg_bin/(n + ('.exe' if os.name == 'nt' else '')))
            for n in ('initdb', 'pg_ctl', 'psql')}
    if any(not Path(p).is_file() for p in bins.values()):
        parser.error('Local initdb, pg_ctl and psql executables required')
    TwoActorIsolatedTests.bins = bins
    unittest.main(argv=[__file__], verbosity=2)
