"""Opt-in actual recovery tests in a NEW disposable loopback PostgreSQL cluster.

No target URL/DSN is accepted. No DEV connection or Supabase access is possible.
Runs the complete new migration, actual recovery, actual lifecycle lock/transition
helpers and actual donation validator/transition triggers. See review document
for reduced-schema/auth stubs and omitted production integration dependencies.
"""
from contextlib import contextmanager
from pathlib import Path
import argparse
import json
import os
import re
import shutil
import socket
import subprocess
import tempfile
import time
import unittest
import uuid

import claim_card_expiry_isolated_test as local_runtime

ROOT = Path(__file__).resolve().parents[2]
BASE = (ROOT / 'supabase/migrations/20261027_persisted_donation_lifecycle.sql').read_text(encoding='utf-8')
PATCH = (ROOT / 'supabase/migrations/20261029_fix_claim_recovery_listing_expiration_race.sql').read_text(encoding='utf-8')
SCHEMA = (ROOT / 'supabase/tests/fixtures/claim_recovery_expiration_isolated_schema.sql').read_text(encoding='utf-8')


def routine(name):
    pattern = r'CREATE(?: OR REPLACE)? FUNCTION public\.' + name + r'\(.*?\bAS\s+(\$\w*\$).*?\1;'
    found = re.search(pattern, BASE, re.S | re.I)
    if found is None and name == 'enforce_listing_transition':
        # Unchanged predecessor, confirmed against deployed pg_get_functiondef.
        source = (ROOT / 'geolock-v3-public-schema.sql').read_text(encoding='utf-8')
        found = re.search(pattern, source, re.S | re.I)
    if found is None:
        raise AssertionError(f'Missing actual fixture dependency: {name}')
    return found.group(0)


def ident(n, offset):
    return str(uuid.UUID(int=n * 100 + offset))


