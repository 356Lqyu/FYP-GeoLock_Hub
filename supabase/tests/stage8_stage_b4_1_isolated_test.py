"""Stage B.4.1 current composed-schema races in a NEW disposable PostgreSQL.

This wrapper reuses the full-schema Stage B migration assembly and its explicit
Auth/Storage/road/cron doubles. It adds bounded 2/5/10-actor claim races and
selects existing full-schema route-authority negative/race regressions. No
external DSN or Supabase connection is accepted.
"""
import argparse
import copy
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import shutil
import threading
import time
import uuid
import unittest
import psycopg

import stage8_stage_b_isolated_test as stage_b
import stage8_reconciliation_compatibility_isolated_test as runtime

ROOT = stage_b.ROOT
OUT = None
DIAGNOSTIC_MODE = False
APPLY_B43 = False
EXPECT_DEADLOCKS = False
CLAIM_REPETITIONS = 1
CLAIM_TEST_SEQUENCE = 0


class StageB41Tests(stage_b.StageBTests):
    @classmethod
    def setUpClass(cls):
        stage_b.OUT = OUT
        runtime.EVIDENCE_DIR = OUT
        stage_b.StageBTests.bins = {
            name: str(PG_BIN / (name + ('.exe' if os.name == 'nt' else '')))
            for name in ('initdb', 'pg_ctl', 'psql')
        }
        if any(not Path(path).is_file() for path in stage_b.StageBTests.bins.values()):
            raise RuntimeError('Required local PostgreSQL executables not found')
        stage_b.StageBTests.setUpClass.__func__(cls)
        cls.db = 'postgres'
        if APPLY_B43:
            def function_catalog(signature):
                return json.loads(cls.query("""
                  SELECT jsonb_build_object(
                    'signature',p.oid::regprocedure::text,
                    'identity_arguments',pg_get_function_identity_arguments(p.oid),
                    'result_type',pg_get_function_result(p.oid),
                    'owner',pg_get_userbyid(p.proowner),
                    'security_definer',p.prosecdef,'configuration',p.proconfig,
                    'acl',p.proacl::text,
                    'body_md5',md5(replace(p.prosrc,E'\\r\\n',E'\\n')))
                  FROM pg_proc p WHERE p.oid=to_regprocedure('{signature}');
                """.replace('{signature}', signature)))
            signatures = ('public.claim_listing(uuid,uuid)',
                          'public.geolock_lock_listing_donations(uuid,text[])')
            before = {signature: function_catalog(signature) for signature in signatures}
            migration = ROOT / 'docs/stage8/stage-b4-3/migrations/20261105_b43_claim_and_donation_lock_no_key_update.sql'
            cls.query(migration.read_text(encoding='utf-8'))
            after = {signature: function_catalog(signature) for signature in signatures}
            (OUT / 'claim-function-compatibility.json').write_text(
                json.dumps(dict(before=before, after=after,
                                compatible=all(all(before[signature][key] == after[signature][key]
                                                   for key in ('signature','identity_arguments',
                                                       'result_type','owner','security_definer',
                                                       'configuration','acl'))
                                               for signature in signatures)),
                           indent=2) + '\n', encoding='utf-8')
        if DIAGNOSTIC_MODE:
            # Instrument only this disposable database copy. Preserve the
            # selected original/corrected lock path and add stacked diagnostics.
            diagnostic_source = (ROOT / 'docs/stage8/stage-b4-3/migrations/20261105_b43_claim_and_donation_lock_no_key_update.sql'
                                 if APPLY_B43 else ROOT / 'supabase/migrations/20261031_claim_audit_and_failure_capture.sql')
            migration = diagnostic_source.read_text()
            definition = stage_b.builder.function(migration, 'public.claim_listing').group(0)
            definition = definition.replace(
                'v_failure_reason text;',
                'v_failure_reason text; v_error_detail text; v_error_context text; '
                'v_error_constraint text; v_error_table text; v_error_schema text;'
            )
            old_diag = 'get stacked diagnostics v_sqlstate=returned_sqlstate,v_error_message=message_text;'
            new_diag = '''get stacked diagnostics v_sqlstate=returned_sqlstate,v_error_message=message_text,
      v_error_detail=pg_exception_detail,v_error_context=pg_exception_context,
      v_error_constraint=constraint_name,v_error_table=table_name,v_error_schema=schema_name;
    if v_sqlstate='40P01' then
      raise log 'B42_DEADLOCK request=% actor=% sqlstate=% message=% detail=% context=% constraint=% relation=%.%',
        p_request,v_actor,v_sqlstate,v_error_message,v_error_detail,v_error_context,
        v_error_constraint,v_error_schema,v_error_table;
    end if;'''
            if old_diag not in definition:
                raise RuntimeError('Expected claim exception diagnostic site not found')
            cls.query(definition.replace(old_diag, new_diag))
        cls.db = 'postgres'
        cls.query("""
          CREATE FUNCTION public.b42_expire_own_claim_lease(p_claim uuid)
          RETURNS void LANGUAGE plpgsql SECURITY DEFINER
          SET search_path=pg_catalog,public,pg_temp AS $$
          BEGIN
            IF auth.uid() IS NULL OR NOT EXISTS(
              SELECT 1 FROM public.donation_claims
              WHERE claim_id=p_claim AND ngo_user_id=auth.uid()) THEN
              RAISE EXCEPTION 'B42_FIXTURE_ACTOR_MISMATCH';
            END IF;
            UPDATE public.claim_leases
            SET issued_at=clock_timestamp()-interval '7 hours',
                expires_at=clock_timestamp()-interval '1 hour'
            WHERE claim_id=p_claim AND lease_status='ACTIVE';
            IF NOT FOUND THEN RAISE EXCEPTION 'B42_FIXTURE_LEASE_NOT_ACTIVE'; END IF;
          END $$;
          REVOKE ALL ON FUNCTION public.b42_expire_own_claim_lease(uuid) FROM PUBLIC,anon;
          GRANT EXECUTE ON FUNCTION public.b42_expire_own_claim_lease(uuid) TO authenticated;
        """)
        cls.db = 'template1'

    def create_available_direct_listing(self, label):
        request = self.req()
        path = f'{stage_b.D}/pending/{request}/{self.req()}.jpg'
        self.query(
            f"INSERT INTO storage.objects(bucket_id,name,metadata) "
            f"VALUES('geolock-donation-images','{path}','{{\"size\":100,\"mimetype\":\"image/jpeg\"}}');"
        )
        items = [dict(category_id='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
                      item_name='B4.1 SYNTHETIC ITEM', quantity=1, unit_weight_kg=20)]
        images = [dict(storage_path=path, content_type='image/jpeg', size_bytes=100)]
        donation = self.rpc(
            f"public.create_donation_with_images('{request}','{label}',"
            f"'B4.1 synthetic direct pickup','LOCAL',3.01,101.01,"
            f"{self.literal(items)},'102',{self.literal(images)})",
            user=stage_b.D,
        )
        listing = self.query(
            f"SELECT listing_id FROM public.listings WHERE donation_id='{donation}';"
        )
        return dict(request=request, donation=donation, listing=listing, image_path=path)

    def add_ngo_actors(self, count):
        actors = [runtime.source.A, runtime.source.B]
        while len(actors) < count:
            actor = str(uuid.uuid4())
            self.query(f"""
              INSERT INTO auth.users(id,email) VALUES('{actor}','{actor}@local.invalid');
              INSERT INTO public.user_profiles(user_id,full_name,role)
                VALUES('{actor}','B4.1 SYNTHETIC NGO','NGO');
              INSERT INTO public.ngo_profiles(user_id,ngo_name,operating_address,latitude,
                longitude,road_node_id,location_verified_at)
                VALUES('{actor}','B4.1 NGO','LOCAL',3,101,'101',clock_timestamp());
            """)
            actors.append(actor)
        return actors[:count]

    def listing_snapshot(self, listing):
        return json.loads(self.query(f"""
          SELECT jsonb_build_object(
            'listing',(SELECT to_jsonb(l) FROM public.listings l WHERE listing_id='{listing}'),
            'donation',(SELECT to_jsonb(d) FROM public.donations d JOIN public.listings l USING(donation_id) WHERE l.listing_id='{listing}'),
            'claims',(SELECT coalesce(jsonb_agg(to_jsonb(c) ORDER BY claim_id),'[]') FROM public.donation_claims c JOIN public.listings l USING(listing_id) WHERE l.listing_id='{listing}'),
            'leases',(SELECT coalesce(jsonb_agg(to_jsonb(le) ORDER BY lease_id),'[]') FROM public.claim_leases le JOIN public.donation_claims c USING(claim_id) JOIN public.listings l USING(listing_id) WHERE l.listing_id='{listing}'),
            'tasks',(SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY t.task_id),'[]') FROM public.pickup_tasks t JOIN public.donation_claims c ON c.claim_id=t.claim_id JOIN public.listings l ON l.listing_id=c.listing_id WHERE l.listing_id='{listing}'),
            'claim_audits',(SELECT coalesce(jsonb_agg(to_jsonb(a) ORDER BY occurred_at,event_id),'[]') FROM public.audit_events a WHERE a.entity_id='{listing}' OR a.details->>'listing_id'='{listing}'),
            'failures',(SELECT coalesce(jsonb_agg(to_jsonb(f) ORDER BY occurred_at,failure_id),'[]') FROM public.operation_failure_events f WHERE f.listing_id='{listing}')
          );
        """))

    def test_full_package_catalog_security_and_authority(self):
        facts = json.loads(self.query("""
          SELECT jsonb_build_object(
            'server_version',version(),
            'extension_names',(SELECT coalesce(jsonb_agg(extname ORDER BY extname),'[]') FROM pg_extension),
            'public_constraints',(SELECT count(*) FROM pg_constraint WHERE connamespace='public'::regnamespace),
            'enabled_triggers',(SELECT count(*) FROM pg_trigger WHERE NOT tgisinternal AND tgenabled='O'),
            'key_rls',(SELECT jsonb_object_agg(c.relname,c.relrowsecurity) FROM pg_class c
              WHERE c.oid IN ('public.pickup_tasks'::regclass,'public.claim_leases'::regclass,
                'public.donation_claims'::regclass,'public.claim_reconciliation_cases'::regclass,
                'public.audit_events'::regclass,'public.pickup_routes'::regclass,
                'public.active_task_route_assignments'::regclass)),
            'authority_trigger',(SELECT jsonb_build_object('enabled',tgenabled='O','function',p.proname)
              FROM pg_trigger t JOIN pg_proc p ON p.oid=t.tgfoid WHERE t.tgname='routing_task_authority'),
            'signatures',(SELECT jsonb_object_agg(signature,owner_name) FROM (
              SELECT p.oid::regprocedure::text signature,pg_get_userbyid(p.proowner) owner_name
              FROM pg_proc p WHERE p.oid IN (
                'public.claim_listing(uuid,uuid)'::regprocedure,
                'public.start_pickup(uuid)'::regprocedure,
                'public.complete_pickup(uuid,boolean)'::regprocedure,
                'public.cancel_claim(uuid,uuid)'::regprocedure,
                'public.recover_expired_claims(integer)'::regprocedure,
                'public.submit_claim_reconciliation(uuid,boolean,uuid)'::regprocedure)) s),
            'route_guard_exists',to_regprocedure('routing_private.task_guard()') IS NOT NULL
          );
        """))
        self.assertGreaterEqual(facts['public_constraints'], 150)
        self.assertTrue(facts['authority_trigger'] and facts['authority_trigger']['enabled'])
        self.assertTrue(facts['route_guard_exists'])
        self.assertTrue(facts['key_rls']['pickup_tasks'])
        self.assertEqual(set(facts['signatures'].values()), {'postgres'})
        (OUT / 'full-schema-catalog.json').write_text(json.dumps(facts, indent=2) + '\n', encoding='utf-8')

    def test_claim_contention_2_5_10_with_replay_and_rollback(self):
        global CLAIM_TEST_SEQUENCE
        CLAIM_TEST_SEQUENCE += 1
        run_sequence = CLAIM_TEST_SEQUENCE
        actors = self.add_ngo_actors(10)
        cases = []
        for count in (2, 5, 10):
            fixture = self.create_available_direct_listing(f'B4.1 claim race {count}')
            before = self.listing_snapshot(fixture['listing'])
            requests = {actor: self.req() for actor in actors[:count]}
            barrier = threading.Barrier(count)

            def attempt(actor, actor_index):
                barrier.wait(timeout=10)
                started = datetime.now(timezone.utc).isoformat()
                try:
                    with psycopg.connect(host='127.0.0.1', port=type(self).port,
                                         dbname=type(self).db, user='postgres',
                                         connect_timeout=3,
                                         application_name=f'b41-claim-{count}-{actor_index}') as conn:
                        with conn.cursor() as cur:
                            # Diagnostic-only local session setting. It gives
                            # the test observer time to capture a wait-for graph.
                            cur.execute("SET LOCAL deadlock_timeout='5s'" if DIAGNOSTIC_MODE
                                        else "SET LOCAL deadlock_timeout='1s'")
                            if DIAGNOSTIC_MODE:
                                cur.execute("SELECT set_config('application_name',%s,true)",
                                            (f'b42-claim-{count}-{actor_index}',))
                            cur.execute('SET LOCAL ROLE authenticated')
                            cur.execute("SELECT set_config('request.jwt.claim.sub',%s,true)", (actor,))
                            cur.execute('SELECT public.claim_listing(%s::uuid,%s::uuid)',
                                        (fixture['listing'], requests[actor]))
                            response = cur.fetchone()[0]
                except psycopg.Error as error:
                    response = dict(outcome='SQL_ERROR', sqlstate=error.sqlstate,
                                    message=error.diag.message_primary if error.diag else str(error),
                                    detail=error.diag.message_detail if error.diag else None,
                                    context=error.diag.context if error.diag else None,
                                    constraint=error.diag.constraint_name if error.diag else None,
                                    table=error.diag.table_name if error.diag else None,
                                    schema=error.diag.schema_name if error.diag else None)
                return dict(actor=actor, request_id=requests[actor],
                            started_at=started, response=response,
                            finished_at=datetime.now(timezone.utc).isoformat())

            lock_graphs = []
            with ThreadPoolExecutor(max_workers=count) as pool:
                futures = [pool.submit(attempt, actor, index)
                           for index, actor in enumerate(actors[:count])]
                while not all(future.done() for future in futures):
                    with psycopg.connect(host='127.0.0.1', port=type(self).port,
                                         dbname=type(self).db, user='postgres',
                                         connect_timeout=3) as monitor:
                        with monitor.cursor() as cur:
                            cur.execute("""
                              SELECT coalesce(jsonb_agg(jsonb_build_object(
                                'pid',a.pid,'application_name',a.application_name,
                                'wait_event_type',a.wait_event_type,'wait_event',a.wait_event,
                                'query',a.query,'blocking_pids',pg_blocking_pids(a.pid),
                                'locks',(SELECT coalesce(jsonb_agg(jsonb_build_object(
                                  'locktype',l.locktype,'mode',l.mode,'relation',
                                  CASE WHEN l.relation IS NULL THEN NULL ELSE l.relation::regclass::text END,
                                  'transactionid',l.transactionid,'granted',l.granted)), '[]')
                                  FROM pg_locks l WHERE l.pid=a.pid)
                              ) ORDER BY a.application_name),'[]')
                              FROM pg_stat_activity a
                              WHERE a.datname=current_database()
                                AND a.application_name LIKE 'b%-claim-%'
                                AND a.state<>'idle'
                            """)
                            snapshot = cur.fetchone()[0]
                    if snapshot and any(row['wait_event_type'] == 'Lock' for row in snapshot):
                        lock_graphs.append(dict(observed_at=datetime.now(timezone.utc).isoformat(),
                                                sessions=snapshot))
                    threading.Event().wait(.05)
                outcomes = [future.result() for future in futures]
            winners = [item for item in outcomes if item['response']['outcome'] == 'SUCCESS']
            losers = [item for item in outcomes if item['response']['outcome'] == 'CONFLICT']
            failure_rows = json.loads(self.query(f"""
              SELECT coalesce(jsonb_agg(to_jsonb(f) ORDER BY occurred_at,failure_id),'[]')
              FROM public.operation_failure_events f WHERE listing_id='{fixture['listing']}';
            """))
            precheck = dict(actor_count=count, fixture=fixture, initial_state=before,
                            actor_requests=outcomes, expected=dict(winners=1, conflicts=count-1),
                            observed=dict(winners=len(winners), conflicts=len(losers),
                                          outcome_counts={outcome: sum(
                                              item['response']['outcome'] == outcome
                                              for item in outcomes)
                                              for outcome in sorted({item['response']['outcome']
                                                                     for item in outcomes})},
                                          failure_rows=failure_rows,
                                          state=self.listing_snapshot(fixture['listing']),
                                          lock_graphs=lock_graphs),
                            status='PENDING_ASSERTIONS' if len(winners) == 1
                            and len(losers) == count - 1 else 'FAIL')
            (OUT / f'claim-contention-r{run_sequence}-{count}-attempt.json').write_text(
                json.dumps(precheck, indent=2) + '\n', encoding='utf-8')
            winner = winners[0] if len(winners) == 1 else None
            replay = None
            reused = None
            replay_ok = False
            reuse_ok = False
            if winner is not None:
                replay = self.jrpc(
                    f"public.claim_listing('{fixture['listing']}','{winner['request_id']}')",
                    user=winner['actor'],
                )
                replay_ok = (replay.get('replayed') is True
                             and replay.get('claim_id') == winner['response'].get('claim_id'))
            second = self.create_available_direct_listing(f'B4.1 request reuse {count}')
            if winner is not None:
                reused = self.jrpc(
                    f"public.claim_listing('{second['listing']}','{winner['request_id']}')",
                    user=winner['actor'],
                )
                reuse_ok = (reused.get('outcome') == 'ERROR'
                            and reused.get('rollback_confirmed') is True)

            final = self.listing_snapshot(fixture['listing'])
            counts = json.loads(self.query(f"""
              SELECT jsonb_build_object(
                'active_claims',(SELECT count(*) FROM public.donation_claims WHERE listing_id='{fixture['listing']}' AND claim_status='ACTIVE'),
                'active_leases',(SELECT count(*) FROM public.claim_leases le JOIN public.donation_claims c USING(claim_id) WHERE c.listing_id='{fixture['listing']}' AND le.lease_status='ACTIVE'),
                'tasks',(SELECT count(*) FROM public.pickup_tasks t JOIN public.donation_claims c USING(claim_id) WHERE c.listing_id='{fixture['listing']}'),
                'attempt_audits',(SELECT count(*) FROM public.audit_events WHERE event_type='CLAIM_ATTEMPT' AND entity_id='{fixture['listing']}'),
                'failure_audits',(SELECT count(*) FROM public.operation_failure_events WHERE listing_id IN ('{fixture['listing']}','{second['listing']}') AND operation_name='claim_listing'),
                'claim_requests',(SELECT count(*) FROM public.claim_requests WHERE listing_id='{fixture['listing']}')
              );
            """))
            second_final = self.listing_snapshot(second['listing'])
            failure_audits_ok = (len(failure_rows) == sum(
                item['response'].get('outcome') == 'ERROR' for item in outcomes)
                and all(row.get('details', {}).get('rollback_confirmed') is True
                        for row in failure_rows))
            invariant_ok = ((counts['active_claims'], counts['active_leases'], counts['tasks']) == (1, 1, 1)
                            and counts['attempt_audits'] == sum(
                                item['response'].get('outcome') in ('SUCCESS', 'CONFLICT', 'INELIGIBLE')
                                for item in outcomes)
                            and second_final['claims'] == [] and failure_audits_ok)
            expected_losers_ok = (len(winners) == 1 and len(losers) == count - 1
                                  and all(item['response'].get('outcome') == 'CONFLICT'
                                          for item in outcomes if item is not winner))
            error_items = [item for item in outcomes if item['response'].get('outcome') == 'ERROR']
            error_ids = {item['response'].get('failure_audit_id') for item in error_items}
            error_states = [row.get('details', {}).get('sqlstate') for row in failure_rows
                            if row.get('failure_id') in error_ids]
            if EXPECT_DEADLOCKS and count > 2 and error_items \
                    and len(error_states) == len(error_items) and set(error_states) == {'40P01'} \
                    and len(winners) == 1 and invariant_ok and replay_ok and reuse_ok:
                case_status = 'EXPECTED_DEADLOCK_REPRODUCED'
            else:
                case_status = ('PASS' if expected_losers_ok and invariant_ok
                               and (winner is None or (replay_ok and reuse_ok)) else 'FAIL')
            case = dict(actor_count=count, fixture=fixture, initial_state=before,
                        actor_requests=outcomes, expected=dict(winners=1, conflicts=count-1),
                        actual=dict(winners=len(winners), conflicts=len(losers),
                                    counts=counts, replay=replay, replay_ok=replay_ok,
                                    reused_request=reused, reuse_ok=reuse_ok,
                                    invariant_ok=invariant_ok,
                                    failure_audits_ok=failure_audits_ok,
                                    expected_losers_ok=expected_losers_ok),
                        second_listing_state=second_final, final_state=final, status=case_status)
            cases.append(case)
            (OUT / f'claim-contention-r{run_sequence}-{count}.json').write_text(
                json.dumps(case, indent=2) + '\n', encoding='utf-8')
        expected = (['PASS', 'EXPECTED_DEADLOCK_REPRODUCED', 'EXPECTED_DEADLOCK_REPRODUCED']
                    if EXPECT_DEADLOCKS else ['PASS'] * 3)
        self.assertEqual([case['status'] for case in cases], expected)

    def test_current_reconciliation_serializes_against_pickup_completion(self):
        f = self.prepare()
        self.authorize()
        self.rpc(f"public.start_pickup('{f['claim']}')")
        # Expire only this disposable lease while preserving the 360-minute
        # interval. Current recovery must retain pickup custody for review.
        self.query(f"""
          UPDATE public.claim_leases SET issued_at=clock_timestamp()-interval '7 hours',
            expires_at=clock_timestamp()-interval '1 hour' WHERE claim_id='{f['claim']}';
          SELECT public.recover_expired_claims(100);
        """)
        self.assertEqual(self.query(
            f"SELECT claim_status FROM public.donation_claims WHERE claim_id='{f['claim']}';"
        ), 'RECONCILIATION_REQUIRED')
        first = self.jrpc(
            f"public.submit_claim_reconciliation('{f['claim']}',true,'{self.req()}')",
            user=runtime.source.A,
        )
        self.assertEqual(first['outcome'], 'AWAITING_COUNTERPART')
        request = self.req()
        reconcile = (
            f"BEGIN; SET LOCAL ROLE authenticated; "
            f"SET LOCAL request.jwt.claim.sub='{runtime.DONOR}'; "
            f"SELECT public.submit_claim_reconciliation('{f['claim']}',true,'{request}'); "
            "SELECT pg_sleep(1.2); COMMIT;"
        )
        with self.concurrent(reconcile):
            pass
        before_competing_completion = json.loads(self.query(f"""
          SELECT jsonb_build_object(
            'claim',(SELECT claim_status FROM public.donation_claims WHERE claim_id='{f['claim']}'),
            'lease',(SELECT lease_status FROM public.claim_leases WHERE claim_id='{f['claim']}'),
            'task',(SELECT task_status FROM public.pickup_tasks WHERE task_id='{f['task']}'),
            'donation',(SELECT donation_status FROM public.donations WHERE donation_id='{f['donation']}'),
            'listing',(SELECT listing_status FROM public.listings WHERE listing_id='{f['listing']}'),
            'case',(SELECT case_status FROM public.claim_reconciliation_cases WHERE claim_id='{f['claim']}'),
            'evidence',(SELECT count(*) FROM public.claim_reconciliation_evidence WHERE case_id=(SELECT case_id FROM public.claim_reconciliation_cases WHERE claim_id='{f['claim']}'))
          );
        """))
        try:
            self.rpc(f"public.complete_pickup('{f['claim']}',true)",
                     error='PICKUP_NOT_STARTED')
            completion_result = 'REJECTED_ALREADY_COLLECTED'
        except Exception as error:
            (OUT / 'reconciliation-completion-race-failure.json').write_text(
                json.dumps(dict(claim=f['claim'], first_party_response=first,
                                concurrent_final_party='donor',
                                state_before_competing_completion=before_competing_completion,
                                completion_error=str(error), status='FAIL'), indent=2) + '\n',
                encoding='utf-8')
            raise
        state = json.loads(self.query(f"""
          SELECT jsonb_build_object(
            'claim',(SELECT claim_status FROM public.donation_claims WHERE claim_id='{f['claim']}'),
            'lease',(SELECT lease_status FROM public.claim_leases WHERE claim_id='{f['claim']}'),
            'task',(SELECT task_status FROM public.pickup_tasks WHERE task_id='{f['task']}'),
            'donation',(SELECT donation_status FROM public.donations WHERE donation_id='{f['donation']}'),
            'listing',(SELECT listing_status FROM public.listings WHERE listing_id='{f['listing']}'),
            'case',(SELECT case_status FROM public.claim_reconciliation_cases WHERE claim_id='{f['claim']}'),
            'evidence',(SELECT count(*) FROM public.claim_reconciliation_evidence WHERE case_id=(SELECT case_id FROM public.claim_reconciliation_cases WHERE claim_id='{f['claim']}')),
            'audits',(SELECT coalesce(jsonb_agg(to_jsonb(a) ORDER BY occurred_at,event_id),'[]') FROM public.audit_events a WHERE claim_id='{f['claim']}')
          );
        """))
        self.assertEqual(state['claim'], 'COMPLETED')
        self.assertEqual(state['lease'], 'COMPLETED')
        self.assertEqual(state['task'], 'COLLECTED')
        self.assertEqual(state['donation'], 'COLLECTED')
        self.assertEqual(state['listing'], 'CLOSED')
        self.assertEqual(state['case'], 'RESOLVED_COLLECTED')
        self.assertEqual(state['evidence'], 2)
        (OUT / 'reconciliation-completion-race.json').write_text(
            json.dumps(dict(claim=f['claim'], route_authorized=True,
                            recovery_before_reconciliation=True,
                            competing_completion=completion_result,
                            state_before_competing_completion=before_competing_completion,
                            final_state=state, status='PASS'), indent=2) + '\n',
            encoding='utf-8')

    def test_route_authority_rejects_capacity_window_and_duration_tampering(self):
        f = self.prepare()
        cases = [
            ('capacity', 'CAPACITY_VIOLATION',
             lambda body: body['plan']['routes'][0]['stops'][0].__setitem__('cumulative_load_kg', 101.0)),
            ('time-window', 'ROUTE_SCHEDULE_INVALID',
             lambda body: body['plan']['routes'][0]['stops'][0].__setitem__(
                 'arrival_us', body['plan']['routes'][0]['stops'][0]['arrival_us'] + 1)),
            ('route-duration', 'ROUTE_DURATION_INVALID',
             lambda body: body['plan']['routes'][0].__setitem__('return_us', 15_000_000_000)),
        ]
        results = []
        for name, expected_error, mutate in cases:
            body = copy.deepcopy(f['candidate']['body'])
            mutate(body)
            candidate = self.jrpc(
                f"public.submit_routing_candidate('{self.req()}',"
                f"'{f['bundle']['snapshot']['snapshot_id']}',{self.literal(body)})",
                role='geolock_planner',
            )
            report = dict(f['report'], candidate_digest=candidate['digest'])
            self.rpc(
                f"public.attest_routing_candidate('{candidate['candidate_id']}','{candidate['digest']}',"
                f"{self.literal(report)})",
                role='geolock_validator',
            )
            observed = self.rpc(
                f"public.authorize_my_routing_candidate('{self.req()}','{candidate['candidate_id']}',"
                "clock_timestamp()+interval '1 second')",
                error=expected_error,
            )
            results.append(dict(condition=name, expected=expected_error,
                                observed_error=observed, candidate_id=candidate['candidate_id'],
                                status='PASS'))
            self.assertEqual(self.query('SELECT count(*) FROM public.pickup_routes;'), '0')
            self.assertEqual(self.query('SELECT count(*) FROM public.active_task_route_assignments;'), '0')
            self.assertEqual(self.query(
                f"SELECT task_status FROM public.pickup_tasks WHERE task_id='{f['task']}';"
            ), 'CONFIRMED')
        (OUT / 'route-authorization-negative-cases.json').write_text(
            json.dumps(dict(fixture=dict(claim=f['claim'], task=f['task'],
                                         listing=f['listing'], donation=f['donation']),
                            cases=results, status='PASS'), indent=2) + '\n',
            encoding='utf-8')

    def test_pickup_start_wins_then_recovery_reconciles(self):
        f = self.prepare()
        self.authorize()
        initial = self.listing_snapshot(f['listing'])
        start = (f"BEGIN; SET LOCAL ROLE authenticated; "
                 f"SET LOCAL request.jwt.claim.sub='{runtime.source.A}'; "
                 f"SELECT public.start_pickup('{f['claim']}'); "
                 f"SELECT public.b42_expire_own_claim_lease('{f['claim']}'); "
                 "SELECT pg_sleep(2); COMMIT;")
        with self.concurrent(start):
            time.sleep(.55)
            recovery_first_attempt = self.query(
                f"SET lock_timeout='5s'; SET statement_timeout='30s'; "
                f"SELECT public.recover_expired_claims(100);"
            )
        # Recovery deliberately uses SKIP LOCKED on the claim row. The first
        # concurrent scan must skip the pickup transaction; the bounded retry
        # after its commit should reconcile the now-expired started claim.
        recovery_retry = self.query(
            f"SET lock_timeout='5s'; SET statement_timeout='30s'; "
            f"SELECT public.recover_expired_claims(100);"
        )
        final = self.listing_snapshot(f['listing'])
        self.assertEqual(recovery_first_attempt, '0')
        self.assertEqual(recovery_retry, '1')
        self.assertEqual(final['claims'][0]['claim_status'], 'RECONCILIATION_REQUIRED')
        self.assertEqual(final['leases'][0]['lease_status'], 'RECONCILIATION_REQUIRED')
        self.assertEqual(final['tasks'][0]['task_status'], 'DISPATCHED')
        self.assertEqual(final['donation']['donation_status'], 'PICKUP_IN_PROGRESS')
        self.assertEqual(final['listing']['listing_status'], 'CLAIMED')
        (OUT / 'pickup-start-recovery-start-first.json').write_text(
            json.dumps(dict(claim=f['claim'], operation_order=['pickup_start_lock',
                'lease_expires_inside_open_pickup_transaction', 'recovery_wait_then_reconcile'], initial_state=initial,
                expected='custody retained; recovery opens reconciliation',
                actual=dict(recovery_first_attempt=recovery_first_attempt,
                            recovery_retry=recovery_retry, final_state=final),
                status='PASS'), indent=2) + '\n', encoding='utf-8')

    def test_recovery_wins_then_pickup_start_is_rejected(self):
        f = self.prepare()
        self.authorize()
        initial = self.listing_snapshot(f['listing'])
        self.query(f"""
          UPDATE public.claim_leases SET issued_at=clock_timestamp()-interval '7 hours',
            expires_at=clock_timestamp()-interval '1 hour' WHERE claim_id='{f['claim']}';
          CREATE FUNCTION public.b41_slow_reconciliation() RETURNS trigger
            LANGUAGE plpgsql AS $$ BEGIN
              IF NEW.lease_status='RECONCILIATION_REQUIRED' THEN PERFORM pg_sleep(1.5); END IF;
              RETURN NULL;
            END $$;
          CREATE TRIGGER b41_slow_reconciliation AFTER UPDATE ON public.claim_leases
            FOR EACH ROW EXECUTE FUNCTION public.b41_slow_reconciliation();
        """)
        try:
            with self.concurrent('SELECT public.recover_expired_claims(100);'):
                try:
                    self.rpc(f"public.start_pickup('{f['claim']}')")
                    raise AssertionError('Pickup start succeeded after recovery held the claim')
                except RuntimeError as error:
                    start_error = str(error)
                    self.assertTrue(any(code in start_error for code in (
                        'DISPATCH_SOURCE_STALE', 'NOT_ACTIVE_CLAIM_HOLDER',
                        'RESERVED_TASK_REQUIRES_RECONCILIATION', 'STALE_OR_EXPIRED_LEASE',
                    )), start_error)
        finally:
            self.query("DROP TRIGGER IF EXISTS b41_slow_reconciliation ON public.claim_leases; "
                       "DROP FUNCTION IF EXISTS public.b41_slow_reconciliation();")
        final = self.listing_snapshot(f['listing'])
        self.assertEqual(final['claims'][0]['claim_status'], 'RECONCILIATION_REQUIRED')
        self.assertEqual(final['leases'][0]['lease_status'], 'RECONCILIATION_REQUIRED')
        self.assertEqual(final['tasks'][0]['task_status'], 'PLANNED')
        self.assertEqual(final['donation']['donation_status'], 'CLAIMED')
        (OUT / 'pickup-start-recovery-recovery-first.json').write_text(
            json.dumps(dict(claim=f['claim'], operation_order=['expiry',
                'recovery_lock_then_reconciliation', 'pickup_start_wait_then_reject'],
                initial_state=initial, expected='pickup start denied; reservation retained',
                actual=dict(start_error=start_error, final_state=final),
                status='PASS'), indent=2) + '\n', encoding='utf-8')


