"""OR-Tools CP-SAT circuit model; pickup-task coverage then road distance.

No handwritten search, route enumeration, penalty substitute for coverage, or
ownership mutation. A separate module validates every emitted plan.
"""

from dataclasses import replace
from fractions import Fraction
from time import perf_counter
from .models import ExecutionConfig
from .problem import Problem, exact, offset, TIME_SCALE, MASS_SCALE, COST_SCALE, SAFE_INTEGER


OBJECTIVE = "MAX_PICKUP_TASKS_THEN_MIN_DIRECTED_ROAD_KM"


def _cost(*values):
    """Legacy cost conversion used only by routing_model_proposed."""
    result = Fraction(COST_SCALE)
    for value in values:
        result *= Fraction(str(value))
    if result.denominator != 1 or result.numerator > SAFE_INTEGER:
        raise ValueError("UNSUPPORTED_PRECISION_OR_RANGE: secondary cost")
    return result.numerator


def _optimise(snapshot, method, config):
    started = perf_counter()
    problem = Problem(snapshot)
    blocked = problem.blocked(method, config)
    if blocked:
        return replace(blocked, runtime_seconds=perf_counter()-started)
    import ortools
    from ortools.sat.python import cp_model

    declared = problem.p["solver"]["version"]
    if declared not in ("NOT_INSTALLED_PHASE_A", ortools.__version__):
        raise ValueError("SOLVER_VERSION_MISMATCH")
    seed = problem.p["solver"]["seed"]
    if seed > 2**31-1:
        raise ValueError("UNSUPPORTED_SOLVER_SEED")
    model = cp_model.CpModel()
    ids, vids = sorted(problem.tasks), sorted(problem.fleet)
    n = len(ids)
    assigned, arcs_by_vehicle = {}, {}
    distance_terms, distance_bound = [], 0
    weights = [exact(problem.tasks[t]["weight_kg"], MASS_SCALE) for t in ids]
    if sum(weights) > SAFE_INTEGER:
        raise ValueError("UNSUPPORTED_TOTAL_MASS")
    for vi, vid in enumerate(vids):
        v = problem.fleet[vid]
        horizon = min(problem.horizon, exact(v["max_route_minutes"], TIME_SCALE))
        used = model.new_bool_var(f"used_{vi}")
        ys = [model.new_bool_var(f"visit_{vi}_{i}") for i in range(n)]
        for i, y in enumerate(ys):
            assigned[vi, i] = y
            model.add(y <= used)
        model.add(sum(ys) >= used)
        model.add(sum(weights[i]*ys[i] for i in range(n)) <= exact(v["capacity_kg"], MASS_SCALE))
        starts = [model.new_int_var(0, horizon, f"start_{vi}_{i}") for i in range(n)]
        returned = model.new_int_var(0, horizon, f"return_{vi}")
        model.add(returned == 0).only_enforce_if(used.Not())
        for i, tid in enumerate(ids):
            task = problem.tasks[tid]
            service = exact(task["service_minutes"], TIME_SCALE)
            earliest = max(0, offset(task["time_window"]["start"], problem.cutoff))
            latest = min(offset(task["time_window"]["end"], problem.cutoff)-service,
                         offset(task["lease_expires_at"], problem.cutoff)-problem.margin-service-1)
            model.add(starts[i] >= earliest).only_enforce_if(ys[i])
            model.add(starts[i] <= latest).only_enforce_if(ys[i])
            model.add(starts[i] == 0).only_enforce_if(ys[i].Not())
        nodes = [problem.depot] + [problem.tasks[t]["pickup"]["road_node_id"] for t in ids]
        circuit = [(0, 0, used.Not())] + [(i+1, i+1, ys[i].Not()) for i in range(n)]
        arcs = {}
        for i in range(n+1):
            for j in range(n+1):
                if i == j:
                    continue
                arc = problem.arc(nodes[i], nodes[j])
                if arc is None:
                    continue  # truly absent from model, never an expensive fake arc
                x = model.new_bool_var(f"arc_{vi}_{i}_{j}")
                arcs[i, j] = x
                circuit.append((i, j, x))
                if i == 0:
                    model.add(starts[j-1] >= arc[1]).only_enforce_if(x)
                elif j == 0:
                    service = exact(problem.tasks[ids[i-1]]["service_minutes"], TIME_SCALE)
                    model.add(returned == starts[i-1]+service+arc[1]).only_enforce_if(x)
                else:
                    service = exact(problem.tasks[ids[i-1]]["service_minutes"], TIME_SCALE)
                    model.add(starts[j-1] >= starts[i-1]+service+arc[1]).only_enforce_if(x)
                # Both CP-SAT methods use raw directed road millimetres as
                # their secondary objective. Vehicle costs do not affect it.
                distance_terms.append(arc[0]*x)
                distance_bound += arc[0]
        model.add_circuit(circuit)
        arcs_by_vehicle[vi] = arcs
    if distance_bound > SAFE_INTEGER:
        raise ValueError("UNSUPPORTED_OBJECTIVE_RANGE")
    for i, tid in enumerate(ids):
        visits = sum(assigned[vi, i] for vi in range(len(vids)))
        model.add(visits == 1 if problem.tasks[tid]["mandatory"] else visits <= 1)
    served = sum(assigned.values())
    model.maximize(served)
    error = model.validate()
    if error:
        raise ValueError("INVALID_SOLVER_MODEL: "+error)

    def solver():
        s = cp_model.CpSolver()
        s.parameters.num_search_workers = 1
        s.parameters.random_seed = seed
        s.parameters.max_deterministic_time = config.deterministic_seconds_per_pass
        # Two passes together stay within the declared solver wall budget.
        s.parameters.max_time_in_seconds = problem.p["solver"]["time_limit_seconds"]/2
        return s

    first = solver()
    first_status = first.solve(model)
    statuses = [first.status_name(first_status)]
    solver_runtime = first.wall_time
    metadata = dict(solver_version=ortools.__version__, solver_statuses=tuple(statuses),
                    solver_runtime_seconds=solver_runtime)
    if first_status not in (cp_model.OPTIMAL, cp_model.FEASIBLE):
        if first_status == cp_model.MODEL_INVALID:
            raise ValueError("INVALID_SOLVER_MODEL: "+first.response_stats())
        return problem.finish(method, (), config,
                              status="INFEASIBLE" if first_status == cp_model.INFEASIBLE else "OPTIMISATION_TIMEOUT",
                              timeout=first_status == cp_model.UNKNOWN,
                              infeasibility_proven=first_status == cp_model.INFEASIBLE,
                              optimization_objective=OBJECTIVE,
                              optimization_status="INFEASIBLE" if first_status == cp_model.INFEASIBLE else "NO_FEASIBLE_SOLUTION",
                              runtime_seconds=perf_counter()-started, **metadata)
    chosen = first
    coverage_optimal = first_status == cp_model.OPTIMAL
    secondary_optimal = False
    gap, bound, objective = None, None, None
    coverage = sum(first.value(y) for y in assigned.values())
    coverage_bound = first.best_objective_bound
    model.add(served == coverage)
    model.minimize(sum(distance_terms))
    second = solver()
    second_status = second.solve(model)
    statuses.append(second.status_name(second_status))
    solver_runtime += second.wall_time
    if second_status in (cp_model.MODEL_INVALID, cp_model.INFEASIBLE):
        raise RuntimeError("FIXED_COVERAGE_MODEL_INCONSISTENT: "+second.response_stats())
    if second_status in (cp_model.OPTIMAL, cp_model.FEASIBLE):
        chosen = second
        secondary_optimal = second_status == cp_model.OPTIMAL
        objective = second.objective_value
        bound = second.best_objective_bound
        gap = max(0.0, objective-bound)/max(1.0, abs(objective))
    timeout = not (coverage_optimal and secondary_optimal)
    routes = []
    for vi, vid in enumerate(vids):
        arcs = arcs_by_vehicle[vi]
        nexts = {i: j for (i, j), x in arcs.items() if chosen.value(x)}
        if 0 not in nexts:
            continue
        ordered, node = [], nexts[0]
        while node != 0:
            if node in ordered or len(ordered) >= n:
                raise RuntimeError("INVALID_SOLVER_CIRCUIT")
            ordered.append(node)
            node = nexts[node]
        route, reason = problem.schedule(vid, [ids[i-1] for i in ordered])
        if route is None:
            raise RuntimeError("SOLVER_SCHEDULE_INCONSISTENT: "+str(reason))
        routes.append(route)
    return problem.finish(method, routes, config, runtime_seconds=perf_counter()-started,
                          solver_runtime_seconds=solver_runtime, solver_version=ortools.__version__,
                          solver_statuses=tuple(statuses), timeout=timeout,
                          coverage_optimal=coverage_optimal, secondary_optimal=secondary_optimal,
                          optimization_objective=OBJECTIVE,
                          optimization_status="OPTIMAL" if coverage_optimal and secondary_optimal else "FEASIBLE_UNPROVEN",
                          pickup_task_objective_value=coverage,
                          pickup_task_objective_bound=coverage_bound,
                          optimality_gap=gap, secondary_bound_scaled=bound,
                          secondary_objective_scaled=objective,
                          gap_scope="FIXED_PICKUP_TASK_COUNT_DIRECTED_DISTANCE" if gap is not None else None)
