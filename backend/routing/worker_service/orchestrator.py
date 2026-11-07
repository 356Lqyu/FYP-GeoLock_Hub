"""Trusted source -> matrix -> four methods -> candidate -> independent attest.

No start/complete/claim/ownership/table-write API exists in this worker.
"""
from dataclasses import asdict
import hashlib
from datetime import timedelta
from uuid import UUID, uuid5

from ..integration import solve_bundle
from ..integration.presentation import planning_response, proposed_presentation
from ..integration.worker import timestamp, decode_plan
from .errors import WorkerError, check
from .transport import uuid, encode


def step_id(snapshot,label):
    return str(uuid5(UUID(snapshot),'geolock-worker-v1:'+label))


class RoutingWorker:
    def __init__(self, planner, graph, validator, journal, *, max_age_seconds=300, solve=solve_bundle, observe=None):
        self.planner,self.graph,self.validator,self.journal=planner,graph,validator,journal
        self.max_age,self.solve=max_age_seconds,solve
        self.observe=observe

    def fresh(self,snapshot,session):
        now=self.planner.now();cut=timestamp(snapshot['cutoff'])
        check(timedelta(0)<=now-cut<=timedelta(seconds=self.max_age),'SNAPSHOT_STALE',409)
        check(now<cut+timedelta(minutes=snapshot['body']['policy']['horizon_minutes']),'SNAPSHOT_STALE',409)
        fleet=session.rpc('list_my_vehicles')
        current={v['vehicle_id']:v for v in fleet['vehicles']}
        selected=snapshot['body']['vehicles']
        check(bool(selected),'NO_ELIGIBLE_VEHICLES',422)
        for v in selected:
            live=current.get(v['vehicle_id'])
            check(live is not None and live['ngo_user_id']==session.user_id and live['eligible_for_planning'] is True
                  and live['vehicle_version']==v['vehicle_version'],'SNAPSHOT_STALE',409)
        check(bool(snapshot['body']['observations']),'NO_PICKUP_TASKS',422)
        cards={c['claim_id']:c for c in session.rpc('get_my_claim_cards_v2')}
        for observation in snapshot['body']['observations']:
            # Ineligible/expired source observations are retained for engine
            # exclusions; any formerly ACTIVE source changing is a stale plan.
            claim=observation['claim']; task=observation['task']; lease=observation['lease']
            if claim['claim_status']!='ACTIVE' or lease['lease_status']!='ACTIVE' or timestamp(lease['expires_at'])<=cut: continue
            card=cards.get(claim['claim_id'])
            check(card is not None and card['claim_status']=='ACTIVE' and card['lease_status']=='ACTIVE'
                  and card['lease_id']==lease['lease_id'] and card['task_status']==task['task_status']
                  and timestamp(card['lease_expires_at'])>now,'SNAPSHOT_STALE',409)

    def plan(self, session, snapshot_id, request_id):
        sid,rid=uuid(snapshot_id),uuid(request_id)
        def stage(name):
            if self.observe:self.observe(dict(stage=name,snapshot_id=sid,request_id=rid))
        stage('read_pending_snapshot')
        snapshot=self.planner.call('read_pending_routing_snapshot',sid)
        check(snapshot is not None and snapshot['snapshot_id']==sid and snapshot['ngo_id']==session.user_id,'SNAPSHOT_NOT_OWNED',403)
        check(snapshot['request_id']==rid,'REQUEST_SNAPSHOT_MISMATCH',409)
        with self.journal.claim(sid,session.user_id,rid):
            stage('verify_snapshot_freshness')
            self.fresh(snapshot,session)
            result=self.journal.get(sid,'result')
            if result is not None: return result
            if snapshot['matrix_id'] is None:
                matrix=self.journal.get(sid,'matrix')
                if matrix is None:
                    stage('build_road_matrix')
                    nodes={str(snapshot['body']['ngo']['road_node_id'])}
                    nodes.update(str(o['task']['pickup_road_node_id']) for o in snapshot['body']['observations'])
                    matrix=self.journal.save(sid,'matrix',self.graph.matrix(sorted(nodes)))
                self.fresh(snapshot,session)  # cold graph builds may outlive cutoff
                stage('store_and_seal_matrix')
                matrix_id=self.graph.rpc.call('store_routing_matrix',step_id(sid,'matrix:'+self.graph.graph_id),self.graph.graph_id,matrix)
                snapshot=self.planner.call('seal_routing_snapshot',sid,matrix_id)
            bundle=self.planner.call('read_routing_snapshot_bundle',sid)
            check(bundle is not None and bundle['snapshot']['ngo_id']==session.user_id
                  and bundle['snapshot']['digest']==snapshot['digest'] and bundle['matrix']['graph_id']==self.graph.graph_id,'SEALED_BUNDLE_MISMATCH',409)
            computed=self.journal.get(sid,'computed')
            if computed is None:
                stage('four_method_optimization')
                comparison=self.solve(bundle)
                # Phase B emits microsecond offsets from departure_us=0, with
                # snapshot.cutoff as the NOMINAL departure. PostgreSQL validates
                # this schedule and retimes its route order at actual departure.
                response=planning_response(bundle,comparison)
                response['timing_basis']='NOMINAL_DEPARTURE_AT_SNAPSHOT_CUTOFF'
                payload=None if comparison.proposed_candidate is None else {'plan':asdict(comparison.proposed_candidate)}
                computed=self.journal.save(sid,'computed',{'response':response,'payload':payload})
            self.fresh(snapshot,session)
            if computed['payload'] is None:
                stage('infeasible')
                response=dict(computed['response'],outcome='INFEASIBLE',validation_status='LOCAL_ONLY')
                return self.journal.save(sid,'result',response)
            stage('submit_candidate')
            candidate=self.planner.call('submit_routing_candidate',step_id(sid,'candidate'),sid,computed['payload'])
            check(candidate['snapshot_id']==sid and candidate['body']==computed['payload'],'CANDIDATE_PAYLOAD_MISMATCH',409)
            self.fresh(snapshot,session)
            stage('independent_validation')
            attestation=self.validator.validate(candidate['candidate_id'],sid,session.user_id)
            check(attestation['candidate_id']==candidate['candidate_id'] and attestation['attested_digest']==candidate['digest'],'VALIDATOR_BINDING_MISMATCH',422)
            # Immutable local witness for the separate exact-scope pilot gate.
            # No extra database writes and no change to the combined response.
            self.journal.save(sid,'independent_attestation',dict(
                candidate_id=candidate['candidate_id'],candidate_digest=candidate['digest'],
                candidate_payload_sha256=hashlib.sha256(encode(candidate['body']).encode()).hexdigest(),
                snapshot_id=sid,snapshot_digest=snapshot['digest'],
                matrix_digest=bundle['matrix']['digest'],policy_id=snapshot['policy_id'],
                validator_build=attestation.get('validator_build')))
            response=dict(computed['response'],candidate_id=candidate['candidate_id'],validation_status='ATTESTED',outcome='CANDIDATE_READY')
            # This is still advisory. It creates no reservations or authority.
            stage('candidate_ready')
            return self.journal.save(sid,'result',response)

    def authorize(self, session, request_id, candidate_id, departure):
        rid,cid=uuid(request_id),uuid(candidate_id)
        timestamp(departure)
        result=session.rpc('authorize_my_routing_candidate',{'p_request':rid,'p_candidate':cid,'p_depart_at':departure})
        check(isinstance(result,dict) and result.get('candidate_id')==cid and bool(result.get('route_ids')),'AUTHORIZATION_NOT_CONFIRMED',502)
        return result  # exact PostgreSQL receipt; never mint a success flag

    def _owned_operation(self, session, snapshot_id, request_id):
        sid,rid=uuid(snapshot_id),uuid(request_id)
        snapshot=self.planner.call('read_pending_routing_snapshot',sid)
        check(snapshot is not None and snapshot['ngo_id']==session.user_id and snapshot['request_id']==rid,
              'NOT_SNAPSHOT_OWNER',403)
        return sid,rid,step_id(sid,'authorize-auto-now')

    def automatic_authorization_capabilities(self, session, request_id):
        lookup=session.rpc('get_my_routing_authorization_receipt',{'p_request':uuid(request_id)})
        check(isinstance(lookup,dict) and lookup.get('contract')=='geolock.routing-auto-now.v1'
              and lookup.get('ngo_id')==session.user_id,'AUTOMATIC_AUTHORIZATION_CONTRACT_UNAVAILABLE',503)
        return dict(contract='geolock.routing-auto-now.v1',ngo_id=session.user_id,automatic_departure=True)

    def _authorization_receipt(self, session, sid, rid, aid):
        lookup=session.rpc('get_my_routing_authorization_receipt',{'p_request':aid})
        check(isinstance(lookup,dict) and lookup.get('contract')=='geolock.routing-auto-now.v1'
              and lookup.get('ngo_id')==session.user_id and lookup.get('request_id')==aid,
              'AUTOMATIC_AUTHORIZATION_CONTRACT_UNAVAILABLE',503)
        if lookup.get('outcome')=='NOT_FOUND': return None
        receipt=lookup.get('result',{})
        check(lookup.get('outcome')=='FOUND' and receipt.get('snapshot_id')==sid
              and receipt.get('departure_mode')=='AUTO_NOW' and bool(receipt.get('route_ids')),
              'AUTHORIZATION_RECEIPT_CONFLICT',409)
        return dict(kind='DATABASE_AUTHORIZATION_RECEIPT',ngo_id=session.user_id,snapshot_id=sid,
                    request_id=rid,authorization_request_id=aid,authorization=receipt)

    def authorization_result(self, session, snapshot_id, request_id):
        """Read-only reconciliation. Absence NEVER triggers a write or replanning."""
        sid,rid,aid=self._owned_operation(session,snapshot_id,request_id)
        receipt=self._authorization_receipt(session,sid,rid,aid)
        if receipt is not None: return receipt
        terminal=self.journal.get(sid,'automatic_authorization_failure')
        saved=self.journal.get(sid,'result')
        state='REJECTED' if terminal else 'INFEASIBLE' if saved and saved.get('outcome')=='INFEASIBLE' else None
        return dict(kind='AUTHORIZATION_UNCONFIRMED',ngo_id=session.user_id,
            snapshot_id=sid,request_id=rid,authorization_request_id=aid,
            operation_terminal=state,failure_code=terminal.get('code') if terminal else None,
            message='No committed receipt visible. This does not prove rollback.')

    def plan_and_authorize(self, session, snapshot_id, request_id):
        sid,rid,aid=self._owned_operation(session,snapshot_id,request_id)
        with self.journal.operation_lock(aid):
            # Capabilities and prior DB commit are checked BEFORE calling the planner.
            receipt=self._authorization_receipt(session,sid,rid,aid)
            if receipt is not None: return receipt
            failure=self.journal.get(sid,'automatic_authorization_failure')
            if failure is not None: raise WorkerError(failure['code'],409)
            intent=self.journal.get(sid,'automatic_authorization_intent')
            result=self.journal.get(sid,'result')
            check(intent is not None or result is None,'SAVED_ADVISORY_RESULT_NOT_AUTO_AUTHORIZABLE',409)
            self.journal.save(sid,'automatic_authorization_intent',
                dict(ngo_id=session.user_id,request_id=rid,authorization_request_id=aid))
            if result is None:
                try: result=self.plan(session,sid,rid)
                except WorkerError as error:
                    if 400<=error.status<500 and not error.retryable:
                        self.journal.save(sid,'automatic_authorization_failure',{'code':error.code})
                    raise
            if result.get('outcome')=='INFEASIBLE': return result
            check(result.get('outcome')=='CANDIDATE_READY' and result.get('validation_status')=='ATTESTED'
                  and result.get('dispatch_authority_issued') is False,'ATTESTED_CANDIDATE_REQUIRED',409)
            candidate=uuid(result.get('candidate_id'))
            payload=dict(p_request=aid,p_candidate=candidate,p_depart_at=None)
            self.journal.save(sid,'automatic_authorization_request',payload)
            # Exactly one call. A transport error is left uncertain; no internal retry.
            try: authorized=session.rpc('authorize_my_routing_candidate',payload)
            except WorkerError as error:
                if 400<=error.status<500 and not error.retryable:
                    self.journal.save(sid,'automatic_authorization_failure',{'code':error.code})
                raise
            check(isinstance(authorized,dict) and authorized.get('candidate_id')==candidate
                  and authorized.get('snapshot_id')==sid and authorized.get('departure_mode')=='AUTO_NOW'
                  and bool(authorized.get('route_ids')),'AUTHORIZATION_OUTCOME_UNKNOWN',503)
            self.journal.save(sid,'automatic_authorization_receipt',authorized)
            return dict(kind='DATABASE_AUTHORIZATION_RECEIPT',ngo_id=session.user_id,snapshot_id=sid,
                request_id=rid,authorization_request_id=aid,authorization=authorized,planning=result)

    def saved_result(self, session, snapshot_id, request_id):
        """Display a historical receipt without planning, writes or new attestation."""
        sid,rid=uuid(snapshot_id),uuid(request_id)
        result=self.journal.read_saved_result(sid,session.user_id,rid)
        check(result.get('ngo_id')==session.user_id and result.get('snapshot_id')==sid,'SAVED_RESULT_NOT_OWNED',404)
        bundle=self.planner.call('read_routing_snapshot_bundle',sid)
        check(bundle is not None and bundle['snapshot']['ngo_id']==session.user_id
              and bundle['snapshot']['request_id']==rid,'SAVED_RESULT_NOT_OWNED',404)
        proposed=next((m for m in result['methods'] if m['method']=='proposed'),None)
        check(proposed is not None,'SAVED_RESULT_NOT_READY',404)
        result['presentation']=proposed_presentation(bundle,decode_plan(proposed['plan']))
        result['saved_result_display_only']=True
        return result  # No freshness claim. Protected authorization rechecks live state.