class RecoveryExpirationTests(unittest.TestCase):
    # Reuse only process/connection/cleanup helpers, never the earlier fixtures.
    run_process = local_runtime.IsolatedClaimCardTests.__dict__['run_process']
    query = local_runtime.IsolatedClaimCardTests.__dict__['query']
    cleanup_cluster = local_runtime.IsolatedClaimCardTests.__dict__['cleanup_cluster']

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix='geolock-recovery-expiry-isolated-')
        cls.folder = Path(cls.tmp.name)
        cls.data = cls.folder / 'data'
        cls.env = {k: v for k, v in os.environ.items() if not k.upper().startswith('PG')}
        cls.env.update(PGCONNECT_TIMEOUT='3', PGPASSFILE=str(cls.folder / 'no-password-file'))
        cls.flags = subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0
        cls.addClassCleanup(cls.cleanup_cluster)
        cls.run_process([cls.bins['initdb'], '-D', str(cls.data), '-U', 'postgres', '-A', 'trust', '--no-locale', '--encoding=UTF8'])
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            cls.port = sock.getsockname()[1]
        cls.run_process([cls.bins['pg_ctl'], '-D', str(cls.data), '-l', str(cls.folder / 'server.log'),
                         '-w', '-t', '20', '-o', f'-h 127.0.0.1 -p {cls.port}', 'start'])
        cls.query(SCHEMA)
        cls.query('\n'.join(routine(n) for n in (
            'geolock_lock_listing_donations', 'geolock_transition_listing_donations',
            'geolock_assert_donation_lifecycle', 'geolock_validate_donation_at_commit',
            'enforce_donation_transition', 'enforce_listing_transition')))
        cls.query("""
          create trigger trg_donation_transition before update on public.donations
            for each row execute function public.enforce_donation_transition();
          create trigger trg_listing_transition before update on public.listings
            for each row execute function public.enforce_listing_transition();
          create constraint trigger donations_lifecycle_at_commit after insert or update on public.donations
            deferrable initially deferred for each row execute function public.geolock_validate_donation_at_commit();
        """)

    def setUp(self):
        self.query("""
          drop trigger if exists test_slow_release on public.claim_leases;
          drop trigger if exists test_fail_audit on public.audit_events;
          truncate public.audit_events,public.claim_reconciliation_cases,
            public.active_task_route_assignments,public.pickup_route_stops,
            public.pickup_tasks,public.claim_leases,public.donation_claims,
            public.listings,public.hub_batch_members,public.hub_inventory,
            public.hub_batches,public.donations cascade;
        """)
        self.query(routine('recover_expired_claims') + """
          revoke all on function public.recover_expired_claims(integer) from public,anon,authenticated,service_role;
          grant execute on function public.recover_expired_claims(integer) to service_role;
        """)
        # The ENTIRE production patch, including guards and COMMIT, runs locally.
        self.query(PATCH)

    def fixture(self, n=1, hub=False, deadline='NULL', task='CONFIRMED'):
        claim, lease, listing, donation, task_id, batch, hub_id = (ident(n, i) for i in range(1, 8))
        status = 'PICKUP_IN_PROGRESS' if task == 'DISPATCHED' else 'CLAIMED'
        sql = ['begin;']
        donations = [ident(n, 4 + i * 10) for i in range(3 if hub else 1)]
        for did in donations:
            sql.append(f"insert into public.donations(donation_id,collection_path,donation_status,total_weight_kg) values('{did}','{'HUB_COLLECTION' if hub else 'DIRECT_PICKUP'}','{status}',{5 if hub else 20});")
        if hub:
            sql.append(f"insert into public.hub_batches values('{batch}','{hub_id}','PUBLISHED',3);")
            for did in donations:
                sql.append(f"insert into public.hub_batch_members values('{batch}','{did}','ACTIVE');")
                sql.append(f"insert into public.hub_inventory values('{did}','{hub_id}','BATCHED');")
        sql.append(f"""insert into public.listings(listing_id,source_type,donation_id,batch_id,listing_status,listing_expires_at)
          values('{listing}','{'HUB_BATCH' if hub else 'DIRECT_DONATION'}',
            {"NULL" if hub else "'" + donation + "'"},{"'" + batch + "'" if hub else "NULL"},'CLAIMED',{deadline});""")
        sql.append(f"insert into public.donation_claims(claim_id,listing_id,claim_status) values('{claim}','{listing}','ACTIVE');")
        sql.append(f"""insert into public.claim_leases(lease_id,claim_id,lease_status,issued_at,expires_at)
          values('{lease}','{claim}','ACTIVE',clock_timestamp()-interval '2 days'+interval '{n} minutes',
            clock_timestamp()-interval '42 hours'+interval '{n} minutes');""")
        sql.append(f"insert into public.pickup_tasks(task_id,claim_id,listing_id,task_status) values('{task_id}','{claim}','{listing}','{task}');")
        sql.append('commit;')
        self.query('\n'.join(sql))
        return dict(claim=claim, lease=lease, listing=listing, donation=donation,
                    task=task_id, batch=batch, donations=donations)

    def state(self, n=1):
        return json.loads(self.query(f"""select json_build_object(
          'claim',c.claim_status,'lease',le.lease_status,'claim_reason',c.close_reason,
          'lease_reason',le.release_reason,'task',t.task_status,'snapshot',t.route_snapshot,
          'listing',l.listing_status,'version',l.listing_version,
          'donations',(select json_agg(d.donation_status order by d.donation_id) from public.donations d
             where d.donation_id=l.donation_id or exists(select 1 from public.hub_batch_members m
               where m.batch_id=l.batch_id and m.donation_id=d.donation_id and m.membership_status='ACTIVE')),
          'cases',(select count(*) from public.claim_reconciliation_cases rc where rc.claim_id=c.claim_id),
          'audits',(select count(*) from public.audit_events a where a.claim_id=c.claim_id),
          'recovery_audits',(select count(*) from public.audit_events a where a.claim_id=c.claim_id and a.event_type='LEASE_RECOVERY'))
          from public.donation_claims c join public.claim_leases le using(claim_id)
          join public.pickup_tasks t using(claim_id) join public.listings l on l.listing_id=c.listing_id
          where c.claim_id='{ident(n,1)}';"""))

    def recover(self, limit=100, expect_error=None):
        return self.query(f"set lock_timeout='5s'; set statement_timeout='15s'; select public.recover_expired_claims({limit});", expect_error=expect_error)

    @contextmanager
    def locked(self, table, key, value):
        assert (table, key) in {('donations', 'donation_id'), ('hub_batches', 'batch_id'), ('donation_claims', 'claim_id')}
        output = tempfile.TemporaryFile(mode='w+', encoding='utf-8')
        env = dict(self.env, PGAPPNAME='isolated-recovery-locker')
        command = f"begin; select 1 from public.{table} where {key}='{value}' for update; select pg_sleep(2); commit;"
        args = [self.bins['psql'], '-X', '--no-password', '-h', '127.0.0.1', '-p', str(self.port),
                '-U', 'postgres', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1', '-Atq', '-c', command]
        proc = subprocess.Popen(args, env=env, creationflags=self.flags, stdout=output, stderr=output)
        try:
            for _ in range(50):
                if self.query("select exists(select 1 from pg_stat_activity where application_name='isolated-recovery-locker' and wait_event='PgSleep');") == 't':
                    break
                time.sleep(0.02)
            else:
                self.fail('Locker did not acquire the fixture row')
            yield
        finally:
            proc.wait(timeout=10)
            output.seek(0)
            message = output.read()
            output.close()
            self.assertEqual(proc.returncode, 0, message)

    def assert_released(self, n=1, members=1):
        state = self.state(n)
        self.assertEqual((state['claim'], state['lease'], state['task'], state['listing']), ('RELEASED','RELEASED','STALE','AVAILABLE'))
        self.assertEqual(state['donations'], ['AVAILABLE' if members == 1 else 'BATCHED'] * members)
        self.assertEqual(state['claim_reason'], 'EXPIRED_SAFE_RELEASE')
        self.assertEqual(state['lease_reason'], 'EXPIRED_SAFE_RELEASE')
        self.assertEqual((state['cases'], state['recovery_audits'], state['audits']), (0,1,1+members))
        self.assertEqual(state['snapshot'], 'unchanged-fixture-snapshot')

    def assert_reconciliation(self, n=1):
        state = self.state(n)
        self.assertEqual((state['claim'], state['lease'], state['listing']), ('RECONCILIATION_REQUIRED','RECONCILIATION_REQUIRED','CLAIMED'))
        self.assertEqual((state['cases'], state['recovery_audits'], state['audits']), (1,1,1))
        self.assertNotIn('AVAILABLE', state['donations'])
        self.assertNotIn('BATCHED', state['donations'])

    def test_direct_valid_deadline_and_null_deadline_release(self):
        self.fixture(1, deadline="clock_timestamp()+interval '1 hour'")
        self.fixture(2)
        self.assertEqual(self.recover(), '2')
        self.assert_released(1)
        self.assert_released(2)
        self.assertEqual(self.recover(), '0')
        self.assert_released(1)

    def test_expired_listing_before_recovery_requires_reconciliation(self):
        self.fixture(deadline="clock_timestamp()-interval '1 second'")
        self.assertEqual(self.recover(), '1')
        self.assert_reconciliation()
        self.assertEqual(self.recover(), '0')
        self.assert_reconciliation()

    def test_boundary_crossed_while_waiting_for_direct_donation_lock(self):
        f = self.fixture()
        with self.locked('donations', 'donation_id', f['donation']):
            self.query(f"update public.listings set listing_expires_at=clock_timestamp()+interval '200 milliseconds' where listing_id='{f['listing']}';")
            self.assertEqual(self.recover(), '1')
        self.assert_reconciliation()
        self.assertEqual(self.state()['task'], 'CONFIRMED')

    def test_boundary_crossed_while_waiting_for_hub_batch_lock(self):
        f = self.fixture(hub=True)
        with self.locked('hub_batches', 'batch_id', f['batch']):
            self.query(f"update public.listings set listing_expires_at=clock_timestamp()+interval '200 milliseconds' where listing_id='{f['listing']}';")
            self.assertEqual(self.recover(), '1')
        self.assert_reconciliation()

    def test_original_function_reproduces_partial_release_under_same_lock_race(self):
        self.query(routine('recover_expired_claims'))
        f = self.fixture()
        with self.locked('donations', 'donation_id', f['donation']):
            self.query(f"update public.listings set listing_expires_at=clock_timestamp()+interval '200 milliseconds' where listing_id='{f['listing']}';")
            self.assertEqual(self.recover(), '1')
        state = self.state()
        self.assertEqual((state['claim'],state['lease'],state['task']), ('RELEASED','RELEASED','STALE'))
        self.assertEqual((state['listing'],state['donations']), ('CLAIMED',['CLAIMED']))
        self.assertEqual(state['recovery_audits'], 1)

    def test_late_expiration_after_decision_rolls_back_instead_of_skipping_restore(self):
        f = self.fixture()
        self.query("""create or replace function public.test_slow_release() returns trigger language plpgsql as $$
          begin if new.lease_status='RELEASED' then perform pg_sleep(2); end if; return null; end $$;
          create trigger test_slow_release after update on public.claim_leases for each row execute function public.test_slow_release();""")
        before = self.state()
        self.query(f"update public.listings set listing_expires_at=clock_timestamp()+interval '1500 milliseconds' where listing_id='{f['listing']}';")
        self.recover(expect_error='RECOVERY_LISTING_REOPEN_PRECONDITION_CHANGED')
        self.assertEqual(self.state(), before)

    def test_whole_hub_batch_restores_all_members_and_keeps_inventory(self):
        self.fixture(hub=True)
        self.assertEqual(self.recover(), '1')
        self.assert_released(members=3)
        self.assertEqual(self.query("select bool_and(inventory_status='BATCHED') from public.hub_inventory;"), 't')
        self.assertEqual(self.query('select batch_status from public.hub_batches;'), 'PUBLISHED')

    def test_route_assignment_and_route_stop_require_reconciliation(self):
        one, two = self.fixture(1), self.fixture(2)
        self.query(f"insert into public.active_task_route_assignments values('{one['task']}'); insert into public.pickup_route_stops values('{two['task']}');")
        self.assertEqual(self.recover(), '2')
        self.assert_reconciliation(1)
        self.assert_reconciliation(2)

    def test_planned_and_dispatched_pickups_never_reopen(self):
        self.fixture(1, task='PLANNED')
        self.fixture(2, task='DISPATCHED')
        self.assertEqual(self.recover(), '2')
        self.assert_reconciliation(1)
        self.assert_reconciliation(2)
        self.assertEqual(self.state(2)['donations'], ['PICKUP_IN_PROGRESS'])

    def test_uncertain_inventory_and_existing_manual_review_case_are_preserved(self):
        f = self.fixture(hub=True)
        self.query(f"update public.hub_inventory set inventory_status='RECONCILIATION_REQUIRED' where donation_id='{f['donation']}';")
        self.query(f"insert into public.claim_reconciliation_cases(claim_id,listing_id,source_type,case_status) values('{f['claim']}','{f['listing']}','HUB_BATCH','MANUAL_REVIEW');")
        self.assertEqual(self.recover(), '1')
        self.assert_reconciliation()
        self.assertEqual(self.query('select case_status from public.claim_reconciliation_cases;'), 'MANUAL_REVIEW')
        self.assertEqual(self.recover(), '0')

    def test_second_candidate_audit_failure_rolls_back_entire_batch(self):
        self.fixture(1)
        second = self.fixture(2)
        before = (self.state(1), self.state(2))
        self.query(f"""create or replace function public.test_fail_audit() returns trigger language plpgsql as $$
          begin if new.event_type='LEASE_RECOVERY' and new.claim_id='{second['claim']}'::uuid then
            raise exception 'INJECTED_AUDIT_FAILURE'; end if; return new; end $$;
          create trigger test_fail_audit before insert on public.audit_events for each row execute function public.test_fail_audit();""")
        self.recover(expect_error='INJECTED_AUDIT_FAILURE')
        self.assertEqual((self.state(1),self.state(2)), before)
        self.assertEqual(self.query('select count(*) from public.audit_events;'), '0')

    def test_bounded_batch_and_skip_locked_claim(self):
        first = self.fixture(1)
        self.fixture(2)
        with self.locked('donation_claims', 'claim_id', first['claim']):
            self.assertEqual(self.recover(1), '1')
        self.assertEqual(self.state(1)['claim'], 'ACTIVE')
        self.assert_released(2)
        self.assertEqual(self.recover(1), '1')
        self.assert_released(1)

    def test_lock_timeout_on_second_candidate_rolls_back_earlier_release(self):
        self.fixture(1)
        second = self.fixture(2)
        before = (self.state(1), self.state(2))
        with self.locked('donations', 'donation_id', second['donation']):
            self.query("set lock_timeout='100ms'; select public.recover_expired_claims(100);",
                       expect_error='lock timeout')
        self.assertEqual((self.state(1), self.state(2)), before)

    def test_statement_timeout_rolls_back_release_and_audits(self):
        self.fixture()
        before = self.state()
        self.query("""create or replace function public.test_slow_release() returns trigger language plpgsql as $$
          begin if new.lease_status='RELEASED' then perform pg_sleep(2); end if; return null; end $$;
          create trigger test_slow_release after update on public.claim_leases for each row execute function public.test_slow_release();""")
        self.query("set statement_timeout='100ms'; select public.recover_expired_claims(1);",
                   expect_error='statement timeout')
        self.assertEqual(self.state(), before)

    def test_owner_signature_search_path_grants_and_audit_outcomes(self):
        data = json.loads(self.query("""select json_build_object('owner',pg_get_userbyid(proowner),'definer',prosecdef,
          'args',pg_get_function_arguments(oid),'result',pg_get_function_result(oid),'config',proconfig,
          'anon',has_function_privilege('anon',oid,'execute'),'authenticated',has_function_privilege('authenticated',oid,'execute'),
          'service',has_function_privilege('service_role',oid,'execute')) from pg_proc where oid='public.recover_expired_claims(integer)'::regprocedure;"""))
        self.assertEqual(data, dict(owner='postgres',definer=True,args='p_limit integer DEFAULT 100',result='integer',
                                   config=['search_path=pg_catalog, public, extensions, pg_temp'],anon=False,authenticated=False,service=True))
        self.fixture()
        self.recover()
        self.assertEqual(self.query("select bool_and(outcome='SUCCESS') from public.audit_events;"), 't')
        self.assertEqual(self.query("select bool_and(details ? 'donation_id' and details ? 'listing_id' and details ? 'task_id') from public.audit_events where event_type='LEASE_RECOVERY';"), 't')

    def test_source_drift_aborts_migration_without_overwriting_work(self):
        altered = routine('recover_expired_claims').replace('declare\n', '-- isolated drift\ndeclare\n', 1)
        self.query(altered)
        self.query(PATCH, expect_error='RECOVERY_SOURCE_REVIEW_REQUIRED')
        self.assertEqual(self.query("select prosrc like '%isolated drift%' from pg_proc where oid='public.recover_expired_claims(integer)'::regprocedure;"), 't')

    def test_acl_drift_aborts_without_changing_grants(self):
        self.query('grant execute on function public.recover_expired_claims(integer) to authenticated;')
        self.query(PATCH, expect_error='RECOVERY_HEADER_OR_ACL_REVIEW_REQUIRED')
        self.assertEqual(self.query("select has_function_privilege('authenticated','public.recover_expired_claims(integer)','execute');"), 't')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run-isolated', action='store_true')
    parser.add_argument('--pg-bin', type=Path)
    args = parser.parse_args()
    if not args.run_isolated:
        parser.error('--run-isolated is required; no external database connection is supported')
    binaries = {name: str(args.pg_bin / (name + ('.exe' if os.name == 'nt' else '')))
                if args.pg_bin else shutil.which(name) for name in ('initdb', 'pg_ctl', 'psql')}
    if any(not value or not Path(value).is_file() for value in binaries.values()):
        parser.error('initdb, pg_ctl and psql binaries are required')
    RecoveryExpirationTests.bins = binaries
    unittest.main(argv=[__file__], verbosity=2)
