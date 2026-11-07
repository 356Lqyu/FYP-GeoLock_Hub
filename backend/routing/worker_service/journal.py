"""Crash-resumable local payload journal. No credentials/tokens are accepted."""
from contextlib import contextmanager
from pathlib import Path
import os
import sqlite3
import sys
import time

from .errors import WorkerError, check
from .transport import encode, uuid
import json


class Journal:
    def __init__(self, directory):
        self.directory = Path(directory)
        self.directory.mkdir(parents=True, exist_ok=True)
        if os.name != 'nt': self.directory.chmod(0o700)
        self.path = self.directory/'jobs.sqlite3'
        self._initialize()
        if os.name != 'nt': self.path.chmod(0o600)

    def _initialize(self):
        # Windows SQLite VFS can briefly reject -shm truncation after a process
        # exits but before its mapped view is released (SQLite check-in
        # 7c103a0b7d). Retry only this exact error, only during idempotent schema
        # initialization. Never retry business/payload writes or discard WAL.
        deadline = time.monotonic() + 3
        while True:
            try:
                with self._db() as db:
                    db.execute('PRAGMA journal_mode=WAL')
                    db.execute('CREATE TABLE IF NOT EXISTS jobs(snapshot TEXT PRIMARY KEY,owner TEXT NOT NULL,request TEXT NOT NULL)')
                    db.execute('CREATE TABLE IF NOT EXISTS steps(snapshot TEXT NOT NULL,name TEXT NOT NULL,body TEXT NOT NULL,PRIMARY KEY(snapshot,name))')
                return
            except sqlite3.OperationalError as error:
                if (sys.platform != 'win32' or getattr(error, 'sqlite_errorcode', None) != 1546
                        or time.monotonic() >= deadline):
                    raise
                time.sleep(min(.05, max(0, deadline - time.monotonic())))

    @contextmanager
    def _db(self):
        db=sqlite3.connect(self.path, timeout=5)
        try:
            with db: yield db
        finally:
            db.close()

    @contextmanager
    def operation_lock(self, key):
        """Cross-process nonblocking lock; no job or business record is created."""
        key=uuid(key)
        with (self.directory/(key+'.operation.lock')).open('a+b') as handle:
            if handle.tell()==0: handle.write(b'0');handle.flush()
            handle.seek(0)
            try:
                if os.name=='nt':
                    import msvcrt
                    msvcrt.locking(handle.fileno(),msvcrt.LK_NBLCK,1)
                else:
                    import fcntl
                    fcntl.flock(handle,fcntl.LOCK_EX|fcntl.LOCK_NB)
            except OSError:
                raise WorkerError('JOB_IN_PROGRESS_RETRY_SAME_REQUEST',409,True) from None
            try: yield
            finally:
                handle.seek(0)
                if os.name=='nt': msvcrt.locking(handle.fileno(),msvcrt.LK_UNLCK,1)
                else: fcntl.flock(handle,fcntl.LOCK_UN)

    @contextmanager
    def claim(self, snapshot, owner, request):
        snapshot,owner,request = uuid(snapshot),uuid(owner),uuid(request)
        # OS lock survives threads/processes and releases automatically on crash.
        with (self.directory/(snapshot+'.lock')).open('a+b') as handle:
            if handle.tell()==0: handle.write(b'0'); handle.flush()
            handle.seek(0)
            try:
                if os.name=='nt':
                    import msvcrt
                    msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
                else:
                    import fcntl
                    fcntl.flock(handle, fcntl.LOCK_EX|fcntl.LOCK_NB)
            except OSError:
                raise WorkerError('JOB_IN_PROGRESS_RETRY_SAME_REQUEST', 409, True) from None
            try:
                with self._db() as db:
                    db.execute('INSERT OR IGNORE INTO jobs VALUES(?,?,?)',(snapshot,owner,request))
                    check(db.execute('SELECT owner,request FROM jobs WHERE snapshot=?',(snapshot,)).fetchone()==(owner,request),'REQUEST_CONFLICT',409)
                yield
            finally:
                handle.seek(0)
                if os.name=='nt': msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
                else: fcntl.flock(handle, fcntl.LOCK_UN)

    def get(self, snapshot, name):
        with self._db() as db:
            row=db.execute('SELECT body FROM steps WHERE snapshot=? AND name=?',(snapshot,name)).fetchone()
            return None if row is None else json.loads(row[0])

    def read_saved_result(self, snapshot, owner, request):
        """Strictly read-only retrieval; never claim a job or create a step."""
        snapshot,owner,request = uuid(snapshot),uuid(owner),uuid(request)
        db=sqlite3.connect(self.path.resolve().as_uri()+'?mode=ro',uri=True,timeout=5)
        try:
            db.execute('PRAGMA query_only=ON')
            check(db.execute('SELECT owner,request FROM jobs WHERE snapshot=?',(snapshot,)).fetchone()==(owner,request),
                  'SAVED_RESULT_NOT_OWNED',404)
            row=db.execute("SELECT body FROM steps WHERE snapshot=? AND name='result'",(snapshot,)).fetchone()
            check(row is not None,'SAVED_RESULT_NOT_READY',404)
            return json.loads(row[0])
        finally: db.close()

    def save(self, snapshot, name, value):
        body=encode(value)
        check(len(body)<16_000_000,'JOB_ARTIFACT_TOO_LARGE',422)
        with self._db() as db:
            db.execute('INSERT OR IGNORE INTO steps VALUES(?,?,?)',(snapshot,name,body))
            check(db.execute('SELECT body FROM steps WHERE snapshot=? AND name=?',(snapshot,name)).fetchone()==(body,),'JOB_PAYLOAD_CONFLICT_REPLAN',409)
        return json.loads(body)
