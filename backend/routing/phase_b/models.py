from dataclasses import dataclass
from decimal import Decimal
import math


@dataclass(frozen=True)
class ExecutionConfig:
    fixed_cost_weight: float = 1.0
    distance_cost_weight: float = 1.0
    deterministic_seconds_per_pass: float = 0.25

    def __post_init__(self):
        for name in ("fixed_cost_weight", "distance_cost_weight", "deterministic_seconds_per_pass"):
            value = getattr(self, name)
            if type(value) not in (int, float) or not math.isfinite(value) or value < 0:
                raise ValueError(f"{name}: finite nonnegative number required")
        if Decimal(str(self.fixed_cost_weight)) + Decimal(str(self.distance_cost_weight)) == 0:
            raise ValueError("at least one secondary cost weight must be positive")


@dataclass(frozen=True)
class Stop:
    task_id: str
    location_id: str
    road_node_id: str
    arrival_us: int
    service_start_us: int
    departure_us: int
    cumulative_load_kg: float


@dataclass(frozen=True)
class Route:
    vehicle_id: str
    ngo_id: str
    start_location_id: str
    start_node_id: str
    end_location_id: str
    end_node_id: str
    departure_us: int
    stops: tuple[Stop, ...]
    return_us: int


@dataclass(frozen=True)
class Plan:
    method: str
    snapshot_sha256: str
    matrix_sha256: str
    routes: tuple[Route, ...]
    unserved_tasks: tuple[str, ...]
    unserved_reasons: tuple[tuple[str, str], ...]
    status: str
    feasible: bool
    config: ExecutionConfig
    runtime_seconds: float = 0.0
    solver_runtime_seconds: float = 0.0
    solver_statuses: tuple[str, ...] = ()
    solver_version: str | None = None
    timeout: bool = False
    infeasibility_proven: bool = False
    coverage_optimal: bool = False
    secondary_optimal: bool = False
    optimization_objective: str | None = None
    optimization_status: str = "NOT_CLAIMED"
    pickup_task_objective_value: int | None = None
    pickup_task_objective_bound: float | None = None
    optimality_gap: float | None = None
    gap_scope: str | None = None
    secondary_objective_scaled: float | None = None
    secondary_bound_scaled: float | None = None
    dispatch_authority_issued: bool = False
