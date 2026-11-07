"""Disposable synthetic journals only. No DEV data, credentials or RPC clients."""
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
from tempfile import TemporaryDirectory
import time
import unittest

from ...worker_service.errors import WorkerError
from ...worker_service.journal import Journal
from ...worker_service.orchestrator import RoutingWorker
from ...worker_service.validator import Validator
from ...worker_service.tests.test_worker_flow import FakeDatabase, FakeGraph, SID, OWNER, REQ
from ...worker_service.tests.test_combined_workflow import CombinedSession


def backup_synthetic(source, target):
    """Only called with freshly created test paths; SQLite backup includes WAL."""
    with target.open('xb'):
        pass
    reader=sqlite3.connect(source.resolve().as_uri()+'?mode=ro',uri=True)
    writer=sqlite3.connect(target)
    try:
        reader.backup(writer)
        assert writer.execute('PRAGMA integrity_check').fetchone()==('ok',)
    finally:
        writer.close(); reader.close()


class RecoveryRehearsalTests(unittest.TestCase):
    def test_abrupt_process_exit_releases_lock_and_preserves_committed_steps_then_restore(self):
        with TemporaryDirectory() as tmp:
            root=Path(tmp);state=root/'synthetic-state';ready=root/'ready.json'
            code='''
import json,sys
from pathlib import Path
from backend.routing.worker_service.journal import Journal
state,ready,sid,owner,request=sys.argv[1:]
j=Journal(state)
with j.claim(sid,owner,request):
    j.save(sid,'prepared',{'scope':'SYNTHETIC-OFFLINE','request_id':request})
    with j._db() as reader:
        reader.execute('BEGIN');reader.execute('SELECT * FROM jobs').fetchall()
        Path(ready).write_text(json.dumps({'ready':True}))
        sys.stdin.readline()
'''
            env={k:v for k,v in os.environ.items() if not k.startswith(('GEOLOCK_','PG'))}
            process=subprocess.Popen([sys.executable,'-B','-c',code,str(state),str(ready),SID,OWNER,REQ],
                                     stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env)
            try:
                deadline=time.monotonic()+10
                while not ready.exists() and process.poll() is None and time.monotonic()<deadline:
                    time.sleep(.02)
                self.assertTrue(ready.exists(),'synthetic child failed to reach committed checkpoint')
                journal=Journal(state)
                with self.assertRaises(WorkerError) as conflict:
                    with journal.claim(SID,OWNER,REQ):pass
                self.assertEqual(conflict.exception.code,'JOB_IN_PROGRESS_RETRY_SAME_REQUEST')
                process.kill(); process.communicate(timeout=10)  # Skip child finally/unlock.
                try:
                    journal=Journal(state)  # Fresh bootstrap opens/recover-checks WAL.
                except sqlite3.OperationalError as error:
                    print(json.dumps(dict(synthetic_crash_reopen='FAIL',sqlite_version=sqlite3.sqlite_version,
                        sqlite_errorcode=getattr(error,'sqlite_errorcode',None),
                        sqlite_errorname=getattr(error,'sqlite_errorname',None))),flush=True)
                    raise
                with journal.claim(SID,OWNER,REQ):
                    self.assertEqual(journal.get(SID,'prepared')['request_id'],REQ)
                backup=root/'synthetic-backup.sqlite3'
                backup_synthetic(journal.path,backup)
                restore=root/'isolated-restore';restore.mkdir()
                shutil.copyfile(backup,restore/'jobs.sqlite3')
                recovered=Journal(restore)
                with recovered.claim(SID,OWNER,REQ):
                    self.assertEqual(recovered.get(SID,'prepared'),journal.get(SID,'prepared'))
            finally:
                if process.poll() is None:process.kill()
                process.communicate(timeout=10)

    def test_restored_bindings_and_append_only_payload_reject_changes(self):
        with TemporaryDirectory() as tmp:
            root=Path(tmp);original=Journal(root/'original')
            with original.claim(SID,OWNER,REQ):original.save(SID,'prepared',{'immutable':'SYNTHETIC'})
            restore=root/'restore';restore.mkdir();backup_synthetic(original.path,restore/'jobs.sqlite3')
            journal=Journal(restore)
            for owner,request in [(SID,REQ),(OWNER,SID)]:
                with self.assertRaises(WorkerError) as rejected:
                    with journal.claim(SID,owner,request):pass
                self.assertEqual(rejected.exception.code,'REQUEST_CONFLICT')
            with self.assertRaises(WorkerError) as rejected:
                journal.save(SID,'prepared',{'immutable':'changed'})
            self.assertEqual(rejected.exception.code,'JOB_PAYLOAD_CONFLICT_REPLAN')
            self.assertEqual(journal.get(SID,'prepared'),{'immutable':'SYNTHETIC'})

    def test_backup_refuses_overwrite_and_corrupt_restore_is_rejected(self):
        with TemporaryDirectory() as tmp:
            root=Path(tmp);journal=Journal(root/'original');backup=root/'backup.sqlite3'
            backup_synthetic(journal.path,backup)
            with self.assertRaises(FileExistsError):backup_synthetic(journal.path,backup)
            bad=root/'corrupt';bad.mkdir();(bad/'jobs.sqlite3').write_bytes(b'NOT-A-SQLITE-BACKUP')
            with self.assertRaises(sqlite3.DatabaseError):Journal(bad)

    def test_restored_journal_and_original_uuid_recover_without_second_authorization(self):
        self._receipt_restore(stale=False)

    def test_older_journal_cannot_undo_committed_mock_database_receipt(self):
        self._receipt_restore(stale=True)

    def _receipt_restore(self,stale):
        with TemporaryDirectory() as tmp:
            root=Path(tmp);journal=Journal(root/'original');db=FakeDatabase();session=CombinedSession(db)
            backup=root/'backup.sqlite3'
            if stale:backup_synthetic(journal.path,backup)
            worker=RoutingWorker(db,FakeGraph(db),Validator(db),journal)
            first=worker.plan_and_authorize(session,SID,REQ)
            if not stale:backup_synthetic(journal.path,backup)
            before=list(db.calls);restore=root/'restore';restore.mkdir();shutil.copyfile(backup,restore/'jobs.sqlite3')
            recovered=RoutingWorker(db,FakeGraph(db),Validator(db),Journal(restore),
                                    solve=lambda _:self.fail('restore must recover receipt, not solve again'))
            result=recovered.plan_and_authorize(session,SID,REQ)
            self.assertEqual(result['authorization'],first['authorization'])
            self.assertEqual(session.auth_calls,1)
            self.assertEqual(db.calls,before+['read_pending_routing_snapshot'])
