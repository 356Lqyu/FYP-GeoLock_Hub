"""Opt-in exact-scope pilot. Existing planning and database authority are reused.

No method is invoked by opening a saved result or by the normal combined flow.
All credentials stay in the verified session, never in the durable journal.
"""
from datetime import timedelta
import hashlib
import re

from ..integration.worker import timestamp
from .errors import check, WorkerError
from .transport import uuid, encode
from .orchestrator import step_id


class ExactRouteWorkflow:
    def __init__(self, worker):
        self.worker = worker
        self.journal = worker.journal

    def _failure(self, request, phase, error):
        code = error.code if isinstance(error, WorkerError) else 'EXACT_STAGE_OUTCOME_UNCERTAIN'
        if not re.fullmatch(r'[A-Z][A-Z0-9_]{1,99}', code):
            code = 'EXACT_STAGE_OUTCOME_UNCERTAIN'
        self.journal.save(request, 'exact_' + phase + '_failure', {
            'error_code': code, 'exception_category': type(error).__name__})

    @staticmethod
    def scope(value):
        check(isinstance(value, dict) and set(value) == {
            'ngo_id', 'vehicle_id', 'policy_id', 'graph_id', 'task_ids',
            'horizon_minutes', 'dispatch_margin_minutes'}, 'INVALID_EXACT_SCOPE', 400)
        result = {k: uuid(value[k]) for k in ('ngo_id', 'vehicle_id', 'policy_id', 'graph_id')}
        tasks = value['task_ids']
        check(isinstance(tasks, list) and len(tasks) == 3, 'THREE_EXACT_TASKS_REQUIRED', 400)
        result['task_ids'] = sorted(uuid(t) for t in tasks)
        check(len(set(result['task_ids'])) == 3, 'DUPLICATE_EXACT_TASK', 400)
        # Pilot admission bounds are explicit, not silently changed DB policy.
        check(type(value['horizon_minutes']) is int and value['horizon_minutes'] == 240
              and type(value['dispatch_margin_minutes']) is int
              and value['dispatch_margin_minutes'] == 15, 'PILOT_POLICY_MISMATCH', 400)
        result.update(horizon_minutes=240, dispatch_margin_minutes=15)
        return result

    def preflight(self, session, scope, request):
        """Authenticated protected reads only; never creates a snapshot."""
        check(session.user_id == scope['ngo_id'], 'EXACT_SCOPE_NOT_OWNED', 403)
        self.worker.automatic_authorization_capabilities(session, request)
        overview = session.rpc('get_my_routing_overview')
        check(overview.get('ngo_id') == session.user_id
              and overview.get('policy_id') == scope['policy_id']
              and overview.get('authorization_enforced') is True, 'EXACT_POLICY_OR_AUTHORITY_MISMATCH')
        admitted = {t['task_id']: t for t in overview['eligible_tasks']}
        check(set(scope['task_ids']) <= set(admitted), 'EXACT_TASK_NOT_ADMITTED')
        fleet = session.rpc('list_my_vehicles')
        matches = [v for v in fleet['vehicles'] if v['vehicle_id'] == scope['vehicle_id']]
        check(len(matches) == 1, 'EXACT_VEHICLE_NOT_AVAILABLE')
        vehicle = matches[0]
        check(vehicle.get('ngo_user_id') == session.user_id and vehicle.get('active_flag') is True
              and vehicle.get('available_for_planning') is True
              and vehicle.get('eligible_for_planning') is True, 'EXACT_VEHICLE_NOT_AVAILABLE')
        check(0 < vehicle['max_route_duration_min'] <= scope['horizon_minutes'], 'INVALID_ROUTE_HORIZON')
        check(sum(admitted[t]['load_kg'] for t in scope['task_ids']) <= vehicle['payload_capacity_kg'],
              'EXACT_CAPACITY_EXCEEDED')
        cards = {c['claim_id']: c for c in session.rpc('get_my_claim_cards_v2')}
        now = self.worker.planner.now()
        for task_id in scope['task_ids']:
            task = admitted[task_id]
            card = cards.get(task['claim_id'])
            check(card is not None and card.get('claim_status') == 'ACTIVE'
                  and card.get('lease_status') == 'ACTIVE' and card.get('task_status') == 'CONFIRMED'
                  and not card.get('lease_recovery_pending', False), 'EXACT_CLAIM_NOT_ACTIVE')
            check(timestamp(card['lease_expires_at']) > now + timedelta(minutes=255),
                  'EXACT_LEASE_BELOW_ADMISSION')
        return vehicle

    def _snapshot(self, snapshot, scope, request):
        raw = snapshot['body']
        check(snapshot['ngo_id'] == scope['ngo_id'] and snapshot['request_id'] == request
              and snapshot['policy_id'] == scope['policy_id'], 'EXACT_SNAPSHOT_BINDING_MISMATCH')
        check(raw['ngo']['user_id'] == scope['ngo_id'] and raw['ngo']['active_flag'] is True
              and raw['ngo']['location_verified_at'] is not None, 'EXACT_NGO_NOT_ACTIVE')
        vehicles = raw['vehicles']
        check(raw.get('selected_vehicle_ids') == [scope['vehicle_id']]
              and len(vehicles) == 1 and vehicles[0]['vehicle_id'] == scope['vehicle_id']
              and vehicles[0]['ngo_user_id'] == scope['ngo_id']
              and vehicles[0]['depot_road_node_id'] == raw['ngo']['road_node_id'], 'EXACT_VEHICLE_BINDING_MISMATCH')
        check(raw['policy']['horizon_minutes'] == 240 and raw['policy']['dispatch_margin_minutes'] == 15,
              'EXACT_POLICY_BINDING_MISMATCH')

    def plan(self, session, request_id, proposed_scope):
        request, scope = uuid(request_id), self.scope(proposed_scope)
        check(session.user_id == scope['ngo_id'], 'EXACT_SCOPE_NOT_OWNED', 403)
        with self.journal.operation_lock(request):
            self.journal.save(request, 'exact_scope', scope)
            # Repeated calls only return an already verified advisory result.
            ready = self.journal.get(request, 'exact_ready')
            if ready is not None:
                return dict(kind='EXACT_CANDIDATE_VERIFIED', dispatch_authority_issued=False, **ready)
            check(self.journal.get(request, 'exact_snapshot_send') is None,
                  'EXACT_OPERATION_ALREADY_ATTEMPTED_RECONCILE_ONLY')
            self.preflight(session, scope, request)
            self.journal.save(request, 'exact_snapshot_send', {'request_id': request})
            try:
                snapshot = session.rpc('begin_my_routing_snapshot', {
                    'p_request': request, 'p_policy': scope['policy_id'],
                    'p_vehicle_ids': [scope['vehicle_id']]})
            except Exception as error:
                self._failure(request, 'snapshot', error)
                raise
            sid = uuid(snapshot['snapshot_id'])
            self.journal.save(request, 'exact_snapshot', {'snapshot_id': sid})
            self._snapshot(snapshot, scope, request)
            try:
                result = self.worker.plan(session, sid, request)  # Planning-only + independent validator.
                ready = self.verify(session, request, sid, scope, result)
            except Exception as error:
                self._failure(request, 'planning', error)
                raise
            self.journal.save(request, 'exact_ready', ready)
            return dict(kind='EXACT_CANDIDATE_VERIFIED', dispatch_authority_issued=False, **ready)

    def verify(self, session, request, sid, scope, result):
        bundle = self.worker.planner.call('read_routing_snapshot_bundle', sid)
        snapshot = bundle['snapshot']
        self._snapshot(snapshot, scope, request)
        check(snapshot['snapshot_id'] == sid and bundle['matrix']['graph_id'] == scope['graph_id']
              and snapshot['matrix_id'] == bundle['matrix']['matrix_id'], 'EXACT_GRAPH_OR_MATRIX_MISMATCH')
        self.worker.fresh(snapshot, session)
        check(result.get('ngo_id') == session.user_id and result.get('snapshot_id') == sid
              and result.get('outcome') == 'CANDIDATE_READY'
              and result.get('validation_status') == 'ATTESTED'
              and result.get('dispatch_authority_issued') is False, 'EXACT_ATTESTATION_REQUIRED')
        cid = uuid(result.get('candidate_id'))
        witness = self.journal.get(sid, 'independent_attestation')
        check(witness is not None and witness['candidate_id'] == cid and witness['snapshot_id'] == sid
              and witness['snapshot_digest'] == snapshot['digest']
              and witness['matrix_digest'] == bundle['matrix']['digest']
              and witness['policy_id'] == scope['policy_id']
              and bool(re.fullmatch('[a-f0-9]{64}', witness['candidate_digest']))
              and bool(witness['validator_build']), 'EXACT_ATTESTATION_BINDING_MISMATCH')
        proposed = [m['plan'] for m in result['methods'] if m['method'] == 'proposed']
        check(len(proposed) == 1, 'EXACT_PROPOSED_REQUIRED')
        plan = proposed[0]
        computed = self.journal.get(sid, 'computed')
        check(computed is not None and computed['payload'] is not None
              and encode(computed['payload']['plan']) == encode(plan)
              and witness.get('candidate_payload_sha256') == hashlib.sha256(encode(computed['payload']).encode()).hexdigest(), 'EXACT_CANDIDATE_PAYLOAD_MISMATCH')
        check(plan['method'] == 'proposed' and plan['feasible'] is True
              and plan['dispatch_authority_issued'] is False, 'EXACT_FEASIBLE_PLAN_REQUIRED')
        check(not plan['unserved_tasks'], 'EXACT_UNSERVED_TASKS')
        routes = plan['routes']
        check(len(routes) == 1 and routes[0]['vehicle_id'] == scope['vehicle_id'], 'EXACT_WRONG_VEHICLE')
        stops = routes[0]['stops']
        served = [s['task_id'] for s in stops]
        check(len(served) == 3 and sorted(served) == scope['task_ids'], 'EXACT_TASK_SET_MISMATCH')
        observations = {o['task']['task_id']: o for o in snapshot['body']['observations']}
        check(set(scope['task_ids']) <= set(observations), 'EXACT_TASK_BINDING_MISMATCH')
        for stop in stops:
            observation = observations[stop['task_id']]
            check(observation['task']['ngo_user_id'] == session.user_id
                  and observation['claim']['ngo_user_id'] == session.user_id
                  and str(observation['task']['pickup_road_node_id']) == stop['road_node_id'],
                  'EXACT_TASK_BINDING_MISMATCH')
        self.preflight(session, scope, request)  # Includes fresh 255-minute admission.
        return dict(ngo_id=session.user_id, request_id=request, snapshot_id=sid, candidate_id=cid,
                    policy_id=scope['policy_id'], vehicle_id=scope['vehicle_id'],
                    authorization_request_id=step_id(sid, 'authorize-auto-now'),
                    task_ids=scope['task_ids'], snapshot_digest=snapshot['digest'],
                    candidate_digest=witness['candidate_digest'], matrix_digest=bundle['matrix']['digest'],
                    validation_status='ATTESTED', presentation=result['presentation'])

    def authorize(self, session, request_id, proposed_scope):
        request, scope = uuid(request_id), self.scope(proposed_scope)
        check(session.user_id == scope['ngo_id'], 'EXACT_SCOPE_NOT_OWNED', 403)
        with self.journal.operation_lock(request):
            check(self.journal.get(request, 'exact_scope') == scope, 'EXACT_SCOPE_CHANGED')
            ready = self.journal.get(request, 'exact_ready')
            check(ready is not None, 'EXACT_VERIFIED_PLAN_REQUIRED')
            sid, aid = ready['snapshot_id'], ready['authorization_request_id']
            receipt = self.worker._authorization_receipt(session, sid, request, aid)
            if receipt is not None:
                ids = receipt['authorization'].get('route_ids')
                check(receipt['authorization']['candidate_id'] == ready['candidate_id']
                      and isinstance(ids, list) and len(ids) == 1 and isinstance(ids[0], str)
                      and bool(ids[0]), 'EXACT_RECEIPT_CONFLICT')
                return receipt  # Receipt replay is read-only, including after lease expiry.
            check(self.journal.get(request, 'exact_authorization_send') is None,
                  'EXACT_AUTHORIZATION_UNCERTAIN_RECONCILE_ONLY')
            result = self.journal.read_saved_result(sid, session.user_id, request)
            verified = self.verify(session, request, sid, scope, result)
            check(verified == ready, 'EXACT_READY_BINDING_CHANGED')
            payload = dict(p_request=aid, p_candidate=ready['candidate_id'], p_depart_at=None)
            self.journal.save(request, 'exact_authorization_request', payload)
            self.journal.save(request, 'exact_authorization_send', {'request_id': aid})
            # Every failure after this durable marker is held; never resubmit.
            try:
                authorized = session.rpc('authorize_my_routing_candidate', payload)
            except Exception as error:
                self._failure(request, 'authorization', error)
                raise
            ids = authorized.get('route_ids') if isinstance(authorized, dict) else None
            check(isinstance(authorized, dict) and authorized.get('candidate_id') == ready['candidate_id']
                  and authorized.get('snapshot_id') == sid and authorized.get('departure_mode') == 'AUTO_NOW'
                  and isinstance(ids, list) and len(ids) == 1 and isinstance(ids[0], str)
                  and bool(ids[0]), 'EXACT_AUTHORIZATION_OUTCOME_UNCERTAIN', 503)
            self.journal.save(request, 'exact_authorization_receipt', authorized)
            return dict(kind='DATABASE_AUTHORIZATION_RECEIPT', ngo_id=session.user_id,
                        request_id=request, snapshot_id=sid, authorization_request_id=aid, authorization=authorized)