def load_tests(loader, tests, pattern):
    names = [
        'test_full_package_catalog_security_and_authority',
        'test_claim_contention_2_5_10_with_replay_and_rollback',
        'test_direct_workflow',
        'test_missing_lease_and_expired_authority_fail_closed',
        'test_void_pickup_retry_reads_committed_authority',
        'test_required_audit_failure_rolls_back_permit_and_business_state',
        'test_route_and_candidate_forgery_and_request_reuse',
        'test_recovery_retains_reserved_task_and_cases',
        'test_unrouted_start_and_direct_task_bypass_denied',
        'test_invalid_handover_rolls_back_completion',
        'test_race_cancel_first_denies_start',
        'test_race_start_first_blocks_cancel',
        'test_sql_rechecks_schedule_even_with_forged_trusted_attestation',
        'test_unauthenticated_and_old_assignment_entrypoint_denied',
        'test_current_reconciliation_serializes_against_pickup_completion',
        'test_route_authority_rejects_capacity_window_and_duration_tampering',
        'test_pickup_start_wins_then_recovery_reconciles',
        'test_recovery_wins_then_pickup_start_is_rejected',
    ]
    return unittest.TestSuite(StageB41Tests(name) for name in names)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run-isolated', action='store_true')
    parser.add_argument('--pg-bin', type=Path, required=True)
    parser.add_argument('--output-dir', type=Path, required=True)
    parser.add_argument('--only', choices=('all', 'claims', 'reconciliation', 'route-negative', 'pickup-races'), default='all')
    parser.add_argument('--diagnostic-locks', action='store_true',
                        help='Instrument the disposable claim function for deadlock DETAIL/CONTEXT and install an isolated fixture helper')
    parser.add_argument('--apply-b43', action='store_true')
    parser.add_argument('--expect-deadlocks', action='store_true')
    parser.add_argument('--claim-repetitions', type=int, default=1,
                        help='Repeat the bounded 2/5/10 schedule (1-5)')
    args = parser.parse_args()
    if not args.run_isolated:
        parser.error('--run-isolated required; external connections are unsupported')
    if args.claim_repetitions < 1 or args.claim_repetitions > 5:
        parser.error('--claim-repetitions must be between 1 and 5')
    if args.expect_deadlocks and args.apply_b43:
        parser.error('--apply-b43 and --expect-deadlocks are incompatible')
    if not args.output_dir.resolve().is_relative_to(ROOT.resolve()):
        parser.error('Keep Stage B.4.1 evidence inside the workspace')
    if args.output_dir.exists():
        parser.error('Choose a new, unused evidence directory')
    args.output_dir.mkdir(parents=True)
    OUT = args.output_dir.resolve()
    PG_BIN = args.pg_bin.resolve()
    DIAGNOSTIC_MODE = args.diagnostic_locks
    APPLY_B43 = args.apply_b43
    EXPECT_DEADLOCKS = args.expect_deadlocks
    CLAIM_REPETITIONS = args.claim_repetitions
    suite = unittest.defaultTestLoader.loadTestsFromModule(__import__(__name__))
    if args.only != 'all':
        selected = {
            'claims': 'test_claim_contention_2_5_10_with_replay_and_rollback',
            'reconciliation': 'test_current_reconciliation_serializes_against_pickup_completion',
            'route-negative': 'test_route_authority_rejects_capacity_window_and_duration_tampering',
            'pickup-races': ('test_pickup_start_wins_then_recovery_reconciles',
                             'test_recovery_wins_then_pickup_start_is_rejected'),
        }[args.only]
        if isinstance(selected, str):
            selected = (selected,)
        if args.only == 'claims':
            suite = unittest.TestSuite(StageB41Tests(selected[0])
                                       for _ in range(CLAIM_REPETITIONS))
        else:
            suite = unittest.TestSuite(StageB41Tests(name) for name in selected)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    summary = dict(tests=result.testsRun,
                   failures=[str(test) + error for test, error in result.failures],
                   errors=[str(test) + error for test, error in result.errors],
                   skipped=[str(test) + error for test, error in result.skipped],
                   supabase_connections=0,
                   scope='current Stage B snapshot/lifecycle and reviewed local routing migrations; declared doubles')
    (OUT / 'results.json').write_text(json.dumps(summary, indent=2) + '\n', encoding='utf-8')
    raise SystemExit(0 if result.wasSuccessful() else 1)
