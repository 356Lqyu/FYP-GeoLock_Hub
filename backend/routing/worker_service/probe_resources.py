"""Sample only the owned probe child's memory; no remote process inspection."""
import ctypes
from ctypes import wintypes
import subprocess
import time


class ProcessEntry(ctypes.Structure):
    _fields_=[('size',wintypes.DWORD),('usage',wintypes.DWORD),('pid',wintypes.DWORD),
        ('heap',ctypes.c_size_t),('module',wintypes.DWORD),('threads',wintypes.DWORD),
        ('parent',wintypes.DWORD),('priority',wintypes.LONG),('flags',wintypes.DWORD),('exe',wintypes.WCHAR*260)]


def process_parents():
    api=ctypes.WinDLL('kernel32',use_last_error=True)
    api.CreateToolhelp32Snapshot.argtypes=[wintypes.DWORD,wintypes.DWORD]
    api.CreateToolhelp32Snapshot.restype=wintypes.HANDLE
    api.Process32FirstW.argtypes=api.Process32NextW.argtypes=[wintypes.HANDLE,ctypes.POINTER(ProcessEntry)]
    api.CloseHandle.argtypes=[wintypes.HANDLE]
    handle=api.CreateToolhelp32Snapshot(2,0)
    if handle==ctypes.c_void_p(-1).value:raise RuntimeError('PROCESS_TREE_INSPECTION_FAILED')
    result={};entry=ProcessEntry();entry.size=ctypes.sizeof(entry)
    try:
        more=api.Process32FirstW(handle,ctypes.byref(entry))
        while more:
            result[entry.pid]=entry.parent
            more=api.Process32NextW(handle,ctypes.byref(entry))
    finally:api.CloseHandle(handle)
    return result


def is_descendant(pid,root,parents):
    seen=set()
    while pid and pid not in seen:
        if pid==root:return True
        seen.add(pid);pid=parents.get(pid,0)
    return False


class OwnedWorker:
    def __init__(self,pid,root):
        if not is_descendant(pid,root,process_parents()):raise RuntimeError('UNOWNED_WORKER_PID_REJECTED')
        self.pid=pid
        self._api=ctypes.WinDLL('kernel32',use_last_error=True)
        self._api.OpenProcess.argtypes=[wintypes.DWORD,wintypes.BOOL,wintypes.DWORD]
        self._api.OpenProcess.restype=wintypes.HANDLE
        self._api.CloseHandle.argtypes=[wintypes.HANDLE]
        self._handle=self._api.OpenProcess(0x0400|0x0010,False,pid)
        if not self._handle:raise RuntimeError('WORKER_MEMORY_ACCESS_FAILED')
        if not is_descendant(pid,root,process_parents()):
            self.close();raise RuntimeError('WORKER_OWNERSHIP_CHANGED')
    def close(self):
        if self._handle:self._api.CloseHandle(self._handle);self._handle=None
    def running(self):
        code=wintypes.DWORD()
        self._api.GetExitCodeProcess.argtypes=[wintypes.HANDLE,ctypes.POINTER(wintypes.DWORD)]
        if not self._api.GetExitCodeProcess(self._handle,ctypes.byref(code)):
            raise RuntimeError('WORKER_EXIT_STATUS_FAILED')
        return code.value==259


def terminate_owned_tree(process):
    # The root was created by this run. Stop verified descendants BEFORE its venv
    # redirector; killing only the redirector is not a reliable worker cleanup.
    parents=process_parents();api=ctypes.WinDLL('kernel32',use_last_error=True)
    api.OpenProcess.argtypes=[wintypes.DWORD,wintypes.BOOL,wintypes.DWORD];api.OpenProcess.restype=wintypes.HANDLE
    api.TerminateProcess.argtypes=[wintypes.HANDLE,wintypes.UINT];api.CloseHandle.argtypes=[wintypes.HANDLE]
    api.WaitForSingleObject.argtypes=[wintypes.HANDLE,wintypes.DWORD]
    descendants=[pid for pid in parents if pid!=process.pid and is_descendant(pid,process.pid,parents)]
    for pid in reversed(descendants):
        handle=api.OpenProcess(1|0x00100000,False,pid)
        if handle:
            try:
                if is_descendant(pid,process.pid,process_parents()):
                    if not api.TerminateProcess(handle,1):raise RuntimeError('OWNED_WORKER_STOP_FAILED')
                    if api.WaitForSingleObject(handle,5000)!=0:raise RuntimeError('OWNED_WORKER_STOP_NOT_CONFIRMED')
            finally:api.CloseHandle(handle)
    if process.poll() is None:process.kill()


