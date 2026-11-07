"""OFFLINE ONLY: compare prospective native-style vs Python hidden input.

Never connects, writes files, logs/hashes credentials or accepts them as arguments.
Only equality booleans and public console metadata leave the process.
Not a reconstruction of an earlier psql process's input.
"""
import argparse
import ctypes
from ctypes import wintypes as w
import getpass
import json
import os
import secrets
import sys
import warnings

def wipe(value):
    if isinstance(value,bytearray): value[:]=b'\x00'*len(value); value.clear()

class NativeConsole:
    def __init__(self):
        if os.name!='nt': raise RuntimeError('Windows console required')
        k=self.k=ctypes.WinDLL('kernel32',use_last_error=True)
        k.CreateFileW.argtypes=[w.LPCWSTR,w.DWORD,w.DWORD,w.LPVOID,w.DWORD,w.DWORD,w.HANDLE]
        k.CreateFileW.restype=w.HANDLE
        k.GetConsoleMode.argtypes=[w.HANDLE,ctypes.POINTER(w.DWORD)]; k.GetConsoleMode.restype=w.BOOL
        k.SetConsoleMode.argtypes=[w.HANDLE,w.DWORD]; k.SetConsoleMode.restype=w.BOOL
        k.ReadConsoleA.argtypes=[w.HANDLE,w.LPVOID,w.DWORD,ctypes.POINTER(w.DWORD),w.LPVOID]
        k.ReadConsoleA.restype=w.BOOL
        k.CloseHandle.argtypes=[w.HANDLE]; k.CloseHandle.restype=w.BOOL
        k.GetConsoleCP.restype=w.UINT
        k.FlushConsoleInputBuffer.argtypes=[w.HANDLE]; k.FlushConsoleInputBuffer.restype=w.BOOL
    def open(self):
        handle=self.k.CreateFileW('CONIN$',0xC0000000,3,None,3,0,None)
        if handle in (None,0,ctypes.c_void_p(-1).value): raise RuntimeError('No native console')
        return handle
    def mode(self,handle):
        value=w.DWORD()
        if not self.k.GetConsoleMode(handle,ctypes.byref(value)): raise RuntimeError('Console mode unavailable')
        return value.value
    def setmode(self,handle,mode):
        if not self.k.SetConsoleMode(handle,mode): raise RuntimeError('Console mode change failed')
    def codepage(self):
        value=self.k.GetConsoleCP()
        if not value: raise RuntimeError('Console input code page unavailable')
        return value
    def read(self,handle):
        buffer=ctypes.create_string_buffer(256); count=w.DWORD()
        try:
            if not self.k.ReadConsoleA(handle,buffer,256,ctypes.byref(count),None):
                raise RuntimeError('Console read failed')
            if not count.value: raise RuntimeError('Empty console read')
            return bytearray(buffer.raw[:count.value])
        finally: ctypes.memset(buffer,0,ctypes.sizeof(buffer))
    def flush(self,handle): self.k.FlushConsoleInputBuffer(handle)
    def close(self,handle): self.k.CloseHandle(handle)

def read_native_style(console):
    """Windows line-processed, echo-off console bytes; same input-codepage principle as psql17.

    This is a reviewed native-style proxy, not instrumentation of installed psql.
    """
    handle=console.open(); original=None; value=bytearray()
    try:
        original=console.mode(handle)
        console.setmode(handle,3)  # ENABLE_LINE_INPUT | ENABLE_PROCESSED_INPUT; no ECHO.
        mode=console.mode(handle)
        if mode&4 or mode&3!=3: raise RuntimeError('Echo-off line mode not established')
        cp=console.codepage()
        print('Offline reference: enter the verified password using hidden native-style input: ',end='',flush=True)
        while not value.endswith(b'\n'):
            chunk=console.read(handle)
            try: value.extend(chunk)
            finally: wipe(chunk)
            if len(value)>16384:
                console.flush(handle)
                raise RuntimeError('Offline input safety bound exceeded')
        result=bytearray(value.rstrip(b'\r\n'))
        return result,cp
    finally:
        wipe(value)
        try:
            if original is not None: console.setmode(handle,original)
        finally:
            console.close(handle)
            print(flush=True)

def compare_values(native_bytes,python_text,code_page):
    if not native_bytes or not python_text: raise ValueError('Offline input unavailable')
    # Conninfo construction/parsing is local-only; no psycopg.connect call exists here.
    from psycopg.conninfo import make_conninfo,conninfo_to_dict
    raw=bytearray(python_text.encode('utf-8'))
    try:
        byte_equal=secrets.compare_digest(native_bytes,raw)  # comparison, NOT hashing.
        try:
            decoded=native_bytes.decode('cp'+str(code_page),errors='strict')
            text_equal=secrets.compare_digest(decoded.encode('utf-8'),raw)
        except (UnicodeError,LookupError): text_equal=None
        roundtrip=conninfo_to_dict(make_conninfo(password=python_text))['password']
        return {'status':'OFFLINE_INPUT_COMPARISON_COMPLETE','console_input_code_page':code_page,
          'native_style_bytes_equal_python_utf8':byte_equal,
          'native_decoded_text_equal_python_text':text_equal,
          'python_conninfo_roundtrip_equal':secrets.compare_digest(roundtrip.encode('utf-8'),raw),
          'network_connection_attempted':False,'historical_psql_bytes_reconstructed':False,
          'credential_written_logged_or_hashed':False}
    finally: wipe(raw)

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compare-offline',action='store_true',help='Two local hidden inputs; zero connections/files')
    args=parser.parse_args()
    if not args.compare_offline:
        print('OFFLINE TOOL READY. Use --compare-offline locally; no connection or password input performed.')
        return 0
    if not sys.stdin.isatty() or not sys.stdout.isatty() or sys.stdin is not sys.__stdin__:
        raise RuntimeError('Normal interactive console required; no redirects/pipes')
    console=NativeConsole(); native=None
    try:
        native,cp=read_native_style(console)
        with warnings.catch_warnings():
            warnings.simplefilter('error',getpass.GetPassWarning)
            python_text=getpass.getpass('Offline comparison: enter the same password using Python hidden input: ')
        result=compare_values(native,python_text,cp)
        del python_text
        result['console_code_page_unchanged']=console.codepage()==cp
        print(json.dumps(result,indent=2))
        return 0 if all(result[k] is True for k in ('native_style_bytes_equal_python_utf8',
            'native_decoded_text_equal_python_text','python_conninfo_roundtrip_equal','console_code_page_unchanged')) else 2
    finally: wipe(native)

if __name__=='__main__':
    try: raise SystemExit(main())
    except KeyboardInterrupt:
        print('OFFLINE_INPUT_CANCELLED. No network connection or credential report saved.')
        raise SystemExit(1)
    except Exception:
        # Do not format an exception: a parser error could include credential content.
        print('OFFLINE_INPUT_CHECK_STOPPED. No raw error or credential content displayed. No network connection attempted.')
        raise SystemExit(1)
