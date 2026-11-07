"""Subprocess-mocked transport tests. No PostgreSQL process or SQL executes."""
import json
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from isolated_psql_sqlfile import SqlFiles, single_transaction
import stage8_reconciliation_compatibility_isolated_test as harness


class SqlFileTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='sqlfile-regression-')
        self.addCleanup(self.tmp.cleanup)
        root=Path(self.tmp.name)
        self.files=SqlFiles(root/'sql-input')
        self.addCleanup(self.files.cleanup)
        self.ctx=SimpleNamespace(folder=root,data=root/'data',port=49151,db='postgres',
            bins=harness.CompatibilityTests.bins,env={},flags=0,sql_files=self.files,
            assertEqual=self.assertEqual,fail=self.fail)
        self.ctx.args=lambda sql:harness.CompatibilityTests.args.__func__(self.ctx,sql)
        self.ctx.run_process=lambda args:harness.CompatibilityTests.run_process.__func__(self.ctx,args)

    def fake_run(self,output='',code=0,inspect=None):
        def run(args,**kwargs):
            self.assertNotIn('-c',args)
            self.assertEqual(kwargs['timeout'],40)
            self.assertIs(kwargs['stdout'],kwargs['stderr'])
            self.assertEqual(kwargs['env']['PGCLIENTENCODING'],'UTF8')
            if inspect:inspect(args)
            kwargs['stdout'].write(output)
            return SimpleNamespace(returncode=code)
        return run

    def query(self,sql,error=None):
        return harness.CompatibilityTests.query.__func__(self.ctx,sql,error)

    def assert_clean(self):
        self.assertEqual(self.files.owned,{})
        self.assertEqual(list(self.files.root.iterdir()),[])

    def test_sql_larger_than_windows_command_limit(self):
        sql='BEGIN;\n-- '+('Unicode é Ω 路 '+('x'*200)+'\n-- ')*600+'\nSELECT 1;\nCOMMIT;'
        self.assertGreater(len(sql),32767)
        def inspect(args):
            self.assertLess(len(subprocess.list2cmdline(args)),1000)
            self.assertEqual(self.files.path(args).read_bytes(),sql.encode('utf-8'))
            self.assertNotIn('--single-transaction',args)
        with patch('subprocess.run',side_effect=self.fake_run('1\n',inspect=inspect)):
            self.assertEqual(self.query(sql),'1')
        self.assert_clean()

    def test_actual_combined_proposal_uses_unchanged_file_input(self):
        sql=(harness.HERE/'003_with_reconciliation_proposal.sql').read_text()
        def inspect(args):self.assertEqual(self.files.path(args).read_text(encoding='utf-8'),sql)
        with patch('subprocess.run',side_effect=self.fake_run(inspect=inspect)):
            self.query(sql)
        self.assert_clean()

    def test_unwrapped_batch_keeps_implicit_atomicity(self):
        with patch('subprocess.run',side_effect=self.fake_run(inspect=lambda args:self.assertIn('--single-transaction',args))):
            self.query('CREATE TABLE a(id integer); INSERT INTO a VALUES(1);')
        self.assert_clean()

    def test_database_creation_is_not_wrapped(self):
        for verb in ('CREATE','DROP'):
            with patch('subprocess.run',side_effect=self.fake_run(inspect=lambda args:self.assertNotIn('--single-transaction',args))):
                self.query(verb+' DATABASE routing_test_123;')
        self.assert_clean()

    def test_do_body_begin_is_not_transaction_control(self):
        self.assertTrue(single_transaction("DO $body$ BEGIN RAISE NOTICE 'x; COMMIT;'; END $body$; SELECT 1;"))
        self.assertFalse(single_transaction("/* BEGIN; */ BEGIN; DO $$BEGIN NULL; END$$; COMMIT;"))
        self.assertFalse(single_transaction("SELECT E'one\\\'two;';"))

    def test_expected_sql_error_keeps_assertion_and_output(self):
        with patch('subprocess.run',side_effect=self.fake_run('ERROR: PROTECTED_COMPLETION_REQUIRED\n',code=1)):
            self.assertIn('PROTECTED_COMPLETION_REQUIRED',self.query('SELECT denied();','PROTECTED_COMPLETION_REQUIRED'))
        self.assert_clean()

    def test_unexpected_sql_error_is_not_swallowed(self):
        with patch('subprocess.run',side_effect=self.fake_run('ERROR: unexpected SQL error\n',code=1)):
            with self.assertRaisesRegex(RuntimeError,'unexpected SQL error'):self.query('SELECT broken();')
        self.assert_clean()

    def test_expected_error_but_success_still_fails(self):
        with patch('subprocess.run',side_effect=self.fake_run()):
            with self.assertRaisesRegex(AssertionError,'Expected'):self.query('SELECT 1;','must fail')
        self.assert_clean()

    def test_timeout_cleans_file_and_propagates(self):
        with patch('subprocess.run',side_effect=subprocess.TimeoutExpired('psql',40)):
            with self.assertRaises(subprocess.TimeoutExpired):self.query('SELECT slow();')
        self.assert_clean()

    def test_process_start_failure_cleans_file(self):
        with patch('subprocess.run',side_effect=FileNotFoundError(206,'Simulated process launch failure')):
            with self.assertRaises(FileNotFoundError):self.query('SELECT 1;')
        self.assert_clean()

    def test_external_connections_still_rejected(self):
        for flag,value in [('-h','db.rcgyuwiidqvrgbxswhqj.supabase.co'),
                           ('-h','db.mffccmlimmbrgasgfnnq.supabase.co'),
                           ('-p','5432'),('-d','postgresql://remote/database')]:
            args=self.ctx.args('SELECT 1;');args[args.index(flag)+1]=value
            with patch('subprocess.run') as launch:
                with self.assertRaises(RuntimeError):self.ctx.run_process(args)
                launch.assert_not_called()
            self.assert_clean()

    def test_unowned_file_rejected_and_never_deleted(self):
        other=Path(self.tmp.name)/'keep.sql';other.write_text('SELECT 1;')
        args=self.ctx.args('SELECT 1;');owned=list(args)
        args[args.index('-f')+1]=str(other)
        with patch('subprocess.run') as launch:
            with self.assertRaises(ValueError):self.ctx.run_process(args)
            launch.assert_not_called()
        self.assertTrue(other.exists())
        self.files.remove(owned);self.assert_clean()

    def test_psql_reconnect_meta_command_is_rejected(self):
        with self.assertRaisesRegex(ValueError,'META_COMMANDS_FORBIDDEN'):
            self.ctx.args('\\connect forbidden\nSELECT 1;')
        self.assert_clean()

    def test_concurrent_command_file_survives_until_process_finishes(self):
        self.ctx.query=lambda sql:'t'
        seen=[]
        def spawn(args,**kwargs):
            seen.append(self.files.path(args))
            return SimpleNamespace(returncode=0,wait=lambda timeout:None,kill=lambda:None)
        with patch('subprocess.Popen',side_effect=spawn):
            with harness.CompatibilityTests.concurrent(self.ctx,'BEGIN; SELECT 1; SELECT pg_sleep(1); COMMIT;'):
                self.assertTrue(seen[0].exists())
        self.assert_clean()

    def test_concurrent_start_failure_cleans_file(self):
        with patch('subprocess.Popen',side_effect=FileNotFoundError('fake failure')):
            with self.assertRaises(FileNotFoundError):
                with harness.CompatibilityTests.concurrent(self.ctx,'BEGIN; SELECT 1; COMMIT;'):pass
        self.assert_clean()


if __name__=='__main__':unittest.main(verbosity=2)
