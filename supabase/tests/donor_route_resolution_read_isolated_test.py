"""Fresh loopback PG17 only. No DSN/profile accepted; no resolver provision/finalize.

Historical terminal rows are explicitly synthetic reader fixtures, not evidence of
a protected release. Existing protected report/evidence RPCs exercise write auth.
"""
import argparse
import json
import multiprocessing as mp
import os
from pathlib import Path
import unittest
from concurrent.futures import ThreadPoolExecutor
from uuid import uuid4

import automatic_routing_isolated_test as auto
import psycopg

ROOT = auto.ROOT
BASE = 'docs/stage8/stage-a/forward-migrations/20261106_route_interruption_resolution.sql'
BASE_PIN = 'a9fe7713fe2ffd65816743b52abd43695d63d1ecbb45fd216983c4a952eca557'
NEW = 'docs/stage8/stage-a/forward-migrations/20261107_donor_route_resolution_read.sql'
DONOR_B = auto.existing.uid('donor-reader-b')
NO = 'NO_HANDOVER_SOURCE_RETAINS_GOODS'


class DonorReadTests(auto.AutomaticTests):
    @classmethod
    def setUpClass(cls):
        assert auto.assembly.digest(ROOT / BASE) == BASE_PIN
        auto.AutomaticTests.setUpClass.__func__(cls)
        cls.lane.hashes[BASE] = BASE_PIN
        cls.lane.hashes[NEW] = auto.assembly.digest(ROOT / NEW)
        cls.lane.hashes[str(Path(__file__).relative_to(ROOT)).replace('\\', '/')] = auto.assembly.digest(Path(__file__))
        receipt = 'docs/stage8/stage-a/forward-migrations/20261105_routing_receipt_readonly.sql'
        cls.lane.hashes[receipt] = auto.assembly.digest(ROOT / receipt)
        cls.lane.apply(receipt)
        cls.lane.apply(BASE)
        catalog = "SELECT coalesce(jsonb_object_agg(oid::regprocedure::text,to_jsonb(p)-'oid'),'{}') FROM pg_proc p WHERE pronamespace IN ('public'::regnamespace,'routing_private'::regnamespace,'fleet_private'::regnamespace,'resolution_private'::regnamespace)"
        before = cls.lane.js(catalog)
        cls.lane.apply(NEW)
        after = cls.lane.js(catalog)
        assert all(after.get(k) == v for k, v in before.items()), 'EXISTING_FUNCTION_CHANGED'
        cls.lane.save('donor-reader-function-preservation.json', {'preserved': len(before), 'added': sorted(set(after)-set(before))})
        cls.lane.save('donor-reader-function-metadata.json', cls.lane.js("SELECT jsonb_build_object('md5',md5(replace(prosrc,E'\\r\\n',E'\\n')),'owner',proowner::regrole::text,'stable',provolatile='s','definer',prosecdef,'config',proconfig,'acl',proacl::text) FROM pg_proc WHERE oid='public.get_my_donation_route_resolution(uuid)'::regprocedure"))
        # No trusted resolver login, operator mapping, or finalization is created.
        fixture = cls()
        auto.AutomaticTests.setUp(fixture)
        try:
            fixture.prepare(two=True)
            fixture.authorize()
            cls.route = fixture.rid
            stops = fixture.session.rpc('get_my_authorized_route', {'p_route': cls.route})['stops']
            fixture.session.rpc('start_pickup', {'p_claim': stops[0]['claim_id']})
            cls.lane.sql(f"INSERT INTO auth.users(id,email) VALUES('{DONOR_B}','donor-reader-b@local.invalid'); INSERT INTO public.user_profiles(user_id,full_name,role) VALUES('{DONOR_B}','SYNTHETIC B','DONOR'); INSERT INTO public.donor_profiles(user_id) VALUES('{DONOR_B}');")
            cls.lane.sql(f"UPDATE public.donations SET donor_user_id='{DONOR_B}' WHERE donation_id=(SELECT l.donation_id FROM public.listings l JOIN public.pickup_tasks t USING(listing_id) WHERE t.task_id='{stops[1]['task_id']}'); UPDATE public.claim_leases SET expires_at=clock_timestamp()-interval '1 second'; SELECT public.recover_expired_claims(100);")
            cls.unreported = 'donor_unreported_' + uuid4().hex
            cls.lane.sql('CREATE DATABASE ' + cls.unreported + ' TEMPLATE ' + fixture.db, db='postgres')
            # Test-only feature flag; no resolver is activated or invoked.
            cls.lane.sql('UPDATE resolution_private.config SET enabled=true')
            with auto.connect(cls.lane.port, fixture.db, 'geolock_local_ngo_login') as conn:
                conn.execute('SET LOCAL ROLE authenticated')
                conn.execute("SELECT set_config('request.jwt.claim.sub',%s,true)", (auto.existing.NGO,))
                cls.case = conn.execute("SELECT public.report_my_route_interruption(%s,'OTHER_REQUIRES_REVIEW',%s)", (cls.route, str(uuid4()))).fetchone()[0]['case_id']
            cls.lane.sql('UPDATE resolution_private.config SET enabled=false')
            cls.rows = cls.lane.js(f"SELECT jsonb_agg(jsonb_build_object('task',t.task_id,'claim',t.claim_id,'donation',d.donation_id,'donor',d.donor_user_id) ORDER BY i.ordinal) FROM routing_private.items i JOIN public.pickup_tasks t USING(task_id) JOIN public.listings l ON l.listing_id=t.listing_id JOIN public.donations d ON d.donation_id=l.donation_id WHERE i.route_id='{cls.route}'")
            cls.template = 'donor_reader_' + uuid4().hex
            cls.lane.sql('CREATE DATABASE ' + cls.template + ' TEMPLATE ' + fixture.db, db='postgres')
        finally:
            fixture.doCleanups()
        cls.lane.db = 'postgres'

    def setUp(self):
        self.db = 'donor_test_' + uuid4().hex
        self.lane.sql('CREATE DATABASE ' + self.db + ' TEMPLATE ' + self.template, db='postgres')
        self.lane.db = self.db
        self.addCleanup(self.drop)
        self.a, self.b = self.rows

    def scalar(self, sql):
        with auto.connect(self.lane.port, self.db, 'postgres') as conn:
            return conn.execute(sql).fetchone()[0]

    def rpc(self, name, args, actor=None, role='authenticated', readonly=False):
        assert name in {'get_my_donation_route_resolution', 'submit_route_resolution_evidence'}
        with auto.connect(self.lane.port, self.db, 'geolock_local_ngo_login') as conn:
            if readonly:
                conn.execute('BEGIN READ ONLY')
            conn.execute('SET LOCAL ROLE ' + role)
            conn.execute("SELECT set_config('request.jwt.claim.sub',%s,true)", (actor if actor is not None else self.a['donor'],))
            value = conn.execute('SELECT public.' + name + '(' + ','.join('%s' for _ in args) + ')', args).fetchone()[0]
            if readonly:
                self.assertEqual(conn.execute('SHOW transaction_read_only').fetchone()[0], 'on')
                conn.rollback()
            return value

    def read(self, donation=None, actor=None):
        return self.rpc('get_my_donation_route_resolution', [donation or self.a['donation']], actor, readonly=True)

    def enable(self):
        self.lane.sql('UPDATE resolution_private.config SET enabled=true')

    def digest(self):
        tables = ['public.donations','public.listings','public.donation_claims','public.claim_leases','public.pickup_tasks','public.pickup_routes','public.active_task_route_assignments','public.claim_reconciliation_cases','public.claim_reconciliation_evidence','public.audit_events','routing_private.items','routing_private.bindings','routing_private.requests','resolution_private.config','resolution_private.cases','resolution_private.items','resolution_private.evidence','resolution_private.requests','resolution_private.releases','resolution_private.incidents','resolution_private.operators']
        return self.scalar('SELECT md5(jsonb_build_array(' + ','.join("(SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text),'[]') FROM " + t + ' t)' for t in tables) + ')::text)')

    def evidence(self, task, assertion, actor):
        version = self.scalar(f"SELECT version FROM resolution_private.cases WHERE case_id='{self.case}'")
        return self.rpc('submit_route_resolution_evidence', [self.case, task, assertion, version, str(uuid4())], actor)

    def history(self, count, unresolved_last=False):
        # Deliberately seeded historical read fixtures. No finalizer or status
        # transition is claimed as tested by this constructor. Triggers are only
        # suppressed inside this disposable owner's fixture transaction.
        with auto.connect(self.lane.port, self.db, 'postgres') as conn:
            conn.execute('SET LOCAL session_replication_role=replica')
            for n in range(count):
                claim, task, route, case = [str(uuid4()) for _ in range(4)]
                opened = unresolved_last and n == count-1
                def clone(table, where, patch):
                    conn.execute('INSERT INTO '+table+' SELECT (jsonb_populate_record(NULL::'+table+',to_jsonb(x)||%s::jsonb)).* FROM '+table+' x WHERE '+where, (json.dumps(patch),))
                clone('public.donation_claims', "claim_id='"+self.a['claim']+"'", dict(claim_id=claim, claim_status='RELEASED', request_id=str(uuid4())))
                clone('public.claim_leases', "claim_id='"+self.a['claim']+"'", dict(claim_id=claim, lease_id=str(uuid4()), lease_status='RELEASED'))
                clone('public.pickup_tasks', "task_id='"+self.a['task']+"'", dict(task_id=task, claim_id=claim, task_status='STALE'))
                clone('public.pickup_routes', "route_id='"+self.route+"'", dict(route_id=route, route_status='ABANDONED', request_id=str(uuid4())))
                clone('routing_private.bindings', "route_id='"+self.route+"'", dict(route_id=route, closed_at='2026-10-01T00:00:00Z', created_at=f'2026-09-{28-n:02}T00:00:00Z'))
                clone('routing_private.items', "route_id='"+self.route+"' AND task_id='"+self.a['task']+"'", dict(route_id=route, task_id=task, released_at='2026-10-01T00:00:00Z'))
                clone('resolution_private.cases', "case_id='"+self.case+"'", dict(case_id=case, route_id=route, status='AWAITING_EVIDENCE' if opened else 'RESOLVED', resolved_at=None if opened else '2026-10-01T00:00:00Z'))
                clone('resolution_private.items', "case_id='"+self.case+"' AND task_id='"+self.a['task']+"'", dict(case_id=case, task_id=task, claim_id=claim))
                clone('public.claim_reconciliation_cases', "claim_id='"+self.a['claim']+"'", dict(case_id=str(uuid4()), claim_id=claim, case_status='RESOLVED_RELEASED'))
        return route

    def test_donor_01_readonly_and_no_mutations(self):
        self.enable(); before = self.digest()
        for _ in range(3):
            value = self.read(); self.assertTrue(value['contexts'][0]['can_submit_evidence'])
        self.assertEqual(before, self.digest())
        self.lane.save('donor-reader-readonly-capture.json', value)

    def test_donor_02_foreign_and_missing_are_identical(self):
        errors = []
        for did in [self.b['donation'], str(uuid4()), None]:
            with self.assertRaises(psycopg.Error) as caught:
                self.rpc('get_my_donation_route_resolution', [did])
            errors.append((caught.exception.sqlstate, caught.exception.diag.message_primary))
        self.assertEqual(errors, [('42501','DONATION_NOT_FOUND_OR_FORBIDDEN')]*3)

    def test_donor_03_roles_and_grants(self):
        for actor in ['', auto.existing.NGO]:
            with self.assertRaisesRegex(psycopg.Error, 'DONATION_NOT_FOUND_OR_FORBIDDEN'):
                self.read(actor=actor)
        for role in ['anon','service_role','geolock_graph_worker','geolock_planner','geolock_validator','geolock_route_resolver']:
            self.assertFalse(self.scalar(f"SELECT has_function_privilege('{role}','public.get_my_donation_route_resolution(uuid)','EXECUTE')"))
        self.assertTrue(self.scalar("SELECT has_function_privilege('authenticated','public.get_my_donation_route_resolution(uuid)','EXECUTE')"))
        self.assertEqual(self.scalar('SELECT count(*) FROM resolution_private.operators'), 0)
        with self.assertRaises(psycopg.Error) as denied:
            self.rpc('get_my_donation_route_resolution',[self.a['donation']],role='anon',readonly=True)
        self.assertEqual(denied.exception.sqlstate,'42501')

    def test_donor_04_evidence_is_scoped_and_missing_is_null(self):
        self.enable()
        self.evidence(self.b['task'], NO, self.b['donor'])
        row = self.read()['contexts'][0]
        self.assertIsNone(row['donor_evidence']['assertion'])
        self.assertNotIn(self.b['donor'], json.dumps(self.read()))
        self.assertNotIn(self.b['task'], json.dumps(self.read()))

    def test_donor_05_writer_independently_denies_foreign_task(self):
        self.enable(); before = self.digest()
        with self.assertRaisesRegex(psycopg.Error, 'ITEM_PARTICIPANT_ONLY'):
            self.evidence(self.b['task'], NO, self.a['donor'])
        self.assertEqual(before, self.digest())
        self.evidence(self.a['task'], NO, self.a['donor'])
        self.assertEqual(self.read()['contexts'][0]['donor_evidence']['assertion'], NO)

    def test_donor_06_disabled_and_never_started_restriction(self):
        value = self.read(self.b['donation'], self.b['donor'])
        self.assertFalse(value['enabled']); self.assertFalse(value['contexts'][0]['can_submit_evidence'])
        self.enable(); value = self.read(self.b['donation'], self.b['donor'])
        self.assertNotIn('HANDOVER_TO_NGO_CONFIRMED', value['contexts'][0]['allowed_assertions'])
        with self.assertRaisesRegex(psycopg.Error, 'NEVER_STARTED_HANDOVER_FORBIDDEN'):
            self.evidence(self.b['task'], 'HANDOVER_TO_NGO_CONFIRMED', self.b['donor'])

    def test_donor_07_no_case_read_never_reports(self):
        self.drop(); self.lane.sql('CREATE DATABASE '+self.db+' TEMPLATE '+self.unreported, db='postgres'); self.lane.db=self.db
        self.enable(); before=self.digest(); row=self.read()['contexts'][0]
        self.assertIsNone(row['case_id']); self.assertEqual(row['blocking_reason'],'AWAITING_NGO_REPORT')
        self.assertEqual(before,self.digest())

    def test_donor_08_removed_assignments_preserve_history(self):
        self.lane.sql(f"DELETE FROM public.active_task_route_assignments WHERE route_id='{self.route}'")
        row=self.read()['contexts'][0]
        self.assertEqual(row['route_id'],self.route); self.assertEqual(row['case_id'],self.case)

    def test_donor_09_distinct_terminal_history(self):
        self.enable(); old=self.history(1); value=self.read()
        self.assertEqual(len(value['contexts']),2)
        self.assertEqual(sum(x['can_submit_evidence'] for x in value['contexts']),1)
        row=next(x for x in value['contexts'] if x['route_id']==old)
        self.assertEqual(row['resolution_status'],'RESOLVED'); self.assertEqual(row['claim_reconciliation_status'],'RESOLVED_RELEASED')

    def test_donor_10_ambiguity_disables_all_contexts(self):
        self.enable(); self.history(1,True); value=self.read()
        self.assertTrue(value['association_conflict']); self.assertFalse(any(x['can_submit_evidence'] for x in value['contexts']))

    def test_donor_11_truncation_scans_omitted_history(self):
        self.enable(); hidden=self.history(21,True); value=self.read()
        self.assertEqual(len(value['contexts']),20); self.assertTrue(value['history_truncated'])
        self.assertTrue(value['association_conflict']); self.assertNotIn(hidden,json.dumps(value))
        self.assertFalse(any(x['can_submit_evidence'] for x in value['contexts']))

    def test_donor_12_source_drift_hides_evidence_and_blocks(self):
        self.enable(); self.evidence(self.a['task'],NO,self.a['donor'])
        self.lane.sql(f"UPDATE resolution_private.items SET source_actor='{DONOR_B}' WHERE case_id='{self.case}' AND task_id='{self.a['task']}'")
        value=self.read(); self.assertTrue(value['association_conflict'])
        self.assertIsNone(value['contexts'][0]['donor_evidence']['assertion'])
        self.assertFalse(value['contexts'][0]['can_submit_evidence'])

    def test_donor_13_latest_amendment_and_version_race(self):
        self.enable(); old=self.read()['contexts'][0]['case_version']
        self.evidence(self.a['task'],NO,self.a['donor'])
        self.evidence(self.a['task'],'UNKNOWN_CUSTODY',self.a['donor'])
        row=self.read()['contexts'][0]
        self.assertEqual(row['resolution_status'],'MANUAL_REVIEW'); self.assertEqual(row['donor_evidence']['assertion'],'UNKNOWN_CUSTODY')
        self.assertEqual(self.scalar('SELECT count(*) FROM resolution_private.evidence'),2)
        with self.assertRaisesRegex(psycopg.Error,'CASE_VERSION_STALE'):
            self.rpc('submit_route_resolution_evidence',[self.case,self.a['task'],NO,old,str(uuid4())])

    def test_donor_14_metadata_and_read_only_dependencies(self):
        meta=self.scalar("SELECT jsonb_build_object('owner',proowner::regrole::text,'stable',provolatile='s','definer',prosecdef,'config',proconfig,'body',prosrc,'args',pg_get_function_arguments(oid)) FROM pg_proc WHERE oid='public.get_my_donation_route_resolution(uuid)'::regprocedure")
        self.assertEqual(meta['owner'],'postgres'); self.assertTrue(meta['stable']); self.assertTrue(meta['definer'])
        self.assertEqual(meta['config'],['search_path=pg_catalog, pg_temp']); self.assertEqual(meta['args'],'p_donation uuid')
        self.assertNotRegex(meta['body'],r'(?i)\b(INSERT|UPDATE|DELETE|PERFORM|EXECUTE|pg_advisory_xact_lock)\b')
        self.assertEqual(self.scalar("SELECT provolatile FROM pg_proc WHERE oid='auth.uid()'::regprocedure"),'s')
        permissions={r:self.scalar(f"SELECT has_function_privilege('{r}','public.get_my_donation_route_resolution(uuid)','EXECUTE')") for r in ['anon','authenticated','service_role','geolock_graph_worker','geolock_planner','geolock_validator','geolock_route_resolver']}
        self.lane.save('donor-reader-effective-permissions.json',permissions)

    def test_donor_15_coherent_snapshot_during_evidence_amendments(self):
        self.enable()
        def amend():
            for assertion in [NO,'UNKNOWN_CUSTODY',NO]:
                self.evidence(self.a['task'],assertion,self.a['donor'])
        with ThreadPoolExecutor(max_workers=1) as pool:
            write=pool.submit(amend)
            for _ in range(6):
                row=self.read()['contexts'][0]
                self.assertLessEqual(row['donor_evidence']['version'] or 0,row['case_version'])
            write.result(timeout=15)
        self.assertEqual(self.scalar('SELECT count(*) FROM resolution_private.evidence'),3)

    def test_donor_16_claim_case_source_drift_fails_closed(self):
        self.enable()
        self.lane.sql(f"UPDATE public.claim_reconciliation_cases SET donation_id='{self.b['donation']}' WHERE claim_id='{self.a['claim']}'")
        value=self.read()
        self.assertTrue(value['association_conflict']); self.assertFalse(value['contexts'][0]['can_submit_evidence'])

    def test_donor_17_independent_participant_evidence_and_timestamps(self):
        self.enable()
        self.evidence(self.a['task'],NO,auto.existing.NGO)
        self.evidence(self.a['task'],NO,self.a['donor'])
        row=self.read()['contexts'][0]
        self.assertEqual(row['donor_evidence']['assertion'],NO)
        self.assertEqual(row['ngo_evidence']['assertion'],NO)
        self.assertIsNotNone(row['donor_evidence']['submitted_at'])
        self.assertGreater(row['donor_evidence']['version'],row['ngo_evidence']['version'])
        self.assertEqual(self.scalar('SELECT count(*) FROM resolution_private.finalizations'),0)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run-isolated',action='store_true',required=True)
    parser.add_argument('--runtime',type=Path,required=True)
    args=parser.parse_args(); runtime=args.runtime.resolve()
    assert runtime.name.startswith('geolock-spatial-runtime-') and (runtime/'pgsql/bin/postgres.exe').is_file()
    for key in list(os.environ):
        if key.upper().startswith(('PG','GEOLOCK','SUPABASE')) or key.upper() in ('DATABASE_URL','DB_URL'):
            os.environ.pop(key,None)
    DonorReadTests.runtime=runtime
    suite=unittest.TestSuite(DonorReadTests(n) for n in unittest.defaultTestLoader.getTestCaseNames(DonorReadTests) if n.startswith('test_donor_'))
    result=unittest.TextTestRunner(verbosity=2,failfast=True).run(suite)
    summary=dict(status='PASS' if result.wasSuccessful() else 'FAIL',tests=result.testsRun,failures=len(result.failures),errors=len(result.errors),dev_connections=0,resolver_logins_created=0,finalization_calls=0,migration_sha256=auto.assembly.digest(ROOT/NEW),base_sha256=auto.assembly.digest(ROOT/BASE))
    if hasattr(DonorReadTests,'lane'):
        DonorReadTests.lane.save('donor-reader-result.json',summary)
        print(json.dumps(dict(evidence=str(DonorReadTests.out),**summary),indent=2))
    return not result.wasSuccessful()


if __name__=='__main__':
    mp.freeze_support()
    raise SystemExit(main())
