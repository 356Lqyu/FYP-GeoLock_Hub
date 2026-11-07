"""Explicit operator stages. Transport supplies the NGO JWT only in memory.

Journal is metadata only. Construction/reopening never sends a network request.
"""
from .errors import check
from .journal import Journal
from .staged import ExactRouteWorkflow
from .transport import uuid


class StagedPilotClient:
    def __init__(self, directory, request_id, scope, call):
        self.request = uuid(request_id)
        self.scope = ExactRouteWorkflow.scope(scope)
        self.journal = Journal(directory)
        self.call = call
        self.journal.save(self.request, 'client_scope', self.scope)

    def plan(self):
        with self.journal.operation_lock(self.request):
            return self._plan()

    def _plan(self):
        check(self.journal.get(self.request, 'client_plan_send') is None,
              'EXACT_CLIENT_PLAN_ALREADY_ATTEMPTED_RECONCILE_ONLY')
        self.journal.save(self.request, 'client_plan_send', {'request_id': self.request})
        ready = self.call('/v1/exact-route-plan', dict(request_id=self.request, scope=self.scope))
        check(ready.get('kind') == 'EXACT_CANDIDATE_VERIFIED'
              and ready.get('dispatch_authority_issued') is False
              and ready.get('request_id') == self.request
              and ready.get('ngo_id') == self.scope['ngo_id']
              and ready.get('vehicle_id') == self.scope['vehicle_id']
              and ready.get('policy_id') == self.scope['policy_id']
              and ready.get('task_ids') == self.scope['task_ids']
              and ready.get('validation_status') == 'ATTESTED', 'EXACT_CLIENT_PLAN_NOT_CONFIRMED')
        self.journal.save(self.request, 'client_ready', ready)
        return ready  # Always STOP here; never calls authorize automatically.

    def authorize(self):
        with self.journal.operation_lock(self.request):
            return self._authorize()

    def _authorize(self):
        ready = self.journal.get(self.request, 'client_ready')
        check(ready is not None, 'EXACT_CLIENT_VERIFIED_PLAN_REQUIRED')
        check(self.journal.get(self.request, 'client_authorization_send') is None,
              'EXACT_CLIENT_AUTHORIZATION_ALREADY_ATTEMPTED_RECONCILE_ONLY')
        self.journal.save(self.request, 'client_authorization_send', {
            'request_id': ready['authorization_request_id'], 'candidate_id': ready['candidate_id']})
        result = self.call('/v1/exact-route-authorize', dict(request_id=self.request, scope=self.scope))
        return self._receipt(result, ready)

    def _receipt(self, result, ready):
        receipt = result.get('authorization', {})
        ids = receipt.get('route_ids')
        check(result.get('kind') == 'DATABASE_AUTHORIZATION_RECEIPT'
              and result.get('ngo_id') == self.scope['ngo_id']
              and result.get('request_id') == self.request
              and result.get('snapshot_id') == ready['snapshot_id']
              and result.get('authorization_request_id') == ready['authorization_request_id']
              and receipt.get('candidate_id') == ready['candidate_id']
              and receipt.get('snapshot_id') == ready['snapshot_id']
              and receipt.get('departure_mode') == 'AUTO_NOW'
              and isinstance(ids, list) and len(ids) == 1 and isinstance(ids[0], str)
              and bool(ids[0]), 'EXACT_CLIENT_AUTHORIZATION_UNCERTAIN')
        self.journal.save(self.request, 'client_receipt', result)
        return result

    def reconcile(self):
        ready = self.journal.get(self.request, 'client_ready')
        check(ready is not None, 'EXACT_CLIENT_SNAPSHOT_NEEDS_OPERATOR_REVIEW')
        result = self.call('/v1/authorization-result', {
            'request_id': self.request, 'snapshot_id': ready['snapshot_id']})
        if result.get('kind') == 'DATABASE_AUTHORIZATION_RECEIPT':
            return self._receipt(result, ready)
        check(result.get('ngo_id') == self.scope['ngo_id']
              and result.get('request_id') == self.request
              and result.get('snapshot_id') == ready['snapshot_id'], 'EXACT_CLIENT_RECEIPT_SCOPE_MISMATCH')
        return result  # NOT_FOUND never clears the durable send marker.
