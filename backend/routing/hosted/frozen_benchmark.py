"""Read-only frozen v3.3 offline solver sample; no graph/Render capacity claim."""
import argparse
from dataclasses import asdict
import json
from pathlib import Path
from time import perf_counter

from .benchmark import peak_memory


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',required=True);a=p.parse_args()
    from experiments.repro_benchmark import sha, ROOT
    from experiments.e4_post_claim_routing.run import Adapter
    from ..phase_b import METHODS,validate_plan
    from ..phase_b.models import ExecutionConfig
    manifest_path=ROOT/'experiments/repro_inputs/v33/generation_manifest.json'
    manifest=json.loads(manifest_path.read_text(encoding='utf-8'))
    if manifest['benchmark_version']!='GEOLOCK-BM-v3.3':raise ValueError('FROZEN_V33_REQUIRED')
    verified={}
    for name,expected in manifest['generated_csv_sha256'].items():
        path=manifest_path.parent/(name+'.csv')
        observed=sha(path)
        if observed!=expected:raise ValueError('FROZEN_INPUT_CHANGED: '+name)
        verified[str(path.relative_to(ROOT))]=observed
    adapter=Adapter()
    converted=[(s['scenario_id'],adapter.convert(s)[1]) for s in adapter.scenarios]
    converted.sort(key=lambda pair:(len(pair[1].admitted_task_ids),pair[0]))
    # Fixed min/median/max admission sample, no selection by measured performance.
    selected=[converted[i] for i in sorted(set((0,len(converted)//2,len(converted)-1)))]
    result=dict(scope='FROZEN-V33-PRECOMPUTED-MATRICES-THREE-SCENARIO-SAMPLE',
                resource_limits='UNCAPPED_WINDOWS_NOT_RENDER',integrity=verified,
                generation_manifest_sha256=sha(ROOT/'experiments/repro_inputs/v33/generation_manifest.json'),
                scenarios=[])
    for sid,snapshot in selected:
        case=dict(scenario_id=sid,admitted_tasks=len(snapshot.admitted_task_ids),
                  snapshot_sha256=snapshot.sha256,matrix_sha256=snapshot.matrix_sha256,methods=[])
        for method,solve in METHODS.items():
            began=perf_counter();plan=solve(snapshot,ExecutionConfig());elapsed=perf_counter()-began
            began=perf_counter();check=validate_plan(snapshot,plan);duration=perf_counter()-began
            case['methods'].append(dict(method=method,solve_seconds=elapsed,validate_seconds=duration,
                                        validation=asdict(check),peak_memory=peak_memory(),timeout=plan.timeout))
            if not check.valid: raise AssertionError((sid,method,check.violations))
        result['scenarios'].append(case)
    with Path(a.output).open('x',encoding='utf-8') as stream:json.dump(result,stream,indent=2,default=str);stream.write('\n')


if __name__=='__main__': main()
