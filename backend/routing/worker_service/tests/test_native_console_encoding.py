"""Actual CRT fgets with synthetic input in a NEW hidden, test-owned console.

Never reads a real password or changes the user's console/code page. No network.
"""
import ctypes
from ctypes import wintypes
import json
import os
import subprocess
import sys
import unittest

from backend.routing.worker_service.password_transport_check import read_native_console_password, classify_native_text

SAMPLES={'ascii':'synthetic-ASCII','accent':'synthetic café','chinese':'synthetic 漢字'}


def console_child(codepage, case):
    kernel=ctypes.WinDLL('kernel32',use_last_error=True)
    kernel.CreateFileW.argtypes=[wintypes.LPCWSTR,wintypes.DWORD,wintypes.DWORD,ctypes.c_void_p,wintypes.DWORD,wintypes.DWORD,wintypes.HANDLE]
    kernel.CreateFileW.restype=wintypes.HANDLE
    kernel.CloseHandle.argtypes=[wintypes.HANDLE]
    class Key(ctypes.Structure):
        _fields_=[('down',wintypes.BOOL),('repeat',wintypes.WORD),('vk',wintypes.WORD),
                  ('scan',wintypes.WORD),('char',wintypes.WCHAR),('control',wintypes.DWORD)]
    class Event(ctypes.Union): _fields_=[('key',Key)]
    class Input(ctypes.Structure): _fields_=[('kind',wintypes.WORD),('event',Event)]
    kernel.WriteConsoleInputW.argtypes=[wintypes.HANDLE,ctypes.POINTER(Input),wintypes.DWORD,ctypes.POINTER(wintypes.DWORD)]
    old=kernel.GetConsoleCP()
    if not old or not kernel.SetConsoleCP(codepage): raise RuntimeError('Private console unavailable')
    handle=kernel.CreateFileW('CONIN$',0xC0000000,3,None,3,0,None)
    try:
        sample=SAMPLES[case]
        events=(Input*(2*(len(sample)+1)))()
        for i,char in enumerate(sample+'\r'):
            for j,down in enumerate((True,False)):
                event=events[2*i+j];event.kind=1;event.event.key=Key(down,1,13 if char=='\r' else 0,0,char,0)
        count=wintypes.DWORD()
        if not kernel.WriteConsoleInputW(handle,events,len(events),ctypes.byref(count)): raise RuntimeError('Synthetic console input failed')
        raw=read_native_console_password()
        try:
            codec='utf-8' if codepage==65001 else 'cp'+str(codepage)
            text,explanation=classify_native_text(raw,sample,codepage)
            return dict(codepage=kernel.GetConsoleCP(),native_matches_codepage_model=raw==sample.encode(codec,errors='replace'),
                        native_matches_ansi_model=raw==sample.encode('cp'+str(kernel.GetACP()),errors='replace'),
                        native_matches_utf8=raw==sample.encode('utf-8'),text=text,explanation=explanation)
        finally: raw[:]=b'\0'*len(raw)
    finally:
        kernel.CloseHandle(handle);kernel.SetConsoleCP(old)


@unittest.skipUnless(sys.platform=='win32','Private Windows console regression')
class NativeConsoleTests(unittest.TestCase):
    def test_real_crt_console_encoding_ascii_accent_utf8_and_lossy_cases(self):
        env={k:v for k,v in os.environ.items() if not k.startswith(('PG','GEOLOCK_','PSYCOPG_'))}
        startup=subprocess.STARTUPINFO();startup.dwFlags|=subprocess.STARTF_USESHOWWINDOW;startup.wShowWindow=0
        for cp,case in ((437,'ascii'),(437,'accent'),(1252,'accent'),(65001,'accent'),(437,'chinese')):
            result=subprocess.run([sys.executable,'-B','-m',__spec__.name,'--console-child',str(cp),case],
                env=env,creationflags=subprocess.CREATE_NEW_CONSOLE,startupinfo=startup,
                capture_output=True,text=True,encoding='utf-8',check=True,timeout=15)
            report=json.loads(result.stdout)
            self.assertEqual(report['codepage'],cp)
            if cp!=65001:self.assertTrue(report['native_matches_codepage_model'])
            if case=='accent' and cp!=65001:
                self.assertFalse(report['native_matches_utf8'])
                self.assertEqual(report['text'],'DECODED TEXT MATCHES REFERENCE')
                self.assertEqual(report['explanation'],'CONSISTENT WITH CODE-PAGE ENCODING')
            elif case=='chinese':
                self.assertEqual(report['explanation'],'UNPROVEN')
            elif cp==65001:
                # Some Windows CRT builds truncate multi-byte console reads. Never
                # turn that implementation-specific mismatch into an encoding fix.
                if report['native_matches_utf8']:
                    self.assertEqual(report['explanation'],'NO BYTE DIFFERENCE')
                else:self.assertEqual(report['explanation'],'UNPROVEN')
            else:self.assertTrue(report['native_matches_utf8'])


if __name__=='__main__' and len(sys.argv)==4 and sys.argv[1]=='--console-child':
    print(json.dumps(console_child(int(sys.argv[2]),sys.argv[3])))
