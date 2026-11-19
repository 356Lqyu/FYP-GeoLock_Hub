"""Solver entry points and routing method registries."""
from .baselines import fcfs, nearest_neighbour
from .cp_sat import _optimise
from ..route_plan import ExecutionConfig


def distance_only(snapshot, config=ExecutionConfig()):
    """Maximize served pickup tasks, then minimize total directed road km."""
    return _optimise(snapshot, "distance_only", config)


def proposed(snapshot, config=ExecutionConfig()):
    """Maximize served pickup tasks, then minimize total directed road km."""
    return _optimise(snapshot, "proposed", config)


OPERATIONAL_METHODS = {"fcfs": fcfs, "nearest_neighbour": nearest_neighbour, "proposed": proposed}

METHODS = {"fcfs": fcfs, "nearest_neighbour": nearest_neighbour,
           "distance_only": distance_only, "proposed": proposed}
