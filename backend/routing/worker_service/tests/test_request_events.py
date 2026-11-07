"""Sanitized local logging only; never sends a routing/DEV request."""
import contextlib
import io
import json
import unittest
from unittest.mock import Mock
from backend.routing.worker_service.server import request_event,Application
from backend.routing.worker_service.errors import WorkerError


class RequestEventTests(unittest.TestCase):
    def test_event_never_logs_headers_payloads_tokens_or_invalid_request_ids(self):
        output=io.StringIO()
        with contextlib.redirect_stdout(output):
            request_event(dict(stage='http_received',request_id='SYNTHETIC_SECRET',
                snapshot_id='00000000-0000-0000-0000-000000000001',
                headers={'Authorization':'Bearer SYNTHETIC_SECRET'},body='SYNTHETIC_SECRET',dsn='SYNTHETIC_SECRET'))
        value=json.loads(output.getvalue())
        self.assertNotIn('SYNTHETIC_SECRET',output.getvalue())
        self.assertNotIn('request_id',value)
        self.assertEqual(value['snapshot_id'],'00000000-0000-0000-0000-000000000001')

    def test_auth_rejection_stops_before_planner_and_logs_stage_without_bearer(self):
        auth=Mock();auth.verify.side_effect=WorkerError('AUTHENTICATION_REQUIRED',401)
        worker=Mock();app=Application(auth=auth,worker=worker,active=True)
        output=io.StringIO()
        with contextlib.redirect_stdout(output),self.assertRaises(WorkerError):
            app.dispatch('/v1/plan','Bearer SYNTHETIC_SECRET',{'request_id':'00000000-0000-0000-0000-000000000001','snapshot_id':'00000000-0000-0000-0000-000000000002'})
        self.assertIn('verify_ngo_jwt',output.getvalue());self.assertNotIn('SYNTHETIC_SECRET',output.getvalue())
        worker.plan.assert_not_called()
