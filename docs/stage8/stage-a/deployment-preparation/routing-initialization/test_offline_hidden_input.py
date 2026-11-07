"""No real credentials, console reads, network calls or fixture files."""
import contextlib
import io
import json
import unittest
from compare_hidden_input_offline import read_native_style,compare_values

class FakeConsole:
    def __init__(self,fail_read=False,echo_stuck=False):
        self.current=7; self.closed=False; self.fail_read=fail_read; self.echo_stuck=echo_stuck
    def open(self): return 1
    def mode(self,h): return self.current
    def setmode(self,h,value): self.current=(value|4) if self.echo_stuck and value==3 else value
    def codepage(self): return 65001
    def read(self,h):
        if self.fail_read: raise RuntimeError('test read error')
        return bytearray(b'EXAMPLE_ONLY\r\n')
    def flush(self,h): pass
    def close(self,h): self.closed=True

class OfflineTests(unittest.TestCase):
    def test_empty_input_does_not_produce_equivalence(self):
        with self.assertRaises(ValueError): compare_values(bytearray(),'EXAMPLE_ONLY',65001)
        with self.assertRaises(ValueError): compare_values(bytearray(b'EXAMPLE_ONLY'),'',65001)

    def test_ascii_and_special_characters_equal(self):
        text='DUMMY_ONLY_@%:' + chr(39)+chr(92)+' space'
        result=compare_values(bytearray(text.encode()),text,65001)
        self.assertTrue(result['native_style_bytes_equal_python_utf8'])
        self.assertTrue(result['python_conninfo_roundtrip_equal'])
        self.assertNotIn(text,json.dumps(result))

    def test_equal_text_different_codepage_bytes(self):
        result=compare_values(bytearray('caf\u00e9'.encode('cp1252')),'caf\u00e9',1252)
        self.assertFalse(result['native_style_bytes_equal_python_utf8'])
        self.assertTrue(result['native_decoded_text_equal_python_text'])

    def test_entry_difference_detected(self):
        result=compare_values(bytearray(b'EXAMPLE_ONLY'),'EXAMPLE_ONLY\u200b',65001)
        self.assertFalse(result['native_style_bytes_equal_python_utf8'])
        self.assertFalse(result['native_decoded_text_equal_python_text'])

    def test_echo_disabled_and_restored(self):
        console=FakeConsole()
        with contextlib.redirect_stdout(io.StringIO()) as output:
            value,cp=read_native_style(console)
        self.assertEqual(value,bytearray(b'EXAMPLE_ONLY'))
        self.assertNotIn('EXAMPLE_ONLY',output.getvalue())
        self.assertEqual(console.current,7); self.assertTrue(console.closed)

    def test_restore_after_read_error(self):
        console=FakeConsole(fail_read=True)
        with contextlib.redirect_stdout(io.StringIO()),self.assertRaises(RuntimeError): read_native_style(console)
        self.assertEqual(console.current,7); self.assertTrue(console.closed)

    def test_fail_closed_if_echo_enabled(self):
        console=FakeConsole(echo_stuck=True)
        with contextlib.redirect_stdout(io.StringIO()),self.assertRaises(RuntimeError): read_native_style(console)
        self.assertTrue(console.closed); self.assertEqual(console.current,7)

if __name__=='__main__': unittest.main()