class Counters(ctypes.Structure):
    _fields_=[('cb',wintypes.DWORD),('faults',wintypes.DWORD)]+[(name,ctypes.c_size_t) for name in
        ('peak_working_set','working_set','quota_peak_paged','quota_paged','quota_peak_nonpaged',
         'quota_nonpaged','private_commit','peak_private_commit')]


def memory_usage(process):
    counters=Counters();counters.cb=ctypes.sizeof(counters)
    api=ctypes.WinDLL('psapi',use_last_error=True).GetProcessMemoryInfo
    api.argtypes=[wintypes.HANDLE,ctypes.POINTER(Counters),wintypes.DWORD]
    if not api(wintypes.HANDLE(int(process._handle)),ctypes.byref(counters),counters.cb):
        raise RuntimeError('PROBE_MEMORY_MONITOR_FAILED')
    return dict(private_commit=counters.private_commit,working_set=counters.working_set,
                peak_private_commit=counters.peak_private_commit,peak_working_set=counters.peak_working_set)


def host_memory():
    class Status(ctypes.Structure):
        _fields_=[('length',wintypes.DWORD),('load',wintypes.DWORD)]+[(name,ctypes.c_ulonglong) for name in
          ('total','available','page_total','page_available','virtual_total','virtual_available','extended')]
    status=Status();status.length=ctypes.sizeof(status)
    if not ctypes.WinDLL('kernel32').GlobalMemoryStatusEx(ctypes.byref(status)):
        raise RuntimeError('HOST_MEMORY_CHECK_FAILED')
    return dict(total_physical_mb=status.total//(1024*1024),available_physical_mb=status.available//(1024*1024))


def run_bounded(command,log,seconds,*,password=None,max_memory_mb=None,popen=subprocess.Popen,
                memory=memory_usage,clock=time.monotonic,worker_metadata=None):
    started=clock();peak=0;working_peak=0;reason=None
    process=popen(command,stdin=subprocess.PIPE if password is not None else subprocess.DEVNULL,
                  stdout=log,stderr=log)
    first=True;worker=None;worker_pid=None
    def stop():
        if worker_metadata is not None:terminate_owned_tree(process)
        else:process.kill()
    try:
        while True:
            try:
                process.communicate(input=password if first else None,timeout=0.2)
                break
            except subprocess.TimeoutExpired:
                first=False
            if max_memory_mb is not None:
                if worker_metadata is not None and worker is None:
                    metadata=worker_metadata()
                    pid=metadata.get('worker_pid')
                    if isinstance(pid,int) and pid>0:
                        worker=OwnedWorker(pid,process.pid);worker_pid=pid
                target=worker or process
                try:usage=memory(target)
                except RuntimeError:
                    if process.poll() is not None:break
                    if worker is None or worker.running():raise
                    # The interpreter can exit just before its venv redirector.
                    # Keep enforcing the wall deadline while the redirector exits.
                    usage=dict(private_commit=0,peak_private_commit=0,working_set=0,peak_working_set=0)
                peak=max(peak,usage['private_commit'],usage['peak_private_commit'])
                working_peak=max(working_peak,usage['working_set'],usage['peak_working_set'])
                if peak>=max_memory_mb*1024*1024:reason='MEMORY LIMIT / NO READINESS PASS'
            if clock()-started>=seconds:reason=reason or 'TIMEOUT / NO READINESS PASS'
            if reason:
                stop();process.communicate();break
        return dict(returncode=process.returncode,stop_reason=reason,elapsed_seconds=round(clock()-started,3),
                    sampled_peak_private_bytes=peak,sampled_peak_working_set_bytes=working_peak,
                    memory_limit_mb=max_memory_mb,wall_limit_seconds=seconds,
                    launcher_pid=process.pid,monitored_worker_pid=worker_pid,
                    memory_scope='verified interpreter descendant' if worker else 'launcher only')
    finally:
        if process.poll() is None:
            stop();process.communicate()
        if worker:worker.close()
