"""OFFLINE equality only: no connections, files, hashes, lengths or secret output.

Native prompt mirrors PostgreSQL17 common/sprompt.c's narrow CRT CONIN$ path.
It is a comparison helper, not execution/interception of the psql binary.
"""
import ctypes
from ctypes import wintypes
import json
import os


def read_native_console_password(prompt=b'Re-enter SAME password for OFFLINE native-console comparison (hidden): '):
    if os.name!='nt': raise RuntimeError('INTERACTIVE_WINDOWS_CONSOLE_REQUIRED')
    crt=ctypes.CDLL('ucrtbase.dll')
    crt.fopen.argtypes=[ctypes.c_char_p,ctypes.c_char_p];crt.fopen.restype=ctypes.c_void_p
    crt.fclose.argtypes=[ctypes.c_void_p]
    crt._fileno.argtypes=[ctypes.c_void_p];crt._fileno.restype=ctypes.c_int
    crt._get_osfhandle.argtypes=[ctypes.c_int];crt._get_osfhandle.restype=ctypes.c_ssize_t
    crt.fgets.argtypes=[ctypes.c_void_p,ctypes.c_int,ctypes.c_void_p];crt.fgets.restype=ctypes.c_void_p
    crt.fputs.argtypes=[ctypes.c_char_p,ctypes.c_void_p];crt.fflush.argtypes=[ctypes.c_void_p]
    kernel=ctypes.WinDLL('kernel32',use_last_error=True)
    kernel.GetConsoleMode.argtypes=[wintypes.HANDLE,ctypes.POINTER(wintypes.DWORD)]
    kernel.SetConsoleMode.argtypes=[wintypes.HANDLE,wintypes.DWORD]
    incoming=crt.fopen(b'CONIN$',b'w+'); outgoing=crt.fopen(b'CONOUT$',b'w+')
    mode=wintypes.DWORD(); changed=False; raw=None; delivered=False
    buffer=ctypes.create_string_buffer(65536)
    try:
        if not incoming or not outgoing: raise RuntimeError('CONSOLE_UNAVAILABLE')
        handle=crt._get_osfhandle(crt._fileno(incoming))
        if not kernel.GetConsoleMode(handle,ctypes.byref(mode)): raise RuntimeError('CONSOLE_MODE_UNAVAILABLE')
        # Same processed/line input without ECHO used by PostgreSQL's native prompt.
        if not kernel.SetConsoleMode(handle,3): raise RuntimeError('CANNOT_DISABLE_ECHO')
        changed=True
        crt.fputs(prompt,outgoing)
        crt.fflush(outgoing)
        if not crt.fgets(buffer,len(buffer),incoming): raise RuntimeError('NO_CONSOLE_INPUT')
        raw=bytearray(buffer.value)
        if not raw.endswith(b'\n'): raise RuntimeError('INPUT_LIMIT_OR_INTERRUPTION')
        while raw and raw[-1] in (10,13): raw.pop()
        delivered=True
        return raw
    finally:
        ctypes.memset(ctypes.addressof(buffer),0,len(buffer))
        if not delivered and isinstance(raw,bytearray): raw[:]=b'\0'*len(raw)
        if changed:
            kernel.SetConsoleMode(handle,mode.value)
            crt.fputs(b'\n',outgoing);crt.fflush(outgoing)
        if incoming: crt.fclose(incoming)
        if outgoing: crt.fclose(outgoing)


def classify_native_text(native, reference, codepage):
    """Fixed statuses only; never normalize or change a password's encoding."""
    try:
        codec='utf-8' if codepage==65001 else 'cp'+str(codepage)
        decoded=bytes(native).decode(codec,errors='strict')
        lossless=decoded.encode(codec,errors='strict')==native
        same=lossless and decoded==reference
    except (LookupError,UnicodeError):
        return 'UNDECODABLE / INCONCLUSIVE','UNPROVEN'
    if same and native!=reference.encode('utf-8'):
        return 'DECODED TEXT MATCHES REFERENCE','CONSISTENT WITH CODE-PAGE ENCODING'
    if same:
        return 'DECODED TEXT MATCHES REFERENCE','NO BYTE DIFFERENCE'
    return 'DIFFERENT TEXT OR LOSSY CONVERSION','UNPROVEN'


def compare(dsn, reference, native_reader=read_native_console_password, *, input_codepage=None):
    from psycopg import pq
    # This is PQconninfoParse only; no libpq connection function is invoked.
    options=pq.Conninfo.parse(dsn.encode('utf-8'))
    password=next((option.val for option in options if option.keyword==b'password'),None)
    expected=bytearray(reference.encode('utf-8'))
    native=None
    try:
        transport=password is not None and password==expected
        if not transport:
            return dict(launcher_transport='MISMATCH',native_console_bytes='NOT CHECKED',database_connection_attempted=False)
        if input_codepage is None:
            input_codepage=ctypes.WinDLL('kernel32').GetConsoleCP() if os.name=='nt' else 0
        native=native_reader()
        text_result,encoding_result=classify_native_text(native,reference,input_codepage)
        return dict(launcher_transport='MATCH',native_console_bytes='MATCH' if native==expected else 'MISMATCH',
                    native_text_comparison=text_result,encoding_explanation=encoding_result,
                    console_input_codepage=input_codepage,database_connection_attempted=False)
    finally:
        for value in (expected,native):
            if isinstance(value,bytearray): value[:]=b'\0'*len(value)


def main():
    # The real password is never printed, logged, hashed or persisted. Only equality
    # outcomes leave this function; no length/ASCII/non-ASCII statistics are emitted.
    dsn=os.environ.pop('GEOLOCK_GRAPH_DSN','')
    reference=os.environ.pop('GEOLOCK_PASSWORD_REFERENCE','')
    try:
        if not dsn or not reference or '\0' in reference: raise RuntimeError('NO_VALID_LOCAL_INPUT')
        result=compare(dsn,reference)
        print(json.dumps(result))
        return 0 if result['launcher_transport']=='MATCH' and result['native_console_bytes']=='MATCH' else 1
    except Exception:
        print('OFFLINE_PASSWORD_COMPARISON_INCOMPLETE / NO CONNECTION ATTEMPTED')
        return 2
    finally:
        dsn=None;reference=None
