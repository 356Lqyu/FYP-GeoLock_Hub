"""Exact-error bounded initialization retry, no live data or DB connections."""
from contextlib import contextmanager
import mmap
from pathlib import Path
import sqlite3
import sys
from tempfile import TemporaryDirectory
from threading import Timer
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from ...worker_service.journal import Journal

MODULE='backend.routing.worker_service.journal'


def truncate_error(code=1546):
    error=sqlite3.OperationalError('synthetic error')
    error.sqlite_errorcode=code
    return error


class JournalInitializationTests(unittest.TestCase):
    def test_windows_exact_transient_initialization_error_retries_without_changing_steps(self):
        with TemporaryDirectory() as tmp:
            journal=Journal(tmp);sid='00000000-0000-0000-0000-000000000001'
            journal.save(sid,'immutable',{'synthetic':True})
            real=journal._db; attempts=[]
            @contextmanager
            def connect():
                attempts.append(1)
                if len(attempts)<3:raise truncate_error()
                with real() as db:yield db
            with patch(MODULE+'.sys',SimpleNamespace(platform='win32')),patch.object(journal,'_db',connect),patch(MODULE+'.time.sleep'):
                journal._initialize()
            self.assertEqual(len(attempts),3)
            self.assertEqual(journal.get(sid,'immutable'),{'synthetic':True})

    def test_nonwindows_truncate_and_other_windows_errors_are_not_retried(self):
        with TemporaryDirectory() as tmp:
            journal=Journal(tmp)
            for platform,code in [('linux',1546),('win32',sqlite3.SQLITE_BUSY),('win32',sqlite3.SQLITE_IOERR)]:
                with self.subTest(platform=platform,code=code),patch(MODULE+'.sys',SimpleNamespace(platform=platform)), \
                        patch.object(journal,'_db',side_effect=truncate_error(code)) as connect,patch(MODULE+'.time.sleep') as sleep:
                    with self.assertRaises(sqlite3.OperationalError):journal._initialize()
                    self.assertEqual(connect.call_count,1);sleep.assert_not_called()

    def test_persistent_windows_error_stops_at_deadline_and_leaves_evidence(self):
        with TemporaryDirectory() as tmp:
            journal=Journal(tmp);before=journal.path.read_bytes()
            with patch(MODULE+'.sys',SimpleNamespace(platform='win32')), \
                    patch.object(journal,'_db',side_effect=truncate_error()) as connect, \
                    patch(MODULE+'.time',SimpleNamespace(monotonic=iter([0,4]).__next__,sleep=lambda _:self.fail('expired deadline'))):
                with self.assertRaises(sqlite3.OperationalError):journal._initialize()
            self.assertEqual(connect.call_count,1);self.assertEqual(journal.path.read_bytes(),before)

    @unittest.skipUnless(sys.platform=='win32','Windows mapped-view VFS regression')
    def test_actual_mapped_shm_release_recovers_preserving_payload(self):
        with TemporaryDirectory() as tmp:
            journal=Journal(tmp);sid='00000000-0000-0000-0000-000000000001'
            journal.save(sid,'immutable',{'synthetic':True})
            shm=Path(str(journal.path)+'-shm');shm.write_bytes(b'\0'*32768)
            handle=shm.open('r+b');mapped=mmap.mmap(handle.fileno(),0,access=mmap.ACCESS_WRITE)
            def release():mapped.close();handle.close()
            timer=Timer(.2,release);timer.start()
            try:
                recovered=Journal(tmp)
                self.assertEqual(recovered.get(sid,'immutable'),{'synthetic':True})
            finally:
                timer.join()
                if not mapped.closed:mapped.close()
                if not handle.closed:handle.close()
