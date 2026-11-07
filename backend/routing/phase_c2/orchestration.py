"""Local orchestration contracts. No HTTP, SQL, assignments or authorization.

Input state tokens/hash declarations are not authenticated DB snapshots.
The future C3 adapter must capture authoritative joins in one consistent snapshot.
"""
from dataclasses import dataclass
from datetime import datetime
from decimal import Decimal
import json
from typing import Protocol

from ..contract import freeze_scenario
from ..phase_b import METHODS
from ..phase_b.models import ExecutionConfig,Plan
from ..phase_b.validation import validate_plan
from .matrices import digest, numeric, require


class ReadOnlyPlanningSource(Protocol):
    def read(self, ngo_id: str, cutoff: str) -> dict:
        """Return source/task/depot/config and observed fleet/hold facts; no writes.

        Caller-supplied joins do not constitute a sealed authoritative snapshot.
        Time windows, service duration and mandatory policy must be explicit.
        """
        ...


@dataclass(frozen=True)
class PreparedInput:
    snapshot: object
    excluded_vehicles: tuple


def prepare_input(payload,*,fleet_rows=None,held_vehicle_ids=None):
    # Copy first: never mutate a source export or the caller's original scenario.
    value=json.loads(json.dumps(payload,allow_nan=False))
    excluded=[]
    if fleet_rows is not None:
        require(type(fleet_rows) is list,'INVALID_FLEET_EXPORT')
        require(held_vehicle_ids is not None or not fleet_rows,'MISSING_HOLD_EXPORT')
        held_vehicle_ids=[] if held_vehicle_ids is None else held_vehicle_ids
        require(type(held_vehicle_ids) in (list,tuple,set) and all(type(v) is str for v in held_vehicle_ids),'INVALID_HOLD_EXPORT')
        value['vehicles']=[]; seen=set()
        for row in fleet_rows:
            require(type(row) is dict,'INVALID_FLEET_EXPORT')
            require(row.get('ngo_user_id')==value['ngo_id'],'FOREIGN_VEHICLE')
            vid=row.get('vehicle_id')
            require(type(vid) is str and bool(vid) and vid not in seen,'DUPLICATE_VEHICLE')
            seen.add(vid)
            for flag in ('active_flag','available_for_planning'):
                require(type(row.get(flag)) is bool,'INVALID_VEHICLE_FLAG')
            reason=('DEACTIVATED' if not row['active_flag'] else 'UNAVAILABLE' if not row['available_for_planning']
                    else 'ACTIVE_ROUTE_HOLD' if vid in held_vehicle_ids else None)
            if 'eligible_for_planning' in row:
                require(type(row['eligible_for_planning']) is bool,'INVALID_VEHICLE_FLAG')
                if not row['eligible_for_planning']: reason=reason or 'INELIGIBLE_RPC_EXPORT'
            required=('vehicle_type','payload_capacity_kg','fixed_cost_rm','distance_cost_rm_per_km','max_route_duration_min','depot_road_node_id','vehicle_version','updated_at')
            if reason is None and any(row.get(k) is None for k in required):
                reason='INCOMPLETE_FLEET'
            if reason is None and row['depot_road_node_id']!=value['depot']['road_node_id']:
                reason='DEPOT_MISMATCH'
            if reason:
                excluded.append((vid,reason)); continue
            require(type(row['vehicle_version']) is int and row['vehicle_version']>0,'INVALID_VEHICLE_VERSION')
            require(type(row['updated_at']) is str and bool(row['updated_at']),'INVALID_VEHICLE_VERSION')
            try:
                updated=datetime.fromisoformat(row['updated_at'].replace('Z','+00:00'))
                cutoff=datetime.fromisoformat(value['cutoff'].replace('Z','+00:00'))
            except ValueError:
                require(False,'INVALID_VEHICLE_VERSION')
            require(updated.tzinfo is not None and cutoff.tzinfo is not None and updated<=cutoff,'VEHICLE_AFTER_CUTOFF')
            require(type(row['vehicle_type']) is str and 1<=len(row['vehicle_type'].strip())<=80,'INVALID_VEHICLE_TYPE')
            capacity=numeric(row['payload_capacity_kg'],True)
            fixed=numeric(row['fixed_cost_rm']); cost=numeric(row['distance_cost_rm_per_km'])
            duration=numeric(row['max_route_duration_min'],True)
            require(capacity<Decimal('1000000000') and capacity==capacity.quantize(Decimal('.001')),'INVALID_VEHICLE_CAPACITY')
            require(-fixed.as_tuple().exponent<=2 and -cost.as_tuple().exponent<=4 and -duration.as_tuple().exponent<=3,'INVALID_VEHICLE_PRECISION')
            # Explicit rejection rather than clipping the NGO's maximum duration.
            require(duration<=Decimal(str(value['configuration']['planning_horizon_minutes'])),'INVALID_ROUTE_HORIZON')
            fields={k:row[k] for k in required}
            fields.update(vehicle_id=vid,ngo_user_id=row['ngo_user_id'],active_flag=True,available_for_planning=True)
            value['vehicles'].append(dict(vehicle_id=vid,ngo_id=row['ngo_user_id'],vehicle_type=row['vehicle_type'],
                capacity_kg=float(capacity),active=True,available_for_planning=True,fixed_cost=float(fixed),
                distance_cost_per_km=float(cost),max_route_minutes=float(duration),
                depot_location_id=value['depot']['location_id'],state_token=digest(fields)))
    else:
        # An explicit hold can only remove availability, never grant eligibility.
        for vehicle in value['vehicles']:
            if vehicle['vehicle_id'] in (held_vehicle_ids or ()):
                vehicle['available_for_planning']=False
                excluded.append((vehicle['vehicle_id'],'ACTIVE_ROUTE_HOLD'))
    return PreparedInput(freeze_scenario(value),tuple(sorted(excluded)))


@dataclass(frozen=True)
class Comparison:
    snapshot_sha256: str
    results: tuple
    proposed_candidate: object
    dispatch_authority_issued: bool = False
    source_authority: str = 'LOCAL_UNTRUSTED'


def evaluate(prepared,config=ExecutionConfig()):
    snapshot=prepared.snapshot
    require(freeze_scenario(snapshot.to_dict()['input'])==snapshot,'INPUT_DIGEST_MISMATCH')
    require(set(METHODS)=={'fcfs','nearest_neighbour','distance_only','proposed'},'INCOMPLETE_METHOD_SET')
    results=[]; candidate=None
    for method,solve in METHODS.items():
        plan=solve(snapshot,config)
        require(isinstance(plan,Plan),'INVALID_SOLVER_RESULT')
        validation=validate_plan(snapshot,plan)
        # A structurally valid infeasibility report must never become a route.
        require(validation.valid,'INDEPENDENT_VALIDATION_FAILED')
        require(plan.method==method and not plan.dispatch_authority_issued,'INVALID_SOLVER_AUTHORITY')
        results.append((method,plan,validation))
        if method=='proposed' and validation.feasible and plan.feasible and plan.routes:
            candidate=plan
    return Comparison(snapshot.sha256,tuple(results),candidate)
