"""Opt-in PostgreSQL tests using ONLY a newly initialized temporary local cluster.

Run directly with --run-isolated. No Supabase URLs, passwords, existing clusters
or PG* connection settings are accepted. Requires initdb, pg_ctl and psql.
Real PostgreSQL compiles/runs v2 and its ACLs. cron.job/schedule/alter_job and
the legacy card reader are explicit test doubles; pg_cron and the production
recovery state machine are NOT integrated or validated by these tests.
"""
from pathlib import Path
import argparse
import json
import os
import shutil
import socket
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SQL = (ROOT / 'supabase/migrations/20261028_claim_card_expiry_and_paused_recovery.sql').read_text(encoding='utf-8')
RPC_SQL = SQL[SQL.index('create function public.get_my_claim_cards_v2()'):SQL.index('-- cron.schedule')]
CRON_SQL = 'do $recovery_cron$' + SQL.split('do $recovery_cron$')[1].split('$recovery_cron$;')[0] + '$recovery_cron$;'
OWNER = '11111111-1111-1111-1111-111111111111'
FOREIGN = '22222222-2222-2222-2222-222222222222'
NAME = 'geolock-expired-claim-recovery'


class IsolatedClaimCardTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix='geolock-claim-expiry-isolated-')
        cls.folder = Path(cls.tmp.name)
        cls.data = cls.folder / 'data'
        cls.env = {k: v for k, v in os.environ.items() if not k.upper().startswith('PG')}
        cls.env.update(PGCONNECT_TIMEOUT='3', PGPASSFILE=str(cls.folder / 'no-password-file'))
        cls.flags = subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0
        cls.addClassCleanup(cls.cleanup_cluster)
        cls.run_process([cls.bins['initdb'], '-D', str(cls.data), '-U', 'postgres',
                         '-A', 'trust', '--no-locale', '--encoding=UTF8'])
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            cls.port = sock.getsockname()[1]
        cls.run_process([cls.bins['pg_ctl'], '-D', str(cls.data), '-l', str(cls.folder / 'server.log'),
                         '-w', '-t', '20', '-o', f'-h 127.0.0.1 -p {cls.port}', 'start'])
        # Minimal explicit doubles for the already-deployed dependencies.
        cls.query(f"""
          create role anon; create role authenticated; create role service_role;
          create schema auth;
          create function auth.uid() returns uuid language sql stable as
            $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
          create table public.ngo_profiles(user_id uuid primary key, active_flag boolean);
          insert into public.ngo_profiles values ('{OWNER}',true),('{FOREIGN}',true);
          create table public.fixture_cards(owner_id uuid, claim_id uuid, claim_status text,
            lease_status text, task_status text, deadline text);
          insert into public.fixture_cards values
            ('{OWNER}','00000000-0000-0000-0000-000000000001','ACTIVE','ACTIVE','CONFIRMED','past'),
            ('{OWNER}','00000000-0000-0000-0000-000000000002','ACTIVE','ACTIVE','CONFIRMED','equal'),
            ('{OWNER}','00000000-0000-0000-0000-000000000003','ACTIVE','ACTIVE','CONFIRMED','future'),
            ('{OWNER}','00000000-0000-0000-0000-000000000004','ACTIVE',null,'CONFIRMED',null),
            ('{OWNER}','00000000-0000-0000-0000-000000000005','RELEASED','RELEASED','STALE','past'),
            ('{OWNER}','00000000-0000-0000-0000-000000000006','RECONCILIATION_REQUIRED','RECONCILIATION_REQUIRED','DISPATCHED','past'),
            ('{FOREIGN}','00000000-0000-0000-0000-000000000007','ACTIVE','ACTIVE','CONFIRMED','past');
          create function public.get_my_claim_cards() returns table(
            claim_id uuid,listing_id uuid,claim_status text,claimed_at timestamptz,
            lease_id uuid,lease_status text,lease_expires_at timestamptz,task_status text,
            source_type text,listing_weight_kg numeric,title text,primary_image_path text)
          language sql security definer set search_path to pg_catalog,public,pg_temp as $$
            select f.claim_id,f.claim_id,f.claim_status,statement_timestamp(),f.claim_id,f.lease_status,
              case f.deadline when 'past' then statement_timestamp()-interval '1 second'
                when 'equal' then statement_timestamp()
                when 'future' then statement_timestamp()+interval '1 hour' end,
              f.task_status,'DIRECT_DONATION'::text,10::numeric,'Fixture'::text,null::text
            from public.fixture_cards f where f.owner_id=auth.uid()
          $$;
          create function public.recover_expired_claims(integer default 100) returns integer
            language plpgsql as $$ begin raise exception 'RECOVERY_MUST_NOT_RUN'; end $$;
          create schema cron;
          create table cron.job(jobid bigint generated always as identity,
            jobname text,schedule text,command text,username text,database text,active boolean);
          create function cron.schedule(text,text,text) returns bigint language sql as $$
            insert into cron.job(jobname,schedule,command,username,database,active)
              values($1,$2,$3,current_user,current_database(),true) returning jobid
          $$;
          create function cron.alter_job(job_id bigint, active boolean) returns void language sql as $$
            update cron.job j set active=$2 where j.jobid=$1
          $$;
        """)
        cls.query(RPC_SQL)

    @classmethod
    def run_process(cls, args, **kwargs):
        # pg_ctl's server descendants can inherit Windows pipe handles and
        # keep communicate() waiting after pg_ctl exits. Files avoid that.
        with tempfile.TemporaryFile(mode='w+', encoding='utf-8') as output:
            result = subprocess.run(args, env=cls.env, creationflags=cls.flags,
                                    stdout=output, stderr=output, text=True, timeout=40, **kwargs)
            output.seek(0)
            text = output.read()
        if result.returncode:
            raise RuntimeError(text)
        return text.strip()

    @classmethod
    def query(cls, sql, expect_error=None):
        args = [cls.bins['psql'], '-X', '--no-password', '-h', '127.0.0.1', '-p', str(cls.port),
                '-U', 'postgres', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1', '-Atq', '-c', sql]
        try:
            result = cls.run_process(args)
        except RuntimeError as exc:
            if expect_error and expect_error in str(exc):
                return str(exc)
            raise
        if expect_error:
            raise AssertionError(f'Expected {expect_error}, got success')
        return result

    @classmethod
    def cleanup_cluster(cls):
        # Also stop a server that started before pg_ctl reported a timeout.
        if (cls.data / 'postmaster.pid').is_file():
            cls.run_process([cls.bins['pg_ctl'], '-D', str(cls.data), '-m', 'immediate', '-w', 'stop'])
        cls.tmp.cleanup()

    def setUp(self):
        self.query('truncate cron.job;')

    def cards(self, user=OWNER):
        result = self.query(f"""begin; set local role authenticated;
          set local request.jwt.claim.sub='{user}';
          select coalesce(json_agg(c order by claim_id),'[]'::json) from public.get_my_claim_cards_v2() c;
          rollback;""")
        return json.loads(result)

    def test_expiry_boundary_null_and_historical_statuses(self):
        cards = self.cards()
        self.assertEqual(len(cards), 6)
        self.assertEqual([c['lease_is_expired'] for c in cards], [True, True, False, None, True, True])
        self.assertEqual([c['lease_recovery_pending'] for c in cards], [True, True, False, False, False, False])
        self.assertEqual(len({c['server_now'] for c in cards}), 1)
        self.assertEqual(cards[1]['lease_expires_at'], cards[1]['server_now'])
        self.assertEqual(cards[4]['claim_status'], 'RELEASED')
        self.assertEqual(cards[5]['claim_status'], 'RECONCILIATION_REQUIRED')

    def test_original_card_projection_is_unchanged(self):
        result = self.query(f"""begin; set local request.jwt.claim.sub='{OWNER}';
          select count(*) from (
            (select to_jsonb(v)-'server_now'-'lease_is_expired'-'lease_recovery_pending'
              from public.get_my_claim_cards_v2() v)
            except all (select to_jsonb(v) from public.get_my_claim_cards() v)
          ) differences; rollback;""")
        self.assertEqual(result, '0')

    def test_rpc_runs_in_read_only_transaction(self):
        self.query(f"""begin read only; set local role authenticated;
          set local request.jwt.claim.sub='{OWNER}';
          select count(*) from public.get_my_claim_cards_v2(); rollback;""")

    def test_ownership_and_authorization(self):
        self.assertEqual(len(self.cards(FOREIGN)), 1)
        self.query("set role authenticated; select * from public.get_my_claim_cards_v2();",
                   expect_error='ACTIVE_NGO_ONLY')
        self.query(f"set request.jwt.claim.sub='{OWNER}'; set role anon; select * from public.get_my_claim_cards_v2();",
                   expect_error='permission denied')
        self.query(f"update ngo_profiles set active_flag=false where user_id='{OWNER}';")
        try:
            self.query(f"set role authenticated; set request.jwt.claim.sub='{OWNER}'; select * from public.get_my_claim_cards_v2();",
                       expect_error='ACTIVE_NGO_ONLY')
        finally:
            self.query(f"update ngo_profiles set active_flag=true where user_id='{OWNER}';")

    def test_rpc_security_metadata_and_grants(self):
        result = self.query("""select json_build_object('owner',pg_get_userbyid(proowner),
          'definer',prosecdef,'stable',provolatile='s','config',proconfig,
          'anon',has_function_privilege('anon',oid,'execute'),
          'authenticated',has_function_privilege('authenticated',oid,'execute'),
          'service',has_function_privilege('service_role',oid,'execute'))
          from pg_proc where oid='public.get_my_claim_cards_v2()'::regprocedure;""")
        data = json.loads(result)
        self.assertEqual(data, dict(owner='postgres',definer=True,stable=True,
                                   config=['search_path=pg_catalog, public, pg_temp'],
                                   anon=False,authenticated=True,service=True))

    def test_cron_block_creates_one_paused_job_and_reuses_it(self):
        self.query(CRON_SQL)
        self.query(CRON_SQL)
        self.assertEqual(self.query('select count(*) from cron.job where not active;'), '1')
        self.assertEqual(self.query('select count(*) from cron.job where active;'), '0')

    def test_cron_rejects_active_or_mismatched_existing_job(self):
        self.query(CRON_SQL)
        self.query('update cron.job set active=true;')
        self.query(CRON_SQL, expect_error='EXISTING_CLAIM_RECOVERY_JOB_MISMATCH')
        self.query("update cron.job set active=false,username='authenticated';")
        self.query(CRON_SQL, expect_error='EXISTING_CLAIM_RECOVERY_JOB_MISMATCH')

    def test_cron_rejects_duplicate_or_alternate_named_jobs(self):
        self.query(CRON_SQL)
        self.query('insert into cron.job(jobname,schedule,command,username,database,active) select jobname,schedule,command,username,database,active from cron.job;')
        self.query(CRON_SQL, expect_error='DUPLICATE_CLAIM_RECOVERY_JOBS')
        self.query("truncate cron.job; select cron.schedule('other','* * * * *','select public.recover_expired_claims(100);');")
        self.query(CRON_SQL, expect_error='OTHER_CLAIM_RECOVERY_JOB_REVIEW_REQUIRED')

    def test_failed_cron_check_rolls_back_new_rpc(self):
        # A separate transaction must roll back the DDL when a later DO fails.
        self.query("select cron.schedule('other','* * * * *','select public.recover_expired_claims(100);');")
        probe_rpc = RPC_SQL.replace('get_my_claim_cards_v2', 'get_my_claim_cards_v2_probe')
        self.query('begin; ' + probe_rpc + CRON_SQL + ' commit;',
                   expect_error='OTHER_CLAIM_RECOVERY_JOB_REVIEW_REQUIRED')
        self.assertEqual(self.query("select to_regprocedure('public.get_my_claim_cards_v2_probe()') is null;"), 't')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run-isolated', action='store_true')
    parser.add_argument('--pg-bin', type=Path)
    args = parser.parse_args()
    if not args.run_isolated:
        parser.error('--run-isolated is required; no external database is supported')
    binaries = {name: str(args.pg_bin / (name + ('.exe' if os.name == 'nt' else '')))
                if args.pg_bin else shutil.which(name) for name in ('initdb', 'pg_ctl', 'psql')}
    if any(not value or not Path(value).is_file() for value in binaries.values()):
        parser.error('initdb, pg_ctl and psql binaries are required')
    IsolatedClaimCardTests.bins = binaries
    unittest.main(argv=[__file__], verbosity=2)
