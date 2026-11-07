"""Read unchanged frozen v3.3 CSVs; export synthetic snapshots, no baseline CLI."""
import hashlib
import json
from pathlib import Path
import sys

ROOT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT))


def main():
    directory=ROOT/'experiments/repro_inputs/v33'
    manifest=json.loads((directory/'generation_manifest.json').read_text())
    assert manifest['benchmark_version']=='GEOLOCK-BM-v3.3'
    seals={}
    for name,expected in manifest['generated_csv_sha256'].items():
        path=directory/(name+'.csv');actual=hashlib.sha256(path.read_bytes()).hexdigest()
        assert actual==expected;seals[name]=actual
    from experiments.e4_post_claim_routing.run import Adapter
    adapter=Adapter();cases=[(row['scenario_id'],adapter.convert(row)[1]) for row in adapter.scenarios]
    cases.sort(key=lambda pair:(len(pair[1].admitted_task_ids),pair[0]))
    selected=[cases[i] for i in sorted(set((0,len(cases)//2,len(cases)-1)))]
    value=dict(scope='EXISTING_FROZEN_V33_SYNTHETIC_BENCHMARK_SAMPLE_NOT_LIVE_BUNDLE',csv_sha256=seals,
        cases=[dict(scenario_id=sid,snapshot_sha256=snapshot.sha256,matrix_sha256=snapshot.matrix_sha256,
                    input=snapshot.to_dict()['input']) for sid,snapshot in selected])
    with (Path(__file__).parent/'frozen-v33-sample.json').open('x',encoding='utf-8') as output:json.dump(value,output)
    print('Frozen CSV seals verified; exported three synthetic min/median/max snapshots.')


if __name__=='__main__':main()
