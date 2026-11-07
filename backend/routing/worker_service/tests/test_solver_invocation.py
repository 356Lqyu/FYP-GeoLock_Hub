"""New focused trace: production worker entry point, REAL OR-Tools solve."""
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch
import re
import unittest
import ortools
from ortools.sat.python import cp_model

from backend.routing.phase_b import OPERATIONAL_METHODS
from backend.routing.worker_service.journal import Journal
from backend.routing.worker_service.orchestrator import RoutingWorker
from backend.routing.worker_service.validator import Validator
from backend.routing.worker_service.transport import RPCS
from backend.routing.worker_service.tests.test_worker_flow import FakeDatabase,FakeGraph,FakeSession,SID,REQ


class SolverInvocationTests(unittest.TestCase):
    def test_real_worker_proposed_method_invokes_cp_sat_and_returns_its_plan_to_flutter(self):
        database=FakeDatabase()  # Synthetic RPC facts; the algorithms are REAL.
        actual_proposed=OPERATIONAL_METHODS['proposed']; actual_solve=cp_model.CpSolver.solve
        calls=[];proposed_plans=[]
        def spy(solver,model,*args,**kwargs):
            self.assertIsInstance(solver,cp_model.CpSolver)
            result=actual_solve(solver,model,*args,**kwargs)
            calls.append(result in (cp_model.OPTIMAL,cp_model.FEASIBLE))
            return result
        def trace_proposed(snapshot,config):
            with patch.object(cp_model.CpSolver,'solve',spy):
                plan=actual_proposed(snapshot,config)
            proposed_plans.append(plan)
            return plan
        with TemporaryDirectory() as temp:
            worker=RoutingWorker(database,FakeGraph(database),Validator(database),Journal(temp))
            with patch.dict(OPERATIONAL_METHODS,{'proposed':trace_proposed}):
                response=worker.plan(FakeSession(database),SID,REQ)
        self.assertGreaterEqual(len(calls),1)
        self.assertTrue(all(calls))
        self.assertEqual(len(proposed_plans),1)
        wire=next(m['plan'] for m in response['methods'] if m['method']=='proposed')
        self.assertEqual(wire,database.candidate['body']['plan'])
        self.assertEqual(wire['solver_version'],ortools.__version__)
        self.assertEqual(wire['optimization_objective'],'MAX_PICKUP_TASKS_THEN_MIN_DIRECTED_ROAD_KM')
        self.assertIn(wire['optimization_status'],('OPTIMAL','FEASIBLE_UNPROVEN'))
        self.assertEqual(ortools.__version__,'9.15.6755')
        self.assertEqual(response['timing_basis'],'NOMINAL_DEPARTURE_AT_SNAPSHOT_CUTOFF')
        self.assertTrue(all(r['departure_us']==0 for r in wire['routes']))
        self.assertFalse(response['dispatch_authority_issued'])

    def test_worker_scopes_are_subsets_of_migration_001_execute_grants(self):
        root=Path(__file__).resolve().parents[4]
        sql=(root/'docs/stage8/integration/001_authority_proposal.sql').read_text()
        grants={}
        for functions,role in re.findall(r'GRANT EXECUTE ON FUNCTION\s+(.*?)\s+TO\s+(geolock_\w+)\s*;',sql,re.S):
            grants.setdefault(role,set()).update(re.findall(r'public\.(\w+)\(',functions))
        self.assertEqual(set(RPCS),{'geolock_graph_worker','geolock_planner','geolock_validator'})
        for role,functions in RPCS.items():self.assertTrue(set(functions)<=grants[role],role)
        self.assertNotIn('attest_routing_candidate',RPCS['geolock_planner'])
        self.assertNotIn('authorize_my_routing_candidate',{n for funcs in RPCS.values() for n in funcs})


if __name__=='__main__':unittest.main()
