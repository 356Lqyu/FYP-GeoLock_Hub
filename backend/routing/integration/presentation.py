"""Flutter wire projection of REAL engine results, never a dispatch response.

The future authenticated worker transport must supply the DB-owned bundle and
candidate receipt. This function does not connect to Supabase or attest a plan.
"""
from dataclasses import asdict
from decimal import Decimal
from ..phase_b import OPERATIONAL_METHODS
from ..planner.matrices import require


def proposed_presentation(bundle, plan):
    """Display-only projection. Never changes a plan, matrix or attestation."""
    raw = bundle['snapshot']['body']
    ngo = raw['ngo']
    vehicles = {v['vehicle_id']: v for v in raw['vehicles']}
    observations = {o['task']['task_id']: o for o in raw['observations']}
    matrix = bundle['matrix']['body']
    indices = {str(n): i for i, n in enumerate(matrix['node_order'])}
    depot = dict(road_node_id=str(ngo['road_node_id']), latitude=ngo['latitude'], longitude=ngo['longitude'])
    routes = []
    for route in plan.routes:
        stops = []
        nodes = [route.start_node_id, *(s.road_node_id for s in route.stops), route.end_node_id]
        km = sum((Decimal(str(matrix['distance_km'][indices[a]][indices[b]])) for a, b in zip(nodes, nodes[1:])), Decimal(0))
        for ordinal, stop in enumerate(route.stops, 1):
            observation = observations[stop.task_id]
            task, listing = observation['task'], observation['listing']
            stops.append(dict(task_id=stop.task_id, claim_id=task['claim_id'], listing_id=task['listing_id'],
                location_id=stop.location_id, road_node_id=stop.road_node_id, ordinal=ordinal,
                latitude=listing['pickup_latitude'], longitude=listing['pickup_longitude'],
                load_kg=task['load_kg']))
        routes.append(dict(vehicle_id=route.vehicle_id,
            vehicle_label=vehicles[route.vehicle_id].get('vehicle_label') or route.vehicle_id,
            total_distance_km=float(km),
            total_duration_min=(route.return_us-route.departure_us)/60_000_000,
            total_load_kg=float(sum((Decimal(str(s['load_kg'])) for s in stops), Decimal(0))),
            pickup_count=len(stops), pickup_location_count=len({s['location_id'] for s in stops}),
            depot=depot.copy(), stops=stops, geometry_status='UNAVAILABLE'))
    return dict(version='geolock.proposed-display.v1', snapshot_id=bundle['snapshot']['snapshot_id'],
        graph_id=bundle['matrix'].get('graph_id'), routes=routes, geometry_status='UNAVAILABLE')


def planning_response(bundle,comparison,*,database_candidate=None,attested_digest=None):
    snapshot=bundle['snapshot']
    methods = {method for method, _, _ in comparison.results}
    require(len(comparison.results) == len(OPERATIONAL_METHODS) and methods == OPERATIONAL_METHODS.keys()
            and not comparison.dispatch_authority_issued, 'ADVISORY_COMPARISON_REQUIRED')
    for _,plan,validation in comparison.results:
        require(plan.snapshot_sha256==comparison.snapshot_sha256 and not plan.dispatch_authority_issued and validation.valid,'INVALID_COMPARISON')
    result=dict(kind='ADVISORY_CANDIDATE',ngo_id=snapshot['ngo_id'],snapshot_id=snapshot['snapshot_id'],
                dispatch_authority_issued=False,methods=[dict(method=method,plan=asdict(plan),validation=asdict(validation))
                for method,plan,validation in comparison.results],validation_status='LOCAL_ONLY')
    result['presentation'] = proposed_presentation(bundle,
        next(p for method,p,_ in comparison.results if method=='proposed'))
    if database_candidate is not None:
        require(database_candidate['snapshot_id']==snapshot['snapshot_id'] and comparison.proposed_candidate is not None,'WRONG_CANDIDATE')
        require(database_candidate['body']['plan']['snapshot_sha256']==comparison.snapshot_sha256,'WRONG_CANDIDATE_INPUT')
        result.update(candidate_id=database_candidate['candidate_id'],validation_status='ATTESTED' if attested_digest==database_candidate['digest'] else 'PENDING')
    return result
