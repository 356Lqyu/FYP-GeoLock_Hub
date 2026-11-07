"""Real NGO session adapter over synthetic HTTP; no credentials or network."""
import unittest
from unittest.mock import Mock

from ..errors import WorkerError
from ..server import Application
from ..transport import NgoSession, BASE
from .test_worker_flow import OWNER, REQ, SID


class StagedSessionTransportTests(unittest.TestCase):
    def test_required_staged_rpcs_reach_owned_jwt_transport(self):
        http = Mock()
        http.request.return_value = {'snapshot_id': SID}
        session = NgoSession(OWNER, 'SYNTHETIC_TOKEN', 'sb_publishable_SYNTHETIC', http)
        for name, params in [('get_my_routing_overview', {}),
                             ('begin_my_routing_snapshot', {'p_request': REQ})]:
            session.rpc(name, params)
            args, kwargs = http.request.call_args
            self.assertEqual(args, (BASE + '/rest/v1/rpc/' + name,))
            self.assertEqual(kwargs['token'], 'SYNTHETIC_TOKEN')
            self.assertEqual(kwargs['body'], params)
        for forbidden in ('recover_expired_claims', 'finalize_route_resolution', 'complete_pickup'):
            with self.assertRaises(WorkerError): session.rpc(forbidden)
        self.assertEqual(http.request.call_count, 2)

    def test_readonly_capability_reports_exact_activation_without_planning(self):
        auth, worker = Mock(), Mock()
        auth.verify.return_value = Mock(user_id=OWNER)
        worker.automatic_authorization_capabilities.return_value = {
            'contract': 'geolock.routing-auto-now.v1', 'ngo_id': OWNER, 'automatic_departure': True}
        for enabled in (False, True):
            app = Application(auth=auth, worker=worker, active=True, exact_enabled=enabled)
            result = app.dispatch('/v1/authorization-capabilities', 'Bearer SYNTHETIC', {'request_id': REQ})
            self.assertEqual(result['exact_staged_enabled'], enabled)
        worker.plan.assert_not_called()
        worker.plan_and_authorize.assert_not_called()
        worker.authorize.assert_not_called()


if __name__ == '__main__':
    unittest.main()
