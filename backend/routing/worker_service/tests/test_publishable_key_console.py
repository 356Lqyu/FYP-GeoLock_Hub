"""Dummy batch-paste into an isolated hidden console; no real clipboard/secrets."""
import ctypes
from ctypes import wintypes
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import threading
import time
import unittest

ROOT=Path(__file__).resolve().parents[4]


def console_child(shell):
    api=ctypes.WinDLL('kernel32',use_last_error=True)
    api.CreateFileW.argtypes=[wintypes.LPCWSTR,wintypes.DWORD,wintypes.DWORD,ctypes.c_void_p,wintypes.DWORD,wintypes.DWORD,wintypes.HANDLE]
    api.CreateFileW.restype=wintypes.HANDLE
    api.GetConsoleMode.argtypes=[wintypes.HANDLE,ctypes.POINTER(wintypes.DWORD)]
    api.CloseHandle.argtypes=[wintypes.HANDLE]
    class Key(ctypes.Structure):
        _fields_=[('down',wintypes.BOOL),('repeat',wintypes.WORD),('vk',wintypes.WORD),('scan',wintypes.WORD),('char',wintypes.WCHAR),('control',wintypes.DWORD)]
    class Event(ctypes.Union):_fields_=[('key',Key)]
    class Input(ctypes.Structure):_fields_=[('kind',wintypes.WORD),('event',Event)]
    api.WriteConsoleInputW.argtypes=[wintypes.HANDLE,ctypes.POINTER(Input),wintypes.DWORD,ctypes.POINTER(wintypes.DWORD)]
    handle=api.CreateFileW('CONIN$',0xC0000000,3,None,3,0,None)
    outcome={};dummy='sb_publishable_'+'X'*1024+'_DUMMY_ONLY'
    def paste():
        deadline=time.monotonic()+20
        while time.monotonic()<deadline:
            mode=wintypes.DWORD()
            if api.GetConsoleMode(handle,ctypes.byref(mode)) and mode.value&2 and not mode.value&4:
                outcome['echo_disabled_during_input']=True
                events=(Input*(2*len(dummy)))()
                for i,char in enumerate(dummy):
                    for j,down in enumerate((True,False)):
                        e=events[2*i+j];e.kind=1;e.event.key=Key(down,1,13 if char=='\r' else 0,0,char,0)
                count=wintypes.DWORD()
                outcome['batch_injected']=bool(api.WriteConsoleInputW(handle,events,len(events),ctypes.byref(count))) and count.value==len(events)
                time.sleep(.3)
                outcome['waited_for_enter']=process.poll() is None
                enter=(Input*2)()
                for i,down in enumerate((True,False)):
                    enter[i].kind=1;enter[i].event.key=Key(down,1,13,0,'\r',0)
                api.WriteConsoleInputW(handle,enter,len(enter),ctypes.byref(count))
                return
            time.sleep(.02)
        outcome['echo_disabled_during_input']=False
    writer=threading.Thread(target=paste,daemon=True)
    try:
        script=ROOT/'backend/routing/worker_service/windows/Test-PlannerPublishableKeyUpdate.ps1'
        # Exercise local functions as commands in the private test console;
        # Windows PowerShell's machine/script execution policy is not changed.
        path=str(script).replace("'","''");folder=str(script.parent).replace("'","''")
        command="& ([ScriptBlock]::Create([IO.File]::ReadAllText('"+path+"'))) -ConsolePasteTest -HelperDirectory '"+folder+"'"
        process=subprocess.Popen([shell,'-NoProfile','-Command',command],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        writer.start()
        try:stdout,stderr=process.communicate(timeout=30)
        except BaseException:
            process.kill();process.communicate();raise
        writer.join(timeout=1)
        outcome.update(exitcode=process.returncode,full_paste_verified='SYNTHETIC_PASTE_PASS' in stdout,
            mode_restored='CONSOLE_MODE_RESTORED' in stdout,
            dummy_not_in_output=dummy not in stdout+stderr)
        # Deliberately never return raw stdout/stderr, even on a failing test.
        return outcome
    finally:api.CloseHandle(handle)


@unittest.skipUnless(sys.platform=='win32','Windows isolated console regression')
class PublishablePasteTests(unittest.TestCase):
    def test_full_dummy_paste_under_windows_powershell_and_pwsh(self):
        shells=[str(Path(os.environ['SystemRoot'])/'System32/WindowsPowerShell/v1.0/powershell.exe')]
        if shutil.which('pwsh'):shells.append(shutil.which('pwsh'))
        startup=subprocess.STARTUPINFO();startup.dwFlags|=subprocess.STARTF_USESHOWWINDOW;startup.wShowWindow=0
        for shell in shells:
            with self.subTest(shell=Path(shell).name):
                result=subprocess.run([sys.executable,'-B','-m',__spec__.name,'--console-child',shell],
                    creationflags=subprocess.CREATE_NEW_CONSOLE,startupinfo=startup,capture_output=True,text=True,check=True,timeout=40)
                report=json.loads(result.stdout)
                self.assertEqual(report['exitcode'],0,report)
                for name in ['echo_disabled_during_input','batch_injected','waited_for_enter','full_paste_verified','mode_restored','dummy_not_in_output']:
                    self.assertTrue(report[name],report)


if __name__=='__main__' and len(sys.argv)==3 and sys.argv[1]=='--console-child':
    print(json.dumps(console_child(sys.argv[2])))
