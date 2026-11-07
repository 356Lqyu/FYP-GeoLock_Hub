"""Primary proposed method: OR-Tools RoutingModel, with independent validation.

The preserved CP-SAT implementation remains available as a historical method;
distance_only still uses it. No candidate/schema/authority contract is changed.
RoutingModel local search supplies incumbents, not an assumed global optimum.
"""
from dataclasses import replace
from decimal import Decimal
from time import perf_counter
from .models import ExecutionConfig
from .problem import Problem, exact, offset, TIME_SCALE, MASS_SCALE
from .optimizers import _cost


def proposed(snapshot, config=ExecutionConfig()):
    started=perf_counter()
    problem=Problem(snapshot)
    blocked=problem.blocked('proposed',config)
    if blocked:return replace(blocked,runtime_seconds=perf_counter()-started)
    import ortools
    from ortools.constraint_solver import pywrapcp,routing_enums_pb2
    from ortools.util import optional_boolean_pb2
    settings=problem.p['solver']
    if settings['version'] not in ('NOT_INSTALLED_PHASE_A',ortools.__version__):
        raise ValueError('SOLVER_VERSION_MISMATCH')
    if settings['workers']!=1 or settings['first_solution']!='PATH_CHEAPEST_ARC' or settings['local_search']!='GUIDED_LOCAL_SEARCH':
        raise ValueError('UNSUPPORTED_ROUTING_MODEL_CONFIGURATION')
    ids,vehicles=sorted(problem.tasks),sorted(problem.fleet)
    nodes=[problem.depot]+[problem.tasks[t]['pickup']['road_node_id'] for t in ids]
    n=len(ids)
    statuses=[]
    search_timeouts=[]
    # Dependency import time is reported in total runtime, not deducted from
    # the declared RoutingModel search/build budget.
    deadline=perf_counter()+settings['time_limit_seconds']
    coefficients={vid:{(i,j):_cost(Decimal(arc[0])/1_000_000,
        problem.fleet[vid]['distance_cost_per_km'],config.distance_cost_weight)
        for i in range(len(nodes)) for j in range(len(nodes))
        if (arc:=problem.arc(nodes[i],nodes[j])) is not None} for vid in vehicles}
    fixed_costs={vid:_cost(problem.fleet[vid]['fixed_cost'],config.fixed_cost_weight) for vid in vehicles}

    def solve(coverage=None):
        manager=pywrapcp.RoutingIndexManager(len(nodes),len(vehicles),0)
        model=pywrapcp.RoutingModel(manager)
        time_cap=min(problem.horizon,max(exact(problem.fleet[v]['max_route_minutes'],TIME_SCALE) for v in vehicles))
        service=[0]+[exact(problem.tasks[t]['service_minutes'],TIME_SCALE) for t in ids]
        demand=[0]+[exact(problem.tasks[t]['weight_kg'],MASS_SCALE) for t in ids]
        def travel(i,j):
            arc=problem.arc(nodes[manager.IndexToNode(i)],nodes[manager.IndexToNode(j)])
            # Missing arcs are removed from NextVar below, never expensive substitutes.
            return service[manager.IndexToNode(i)]+(arc[1] if arc else 0)
        time_index=model.RegisterTransitCallback(travel)
        model.AddDimension(time_index,time_cap,time_cap,True,'Time')
        time=model.GetDimensionOrDie('Time')
        capacities=[exact(problem.fleet[v]['capacity_kg'],MASS_SCALE) for v in vehicles]
        demand_index=model.RegisterUnaryTransitCallback(lambda i:demand[manager.IndexToNode(i)])
        model.AddDimensionWithVehicleCapacity(demand_index,0,capacities,True,'Load')
        ends=[model.End(k) for k in range(len(vehicles))]
        for i in range(model.Size()):
            for j in list(range(model.Size()))+ends:
                if i!=j and problem.arc(nodes[manager.IndexToNode(i)],nodes[manager.IndexToNode(j)]) is None:
                    model.NextVar(i).RemoveValue(j)
        for k,vid in enumerate(vehicles):
            time.CumulVar(model.End(k)).SetMax(min(problem.horizon,exact(problem.fleet[vid]['max_route_minutes'],TIME_SCALE)))
            vehicle=problem.fleet[vid]
            def cost(i,j,vid=vid):
                if coverage is None:return 0
                return coefficients[vid].get((manager.IndexToNode(i),manager.IndexToNode(j)),0)
            model.SetArcCostEvaluatorOfVehicle(model.RegisterTransitCallback(cost),k)
            if coverage is not None:model.SetFixedCostOfVehicle(fixed_costs[vid],k)
        active=[]
        for i,tid in enumerate(ids,1):
            task=problem.tasks[tid]; index=manager.NodeToIndex(i)
            active.append(model.ActiveVar(index))
            if not task['mandatory']:model.AddDisjunction([index],1 if coverage is None else 0)
            earliest=max(0,offset(task['time_window']['start'],problem.cutoff))
            latest=min(offset(task['time_window']['end'],problem.cutoff)-service[i],
                       offset(task['lease_expires_at'],problem.cutoff)-problem.margin-service[i]-1,time_cap)
            if latest<earliest:
                model.solver().Add(model.ActiveVar(index)==0)
            else:time.CumulVar(index).SetRange(earliest,latest)
        if coverage is not None:model.solver().Add(model.solver().Sum(active)==coverage)
        params=pywrapcp.DefaultRoutingSearchParameters()
        params.first_solution_strategy=routing_enums_pb2.FirstSolutionStrategy.PATH_CHEAPEST_ARC
        params.local_search_metaheuristic=routing_enums_pb2.LocalSearchMetaheuristic.GUIDED_LOCAL_SEARCH
        # Native CP RoutingModel search is single-threaded. Do not translate
        # CP-SAT deterministic_seconds_per_pass or random_seed into fake settings.
        params.use_cp=optional_boolean_pb2.BOOL_TRUE
        params.use_cp_sat=optional_boolean_pb2.BOOL_FALSE
        params.use_generalized_cp_sat=optional_boolean_pb2.BOOL_FALSE
        params.fallback_to_cp_sat_size_threshold=0
        remaining=max(0,deadline-perf_counter())
        if coverage is None:
            if all(problem.tasks[t]['mandatory'] for t in ids):params.solution_limit=1
            else:remaining=min(remaining,settings['time_limit_seconds']/3)
        params.time_limit.FromMilliseconds(max(0,int(remaining*1000)))
        assignment=model.SolveWithParameters(params)
        enum=routing_enums_pb2.RoutingSearchStatus.DESCRIPTOR.enum_types_by_name['Value']
        status=enum.values_by_number[model.status()].name
        statuses.append('ROUTING_MODEL:'+status)
        # Query the native limit immediately after search. Python route
        # extraction/validation time must not retroactively label search a
        # timeout. The mandatory coverage pass's one-solution limit is not a
        # time limit; optional coverage and secondary passes have time budgets.
        limit_crossed=bool(model.CheckLimit())
        time_limited=(assignment is None or coverage is not None or params.solution_limit!=1)
        search_timeouts.append('TIMEOUT' in status or (limit_crossed and time_limited))
        return manager,model,assignment

    manager,model,assignment=solve()
    if assignment is None:
        proven=statuses[-1].endswith('ROUTING_INFEASIBLE')
        timed_out=not proven and search_timeouts[-1]
        return problem.finish('proposed',(),config,status='OPTIMISATION_TIMEOUT' if timed_out else 'INFEASIBLE',
            timeout=timed_out,infeasibility_proven=proven,solver_version=ortools.__version__,
            solver_statuses=tuple(statuses),runtime_seconds=perf_counter()-started,
            solver_runtime_seconds=perf_counter()-started)
    coverage=sum(assignment.Value(model.ActiveVar(manager.NodeToIndex(i))) for i in range(1,n+1))
    best=(manager,model,assignment)
    if perf_counter()<deadline:
        second=solve(coverage)
        if second[2] is not None:best=second
    manager,model,assignment=best
    routes=[]
    for k,vid in enumerate(vehicles):
        index=assignment.Value(model.NextVar(model.Start(k))); ordered=[]
        while not model.IsEnd(index):
            ordered.append(ids[manager.IndexToNode(index)-1])
            index=assignment.Value(model.NextVar(index))
        if ordered:
            route,reason=problem.schedule(vid,ordered)
            if route is None:raise RuntimeError('ROUTING_MODEL_SCHEDULE_INCONSISTENT:'+str(reason))
            routes.append(route)
    # Full task coverage proves the primary count optimum. GLS cost quality or
    # an exhausted search budget alone does not prove the secondary optimum.
    return problem.finish('proposed',routes,config,runtime_seconds=perf_counter()-started,
        solver_runtime_seconds=perf_counter()-started,solver_version=ortools.__version__,
        solver_statuses=tuple(statuses),coverage_optimal=coverage==n,secondary_optimal=False,
        timeout=any(search_timeouts),optimality_gap=None)
