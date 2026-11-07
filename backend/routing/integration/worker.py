"""Rebuild solver inputs from sealed source facts, independently of candidates.

Database digests are opaque PostgreSQL jsonb hashes, distinct from Phase A's
canonical JSON hashes. This module checks relationships, not DB authenticity.
Only a future trusted RPC transport can attest where the bundle came from.
"""
from dataclasses import dataclass
from datetime import datetime, timedelta
import copy
import re

from ..contract import VERSION, DEV_PROJECT
from ..phase_c2 import prepare_input, evaluate
from ..phase_c2.matrices import digest, require
from ..phase_b.models import ExecutionConfig, Plan, Route, Stop
from ..phase_b.validation import validate_plan


@dataclass(frozen=True)
class IntegrationInput:
    snapshot: object
    excluded_vehicles: tuple
    excluded_observations: tuple


def timestamp(value):
    result = datetime.fromisoformat(value.replace('Z', '+00:00'))
    require(result.tzinfo is not None, 'TIMEZONE_REQUIRED')
    return result


def token(value):
    require(type(value) is str and re.fullmatch('[0-9a-f]{64}', value) is not None, 'DATABASE_DIGEST_REQUIRED')


def prepare_bundle(bundle):
    """Fail closed on incomplete exports. Fleet/hold selection is DB snapshot-owned."""
    bundle = copy.deepcopy(bundle)
    s, m = bundle['snapshot'], bundle['matrix']
    token(s['digest']); token(m['digest'])
    require(s['sealed_at'] is not None and s['matrix_id'] == m['matrix_id'], 'UNSEALED_OR_WRONG_MATRIX')
    raw = s['body']; ngo = raw['ngo']; policy = raw['policy']; cut = timestamp(s['cutoff'])
    require(ngo['user_id'] == s['ngo_id'] and ngo['role'] == 'NGO', 'INVALID_SNAPSHOT_OWNER')
    require(ngo['active_flag'] is True and ngo['location_verified_at'] is not None, 'UNVERIFIED_DEPOT')
    require(type(policy['mandatory']) is bool, 'EXPLICIT_POLICY_REQUIRED')
    matrix = m['body']
    require(matrix['source_kind'] == 'OPERATIONAL_ROAD_NETWORK', 'OPERATIONAL_MATRIX_REQUIRED')
    net = matrix['network_snapshot_id']

    def location(identity, node, lat, lon, source):
        return dict(location_id=str(identity), road_node_id=str(node), network_snapshot_id=net,
                    latitude=lat, longitude=lon, state_token=digest(source))

    depot = location(s['ngo_id'], ngo['road_node_id'], ngo['latitude'], ngo['longitude'], ngo)
    tasks = []; excluded = []
    horizon = cut + timedelta(minutes=policy['horizon_minutes'])
    for obs in raw['observations']:
        t, c, le, listing = (obs[k] for k in ('task', 'claim', 'lease', 'listing'))
        require(t['ngo_user_id'] == s['ngo_id'] == c['ngo_user_id'], 'FOREIGN_TASK')
        require(t['claim_id'] == c['claim_id'] == le['claim_id'] and t['listing_id'] == listing['listing_id'] == c['listing_id'], 'BROKEN_SOURCE_JOIN')
        donations = obs['donations']; require(bool(donations), 'MISSING_DONATIONS')
        direct = listing['source_type'] == 'DIRECT_DONATION'
        require(direct or listing['source_type'] == 'HUB_BATCH', 'INVALID_SOURCE_TYPE')
        require(all(d['collection_path']==('DIRECT_PICKUP' if direct else 'HUB_COLLECTION') for d in donations), 'INVALID_COLLECTION_PATH')
        if direct:
            require(len(donations) == 1 and donations[0]['donation_id'] == listing['donation_id'], 'BROKEN_DONATION_JOIN')
            d = donations[0]
            authorized = location(d['donation_id'], d['pickup_road_node_id'], d['latitude'], d['longitude'], d)
            batch = None
        else:
            b, h, inventory = obs['batch'], obs['hub'], obs['inventory']
            require(b['batch_id'] == listing['batch_id'] and b['hub_id'] == h['hub_id'], 'BROKEN_HUB_JOIN')
            require(b['batch_donation_count'] == len(donations) and b['batch_weight_kg'] == listing['listing_weight_kg'], 'BATCH_TOTAL_MISMATCH')
            require(h['active_flag'] is True and len(inventory) == len(donations), 'INVALID_HUB_INVENTORY')
            require({x['donation_id'] for x in inventory} == {d['donation_id'] for d in donations}, 'INVALID_HUB_INVENTORY')
            require(all(x['inventory_status'] == 'BATCHED' and x['hub_id'] == h['hub_id'] for x in inventory), 'INVALID_HUB_INVENTORY')
            authorized = location(h['hub_id'], h['road_node_id'], h['latitude'], h['longitude'], h)
            batch = dict(batch_id=b['batch_id'], hub_id=h['hub_id'], batch_version=b['batch_version'],
                         batch_status=b['batch_status'], inventory_status='BATCHED', member_count=len(donations), state_token=digest(obs))
        pickup = location(authorized['location_id'], listing['pickup_road_node_id'], listing['pickup_latitude'], listing['pickup_longitude'], listing)
        # Phase A requires exact authorized location identity and coordinates.
        require(pickup['road_node_id'] == authorized['road_node_id'] and t['pickup_road_node_id'] == pickup['road_node_id'], 'UNAUTHORIZED_PICKUP_NODE')
        require((pickup['latitude'], pickup['longitude']) == (authorized['latitude'], authorized['longitude']), 'UNAUTHORIZED_PICKUP_COORDINATES')
        pickup = authorized.copy()
        starts = [cut] + [timestamp(d['availability_start']) for d in donations if d['availability_start'] is not None]
        ends = [horizon] + [timestamp(d['availability_end']) for d in donations if d['availability_end'] is not None]
        if listing['listing_expires_at'] is not None: ends.append(timestamp(listing['listing_expires_at']))
        service=policy['direct_service_minutes' if direct else 'hub_service_minutes']
        if min(ends)-max(starts)<timedelta(minutes=service) or min(ends)<=max(starts):
            excluded.append((t['task_id'],'NO_SERVICE_WINDOW_IN_HORIZON'))
            continue
        tasks.append(dict(task_id=t['task_id'], ngo_id=t['ngo_user_id'], claim_id=t['claim_id'], claim_ngo_id=c['ngo_user_id'],
            lease_id=le['lease_id'], listing_id=t['listing_id'], source_type=listing['source_type'], task_status=t['task_status'],
            claim_status=c['claim_status'], lease_status=le['lease_status'], listing_status=listing['listing_status'],
            created_at=t['created_at'], lease_issued_at=le['issued_at'], lease_expires_at=le['expires_at'],
            listing_expires_at=listing['listing_expires_at'], listing_version=listing['listing_version'], task_state_token=digest(t),
            claim_state_token=digest(c), lease_state_token=digest(le), pickup=pickup, authorized_pickup=authorized,
            weight_kg=t['load_kg'], listing_weight_kg=listing['listing_weight_kg'],
            time_window=dict(start=max(starts).isoformat(), end=min(ends).isoformat(), provenance='Explicit policy '+s['policy_id']+' intersected with captured donor/listing windows'),
            service_minutes=service, mandatory=policy['mandatory'],
            has_route_assignment=obs['has_route_assignment'], reconciliation_blocked=c['claim_status']=='RECONCILIATION_REQUIRED',
            donations=[dict(donation_id=d['donation_id'], donation_status=d['donation_status'], state_token=digest(d)) for d in donations], batch=batch))
    # Preserve the Phase A scenario contract field. The optimizer's active
    # objective is versioned explicitly on Plan.optimization_objective.
    payload = dict(schema_version=VERSION, planning_run_id=s['snapshot_id'], scenario_id=s['snapshot_id'],
        source=dict(kind='OPERATIONAL_SNAPSHOT', project_ref=DEV_PROJECT,
                    provenance='Proposed sealed DB export; authenticity must be established by transport', evidence_ref='snapshot:'+s['digest']),
        ngo_id=s['ngo_id'], ngo_active=ngo['active_flag'], ngo_location_generation=ngo['location_generation'],
        ngo_location_verified_at=ngo['location_verified_at'], cutoff=s['cutoff'],
        configuration=dict(version=s['policy_id'], currency='RM', planning_horizon_minutes=policy['horizon_minutes'],
            dispatch_margin_minutes=policy['dispatch_margin_minutes'], objective='MIN_UNSERVED_THEN_FIXED_PLUS_DISTANCE_COST', time_window_policy='SERVICE_COMPLETION_WITHIN_WINDOW'),
        depot=depot, route_start_location_id=depot['location_id'], route_end_location_id=depot['location_id'],
        vehicles=[], tasks=tasks, matrix=matrix, solver=policy['solver'])
    prepared=prepare_input(payload, fleet_rows=raw['vehicles'], held_vehicle_ids=[])
    return IntegrationInput(prepared.snapshot,prepared.excluded_vehicles,tuple(sorted(excluded)))


