"""Historical E4 v3.3 admission adapter for offline diagnostics.

This adapter retains the 483-task policy of the November 5 evidence. The
current E4 runner uses its own 500-task admission policy. The compatibility adapter is used by the two offline diagnostics.
"""
from types import SimpleNamespace

from experiments.routing_research.benchmark_v32.adapter import Adapter as ExistingAdapter
from backend.routing.contract import freeze_scenario
from experiments.repro_benchmark import DATA, ROOT, module, rows

SETTINGS=dict(approved=True,geofence_km=20,lease_minutes=360,route_minutes=240,service_minutes=10,
 safety_margin_minutes=0,mandatory=False,availability_policy='BASELINE_ROUTING_WINDOW',
 listing_expiry_policy='COMMON_STAGE8_ADMISSION',currency='BENCHMARK_COST_UNIT',fixed_cost=5,
 distance_cost_per_km=1,solver_wall_seconds=30,deterministic_seconds_per_pass=0.25,seed=42)

class Adapter(ExistingAdapter):
    def __init__(self):
        self.settings=dict(SETTINGS);self.root=ROOT;self.modules={n:module(n) for n in ('fcfs','nearest_next')}
        self.base=self.modules['nearest_next'];self.args=SimpleNamespace(**SETTINGS)
        self.data=self.base.setup_route_data(DATA)
        self.nodes={r['road_node_id']:r for r in rows(DATA/'road_nodes.csv')}
        self.scenarios=self.base.select_scenarios(self.data,('ROUTE_PLANNING',),None)
        assert len(self.scenarios)==100
    def convert(self,scenario):
        shared,frozen=super().convert(scenario)
        # Version labels only; never regenerate/rewrite source data or costs.
        payload=frozen.to_dict()['input']
        def version(v):
            if isinstance(v,dict):return {k:version(x) for k,x in v.items()}
            if isinstance(v,list):return [version(x) for x in v]
            return 'OSM-DIRECTED-v3.3' if v=='OSM-DIRECTED-v3.2' else v
        payload=version(payload);payload['configuration']['version']='E4-V33-ACTUAL-WORKER'
        return shared,freeze_scenario(payload)
