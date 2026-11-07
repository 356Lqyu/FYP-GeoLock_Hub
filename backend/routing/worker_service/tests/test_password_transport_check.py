"""Synthetic offline password-path tests; never authenticate or print credentials."""
import base64
import ctypes
import json
from pathlib import Path
import shutil
import subprocess
import sys
import unittest
from unittest.mock import Mock, patch

from backend.routing.worker_service.password_transport_check import compare, read_native_console_password

ROOT=Path(__file__).resolve().parents[4]
LAUNCHER=ROOT/'docs/stage8/functional-routing/run_readonly_graph_probe.ps1'


def dsn(password):
    from psycopg.conninfo import make_conninfo
    return make_conninfo(host='offline.invalid',password=password)


class PasswordTransportTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform=='win32','Windows console mode restoration')
    def test_native_console_mode_restored_on_success_and_input_failure(self):
        for eof in (False,True):
            crt=Mock();kernel=Mock()
            crt.fopen.side_effect=[1,2];crt._fileno.return_value=3;crt._get_osfhandle.return_value=123
            def get_mode(handle,mode): mode._obj.value=7;return 1
            kernel.GetConsoleMode.side_effect=get_mode;kernel.SetConsoleMode.return_value=1
            def read(buffer,size,stream):
                if eof: return None
                ctypes.memmove(buffer,b'synthetic\n\0',11);return ctypes.addressof(buffer)
            crt.fgets.side_effect=read
            with patch('ctypes.CDLL',return_value=crt),patch('ctypes.WinDLL',return_value=kernel):
                if eof:
                    with self.assertRaises(RuntimeError):read_native_console_password()
                else:self.assertEqual(read_native_console_password(),bytearray(b'synthetic'))
            self.assertEqual([c.args for c in kernel.SetConsoleMode.call_args_list],[(123,3),(123,7)])
            self.assertEqual(crt.fclose.call_count,2)

    def test_utf8_roundtrip_is_equality_only_and_wipes_native_buffer(self):
        secret='SYNTHETIC ü漢字 \\ quote\''
        native=bytearray(secret.encode('utf-8'))
        with patch('psycopg.connect',side_effect=AssertionError('Network forbidden')):
            result=compare(dsn(secret),secret,native_reader=lambda:native,input_codepage=65001)
        self.assertEqual(result['launcher_transport'],'MATCH')
        self.assertEqual(result['native_console_bytes'],'MATCH')
        self.assertEqual(result['native_text_comparison'],'DECODED TEXT MATCHES REFERENCE')
        self.assertTrue(all(x==0 for x in native))
        self.assertNotIn(secret,json.dumps(result))

    def test_different_native_codepage_bytes_are_not_silently_normalized(self):
        secret='synthetic café'
        result=compare(dsn(secret),secret,native_reader=lambda:bytearray(secret.encode('cp1252')),input_codepage=1252)
        self.assertEqual(result['launcher_transport'],'MATCH')
        self.assertEqual(result['native_console_bytes'],'MISMATCH')
        self.assertEqual(result['native_text_comparison'],'DECODED TEXT MATCHES REFERENCE')
        self.assertEqual(result['encoding_explanation'],'CONSISTENT WITH CODE-PAGE ENCODING')
        self.assertNotIn(secret,json.dumps(result))

    def test_manual_difference_or_lossy_input_does_not_confirm_encoding(self):
        for actual in (b'synthetic typo',b'synthetic ?'):
            result=compare(dsn('synthetic café'),'synthetic café',native_reader=lambda:bytearray(actual),input_codepage=437)
            self.assertEqual(result['native_text_comparison'],'DIFFERENT TEXT OR LOSSY CONVERSION')
            self.assertEqual(result['encoding_explanation'],'UNPROVEN')

    def test_unicode_normalization_and_spaces_are_not_silently_folded(self):
        for reference,actual in [('café','cafe\u0301'),(' spaces ','spaces')]:
            result=compare(dsn(reference),reference,native_reader=lambda:bytearray(actual.encode('utf-8')),input_codepage=65001)
            self.assertEqual(result['encoding_explanation'],'UNPROVEN')

    def test_dsn_corruption_stops_before_second_prompt(self):
        reader=Mock()
        result=compare(dsn('synthetic wrong'),'synthetic expected',native_reader=reader)
        self.assertEqual(result['launcher_transport'],'MISMATCH')
        reader.assert_not_called()

    @unittest.skipUnless(sys.platform=='win32','Actual Windows SecureString/environment bridge')
    def test_securestring_environment_and_native17_libpq_roundtrip(self):
        samples=['synthetic spaces',"synthetic'quote",'synthetic\\backslash\\',
                 'synthetic"$`;&','synthetic ü漢字',' synthetic ends ']
        quote=lambda value:"'"+str(value).replace("'","''")+"'"
        code=("$ErrorActionPreference='Stop';$t=$null;$e=$null;"
              "$a=[System.Management.Automation.Language.Parser]::ParseFile("+quote(LAUNCHER)+",[ref]$t,[ref]$e);"
              "if($e.Count){throw 'Parse failed'};"
              "$f=$a.Find({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'New-GraphProbeDsn'},$true);"
              "Invoke-Expression $f.Extent.Text; $answers=@(); foreach($s in @("+','.join(map(quote,samples))+")){"
              "$secure=ConvertTo-SecureString $s -AsPlainText -Force;$ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure);"
              "try{$plain=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr);"
              "$i=New-Object Diagnostics.ProcessStartInfo;$i.FileName="+quote(sys.executable)+";"
              "$i.WorkingDirectory="+quote(ROOT)+";$i.UseShellExecute=$false;$i.CreateNoWindow=$true;"
              "$i.RedirectStandardOutput=$true;$i.RedirectStandardError=$true;"
              "$i.Arguments='-B -m backend.routing.worker_service.tests.test_password_transport_check';"
              "foreach($k in @($i.EnvironmentVariables.Keys)){if($k -match '^(PG|GEOLOCK_|PSYCOPG_)'){$i.EnvironmentVariables.Remove($k)}};"
              "$i.EnvironmentVariables['GEOLOCK_GRAPH_DSN']=New-GraphProbeDsn $plain;"
              "$i.EnvironmentVariables['GEOLOCK_PASSWORD_REFERENCE']=$plain;"
              "$p=[Diagnostics.Process]::Start($i);$i.EnvironmentVariables.Remove('GEOLOCK_GRAPH_DSN');$i.EnvironmentVariables.Remove('GEOLOCK_PASSWORD_REFERENCE');"
              "$out=$p.StandardOutput.ReadToEnd();$p.WaitForExit();$answers+=($p.ExitCode -eq 0 -and $out.Trim() -eq 'PASS');$p.Dispose()"
              "}finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr);$secure.Dispose();$plain=$null}};"
              "$answers|ConvertTo-Json")
        result=subprocess.run([shutil.which('pwsh'),'-NoProfile','-EncodedCommand',base64.b64encode(code.encode('utf-16-le')).decode()],
                              capture_output=True,text=True,encoding='utf-8',check=True)
        self.assertEqual(json.loads(result.stdout),[True]*len(samples))


if __name__=='__main__':
    # Only a synthetic child launched by the offline test. No console prompt/DB.
    import os
    from backend.routing.worker_service.connection_diagnostic_native17 import configure_client
    handle,_=configure_client()
    try:
        reference=os.environ.pop('GEOLOCK_PASSWORD_REFERENCE')
        conninfo=os.environ.pop('GEOLOCK_GRAPH_DSN')
        result=compare(conninfo,reference,native_reader=lambda:bytearray(reference.encode('utf-8')),input_codepage=65001)
        if result['launcher_transport']!='MATCH' or result['native_console_bytes']!='MATCH': sys.exit(1)
        print('PASS')
    finally:
        handle.close()