def solve_bundle(bundle):
    prepared = prepare_bundle(bundle)
    comparison = evaluate(prepared, ExecutionConfig(**bundle['snapshot']['body']['policy']['execution']))
    return comparison


def decode_plan(value):
    """Exact dataclass fields and independent validation; no arbitrary constructor."""
    value = copy.deepcopy(value)
    value['config'] = ExecutionConfig(**value['config'])
    routes = []
    for route in value['routes']:
        route['stops'] = tuple(Stop(**s) for s in route['stops'])
        routes.append(Route(**route))
    value['routes'] = tuple(routes)
    value['unserved_tasks'] = tuple(value['unserved_tasks'])
    value['unserved_reasons'] = tuple(tuple(x) for x in value['unserved_reasons'])
    value['solver_statuses'] = tuple(value.get('solver_statuses', ()))
    return Plan(**value)


def validate_work_item(work_item, *, validator_build):
    """A separate worker rebuilds inputs; it never invokes the optimizer."""
    require(bool(validator_build.strip()), 'VALIDATOR_BUILD_REQUIRED')
    prepared = prepare_bundle(work_item)
    candidate = work_item['candidate']; token(candidate['digest'])
    require(candidate['snapshot_id'] == work_item['snapshot']['snapshot_id'], 'WRONG_CANDIDATE_SNAPSHOT')
    plan = decode_plan(candidate['body']['plan'])
    require(plan.method == 'proposed' and not plan.dispatch_authority_issued, 'ADVISORY_PROPOSED_ONLY')
    require(plan.config == ExecutionConfig(**work_item['snapshot']['body']['policy']['execution']), 'OBJECTIVE_POLICY_MISMATCH')
    result = validate_plan(prepared.snapshot, plan)
    require(result.valid and result.feasible and plan.feasible and bool(plan.routes), 'INDEPENDENT_VALIDATION_FAILED')
    return dict(candidate_digest=candidate['digest'], snapshot_digest=work_item['snapshot']['digest'],
                matrix_digest=work_item['matrix']['digest'], input_sha256=prepared.snapshot.sha256,
                matrix_sha256=prepared.snapshot.matrix_sha256, validator_build=validator_build,
                valid=result.valid, feasible=result.feasible, dispatch_authority_issued=False)
