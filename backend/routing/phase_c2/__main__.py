"""Credential-free synthetic claim-to-candidate demonstration; no publication."""
import argparse
from dataclasses import asdict
import json
from pathlib import Path

from ..generate_examples import build_mixed
from . import freeze_graph,build_matrix,prepare_input,evaluate


def demonstration():
    scenario=build_mixed()
    existing=scenario['matrix']; nodes=existing['node_order']; edges=[]
    for i,source in enumerate(nodes):
        for j,target in enumerate(nodes):
            if i!=j and existing['arc_status'][i][j]=='AVAILABLE':
                edges.append(dict(edge_id=f'SYNTHETIC-{i}-{j}',source_node=source,target_node=target,
                                  road_km=existing['distance_km'][i][j],travel_minutes=existing['travel_minutes'][i][j]))
    graph=freeze_graph(nodes=list(nodes),edges=edges,snapshot_id=existing['network_snapshot_id'],kind='SYNTHETIC_BENCHMARK',
                       complete=True,speed_profile='EXPLICIT SYNTHETIC EDGE TIMES')
    scenario['matrix']=build_matrix(graph,list(nodes))
    scenario['source']['provenance']+='; LOCAL C2 demo, wholly synthetic graph and fleet; no live DB inputs'
    rows=[]
    for vehicle in scenario['vehicles']:
        rows.append(dict(vehicle_id=vehicle['vehicle_id'],ngo_user_id=scenario['ngo_id'],vehicle_type=vehicle['vehicle_type'],
            payload_capacity_kg=vehicle['capacity_kg'],fixed_cost_rm=vehicle['fixed_cost'],distance_cost_rm_per_km=vehicle['distance_cost_per_km'],
            max_route_duration_min=vehicle['max_route_minutes'],active_flag=True,available_for_planning=True,
            depot_road_node_id=scenario['depot']['road_node_id'],vehicle_version=1,updated_at=scenario['cutoff']))
    prepared=prepare_input(scenario,fleet_rows=rows,held_vehicle_ids=[])
    compared=evaluate(prepared)
    return dict(synthetic=True,live_database_access=False,dispatch_authority_issued=False,source_authority='LOCAL_UNTRUSTED',
        graph_sha256=graph.sha256,input_snapshot=prepared.snapshot.to_dict(),snapshot_sha256=prepared.snapshot.sha256,
        excluded_vehicles=prepared.excluded_vehicles,
        methods=[dict(method=method,plan=asdict(plan),validation=asdict(validation)) for method,plan,validation in compared.results],
        proposed_candidate_available=compared.proposed_candidate is not None)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    result=demonstration()
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(result,sort_keys=True,indent=2,allow_nan=False)+'\n',encoding='utf-8')
    print(json.dumps(dict(synthetic=True,methods=len(result['methods']),validations=[x['validation']['valid'] for x in result['methods']],
                         proposed_candidate_available=result['proposed_candidate_available'],dispatch_authority_issued=False)))


if __name__=='__main__': main()
