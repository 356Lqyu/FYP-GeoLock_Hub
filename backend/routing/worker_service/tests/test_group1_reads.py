"""Group 1 helper bounds. No real device, credentials or network."""
from contextlib import redirect_stdout
import importlib.util
import io
from pathlib import Path
from unittest.mock import patch
import unittest

from ..errors import WorkerError
from ..transport import BASE, JsonHttp

SCRIPT = Path(__file__).resolve().parents[4] / 'scripts/Verify-ExactPilotGroup1.py'
spec = importlib.util.spec_from_file_location('group1_helper_test', SCRIPT)
group1 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(group1)


class Group1Tests(unittest.TestCase):
    def test_hold_distinguishes_missing_runtime_field_from_disabled_flag_and_vehicle(self):
        self.assertEqual(group1.hold_reasons(True, {}), ['PLANNER_EXACT_CAPABILITY_FIELD_MISSING'])
        self.assertEqual(group1.hold_reasons(True, {'exact_staged_enabled': False}),
                         ['PLANNER_EXACT_WORKFLOW_NOT_ENABLED'])
        self.assertEqual(group1.hold_reasons(False, {'exact_staged_enabled': True}),
                         ['V3_PROTECTED_READINESS_NOT_CONFIRMED'])
        self.assertEqual(group1.hold_reasons(True, {'exact_staged_enabled': True}), [])

    def test_default_command_is_local_only(self):
        output = io.StringIO()
        with patch('sys.argv', [str(SCRIPT)]), redirect_stdout(output), \
                patch.object(group1.phone, 'phone_session', side_effect=AssertionError('Phone')), \
                patch.object(group1.phone, 'health', side_effect=AssertionError('Network')):
            group1.main()
        self.assertIn('"connection_attempted":false', output.getvalue())

    def test_snapshot_authorization_and_direct_profile_reads_are_denied(self):
        reads = group1.Reads()
        with patch.object(JsonHttp, 'request') as http:
            for path in ('/rest/v1/rpc/begin_my_routing_snapshot',
                         '/rest/v1/rpc/authorize_my_routing_candidate',
                         '/rest/v1/ngo_profiles'):
                with self.assertRaises(WorkerError): reads.request(BASE + path, token='SYNTHETIC')
            http.assert_not_called()

    def test_protected_overview_read_uses_existing_session_transport(self):
        reads = group1.Reads()
        with patch.object(JsonHttp, 'request', return_value={'policy_id': 'synthetic-policy'}) as http:
            result = reads.request(BASE + '/rest/v1/rpc/get_my_routing_overview', token='SYNTHETIC', body={})
        self.assertEqual(result['policy_id'], 'synthetic-policy')
        http.assert_called_once()


if __name__ == '__main__':
    unittest.main()
