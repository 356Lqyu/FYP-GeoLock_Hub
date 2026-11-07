"""Deterministic constructive baselines; no solver-side route validation claims."""

from time import perf_counter
from dataclasses import replace
from .models import ExecutionConfig
from .problem import Problem, offset


def _greedy(snapshot, method, config):
    started = perf_counter()
    problem = Problem(snapshot)
    blocked = problem.blocked(method, config)
    if blocked:
        return replace(blocked, runtime_seconds=perf_counter()-started)
    remaining, routes, reasons = set(problem.tasks), [], {}
    # At most one depot-return trip per vehicle. No reload or split pickup.
    for vid in sorted(problem.fleet):
        route_ids = []
        while remaining:
            current = problem.tasks[route_ids[-1]]["pickup"]["road_node_id"] if route_ids else problem.depot
            if method == "fcfs":
                order = sorted(remaining, key=lambda tid: (offset(problem.tasks[tid]["created_at"], problem.cutoff), tid))
            else:
                def key(tid):
                    arc = problem.arc(current, problem.tasks[tid]["pickup"]["road_node_id"])
                    return (arc[0] if arc is not None else float("inf"), tid)
                order = sorted(remaining, key=key)
            chosen = None
            for tid in order:
                candidate, reason = problem.schedule(vid, route_ids+[tid])
                if candidate is not None:
                    chosen = tid
                    break
                reasons[tid] = reason
            if chosen is None:
                break
            route_ids.append(chosen)
            remaining.remove(chosen)
        if route_ids:
            route, _ = problem.schedule(vid, route_ids)
            routes.append(route)
    return problem.finish(method, routes, config, reasons=reasons,
                          runtime_seconds=perf_counter()-started)


def fcfs(snapshot, config=ExecutionConfig()):
    """Oldest confirmed task first, ID tie; infeasible tasks deferred per vehicle."""
    return _greedy(snapshot, "fcfs", config)


def nearest_neighbour(snapshot, config=ExecutionConfig()):
    """Shortest available directed next arc, ID tie, fixed vehicle order."""
    return _greedy(snapshot, "nearest_neighbour", config)
